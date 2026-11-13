import AVFoundation
import Foundation
import CoreFoundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

private final class RTCQualityStatsCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[RTCQualityStatRecord], Never>?
    init(_ continuation: CheckedContinuation<[RTCQualityStatRecord], Never>) { self.continuation = continuation }
    func complete(_ records: [RTCQualityStatRecord]) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: records)
    }
}

#if canImport(WebRTC)
@MainActor
extension WebRTCVideoMediaClient {
    func maybeEmitConnected() {
        let videoReady = activeMediaMode == "audio"
            || remoteCameraPausedByContract
            || remoteVideoFrameReady
        guard iceConnected, remoteAudioRTPReady, videoReady else { return }
        if !connectedEmitted {
            connectedEmitted = true
            qualityTelemetrySession?.start()
            emit(.mediaConnected)
        } else if awaitingMediaRecovery {
            awaitingMediaRecovery = false
            emit(.connectionRecovered)
        }
    }

    func startMediaReadinessProbe() {
        guard mediaReadinessTask == nil,
              let context = currentContext,
              let peerConnection else { return }
        mediaReadinessGeneration &+= 1
        let generation = mediaReadinessGeneration
        let epoch = sessionEpoch
        let callID = context.callID
        mediaReadinessTask = Task { @MainActor [weak self] in
            defer {
                if self?.mediaReadinessGeneration == generation {
                    self?.mediaReadinessTask = nil
                }
            }
            while !Task.isCancelled {
                guard let self,
                      self.mediaReadinessGeneration == generation,
                      self.sessionEpoch == epoch,
                      self.currentContext?.callID == callID,
                      self.peerConnection === peerConnection else { return }
                if self.iceConnected, self.remoteAudioTrackReady {
                    let sample = await self.inboundMediaRTPStats(peerConnection: peerConnection)
                    guard !Task.isCancelled,
                          self.mediaReadinessGeneration == generation,
                          self.sessionEpoch == epoch,
                          self.currentContext?.callID == callID,
                          self.peerConnection === peerConnection else { return }
                    let hasBaseline = self.lastInboundAudioBytes > 0 && self.lastInboundAudioPackets > 0
                    let audioGrew = sample.audioBytes > self.lastInboundAudioBytes
                        && sample.audioPackets > self.lastInboundAudioPackets
                    let requiresVideoGrowth = self.activeMediaMode == "video"
                        && !self.remoteCameraPausedByContract
                    let hasVideoBaseline = self.lastInboundVideoBytes > 0
                        && self.lastInboundVideoPackets > 0
                        && self.lastInboundVideoFrames > 0
                    let videoGrew = sample.videoBytes > self.lastInboundVideoBytes
                        && sample.videoPackets > self.lastInboundVideoPackets
                        && sample.videoFrames > self.lastInboundVideoFrames
                    if hasBaseline, audioGrew,
                       !requiresVideoGrowth || (hasVideoBaseline && videoGrew) {
                        self.lastInboundAudioBytes = sample.audioBytes
                        self.lastInboundAudioPackets = sample.audioPackets
                        self.lastInboundVideoBytes = sample.videoBytes
                        self.lastInboundVideoPackets = sample.videoPackets
                        self.lastInboundVideoFrames = sample.videoFrames
                        self.remoteAudioRTPReady = true
                        self.videoDebug(
                            "remote_media_rtp_ready audioBytes=\(sample.audioBytes) audioPackets=\(sample.audioPackets) videoFrames=\(sample.videoFrames)"
                        )
                        self.maybeEmitConnected()
                        return
                    }
                    if sample.audioBytes > 0, sample.audioPackets > 0 {
                        self.lastInboundAudioBytes = sample.audioBytes
                        self.lastInboundAudioPackets = sample.audioPackets
                    }
                    if sample.videoBytes > 0, sample.videoPackets > 0, sample.videoFrames > 0 {
                        self.lastInboundVideoBytes = sample.videoBytes
                        self.lastInboundVideoPackets = sample.videoPackets
                        self.lastInboundVideoFrames = sample.videoFrames
                    }
                }
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
        }
    }

    private func inboundMediaRTPStats(
        peerConnection: RTCPeerConnection
    ) async -> (
        audioBytes: Int64,
        audioPackets: Int64,
        videoBytes: Int64,
        videoPackets: Int64,
        videoFrames: Int64
    ) {
        return await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                var audioBytes: Int64 = 0
                var audioPackets: Int64 = 0
                var videoBytes: Int64 = 0
                var videoPackets: Int64 = 0
                var videoFrames: Int64 = 0
                for statistic in report.statistics.values {
                    guard statistic.type.lowercased() == "inbound-rtp" else { continue }
                    let kind = (statistic.values["kind"] as? String
                        ?? statistic.values["mediaType"] as? String
                        ?? "").lowercased()
                    if kind == "audio" {
                        audioBytes += (statistic.values["bytesReceived"] as? NSNumber)?.int64Value ?? 0
                        audioPackets += (statistic.values["packetsReceived"] as? NSNumber)?.int64Value ?? 0
                    } else if kind == "video" {
                        videoBytes += (statistic.values["bytesReceived"] as? NSNumber)?.int64Value ?? 0
                        videoPackets += (statistic.values["packetsReceived"] as? NSNumber)?.int64Value ?? 0
                        videoFrames += (statistic.values["framesDecoded"] as? NSNumber)?.int64Value
                            ?? (statistic.values["framesReceived"] as? NSNumber)?.int64Value
                            ?? 0
                    }
                }
                continuation.resume(
                    returning: (audioBytes, audioPackets, videoBytes, videoPackets, videoFrames)
                )
            }
        }
    }

    func qualityStatRecords(for connection: RTCPeerConnection) async -> [RTCQualityStatRecord] {
        return await withCheckedContinuation { continuation in
            let request = RTCQualityStatsCompletion(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { request.complete([]) }
            connection.statistics { report in
                let records = report.statistics.values.map { statistic in
                    let values = statistic.values
                    func string(_ key: String) -> String? {
                        values[key] as? String
                    }
                    func double(_ key: String) -> Double? {
                        (values[key] as? NSNumber)?.doubleValue
                    }
                    func int64(_ key: String) -> Int64? {
                        guard let value = (values[key] as? NSNumber)?.doubleValue,
                              value.isFinite, value.rounded(.towardZero) == value,
                              value >= 0, value <= 9_007_199_254_740_991 else { return nil }
                        return Int64(value)
                    }
                    func bool(_ key: String) -> Bool? {
                        (values[key] as? NSNumber)?.boolValue
                    }
                    func identifier(_ key: String) -> String? {
                        if let value = values[key] as? String { return value }
                        if let value = values[key] as? NSNumber { return value.stringValue }
                        return nil
                    }
                    return RTCQualityStatRecord(
                        id: statistic.id,
                        type: statistic.type,
                        timestampUS: statistic.timestamp_us,
                        selectedCandidatePairID: string("selectedCandidatePairId"),
                        localCandidateID: string("localCandidateId"),
                        remoteCandidateID: string("remoteCandidateId"),
                        candidateType: string("candidateType"),
                        protocolName: string("protocol"),
                        relayProtocol: string("relayProtocol"),
                        candidateURL: string("url"),
                        state: string("state"),
                        selected: bool("selected"),
                        nominated: bool("nominated"),
                        currentRoundTripTimeSeconds: double("currentRoundTripTime"),
                        availableOutgoingBitrateBPS: double("availableOutgoingBitrate"),
                        jitterSeconds: double("jitter"),
                        packetsLost: int64("packetsLost"),
                        packetsReceived: int64("packetsReceived"),
                        bytesReceived: int64("bytesReceived"),
                        bytesSent: int64("bytesSent"),
                        framesPerSecond: double("framesPerSecond"),
                        framesDropped: int64("framesDropped"),
                        concealedSamples: int64("concealedSamples"),
                        totalSamplesReceived: int64("totalSamplesReceived"),
                        freezeCount: int64("freezeCount"),
                        kind: string("kind"),
                        mediaType: string("mediaType"),
                        codecID: string("codecId"),
                        mimeType: string("mimeType"),
                        ssrc: identifier("ssrc"),
                        framesEncoded: int64("framesEncoded"),
                        framesSent: int64("framesSent"),
                        framesReceived: int64("framesReceived"),
                        framesDecoded: int64("framesDecoded")
                    )
                }
                Task { @MainActor [weak self] in
                    guard let self, self.peerConnection === connection else { return }
                    self.videoDebug(rtcVideoFrameStatsSummary(records))
                }
                request.complete(records)
            }
        }
    }

    func videoDebug(_ message: @autoclosure () -> String) {
        let value = message()
        let callID = currentDebugID.isEmpty ? "no-call" : currentDebugID
#if DEBUG
        NSLog("[JHT RTC][Video:%@] %@", callID, value)
#endif
        Task {
            await RTCCallDiagnosticLogStore.shared.append(category: "VideoMedia", media: "video", callID: callID, message: value)
        }
    }

    static func shortStableHash(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "missing" }
        var hash: UInt32 = 2_166_136_261
        for byte in trimmed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    static func safeErrorLabel(_ error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let signalError = error as? RTCVideoSignalHTTPError {
            return "signal_http:\(signalError.statusCode):\(signalError.code)"
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .missingContext:
                return "missing_context"
            case .badURL:
                return "bad_url"
            case .unauthorized:
                return "unauthorized"
            case .forbidden:
                return "forbidden"
            case let .businessForbidden(code, _, _):
                return "business_forbidden:\(code)"
            case let .conflict(code, _):
                return "conflict:\(code)"
            case .server:
                return "server"
            case let .httpStatus(statusCode, _):
                return "http_status:\(statusCode)"
            case .securityBlocked:
                return "security_blocked"
            case let .forcedAuthRequired(requirement):
                return "forced_auth_required:\(requirement.rawValue)"
            case let .loginSecurity(code, _, _):
                return "login_security:\(code)"
            case let .rateLimited(code, _, _, _):
                return "rate_limited:\(code)"
            case .emptyResponse:
                return "empty_response"
            }
        }
        if let urlError = error as? URLError {
            return "url:\(urlError.code.rawValue)"
        }
        return String(describing: type(of: error))
    }

    // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：只记录安全错误字段，不输出 userInfo/凭据
    static func safeErrorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [
            "label=\(safeErrorLabel(error))",
            "type=\(String(describing: type(of: error)))",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlyingDomain=\(underlying.domain)")
            parts.append("underlyingCode=\(underlying.code)")
        }
        return parts.joined(separator: " ")
    }
    // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
}
#endif

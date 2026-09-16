import AVFoundation
import Foundation
import CoreFoundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

enum RTCVideoMediaEvent: String, Sendable, Equatable {
    case previewReady
    case localTrackReady
    case remoteAudioTrackReady
    case remoteVideoTrackReady
    case signaling
    case connecting
    case mediaConnected
    case reconnecting
    case connectionRecovered
    case cameraPaused
    case cameraUnavailable
    case cameraResumed
    case cameraSwitching
    case cameraSwitched
    case remoteCameraPaused
    case remoteCameraResumed
    case remoteDowngradedToAudio
    case serverSignalTerminal
    case failed
    case closed
}

// JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
struct RTCVideoSignalHTTPError: Error, RTCSignalHTTPFailureRepresenting, Sendable, Equatable, LocalizedError {
// JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
    let statusCode: Int
    let code: String
    let message: String

    var errorDescription: String? { message }
}

enum RTCVideoSignalFailurePolicy {
    private static func normalizedCode(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    static func isAuthoritativeTerminal(_ error: Error) -> Bool {
        guard let error = error as? RTCVideoSignalHTTPError else { return false }
        let code = normalizedCode(error.code)
        return (error.statusCode == 409 && code == "rtc_call_not_active")
            || (error.statusCode == 404 && code == "rtc_call_not_found")
    }

    static func shouldDropBestEffort(kind: RemoteRTCSignalKind, after error: Error) -> Bool {
        guard kind == .mediaState,
              let error = error as? RTCVideoSignalHTTPError else {
            return false
        }
        return error.statusCode == 422
            && normalizedCode(error.code) == "rtc_signal_payload_invalid"
    }
}

enum RTCVideoSignalPollingFailurePolicy {
    static func isLongPollTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    static func shouldEmitReconnecting(after error: Error, iceConnected: Bool) -> Bool {
        !(iceConnected && isLongPollTimeout(error))
    }
}

// JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
enum RTCVideoSignalPollingBackoffPolicy {
    static let failureDelayNanoseconds: [UInt64] = [
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        16_000_000_000,
        30_000_000_000
    ]
    static let quickEmptyMinimumDelayNanoseconds: UInt64 = 1_000_000_000

    static func delayNanoseconds(afterFailureCount failureCount: Int, stableKey: String) -> UInt64 {
        guard !failureDelayNanoseconds.isEmpty else { return 0 }
        let index = min(max(failureCount, 1) - 1, failureDelayNanoseconds.count - 1)
        let baseDelay = failureDelayNanoseconds[index]
        guard baseDelay > 0 else { return 0 }
        let jitterWindow = max(baseDelay / 5, 1)
        return addingClamped(baseDelay, deterministicJitterNanoseconds(stableKey: stableKey, modulo: jitterWindow))
    }

    static func shouldDelayQuickEmptyPage(
        itemCount: Int,
        previousCursor: String,
        nextCursor: String,
        elapsedNanoseconds: UInt64
    ) -> Bool {
        itemCount == 0
            && (nextCursor.isEmpty || nextCursor == previousCursor)
            && elapsedNanoseconds < quickEmptyMinimumDelayNanoseconds
    }

    private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }

    private static func deterministicJitterNanoseconds(stableKey: String, modulo: UInt64) -> UInt64 {
        guard modulo > 0 else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stableKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash % modulo
    }
}

struct RTCVideoSignalPollingBackoffState {
    private(set) var failureCount = 0

    mutating func reset() {
        failureCount = 0
    }

    mutating func recordFailureAndDelayNanoseconds(stableKey: String) -> UInt64 {
        failureCount += 1
        return RTCVideoSignalPollingBackoffPolicy.delayNanoseconds(
            afterFailureCount: failureCount,
            stableKey: stableKey
        )
    }
}
// JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

enum RTCVideoMediaStatePayload {
    static func make(
        cameraEnabled: Bool? = nil,
        microphoneEnabled: Bool? = nil,
        mediaMode: String
    ) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "media_mode": .string(mediaMode)
        ]
        if let cameraEnabled {
            payload["camera_enabled"] = .bool(cameraEnabled)
        }
        if let microphoneEnabled {
            payload["microphone_enabled"] = .bool(microphoneEnabled)
        }
        return payload
    }
}

enum RTCVideoSignalLongPollPolicy {
    static let maximumWaitMS = 25_000
    static let timeoutSafetyMarginSeconds: TimeInterval = 5

    static func normalizedWaitMS(_ waitMS: Int) -> Int {
        min(max(waitMS, 0), maximumWaitMS)
    }

    static func requestTimeout(waitMS: Int) -> TimeInterval {
        let waitSeconds = TimeInterval(normalizedWaitMS(waitMS)) / 1_000
        return waitSeconds + timeoutSafetyMarginSeconds
    }
}

struct RTCVideoCapturePolicy {
    static func shouldCapture(cameraEnabledIntent: Bool, isApplicationBackgrounded: Bool) -> Bool {
        cameraEnabledIntent && !isApplicationBackgrounded
    }
}

struct RTCVideoCameraFailurePolicy {
    static func resolvedIntent(requestedEnabled: Bool, previousIntent: Bool) -> Bool {
        requestedEnabled ? previousIntent : false
    }
}

struct RTCIncomingVideoAnswerPlan: Sendable, Equatable {
    let acceptedMode: String
    let startsVideoMedia: Bool
    let cameraEnabled: Bool
    let notice: String?

    static func resolve(
        requestedMode: String,
        cameraAvailable: Bool,
        cameraAuthorized: Bool
    ) -> RTCIncomingVideoAnswerPlan {
        let wantsVideo = requestedMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
        guard wantsVideo else {
            return RTCIncomingVideoAnswerPlan(
                acceptedMode: "audio",
                startsVideoMedia: false,
                cameraEnabled: false,
                notice: nil
            )
        }
        let cameraEnabled = cameraAvailable && cameraAuthorized
        let notice: String?
        if !cameraAvailable {
            notice = "摄像头暂不可用，已关闭摄像头继续视频通话"
        } else if !cameraAuthorized {
            notice = "摄像头权限未开启，已关闭摄像头继续视频通话"
        } else {
            notice = nil
        }
        return RTCIncomingVideoAnswerPlan(
            acceptedMode: "video",
            startsVideoMedia: true,
            cameraEnabled: cameraEnabled,
            notice: notice
        )
    }
}

struct RTCVideoConnectionGate: Sendable, Hashable {
    private(set) var peerConnectionConnected = false
    private(set) var remoteMediaTrackReady = false
    private(set) var didEmitConnected = false

    mutating func apply(_ event: RTCVideoMediaEvent) -> Bool {
        switch event {
        case .remoteAudioTrackReady, .remoteVideoTrackReady:
            remoteMediaTrackReady = true
        case .mediaConnected:
            peerConnectionConnected = true
        case .reconnecting, .serverSignalTerminal, .failed, .closed:
            peerConnectionConnected = false
        default:
            break
        }
        guard peerConnectionConnected, remoteMediaTrackReady, !didEmitConnected else { return false }
        didEmitConnected = true
        return true
    }
}

struct RTCVideoSignalRuntimeState: Sendable, Equatable {
    private(set) var rtcToken: String
    private(set) var generation = 0
    private(set) var cursor = ""
    private(set) var receivedMessageIDs: Set<String> = []

    init(rtcToken: String) {
        self.rtcToken = rtcToken
    }

    mutating func rebindToken(_ token: String) {
        rtcToken = token
        generation &+= 1
    }

    mutating func stageTokenRebind(_ token: String) {
        rtcToken = token
    }

    mutating func invalidatePolling() {
        generation &+= 1
    }

    func isCurrent(generation: Int) -> Bool {
        self.generation == generation
    }

    func hasProcessed(_ messageID: String) -> Bool {
        !messageID.isEmpty && receivedMessageIDs.contains(messageID)
    }

    mutating func markProcessed(_ messageID: String) {
        if !messageID.isEmpty {
            receivedMessageIDs.insert(messageID)
        }
    }

    mutating func commitCursor(_ cursor: String) {
        self.cursor = cursor
    }
}

struct RTCVideoInBandCredentialRefreshState: Sendable, Equatable {
    private(set) var isPending = false
    private(set) var requiredAcknowledgedCursor = ""

    mutating func request() {
        isPending = true
    }

    mutating func requireAcknowledgement(of cursor: String) {
        guard isPending else { return }
        let normalized = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            requiredAcknowledgedCursor = normalized
        }
    }

    mutating func completeAfterAcknowledgement(
        acknowledgedCursor: String,
        didAcknowledgeAndCommit: Bool
    ) -> Bool {
        let normalized = acknowledgedCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPending,
              didAcknowledgeAndCommit,
              !requiredAcknowledgedCursor.isEmpty,
              normalized == requiredAcknowledgedCursor else {
            return false
        }
        isPending = false
        requiredAcknowledgedCursor = ""
        return true
    }

    mutating func reset() {
        isPending = false
        requiredAcknowledgedCursor = ""
    }
}

enum RTCVideoCredentialRefreshAction: Sendable, Equatable {
    case refreshAndNegotiate
    case retryNegotiation
    case rejectOutOfBand

    static func resolve(inBandRequest: Bool, inBandRefreshPending: Bool) -> Self {
        if inBandRequest {
            return inBandRefreshPending ? .retryNegotiation : .refreshAndNegotiate
        }
        return inBandRefreshPending ? .rejectOutOfBand : .refreshAndNegotiate
    }
}

struct RTCVideoCredentialRefreshSnapshot: Sendable, Equatable {
    let sessionEpoch: Int
    let callID: String
    let roomID: String
    let rtcToken: String

    func matches(
        sessionEpoch: Int,
        callID: String,
        roomID: String,
        rtcToken: String
    ) -> Bool {
        self.sessionEpoch == sessionEpoch
            && self.callID == callID
            && self.roomID == roomID
            && self.rtcToken == rtcToken
    }
}

enum RTCVideoSignalBatchProcessor {
    @MainActor
    static func process(
        _ items: [RemoteRTCSignalItem],
        state: inout RTCVideoSignalRuntimeState,
        generation: Int,
        handle: @MainActor (RemoteRTCSignalItem) async throws -> Void
    ) async throws {
        for item in items {
            try Task.checkCancellation()
            guard state.isCurrent(generation: generation) else {
                throw CancellationError()
            }
            if state.hasProcessed(item.messageID) {
                continue
            }
            try await handle(item)
            guard state.isCurrent(generation: generation) else {
                throw CancellationError()
            }
            state.markProcessed(item.messageID)
        }
    }
}

enum RTCVideoSignalOutboxError: Error, Equatable {
    case capacityExceeded
}

struct RTCVideoSignalOutbox: Sendable, Equatable {
    let capacity: Int
    private(set) var pending: [RemoteRTCSignalEnvelope] = []

    init(capacity: Int = 512) {
        self.capacity = max(capacity, 1)
    }

    mutating func enqueue(_ envelope: RemoteRTCSignalEnvelope) throws {
        if pending.contains(where: { $0.messageID == envelope.messageID }) {
            return
        }
        if envelope.kind == .mediaState,
           let existingIndex = pending.firstIndex(where: { $0.kind == .mediaState }) {
            pending[existingIndex] = envelope
            return
        }
        if envelope.kind != .mediaState {
            // media_state is best-effort and its lower sequence becomes stale
            // once a later SDP/ICE envelope is sent. Discard it instead of
            // reordering sequence numbers or poisoning critical signaling.
            pending.removeAll { $0.kind == .mediaState }
        }
        if pending.count >= capacity {
            throw RTCVideoSignalOutboxError.capacityExceeded
        }
        pending.append(envelope)
    }

    mutating func markDelivered(messageID: String) {
        pending.removeAll { $0.messageID == messageID }
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
    }
}

enum RTCVideoCredentialSchedule {
    static func delay(
        refreshAfter: String,
        expiresAt: String,
        now: Date = Date()
    ) -> TimeInterval? {
        let formatter = ISO8601DateFormatter()
        if let refreshDate = formatter.date(from: refreshAfter) {
            return max(1, refreshDate.timeIntervalSince(now))
        }
        if let expiryDate = formatter.date(from: expiresAt) {
            return max(1, expiryDate.timeIntervalSince(now) - 300)
        }
        return nil
    }
}

enum RTCVideoICERestartAction: Equatable {
    case restartAndOffer
    case requestCallerRestart
}

enum RTCVideoICERestartPolicy {
    static func action(isCaller: Bool) -> RTCVideoICERestartAction {
        isCaller ? .restartAndOffer : .requestCallerRestart
    }
}

enum RTCQualityTokenScope {
    static let writeScope = "rtc:quality:write"

    static func hasWriteScope(_ token: String) -> Bool {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let payload = base64URLData(String(components[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let scopes = object["scopes"] as? [String] else {
            return false
        }
        return scopes.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == writeScope
        }
    }

    private static func base64URLData(_ raw: String) -> Data? {
        var normalized = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - normalized.count % 4) % 4
        normalized.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: normalized)
    }
}

struct RTCQualityStatRecord: Sendable, Equatable {
    let id: String
    let type: String
    let timestampUS: Double
    let selectedCandidatePairID: String?
    let localCandidateID: String?
    let remoteCandidateID: String?
    let candidateType: String?
    let protocolName: String?
    let relayProtocol: String?
    let candidateURL: String?
    let state: String?
    let selected: Bool?
    let nominated: Bool?
    let currentRoundTripTimeSeconds: Double?
    let availableOutgoingBitrateBPS: Double?
    let jitterSeconds: Double?
    let packetsLost: Int64?
    let packetsReceived: Int64?
    let bytesReceived: Int64?
    let bytesSent: Int64?
    let framesPerSecond: Double?
    let framesDropped: Int64?
    let concealedSamples: Int64?
    let totalSamplesReceived: Int64?
    let freezeCount: Int64?
    let kind: String?
    let mediaType: String?
    let codecID: String?
    let mimeType: String?
    let ssrc: String?
    let framesEncoded: Int64?
    let framesSent: Int64?
    let framesReceived: Int64?
    let framesDecoded: Int64?

    init(
        id: String,
        type: String,
        timestampUS: Double = 0,
        selectedCandidatePairID: String? = nil,
        localCandidateID: String? = nil,
        remoteCandidateID: String? = nil,
        candidateType: String? = nil,
        protocolName: String? = nil,
        relayProtocol: String? = nil,
        candidateURL: String? = nil,
        state: String? = nil,
        selected: Bool? = nil,
        nominated: Bool? = nil,
        currentRoundTripTimeSeconds: Double? = nil,
        availableOutgoingBitrateBPS: Double? = nil,
        jitterSeconds: Double? = nil,
        packetsLost: Int64? = nil,
        packetsReceived: Int64? = nil,
        bytesReceived: Int64? = nil,
        bytesSent: Int64? = nil,
        framesPerSecond: Double? = nil,
        framesDropped: Int64? = nil,
        concealedSamples: Int64? = nil,
        totalSamplesReceived: Int64? = nil,
        freezeCount: Int64? = nil,
        kind: String? = nil,
        mediaType: String? = nil,
        codecID: String? = nil,
        mimeType: String? = nil,
        ssrc: String? = nil,
        framesEncoded: Int64? = nil,
        framesSent: Int64? = nil,
        framesReceived: Int64? = nil,
        framesDecoded: Int64? = nil
    ) {
        self.id = id
        self.type = type
        self.timestampUS = timestampUS
        self.selectedCandidatePairID = selectedCandidatePairID
        self.localCandidateID = localCandidateID
        self.remoteCandidateID = remoteCandidateID
        self.candidateType = candidateType
        self.protocolName = protocolName
        self.relayProtocol = relayProtocol
        self.candidateURL = candidateURL
        self.state = state
        self.selected = selected
        self.nominated = nominated
        self.currentRoundTripTimeSeconds = currentRoundTripTimeSeconds
        self.availableOutgoingBitrateBPS = availableOutgoingBitrateBPS
        self.jitterSeconds = jitterSeconds
        self.packetsLost = packetsLost
        self.packetsReceived = packetsReceived
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.framesPerSecond = framesPerSecond
        self.framesDropped = framesDropped
        self.concealedSamples = concealedSamples
        self.totalSamplesReceived = totalSamplesReceived
        self.freezeCount = freezeCount
        self.kind = kind
        self.mediaType = mediaType
        self.codecID = codecID
        self.mimeType = mimeType
        self.ssrc = ssrc
        self.framesEncoded = framesEncoded
        self.framesSent = framesSent
        self.framesReceived = framesReceived
        self.framesDecoded = framesDecoded
    }
}

func rtcVideoFrameStatsSummary(_ records: [RTCQualityStatRecord]) -> String {
    let codecs = records.reduce(into: [String: String]()) { result, record in
        guard record.type.caseInsensitiveCompare("codec") == .orderedSame,
              !record.id.isEmpty,
              result[record.id] == nil else { return }
        result[record.id] = safeRTCStatLabel(record.mimeType)
    }
    func side(_ type: String) -> String {
        guard let record = records.first(where: {
            $0.type.caseInsensitiveCompare(type) == .orderedSame &&
                ($0.kind ?? $0.mediaType ?? "").caseInsensitiveCompare("video") == .orderedSame
        }) else { return "\(type)=absent" }
        let codecValue = codecs[record.codecID ?? ""] ?? ""
        let codec = codecValue.isEmpty ? "unknown" : codecValue
        let counters: String
        if type == "outbound-rtp" {
            counters = "encoded=\(record.framesEncoded ?? -1),sent=\(record.framesSent ?? -1),bytes=\(record.bytesSent ?? -1)"
        } else {
            counters = "received=\(record.framesReceived ?? -1),decoded=\(record.framesDecoded ?? -1),bytes=\(record.bytesReceived ?? -1)"
        }
        let ssrcValue = safeRTCStatLabel(record.ssrc)
        return "\(type)[\(counters),codec=\(codec),ssrc=\(ssrcValue.isEmpty ? "unknown" : ssrcValue)]"
    }
    return "video_frame_stats \(side("outbound-rtp")) \(side("inbound-rtp"))"
}

private func safeRTCStatLabel(_ value: String?) -> String {
    String((value ?? "").prefix(64).filter { character in
        character.isLetter || character.isNumber || "/-_+.".contains(character)
    })
}

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

struct RTCTurnRouteCollector: Sendable {
    private struct TransportState: Sendable {
        let number: Int
        var selectedPairID: String?
        var epoch: Int
    }
    let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var capability: RemoteRTCTurnRouteTelemetry?
    private var enabled = true
    private var states: [String: TransportState] = [:]

    init(capability: RemoteRTCTurnRouteTelemetry?) {
        self.capability = capability?.isSupported == true ? capability : nil
    }

    mutating func enableIfPreviouslyUnavailable(_ capability: RemoteRTCTurnRouteTelemetry?) {
        // Freeze a connection's directory, including through credential refresh.
        // Already queued values are immutable and never relabelled with a new map.
        enabled = capability?.isSupported == true
        if self.capability == nil, enabled { self.capability = capability }
        // A changed directory cannot relabel this PC. Resume after a new PC.
        if let capability, let original = self.capability,
           capability.mappingVersion != original.mappingVersion { enabled = false }
        if !enabled { invalidateSelections(except: []) }
    }

    mutating func disable() {
        enabled = false
        invalidateSelections(except: [])
    }

    mutating func observe(_ records: [RTCQualityStatRecord]) -> RTCTurnRouteObservation? {
        guard enabled, let capability else { return nil }
        var selectedPairs = Set<String>()
        let transports = records.filter { $0.type == "transport" }.sorted { $0.id < $1.id }.filter {
            guard let pairID = $0.selectedCandidatePairID, !pairID.isEmpty else { return true }
            return selectedPairs.insert(pairID).inserted
        }
        let identifiers = Set(transports.map(\.id))
        guard transports.count <= 8, identifiers.count == transports.count else {
            invalidateSelections(except: [])
            return nil
        }
        invalidateSelections(except: identifiers)
        if transports.isEmpty {
            // No synthetic stats ID consumes a slot in the real transport map.
            return RTCTurnRouteObservation(connectionID: connectionID, mappingVersion: capability.mappingVersion,
                transports: [.init(transportID: 1, routeEpoch: states.values.first(where: { $0.number == 1 })?.epoch ?? 1,
                    selectionBasis: "unavailable", localCandidateType: "unknown", remoteCandidateType: "unknown",
                    localRelayProtocol: "unknown", nodeID: nil, unknownReason: "selection_unavailable",
                    bytesSent: nil, bytesReceived: nil)])
        }
        var result: [RTCTurnRouteObservation.Transport] = []
        for transport in transports {
            let pairID = transport.selectedCandidatePairID.flatMap { $0.isEmpty ? nil : $0 }
            if states[transport.id] == nil {
                guard states.count < 8 else { return nil }
                states[transport.id] = TransportState(number: states.count + 1, selectedPairID: pairID, epoch: 1)
            }
            guard var state = states[transport.id] else { return nil }
            if state.selectedPairID != pairID {
                guard state.epoch < 10_000 else { return nil }
                state.epoch += 1
                state.selectedPairID = pairID
                states[transport.id] = state
            }
            let pair = pairID.flatMap { id in records.first { $0.id == id && $0.type == "candidate-pair" } }
            let local = pair.flatMap { pair in records.first { $0.id == pair.localCandidateID && $0.type == "local-candidate" } }
            let remote = pair.flatMap { pair in records.first { $0.id == pair.remoteCandidateID && $0.type == "remote-candidate" } }
            let localType = candidateType(local?.candidateType)
            let remoteType = candidateType(remote?.candidateType)
            let relayProtocol = localType == "relay" && ["udp", "tcp", "tls"].contains(local?.relayProtocol ?? "")
                ? local!.relayProtocol! : "unknown"
            let nodeID = localType == "relay" ? nodeID(for: local?.candidateURL, in: capability) : nil
            let reason: String
            if pairID == nil { reason = "selection_unavailable" }
            else if localType == "relay" { reason = nodeID == nil ? "mapping_unavailable" : "none" }
            else if pair == nil || localType == "unknown" || remoteType == "unknown" { reason = "candidate_unavailable" }
            else { reason = "none" }
            let sent = validCounter(pair?.bytesSent)
            let received = validCounter(pair?.bytesReceived)
            let hasCounters = sent != nil && received != nil
            result.append(.init(
                transportID: state.number, routeEpoch: state.epoch,
                selectionBasis: pairID == nil ? "unavailable" : "transport.selectedCandidatePairId",
                localCandidateType: localType, remoteCandidateType: remoteType,
                localRelayProtocol: relayProtocol, nodeID: nodeID, unknownReason: reason,
                bytesSent: hasCounters ? sent : nil, bytesReceived: hasCounters ? received : nil
            ))
        }
        return RTCTurnRouteObservation(connectionID: connectionID, mappingVersion: capability.mappingVersion, transports: result)
    }

    private mutating func invalidateSelections(except identifiers: Set<String>) {
        for id in Array(states.keys) where !identifiers.contains(id) {
            guard var state = states[id], state.selectedPairID != nil else { continue }
            state.selectedPairID = nil
            state.epoch = min(state.epoch + 1, 10_000)
            states[id] = state
        }
    }

    private func candidateType(_ value: String?) -> String {
        ["host", "srflx", "prflx", "relay"].contains(value ?? "") ? value! : "unknown"
    }

    private func validCounter(_ value: Int64?) -> Int64? {
        guard let value, value >= 0, value <= 9_007_199_254_740_991 else { return nil }
        return value
    }

    private func nodeID(for url: String?, in capability: RemoteRTCTurnRouteTelemetry) -> String? {
        guard let host = Self.turnHostname(url) else { return nil }
        let matches = Set(capability.nodes.filter { node in
            node.urls.contains { Self.turnHostname($0) == host }
        }.map(\.nodeID))
        return matches.count == 1 ? matches.first : nil
    }

    private static func turnHostname(_ value: String?) -> String? {
        guard let value, value.count <= 2048, let colon = value.firstIndex(of: ":"),
              ["turn", "turns"].contains(value[..<colon].lowercased()) else { return nil }
        let remainder = value[value.index(after: colon)...]
        guard let parts = URLComponents(string: "https://" + remainder),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path.isEmpty, let host = parts.host, !host.isEmpty else { return nil }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }
}

@MainActor
final class RTCQualitySequenceLedger {
    static let shared = RTCQualitySequenceLedger()
    private let defaults: UserDefaults
    private var storageAvailable = true

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func reserve(callKey: String) -> Int64? {
        // Persist only a scalar per opaque call/role hash. No in-memory history
        // or arbitrary lifetime call limit; directory/URLs remain memory-only.
        let hash = SHA256.hash(data: Data(callKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "rtc.quality.sequence.v1." + hash
        guard storageAvailable else { return nil }
        let stored = defaults.object(forKey: key)
        if let stored {
            guard let number = stored as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
                  stored is Int else { return nil }
        }
        let previous = stored as? Int ?? 0
        guard previous >= 0, previous < 10_000 else { return nil }
        defaults.set(previous + 1, forKey: key)
        // Commit the reservation before enqueue/send. A failed reservation is
        // skipped, so process/PC reconstruction cannot resend its sequence.
        guard defaults.synchronize() else { storageAvailable = false; return nil }
        return Int64(previous + 1)
    }
}

private struct RTCQualityCounterSnapshot: Sendable, Equatable {
    let timestampUS: Double
    let bytesReceived: Int64
    let bytesSent: Int64
    let packetsLost: Int64
    let packetsReceived: Int64
    let framesDropped: Int64
    let concealedSamples: Int64
    let totalSamplesReceived: Int64
    let freezeCount: Int64
}

struct RTCQualitySampleReducer: Sendable {
    private var previous: RTCQualityCounterSnapshot?

    mutating func reduce(
        records: [RTCQualityStatRecord],
        sampledAt: Date,
        sampleSeq: Int64
    ) -> RTCQualitySample? {
        let selectedPair = selectedCandidatePair(in: records)
        let localCandidate = selectedPair.flatMap { pair in
            records.first { $0.id == pair.localCandidateID && isCandidate($0.type) }
        }
        let remoteCandidate = selectedPair.flatMap { pair in
            records.first { $0.id == pair.remoteCandidateID && isCandidate($0.type) }
        }
        let route = connectionRoute(
            selectedPair: selectedPair,
            localCandidate: localCandidate,
            remoteCandidate: remoteCandidate
        )
        let candidateProtocol = protocolValue(localCandidate ?? remoteCandidate)
        let inbound = records.filter { normalizedType($0.type) == "inbound-rtp" }
        let outbound = records.filter { normalizedType($0.type) == "outbound-rtp" }
        let timestampUS = records.map(\.timestampUS).max() ?? sampledAt.timeIntervalSince1970 * 1_000_000
        let counters = RTCQualityCounterSnapshot(
            timestampUS: timestampUS,
            bytesReceived: positiveSum(inbound.compactMap(\.bytesReceived)),
            bytesSent: positiveSum(outbound.compactMap(\.bytesSent)),
            packetsLost: positiveSum(inbound.compactMap(\.packetsLost)),
            packetsReceived: positiveSum(inbound.compactMap(\.packetsReceived)),
            framesDropped: positiveSum(inbound.compactMap(\.framesDropped)),
            concealedSamples: positiveSum(inbound.compactMap(\.concealedSamples)),
            totalSamplesReceived: positiveSum(inbound.compactMap(\.totalSamplesReceived)),
            freezeCount: positiveSum(inbound.compactMap(\.freezeCount))
        )

        let rttMS = bounded(selectedPair?.currentRoundTripTimeSeconds.map { $0 * 1_000 }, maximum: 60_000)
        let jitterMS = bounded(inbound.compactMap(\.jitterSeconds).max().map { $0 * 1_000 }, maximum: 60_000)
        let availableOutgoingKbps = bounded(
            selectedPair?.availableOutgoingBitrateBPS.map { $0 / 1_000 },
            maximum: 10_000_000
        )
        let fps = bounded(
            (inbound + outbound).compactMap(\.framesPerSecond).max(),
            maximum: 240
        )
        let inboundKbps = bitrateKbps(
            currentBytes: counters.bytesReceived,
            previousBytes: previous?.bytesReceived,
            currentTimestampUS: counters.timestampUS,
            previousTimestampUS: previous?.timestampUS
        )
        let outboundKbps = bitrateKbps(
            currentBytes: counters.bytesSent,
            previousBytes: previous?.bytesSent,
            currentTimestampUS: counters.timestampUS,
            previousTimestampUS: previous?.timestampUS
        )
        let packetLossPct = ratioPercent(
            currentNumerator: counters.packetsLost,
            previousNumerator: previous?.packetsLost,
            currentDenominatorPart: counters.packetsReceived,
            previousDenominatorPart: previous?.packetsReceived
        )
        let audioConcealmentPct = ratioPercent(
            currentNumerator: counters.concealedSamples,
            previousNumerator: previous?.concealedSamples,
            currentDenominatorPart: counters.totalSamplesReceived - counters.concealedSamples,
            previousDenominatorPart: previous.map { $0.totalSamplesReceived - $0.concealedSamples }
        )
        let framesDropped = counterDelta(counters.framesDropped, previous?.framesDropped, maximum: 1_000_000_000)
        let freezeCount = counterDelta(counters.freezeCount, previous?.freezeCount, maximum: 1_000_000)
        previous = counters

        let hasMetric = [
            rttMS,
            jitterMS,
            packetLossPct,
            availableOutgoingKbps,
            inboundKbps,
            outboundKbps,
            fps,
            audioConcealmentPct
        ].contains { $0 != nil } || framesDropped != nil || freezeCount != nil
        guard hasMetric else { return nil }

        return RTCQualitySample(
            sampledAt: sampledAt,
            sampleSeq: sampleSeq,
            connectionRoute: route,
            candidateProtocol: candidateProtocol,
            rttMS: rttMS,
            jitterMS: jitterMS,
            packetLossPct: packetLossPct,
            availableOutgoingBitrateKbps: availableOutgoingKbps,
            inboundBitrateKbps: inboundKbps,
            outboundBitrateKbps: outboundKbps,
            framesPerSecond: fps,
            framesDropped: framesDropped,
            audioConcealmentPct: audioConcealmentPct,
            freezeCount: freezeCount
        )
    }

    private func selectedCandidatePair(in records: [RTCQualityStatRecord]) -> RTCQualityStatRecord? {
        let selectedID = records
            .first { normalizedType($0.type) == "transport" }?
            .selectedCandidatePairID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedID, !selectedID.isEmpty,
           let pair = records.first(where: {
               $0.id == selectedID && normalizedType($0.type) == "candidate-pair"
           }) {
            return pair
        }
        return records.first {
            normalizedType($0.type) == "candidate-pair"
                && ($0.selected == true || ($0.nominated == true && normalized($0.state) == "succeeded"))
        }
    }

    private func connectionRoute(
        selectedPair: RTCQualityStatRecord?,
        localCandidate: RTCQualityStatRecord?,
        remoteCandidate: RTCQualityStatRecord?
    ) -> String {
        guard selectedPair != nil, localCandidate != nil || remoteCandidate != nil else { return "unknown" }
        let types = [localCandidate?.candidateType, remoteCandidate?.candidateType]
            .compactMap { $0.map(normalized) }
        if types.contains("relay") {
            return "relay"
        }
        return types.isEmpty ? "unknown" : "direct"
    }

    private func protocolValue(_ candidate: RTCQualityStatRecord?) -> String {
        let relay = normalized(candidate?.relayProtocol)
        if ["udp", "tcp", "tls"].contains(relay) { return relay }
        let transport = normalized(candidate?.protocolName)
        return ["udp", "tcp", "tls"].contains(transport) ? transport : "unknown"
    }

    private func bitrateKbps(
        currentBytes: Int64,
        previousBytes: Int64?,
        currentTimestampUS: Double,
        previousTimestampUS: Double?
    ) -> Double? {
        guard let previousBytes,
              let previousTimestampUS,
              currentBytes >= previousBytes,
              currentTimestampUS > previousTimestampUS else {
            return nil
        }
        let seconds = (currentTimestampUS - previousTimestampUS) / 1_000_000
        guard seconds > 0 else { return nil }
        return bounded(Double(currentBytes - previousBytes) * 8 / seconds / 1_000, maximum: 10_000_000)
    }

    private func ratioPercent(
        currentNumerator: Int64,
        previousNumerator: Int64?,
        currentDenominatorPart: Int64,
        previousDenominatorPart: Int64?
    ) -> Double? {
        let numerator: Int64
        let denominatorPart: Int64
        if let previousNumerator, let previousDenominatorPart,
           currentNumerator >= previousNumerator,
           currentDenominatorPart >= previousDenominatorPart {
            numerator = currentNumerator - previousNumerator
            denominatorPart = currentDenominatorPart - previousDenominatorPart
        } else {
            numerator = currentNumerator
            denominatorPart = currentDenominatorPart
        }
        let total = numerator + denominatorPart
        guard numerator >= 0, denominatorPart >= 0, total > 0 else { return nil }
        return bounded(Double(numerator) / Double(total) * 100, maximum: 100)
    }

    private func counterDelta(_ current: Int64, _ previous: Int64?, maximum: Int64) -> Int64? {
        guard let previous, current >= previous else { return nil }
        return min(max(current - previous, 0), maximum)
    }

    private func positiveSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { partial, value in
            let positive = max(value, 0)
            return partial > Int64.max - positive ? Int64.max : partial + positive
        }
    }

    private func bounded(_ value: Double?, maximum: Double) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, maximum)
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func normalizedType(_ value: String) -> String {
        normalized(value).replacingOccurrences(of: "_", with: "-")
    }

    private func isCandidate(_ type: String) -> Bool {
        let value = normalizedType(type)
        return value == "local-candidate" || value == "remote-candidate"
    }
}

enum RTCQualityUploadFailurePolicy {
    static func isTerminal(_ error: Error) -> Bool {
        if error is RTCCredentialError || error is CancellationError { return true }
        if let signal = error as? RTCVideoSignalHTTPError {
            return [404, 409, 422].contains(signal.statusCode)
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .businessForbidden, .forbidden, .unauthorized:
                return true
            default:
                break
            }
        }
        return false
    }

    static func retryDelaySeconds(attempt: Int) -> UInt64 {
        let exponent = min(max(attempt - 1, 0), 3)
        return UInt64(min(5 * (1 << exponent), 40))
    }
}

typealias RTCQualityStatsProvider = @MainActor () async -> [RTCQualityStatRecord]
typealias RTCQualityReporter = @MainActor (_ samples: [RTCQualitySample], _ rtcToken: String) async throws -> Void

@MainActor
final class RTCQualityTelemetrySession {
    static let sampleIntervalNanoseconds: UInt64 = 10_000_000_000
    static let batchSize = 3
    static let maximumPendingSamples = 30
    static let maximumRetryAttempts = 4

    private var rtcToken: String
    private let statsProvider: RTCQualityStatsProvider
    private let reporter: RTCQualityReporter
    private let now: () -> Date
    private var reducer = RTCQualitySampleReducer()
    private var nextSampleSeq: Int64 = 1
    private var routeCollector: RTCTurnRouteCollector
    private let sequenceProvider: (() -> Int64?)?
    private var captureInProgress = false
    private var pending: [RTCQualitySample] = []
    private var timerTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var stopped = false

    init(
        rtcToken: String,
        statsProvider: @escaping RTCQualityStatsProvider,
        reporter: @escaping RTCQualityReporter,
        turnRouteTelemetry: RemoteRTCTurnRouteTelemetry? = nil,
        sequenceProvider: (() -> Int64?)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.rtcToken = rtcToken
        self.statsProvider = statsProvider
        self.reporter = reporter
        self.now = now
        self.routeCollector = RTCTurnRouteCollector(capability: turnRouteTelemetry)
        self.sequenceProvider = sequenceProvider
    }

    func start() {
        guard timerTask == nil,
              RTCQualityTokenScope.hasWriteScope(rtcToken) else {
            return
        }
        timerTask = Task { @MainActor [weak self] in
            await self?.captureAndQueue(forceUpload: false, allowStopped: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.sampleIntervalNanoseconds)
                } catch {
                    break
                }
                guard let self, !self.stopped else { break }
                await self.captureAndQueue(forceUpload: false, allowStopped: false)
            }
        }
    }

    func updateRouteCapability(_ capability: RemoteRTCTurnRouteTelemetry?) {
        routeCollector.enableIfPreviouslyUnavailable(capability)
    }

    func updateToken(_ token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RTCQualityTokenScope.hasWriteScope(normalized) else {
            stopped = true
            timerTask?.cancel()
            timerTask = nil
            pending.removeAll(keepingCapacity: false)
            return
        }
        rtcToken = normalized
    }

    func applicationDidEnterBackground() async {
        await captureAndQueue(forceUpload: true, allowStopped: false)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        timerTask?.cancel()
        timerTask = nil
        await captureAndQueue(forceUpload: true, allowStopped: true)
        scheduleUpload()
    }

    func captureForTesting(forceUpload: Bool) async {
        await captureAndQueue(forceUpload: forceUpload, allowStopped: false)
    }

    var pendingCountForTesting: Int { pending.count }
    var nextSequenceForTesting: Int64 { nextSampleSeq }
    var isStoppedForTesting: Bool { stopped }

    private func captureAndQueue(forceUpload: Bool, allowStopped: Bool) async {
        guard !captureInProgress, allowStopped || !stopped,
              RTCQualityTokenScope.hasWriteScope(rtcToken),
              pending.count < Self.maximumPendingSamples,
              nextSampleSeq <= 10_000 else {
            return
        }
        captureInProgress = true
        defer { captureInProgress = false }
        let records = await statsProvider()
        guard allowStopped || !stopped else { return }
        let observation = routeCollector.observe(records)
        guard let sequence = sequenceProvider?() ?? (sequenceProvider == nil ? nextSampleSeq : nil) else {
            print("[RTCQuality] coverage_gap=sequence_unavailable")
            stopped = true
            timerTask?.cancel()
            timerTask = nil
            scheduleUpload()
            return
        }
        if var sample = reducer.reduce(records: records, sampledAt: now(), sampleSeq: sequence) {
            sample.routeObservation = observation
            pending.append(sample)
        }
        nextSampleSeq = sequence + 1
        if forceUpload || pending.count >= Self.batchSize {
            scheduleUpload()
        }
    }

    private func scheduleUpload() {
        guard uploadTask == nil,
              !pending.isEmpty,
              RTCQualityTokenScope.hasWriteScope(rtcToken) else {
            return
        }
        // Three samples remain comfortably under the existing 64 KiB API
        // limit even with eight transports; drain a backlog in bounded batches.
        let batch = Array(pending.prefix(Self.batchSize))
        let batchSequences = Set(batch.map(\.sampleSeq))
        let token = rtcToken
        uploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.reporter(batch, token)
                self.pending.removeAll { batchSequences.contains($0.sampleSeq) }
                self.retryAttempt = 0
                self.uploadTask = nil
                if !self.pending.isEmpty {
                    self.scheduleUpload()
                }
            } catch {
                self.uploadTask = nil
                if let signal = error as? RTCVideoSignalHTTPError,
                   ((signal.statusCode == 400 && signal.code == "bad_json") ||
                    (signal.statusCode == 422 && signal.code == "rtc_quality_route_unsupported")),
                   batch.contains(where: { $0.routeObservation != nil }) {
                    self.routeCollector.disable()
                    // Drop unaccepted extension samples as a coverage gap. Never
                    // strip a queued value and reuse its sequence with new bytes.
                    self.pending.removeAll { $0.routeObservation != nil }
                    self.retryAttempt = 0
                    print("[RTCQuality] coverage_gap=route_unsupported")
                    if !self.pending.isEmpty { self.scheduleUpload() }
                    return
                }
                if let signal = error as? RTCVideoSignalHTTPError,
                   signal.statusCode == 409, signal.code == "rtc_quality_node_mapping_stale" {
                    // Preserve the original bounded batch. Never relabel or resend
                    // its sequence with different content after a directory change.
                    self.stopped = true
                    self.timerTask?.cancel()
                    self.timerTask = nil
                    print("[RTCQuality] coverage_gap=node_mapping_stale")
                    return
                }
                if RTCQualityUploadFailurePolicy.isTerminal(error) {
                    self.pending.removeAll(keepingCapacity: false)
                    self.stopped = true
                    self.timerTask?.cancel()
                    self.timerTask = nil
                    return
                }
                self.retryAttempt += 1
                guard self.retryAttempt <= Self.maximumRetryAttempts else {
                    self.pending.removeAll(keepingCapacity: false)
                    return
                }
                let delay = RTCQualityUploadFailurePolicy.retryDelaySeconds(attempt: self.retryAttempt)
                self.uploadTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    self.uploadTask = nil
                    self.scheduleUpload()
                }
            }
        }
    }
}

typealias RTCVideoSignalSender = @MainActor (_ envelope: RemoteRTCSignalEnvelope, _ rtcToken: String) async throws -> RemoteRTCSignalPostResult
typealias RTCVideoSignalPoller = @MainActor (_ cursor: String, _ rtcToken: String) async throws -> RemoteRTCSignalItemsData
typealias RTCVideoSignalAcknowledger = @MainActor (_ cursor: String, _ rtcToken: String) async throws -> Void
typealias RTCIceCredentialRefresher = @MainActor (_ rtcToken: String) async throws -> RemoteRTCIceCredentials

struct VideoMediaSessionContext {
    let callID: String
    let roomID: String
    var rtcToken: String
    let direction: String
    let localUID: String
    let localDeviceID: String
    let peerUID: String
    let peerDeviceID: String
    let iceServers: [RemoteRTCIceServer]
    let iceCredentialExpiresAt: String
    let iceCredentialRefreshAfter: String
    var turnRouteTelemetry: RemoteRTCTurnRouteTelemetry? = nil
    var icePolicy: RTCIcePolicy = .legacy
    let postSignal: RTCVideoSignalSender
    let pollSignals: RTCVideoSignalPoller
    let acknowledgeSignals: RTCVideoSignalAcknowledger
    let refreshIceCredentials: RTCIceCredentialRefresher
    let reportQuality: RTCQualityReporter

    var isCaller: Bool {
        let value = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.contains("呼出") || value.contains("caller") || value.contains("outgoing")
    }

    var isPolite: Bool { !isCaller }
}

@MainActor
protocol VideoMediaClient: AnyObject {
    var isAvailable: Bool { get }
    var cameraAvailable: Bool { get }

    func preparePreview(preferFrontCamera: Bool) async throws
    func start(context: VideoMediaSessionContext, cameraEnabled: Bool) async throws -> AsyncStream<RTCVideoMediaEvent>
    func setMuted(_ isMuted: Bool) async
    func setSpeakerEnabled(_ isEnabled: Bool) async throws
    func setCameraEnabled(_ isEnabled: Bool) async throws
    func switchCamera() async throws
    func downgradeToAudio() async throws
    func applicationDidEnterBackground() async
    func applicationWillEnterForeground() async throws
    func reconcileAudioSessionAfterSystemEvent() async throws
    func stop(reason: String) async
}

@MainActor
final class NoopVideoMediaClient: VideoMediaClient {
    var isAvailable: Bool { false }
    var cameraAvailable: Bool { false }

    func preparePreview(preferFrontCamera: Bool) async throws {
        throw IMAPIError.server("当前设备不支持视频通话")
    }

    func start(context: VideoMediaSessionContext, cameraEnabled: Bool) async throws -> AsyncStream<RTCVideoMediaEvent> {
        throw IMAPIError.server("当前设备不支持视频通话")
    }

    func setMuted(_ isMuted: Bool) async {}
    func setSpeakerEnabled(_ isEnabled: Bool) async throws {
        throw IMAPIError.server("当前设备不支持视频通话音频路由")
    }
    func setCameraEnabled(_ isEnabled: Bool) async throws {}
    func switchCamera() async throws {}
    func downgradeToAudio() async throws {}
    func applicationDidEnterBackground() async {}
    func applicationWillEnterForeground() async throws {}
    func reconcileAudioSessionAfterSystemEvent() async throws {}
    func stop(reason: String) async {}
}

#if canImport(WebRTC)
@MainActor
final class RTCVideoRenderRegistry: ObservableObject {
    static let shared = RTCVideoRenderRegistry()

    @Published private(set) var localRevision = 0
    @Published private(set) var remoteRevision = 0

    private var localTrack: RTCVideoTrack?
    private var remoteTrack: RTCVideoTrack?
    private var localRenderers: [ObjectIdentifier: RTCVideoRenderer] = [:]
    private var remoteRenderers: [ObjectIdentifier: RTCVideoRenderer] = [:]

    func setLocalTrack(_ track: RTCVideoTrack?) {
        if let old = localTrack {
            localRenderers.values.forEach { old.remove($0) }
        }
        localTrack = track
        if let track {
            localRenderers.values.forEach { track.add($0) }
        }
        localRevision &+= 1
    }

    func setRemoteTrack(_ track: RTCVideoTrack?) {
        if let old = remoteTrack {
            remoteRenderers.values.forEach { old.remove($0) }
        }
        remoteTrack = track
        if let track {
            remoteRenderers.values.forEach { track.add($0) }
        }
        remoteRevision &+= 1
    }

    func attach(_ renderer: RTCVideoRenderer, local: Bool) {
        let key = ObjectIdentifier(renderer as AnyObject)
        if local {
            localRenderers[key] = renderer
            localTrack?.add(renderer)
        } else {
            remoteRenderers[key] = renderer
            remoteTrack?.add(renderer)
        }
    }

    func detach(_ renderer: RTCVideoRenderer, local: Bool) {
        let key = ObjectIdentifier(renderer as AnyObject)
        if local {
            localTrack?.remove(renderer)
            localRenderers.removeValue(forKey: key)
        } else {
            remoteTrack?.remove(renderer)
            remoteRenderers.removeValue(forKey: key)
        }
    }

    func clear() {
        setLocalTrack(nil)
        setRemoteTrack(nil)
    }
}

private final class RTCVideoFirstFrameObserver: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var observed = false
    private let onFirstFrame: (Int, Int, Int) -> Void

    init(onFirstFrame: @escaping (Int, Int, Int) -> Void) {
        self.onFirstFrame = onFirstFrame
    }

    func setSize(_ size: CGSize) {}

    func reset() {
        lock.lock()
        observed = false
        lock.unlock()
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        guard !observed else {
            lock.unlock()
            return
        }
        observed = true
        lock.unlock()
        onFirstFrame(Int(frame.width), Int(frame.height), Int(frame.rotation.rawValue))
    }
}

struct RTCVideoRendererView: UIViewRepresentable {
    let local: Bool
    var mirrored = false
    var onVideoSizeChanged: ((CGSize) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(local: local, onVideoSizeChanged: onVideoSizeChanged)
    }

    func makeUIView(context: Context) -> RTCVideoRendererContainer {
        let container = RTCVideoRendererContainer()
        container.renderer.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        context.coordinator.renderer = container.renderer
        container.renderer.delegate = context.coordinator
        RTCVideoRenderRegistry.shared.attach(container.renderer, local: local)
        return container
    }

    func updateUIView(_ uiView: RTCVideoRendererContainer, context: Context) {
        context.coordinator.onVideoSizeChanged = onVideoSizeChanged
        uiView.renderer.videoContentMode = .scaleAspectFit
        uiView.renderer.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    static func dismantleUIView(_ uiView: RTCVideoRendererContainer, coordinator: Coordinator) {
        coordinator.active = false
        uiView.renderer.delegate = nil
        RTCVideoRenderRegistry.shared.detach(uiView.renderer, local: coordinator.local)
    }

    @MainActor
    final class Coordinator: NSObject, RTCVideoViewDelegate {
        let local: Bool
        weak var renderer: RTCMTLVideoView?
        var active = true
        var onVideoSizeChanged: ((CGSize) -> Void)?
        private var lastSize = CGSize.zero

        init(local: Bool, onVideoSizeChanged: ((CGSize) -> Void)?) {
            self.local = local
            self.onVideoSizeChanged = onVideoSizeChanged
        }

        nonisolated func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            // Copy identity at the delegate boundary; the non-Sendable renderer
            // must not cross into the main actor with the callback.
            let rendererID = ObjectIdentifier(videoView as AnyObject)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active,
                      self.renderer.map(ObjectIdentifier.init) == rendererID,
                      size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0,
                      size != self.lastSize else { return }
                self.lastSize = size
                self.onVideoSizeChanged?(size)
            }
        }
    }
}

// SwiftUI owns the viewport; decoded frame dimensions must never become its
// intrinsic layout size. RTCMTLVideoView fits the rotated frame inside this box.
final class RTCVideoRendererContainer: UIView {
    let renderer = RTCMTLVideoView(frame: .zero)

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        renderer.backgroundColor = .black
        renderer.videoContentMode = .scaleAspectFit
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(renderer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Changing bounds/center is safe while the local camera is mirrored.
        renderer.bounds = CGRect(origin: .zero, size: bounds.size)
        renderer.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

@MainActor
final class WebRTCVideoMediaClient: NSObject, VideoMediaClient {
    private let factory: RTCPeerConnectionFactory
    private var currentContext: VideoMediaSessionContext?
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoSource: RTCVideoSource?
    private var localVideoTrack: RTCVideoTrack?
    private var remoteAudioTracks: [RTCAudioTrack] = []
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteFirstFrameObserver: RTCVideoFirstFrameObserver?
    private var capturer: RTCCameraVideoCapturer?
    private var selectedPosition: AVCaptureDevice.Position = .front
    private var cameraEnabledIntent = true
    private var isCapturing = false
    private var isApplicationBackgrounded = false
    private var activeMediaMode = "video"
    private var signalPollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var credentialRefreshTask: Task<Void, Never>?
    private var mediaReadinessTask: Task<Void, Never>?
    private var mediaReadinessGeneration = 0
    private var qualityTelemetrySession: RTCQualityTelemetrySession?
    private var eventContinuation: AsyncStream<RTCVideoMediaEvent>.Continuation?
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var remoteCandidateKeys: Set<String> = []
    private var signalState = RTCVideoSignalRuntimeState(rtcToken: "")
    private var inBandCredentialRefresh = RTCVideoInBandCredentialRefreshState()
    private var signalOutbox = RTCVideoSignalOutbox()
    private var isFlushingSignalOutbox = false
    private var refreshingCredentialSessionEpoch: Int?
    private var sessionEpoch = 0
    private var isClosingCurrentSession = false
    private var sequence = 0
    private var negotiationID = "neg-\(UUID().uuidString.lowercased())"
    private var makingOffer = false
    private var ignoreOffer = false
    private var isSettingRemoteAnswerPending = false
    private var iceConnected = false
    private var remoteAudioTrackReady = false
    private var remoteAudioRTPReady = false
    private var remoteVideoFrameReady = false
    private var remoteCameraPausedByContract = false
    private var awaitingMediaRecovery = false
    private var lastInboundAudioBytes: Int64 = 0
    private var lastInboundAudioPackets: Int64 = 0
    private var lastInboundVideoBytes: Int64 = 0
    private var lastInboundVideoPackets: Int64 = 0
    private var lastInboundVideoFrames: Int64 = 0
    private var connectedEmitted = false
    private var currentDebugID = ""

    override init() {
        _ = WebRTCRuntime.isReady
        factory = RTCPeerConnectionFactory()
        super.init()
    }

    var isAvailable: Bool { WebRTCRuntime.isReady }

    var cameraAvailable: Bool {
        !RTCCameraVideoCapturer.captureDevices().isEmpty
    }

    func preparePreview(preferFrontCamera: Bool) async throws {
        guard isAvailable else { throw IMAPIError.server("当前设备不支持视频通话") }
        selectedPosition = preferFrontCamera ? .front : .back
        try createLocalVideoTrackIfNeeded()
        cameraEnabledIntent = true
        try await startCaptureIfNeeded()
        emit(.previewReady)
    }

    func start(context: VideoMediaSessionContext, cameraEnabled: Bool) async throws -> AsyncStream<RTCVideoMediaEvent> {
        if let existing = currentContext, existing.callID == context.callID {
            try existing.icePolicy.validateReplacement(context.icePolicy)
        }
        // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：不再因 relay policy 在启动前强制校验 TURN
        // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束
        await closeCurrent(reason: "restart", sendBye: false, finishStream: true, releasePreview: false)
        currentDebugID = Self.shortStableHash(context.callID)
        guard !context.callID.isEmpty, !context.roomID.isEmpty, !context.rtcToken.isEmpty else {
            throw IMAPIError.server("视频房间信息不完整")
        }
        guard !context.localDeviceID.isEmpty, !context.peerUID.isEmpty, !context.peerDeviceID.isEmpty else {
            throw IMAPIError.server("视频设备信息不完整")
        }
        let stream = AsyncStream<RTCVideoMediaEvent> { continuation in
            eventContinuation = continuation
        }
        currentContext = context
        sessionEpoch &+= 1
        signalState = RTCVideoSignalRuntimeState(rtcToken: context.rtcToken)
        inBandCredentialRefresh.reset()
        signalOutbox = RTCVideoSignalOutbox()
        negotiationID = "neg-\(UUID().uuidString.lowercased())"
        sequence = 0
        cameraEnabledIntent = cameraEnabled
        activeMediaMode = "video"
        iceConnected = false
        remoteAudioTrackReady = false
        remoteAudioRTPReady = false
        remoteVideoFrameReady = false
        remoteCameraPausedByContract = false
        awaitingMediaRecovery = false
        lastInboundAudioBytes = 0
        lastInboundAudioPackets = 0
        lastInboundVideoBytes = 0
        lastInboundVideoPackets = 0
        lastInboundVideoFrames = 0
        connectedEmitted = false

        do {
            videoDebug(
                "start role=\(context.isCaller ? "caller" : "callee") localDeviceHash=\(Self.shortStableHash(context.localDeviceID)) peerDeviceHash=\(Self.shortStableHash(context.peerDeviceID)) iceServers=\(context.iceServers.count) cameraIntent=\(cameraEnabled)"
            )
            try configureAudioSession()
            try createPeerConnection(context: context)
            if RTCQualityTokenScope.hasWriteScope(context.rtcToken), let connection = peerConnection {
                qualityTelemetrySession = RTCQualityTelemetrySession(
                    rtcToken: context.rtcToken,
                    statsProvider: { [weak self, weak connection] in
                        guard let self, let connection else { return [] }
                        return await self.qualityStatRecords(for: connection)
                    },
                    reporter: context.reportQuality,
                    turnRouteTelemetry: context.turnRouteTelemetry,
                    sequenceProvider: {
                        RTCQualitySequenceLedger.shared.reserve(callKey: "\(context.roomID)|\(context.callID)|\(context.localUID)|\(context.isCaller)")
                    }
                )
            } else {
                qualityTelemetrySession = nil
            }
            try createLocalAudioTrack(context: context)
            try createLocalVideoTrackIfNeeded()
            try addLocalVideoTrack(context: context)
            let shouldCapture = RTCVideoCapturePolicy.shouldCapture(
                cameraEnabledIntent: cameraEnabled,
                isApplicationBackgrounded: isApplicationBackgrounded
            )
            var cameraUnavailableAtStart = false
            if shouldCapture {
                do {
                    try await startCaptureIfNeeded()
                } catch {
                    cameraEnabledIntent = false
                    localVideoTrack?.isEnabled = false
                    await stopCaptureIfNeeded()
                    cameraUnavailableAtStart = true
                }
            } else {
                await stopCaptureIfNeeded()
                localVideoTrack?.isEnabled = false
            }
            startSignalPolling(context: context)
            scheduleCredentialRefresh(
                refreshAfter: context.iceCredentialRefreshAfter,
                expiresAt: context.iceCredentialExpiresAt
            )
            if context.isCaller {
                try await negotiate(iceRestart: false)
            }
            if cameraUnavailableAtStart || !shouldCapture {
                emit(cameraUnavailableAtStart ? .cameraUnavailable : .cameraPaused)
                try? await sendSignal(
                    kind: .mediaState,
                    data: RTCVideoMediaStatePayload.make(
                        cameraEnabled: false,
                        mediaMode: "video"
                    )
                )
            }
            return stream
        } catch {
            await closeCurrent(reason: "start_failed", sendBye: false, finishStream: true, releasePreview: true)
            throw error
        }
    }

    func setMuted(_ isMuted: Bool) async {
        localAudioTrack?.isEnabled = !isMuted
    }

    func setSpeakerEnabled(_ isEnabled: Bool) async throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let options: AVAudioSession.CategoryOptions = isEnabled
            ? [.allowBluetoothHFP, .defaultToSpeaker]
            : [.allowBluetoothHFP]
        try session.setCategory(.playAndRecord, with: options)
        try session.setMode(.videoChat)
        try session.setActive(true)
        session.isAudioEnabled = true
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(isEnabled ? .speaker : .none)
    }

    func setCameraEnabled(_ isEnabled: Bool) async throws {
        let previousIntent = cameraEnabledIntent
        cameraEnabledIntent = isEnabled
        activeMediaMode = "video"
        guard capturer != nil, localVideoTrack != nil else { return }
        guard !isApplicationBackgrounded else {
            localVideoTrack?.isEnabled = false
            return
        }
        do {
            if isEnabled {
                try await startCaptureIfNeeded()
                localVideoTrack?.isEnabled = true
                emit(.cameraResumed)
            } else {
                localVideoTrack?.isEnabled = false
                await stopCaptureIfNeeded()
                emit(.cameraPaused)
            }
            try await sendSignal(
                kind: .mediaState,
                data: RTCVideoMediaStatePayload.make(
                    cameraEnabled: isEnabled,
                    mediaMode: "video"
                )
            )
        } catch {
            let resolvedIntent = RTCVideoCameraFailurePolicy.resolvedIntent(
                requestedEnabled: isEnabled,
                previousIntent: previousIntent
            )
            cameraEnabledIntent = resolvedIntent
            if resolvedIntent {
                try? await startCaptureIfNeeded()
                localVideoTrack?.isEnabled = isCapturing
            } else {
                localVideoTrack?.isEnabled = false
                await stopCaptureIfNeeded()
            }
            throw error
        }
    }

    func switchCamera() async throws {
        guard cameraAvailable else { throw IMAPIError.server("当前设备没有可切换的摄像头") }
        emit(.cameraSwitching)
        let previousPosition = selectedPosition
        selectedPosition = previousPosition == .front ? .back : .front
        guard capturer != nil, localVideoTrack != nil else {
            emit(.cameraSwitched)
            return
        }
        await stopCaptureIfNeeded()
        do {
            if cameraEnabledIntent, !isApplicationBackgrounded {
                try await startCaptureIfNeeded()
            }
            emit(.cameraSwitched)
        } catch {
            selectedPosition = previousPosition
            if cameraEnabledIntent, !isApplicationBackgrounded {
                try? await startCaptureIfNeeded()
            }
            emit(.cameraUnavailable)
            throw error
        }
    }

    func downgradeToAudio() async throws {
        activeMediaMode = "audio"
        cameraEnabledIntent = false
        localVideoTrack?.isEnabled = false
        await stopCaptureIfNeeded()
        emit(.cameraPaused)
        maybeEmitConnected()
        try await sendSignal(
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(
                cameraEnabled: false,
                microphoneEnabled: localAudioTrack?.isEnabled,
                mediaMode: "audio"
            )
        )
    }

    func applicationDidEnterBackground() async {
        isApplicationBackgrounded = true
        localVideoTrack?.isEnabled = false
        await stopCaptureIfNeeded()
        emit(.cameraPaused)
        try? await sendSignal(
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(
                cameraEnabled: false,
                mediaMode: activeMediaMode
            )
        )
        await qualityTelemetrySession?.applicationDidEnterBackground()
    }

    func applicationWillEnterForeground() async throws {
        isApplicationBackgrounded = false
        let shouldResumeVideo = activeMediaMode == "video" && cameraEnabledIntent
        if shouldResumeVideo {
            try await startCaptureIfNeeded()
            localVideoTrack?.isEnabled = true
            emit(.cameraResumed)
        }
        try await sendSignal(
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(
                cameraEnabled: shouldResumeVideo,
                mediaMode: activeMediaMode
            )
        )
    }

    func reconcileAudioSessionAfterSystemEvent() async throws {
        try configureAudioSession()
    }

    func stop(reason: String) async {
        await closeCurrent(reason: reason, sendBye: true, finishStream: true, releasePreview: true)
    }

    private func configureAudioSession() throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.setCategory(.playAndRecord, with: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setMode(.videoChat)
        // JHT_MOD_BEGIN RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改开始：通话音频低延迟偏好，不支持时不阻断通话
        let avSession = AVAudioSession.sharedInstance()
        try? avSession.setPreferredSampleRate(48_000)
        try? avSession.setPreferredIOBufferDuration(0.01)
        // JHT_MOD_END RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改结束
        try session.setActive(true)
        session.isAudioEnabled = true
    }

    private func createPeerConnection(context: VideoMediaSessionContext) throws {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        // JHT_MOD_BEGIN RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改开始：预热少量 ICE candidate，缩短初始连通等待
        configuration.iceCandidatePoolSize = 2
        // JHT_MOD_END RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改结束
        // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：取消 iOS 强制中继，允许 host/srflx/relay 共同参与 ICE
        configuration.iceTransportPolicy = .all
        // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束
        configuration.iceServers = makeIceServers(context.iceServers)
        guard !configuration.iceServers.isEmpty else {
            throw IMAPIError.server("视频 ICE 配置缺失")
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw IMAPIError.server("视频连接初始化失败")
        }
        peerConnection = connection
    }

    private func makeIceServers(_ servers: [RemoteRTCIceServer]) -> [RTCIceServer] {
        servers.compactMap { server in
            let urls = server.urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: server.username, credential: server.credential)
        }
    }

    private func createLocalAudioTrack(context: VideoMediaSessionContext) throws {
        guard let peerConnection else { throw IMAPIError.server("视频连接未就绪") }
        let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "audio-\(context.callID)")
        track.isEnabled = true
        guard peerConnection.add(track, streamIds: ["video-\(context.callID)"]) != nil else {
            throw IMAPIError.server("麦克风轨道创建失败")
        }
        localAudioTrack = track
        emit(.localTrackReady)
    }

    private func createLocalVideoTrackIfNeeded() throws {
        guard localVideoTrack == nil else { return }
        let source = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "video-\(UUID().uuidString)")
        track.isEnabled = true
        localVideoSource = source
        localVideoTrack = track
        self.capturer = capturer
        RTCVideoRenderRegistry.shared.setLocalTrack(track)
    }

    private func addLocalVideoTrack(context: VideoMediaSessionContext) throws {
        guard let peerConnection, let localVideoTrack else { throw IMAPIError.server("摄像头轨道未就绪") }
        guard peerConnection.add(localVideoTrack, streamIds: ["video-\(context.callID)"]) != nil else {
            throw IMAPIError.server("摄像头轨道创建失败")
        }
    }

    private func startCaptureIfNeeded() async throws {
        guard !isCapturing else { return }
        guard let capturer else { throw IMAPIError.server("摄像头未就绪") }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard !devices.isEmpty else { throw IMAPIError.server("当前设备没有可用摄像头") }
        let device = devices.first(where: { $0.position == selectedPosition }) ?? devices[0]
        selectedPosition = device.position
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats
            .filter({
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return size.width <= 1280 && size.height <= 720
            })
            .max(by: {
                let lhs = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let rhs = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return lhs.width * lhs.height < rhs.width * rhs.height
            }) ?? formats.first else {
            throw IMAPIError.server("摄像头格式不可用")
        }
        let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 24
        let fps = min(30, max(15, Int(maxFPS.rounded(.down))))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            capturer.startCapture(with: device, format: format, fps: fps) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        isCapturing = true
        localVideoTrack?.isEnabled = true
    }

    private func stopCaptureIfNeeded() async {
        guard isCapturing, let capturer else { return }
        await withCheckedContinuation { continuation in
            capturer.stopCapture {
                continuation.resume()
            }
        }
        isCapturing = false
    }

    private func startSignalPolling(context: VideoMediaSessionContext) {
        signalPollTask?.cancel()
        signalState.invalidatePolling()
        let generation = signalState.generation
        let pollSessionEpoch = sessionEpoch
        let pollCallID = context.callID
        signalPollTask = Task { @MainActor [weak self] in
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            var pollingBackoff = RTCSignalPollingBackoffState()
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            while !Task.isCancelled {
                guard let self,
                      self.isCurrentSignalSession(
                        generation: generation,
                        sessionEpoch: pollSessionEpoch,
                        callID: pollCallID
                      ) else { break }
                do {
                    let cursor = self.signalState.cursor
                    let token = self.signalState.rtcToken
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                    let pollStartedAt = DispatchTime.now().uptimeNanoseconds
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
                    let page = try await context.pollSignals(cursor, token)
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                    let pollElapsed = DispatchTime.now().uptimeNanoseconds - pollStartedAt
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
                    try Task.checkCancellation()
                    guard self.isCurrentSignalSession(
                        generation: generation,
                        sessionEpoch: pollSessionEpoch,
                        callID: pollCallID
                    ) else { break }
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                    pollingBackoff.reset()
                    let next = page.nextCursor.trimmingCharacters(in: .whitespacesAndNewlines)
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
                    if !page.items.isEmpty {
                        self.videoDebug(
                            "signal_poll_ok items=\(page.items.count) kinds=\(page.items.map { $0.kind.rawValue }.joined(separator: ",")) cursorAdvanced=\(!page.nextCursor.isEmpty && page.nextCursor != cursor)"
                        )
                    }
                    for item in page.items {
                        try Task.checkCancellation()
                        guard self.isCurrentSignalSession(
                            generation: generation,
                            sessionEpoch: pollSessionEpoch,
                            callID: pollCallID
                        ) else {
                            throw CancellationError()
                        }
                        if self.signalState.hasProcessed(item.messageID) {
                            continue
                        }
                        try await self.handleSignal(item)
                        guard self.isCurrentSignalSession(
                            generation: generation,
                            sessionEpoch: pollSessionEpoch,
                            callID: pollCallID
                        ) else {
                            throw CancellationError()
                        }
                        self.signalState.markProcessed(item.messageID)
                    }
                    self.inBandCredentialRefresh.requireAcknowledgement(of: next)
                    var didAcknowledgeAndCommit = false
                    if !next.isEmpty, next != self.signalState.cursor {
                        try await context.acknowledgeSignals(next, self.signalState.rtcToken)
                        try Task.checkCancellation()
                        guard self.isCurrentSignalSession(
                            generation: generation,
                            sessionEpoch: pollSessionEpoch,
                            callID: pollCallID
                        ) else {
                            throw CancellationError()
                        }
                        self.signalState.commitCursor(next)
                        didAcknowledgeAndCommit = true
                    }
                    try? await self.flushSignalOutbox()
                    _ = self.inBandCredentialRefresh.completeAfterAcknowledgement(
                        acknowledgedCursor: self.signalState.cursor,
                        didAcknowledgeAndCommit: didAcknowledgeAndCommit
                    )
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                    if let emptyDelay = RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                        itemCount: page.items.count,
                        previousCursor: cursor,
                        nextCursor: next,
                        elapsedNanoseconds: pollElapsed,
                        isConnected: self.connectedEmitted && self.iceConnected
                    ) {
                        self.videoDebug("signal_poll_quick_empty_delay elapsed_ms=\(pollElapsed / 1_000_000) delay_ms=\(emptyDelay / 1_000_000) connected=\(self.connectedEmitted && self.iceConnected)")
                        try? await Task.sleep(nanoseconds: emptyDelay)
                    }
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
                } catch is CancellationError {
                    break
                } catch {
                    self.videoDebug(
                        "signal_poll_failed error=\(Self.safeErrorLabel(error)) iceConnected=\(self.iceConnected)"
                    )
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    if RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(error) {
                        self.videoDebug("signal_poll_terminal error=\(Self.safeErrorLabel(error))")
                        self.emit(.serverSignalTerminal)
                        await self.closeCurrent(
                            reason: "server_signal_terminal",
                            sendBye: false,
                            finishStream: true,
                            releasePreview: true
                        )
                        break
                    }
                    if RTCSignalPollingBackoffPolicy.shouldStopPolling(after: error) {
                        self.videoDebug("signal_poll_stop error=\(Self.safeErrorLabel(error))")
                        break
                    }
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    if RTCVideoSignalPollingFailurePolicy.shouldEmitReconnecting(
                        after: error,
                        iceConnected: self.iceConnected
                    ) {
                        self.emit(.reconnecting)
                    }
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    let delay = pollingBackoff.recordFailureAndDelayNanoseconds(stableKey: pollCallID, error: error)
                    self.videoDebug("signal_poll_backoff delay_ms=\(delay / 1_000_000)")
                    try? await Task.sleep(nanoseconds: delay)
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                }
            }
        }
    }

    private func isCurrentSignalSession(
        generation: Int,
        sessionEpoch: Int,
        callID: String
    ) -> Bool {
        self.sessionEpoch == sessionEpoch
            && currentContext?.callID == callID
            && signalState.isCurrent(generation: generation)
    }

    private func handleSignal(_ item: RemoteRTCSignalItem) async throws {
        guard let context = currentContext else { return }
        guard acceptsRemoteSignal(item, context: context) else { return }
        videoDebug(
            "signal_handle kind=\(item.kind.rawValue) fromDeviceHash=\(Self.shortStableHash(item.fromDevice)) targetDeviceHash=\(Self.shortStableHash(item.toDevice))"
        )
        switch item.kind {
        case .offer, .answer:
            try await handleDescription(item)
        case .candidate:
            guard acceptsNegotiation(item.negotiationID) else { return }
            try await handleCandidates(item.data)
        case .iceRestart:
            if context.isCaller {
                try await refreshCredentialsAndRestartAsCaller(
                    inBandSignalRefresh: true
                )
            }
        case .mediaState:
            let mediaMode = item.data["media_mode"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if mediaMode == "audio" {
                activeMediaMode = "audio"
                cameraEnabledIntent = false
                localVideoTrack?.isEnabled = false
                await stopCaptureIfNeeded()
                emit(.remoteDowngradedToAudio)
                maybeEmitConnected()
                return
            }
            if let enabled = item.data["camera_enabled"]?.boolValue {
                if enabled {
                    remoteCameraPausedByContract = false
                    remoteVideoFrameReady = false
                    rearmRemoteFirstFrameObserver()
                } else {
                    remoteCameraPausedByContract = true
                }
                emit(enabled ? .remoteCameraResumed : .remoteCameraPaused)
                maybeEmitConnected()
            }
        case .renegotiate:
            if context.isPolite {
                try await negotiate(iceRestart: false)
            }
        case .iceComplete:
            return
        case .bye:
            emit(.closed)
            await closeCurrent(reason: "remote_bye", sendBye: false, finishStream: true, releasePreview: true)
        case .unknown:
            return
        }
    }

    private func handleDescription(_ item: RemoteRTCSignalItem) async throws {
        guard let peerConnection, let context = currentContext else { return }
        let decoded = try RTCSignalPayloadCodec.sessionDescription(from: item.data)
        guard let type = rtcSdpType(decoded.type), !decoded.sdp.isEmpty else {
            throw IMAPIError.server("视频协商信息无效")
        }
        let description = RTCSessionDescription(type: type, sdp: decoded.sdp)
        let readyForOffer = !makingOffer
            && (peerConnection.signalingState == .stable || isSettingRemoteAnswerPending)
        let offerCollision = type == .offer && !readyForOffer
        ignoreOffer = !context.isPolite && offerCollision
        if ignoreOffer { return }
        if type == .offer {
            adoptRemoteNegotiationIDIfNeeded(item.negotiationID)
        }
        if offerCollision {
            try await setLocalDescription(
                RTCSessionDescription(type: .rollback, sdp: ""),
                peerConnection: peerConnection
            )
        }
        guard type == .offer || acceptsNegotiation(item.negotiationID) else { return }
        isSettingRemoteAnswerPending = type == .answer
        defer {
            if type == .answer {
                isSettingRemoteAnswerPending = false
            }
        }
        try await setRemoteDescription(description, peerConnection: peerConnection)
        videoDebug("remote_description_set type=\(decoded.type)")
        try await flushPendingRemoteCandidates()
        if type == .offer {
            let answer = try await createAnswer(peerConnection: peerConnection)
            try await setLocalDescription(answer, peerConnection: peerConnection)
            try await sendDescription(answer, kind: .answer)
            videoDebug("answer_enqueued")
        }
    }

    private func adoptRemoteNegotiationIDIfNeeded(_ remoteNegotiationID: String) {
        let normalized = remoteNegotiationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != negotiationID else { return }
        negotiationID = normalized
        remoteCandidateKeys.removeAll()
        videoDebug("negotiation_adopted source=remote_offer")
    }

    private func acceptsRemoteSignal(_ item: RemoteRTCSignalItem, context: VideoMediaSessionContext) -> Bool {
        guard item.callID.isEmpty || item.callID == context.callID else {
            videoDebug("signal_ignored reason=call_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let fromUID = item.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fromUID.isEmpty || fromUID == context.peerUID else {
            videoDebug("signal_ignored reason=from_uid_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let toUID = item.toUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard toUID.isEmpty || toUID == context.localUID else {
            videoDebug("signal_ignored reason=to_uid_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let fromDevice = item.fromDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fromDevice.isEmpty || fromDevice == context.peerDeviceID else {
            videoDebug("signal_ignored reason=from_device_mismatch kind=\(item.kind.rawValue) fromHash=\(Self.shortStableHash(fromDevice)) peerHash=\(Self.shortStableHash(context.peerDeviceID))")
            return false
        }
        let targetDevice = item.toDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetDevice.isEmpty || targetDevice == context.localDeviceID else {
            videoDebug("signal_ignored reason=target_device_mismatch kind=\(item.kind.rawValue) targetHash=\(Self.shortStableHash(targetDevice)) localHash=\(Self.shortStableHash(context.localDeviceID))")
            return false
        }
        return true
    }

    private func acceptsNegotiation(_ remoteNegotiationID: String) -> Bool {
        let normalized = remoteNegotiationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty || normalized == negotiationID else {
            videoDebug("signal_ignored reason=negotiation_mismatch remote=\(Self.shortStableHash(normalized)) local=\(Self.shortStableHash(negotiationID))")
            return false
        }
        return true
    }

    private func handleCandidates(_ data: [String: JSONValue]) async throws {
        let candidates = try RTCSignalPayloadCodec.candidates(from: data)
        if !candidates.isEmpty {
            videoDebug("remote_candidates_received count=\(candidates.count)")
        }
        for item in candidates {
            let candidate = RTCIceCandidate(
                sdp: item.candidate,
                sdpMLineIndex: Int32(item.sdpMLineIndex ?? 0),
                sdpMid: item.sdpMid
            )
            let key = remoteCandidateKey(candidate)
            guard remoteCandidateKeys.insert(key).inserted else {
                videoDebug("remote_candidate_ignored reason=duplicate")
                continue
            }
            guard let peerConnection else { return }
            if peerConnection.remoteDescription == nil {
                pendingRemoteCandidates.append(candidate)
            } else {
                try await addIceCandidate(candidate, peerConnection: peerConnection)
            }
        }
    }

    private func flushPendingRemoteCandidates() async throws {
        guard let peerConnection else { return }
        let candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in candidates {
            try await addIceCandidate(candidate, peerConnection: peerConnection)
        }
    }

    private func negotiate(iceRestart: Bool) async throws {
        guard let peerConnection else { return }
        guard peerConnection.signalingState == .stable else { return }
        makingOffer = true
        defer { makingOffer = false }
        if iceRestart {
            peerConnection.restartIce()
            negotiationID = "neg-\(UUID().uuidString.lowercased())"
            sequence = 0
            remoteCandidateKeys.removeAll()
        }
        let offer = try await createOffer(peerConnection: peerConnection, iceRestart: iceRestart)
        try await setLocalDescription(offer, peerConnection: peerConnection)
        try await sendDescription(offer, kind: .offer)
        emit(.signaling)
    }

    private func refreshCredentialsForCurrentRole() async throws {
        guard let context = currentContext else { return }
        guard RTCVideoCredentialRefreshAction.resolve(
            inBandRequest: false,
            inBandRefreshPending: inBandCredentialRefresh.isPending
        ) != .rejectOutOfBand else {
            return
        }
        switch RTCVideoICERestartPolicy.action(isCaller: context.isCaller) {
        case .restartAndOffer:
            try await refreshCredentialsAndRestartAsCaller()
        case .requestCallerRestart:
            try await refreshCredentialsAndRequestCallerRestart()
        }
    }

    private func applyRefreshedCredentials(
        inBandSignalRefresh: Bool = false
    ) async throws -> Bool {
        guard let context = currentContext, let peerConnection else { return false }
        guard refreshingCredentialSessionEpoch == nil else { return false }
        let refreshSnapshot = RTCVideoCredentialRefreshSnapshot(
            sessionEpoch: sessionEpoch,
            callID: context.callID,
            roomID: context.roomID,
            rtcToken: signalState.rtcToken
        )
        refreshingCredentialSessionEpoch = refreshSnapshot.sessionEpoch
        defer {
            if refreshingCredentialSessionEpoch == refreshSnapshot.sessionEpoch {
                refreshingCredentialSessionEpoch = nil
            }
        }
        let refreshed = try await context.refreshIceCredentials(refreshSnapshot.rtcToken)
        try Task.checkCancellation()
        guard let liveContext = currentContext,
              refreshSnapshot.matches(
                sessionEpoch: sessionEpoch,
                callID: liveContext.callID,
                roomID: liveContext.roomID,
                rtcToken: signalState.rtcToken
              ),
              self.peerConnection === peerConnection else {
            throw CancellationError()
        }
        try liveContext.icePolicy.validateReplacement(refreshed.icePolicy)
        let reboundToken = refreshed.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshed.iceServers.isEmpty, !reboundToken.isEmpty else {
            throw IMAPIError.server("视频网络凭据不可用")
        }
        let configuration = peerConnection.configuration
        // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：ICE 重启刷新凭据时也不再强制 relay
        configuration.iceTransportPolicy = .all
        // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束
        configuration.iceServers = makeIceServers(refreshed.iceServers)
        guard peerConnection.setConfiguration(configuration) else {
            throw IMAPIError.server("视频网络凭据更新失败")
        }
        // Token and ICE credentials are one atomic server generation. Rebind
        // before restarting any poll or signal operation; the old token is
        // never retained after this point.
        if inBandSignalRefresh {
            signalState.stageTokenRebind(reboundToken)
            inBandCredentialRefresh.request()
        } else {
            signalState.rebindToken(reboundToken)
        }
        qualityTelemetrySession?.updateToken(reboundToken)
        qualityTelemetrySession?.updateRouteCapability(refreshed.turnRouteTelemetry)
        var reboundContext = context
        reboundContext.rtcToken = reboundToken
        currentContext = reboundContext
        if !inBandSignalRefresh {
            startSignalPolling(context: reboundContext)
        }
        scheduleCredentialRefresh(
            refreshAfter: refreshed.iceCredentialRefreshAfter,
            expiresAt: refreshed.iceCredentialExpiresAt
        )
        try? await flushSignalOutbox()
        return true
    }

    private func refreshCredentialsAndRestartAsCaller(
        inBandSignalRefresh: Bool = false
    ) async throws {
        guard currentContext?.isCaller == true else { return }
        switch RTCVideoCredentialRefreshAction.resolve(
            inBandRequest: inBandSignalRefresh,
            inBandRefreshPending: inBandCredentialRefresh.isPending
        ) {
        case .retryNegotiation:
            try await negotiate(iceRestart: true)
            return
        case .rejectOutOfBand:
            return
        case .refreshAndNegotiate:
            break
        }
        let didRefresh = try await applyRefreshedCredentials(
            inBandSignalRefresh: inBandSignalRefresh
        )
        guard didRefresh else {
            if inBandSignalRefresh {
                throw IMAPIError.server("视频网络凭据正在更新")
            }
            return
        }
        try await negotiate(iceRestart: true)
    }

    private func refreshCredentialsAndRequestCallerRestart() async throws {
        guard currentContext?.isPolite == true else { return }
        guard RTCVideoCredentialRefreshAction.resolve(
            inBandRequest: false,
            inBandRefreshPending: inBandCredentialRefresh.isPending
        ) != .rejectOutOfBand else {
            return
        }
        guard try await applyRefreshedCredentials() else { return }
        try await sendSignal(
            kind: .iceRestart,
            data: RTCSignalPayloadCodec.iceRestartData()
        )
    }

    private func scheduleCredentialRefresh(refreshAfter: String, expiresAt: String) {
        credentialRefreshTask?.cancel()
        guard let delay = RTCVideoCredentialSchedule.delay(
            refreshAfter: refreshAfter,
            expiresAt: expiresAt
        ) else { return }
        credentialRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? await self?.refreshCredentialsForCurrentRole()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            try? await self.refreshCredentialsForCurrentRole()
        }
    }

    private func sendDescription(_ description: RTCSessionDescription, kind: RemoteRTCSignalKind) async throws {
        try await sendSignal(
            kind: kind,
            data: RTCSignalPayloadCodec.sessionDescriptionData(type: kind.rawValue, sdp: description.sdp)
        )
    }

    private func sendCandidate(_ candidate: RTCIceCandidate) async {
        let value = RemoteRTCIceCandidateSignalData(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex),
            usernameFragment: nil
        )
        do {
            try await sendSignal(kind: .candidate, data: RTCSignalPayloadCodec.candidateData([value]))
        } catch {
            // A full bounded outbox is a call-level reliability failure. Never
            // silently discard a candidate that cannot be retained.
            emit(.failed)
        }
    }

    private func sendSignal(kind: RemoteRTCSignalKind, data: [String: JSONValue]) async throws {
        guard let context = currentContext else { return }
        sequence += 1
        let envelope = RemoteRTCSignalEnvelope(
            protocolVersion: RTCDeviceCapabilities.protocolVersion,
            messageID: UUID().uuidString.lowercased(),
            seq: sequence,
            negotiationID: negotiationID,
            callID: context.callID,
            toUID: context.peerUID,
            toDevice: context.peerDeviceID,
            kind: kind,
            data: data,
            sentAt: ISO8601DateFormatter().string(from: Date())
        )
        try signalOutbox.enqueue(envelope)
        videoDebug(
            "signal_enqueued kind=\(kind.rawValue) pending=\(signalOutbox.pending.count) peerDeviceHash=\(Self.shortStableHash(context.peerDeviceID))"
        )
        do {
            try await flushSignalOutbox()
        } catch {
            // Retryable critical signaling stays queued with its original
            // message_id and seq. A later critical envelope may supersede an
            // unsent best-effort media_state to keep sequence order monotonic.
            videoDebug(
                "signal_flush_deferred kind=\(kind.rawValue) pending=\(signalOutbox.pending.count) error=\(Self.safeErrorLabel(error))"
            )
            emit(.reconnecting)
        }
    }

    private func flushSignalOutbox() async throws {
        guard !isFlushingSignalOutbox, let context = currentContext else { return }
        isFlushingSignalOutbox = true
        defer { isFlushingSignalOutbox = false }
        while let envelope = signalOutbox.pending.first {
            do {
                _ = try await context.postSignal(envelope, signalState.rtcToken)
                signalOutbox.markDelivered(messageID: envelope.messageID)
                videoDebug(
                    "signal_delivered kind=\(envelope.kind.rawValue) pending=\(signalOutbox.pending.count)"
                )
            } catch {
                videoDebug(
                    "signal_delivery_failed kind=\(envelope.kind.rawValue) error=\(Self.safeErrorLabel(error))"
                )
                if RTCVideoSignalFailurePolicy.shouldDropBestEffort(kind: envelope.kind, after: error) {
                    signalOutbox.markDelivered(messageID: envelope.messageID)
                    videoDebug(
                        "signal_best_effort_dropped kind=\(envelope.kind.rawValue) pending=\(signalOutbox.pending.count)"
                    )
                    continue
                }
                guard RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(error) else {
                    throw error
                }
                signalOutbox.reset()
                emit(.serverSignalTerminal)
                await closeCurrent(
                    reason: "server_signal_terminal",
                    sendBye: false,
                    finishStream: true,
                    releasePreview: true
                )
                return
            }
        }
    }

    private func createOffer(peerConnection: RTCPeerConnection, iceRestart: Bool) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
                "IceRestart": iceRestart ? "true" : "false"
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: IMAPIError.server("视频协商创建失败"))
                }
            }
        }
    }

    private func createAnswer(peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: IMAPIError.server("视频协商应答失败"))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func setRemoteDescription(_ description: RTCSessionDescription, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func addIceCandidate(_ candidate: RTCIceCandidate, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func remoteCandidateKey(_ candidate: RTCIceCandidate) -> String {
        [
            candidate.sdp.trimmingCharacters(in: .whitespacesAndNewlines),
            candidate.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            String(candidate.sdpMLineIndex)
        ].joined(separator: "|")
    }

    private func rtcSdpType(_ value: String) -> RTCSdpType? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "offer": return .offer
        case "answer": return .answer
        default: return nil
        }
    }

    private func maybeEmitConnected() {
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

    private func startMediaReadinessProbe() {
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

    private func closeCurrent(
        reason: String,
        sendBye: Bool,
        finishStream: Bool,
        releasePreview: Bool
    ) async {
        guard !isClosingCurrentSession else { return }
        isClosingCurrentSession = true
        defer { isClosingCurrentSession = false }
        // Invalidate every suspended poll/refresh before the first await below.
        // A late response from the old call must never mutate a replacement call.
        sessionEpoch &+= 1
        let context = currentContext
        signalPollTask?.cancel()
        reconnectTask?.cancel()
        credentialRefreshTask?.cancel()
        mediaReadinessGeneration &+= 1
        mediaReadinessTask?.cancel()
        signalPollTask = nil
        reconnectTask = nil
        credentialRefreshTask = nil
        mediaReadinessTask = nil
        let qualitySession = qualityTelemetrySession
        qualityTelemetrySession = nil
        Task { @MainActor in await qualitySession?.stop() }
        if sendBye, context != nil {
            try? await sendSignal(kind: .bye, data: ["reason": .string(reason)])
        }
        await stopCaptureIfNeeded()
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack?.isEnabled = false
        localAudioTrack = nil
        remoteAudioTracks.removeAll()
        remoteAudioTrackReady = false
        remoteAudioRTPReady = false
        remoteVideoFrameReady = false
        remoteCameraPausedByContract = false
        awaitingMediaRecovery = false
        lastInboundAudioBytes = 0
        lastInboundAudioPackets = 0
        lastInboundVideoBytes = 0
        lastInboundVideoPackets = 0
        lastInboundVideoFrames = 0
        if let remoteVideoTrack, let remoteFirstFrameObserver {
            remoteVideoTrack.remove(remoteFirstFrameObserver)
        }
        remoteFirstFrameObserver = nil
        remoteVideoTrack = nil
        pendingRemoteCandidates.removeAll()
        remoteCandidateKeys.removeAll()
        currentContext = nil
        signalState = RTCVideoSignalRuntimeState(rtcToken: "")
        inBandCredentialRefresh.reset()
        signalOutbox = RTCVideoSignalOutbox()
        isFlushingSignalOutbox = false
        refreshingCredentialSessionEpoch = nil
        if releasePreview {
            localVideoTrack?.isEnabled = false
            localVideoTrack = nil
            localVideoSource = nil
            capturer = nil
            RTCVideoRenderRegistry.shared.clear()
        } else {
            RTCVideoRenderRegistry.shared.setRemoteTrack(nil)
        }
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        audioSession.isAudioEnabled = false
        try? audioSession.setActive(false)
        audioSession.unlockForConfiguration()
        if finishStream {
            eventContinuation?.finish()
            eventContinuation = nil
        }
        videoDebug("closed reason=\(reason) sendBye=\(sendBye)")
        currentDebugID = ""
    }

    private func qualityStatRecords(for connection: RTCPeerConnection) async -> [RTCQualityStatRecord] {
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

    private func emit(_ event: RTCVideoMediaEvent) {
        videoDebug("event=\(event.rawValue)")
        eventContinuation?.yield(event)
    }

    private func bindRemoteVideoTrack(_ track: RTCVideoTrack) {
        guard remoteVideoTrack !== track else {
            rearmRemoteFirstFrameObserver()
            return
        }
        if let remoteVideoTrack, let remoteFirstFrameObserver {
            remoteVideoTrack.remove(remoteFirstFrameObserver)
        }
        remoteVideoTrack = track
        remoteVideoFrameReady = false
        lastInboundVideoBytes = 0
        lastInboundVideoPackets = 0
        lastInboundVideoFrames = 0
        track.isEnabled = true
        RTCVideoRenderRegistry.shared.setRemoteTrack(track)
        let epoch = sessionEpoch
        let observer = RTCVideoFirstFrameObserver { [weak self] width, height, rotation in
            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionEpoch == epoch,
                      self.remoteVideoTrack === track else { return }
                self.videoDebug("remote_first_frame width=\(width) height=\(height) rotation=\(rotation)")
                self.remoteVideoFrameReady = true
                self.emit(.remoteVideoTrackReady)
                self.maybeEmitConnected()
            }
        }
        remoteFirstFrameObserver = observer
        track.add(observer)
    }

    private func rearmRemoteFirstFrameObserver() {
        remoteFirstFrameObserver?.reset()
    }

    private func videoDebug(_ message: @autoclosure () -> String) {
        let value = message()
        let callID = currentDebugID.isEmpty ? "no-call" : currentDebugID
#if DEBUG
        NSLog("[JHT RTC][Video:%@] %@", callID, value)
#endif
        Task {
            await RTCCallDiagnosticLogStore.shared.append(category: "VideoMedia", media: "video", callID: callID, message: value)
        }
    }

    private static func shortStableHash(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "missing" }
        var hash: UInt32 = 2_166_136_261
        for byte in trimmed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    private static func safeErrorLabel(_ error: Error) -> String {
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
}

extension WebRTCVideoMediaClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let audioTracks = stream.audioTracks
        let videoTrack = stream.videoTracks.first
        Task { @MainActor [weak self] in
            for track in audioTracks where !(self?.remoteAudioTracks.contains { $0 === track } ?? true) {
                track.isEnabled = true
                self?.remoteAudioTracks.append(track)
                self?.remoteAudioTrackReady = true
                self?.emit(.remoteAudioTrackReady)
                self?.startMediaReadinessProbe()
                self?.maybeEmitConnected()
            }
            if let videoTrack {
                self?.bindRemoteVideoTrack(videoTrack)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.videoDebug("ice_state=\(String(describing: newState))")
            switch newState {
            case .checking:
                self.emit(.connecting)
            case .connected, .completed:
                self.iceConnected = true
                self.reconnectTask?.cancel()
                self.startMediaReadinessProbe()
                self.maybeEmitConnected()
                try? await self.flushSignalOutbox()
            case .disconnected:
                self.iceConnected = false
                self.awaitingMediaRecovery = self.connectedEmitted
                self.remoteAudioRTPReady = false
                self.remoteVideoFrameReady = false
                self.lastInboundAudioBytes = 0
                self.lastInboundAudioPackets = 0
                self.lastInboundVideoBytes = 0
                self.lastInboundVideoPackets = 0
                self.lastInboundVideoFrames = 0
                self.mediaReadinessGeneration &+= 1
                self.mediaReadinessTask?.cancel()
                self.mediaReadinessTask = nil
                self.rearmRemoteFirstFrameObserver()
                self.emit(.reconnecting)
                self.scheduleReconnect()
            case .failed:
                self.iceConnected = false
                self.awaitingMediaRecovery = self.connectedEmitted
                self.remoteAudioRTPReady = false
                self.remoteVideoFrameReady = false
                self.lastInboundAudioBytes = 0
                self.lastInboundAudioPackets = 0
                self.lastInboundVideoBytes = 0
                self.lastInboundVideoPackets = 0
                self.lastInboundVideoFrames = 0
                self.mediaReadinessGeneration &+= 1
                self.mediaReadinessTask?.cancel()
                self.mediaReadinessTask = nil
                self.rearmRemoteFirstFrameObserver()
                self.emit(.reconnecting)
                self.scheduleReconnect()
            case .closed:
                self.emit(.closed)
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            try? await self?.sendSignal(kind: .iceComplete, data: RTCSignalPayloadCodec.iceCompleteData)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            self?.videoDebug("local_candidate_generated")
            await self?.sendCandidate(candidate)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            self?.videoDebug("peer_connection_state=\(String(describing: newState))")
            switch newState {
            case .connecting:
                self?.emit(.connecting)
            case .connected:
                self?.iceConnected = true
                self?.startMediaReadinessProbe()
                self?.maybeEmitConnected()
                try? await self?.flushSignalOutbox()
            case .disconnected:
                self?.iceConnected = false
                self?.awaitingMediaRecovery = self?.connectedEmitted == true
                self?.remoteAudioRTPReady = false
                self?.remoteVideoFrameReady = false
                self?.lastInboundAudioBytes = 0
                self?.lastInboundAudioPackets = 0
                self?.lastInboundVideoBytes = 0
                self?.lastInboundVideoPackets = 0
                self?.lastInboundVideoFrames = 0
                if let self { self.mediaReadinessGeneration &+= 1 }
                self?.mediaReadinessTask?.cancel()
                self?.mediaReadinessTask = nil
                self?.rearmRemoteFirstFrameObserver()
                self?.emit(.reconnecting)
            case .failed:
                self?.iceConnected = false
                self?.awaitingMediaRecovery = self?.connectedEmitted == true
                self?.remoteAudioRTPReady = false
                self?.remoteVideoFrameReady = false
                self?.lastInboundAudioBytes = 0
                self?.lastInboundAudioPackets = 0
                self?.lastInboundVideoBytes = 0
                self?.lastInboundVideoPackets = 0
                self?.lastInboundVideoFrames = 0
                if let self { self.mediaReadinessGeneration &+= 1 }
                self?.mediaReadinessTask?.cancel()
                self?.mediaReadinessTask = nil
                self?.rearmRemoteFirstFrameObserver()
                self?.emit(.failed)
            case .closed:
                self?.emit(.closed)
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didStartReceivingOn transceiver: RTCRtpTransceiver
    ) {
        Task { @MainActor [weak self] in
            if let videoTrack = transceiver.receiver.track as? RTCVideoTrack {
                self?.bindRemoteVideoTrack(videoTrack)
            } else if let audioTrack = transceiver.receiver.track as? RTCAudioTrack {
                audioTrack.isEnabled = true
                if !(self?.remoteAudioTracks.contains { $0 === audioTrack } ?? true) {
                    self?.remoteAudioTracks.append(audioTrack)
                }
                self?.remoteAudioTrackReady = true
                self?.emit(.remoteAudioTrackReady)
                self?.startMediaReadinessProbe()
                self?.maybeEmitConnected()
            }
        }
    }
}
#else
struct RTCVideoRendererView: View {
    let local: Bool
    var mirrored = false
    var onVideoSizeChanged: ((CGSize) -> Void)?

    var body: some View {
        Color.black
    }
}
#endif

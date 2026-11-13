import AVFoundation
import Foundation

// WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: keep system call frameworks out unless a build explicitly enables CallKit.
#if WDT_ENABLE_CALLKIT && canImport(CallKit)
@preconcurrency import CallKit
#endif

#if WDT_ENABLE_CALLKIT && canImport(PushKit)
@preconcurrency import PushKit
#endif
// WDT_IOS1_CALLKIT_CN_POLICY_20260923_END

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
@MainActor
extension WebRTCVoiceMediaClient {
#if DEBUG
    func startVoiceQualityProbe() {
        guard qualityProbeTask == nil,
              let context = currentContext,
              let peerConnection else { return }
        let epoch = sessionEpoch
        let callID = context.callID
        qualityProbeTask = Task { @MainActor [weak self] in
            defer {
                if self?.sessionEpoch == epoch,
                   self?.currentContext?.callID == callID {
                    self?.qualityProbeTask = nil
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self,
                      self.sessionEpoch == epoch,
                      self.currentContext?.callID == callID,
                      self.peerConnection === peerConnection,
                      self.hasConnected,
                      self.isICEConnected else { return }
                let records = await self.qualityStatRecords(for: peerConnection)
                self.qualitySampleSequence += 1
                guard let sample = self.qualitySampleReducer.reduce(
                    records: records,
                    sampledAt: Date(),
                    sampleSeq: self.qualitySampleSequence
                ) else { continue }
                self.rtcDebug(
                    "voice_quality issue=media_degrade_or_long_call_end route=\(sample.connectionRoute) proto=\(sample.candidateProtocol) rtt_ms=\(Self.qualityMetric(sample.rttMS)) jitter_ms=\(Self.qualityMetric(sample.jitterMS)) loss_pct=\(Self.qualityMetric(sample.packetLossPct)) conceal_pct=\(Self.qualityMetric(sample.audioConcealmentPct)) in_kbps=\(Self.qualityMetric(sample.inboundBitrateKbps)) out_kbps=\(Self.qualityMetric(sample.outboundBitrateKbps))"
                )
            }
        }
    }

    private func qualityStatRecords(for connection: RTCPeerConnection) async -> [RTCQualityStatRecord] {
        await withCheckedContinuation { continuation in
            connection.statistics { report in
                continuation.resume(returning: report.statistics.values.map { statistic in
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
                })
            }
        }
    }

    private static func qualityMetric(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.1f", value)
    }
#endif
}
#endif

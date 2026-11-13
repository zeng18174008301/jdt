import AVFoundation
import Foundation
import CoreFoundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

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

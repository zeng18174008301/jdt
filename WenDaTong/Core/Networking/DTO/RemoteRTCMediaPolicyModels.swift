// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Data
import IM4Domain

enum RTCIcePolicyError: Error, LocalizedError {
    case invalidPolicy, missingPolicy, changedPolicy, relayUnavailable

    var errorDescription: String? {
        switch self {
        case .relayUnavailable: return "通话连接失败，请稍后重试"
        default: return "通话连接策略暂不可用，请稍后重试"
        }
    }
}

typealias RTCIcePolicy = IM4Domain.RTCIcePolicy

extension RTCIcePolicy: @retroactive Decodable {

    // Only an explicitly negotiated legacy server may reach this default.
    static let legacy = Self(transport: .all, version: 0, revision: "")

    enum CodingKeys: String, CodingKey {
        case transport = "ice_transport_policy"
        case version = "ice_transport_policy_version"
        case revision = "rtc_config_revision"
    }



    public init(from decoder: Decoder) throws {
        let transport: Transport
        let version: Int
        let revision: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decode(Transport.self, forKey: .transport)
        version = try c.decode(Int.self, forKey: .version)
        revision = try c.decode(String.self, forKey: .revision)
        guard version == 1, !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RTCIcePolicyError.invalidPolicy
        }
        self.init(transport: transport, version: version, revision: revision)
    }

    static func decodeIfPresent(from decoder: Decoder) throws -> Self? {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.transport) || c.contains(.version) || c.contains(.revision) else { return nil }
        return try Self(from: decoder)
    }

    // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：保留后端 ICE policy 合同解析，但 iOS 不再因 relay policy 强制阻断非中继路径
    static func resolve(_ value: Self?, requiresV1: Bool, servers _: [RemoteRTCIceServer]) throws -> Self {
        guard let value else {
            guard !requiresV1 else { throw RTCIcePolicyError.missingPolicy }
            return .legacy
        }
        return value
    }
    // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束

    func validateReplacement(_ value: Self?) throws {
        guard (value ?? .legacy) == self else { throw RTCIcePolicyError.changedPolicy }
    }

    func validateServers(_ servers: [RemoteRTCIceServer]) throws {
        guard transport == .relay else { return }
        let usable = servers.contains { server in
            guard !(server.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !(server.credential ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return server.urls.contains { raw in
                let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, ["turn", "turns"].contains(parts[0].lowercased()),
                      let url = URLComponents(string: String(parts[0]) + "://" + String(parts[1])),
                      let host = url.host, !host.isEmpty,
                      url.user == nil, url.password == nil, url.path.isEmpty else { return false }
                return url.port.map { (1...65535).contains($0) } ?? true
            }
        }
        guard usable else { throw RTCIcePolicyError.relayUnavailable }
    }
}

typealias RemoteRTCMedia = IM4Data.RemoteRTCMedia

extension RemoteRTCMedia: @retroactive Decodable {


    enum CodingKeys: String, CodingKey {
        case owtBaseURL = "owt_base_url"
        case turnRouteTelemetry = "turn_route_telemetry"
        case iceServers = "ice_servers"
        case iceCredentialExpiresAt = "ice_credential_expires_at"
        case iceCredentialRefreshAfter = "ice_credential_refresh_after"
    }



    public init(from decoder: Decoder) throws {
        let owtBaseURL: String
        let icePolicy: RTCIcePolicy?
        let iceServers: [RemoteRTCIceServer]
        let iceCredentialExpiresAt: String
        let iceCredentialRefreshAfter: String
        let turnRouteTelemetry: RemoteRTCTurnRouteTelemetry?
        icePolicy = try RTCIcePolicy.decodeIfPresent(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Optional telemetry must never make otherwise valid media credentials fail.
        turnRouteTelemetry = try? c.decode(RemoteRTCTurnRouteTelemetry.self, forKey: .turnRouteTelemetry)
        owtBaseURL = try c.decodeIfPresent(String.self, forKey: .owtBaseURL) ?? ""
        iceServers = try c.decodeIfPresent([RemoteRTCIceServer].self, forKey: .iceServers) ?? []
        iceCredentialExpiresAt = try c.decodeIfPresent(String.self, forKey: .iceCredentialExpiresAt) ?? ""
        iceCredentialRefreshAfter = try c.decodeIfPresent(String.self, forKey: .iceCredentialRefreshAfter) ?? ""
        self.init(owtBaseURL: owtBaseURL, iceServers: iceServers, iceCredentialExpiresAt: iceCredentialExpiresAt, iceCredentialRefreshAfter: iceCredentialRefreshAfter, turnRouteTelemetry: turnRouteTelemetry, icePolicy: icePolicy)
    }
}

typealias RemoteRTCIceServer = IM4Data.RemoteRTCIceServer

typealias RemoteRTCIceCredentials = IM4Data.RemoteRTCIceCredentials

extension RemoteRTCIceCredentials: @retroactive Decodable {


    enum CodingKeys: String, CodingKey {
        case turnRouteTelemetry = "turn_route_telemetry"
        case iceServers = "ice_servers"
        case rtcToken = "rtc_token"
        case iceCredentialExpiresAt = "ice_credential_expires_at"
        case iceCredentialRefreshAfter = "ice_credential_refresh_after"
    }



    public init(from decoder: Decoder) throws {
        let icePolicy: RTCIcePolicy?
        let iceServers: [RemoteRTCIceServer]
        let rtcToken: String
        let iceCredentialExpiresAt: String
        let iceCredentialRefreshAfter: String
        let turnRouteTelemetry: RemoteRTCTurnRouteTelemetry?
        icePolicy = try RTCIcePolicy.decodeIfPresent(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Optional telemetry must never make otherwise valid media credentials fail.
        turnRouteTelemetry = try? c.decode(RemoteRTCTurnRouteTelemetry.self, forKey: .turnRouteTelemetry)
        iceServers = try c.decode([RemoteRTCIceServer].self, forKey: .iceServers)
        rtcToken = try c.decode(String.self, forKey: .rtcToken)
        iceCredentialExpiresAt = try c.decode(String.self, forKey: .iceCredentialExpiresAt)
        iceCredentialRefreshAfter = try c.decode(String.self, forKey: .iceCredentialRefreshAfter)
        self.init(iceServers: iceServers, rtcToken: rtcToken, iceCredentialExpiresAt: iceCredentialExpiresAt, iceCredentialRefreshAfter: iceCredentialRefreshAfter, turnRouteTelemetry: turnRouteTelemetry, icePolicy: icePolicy)
    }
}

typealias RemoteRTCTurnRouteTelemetry = IM4Data.RemoteRTCTurnRouteTelemetry

extension RemoteRTCTurnRouteTelemetry {
    var isSupported: Bool {
        schemaVersion == "rtc-turn-route-v1"
            && mappingVersion.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            && !nodes.isEmpty && nodes.count <= 256
            && nodes.allSatisfy {
                $0.nodeID.range(of: "^tn_[0-9a-f]{32}$", options: .regularExpression) != nil
                    && !$0.urls.isEmpty && $0.urls.count <= 32
            }
    }
}

typealias RTCTurnRouteObservation = IM4Data.RTCTurnRouteObservation

extension RTCTurnRouteObservation {
    var requestBody: [String: Any] {
        ["schema_version": "rtc-turn-route-v1", "connection_id": connectionID,
         "mapping_version": mappingVersion, "transports": transports.map(\.requestBody)]
    }
}

extension RTCTurnRouteObservation.Transport {
    var requestBody: [String: Any] {
        var body: [String: Any] = [
            "transport_id": transportID, "route_epoch": routeEpoch,
            "selection_basis": selectionBasis, "local_candidate_type": localCandidateType,
            "remote_candidate_type": remoteCandidateType, "local_relay_protocol": localRelayProtocol,
            "unknown_reason": unknownReason
        ]
        if let nodeID { body["node_id"] = nodeID }
        if let bytesSent, let bytesReceived {
            body["bytes_sent"] = bytesSent
            body["bytes_received"] = bytesReceived
        }
        return body
    }
}

typealias RTCQualitySample = IM4Data.RTCQualitySample

extension RTCQualitySample {
    static let schemaVersion = "rtc-quality-v1"

    var requestBody: [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: Any] = [
            "sampled_at": formatter.string(from: sampledAt),
            "sample_seq": sampleSeq,
            "connection_route": connectionRoute,
            "candidate_protocol": candidateProtocol
        ]
        if let rttMS { body["rtt_ms"] = rttMS }
        if let jitterMS { body["jitter_ms"] = jitterMS }
        if let packetLossPct { body["packet_loss_pct"] = packetLossPct }
        if let availableOutgoingBitrateKbps { body["available_outgoing_bitrate_kbps"] = availableOutgoingBitrateKbps }
        if let inboundBitrateKbps { body["inbound_bitrate_kbps"] = inboundBitrateKbps }
        if let outboundBitrateKbps { body["outbound_bitrate_kbps"] = outboundBitrateKbps }
        if let framesPerSecond { body["frames_per_second"] = framesPerSecond }
        if let framesDropped { body["frames_dropped"] = framesDropped }
        if let audioConcealmentPct { body["audio_concealment_pct"] = audioConcealmentPct }
        if let freezeCount { body["freeze_count"] = freezeCount }
        if let routeObservation { body["route_observation"] = routeObservation.requestBody }
        return body
    }
}

typealias RemoteRTCQualityBatchResult = IM4Data.RemoteRTCQualityBatchResult
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

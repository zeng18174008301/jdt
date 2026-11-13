// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Domain

public struct RemoteRTCSignalEnvelope: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let messageID: String
    public let seq: Int
    public let negotiationID: String
    public let callID: String
    public let toUID: String
    public let toDevice: String
    public let kind: RemoteRTCSignalKind
    public let data: [String: JSONValue]
    public let sentAt: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case messageID = "message_id"
        case seq
        case negotiationID = "negotiation_id"
        case callID = "call_id"
        case toUID = "to_uid"
        case toDevice = "to_device"
        case kind
        case data
        case sentAt = "sent_at"
    }

    public init(
        protocolVersion: String = "",
        messageID: String = "",
        seq: Int = 0,
        negotiationID: String = "",
        callID: String = "",
        toUID: String = "",
        toDevice: String = "",
        kind: RemoteRTCSignalKind,
        data: [String: JSONValue] = [:],
        sentAt: String = ""
    ) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.seq = seq
        self.negotiationID = negotiationID
        self.callID = callID
        self.toUID = toUID
        self.toDevice = toDevice
        self.kind = kind
        self.data = data
        self.sentAt = sentAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(String.self, forKey: .protocolVersion) ?? ""
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        negotiationID = try c.decodeIfPresent(String.self, forKey: .negotiationID) ?? ""
        callID = try c.decodeIfPresent(String.self, forKey: .callID) ?? ""
        toUID = try c.decodeIfPresent(String.self, forKey: .toUID) ?? ""
        toDevice = try c.decodeIfPresent(String.self, forKey: .toDevice) ?? ""
        kind = try c.decodeIfPresent(RemoteRTCSignalKind.self, forKey: .kind) ?? .unknown("")
        data = try c.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
        sentAt = try c.decodeIfPresent(String.self, forKey: .sentAt) ?? ""
    }
}

public struct RemoteRTCSignalItemsData: Codable, Sendable, Equatable {
    public let items: [RemoteRTCSignalItem]
    public let nextCursor: String
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    public init(items: [RemoteRTCSignalItem] = [], nextCursor: String = "", hasMore: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteRTCSignalItem].self, forKey: .items) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor) ?? ""
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore) ?? false
    }
}

public struct RemoteRTCSignalItem: Codable, Sendable, Equatable {
    public let serverCursor: String
    public let messageID: String
    public let seq: Int
    public let negotiationID: String
    public let callID: String
    public let fromUID: String
    public let fromDevice: String
    public let toUID: String
    public let toDevice: String
    public let kind: RemoteRTCSignalKind
    public let data: [String: JSONValue]
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case serverCursor = "server_cursor"
        case messageID = "message_id"
        case seq
        case negotiationID = "negotiation_id"
        case callID = "call_id"
        case fromUID = "from_uid"
        case fromDevice = "from_device"
        case toUID = "to_uid"
        case toDevice = "to_device"
        case kind
        case data
        case createdAt = "created_at"
    }

    public init(
        serverCursor: String = "",
        messageID: String = "",
        seq: Int = 0,
        negotiationID: String = "",
        callID: String = "",
        fromUID: String = "",
        fromDevice: String = "",
        toUID: String = "",
        toDevice: String = "",
        kind: RemoteRTCSignalKind,
        data: [String: JSONValue] = [:],
        createdAt: String = ""
    ) {
        self.serverCursor = serverCursor
        self.messageID = messageID
        self.seq = seq
        self.negotiationID = negotiationID
        self.callID = callID
        self.fromUID = fromUID
        self.fromDevice = fromDevice
        self.toUID = toUID
        self.toDevice = toDevice
        self.kind = kind
        self.data = data
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverCursor = try c.decodeIfPresent(String.self, forKey: .serverCursor) ?? ""
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        negotiationID = try c.decodeIfPresent(String.self, forKey: .negotiationID) ?? ""
        callID = try c.decodeIfPresent(String.self, forKey: .callID) ?? ""
        fromUID = try c.decodeIfPresent(String.self, forKey: .fromUID) ?? ""
        fromDevice = try c.decodeIfPresent(String.self, forKey: .fromDevice) ?? ""
        toUID = try c.decodeIfPresent(String.self, forKey: .toUID) ?? ""
        toDevice = try c.decodeIfPresent(String.self, forKey: .toDevice) ?? ""
        kind = try c.decodeIfPresent(RemoteRTCSignalKind.self, forKey: .kind) ?? .unknown("")
        data = try c.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

public struct RemoteRTCSignalPostResult: Decodable, Sendable, Equatable {
    public let messageID: String
    public let serverCursor: String
    public let duplicate: Bool
    public let serverReceivedAt: String
    public let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case serverCursor = "server_cursor"
        case duplicate
        case serverReceivedAt = "server_received_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        serverCursor = try c.decodeIfPresent(String.self, forKey: .serverCursor) ?? ""
        duplicate = c.decodeLossyBoolIfPresent(forKey: .duplicate) ?? false
        serverReceivedAt = try c.decodeIfPresent(String.self, forKey: .serverReceivedAt) ?? ""
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt) ?? ""
    }
}

public struct RemoteRTCSessionDescriptionSignalData: Codable, Sendable, Equatable {
    public let type: String
    public let sdp: String



    public init(type: String = "", sdp: String = "") {
        self.type = type
        self.sdp = sdp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        sdp = try c.decodeIfPresent(String.self, forKey: .sdp) ?? ""
    }
}

public struct RemoteRTCIceCandidateSignalData: Codable, Sendable, Equatable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int?
    public let usernameFragment: String?

    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_mline_index"
        case usernameFragment = "username_fragment"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case sdpMid
        case sdpMLineIndex
        case usernameFragment
    }

    public init(candidate: String = "", sdpMid: String? = nil, sdpMLineIndex: Int? = nil, usernameFragment: String? = nil) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.usernameFragment = usernameFragment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        candidate = try c.decodeIfPresent(String.self, forKey: .candidate) ?? ""
        sdpMid = try c.decodeIfPresent(String.self, forKey: .sdpMid)
            ?? legacy.decodeIfPresent(String.self, forKey: .sdpMid)
        sdpMLineIndex = try c.decodeIfPresent(Int.self, forKey: .sdpMLineIndex)
            ?? legacy.decodeIfPresent(Int.self, forKey: .sdpMLineIndex)
        usernameFragment = try c.decodeIfPresent(String.self, forKey: .usernameFragment)
            ?? legacy.decodeIfPresent(String.self, forKey: .usernameFragment)
    }
}

public struct RemoteRTCIceCandidatesSignalData: Codable, Sendable, Equatable {
    public let candidates: [RemoteRTCIceCandidateSignalData]

    enum CodingKeys: String, CodingKey {
        case candidates
    }

    public init(candidates: [RemoteRTCIceCandidateSignalData] = []) {
        self.candidates = candidates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let batch = try c.decodeIfPresent([RemoteRTCIceCandidateSignalData].self, forKey: .candidates) {
            candidates = batch
        } else {
            let single = try RemoteRTCIceCandidateSignalData(from: decoder)
            candidates = single.candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [single]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(candidates, forKey: .candidates)
    }
}

public struct RemoteRTCByeSignalData: Codable, Sendable, Equatable {
    public let reason: String

    public init(reason: String = "") {
        self.reason = reason
    }
}
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

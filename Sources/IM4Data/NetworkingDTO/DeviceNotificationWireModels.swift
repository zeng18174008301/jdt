import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteUserDevice: Decodable, Sendable {
    public let id: String
    public let deviceID: String
    public let deviceType: String
    public let appID: String
    public let status: String
    public let banned: Bool
    public let lastSeenAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case deviceType = "device_type"
        case appID = "app_id"
        case status
        case banned
        case isBlocked = "is_blocked"
        case lastSeenAt = "last_seen_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        deviceType = try container.decode(String.self, forKey: .deviceType)
        appID = try container.decode(String.self, forKey: .appID)
        status = try container.decode(String.self, forKey: .status)
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        banned = try container.decodeIfPresent(Bool.self, forKey: .banned)
            ?? container.decodeIfPresent(Bool.self, forKey: .isBlocked)
            ?? (normalizedStatus == "banned" || normalizedStatus == "blocked")
        lastSeenAt = try container.decodeIfPresent(String.self, forKey: .lastSeenAt)
    }

    public init(
        id: String,
        deviceID: String,
        deviceType: String,
        appID: String,
        status: String,
        banned: Bool,
        lastSeenAt: String?
    ) {
        self.id = id
        self.deviceID = deviceID
        self.deviceType = deviceType
        self.appID = appID
        self.status = status
        self.banned = banned
        self.lastSeenAt = lastSeenAt
    }
}

public struct RemoteMyLoginLog: Decodable, Sendable {
    public let id: String
    public let deviceType: String
    public let result: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case deviceType = "device_type"
        case result
        case createdAt = "created_at"
    }

    public init(
        id: String,
        deviceType: String,
        result: String,
        createdAt: String
    ) {
        self.id = id
        self.deviceType = deviceType
        self.result = result
        self.createdAt = createdAt
    }
}

public struct RemoteDeviceRegistration: Equatable, Sendable {
    public let deviceType: String
    public let pushTokenType: String?
    public let pushToken: String?
    public let bundleID: String?
    public let environment: String?

    public init(
        deviceType: String = "ios",
        pushTokenType: String? = nil,
        pushToken: String? = "",
        bundleID: String? = nil,
        environment: String? = nil
    ) {
        self.deviceType = deviceType
        self.pushTokenType = pushTokenType
        self.pushToken = pushToken
        self.bundleID = bundleID
        self.environment = environment
    }












}

public struct RemotePushTokenRetirementResponse: Decodable, Equatable, Sendable {
    public let status: RemotePushTokenRetirementStatus
    public let slot: RemotePushTokenSlot
    public let provider: RemotePushTokenProvider
    public let terminal: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case slot
        case provider
        case terminal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(RemotePushTokenRetirementStatus.self, forKey: .status)
        slot = try container.decode(RemotePushTokenSlot.self, forKey: .slot)
        provider = try container.decode(RemotePushTokenProvider.self, forKey: .provider)
        terminal = try container.decode(Bool.self, forKey: .terminal)
        let expectedSlot: RemotePushTokenSlot = provider == .apns ? .ordinary : .voip
        guard slot == expectedSlot else {
            throw DecodingError.dataCorruptedError(
                forKey: .slot,
                in: container,
                debugDescription: "push token provider and slot must match"
            )
        }
    }

    public init(
        status: RemotePushTokenRetirementStatus,
        slot: RemotePushTokenSlot,
        provider: RemotePushTokenProvider,
        terminal: Bool
    ) {
        self.status = status
        self.slot = slot
        self.provider = provider
        self.terminal = terminal
    }
}

public struct RemoteNotificationTargetResolution: Decodable, Equatable, Sendable {
    public let kind: RemoteNotificationTargetKind
    public let conversationID: String?
    public let systemDestination: String?
    public let messageID: String?
    public let channelSeq: Int64?

    enum CodingKeys: String, CodingKey {
        case kind
        case conversationID = "conversation_id"
        case systemDestination = "system_destination"
        case messageID = "message_id"
        case channelSeq = "channel_seq"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(RemoteNotificationTargetKind.self, forKey: .kind)
        conversationID = try Self.decodeOmittedNonEmptyString(.conversationID, from: container)
        systemDestination = try Self.decodeOmittedNonEmptyString(.systemDestination, from: container)
        messageID = try Self.decodeOmittedNonEmptyString(.messageID, from: container)
        if container.contains(.channelSeq) {
            guard try !container.decodeNil(forKey: .channelSeq) else {
                throw DecodingError.valueNotFound(
                    Int64.self,
                    .init(codingPath: container.codingPath + [CodingKeys.channelSeq], debugDescription: "channel_seq must be omitted instead of null")
                )
            }
            let decoded = try container.decode(Int64.self, forKey: .channelSeq)
            guard decoded > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .channelSeq, in: container, debugDescription: "channel_seq must be positive")
            }
            channelSeq = decoded
        } else {
            channelSeq = nil
        }

        switch kind {
        case .conversation:
            guard conversationID != nil, systemDestination == nil else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "conversation target shape is invalid")
            }
        case .system:
            guard conversationID == nil, systemDestination == "system_notification" else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "system target shape is invalid")
            }
        }
    }

    private static func decodeOmittedNonEmptyString(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        guard try !container.decodeNil(forKey: key) else {
            throw DecodingError.valueNotFound(
                String.self,
                .init(codingPath: container.codingPath + [key], debugDescription: "optional strings must be omitted instead of null")
            )
        }
        let value = try container.decode(String.self, forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "identifier must not be empty")
        }
        return value
    }

    public init(
        kind: RemoteNotificationTargetKind,
        conversationID: String?,
        systemDestination: String?,
        messageID: String?,
        channelSeq: Int64?
    ) {
        self.kind = kind
        self.conversationID = conversationID
        self.systemDestination = systemDestination
        self.messageID = messageID
        self.channelSeq = channelSeq
    }
}

public struct RemoteInboxEntry: Decodable, Sendable {
    public let id: String
    public let kind: String
    public let title: String
    public let summary: String
    public let senderAvatarURL: String
    public let readAt: String?
    public let createdAt: String?
    public let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case category
        case type
        case notificationType = "notification_type"
        case channel
        case title
        case summary
        case senderAvatarURL = "sender_avatar_url"
        case senderAvatar = "sender_avatar"
        case avatarURL = "avatar_url"
        case avatar
        case readAt = "read_at"
        case createdAt = "created_at"
        case payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = [
            try c.decodeIfPresent(String.self, forKey: .kind),
            try c.decodeIfPresent(String.self, forKey: .category),
            try c.decodeIfPresent(String.self, forKey: .type),
            try c.decodeIfPresent(String.self, forKey: .notificationType),
            try c.decodeIfPresent(String.self, forKey: .channel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        senderAvatarURL = try c.decodeIfPresent(String.self, forKey: .senderAvatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .senderAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatar)
            ?? ""
        readAt = try c.decodeIfPresent(String.self, forKey: .readAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        payload = try c.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
    }

    public init(
        id: String,
        kind: String,
        title: String,
        summary: String,
        senderAvatarURL: String,
        readAt: String?,
        createdAt: String?,
        payload: [String: JSONValue]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.senderAvatarURL = senderAvatarURL
        self.readAt = readAt
        self.createdAt = createdAt
        self.payload = payload
    }
}

public struct RemoteSystemInboxReadResponse: Decodable, Sendable {
    public let items: [RemoteInboxEntry]
    public let imReadAck: RemoteIMReadAckTarget?

    enum CodingKeys: String, CodingKey {
        case items
        case imReadAck = "im_read_ack"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteInboxEntry].self, forKey: .items) ?? []
        imReadAck = try c.decodeIfPresent(RemoteIMReadAckTarget.self, forKey: .imReadAck)
    }

    public init(
        items: [RemoteInboxEntry],
        imReadAck: RemoteIMReadAckTarget?
    ) {
        self.items = items
        self.imReadAck = imReadAck
    }
}

public struct RemoteIMReadAckTarget: Decodable, Sendable {
    public let channelID: String
    public let channelType: String
    public let applied: Bool
    public let lastRead: Int64
    public let receipts: [RemoteMessageReceipt]

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
        case applied
        case lastRead = "last_read"
        case receipts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        applied = try c.decodeIfPresent(Bool.self, forKey: .applied) ?? false
        lastRead = try c.decodeIfPresent(Int64.self, forKey: .lastRead) ?? 0
        receipts = try c.decodeIfPresent([RemoteMessageReceipt].self, forKey: .receipts) ?? []
    }

    public init(
        channelID: String,
        channelType: String,
        applied: Bool,
        lastRead: Int64,
        receipts: [RemoteMessageReceipt]
    ) {
        self.channelID = channelID
        self.channelType = channelType
        self.applied = applied
        self.lastRead = lastRead
        self.receipts = receipts
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

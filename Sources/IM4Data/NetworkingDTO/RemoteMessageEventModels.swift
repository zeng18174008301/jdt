// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
import Foundation

public struct RemoteConversationSettingsResponse: Decodable, Sendable {
    public let conversation: RemoteConversation?
}

public struct RemoteExtraResponse: Decodable, Sendable {
    public let extra: RemoteMessageExtra?
	public let message: RemoteMessage?
	public let duplicate: Bool
    public let readReceipts: [RemoteMessageReceipt]

    enum CodingKeys: String, CodingKey {
        case extra
        case messageExtra = "message_extra"
		case message
		case currentMessage = "current_message"
		case duplicate
        case readReceipts = "read_receipts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extra = try container.decodeIfPresent(RemoteMessageExtra.self, forKey: .extra)
            ?? container.decodeIfPresent(RemoteMessageExtra.self, forKey: .messageExtra)
		message = try container.decodeIfPresent(RemoteMessage.self, forKey: .message)
			?? container.decodeIfPresent(RemoteMessage.self, forKey: .currentMessage)
		duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        readReceipts = try container.decodeIfPresent([RemoteMessageReceipt].self, forKey: .readReceipts) ?? []
    }
}

public struct RemoteMessageExtra: Decodable, Sendable {
    public let tenantID: String
    public let messageID: String
    public let channelID: String
    public let channelType: String
    public let channelSeq: Int64
	public let version: Int64
    public let operatorUID: String
    public let extraType: String?
    public let emoji: String
    public let action: String
    public let payload: [String: JSONValue]
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case messageID = "message_id"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
		case version
        case operatorUID = "operator_uid"
        case extraType = "extra_type"
        case emoji
        case action
        case payload
        case createdAt = "created_at"
    }











    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPayload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        payload = decodedPayload
        tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID)
            ?? decodedPayload["tenant_id"]?.stringValue
            ?? ""
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
            ?? decodedPayload["message_id"]?.stringValue
            ?? decodedPayload["msg_id"]?.stringValue
            ?? ""
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID)
            ?? decodedPayload["channel_id"]?.stringValue
            ?? ""
        channelType = try container.decodeIfPresent(String.self, forKey: .channelType)
            ?? decodedPayload["channel_type"]?.stringValue
            ?? ""
        channelSeq = container.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? container.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
            ?? decodedPayload["channel_seq"]?.stringValue.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? decodedPayload["channelSeq"]?.stringValue.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? 0
		version = container.decodeLossyInt64IfPresent(forKey: .version)
			?? decodedPayload["version"]?.stringValue.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
			?? 0
        operatorUID = try container.decodeIfPresent(String.self, forKey: .operatorUID)
            ?? decodedPayload["operator_uid"]?.stringValue
            ?? decodedPayload["actor_uid"]?.stringValue
            ?? decodedPayload["from_uid"]?.stringValue
            ?? decodedPayload["sender_uid"]?.stringValue
            ?? decodedPayload["user_id"]?.stringValue
            ?? ""
        extraType = try container.decodeIfPresent(String.self, forKey: .extraType)
            ?? decodedPayload["extra_type"]?.stringValue
            ?? decodedPayload["type"]?.stringValue
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
            ?? decodedPayload["emoji"]?.stringValue
            ?? decodedPayload["reaction"]?.stringValue
            ?? ""
        action = try container.decodeIfPresent(String.self, forKey: .action)
            ?? decodedPayload["action"]?.stringValue
            ?? "add"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

public struct RemoteConversationReadWatermark: Decodable, Sendable, Equatable {
    public let eventID: String
    public let tenantID: String
    public let imUID: String
    public let appID: String
    public let channelID: String
    public let channelType: String
    public let lastReadSeq: Int64
    public let occurredAt: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventIDCamel = "eventId"
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case imUID = "im_uid"
        case imUIDCamel = "imUID"
        case appID = "app_id"
        case appIDCamel = "appId"
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case lastReadSeq = "last_read_seq"
        case lastReadSeqCamel = "lastReadSeq"
        case occurredAt = "occurred_at"
        case occurredAtCamel = "occurredAt"
    }

    public init(
        eventID: String,
        tenantID: String,
        imUID: String,
        appID: String,
        channelID: String,
        channelType: String,
        lastReadSeq: Int64,
        occurredAt: String
    ) {
        self.eventID = eventID
        self.tenantID = tenantID
        self.imUID = imUID
        self.appID = appID
        self.channelID = channelID
        self.channelType = channelType
        self.lastReadSeq = lastReadSeq
        self.occurredAt = occurredAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
            ?? c.decodeIfPresent(String.self, forKey: .eventIDCamel)
            ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .imUIDCamel)
            ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
            ?? c.decodeIfPresent(String.self, forKey: .channelIDCamel)
            ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType)
            ?? c.decodeIfPresent(String.self, forKey: .channelTypeCamel)
            ?? ""
        lastReadSeq = c.decodeLossyInt64IfPresent(forKey: .lastReadSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .lastReadSeqCamel)
            ?? 0
        occurredAt = try c.decodeIfPresent(String.self, forKey: .occurredAt)
            ?? c.decodeIfPresent(String.self, forKey: .occurredAtCamel)
            ?? ""
    }
}
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

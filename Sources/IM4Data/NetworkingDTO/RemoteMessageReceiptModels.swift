// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
import Foundation

public struct RemoteReadAckResponse: Decodable, Sendable {
    public static let empty = RemoteReadAckResponse(
        channelID: "",
        channelType: "",
        lastReadSeq: 0,
        readReceipts: []
    )

    public let channelID: String
    public let channelType: String
    public let lastReadSeq: Int64?
    public let readReceipts: [RemoteMessageReceipt]

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
        case lastReadSeq = "last_read_seq"
        case readReceipts = "read_receipts"
    }

    public init(channelID: String, channelType: String, lastReadSeq: Int64, readReceipts: [RemoteMessageReceipt]) {
        self.channelID = channelID
        self.channelType = channelType
        self.lastReadSeq = lastReadSeq
        self.readReceipts = readReceipts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        lastReadSeq = try c.decodeIfPresent(Int64.self, forKey: .lastReadSeq) ?? 0
        readReceipts = try c.decodeIfPresent([RemoteMessageReceipt].self, forKey: .readReceipts) ?? []
    }
}

public struct RemoteMessageReadReceiptResponse: Decodable, Sendable {
    public let read: Bool
    public let readCount: Int?
    public let unreadCount: Int?
    public let memberCount: Int?
    public let targetCount: Int?
    public let canViewDetails: Bool
    public let readReceiptsEnabled: Bool?
    public let featureStatus: String
    public let featureMessage: String
    public let items: [RemoteMessageReceipt]
    public let unreadItems: [RemoteMessageReadParticipant]
    public let reactions: [RemoteMessageReactionReceipt]



    enum CodingKeys: String, CodingKey {
        case read
        case readCount = "read_count"
        case unreadCount = "unread_count"
        case memberCount = "member_count"
        case targetCount = "receipt_target_count"
        case canViewDetails = "can_view_details"
        case readReceiptsEnabled = "read_receipts_enabled"
        case featureStatus = "feature_status"
        case featureMessage = "feature_message"
        case items
        case unreadItems = "unread_items"
        case reactions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        read = try container.decodeIfPresent(Bool.self, forKey: .read) ?? false
        readCount = try container.decodeIfPresent(Int.self, forKey: .readCount)
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount)
        memberCount = try container.decodeIfPresent(Int.self, forKey: .memberCount)
        targetCount = try container.decodeIfPresent(Int.self, forKey: .targetCount)
        // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023: explicit denial wins; reactions never grant receipt access.
        let explicitCanViewDetails = try container.decodeIfPresent(Bool.self, forKey: .canViewDetails)
        readReceiptsEnabled = container.decodeLossyBoolIfPresent(forKey: .readReceiptsEnabled)
        featureStatus = try container.decodeIfPresent(String.self, forKey: .featureStatus) ?? ""
        featureMessage = try container.decodeIfPresent(String.self, forKey: .featureMessage) ?? ""
        items = try container.decodeIfPresent([RemoteMessageReceipt].self, forKey: .items) ?? []
        unreadItems = try container.decodeIfPresent([RemoteMessageReadParticipant].self, forKey: .unreadItems) ?? []
        reactions = try container.decodeIfPresent([RemoteMessageReactionReceipt].self, forKey: .reactions) ?? []
        canViewDetails = explicitCanViewDetails ?? (readCount != nil || unreadCount != nil
            || memberCount != nil || targetCount != nil || !items.isEmpty || !unreadItems.isEmpty)
    }
}

public struct RemoteMessageReadParticipant: Decodable, Sendable {
    public let imUID: String
    public let displayName: String
    public let nickname: String
    public let remark: String
    public let readAt: String?
    public let deviceID: String

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case displayName = "display_name"
        case nickname
        case remark
        case readAt = "read_at"
        case readAtCamel = "readAt"
        case deviceID = "device_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try container.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        remark = try container.decodeIfPresent(String.self, forKey: .remark) ?? ""
        readAt = container.decodeLossyStringIfPresent(forKey: .readAt)
            ?? container.decodeLossyStringIfPresent(forKey: .readAtCamel)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
    }
}

public struct RemoteMessageReceipt: Decodable, Sendable {
    public let messageID: String
    public let channelID: String
    public let channelType: String
    public let fromUID: String
    public let imUID: String
    public let deviceID: String
    public let receiptType: String
    public let channelSeq: Int64
    public let createdAt: String?
    public let displayName: String
    public let nickname: String
    public let remark: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case fromUID = "from_uid"
        case imUID = "im_uid"
        case deviceID = "device_id"
        case receiptType = "receipt_type"
        case channelSeq = "channel_seq"
        case createdAt = "created_at"
        case displayName = "display_name"
        case nickname
        case remark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try container.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        fromUID = try container.decodeIfPresent(String.self, forKey: .fromUID) ?? ""
        imUID = try container.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        receiptType = try container.decodeIfPresent(String.self, forKey: .receiptType) ?? ""
        channelSeq = try container.decodeIfPresent(Int64.self, forKey: .channelSeq) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        remark = try container.decodeIfPresent(String.self, forKey: .remark) ?? ""
    }
}

public struct RemoteMessageReceiptSyncResult: Decodable, Sendable {
    public let items: [RemoteMessageReceipt]
    public let readReceiptsEnabled: Bool?
    public let featureStatus: String
    public let readUpToSeq: Int64?
    public let canViewReadReceiptDetails: Bool?

    enum CodingKeys: String, CodingKey {
        case items
        case readReceiptsEnabled = "read_receipts_enabled"
        case featureStatus = "feature_status"
        case readUpToSeq = "read_up_to_seq"
        case canViewReadReceiptDetails = "can_view_read_receipt_details"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([RemoteMessageReceipt].self, forKey: .items) ?? []
        readReceiptsEnabled = container.decodeLossyBoolIfPresent(forKey: .readReceiptsEnabled)
        featureStatus = try container.decodeIfPresent(String.self, forKey: .featureStatus) ?? ""
        // An absent/malformed scalar must not discard otherwise valid receipt items.
        let sequence = try? container.decode(Int64.self, forKey: .readUpToSeq)
        readUpToSeq = sequence.flatMap { $0 >= 0 ? $0 : nil }
        canViewReadReceiptDetails = container.decodeLossyBoolIfPresent(forKey: .canViewReadReceiptDetails)
    }
}

public struct RemoteMessageReactionReceipt: Decodable, Sendable {
    public let tenantID: String
    public let messageID: String
    public let channelID: String
    public let channelType: String
    public let operatorUID: String
    public let emoji: String
    public let action: String
    public let payload: [String: JSONValue]
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case messageID = "message_id"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case operatorUID = "operator_uid"
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
        operatorUID = try container.decodeIfPresent(String.self, forKey: .operatorUID)
            ?? decodedPayload["operator_uid"]?.stringValue
            ?? decodedPayload["actor_uid"]?.stringValue
            ?? decodedPayload["from_uid"]?.stringValue
            ?? decodedPayload["sender_uid"]?.stringValue
            ?? decodedPayload["user_id"]?.stringValue
            ?? ""
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
            ?? decodedPayload["emoji"]?.stringValue
            ?? decodedPayload["reaction"]?.stringValue
            ?? ""
        action = try container.decodeIfPresent(String.self, forKey: .action)
            ?? decodedPayload["action"]?.stringValue
            ?? "add"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? decodedPayload["created_at"]?.stringValue
            ?? decodedPayload["createdAt"]?.stringValue
            ?? decodedPayload["updated_at"]?.stringValue
            ?? decodedPayload["updatedAt"]?.stringValue
    }
}
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

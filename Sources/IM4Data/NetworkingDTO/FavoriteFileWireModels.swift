import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteFavoriteAssetsResponse: Decodable, Equatable, Sendable {
    public let items: [RemoteFavoriteAssetItem]
    public let nextCursor: String
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
        case hasMore = "has_more"
        case hasMoreCamel = "hasMore"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteFavoriteAssetItem].self, forKey: .items) ?? []
        let snakeCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        let camelCursor = try c.decodeIfPresent(String.self, forKey: .nextCursorCamel)
        nextCursor = snakeCursor ?? camelCursor ?? ""
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreCamel)
            ?? false
    }

    public init(
        items: [RemoteFavoriteAssetItem],
        nextCursor: String,
        hasMore: Bool
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct RemoteFavoriteAssetItem: Decodable, Equatable, Sendable {
    public let tenantID: String
    public let messageID: String
    public let channelID: String
    public let channelType: String
    public let channelSeq: Int64
    public let fromUID: String
    public let senderUID: String
    public let senderUserID: String
    public let fromUserID: String
    public let contentType: String
    public let payload: [String: JSONValue]
    public let status: String
    public let createdAt: String?
    public let favoritedAt: String?
    public let favoriteVersion: Int64
    public let category: String
    public let displayText: String
    public let cursor: String



    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case messageID = "message_id"
        case messageIDCamel = "messageId"
        case id
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case seq
        case fromUID = "from_uid"
        case fromUIDCamel = "fromUid"
        case senderUID = "sender_uid"
        case senderUIDCamel = "senderUid"
        case senderUserID = "sender_user_id"
        case senderUserIDCamel = "senderUserId"
        case fromUserID = "from_user_id"
        case fromUserIDCamel = "fromUserId"
        case contentType = "content_type"
        case contentTypeCamel = "contentType"
        case payload
        case status
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case favoritedAt = "favorited_at"
        case favoritedAtCamel = "favoritedAt"
        case favoriteVersion = "favorite_version"
        case favoriteVersionCamel = "favoriteVersion"
        case version
        case category
        case displayText = "display_text"
        case displayTextCamel = "displayText"
        case cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPayload = try c.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        payload = decodedPayload
        tenantID = Self.decodeString(from: c, keys: [.tenantID, .tenantIDCamel], fallback: decodedPayload["tenant_id"]?.stringValue)
        messageID = Self.decodeString(from: c, keys: [.messageID, .messageIDCamel, .id], fallback: decodedPayload["message_id"]?.stringValue)
        channelID = Self.decodeString(from: c, keys: [.channelID, .channelIDCamel], fallback: decodedPayload["channel_id"]?.stringValue)
        channelType = Self.decodeString(from: c, keys: [.channelType, .channelTypeCamel], fallback: decodedPayload["channel_type"]?.stringValue)
        channelSeq = c.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
            ?? c.decodeLossyInt64IfPresent(forKey: .seq)
            ?? 0
        fromUID = Self.decodeString(from: c, keys: [.fromUID, .fromUIDCamel], fallback: decodedPayload["from_uid"]?.stringValue)
        senderUID = Self.decodeString(from: c, keys: [.senderUID, .senderUIDCamel], fallback: decodedPayload["sender_uid"]?.stringValue)
        senderUserID = Self.decodeString(from: c, keys: [.senderUserID, .senderUserIDCamel], fallback: decodedPayload["sender_user_id"]?.stringValue)
        fromUserID = Self.decodeString(from: c, keys: [.fromUserID, .fromUserIDCamel], fallback: decodedPayload["from_user_id"]?.stringValue)
        contentType = Self.decodeString(from: c, keys: [.contentType, .contentTypeCamel], fallback: decodedPayload["content_type"]?.stringValue)
        status = Self.decodeString(from: c, keys: [.status], fallback: decodedPayload["status"]?.stringValue)
        createdAt = Self.decodeOptionalString(from: c, keys: [.createdAt, .createdAtCamel])
        favoritedAt = Self.decodeOptionalString(from: c, keys: [.favoritedAt, .favoritedAtCamel])
        favoriteVersion = c.decodeLossyInt64IfPresent(forKey: .favoriteVersion)
            ?? c.decodeLossyInt64IfPresent(forKey: .favoriteVersionCamel)
            ?? c.decodeLossyInt64IfPresent(forKey: .version)
            ?? 0
        category = Self.decodeString(from: c, keys: [.category], fallback: decodedPayload["category"]?.stringValue)
        displayText = Self.decodeString(from: c, keys: [.displayText, .displayTextCamel], fallback: decodedPayload["display_text"]?.stringValue)
        cursor = Self.decodeString(from: c, keys: [.cursor], fallback: decodedPayload["cursor"]?.stringValue)
    }

    private static func decodeString(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys], fallback: String? = nil) -> String {
        decodeOptionalString(from: container, keys: keys) ?? fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func decodeOptionalString(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    public init(
        tenantID: String,
        messageID: String,
        channelID: String,
        channelType: String,
        channelSeq: Int64,
        fromUID: String,
        senderUID: String,
        senderUserID: String,
        fromUserID: String,
        contentType: String,
        payload: [String: JSONValue],
        status: String,
        createdAt: String?,
        favoritedAt: String?,
        favoriteVersion: Int64,
        category: String,
        displayText: String,
        cursor: String
    ) {
        self.tenantID = tenantID
        self.messageID = messageID
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.fromUID = fromUID
        self.senderUID = senderUID
        self.senderUserID = senderUserID
        self.fromUserID = fromUserID
        self.contentType = contentType
        self.payload = payload
        self.status = status
        self.createdAt = createdAt
        self.favoritedAt = favoritedAt
        self.favoriteVersion = favoriteVersion
        self.category = category
        self.displayText = displayText
        self.cursor = cursor
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

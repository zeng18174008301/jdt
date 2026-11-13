// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
import Foundation
import IM4Domain

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端消息分页结果标记为可跨任务传递的值快照
public struct RemoteMessageSyncResult: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    public let items: [RemoteMessage]
    public let hasExplicitItems: Bool // WDT_IOS1_HTTP_ROUTE_V5_20261113
    public let hasMore: Bool?
    public let hasMoreBefore: Bool?
    public let hasMoreAfter: Bool?
    public let nextAfterSeq: Int64?
    public let nextBeforeSeq: Int64? // WDT_IOS1_HTTP_ROUTE_V5_20261113
    public let historyVisibleFromSeq: Int64
    public let historyLimited: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case hasMoreCamel = "hasMore"
        case hasMoreBefore = "has_more_before"
        case hasMoreBeforeCamel = "hasMoreBefore"
        case hasMoreAfter = "has_more_after"
        case hasMoreAfterCamel = "hasMoreAfter"
        case nextAfterSeq = "next_after_seq"
        case nextAfterSeqCamel = "nextAfterSeq"
        case nextBeforeSeq = "next_before_seq" // WDT_IOS1_HTTP_ROUTE_V5_20261113
        case historyVisibleFromSeq = "history_visible_from_seq"
        case historyVisibleFromSeqCamel = "historyVisibleFromSeq"
        case historyLimited = "history_limited"
        case historyLimitedCamel = "historyLimited"
    }

    public init(
        items: [RemoteMessage],
        hasMore: Bool? = nil,
        hasMoreBefore: Bool? = nil,
        hasMoreAfter: Bool? = nil,
        nextAfterSeq: Int64? = nil,
        historyVisibleFromSeq: Int64 = 1,
        historyLimited: Bool = false,
        nextBeforeSeq: Int64? = nil // WDT_IOS1_HTTP_ROUTE_V5_20261113
    ) {
        self.items = items
        hasExplicitItems = true // WDT_IOS1_HTTP_ROUTE_V5_20261113
        self.hasMore = hasMore
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.nextAfterSeq = nextAfterSeq
        self.nextBeforeSeq = nextBeforeSeq // WDT_IOS1_HTTP_ROUTE_V5_20261113
        self.historyVisibleFromSeq = max(1, historyVisibleFromSeq)
        self.historyLimited = historyLimited
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        let decodedItems = try c.decodeIfPresent([RemoteMessage].self, forKey: .items)
        hasExplicitItems = decodedItems != nil
        items = decodedItems ?? []
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreCamel)
        hasMoreBefore = c.decodeLossyBoolIfPresent(forKey: .hasMoreBefore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreBeforeCamel)
        hasMoreAfter = c.decodeLossyBoolIfPresent(forKey: .hasMoreAfter)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreAfterCamel)
        nextAfterSeq = c.decodeLossyInt64IfPresent(forKey: .nextAfterSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .nextAfterSeqCamel)
        nextBeforeSeq = c.decodeLossyInt64IfPresent(forKey: .nextBeforeSeq) // WDT_IOS1_HTTP_ROUTE_V5_20261113
        historyVisibleFromSeq = max(
            1,
            c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeq)
                ?? c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeqCamel)
                ?? 1
        )
        historyLimited = c.decodeLossyBoolIfPresent(forKey: .historyLimited)
            ?? c.decodeLossyBoolIfPresent(forKey: .historyLimitedCamel)
            ?? false
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端消息模型标记为可跨任务传递的值快照
public struct RemoteMessage: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    public let messageID: String
    public let clientMsgNo: String?
    public let channelID: String
    public let channelType: String
    public let channelSeq: Int64
    public let fromUID: String
    public let senderProvenance: BatchForwardSenderProvenance
    public let senderDisplayName: String
    public let senderAvatar: String
    public let senderAvatarVersion: String
    public let senderAvatarUpdatedAt: String
    public let contentType: String
    public let payload: [String: JSONValue]
    public let quote: String?
    public let status: String
    public let readStatus: String?
    public let readCount: Int?
    public let readAt: String?
    public let createdAt: String?
    public let isEdited: Bool
	public let editRevision: Int64

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case id
        case clientMsgNo = "client_msg_no"
        case clientMessageID = "client_message_id"
        case clientID = "client_id"
        case clientMsgID = "client_msg_id"
        case localID = "local_id"
        case localIDCamel = "localId"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case channelSeq = "channel_seq"
        case seq
        case fromUID = "from_uid"
        case senderUID = "sender_uid"
        case senderUserID = "sender_user_id"
        case fromUserID = "from_user_id"
        case senderName = "sender_name"
        case senderDisplayName = "sender_display_name"
        case senderNickname = "sender_nickname"
        case fromName = "from_name"
        case fromNickname = "from_nickname"
        case displayName = "display_name"
        case nickname
        case senderAvatar = "sender_avatar"
        case senderAvatarURL = "sender_avatar_url"
        case fromAvatar = "from_avatar"
        case avatar
        case senderAvatarVersion = "sender_avatar_version"
        case senderAvatarVersionCamel = "senderAvatarVersion"
        case fromAvatarVersion = "from_avatar_version"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case senderAvatarUpdatedAt = "sender_avatar_updated_at"
        case senderAvatarUpdatedAtCamel = "senderAvatarUpdatedAt"
        case fromAvatarUpdatedAt = "from_avatar_updated_at"
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case contentType = "content_type"
        case payload
        case quote
        case quoteText = "quote_text"
        case quotedText = "quoted_text"
        case replyQuote = "reply_quote"
        case replyTo = "reply_to"
        case replyToCamel = "replyTo"
        case replyMessage = "reply_message"
        case replyMessageCamel = "replyMessage"
        case quotedMessage = "quoted_message"
        case quoted
        case reply
        case messageExtra = "message_extra"
        case status
        case readStatus = "read_status"
        case readCount = "read_count"
        case readAt = "read_at"
        case createdAt = "created_at"
        case isEdited = "is_edited"
        case edited
        case editedAt = "edited_at"
        case editedAtCamel = "editedAt"
		case editRevision = "edit_revision"
		case editRevisionCamel = "editRevision"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decodedPayload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        for (payloadKey, codingKey) in [
            ("reply_to", CodingKeys.replyTo),
            ("replyTo", .replyToCamel),
            ("reply_message", .replyMessage),
            ("replyMessage", .replyMessageCamel),
            ("quoted_message", .quotedMessage),
            ("quoted", .quoted),
            ("reply", .reply),
            ("message_extra", .messageExtra)
        ] {
            if decodedPayload[payloadKey] == nil,
               let topLevelValue = try container.decodeIfPresent(JSONValue.self, forKey: codingKey) {
                decodedPayload[payloadKey] = topLevelValue
            }
        }
        payload = decodedPayload
        messageID = Self.decodeString(from: container, keys: [.messageID, .id])
        clientMsgNo = Self.decodeOptionalString(from: container, keys: [.clientMsgNo, .clientMessageID, .clientID, .clientMsgID, .localID, .localIDCamel])
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["client_msg_no", "client_message_id", "client_id", "client_msg_id", "local_id", "localId"]
            )
        channelID = Self.decodeString(from: container, keys: [.channelID], fallback: payload["channel_id"]?.stringValue)
        channelType = Self.decodeString(from: container, keys: [.channelType], fallback: payload["channel_type"]?.stringValue)
        channelSeq = Self.decodeInt64(from: container, keys: [.channelSeq, .seq])
        let authoritativeSenderUID = Self.decodeOptionalString(
            from: container,
            keys: [.fromUID, .senderUID, .senderUserID, .fromUserID]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSenderUID = [
            payload["from_uid"]?.stringValue,
            payload["sender_uid"]?.stringValue,
            payload["sender_user_id"]?.stringValue,
            payload["from_user_id"]?.stringValue
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let authoritativeSenderUID, !authoritativeSenderUID.isEmpty {
            fromUID = authoritativeSenderUID
            senderProvenance = .authoritativeStored
        } else {
            fromUID = fallbackSenderUID ?? ""
            senderProvenance = fallbackSenderUID == nil ? .unknown : .clientSupplied
        }
        senderDisplayName = Self.decodeOptionalString(
            from: container,
            keys: [.senderDisplayName, .senderName, .senderNickname, .fromName, .fromNickname, .displayName, .nickname]
        )
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["sender_display_name", "sender_name", "sender_nickname", "from_name", "from_nickname", "display_name", "nickname", "user_name"]
            )
            ?? ""
        senderAvatar = Self.decodeOptionalString(
            from: container,
            keys: [.senderAvatar, .senderAvatarURL, .fromAvatar, .avatar]
        )
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["sender_avatar", "sender_avatar_url", "from_avatar", "avatar", "avatar_url"]
            )
            ?? ""
        senderAvatarVersion = Self.decodeOptionalString(
            from: container,
            keys: [.senderAvatarVersion, .senderAvatarVersionCamel, .fromAvatarVersion, .avatarVersion, .avatarVersionCamel, .version]
        )
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["sender_avatar_version", "senderAvatarVersion", "from_avatar_version", "avatar_version", "avatarVersion", "version"]
            )
            ?? ""
        senderAvatarUpdatedAt = Self.decodeOptionalString(
            from: container,
            keys: [.senderAvatarUpdatedAt, .senderAvatarUpdatedAtCamel, .fromAvatarUpdatedAt, .avatarUpdatedAt, .avatarUpdatedAtCamel, .updatedAt]
        )
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["sender_avatar_updated_at", "senderAvatarUpdatedAt", "from_avatar_updated_at", "avatar_updated_at", "avatarUpdatedAt", "updated_at", "updatedAt"]
            )
            ?? ""
        contentType = Self.decodeString(from: container, keys: [.contentType], fallback: payload["content_type"]?.stringValue)
        quote = Self.decodeOptionalString(from: container, keys: [.quote, .quoteText, .quotedText, .replyQuote])
        status = Self.decodeString(from: container, keys: [.status])
        readStatus = Self.decodeOptionalString(from: container, keys: [.readStatus])
        readCount = try container.decodeIfPresent(Int.self, forKey: .readCount)
        readAt = Self.decodeOptionalString(from: container, keys: [.readAt])
        createdAt = Self.decodeOptionalString(from: container, keys: [.createdAt])
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isEdited = normalizedStatus == "edited"
            || Self.decodeOptionalBool(from: container, keys: [.isEdited, .edited]) == true
            || Self.decodeOptionalString(from: container, keys: [.editedAt, .editedAtCamel]) != nil
            || payload["is_edited"]?.boolValue == true
            || payload["edited"]?.boolValue == true
            || Self.hasNonEmptyString(in: payload, keys: ["edited_at", "editedAt"])
		let topLevelEditRevision = Self.decodeInt64(from: container, keys: [.editRevision, .editRevisionCamel])
		editRevision = topLevelEditRevision > 0
			? topLevelEditRevision
			: Int64(payload["edit_revision"]?.stringValue ?? payload["editRevision"]?.stringValue ?? "") ?? 0
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

    private static func decodeOptionalString(from payload: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func decodeOptionalBool(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Bool? {
        for key in keys {
            do {
                if let value = try container.decodeIfPresent(Bool.self, forKey: key) {
                    return value
                }
                if let value = try container.decodeIfPresent(Int.self, forKey: key) {
                    return value != 0
                }
                if let value = try container.decodeIfPresent(String.self, forKey: key) {
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if ["true", "1", "yes"].contains(normalized) { return true }
                    if ["false", "0", "no"].contains(normalized) { return false }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private static func hasNonEmptyString(in payload: [String: JSONValue], keys: [String]) -> Bool {
        decodeOptionalString(from: payload, keys: keys) != nil
    }

    private static func decodeInt64(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int64 {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Int64(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return 0
    }
}
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

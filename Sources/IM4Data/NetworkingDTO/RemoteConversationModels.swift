// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
import Foundation

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话分页结果标记为可跨任务传递的值快照
public struct RemoteConversationPage: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    public let conversations: [RemoteConversation]
    public let hasMore: Bool
    public let nextCursor: String?
    public let snapshotID: String?
    public let snapshotVersion: Int64?

    public init(conversations: [RemoteConversation], hasMore: Bool, nextCursor: String?, snapshotID: String?, snapshotVersion: Int64?) {
        self.conversations = conversations
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.snapshotID = snapshotID
        self.snapshotVersion = snapshotVersion
    }

    enum CodingKeys: String, CodingKey {
        case conversations
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case snapshotID = "snapshot_id"
        case snapshotVersion = "snapshot_version"
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话同步结果标记为可跨任务传递的值快照
public struct RemoteConversationSyncData: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    public let version: Int64
    public let conversations: [RemoteConversation]
    public let removedConversations: [RemoteRemovedConversation]

    enum CodingKeys: String, CodingKey {
        case version
        case conversations
        case removedConversations = "removed_conversations"
        case removedConversationsCamel = "removedConversations"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decodeLossyInt64IfPresent(forKey: .version) ?? 0
        conversations = try c.decodeIfPresent([RemoteConversation].self, forKey: .conversations) ?? []
        removedConversations = try c.decodeIfPresent([RemoteRemovedConversation].self, forKey: .removedConversations)
            ?? c.decodeIfPresent([RemoteRemovedConversation].self, forKey: .removedConversationsCamel)
            ?? []
    }
}

public struct RemoteRemovedConversation: Decodable, Sendable, Equatable {
    public let tenantID: String
    public let channelID: String
    public let channelType: String
    public let reason: String
    public let version: Int64
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case id
        case conversationID = "conversation_id"
        case conversationIDCamel = "conversationId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case type
        case reason
        case version
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
            ?? c.decodeIfPresent(String.self, forKey: .channelIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .conversationID)
            ?? c.decodeIfPresent(String.self, forKey: .conversationIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType)
            ?? c.decodeIfPresent(String.self, forKey: .channelTypeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .type)
            ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        version = c.decodeLossyInt64IfPresent(forKey: .version) ?? 0
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel)
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：置顶消息响应标记为可跨任务传递的值快照
public struct RemotePinnedMessagesResponse: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    public let items: [RemoteMessage]
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话模型标记为可跨任务传递的值快照
public struct RemoteConversation: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    public let channelID: String
    public let channelType: String
    public let memberCount: Int?
    public let unreadCount: Int
    public let unreadReactionCount: Int
    public let hasReactionUnread: Bool
    public let lastMsgSeq: Int64
    public let lastReadSeq: Int64
    public let firstUnreadSeq: Int64
    public let firstUnreadMessageID: String
    public let unreadAnchorSeq: Int64
    public let unreadAnchorState: String
    public let version: Int64
    public let stick: Bool
    public let mute: Bool
    public let muteProvided: Bool
    public let lastActivityAt: String?
    public let lastMessageAt: String?
    public let updatedAt: String?
    public let displayName: String
    public let avatar: String
    public let avatarProvided: Bool
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let lastMessage: RemoteMessage?
    public let pinnedMessages: [RemoteMessage]
    public let pinnedMessagesProvided: Bool
    public let hasMention: Bool
    public let mentionCount: Int
    public let mentionSummary: RemoteMentionSummary?
    public let historyVisibleFromSeq: Int64
    public let historyLimited: Bool

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case membersCount = "members_count"
        case membersCountCamel = "membersCount"
        case total
        case unreadCount = "unread_count"
        case unreadReactionCount = "unread_reaction_count"
        case hasReactionUnread = "has_reaction_unread"
        case lastMsgSeq = "last_msg_seq"
        case lastReadSeq = "last_read_seq"
        case lastRead = "last_read"
        case firstUnreadSeq = "first_unread_seq"
        case firstUnreadMessageID = "first_unread_message_id"
        case unreadAnchorSeq = "unread_anchor_seq"
        case unreadAnchorState = "unread_anchor_state"
        case version
        case pinned
        case stick
        case sticky
        case top
        case isPinned = "is_pinned"
        case isPinnedCamel = "isPinned"
        case isStick = "is_stick"
        case isStickCamel = "isStick"
        case isSticky = "is_sticky"
        case isStickyCamel = "isSticky"
        case isTop = "is_top"
        case isTopCamel = "isTop"
        case mute
        case muted
        case dnd
        case isMuted = "is_muted"
        case isMutedCamel = "isMuted"
        case doNotDisturb = "do_not_disturb"
        case doNotDisturbCamel = "doNotDisturb"
        case lastActivityAt = "last_activity_at"
        case lastMessageAt = "last_message_at"
        case updatedAt = "updated_at"
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case name
        case title
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case lastMessage = "last_message"
        case pinnedMessages = "pinned_messages"
        case hasMention = "has_mention"
        case mentionCount = "mention_count"
        case mentionSummary = "mention_summary"
        case historyVisibleFromSeq = "history_visible_from_seq"
        case historyVisibleFromSeqCamel = "historyVisibleFromSeq"
        case historyLimited = "history_limited"
        case historyLimitedCamel = "historyLimited"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try container.decodeIfPresent(String.self, forKey: .channelType) ?? "direct"
        memberCount = container.decodeLossyIntIfPresent(forKey: .memberCount)
            ?? container.decodeLossyIntIfPresent(forKey: .memberCountCamel)
            ?? container.decodeLossyIntIfPresent(forKey: .membersCount)
            ?? container.decodeLossyIntIfPresent(forKey: .membersCountCamel)
            ?? container.decodeLossyIntIfPresent(forKey: .total)
        unreadCount = max(0, try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0)
        unreadReactionCount = max(0, try container.decodeIfPresent(Int.self, forKey: .unreadReactionCount) ?? 0)
        hasReactionUnread = Self.decodeHasReactionUnread(from: container, fallback: unreadReactionCount > 0)
        lastMsgSeq = try container.decodeIfPresent(Int64.self, forKey: .lastMsgSeq) ?? 0
        lastReadSeq = max(
            try container.decodeIfPresent(Int64.self, forKey: .lastReadSeq) ?? 0,
            try container.decodeIfPresent(Int64.self, forKey: .lastRead) ?? 0
        )
        firstUnreadSeq = max(0, try container.decodeIfPresent(Int64.self, forKey: .firstUnreadSeq) ?? 0)
        firstUnreadMessageID = try container.decodeIfPresent(String.self, forKey: .firstUnreadMessageID) ?? ""
        unreadAnchorSeq = max(0, try container.decodeIfPresent(Int64.self, forKey: .unreadAnchorSeq) ?? firstUnreadSeq)
        unreadAnchorState = try container.decodeIfPresent(String.self, forKey: .unreadAnchorState) ?? (firstUnreadSeq > 0 ? "ready" : "none")
        version = try container.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        stick = Self.decodePinnedState(from: container)
        mute = Self.decodeMutedState(from: container)
        muteProvided = Self.hasMutedStateField(in: container)
        lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt)
        lastMessageAt = try container.decodeIfPresent(String.self, forKey: .lastMessageAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? ""
        avatarProvided = container.contains(.avatar)
            || container.contains(.avatarURL)
            || container.contains(.avatarURLCamel)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
            ?? container.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? container.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try container.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? container.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? ""
        avatarUpdatedAt = try container.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? ""
        lastMessage = try container.decodeIfPresent(RemoteMessage.self, forKey: .lastMessage)
        pinnedMessages = try container.decodeIfPresent([RemoteMessage].self, forKey: .pinnedMessages) ?? []
        pinnedMessagesProvided = container.contains(.pinnedMessages)
        hasMention = try container.decodeIfPresent(Bool.self, forKey: .hasMention) ?? false
        mentionCount = max(0, try container.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0)
        mentionSummary = try container.decodeIfPresent(RemoteMentionSummary.self, forKey: .mentionSummary)
        historyVisibleFromSeq = max(
            1,
            container.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeq)
                ?? container.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeqCamel)
                ?? 1
        )
        historyLimited = container.decodeLossyBoolIfPresent(forKey: .historyLimited)
            ?? container.decodeLossyBoolIfPresent(forKey: .historyLimitedCamel)
            ?? false
    }

    private static func decodePinnedState(from container: KeyedDecodingContainer<CodingKeys>) -> Bool {
        [
            .pinned,
            .stick,
            .sticky,
            .top,
            .isPinned,
            .isPinnedCamel,
            .isStick,
            .isStickCamel,
            .isSticky,
            .isStickyCamel,
            .isTop,
            .isTopCamel
        ]
        .contains { container.decodeLossyBoolIfPresent(forKey: $0) == true }
    }

    private static func decodeMutedState(from container: KeyedDecodingContainer<CodingKeys>) -> Bool {
        [
            .mute,
            .muted,
            .dnd,
            .isMuted,
            .isMutedCamel,
            .doNotDisturb,
            .doNotDisturbCamel
        ]
        .contains { container.decodeLossyBoolIfPresent(forKey: $0) == true }
    }

    private static func hasMutedStateField(in container: KeyedDecodingContainer<CodingKeys>) -> Bool {
        [
            .mute,
            .muted,
            .dnd,
            .isMuted,
            .isMutedCamel,
            .doNotDisturb,
            .doNotDisturbCamel
        ]
        .contains { container.contains($0) }
    }

    private static func decodeHasReactionUnread(from container: KeyedDecodingContainer<CodingKeys>, fallback: Bool) -> Bool {
        if let boolValue = try? container.decode(Bool.self, forKey: .hasReactionUnread) {
            return boolValue
        }
        if let intValue = try? container.decode(Int.self, forKey: .hasReactionUnread) {
            return intValue > 0
        }
        if let stringValue = try? container.decode(String.self, forKey: .hasReactionUnread) {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "y"].contains(normalized)
        }
        return fallback
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端 mention 摘要标记为可跨任务传递的值快照
public struct RemoteMentionSummary: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    public let type: String
    public let text: String
    public let messageID: String
    public let channelSeq: Int64

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case messageID = "message_id"
        case channelSeq = "channel_seq"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        channelSeq = try container.decodeIfPresent(Int64.self, forKey: .channelSeq) ?? 0
    }
}
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// A detached value used by a synchronous reducer, persistence or explicit reader.
// ConversationStore retains metadata only; message windows have one scoped owner.
@dynamicMemberLookup
public struct ConversationMessageSnapshot: Identifiable, Hashable, Sendable {
    public var conversation: Conversation
    public var messages: [ChatMessage]

    public var id: String { conversation.id }
    public var withoutMessages: Conversation { conversation }

    public init(conversation: Conversation, messages: [ChatMessage]) {
        self.conversation = conversation
        self.messages = messages
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<Conversation, Value>) -> Value {
        conversation[keyPath: keyPath]
    }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<Conversation, Value>) -> Value {
        get { conversation[keyPath: keyPath] }
        set { conversation[keyPath: keyPath] = newValue }
    }

    public init(
        id: String,
        title: String,
        subtitle: String,
        kind: ConversationKind,
        lastMessage: String,
        time: String,
        unread: Int,
        isPinned: Bool,
        isMuted: Bool,
        memberCount: Int?,
        accentHex: UInt,
        participants: [IMUser],
        messages: [ChatMessage],
        avatarURL: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = "",
        hasUnreadReaction: Bool = false,
        unreadReactionCount: Int = 0,
        lastMsgSeq: Int64 = 0,
        messageCoveredThroughSeq: Int64 = 0,
        messageCoverageRequiresRecovery: Bool = false,
        lastReadSeq: Int64 = 0,
        firstUnreadSeq: Int64 = 0,
        firstUnreadMessageID: String = "",
        unreadAnchorSeq: Int64 = 0,
        unreadAnchorState: String = "",
        hasMention: Bool = false,
        mentionCount: Int = 0,
        mentionSummaryText: String = "",
        mentionSummaryMessageID: String = "",
        mentionSummaryChannelSeq: Int64 = 0,
        sortTimestamp: TimeInterval = 0,
        historyVisibleFromSeq: Int64 = 1,
        historyLimited: Bool = false,
        historyBoundaryConfirmed: Bool = false
    ) {
        conversation = Conversation(
            id: id,
            title: title,
            subtitle: subtitle,
            kind: kind,
            lastMessage: lastMessage,
            time: time,
            unread: unread,
            isPinned: isPinned,
            isMuted: isMuted,
            memberCount: memberCount,
            accentHex: accentHex,
            participants: participants,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            hasUnreadReaction: hasUnreadReaction,
            unreadReactionCount: unreadReactionCount,
            lastMsgSeq: lastMsgSeq,
            messageCoveredThroughSeq: messageCoveredThroughSeq,
            messageCoverageRequiresRecovery: messageCoverageRequiresRecovery,
            lastReadSeq: lastReadSeq,
            firstUnreadSeq: firstUnreadSeq,
            firstUnreadMessageID: firstUnreadMessageID,
            unreadAnchorSeq: unreadAnchorSeq,
            unreadAnchorState: unreadAnchorState,
            hasMention: hasMention,
            mentionCount: mentionCount,
            mentionSummaryText: mentionSummaryText,
            mentionSummaryMessageID: mentionSummaryMessageID,
            mentionSummaryChannelSeq: mentionSummaryChannelSeq,
            sortTimestamp: sortTimestamp,
            historyVisibleFromSeq: historyVisibleFromSeq,
            historyLimited: historyLimited,
            historyBoundaryConfirmed: historyBoundaryConfirmed
        )
        self.messages = messages
    }
}
// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END

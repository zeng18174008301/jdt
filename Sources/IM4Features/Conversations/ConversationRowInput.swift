// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import Foundation
import IM4Domain

public struct ConversationCertificationInput: Equatable, Sendable {
    public let visibleLabel: String
    public let accessibilityLabel: String
    public let styleToken: String
    public let revision: Int64
    public let generation: Int64
    public init(visibleLabel: String, accessibilityLabel: String, styleToken: String, revision: Int64, generation: Int64) {
        self.visibleLabel = visibleLabel; self.accessibilityLabel = accessibilityLabel
        self.styleToken = styleToken; self.revision = revision; self.generation = generation
    }
}
public struct ConversationRowAvatarInput: Equatable, Sendable {
    public let avatarURL: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let avatarImageCacheKey: String
    public let directCertificationUID: String
    public let directCertificationPresentation: ConversationCertificationInput?
    public init(avatarURL: String, avatarVersion: String, avatarUpdatedAt: String, avatarImageCacheKey: String,
                directCertificationUID: String, directCertificationPresentation: ConversationCertificationInput?) {
        self.avatarURL = avatarURL; self.avatarVersion = avatarVersion; self.avatarUpdatedAt = avatarUpdatedAt
        self.avatarImageCacheKey = avatarImageCacheKey; self.directCertificationUID = directCertificationUID
        self.directCertificationPresentation = directCertificationPresentation
    }
}
public struct ConversationRowInput: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ConversationKind
    public let displayTitle: String
    public let groupMemberCount: Int?
    public let lastMessage: String
    public let time: String
    public let unread: Int
    public let isPinned: Bool
    public let isMuted: Bool
    public let accentHex: UInt
    public let hasUnreadReaction: Bool
    public let unreadReactionCount: Int
    public let sortTimestamp: TimeInterval
    public let rowPresentation: ConversationRowAvatarInput
    public init(id: String, kind: ConversationKind, displayTitle: String, groupMemberCount: Int?, lastMessage: String,
                time: String, unread: Int, isPinned: Bool, isMuted: Bool, accentHex: UInt, hasUnreadReaction: Bool,
                unreadReactionCount: Int, sortTimestamp: TimeInterval, rowPresentation: ConversationRowAvatarInput) {
        self.id = id; self.kind = kind; self.displayTitle = displayTitle; self.groupMemberCount = groupMemberCount
        self.lastMessage = lastMessage; self.time = time; self.unread = unread; self.isPinned = isPinned
        self.isMuted = isMuted; self.accentHex = accentHex; self.hasUnreadReaction = hasUnreadReaction
        self.unreadReactionCount = unreadReactionCount; self.sortTimestamp = sortTimestamp; self.rowPresentation = rowPresentation
    }
}
public struct ConversationMentionPreview: Equatable, Sendable {
    public let senderName: String
    public let text: String
    public init(senderName: String, text: String) { self.senderName = senderName; self.text = text }
}
public struct ConversationListItemInput: Equatable, Identifiable, Sendable {
    public let rowModel: ConversationRowInput
    public let unreadMention: ConversationMentionPreview?
    public var id: String { rowModel.id }
    public init(rowModel: ConversationRowInput, unreadMention: ConversationMentionPreview?) {
        self.rowModel = rowModel; self.unreadMention = unreadMention
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

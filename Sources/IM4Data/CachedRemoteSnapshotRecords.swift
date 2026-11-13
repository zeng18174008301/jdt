// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import IM4Domain

public struct CachedRemoteSnapshotLoadResult: @unchecked Sendable {
    public let conversations: [ConversationMessageSnapshot]
    public let readMs: Int
    public let decodeMs: Int
    public let mapSortMs: Int

    public init(conversations: [ConversationMessageSnapshot], readMs: Int, decodeMs: Int, mapSortMs: Int) {
        self.conversations = conversations
        self.readMs = readMs
        self.decodeMs = decodeMs
        self.mapSortMs = mapSortMs
    }
}

public struct CachedRemoteSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let scope: String
    public let createdAt: TimeInterval
    public let conversations: [CachedConversation]

    public init(schemaVersion: Int, scope: String, createdAt: TimeInterval, conversations: [CachedConversation]) {
        self.schemaVersion = schemaVersion
        self.scope = scope
        self.createdAt = createdAt
        self.conversations = conversations
    }
}

public struct CachedConversation: Codable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: String
    public let lastMessage: String
    public let time: String
    public let unread: Int
    public let isPinned: Bool
    public let isMuted: Bool
    public let memberCount: Int?
    public let accentHex: UInt
    public let participants: [CachedUser]
    public let messages: [CachedMessage]
    public let avatarURL: String
    public let avatarVersion: String?
    public let avatarUpdatedAt: String?
    public let hasUnreadReaction: Bool
    public let unreadReactionCount: Int
    public let lastMsgSeq: Int64
    public let messageCoveredThroughSeq: Int64?
    public let messageCoverageRequiresRecovery: Bool?
    public let lastReadSeq: Int64?
    public let firstUnreadSeq: Int64?
    public let firstUnreadMessageID: String?
    public let unreadAnchorSeq: Int64?
    public let unreadAnchorState: String?
    public let hasMention: Bool?
    public let mentionCount: Int?
    public let mentionSummaryText: String?
    public let mentionSummaryMessageID: String?
    public let mentionSummaryChannelSeq: Int64?
    public let sortTimestamp: TimeInterval?
    public let historyVisibleFromSeq: Int64?
    public let historyLimited: Bool?
    public let historyBoundaryConfirmed: Bool?

    public init(conversation: ConversationMessageSnapshot, messageLimit: Int) {
        id = conversation.id
        title = conversation.title
        subtitle = conversation.subtitle
        kind = conversation.kind.rawValue
        lastMessage = conversation.lastMessage
        time = conversation.time
        unread = conversation.unread
        isPinned = conversation.isPinned
        isMuted = conversation.isMuted
        memberCount = conversation.memberCount
        accentHex = conversation.accentHex
        participants = conversation.participants.map(CachedUser.init)
        messages = conversation.messages.suffix(messageLimit).map(CachedMessage.init)
        avatarURL = conversation.avatarURL
        avatarVersion = conversation.avatarVersion.isEmpty ? nil : conversation.avatarVersion
        avatarUpdatedAt = conversation.avatarUpdatedAt.isEmpty ? nil : conversation.avatarUpdatedAt
        hasUnreadReaction = conversation.hasUnreadReaction
        unreadReactionCount = conversation.unreadReactionCount
        lastMsgSeq = conversation.lastMsgSeq
        messageCoveredThroughSeq = conversation.messageCoveredThroughSeq > 0
            ? conversation.messageCoveredThroughSeq
            : nil
        messageCoverageRequiresRecovery = conversation.messageCoverageRequiresRecovery ? true : nil
        lastReadSeq = conversation.lastReadSeq > 0 ? conversation.lastReadSeq : nil
        firstUnreadSeq = conversation.firstUnreadSeq > 0 ? conversation.firstUnreadSeq : nil
        firstUnreadMessageID = conversation.firstUnreadMessageID.isEmpty ? nil : conversation.firstUnreadMessageID
        unreadAnchorSeq = conversation.unreadAnchorSeq > 0 ? conversation.unreadAnchorSeq : nil
        unreadAnchorState = conversation.unreadAnchorState.isEmpty ? nil : conversation.unreadAnchorState
        hasMention = conversation.hasMention
        mentionCount = conversation.mentionCount
        mentionSummaryText = conversation.mentionSummaryText
        mentionSummaryMessageID = conversation.mentionSummaryMessageID
        mentionSummaryChannelSeq = conversation.mentionSummaryChannelSeq
        sortTimestamp = conversation.sortTimestamp > 0 ? conversation.sortTimestamp : nil
        historyVisibleFromSeq = conversation.historyVisibleFromSeq > 1 ? conversation.historyVisibleFromSeq : nil
        historyLimited = conversation.historyLimited ? true : nil
        historyBoundaryConfirmed = conversation.historyBoundaryConfirmed ? true : nil
    }

}

public struct CachedUser: Codable, Sendable {
    public let id: String
    public let userID: String
    public let username: String
    public let name: String
    public let title: String
    public let department: String
    public let phone: String
    public let phoneVerified: Bool
    public let realNameVerified: Bool
    public let realNameStatus: String
    public let email: String
    public let status: String
    public let enterprise: String
    public let avatarSeed: UInt
    public let avatarURL: String
    public let avatarVersion: String?
    public let avatarUpdatedAt: String?
    public let badges: [String]

    public init(user: IMUser) {
        id = user.id
        userID = user.userID
        username = user.username
        name = user.name
        title = user.title
        department = user.department
        phone = user.phone
        phoneVerified = user.phoneVerified
        realNameVerified = user.realNameVerified
        realNameStatus = user.realNameStatus
        email = user.email
        status = user.status
        enterprise = user.enterprise
        avatarSeed = user.avatarSeed
        avatarURL = user.avatarURL
        avatarVersion = user.avatarVersion.isEmpty ? nil : user.avatarVersion
        avatarUpdatedAt = user.avatarUpdatedAt.isEmpty ? nil : user.avatarUpdatedAt
        badges = user.badges
    }

    public var model: IMUser {
        IMUser(
            id: id,
            userID: userID,
            username: username,
            name: name,
            title: title,
            department: department,
            phone: phone,
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameStatus,
            email: email,
            status: status,
            enterprise: enterprise,
            avatarSeed: avatarSeed,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion ?? "",
            avatarUpdatedAt: avatarUpdatedAt ?? "",
            badges: badges
        )
    }
}

public struct CachedMessage: Codable, Sendable {
    public let id: String
    public let senderId: String
    public let senderProvenance: String?
    public let senderName: String
    public let senderAvatarURL: String?
    public let senderAvatarVersion: String?
    public let senderAvatarUpdatedAt: String?
    public let senderAvatarSeed: UInt?
    public let text: String
    public let time: String
    public let createdAt: TimeInterval?
    public let channelSeq: Int64
    public let isOutgoing: Bool
    public let status: String
    public let kind: String
    public let contentType: String?
    public let reactions: [CachedReaction]
    public let readBy: [CachedReadReceipt]
    public let unreadBy: [CachedReadReceipt]
    public let readCount: Int?
    public let unreadCount: Int?
    public let readStateKnown: Bool
    public let deliveryStateKnown: Bool?
    public let canViewReadDetails: Bool
    public let quote: String?
    public let replyContext: MessageReplyContext?
    public let attachmentName: String?
    public let attachmentMeta: String?
    public let attachmentFileID: String?
    public let attachmentSizeBytes: Int64?
    public let attachmentPreviewURL: String
    public let attachmentDownloadURL: String
    public let attachmentPreviewAvailable: Bool
    public let attachmentDownloadAvailable: Bool
    public let attachmentMimeType: String?
    public let attachmentCacheKey: String?
    public let attachmentVersion: String?
    public let attachmentChecksum: String?
    public let attachmentMediaCategory: String
    public let attachmentExtension: String
    public let attachmentThumbnailURL: String
    public let attachmentPosterURL: String
    public let attachmentCoverURL: String
    public let attachmentPreviewKind: String
    public let attachmentContentDisposition: String?
    public let attachmentWidth: Int?
    public let attachmentHeight: Int?
    public let attachmentDurationSeconds: Double?
    public let attachmentUploadStatus: String
    public let attachmentUploadFailure: AttachmentUploadFailure?
    public let isPinned: Bool
    public let isPinnedContextOnly: Bool?
    public let isFavorited: Bool
    public let isDeletedLocally: Bool?
    public let isEdited: Bool
	public let editRevision: Int64?
    public let auditTags: [String]
    public let reportState: String?
    public let serverTrace: String?
    public let mentionExcluded: Bool
    public let mentionAll: Bool?
    public let mentionedUsers: [MentionIdentity]?
    public let voiceWaveform: [Int]?
    public let stickerSnapshot: StickerMessageSnapshot?
    public let rtcCallRecord: RTCCallRecordPayload?
    public let systemEventType: String?
    public let systemDisplayStyle: String?
    public let systemColorToken: String?
    public let systemTextColorHex: String?
    public let systemBackgroundColorHex: String?
    public let systemAccentColorHex: String?

    public init(message: ChatMessage) {
        id = message.id
        senderId = message.senderId
        senderProvenance = message.senderProvenance.rawValue
        senderName = message.senderName
        senderAvatarURL = message.senderAvatarURL.isEmpty ? nil : message.senderAvatarURL
        senderAvatarVersion = message.senderAvatarVersion.isEmpty ? nil : message.senderAvatarVersion
        senderAvatarUpdatedAt = message.senderAvatarUpdatedAt.isEmpty ? nil : message.senderAvatarUpdatedAt
        senderAvatarSeed = message.senderAvatarSeed == 0 ? nil : message.senderAvatarSeed
        text = message.text
        time = message.time
        createdAt = message.createdAt?.timeIntervalSince1970
        channelSeq = message.channelSeq
        isOutgoing = message.isOutgoing
        status = message.status.rawValue
        kind = message.kind.rawValue
        contentType = message.contentType.isEmpty ? nil : message.contentType
        reactions = message.reactions.map(CachedReaction.init)
        readBy = message.readBy.map(CachedReadReceipt.init)
        unreadBy = message.unreadBy.map(CachedReadReceipt.init)
        readCount = message.readCount
        unreadCount = message.unreadCount
        readStateKnown = message.readStateKnown
        deliveryStateKnown = message.deliveryStateKnown
        canViewReadDetails = message.canViewReadDetails
        quote = message.quote
        replyContext = message.replyContext
        attachmentName = message.attachmentName
        attachmentMeta = message.attachmentMeta
        attachmentFileID = message.attachmentFileID
        attachmentSizeBytes = message.attachmentSizeBytes
        attachmentPreviewURL = message.attachmentPreviewURL
        attachmentDownloadURL = message.attachmentDownloadURL
        attachmentPreviewAvailable = message.attachmentPreviewAvailable
        attachmentDownloadAvailable = message.attachmentDownloadAvailable
        attachmentMimeType = message.attachmentMimeType.isEmpty ? nil : message.attachmentMimeType
        attachmentCacheKey = message.attachmentCacheKey.isEmpty ? nil : message.attachmentCacheKey
        attachmentVersion = message.attachmentVersion.isEmpty ? nil : message.attachmentVersion
        attachmentChecksum = message.attachmentChecksum.isEmpty ? nil : message.attachmentChecksum
        attachmentMediaCategory = message.attachmentMediaCategory
        attachmentExtension = message.attachmentExtension
        attachmentThumbnailURL = message.attachmentThumbnailURL
        attachmentPosterURL = message.attachmentPosterURL
        attachmentCoverURL = message.attachmentCoverURL
        attachmentPreviewKind = message.attachmentPreviewKind
        attachmentContentDisposition = message.attachmentContentDisposition
        attachmentWidth = message.attachmentWidth
        attachmentHeight = message.attachmentHeight
        attachmentDurationSeconds = message.attachmentDurationSeconds
        attachmentUploadStatus = message.attachmentUploadStatus
        attachmentUploadFailure = message.attachmentUploadFailure
        isPinned = message.isPinned
        isPinnedContextOnly = message.isPinnedContextOnly ? true : nil
        isFavorited = message.isFavorited
        isDeletedLocally = message.isDeletedLocally ? true : nil
        isEdited = message.isEdited
		editRevision = message.editRevision > 0 ? message.editRevision : nil
        auditTags = message.auditTags
        reportState = message.reportState
        serverTrace = message.serverTrace
        mentionExcluded = message.mentionExcluded
        mentionAll = message.mentionAll
        mentionedUsers = message.mentionedUsers
        voiceWaveform = message.voiceWaveform
        stickerSnapshot = message.stickerSnapshot
        rtcCallRecord = message.rtcCallRecord
        systemEventType = message.systemEventType
        systemDisplayStyle = message.systemDisplayStyle
        systemColorToken = message.systemColorToken
        systemTextColorHex = message.systemTextColorHex
        systemBackgroundColorHex = message.systemBackgroundColorHex
        systemAccentColorHex = message.systemAccentColorHex
    }

    /// Local previews and expiring signed URLs are runtime-only. The durable
    /// outbox can reconstruct local media from its scope-relative staged file
    /// and can re-authorize remote URLs from the stable file identifier.



}

public struct CachedReaction: Codable, Sendable {
    public let id: String
    public let emoji: String
    public let count: Int
    public let reactedByMe: Bool

    public init(reaction: Reaction) {
        id = reaction.id
        emoji = reaction.emoji
        count = reaction.count
        reactedByMe = reaction.reactedByMe
    }

    public var model: Reaction {
        Reaction(id: id, emoji: emoji, count: count, reactedByMe: reactedByMe)
    }
}

public struct CachedReadReceipt: Codable, Sendable {
    public let id: String
    public let user: CachedUser
    public let device: String
    public let time: String

    public init(receipt: ReadReceipt) {
        id = receipt.id
        user = CachedUser(user: receipt.user)
        device = receipt.device
        time = receipt.time
    }

    public var model: ReadReceipt {
        ReadReceipt(id: id, user: user.model, device: device, time: time)
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

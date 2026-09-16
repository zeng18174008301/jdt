import Foundation

struct CachedRemoteSnapshotLoadResult: @unchecked Sendable {
    let conversations: [Conversation]
    let readMs: Int
    let decodeMs: Int
    let mapSortMs: Int
}

struct CachedRemoteSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let scope: String
    let createdAt: TimeInterval
    let conversations: [CachedConversation]
}

struct CachedConversation: Codable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let lastMessage: String
    let time: String
    let unread: Int
    let isPinned: Bool
    let isMuted: Bool
    let memberCount: Int?
    let accentHex: UInt
    let participants: [CachedUser]
    let messages: [CachedMessage]
    let avatarURL: String
    let avatarVersion: String?
    let avatarUpdatedAt: String?
    let hasUnreadReaction: Bool
    let unreadReactionCount: Int
    let lastMsgSeq: Int64
    let messageCoveredThroughSeq: Int64?
    let messageCoverageRequiresRecovery: Bool?
    let lastReadSeq: Int64?
    let firstUnreadSeq: Int64?
    let firstUnreadMessageID: String?
    let unreadAnchorSeq: Int64?
    let unreadAnchorState: String?
    let hasMention: Bool?
    let mentionCount: Int?
    let mentionSummaryText: String?
    let mentionSummaryMessageID: String?
    let mentionSummaryChannelSeq: Int64?
    let sortTimestamp: TimeInterval?
    let historyVisibleFromSeq: Int64?
    let historyLimited: Bool?
    let historyBoundaryConfirmed: Bool?

    init(conversation: Conversation, messageLimit: Int) {
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

    var model: Conversation {
        // Cached kind is the local display enum (e.g. 单聊), not the wire type.
        let channelType = kind == ConversationKind.direct.rawValue ? "direct"
            : (kind == ConversationKind.group.rawValue ? "group" : "system")
        let cachedMessages = messages.map { $0.restoredModel(channelType: channelType) }
        let repairedSummaryTime = messages.first(where: {
            $0.channelSeq == lastMsgSeq && $0.needsRTCTimeProjection
        }).flatMap { source in
            cachedMessages.first(where: { $0.id == source.id })?.time
        }
        let cachedSortTimestamp = sortTimestamp
            ?? cachedMessages.compactMap(\.createdAt).max()?.timeIntervalSince1970
            ?? 0
        return Conversation(
            id: id,
            title: title,
            subtitle: subtitle,
            kind: ConversationKind(rawValue: kind) ?? .direct,
            lastMessage: lastMessage,
            time: repairedSummaryTime ?? time,
            unread: unread,
            isPinned: isPinned,
            isMuted: isMuted,
            memberCount: memberCount,
            accentHex: accentHex,
            participants: participants.map(\.model),
            messages: cachedMessages,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion ?? "",
            avatarUpdatedAt: avatarUpdatedAt ?? "",
            hasUnreadReaction: hasUnreadReaction,
            unreadReactionCount: unreadReactionCount,
            lastMsgSeq: lastMsgSeq,
            messageCoveredThroughSeq: messageCoveredThroughSeq ?? 0,
            messageCoverageRequiresRecovery: messageCoverageRequiresRecovery ?? false,
            lastReadSeq: lastReadSeq ?? 0,
            firstUnreadSeq: firstUnreadSeq ?? 0,
            firstUnreadMessageID: firstUnreadMessageID ?? "",
            unreadAnchorSeq: unreadAnchorSeq ?? 0,
            unreadAnchorState: unreadAnchorState ?? "",
            hasMention: hasMention ?? false,
            mentionCount: mentionCount ?? 0,
            mentionSummaryText: mentionSummaryText ?? "",
            mentionSummaryMessageID: mentionSummaryMessageID ?? "",
            mentionSummaryChannelSeq: mentionSummaryChannelSeq ?? 0,
            sortTimestamp: cachedSortTimestamp,
            historyVisibleFromSeq: max(1, historyVisibleFromSeq ?? 1),
            historyLimited: historyLimited ?? false,
            historyBoundaryConfirmed: historyBoundaryConfirmed ?? false
        )
    }
}

struct CachedUser: Codable, Sendable {
    let id: String
    let userID: String
    let username: String
    let name: String
    let title: String
    let department: String
    let phone: String
    let phoneVerified: Bool
    let realNameVerified: Bool
    let realNameStatus: String
    let email: String
    let status: String
    let enterprise: String
    let avatarSeed: UInt
    let avatarURL: String
    let avatarVersion: String?
    let avatarUpdatedAt: String?
    let badges: [String]

    init(user: IMUser) {
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

    var model: IMUser {
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

struct CachedMessage: Codable, Sendable {
    let id: String
    let senderId: String
    let senderProvenance: String?
    let senderName: String
    let senderAvatarURL: String?
    let senderAvatarVersion: String?
    let senderAvatarUpdatedAt: String?
    let senderAvatarSeed: UInt?
    let text: String
    let time: String
    let createdAt: TimeInterval?
    let channelSeq: Int64
    let isOutgoing: Bool
    let status: String
    let kind: String
    let contentType: String?
    let reactions: [CachedReaction]
    let readBy: [CachedReadReceipt]
    let unreadBy: [CachedReadReceipt]
    let readCount: Int?
    let unreadCount: Int?
    let readStateKnown: Bool
    let deliveryStateKnown: Bool?
    let canViewReadDetails: Bool
    let quote: String?
    let replyContext: MessageReplyContext?
    let attachmentName: String?
    let attachmentMeta: String?
    let attachmentFileID: String?
    let attachmentSizeBytes: Int64?
    let attachmentPreviewURL: String
    let attachmentDownloadURL: String
    let attachmentPreviewAvailable: Bool
    let attachmentDownloadAvailable: Bool
    let attachmentMimeType: String?
    let attachmentCacheKey: String?
    let attachmentVersion: String?
    let attachmentChecksum: String?
    let attachmentMediaCategory: String
    let attachmentExtension: String
    let attachmentThumbnailURL: String
    let attachmentPosterURL: String
    let attachmentCoverURL: String
    let attachmentPreviewKind: String
    let attachmentContentDisposition: String?
    let attachmentWidth: Int?
    let attachmentHeight: Int?
    let attachmentDurationSeconds: Double?
    let attachmentUploadStatus: String
    let attachmentUploadFailure: AttachmentUploadFailure?
    let isPinned: Bool
    let isPinnedContextOnly: Bool?
    let isFavorited: Bool
    let isDeletedLocally: Bool?
    let isEdited: Bool
	let editRevision: Int64?
    let auditTags: [String]
    let reportState: String?
    let serverTrace: String?
    let mentionExcluded: Bool
    let mentionAll: Bool?
    let mentionedUsers: [MentionIdentity]?
    let voiceWaveform: [Int]?
    let stickerSnapshot: StickerMessageSnapshot?
    let rtcCallRecord: RTCCallRecordPayload?
    let systemEventType: String?
    let systemDisplayStyle: String?
    let systemColorToken: String?
    let systemTextColorHex: String?
    let systemBackgroundColorHex: String?
    let systemAccentColorHex: String?

    init(message: ChatMessage) {
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
    func sanitizedForDurableOutbox() -> CachedMessage {
        var sanitized = model
        sanitized.attachmentPreviewURL = ""
        sanitized.attachmentDownloadURL = ""
        sanitized.attachmentThumbnailURL = ""
        sanitized.attachmentPosterURL = ""
        sanitized.attachmentCoverURL = ""
        return CachedMessage(message: sanitized)
    }

    var model: ChatMessage {
        restoredModel()
    }

    fileprivate var needsRTCTimeProjection: Bool {
        // Cached text may predate the original-event-time rule even with a finite envelope date.
        let isRTC = rtcCallRecord != nil || kind == MessageKind.rtcCallRecord.rawValue
            || contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record"
        return isRTC
    }

    fileprivate func restoredModel(channelType: String = "direct") -> ChatMessage {
        let restoredTime: String
        if needsRTCTimeProjection {
            let projectedDate = RTCCallRecordTimeProjection.messageDate(
                outerDate: createdAt.map(Date.init(timeIntervalSince1970:)),
                record: rtcCallRecord, contentType: contentType ?? "",
                channelType: channelType, fromUID: senderId
            )
            restoredTime = RTCCallRecordTimeProjection.displayTime(projectedDate)
        } else {
            restoredTime = time
        }
        var message = ChatMessage(
            id: id,
            senderId: senderId,
            senderProvenance: senderProvenance
                .flatMap(BatchForwardSenderProvenance.init(rawValue:))
                ?? .unknown,
            senderName: senderName,
            senderAvatarURL: senderAvatarURL ?? "",
            senderAvatarVersion: senderAvatarVersion ?? "",
            senderAvatarUpdatedAt: senderAvatarUpdatedAt ?? "",
            senderAvatarSeed: senderAvatarSeed ?? 0,
            text: text,
            time: restoredTime,
            createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
            channelSeq: channelSeq,
            isOutgoing: isOutgoing,
            status: MessageDelivery(rawValue: status) ?? .sent,
            kind: MessageKind(rawValue: kind) ?? .text,
            reactions: reactions.map(\.model),
            readBy: readBy.map(\.model),
            unreadBy: unreadBy.map(\.model),
            readCount: readCount,
            unreadCount: unreadCount,
            readStateKnown: readStateKnown,
            canViewReadDetails: canViewReadDetails,
            quote: quote,
            attachmentName: attachmentName,
            attachmentMeta: attachmentMeta,
            attachmentFileID: attachmentFileID,
            attachmentSizeBytes: attachmentSizeBytes,
            attachmentPreviewURL: attachmentPreviewURL,
            attachmentDownloadURL: attachmentDownloadURL,
            attachmentPreviewAvailable: attachmentPreviewAvailable,
            attachmentDownloadAvailable: attachmentDownloadAvailable
        )
        message.replyContext = replyContext
        message.contentType = contentType ?? ""
        message.deliveryStateKnown = deliveryStateKnown ?? false
        message.attachmentMimeType = attachmentMimeType ?? ""
        message.attachmentCacheKey = attachmentCacheKey ?? ""
        message.attachmentVersion = attachmentVersion ?? ""
        message.attachmentChecksum = attachmentChecksum ?? ""
        message.attachmentMediaCategory = attachmentMediaCategory
        message.attachmentExtension = attachmentExtension
        message.attachmentThumbnailURL = attachmentThumbnailURL
        message.attachmentPosterURL = attachmentPosterURL
        message.attachmentCoverURL = attachmentCoverURL
        message.attachmentPreviewKind = attachmentPreviewKind
        message.attachmentContentDisposition = attachmentContentDisposition ?? ""
        message.attachmentWidth = attachmentWidth
        message.attachmentHeight = attachmentHeight
        message.attachmentDurationSeconds = attachmentDurationSeconds
        message.attachmentUploadStatus = attachmentUploadStatus
        message.attachmentUploadFailure = attachmentUploadFailure
        message.isPinned = isPinned
        message.isPinnedContextOnly = isPinnedContextOnly ?? false
        message.isFavorited = isFavorited
        message.isDeletedLocally = isDeletedLocally ?? false
        message.isEdited = isEdited
		message.editRevision = editRevision ?? 0
        message.auditTags = auditTags
        message.reportState = reportState
        message.serverTrace = serverTrace
        message.mentionExcluded = mentionExcluded
        message.mentionAll = mentionAll ?? false
        message.mentionedUsers = mentionedUsers ?? []
        message.voiceWaveform = voiceWaveform ?? []
        message.stickerSnapshot = stickerSnapshot
        message.rtcCallRecord = rtcCallRecord
        message.systemEventType = systemEventType
        message.systemDisplayStyle = systemDisplayStyle
        message.systemColorToken = systemColorToken
        message.systemTextColorHex = systemTextColorHex
        message.systemBackgroundColorHex = systemBackgroundColorHex
        message.systemAccentColorHex = systemAccentColorHex
        return message
    }
}

struct CachedReaction: Codable, Sendable {
    let id: String
    let emoji: String
    let count: Int
    let reactedByMe: Bool

    init(reaction: Reaction) {
        id = reaction.id
        emoji = reaction.emoji
        count = reaction.count
        reactedByMe = reaction.reactedByMe
    }

    var model: Reaction {
        Reaction(id: id, emoji: emoji, count: count, reactedByMe: reactedByMe)
    }
}

struct CachedReadReceipt: Codable, Sendable {
    let id: String
    let user: CachedUser
    let device: String
    let time: String

    init(receipt: ReadReceipt) {
        id = receipt.id
        user = CachedUser(user: receipt.user)
        device = receipt.device
        time = receipt.time
    }

    var model: ReadReceipt {
        ReadReceipt(id: id, user: user.model, device: device, time: time)
    }
}

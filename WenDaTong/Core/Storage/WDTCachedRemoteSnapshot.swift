// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

extension CachedConversation {
    var model: ConversationMessageSnapshot {
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
        return ConversationMessageSnapshot(
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

extension CachedMessage {
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
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

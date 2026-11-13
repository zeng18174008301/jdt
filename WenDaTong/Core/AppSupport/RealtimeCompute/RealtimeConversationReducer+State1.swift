import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension RealtimeConversationReducer {
    // Source Stores/ConversationStore+Lifecycle.swift:78; pure value snapshot counterpart.
    func conversationListPrecedes(_ lhs: ConversationMessageSnapshot, _ rhs: ConversationMessageSnapshot) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        let lhsTimestamp = conversationSortTimestamp(lhs)
        let rhsTimestamp = conversationSortTimestamp(rhs)
        if lhsTimestamp != rhsTimestamp { return lhsTimestamp > rhsTimestamp }
        return lhs.id < rhs.id
    }

    // Source Stores/ConversationStore+Lifecycle.swift:655; pure value snapshot counterpart.
    func conversationSortTimestamp(_ conversation: ConversationMessageSnapshot) -> TimeInterval {
        if conversation.sortTimestamp > 0 {
            return conversation.sortTimestamp
        }
        if let latestDate = latestConfirmedMessage(in: conversation.messages).flatMap(effectiveCreatedAt) {
            return latestDate.timeIntervalSince1970
        }
        return 0
    }

    // Source Stores/ConversationStore+LocalMessages.swift:35; pure value snapshot counterpart.
    func latestConfirmedMessage(in messages: [ChatMessage]) -> ChatMessage? {
        messages.last { message in
            message.status != .failed && message.status != .sending && !message.isDeletedLocally
        }
    }

    // Source Stores/ConversationStore+RemoteMerge.swift:642; pure value snapshot counterpart.
    func messageTimelinePrecedes(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.channelSeq > 0, rhs.channelSeq > 0, lhs.channelSeq != rhs.channelSeq {
            return lhs.channelSeq < rhs.channelSeq
        }
        let lhsDate = lhs.createdAt ?? Date.distantPast
        let rhsDate = rhs.createdAt ?? Date.distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id < rhs.id
    }

    // Source Stores/ConversationStore+RemoteMerge.swift:28; pure value snapshot counterpart.
    func resolvedGroupMemberCount(incoming: Int?, existing: Int?, participants: [IMUser]) -> Int? {
        guard let incoming, incoming > 0 else { return nil }
        return incoming
    }

    // Source Stores/ConversationStore+History.swift:59; pure value snapshot counterpart.
    func applyingHistoryVisibilityBoundary(
        _ boundary: HistoryVisibilityBoundary?,
        to conversation: ConversationMessageSnapshot?,
        keepPendingLocalMessages: Bool = true
    ) -> ConversationMessageSnapshot? {
        guard let conversation else { return nil }
        var updated = conversation
        guard updated.kind == .group else { return updated }
        let resolvedBoundary = boundary ?? HistoryVisibilityBoundary(fromSeq: 1, limited: false, confirmed: true)
        let previousBoundarySeq = (updated.historyBoundaryConfirmed || updated.historyVisibleFromSeq > 1 || updated.historyLimited)
            ? max(1, updated.historyVisibleFromSeq)
            : nil
        let shouldClearForNewEpisode = previousBoundarySeq.map { resolvedBoundary.fromSeq < $0 } ?? false
        updated.historyVisibleFromSeq = resolvedBoundary.fromSeq
        updated.historyLimited = resolvedBoundary.limited
        updated.historyBoundaryConfirmed = resolvedBoundary.confirmed
        if shouldClearForNewEpisode {
            updated.messages = keepPendingLocalMessages ? updated.messages.filter { isPendingLocalMessage($0) } : []
        } else {
            updated.messages = historyVisibleMessages(
                updated.messages,
                boundary: resolvedBoundary,
                keepPendingLocalMessages: keepPendingLocalMessages
            )
        }
        let refreshSummary = !conversation.historyBoundaryConfirmed
            || conversation.historyVisibleFromSeq != updated.historyVisibleFromSeq
            || conversation.historyLimited != updated.historyLimited
            || conversation.historyBoundaryConfirmed != updated.historyBoundaryConfirmed
            || conversation.messages != updated.messages
        refreshHistoryBoundedSummary(&updated, boundary: resolvedBoundary, refreshSummary: refreshSummary)
        return updated
    }

    // Source Stores/ConversationStore+History.swift:114; pure value snapshot counterpart.
    func refreshHistoryBoundedSummary(_ conversation: inout ConversationMessageSnapshot, boundary: HistoryVisibilityBoundary, refreshSummary: Bool) {
        if refreshSummary {
            if let latest = latestConfirmedMessage(in: conversation.messages.filter { !$0.isPinnedContextOnly })
                ?? latestConfirmedMessage(in: conversation.messages) {
                conversation.lastMessage = latest.conversationListPreview
                conversation.time = latest.time
                conversation.sortTimestamp = effectiveCreatedAt(for: latest)?.timeIntervalSince1970 ?? conversation.sortTimestamp
            } else if boundary.isRestrictive || conversation.historyBoundaryConfirmed {
                conversation.lastMessage = ""
                conversation.time = ""
                conversation.sortTimestamp = 0
            }
        }
        if boundary.isRestrictive {
            if conversation.firstUnreadSeq > 0 && conversation.firstUnreadSeq < boundary.fromSeq {
                conversation.unread = 0
                conversation.firstUnreadSeq = 0
                conversation.firstUnreadMessageID = ""
                conversation.unreadAnchorSeq = 0
                conversation.unreadAnchorState = "none"
            }
            if conversation.mentionSummaryChannelSeq > 0 && conversation.mentionSummaryChannelSeq < boundary.fromSeq {
                conversation.hasMention = false
                conversation.mentionCount = 0
                conversation.mentionSummaryText = ""
                conversation.mentionSummaryMessageID = ""
                conversation.mentionSummaryChannelSeq = 0
            }
            if conversation.messages.isEmpty {
                conversation.unread = 0
                conversation.hasUnreadReaction = false
                conversation.unreadReactionCount = 0
                conversation.hasMention = false
                conversation.mentionCount = 0
            }
        }
    }

    // Source Stores/ConversationStore+RemoteMerge.swift:634; pure value snapshot counterpart.
    func effectiveCreatedAt(for message: ChatMessage) -> Date? {
        message.createdAt
    }

    // Source Stores/ConversationStore+History.swift:42; pure value snapshot counterpart.
    func historyVisibleMessages(
        _ messages: [ChatMessage],
        boundary: HistoryVisibilityBoundary?,
        keepPendingLocalMessages: Bool = true
    ) -> [ChatMessage] {
        guard let boundary, boundary.isRestrictive else { return messages }
        return messages.filter { message in
            if message.channelSeq >= boundary.fromSeq {
                return true
            }
            if keepPendingLocalMessages, isPendingLocalMessage(message) {
                return true
            }
            return false
        }
    }

    // Source Stores/ConversationStore+RemoteMerge.swift:638; pure value snapshot counterpart.
    func isPendingLocalMessage(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed
    }

    // Source Stores/ConversationStore+History.swift:32; pure value snapshot counterpart.
    func historyBoundary(for conversation: ConversationMessageSnapshot?) -> HistoryVisibilityBoundary? {
        guard let conversation, conversation.kind == .group else { return nil }
        guard conversation.historyBoundaryConfirmed || conversation.historyLimited || conversation.historyVisibleFromSeq > 1 else { return nil }
        return HistoryVisibilityBoundary(
            fromSeq: conversation.historyVisibleFromSeq,
            limited: conversation.historyLimited,
            confirmed: conversation.historyBoundaryConfirmed
        )
    }

    // Source Stores/ConversationStore+LocalMessages.swift:566; pure value snapshot counterpart.
    func markMessageAsRecalledFromRemoteStatus(_ message: inout ChatMessage) {
        markMessageAsRecalled(&message, recallText: nil)
    }

    // Source Stores/ConversationStore+LocalMessages.swift:570; pure value snapshot counterpart.
    func markMessageAsRecalled(_ message: inout ChatMessage, recallText: String?) {
        let safeText = recallText?.trimmingCharacters(in: .whitespacesAndNewlines)
        message.status = .recalled
        message.text = safeText?.isEmpty == false ? safeText! : defaultRecallText(for: message)
        message.quote = nil
        message.replyContext = unavailableReplyContext(messageID: message.id)
        message.attachmentName = nil
        message.attachmentMeta = nil
        message.attachmentFileID = nil
        message.attachmentSizeBytes = nil
        message.attachmentPreviewURL = ""
        message.attachmentDownloadURL = ""
        message.attachmentPreviewAvailable = false
        message.attachmentDownloadAvailable = false
        message.attachmentThumbnailURL = ""
        message.attachmentPosterURL = ""
        message.attachmentCoverURL = ""
        message.attachmentTransferProgress = nil
        message.attachmentMimeType = ""
        message.attachmentCacheKey = ""
        message.attachmentVersion = ""
        message.attachmentChecksum = ""
        message.attachmentMediaCategory = ""
        message.attachmentExtension = ""
        message.attachmentPreviewKind = ""
        message.attachmentContentDisposition = ""
        message.attachmentWidth = nil
        message.attachmentHeight = nil
        message.attachmentDurationSeconds = nil
        message.attachmentUploadStatus = ""
        message.attachmentUploadFailure = nil
        message.reactions = []
        message.reactionDetails = []
        message.readBy = []
        message.unreadBy = []
        message.readCount = nil
        message.unreadCount = nil
        message.readStateKnown = false
        message.canViewReadDetails = false
    }

    // Source Stores/ConversationStore+RemoteMerge.swift:720; pure value snapshot counterpart.
    func unavailableReplyContext(messageID: String = "") -> MessageReplyContext {
        MessageReplyContext(
            messageID: messageID,
            summary: "原消息不可查看/已撤回",
            isUnavailable: true
        )
    }

    // Source Stores/ConversationStore+LocalMessages.swift:611; pure value snapshot counterpart.
    func defaultRecallText(for message: ChatMessage) -> String {
        if message.isOutgoing {
            return "你撤回了一条消息"
        }
        let sender = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, sender != "未知用户", sender != "系统" else {
            return "对方撤回了一条消息"
        }
        return "\(sender)撤回了一条消息"
    }

    // Source Stores/ConversationStore+LocalMessages.swift:657; pure value snapshot counterpart.
    func markMessageAsAdminDeleted(_ message: inout ChatMessage) {
        message.isDeletedLocally = true
        message.status = .recalled
        message.text = "原消息已删除"
        message.quote = nil
        message.replyContext = unavailableReplyContext(messageID: message.id)
        message.attachmentName = nil
        message.attachmentMeta = nil
        message.attachmentFileID = nil
        message.attachmentSizeBytes = nil
        message.attachmentPreviewURL = ""
        message.attachmentDownloadURL = ""
        message.attachmentPreviewAvailable = false
        message.attachmentDownloadAvailable = false
        message.attachmentThumbnailURL = ""
        message.attachmentPosterURL = ""
        message.attachmentCoverURL = ""
        message.attachmentTransferProgress = nil
        message.attachmentMimeType = ""
        message.attachmentCacheKey = ""
        message.attachmentVersion = ""
        message.attachmentChecksum = ""
        message.attachmentMediaCategory = ""
        message.attachmentExtension = ""
        message.attachmentPreviewKind = ""
        message.attachmentContentDisposition = ""
        message.attachmentWidth = nil
        message.attachmentHeight = nil
        message.attachmentDurationSeconds = nil
        message.attachmentUploadStatus = ""
        message.attachmentUploadFailure = nil
        message.reactions = []
        message.reactionDetails = []
        message.readBy = []
        message.unreadBy = []
        message.readCount = nil
        message.unreadCount = nil
        message.readStateKnown = false
        message.canViewReadDetails = false
    }

    // Source Stores/ConversationStore+ReadState.swift:294; pure value snapshot counterpart.
    func applyRemoteReadSummary(
        from remote: RemoteMessage,
        to message: inout ChatMessage,
        readReceiptsEnabled: Bool
    ) {
        guard message.isOutgoing, message.status != .recalled, !message.isDeletedLocally else { return }
        guard readReceiptsEnabled else {
            stripReadReceiptDetails(from: &message)
            return
        }
        let normalizedStatus = remote.readStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hasSummary = !normalizedStatus.isEmpty || remote.readCount != nil || remote.readAt != nil
        guard hasSummary else { return }
        let summaryReadCount = max(0, remote.readCount ?? 0)
        let isRead = normalizedStatus == "read" || summaryReadCount > 0 || remote.readAt != nil
        message.readStateKnown = true
        if let remoteReadCount = remote.readCount {
            message.readCount = max(message.readCount ?? 0, max(0, remoteReadCount))
        }
        if isRead {
            message.status = .read
            return
        }
        if message.status != .read {
            message.status = .sent
            if message.readCount == nil {
                message.readCount = 0
            }
        }
    }

    // Source Stores/ConversationStore+ReadState.swift:325; pure value snapshot counterpart.
    func applyRemoteReadSummary(
        from remote: RemoteMessage,
        toMessagesIn conversation: inout ConversationMessageSnapshot,
        readReceiptsEnabled: Bool
    ) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == remote.messageID }) else { return }
        applyRemoteReadSummary(from: remote, to: &conversation.messages[index], readReceiptsEnabled: readReceiptsEnabled)
    }

    // Source Stores/ConversationStore+ReadState.swift:632; pure value snapshot counterpart.
    func stripReadReceiptDetails(from message: inout ChatMessage) {
        message.readBy = []
        message.unreadBy = []
        message.readCount = nil
        message.unreadCount = nil
        message.readStateKnown = false
        message.canViewReadDetails = false
        message.reactionDetails = []
        if message.status == .read {
            message.status = .sent
        }
    }

    // Source Stores/ConversationStore+RemoteMerge.swift:652; pure value snapshot counterpart.
    func mergeExistingRemoteState(from previous: ChatMessage, into message: inout ChatMessage) {
        // History and sidecars are fetched independently. A stale body or read
        // state cannot undo a recall or deletion that has already been applied.
        if previous.isDeletedLocally, !message.isDeletedLocally {
            markMessageAsAdminDeleted(&message)
        } else if previous.status == .recalled, message.status != .recalled {
            markMessageAsRecalled(&message, recallText: nil)
        }
        guard message.status != .recalled, !message.isDeletedLocally else { return }
        if let fileID = previous.attachmentFileID, !fileID.isEmpty,
           message.attachmentFileID == fileID, message.kind == previous.kind,
           !previous.isDeletedLocally, !message.isDeletedLocally,
           previous.status != .recalled, message.status != .recalled,
           (message.attachmentVersion.isEmpty || previous.attachmentVersion.isEmpty || message.attachmentVersion == previous.attachmentVersion),
           (message.attachmentChecksum.isEmpty || previous.attachmentChecksum.isEmpty || message.attachmentChecksum == previous.attachmentChecksum),
           (message.attachmentSizeBytes == nil || previous.attachmentSizeBytes == nil || message.attachmentSizeBytes == previous.attachmentSizeBytes) {
            if message.attachmentCacheKey.isEmpty { message.attachmentCacheKey = previous.attachmentCacheKey }
            if message.attachmentVersion.isEmpty { message.attachmentVersion = previous.attachmentVersion }
            if message.attachmentChecksum.isEmpty { message.attachmentChecksum = previous.attachmentChecksum }
            if message.attachmentMimeType.isEmpty { message.attachmentMimeType = previous.attachmentMimeType }
            if message.attachmentExtension.isEmpty { message.attachmentExtension = previous.attachmentExtension }
            if message.attachmentSizeBytes == nil { message.attachmentSizeBytes = previous.attachmentSizeBytes }
        }
		if previous.editRevision >= message.editRevision && previous.editRevision > 0 {
			message.text = previous.text
			message.isEdited = previous.isEdited
			message.editRevision = previous.editRevision
		}
        if message.senderAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.senderAvatarURL = previous.senderAvatarURL
        }
        if message.senderAvatarVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.senderAvatarVersion = previous.senderAvatarVersion
        }
        if message.senderAvatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.senderAvatarUpdatedAt = previous.senderAvatarUpdatedAt
        }
        if message.senderAvatarSeed == 0 {
            message.senderAvatarSeed = previous.senderAvatarSeed
        }
        message.reactions = previous.reactions
        message.reactionDetails = previous.reactionDetails
        message.readBy = previous.readBy
        message.unreadBy = previous.unreadBy
        message.readCount = previous.readCount
        message.readStateKnown = previous.readStateKnown
        message.deliveryStateKnown = message.deliveryStateKnown || previous.deliveryStateKnown
        message.canViewReadDetails = previous.canViewReadDetails
        if previous.status == .read || (previous.readCount ?? 0) > 0 || !previous.readBy.isEmpty {
            message.status = .read
        }
    }

    // Source Stores/ConversationStore+History.swift:460; pure value snapshot counterpart.
    func retainedMessages(_ messages: [ChatMessage], for retention: MessageWindowRetention) -> [ChatMessage] {
        guard case .latestTail(let limit) = retention else { return messages }
        let boundedLimit = max(1, limit)
        let timelineMessages = messages.filter { message in
            !message.isPinnedContextOnly && !isPendingLocalMessage(message)
        }
        guard timelineMessages.count > boundedLimit else { return messages }
        let tailIDs = Set(timelineMessages.suffix(boundedLimit).map(\.id))
        var retained = messages.filter { message in
            tailIDs.contains(message.id)
                || isPendingLocalMessage(message)
                || message.isPinnedContextOnly
        }
        retained.sort(by: messageTimelinePrecedes)
        return retained
    }

    // Source Stores/ConversationStore+RemoteMerge.swift:8; pure value snapshot counterpart.
    func messageSequenceCoveredThrough(in conversation: ConversationMessageSnapshot) -> Int64 {
        let explicitCoverage = max(0, conversation.messageCoveredThroughSeq)
        if conversation.messageCoverageRequiresRecovery {
            return explicitCoverage
        }
        return max(explicitCoverage, inferredMessageSequenceCoverage(conversation.messages))
    }

    // Source Stores/ConversationStore+RemoteMerge.swift:452; pure value snapshot counterpart.
    func inferredMessageSequenceCoverage(_ messages: [ChatMessage]) -> Int64 {
        var sequences = Set<Int64>()
        var minimumSequence: Int64?
        for message in messages {
            guard message.channelSeq > 0,
                  !message.isPinnedContextOnly,
                  !isPendingLocalMessage(message) else { continue }
            sequences.insert(message.channelSeq)
            if let currentMinimum = minimumSequence {
                minimumSequence = min(currentMinimum, message.channelSeq)
            } else {
                minimumSequence = message.channelSeq
            }
        }
        guard var coveredThrough = minimumSequence else { return 0 }
        while sequences.contains(coveredThrough + 1) {
            coveredThrough += 1
        }
        return coveredThrough
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

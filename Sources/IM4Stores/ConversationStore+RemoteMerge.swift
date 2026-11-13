// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN

public extension ConversationStore {
    func latestReadableSequence(in conversation: ConversationMessageSnapshot) -> Int64 {
        messageSequenceCoveredThrough(in: conversation)
    }

    func messageSequenceCoveredThrough(in conversation: ConversationMessageSnapshot) -> Int64 {
        let explicitCoverage = max(0, conversation.messageCoveredThroughSeq)
        if conversation.messageCoverageRequiresRecovery {
            return explicitCoverage
        }
        return max(explicitCoverage, inferredMessageSequenceCoverage(conversation.messages))
    }

    func messageSequenceRecoveryTarget(for conversation: ConversationMessageSnapshot) -> MessageSequenceRecoveryTarget? {
        let coveredThrough = messageSequenceCoveredThrough(in: conversation)
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免为最大序号生成临时数组
        let observedThrough = max(
            conversation.lastMsgSeq,
            ConversationSequenceInspector.maximumChannelSeq(in: conversation.messages) ?? 0
        )
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        guard observedThrough > coveredThrough else { return nil }
        return MessageSequenceRecoveryTarget(afterSeq: coveredThrough, throughSeq: observedThrough)
    }

    func resolvedGroupMemberCount(incoming: Int?, existing: Int?, participants: [IMUser]) -> Int? {
        // WDT_APP_CONTRACT_20261021_05: no inference from loaded members or stale aggregates.
        guard let incoming, incoming > 0 else { return nil }
        return incoming
    }

    @discardableResult
    func mergeRemoteConversationList(
        entries: [RemoteConversationMergeEntry],
        replacing: Bool,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> MergedRemoteConversationsResult {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let previousByChannelID = conversationsByChannelID(channelIDForConversation: channelIDForConversation)
            var nextByChannelID: [String: ConversationMessageSnapshot] = replacing ? [:] : previousByChannelID
            for entry in entries {
                nextByChannelID[entry.channelID] = entry.conversation
            }
            let ordered = deduplicatedConversationsByID(Array(nextByChannelID.values)).sorted(by: conversationListPrecedes)
            let merged = conversationsEnforcingGlobalRTCCallRecordExactOnce(ordered)
            // JHT_MOD_BEGIN CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改开始：复用无临时数组索引，降低远端会话合并主线程分配
            let mergedByChannelID = Self.indexedConversations(
                merged,
                channelIDForConversation: channelIDForConversation
            )
            // JHT_MOD_END CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改结束
            let soundCandidates = entries.compactMap { entry -> RemoteConversationSoundCandidate? in
                guard let previous = previousByChannelID[entry.channelID],
                      let normalizedMapped = mergedByChannelID[entry.channelID] else { return nil }
                return RemoteConversationSoundCandidate(
                    previous: previous,
                    remote: entry.remote,
                    mapped: normalizedMapped
                )
            }
            publishConversationsIfChanged(merged)
            return MergedRemoteConversationsResult(conversations: merged, soundCandidates: soundCandidates)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func replaceLocalMessageWithRemoteConfirmation(
        localID: String,
        remoteMessageID: String,
        remoteMapped: ChatMessage,
        remoteDisplayTime: String,
        remoteCreatedAt: Date?,
        remoteChannelSeq: Int64,
        in conversationID: String,
        readReceiptsEnabled: Bool
    ) -> ConfirmedLocalMessageReplacement? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == localID }) else { return nil }
            let previous = conversationMessageSnapshot(at: cIndex).messages[mIndex]
            let confirmed = confirmedLocalMessage(
                previous: previous,
                remoteMapped: remoteMapped,
                remoteMessageID: remoteMessageID,
                remoteDisplayTime: remoteDisplayTime,
                remoteCreatedAt: remoteCreatedAt,
                remoteChannelSeq: remoteChannelSeq,
                readReceiptsEnabled: readReceiptsEnabled
            )
            // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
            mutateStoredConversation(at: cIndex) { conversation in
                conversation.messages[mIndex] = confirmed
                updateConversationLatestFromMessages(&conversation)
            }
            // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END
            return ConfirmedLocalMessageReplacement(previousMessage: previous, confirmedMessage: confirmed)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func confirmedLocalMessage(
        previous: ChatMessage,
        remoteMapped: ChatMessage,
        remoteMessageID: String,
        remoteDisplayTime: String,
        remoteCreatedAt: Date?,
        remoteChannelSeq: Int64,
        readReceiptsEnabled: Bool
    ) -> ChatMessage {
        let previousPreviewURL = retainedRemoteAttachmentURL(previous.attachmentPreviewURL)
        let previousDownloadURL = retainedRemoteAttachmentURL(previous.attachmentDownloadURL)
        let mergedPreviewURL = remoteMapped.attachmentPreviewURL.isEmpty ? previousPreviewURL : remoteMapped.attachmentPreviewURL
        let mergedDownloadURL = remoteMapped.attachmentDownloadURL.isEmpty ? previousDownloadURL : remoteMapped.attachmentDownloadURL
        var merged = ChatMessage(
            id: remoteMessageID,
            senderId: remoteMapped.senderProvenance == .authoritativeStored
                ? remoteMapped.senderId
                : previous.senderId,
            senderProvenance: remoteMapped.senderProvenance,
            senderName: previous.senderName,
            senderAvatarURL: remoteMapped.senderAvatarURL.isEmpty ? previous.senderAvatarURL : remoteMapped.senderAvatarURL,
            senderAvatarVersion: remoteMapped.senderAvatarVersion.isEmpty ? previous.senderAvatarVersion : remoteMapped.senderAvatarVersion,
            senderAvatarUpdatedAt: remoteMapped.senderAvatarUpdatedAt.isEmpty ? previous.senderAvatarUpdatedAt : remoteMapped.senderAvatarUpdatedAt,
            senderAvatarSeed: remoteMapped.senderAvatarSeed == 0 ? previous.senderAvatarSeed : remoteMapped.senderAvatarSeed,
            text: previous.text,
            time: remoteDisplayTime,
            createdAt: remoteCreatedAt ?? previous.createdAt,
            channelSeq: remoteChannelSeq,
            isOutgoing: previous.isOutgoing,
            status: previous.status == .read || (previous.readCount ?? 0) > 0 || !previous.readBy.isEmpty ? .read : .sent,
            kind: previous.kind,
            reactions: previous.reactions,
            reactionDetails: previous.reactionDetails,
            readBy: previous.readBy,
            unreadBy: previous.unreadBy,
            readCount: previous.readCount,
            readStateKnown: previous.readStateKnown,
            deliveryStateKnown: previous.deliveryStateKnown,
            canViewReadDetails: previous.canViewReadDetails,
            quote: remoteMapped.quote ?? previous.quote,
            attachmentName: previous.attachmentName,
            attachmentMeta: previous.attachmentMeta,
            attachmentFileID: remoteMapped.attachmentFileID?.isEmpty == false ? remoteMapped.attachmentFileID : previous.attachmentFileID,
            attachmentSizeBytes: previous.attachmentSizeBytes,
            attachmentPreviewURL: mergedPreviewURL,
            attachmentDownloadURL: mergedDownloadURL,
            attachmentPreviewAvailable: (!mergedPreviewURL.isEmpty && previous.attachmentPreviewAvailable) || remoteMapped.attachmentPreviewAvailable,
            attachmentDownloadAvailable: (!mergedDownloadURL.isEmpty && previous.attachmentDownloadAvailable) || remoteMapped.attachmentDownloadAvailable,
            attachmentTransferProgress: nil,
            isPinned: previous.isPinned,
            isFavorited: previous.isFavorited,
            isDeletedLocally: previous.isDeletedLocally,
            isEdited: previous.isEdited,
            auditTags: previous.auditTags,
            reportState: previous.reportState,
            serverTrace: remoteMessageID
        )
        merged.attachmentMediaCategory = remoteMapped.attachmentMediaCategory.isEmpty ? previous.attachmentMediaCategory : remoteMapped.attachmentMediaCategory
        merged.attachmentMimeType = remoteMapped.attachmentMimeType.isEmpty ? previous.attachmentMimeType : remoteMapped.attachmentMimeType
        merged.attachmentCacheKey = remoteMapped.attachmentCacheKey.isEmpty ? previous.attachmentCacheKey : remoteMapped.attachmentCacheKey
        merged.attachmentVersion = remoteMapped.attachmentVersion.isEmpty ? previous.attachmentVersion : remoteMapped.attachmentVersion
        merged.attachmentChecksum = remoteMapped.attachmentChecksum.isEmpty ? previous.attachmentChecksum : remoteMapped.attachmentChecksum
        merged.attachmentExtension = remoteMapped.attachmentExtension.isEmpty ? previous.attachmentExtension : remoteMapped.attachmentExtension
        merged.attachmentThumbnailURL = remoteMapped.attachmentThumbnailURL.isEmpty ? retainedRemoteAttachmentURL(previous.attachmentThumbnailURL) : remoteMapped.attachmentThumbnailURL
        merged.attachmentPosterURL = remoteMapped.attachmentPosterURL.isEmpty ? retainedRemoteAttachmentURL(previous.attachmentPosterURL) : remoteMapped.attachmentPosterURL
        merged.attachmentCoverURL = remoteMapped.attachmentCoverURL.isEmpty ? retainedRemoteAttachmentURL(previous.attachmentCoverURL) : remoteMapped.attachmentCoverURL
        merged.attachmentPreviewKind = remoteMapped.attachmentPreviewKind.isEmpty ? previous.attachmentPreviewKind : remoteMapped.attachmentPreviewKind
        merged.attachmentContentDisposition = remoteMapped.attachmentContentDisposition.isEmpty ? previous.attachmentContentDisposition : remoteMapped.attachmentContentDisposition
        merged.attachmentWidth = remoteMapped.attachmentWidth ?? previous.attachmentWidth
        merged.attachmentHeight = remoteMapped.attachmentHeight ?? previous.attachmentHeight
        merged.attachmentDurationSeconds = remoteMapped.attachmentDurationSeconds ?? previous.attachmentDurationSeconds
        merged.attachmentUploadStatus = normalizedCompletedAttachmentStatus(remoteMapped.attachmentUploadStatus)
        merged.attachmentUploadFailure = nil
        merged.replyContext = remoteMapped.replyContext ?? previous.replyContext
        merged.mentionExcluded = remoteMapped.mentionExcluded || previous.mentionExcluded
        merged.mentionAll = remoteMapped.mentionAll || previous.mentionAll
        merged.mentionedUsers = remoteMapped.mentionedUsers.isEmpty
            ? previous.mentionedUsers
            : remoteMapped.mentionedUsers
        if !readReceiptsEnabled {
            stripReadReceiptDetails(from: &merged)
        }
        return merged
    }

    func mergeMappedRemoteMessages(
        previous: ConversationMessageSnapshot?,
        mappedRemoteMessages: [MappedRemoteMessage],
        readReceiptsEnabled: Bool,
        fromRealtime: Bool,
        windowRetention: MessageWindowRetention = .preserveLoadedHistory,
        sequenceCoverageAfterSeq: Int64? = nil,
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_PREPEND_STORE_PARAM - 修改开始：更早消息分页 beforeSeq 触发保守快捷合并
        olderHistoryBeforeSeq: Int64? = nil,
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_PREPEND_STORE_PARAM - 修改结束：更早消息分页 beforeSeq 触发保守快捷合并
        coveredChannelSeqs: [Int64]? = nil,
        effectiveReadSeq: Int64 = 0
    ) -> MergedRemoteMessagesResult {
        ConversationMessageMergeReducer(conversations: conversationMessageSnapshots(), rtcAuthority: rtcAuthority)
            .mergeMappedRemoteMessages(previous: previous, mappedRemoteMessages: mappedRemoteMessages,
            readReceiptsEnabled: readReceiptsEnabled, fromRealtime: fromRealtime,
            windowRetention: windowRetention, sequenceCoverageAfterSeq: sequenceCoverageAfterSeq,
            olderHistoryBeforeSeq: olderHistoryBeforeSeq, coveredChannelSeqs: coveredChannelSeqs,
            effectiveReadSeq: effectiveReadSeq)
    }

    private func inferredMessageSequenceCoverage(_ messages: [ChatMessage]) -> Int64 {
        // JHT_MOD_BEGIN MESSAGE_SEQUENCE_COVERAGE_LINEAR_PERF_20260912 - 修改开始：保持覆盖语义不变，去掉大消息数组排序开销
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
        // JHT_MOD_END MESSAGE_SEQUENCE_COVERAGE_LINEAR_PERF_20260912 - 修改结束
        return coveredThrough
    }

    @discardableResult
    func applyMergedRemoteMessagesConversation(
        channelID: String,
        kind: ConversationKind,
        previous: ConversationMessageSnapshot?,
        title: String,
        subtitle: String,
        participants: [IMUser],
        messages: [ChatMessage],
        latestMessage: ChatMessage,
        incomingRealtimeMessages: [ChatMessage],
        latestKnownSeq: Int64,
        messageCoveredThroughSeq: Int64 = 0,
        messageCoverageRequiresRecovery: Bool = false,
        fromRealtime: Bool,
        isActiveRealtimeConversation: Bool,
        canAutoReadActiveRealtimeConversation: Bool,
        memberCount: Int?,
        accentHex: UInt,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String,
        effectiveReadSeq: Int64 = 0,
        historyBoundary: HistoryVisibilityBoundary? = nil,
        preparedRealtime: AppliedRemoteMessagesConversationResult? = nil, // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        preparedChangesState: Bool = true
    ) -> AppliedRemoteMessagesConversationResult {
        if let preparedRealtime { // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
            return applyPreparedRealtimeConversation(preparedRealtime, previousID: previous?.id, channelID: channelID, changed: preparedChangesState)
        }
        // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let hasNewRealtimeActivity = fromRealtime && !incomingRealtimeMessages.isEmpty
            let latestMessageIsCoveredByRead = fromRealtime
                && latestMessage.channelSeq > 0
                && latestMessage.channelSeq <= effectiveReadSeq
            let candidateSortTimestamp = effectiveCreatedAt(for: latestMessage)?.timeIntervalSince1970 ?? 0
            let previousSortTimestamp = previous?.sortTimestamp ?? 0
            let latestDisplayTime = latestMessage.time.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? previous?.time ?? ""
                : latestMessage.time
            let hasNewerTimestamp = candidateSortTimestamp > previousSortTimestamp + 0.5
            let hasNewerSequence = latestKnownSeq > (previous?.lastMsgSeq ?? 0)
            let shouldUseLatestSummary = !latestMessageIsCoveredByRead
                && (previous == nil || hasNewRealtimeActivity || hasNewerTimestamp || hasNewerSequence)
            let sortTimestamp: TimeInterval
            let resolvedTime: String
            if shouldUseLatestSummary {
                sortTimestamp = max(previousSortTimestamp, candidateSortTimestamp)
                resolvedTime = latestDisplayTime
            } else {
                sortTimestamp = previousSortTimestamp > 0 ? previousSortTimestamp : candidateSortTimestamp
                resolvedTime = previous?.time ?? latestDisplayTime
            }

            let shouldAutoRead = fromRealtime
                && isActiveRealtimeConversation
                && canAutoReadActiveRealtimeConversation
                && !incomingRealtimeMessages.isEmpty
                && kind != .system
            let previousReadCoversKnownMessages = effectiveReadSeq > 0
                && (previous?.lastMsgSeq ?? 0) > 0
                && (previous?.lastMsgSeq ?? 0) <= effectiveReadSeq
            let previousUnread = previousReadCoversKnownMessages ? 0 : previous?.unread ?? 0
            let nextUnread: Int
            if fromRealtime,
               !incomingRealtimeMessages.isEmpty,
               (!isActiveRealtimeConversation || !canAutoReadActiveRealtimeConversation) {
                nextUnread = previousUnread + incomingRealtimeMessages.count
            } else {
                nextUnread = previousUnread
            }
            let firstNewUnreadMessage = fromRealtime && previousUnread == 0 && nextUnread > 0
                ? incomingRealtimeMessages.first
                : nil
            let nextFirstUnreadSeq: Int64 = {
                guard nextUnread > 0 else { return 0 }
                if previousUnread > 0 {
                    return previous?.firstUnreadSeq ?? 0
                }
                return firstNewUnreadMessage?.channelSeq ?? 0
            }()
            let nextFirstUnreadMessageID: String = {
                guard nextUnread > 0 else { return "" }
                if previousUnread > 0 {
                    return previous?.firstUnreadMessageID ?? ""
                }
                return firstNewUnreadMessage?.id ?? ""
            }()
            let previousUnreadReactionCount = previousReadCoversKnownMessages ? 0 : previous?.unreadReactionCount ?? 0
            let previousHasUnreadReaction = previousReadCoversKnownMessages ? false : previous?.hasUnreadReaction == true
            let hasUnreadReaction = nextUnread > 0 && (previousHasUnreadReaction || previousUnreadReactionCount > 0)
            let resolvedMemberCount = kind == .group
                ? resolvedGroupMemberCount(incoming: memberCount, existing: previous?.memberCount ?? 0, participants: participants)
                : memberCount
            let resolvedHistoryBoundary = historyBoundary ?? self.historyBoundary(for: previous)
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = kind == .direct && normalizedTitle.isEmpty
                ? previous?.title ?? title
                : title
            let resolvedParticipants = kind == .direct && participants.isEmpty
                ? previous?.participants ?? participants
                : participants
            let mapped = ConversationMessageSnapshot(
                id: kind == .system ? "system_notification" : (previous?.id ?? channelID),
                title: resolvedTitle,
                subtitle: subtitle,
                kind: kind,
                lastMessage: shouldUseLatestSummary ? conversationListPreview(latestMessage) : previous?.lastMessage ?? "",
                time: resolvedTime,
                unread: nextUnread,
                isPinned: previous?.isPinned ?? false,
                isMuted: previous?.isMuted ?? false,
                memberCount: resolvedMemberCount,
                accentHex: previous?.accentHex ?? accentHex,
                participants: resolvedParticipants,
                messages: messages,
                avatarURL: avatarURL.isEmpty ? previous?.avatarURL ?? "" : avatarURL,
                avatarVersion: avatarVersion.isEmpty ? previous?.avatarVersion ?? "" : avatarVersion,
                avatarUpdatedAt: avatarUpdatedAt.isEmpty ? previous?.avatarUpdatedAt ?? "" : avatarUpdatedAt,
                hasUnreadReaction: hasUnreadReaction,
                unreadReactionCount: hasUnreadReaction ? previousUnreadReactionCount : 0,
                lastMsgSeq: latestKnownSeq,
                messageCoveredThroughSeq: messageCoveredThroughSeq,
                messageCoverageRequiresRecovery: messageCoverageRequiresRecovery,
                lastReadSeq: max(previous?.lastReadSeq ?? 0, effectiveReadSeq),
                firstUnreadSeq: nextFirstUnreadSeq,
                firstUnreadMessageID: nextFirstUnreadMessageID,
                unreadAnchorSeq: nextUnread > 0 ? (previousUnread > 0 ? previous?.unreadAnchorSeq ?? 0 : nextFirstUnreadSeq) : 0,
                unreadAnchorState: nextUnread > 0 ? (previousUnread > 0 ? previous?.unreadAnchorState ?? "unread" : "unread") : "none",
                hasMention: previous?.hasMention ?? false,
                mentionCount: previous?.mentionCount ?? 0,
                mentionSummaryText: previous?.mentionSummaryText ?? "",
                mentionSummaryMessageID: previous?.mentionSummaryMessageID ?? "",
                mentionSummaryChannelSeq: previous?.mentionSummaryChannelSeq ?? 0,
                sortTimestamp: sortTimestamp,
                historyVisibleFromSeq: resolvedHistoryBoundary?.fromSeq ?? previous?.historyVisibleFromSeq ?? 1,
                historyLimited: resolvedHistoryBoundary?.limited ?? previous?.historyLimited ?? false,
                historyBoundaryConfirmed: resolvedHistoryBoundary?.confirmed ?? previous?.historyBoundaryConfirmed ?? false
            )

            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var removed: [Conversation] = []
            if let previous, let existingIndex = next.firstIndex(where: { $0.id == previous.id }) {
                removed = [next[existingIndex].conversation]
                next[existingIndex] = mapped
            } else if let existingIndex = next.firstIndex(where: { $0.id == mapped.id || $0.id == channelID }) {
                removed = [next[existingIndex].conversation]
                next[existingIndex] = mapped
            } else {
                next.insert(mapped, at: 0)
            }
            publishConversationsIfChanged(next.sorted(by: conversationListPrecedes),
                unreadUpdate: .delta(removing: removed, adding: [mapped.conversation], baseRevision: unreadRevision))

            return AppliedRemoteMessagesConversationResult(
                conversation: mapped,
                incomingRealtimeMessages: incomingRealtimeMessages,
                shouldPlayIncomingSound: hasNewRealtimeActivity && !isActiveRealtimeConversation && !mapped.isMuted,
                shouldAutoRead: shouldAutoRead
            )
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func effectiveCreatedAt(for message: ChatMessage) -> Date? {
        message.createdAt
    }

    func isPendingLocalMessage(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed
    }

    func messageTimelinePrecedes(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.channelSeq > 0, rhs.channelSeq > 0, lhs.channelSeq != rhs.channelSeq {
            return lhs.channelSeq < rhs.channelSeq
        }
        let lhsDate = lhs.createdAt ?? Date.distantPast
        let rhsDate = rhs.createdAt ?? Date.distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id < rhs.id
    }

    func mergeExistingRemoteState(from previous: ChatMessage, into message: inout ChatMessage) {
        // History and sidecars are fetched independently. A stale body or read
        // state cannot undo a recall or deletion that has already been applied.
        if previous.isDeletedLocally, !message.isDeletedLocally {
            markMessageAsAdminDeleted(&message)
        } else if previous.status == .recalled, message.status != .recalled {
            markMessageAsRecalled(&message, recallText: nil)
        }
        guard message.status != .recalled, !message.isDeletedLocally else { return }
        // WDT_CHAT_MEDIA_CACHE_REUSE_20261102: history payloads can omit file-detail cache metadata.
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

    private func normalizedCompletedAttachmentStatus(_ remoteStatus: String) -> String {
        let trimmed = remoteStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "uploaded" : trimmed
    }

    private func retainedRemoteAttachmentURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), url.isFileURL {
            return ""
        }
        return rawValue
    }

    func unavailableReplyContext(messageID: String = "") -> MessageReplyContext {
        MessageReplyContext(
            messageID: messageID,
            summary: "原消息不可查看/已撤回",
            isUnavailable: true
        )
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END // WDT_IOS1_INCREMENTAL_UNREAD_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END

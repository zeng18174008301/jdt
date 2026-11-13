import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension RealtimeConversationReducer {
    // Source Stores/ConversationStore+RemoteMerge.swift:476; pure value snapshot counterpart.
    func makeMergedRemoteMessagesConversation(
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
        historyBoundary: HistoryVisibilityBoundary? = nil
    ) -> AppliedRemoteMessagesConversationResult {
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
                lastMessage: shouldUseLatestSummary ? latestMessage.conversationListPreview : previous?.lastMessage ?? "",
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

            return AppliedRemoteMessagesConversationResult(
                conversation: mapped,
                incomingRealtimeMessages: incomingRealtimeMessages,
                shouldPlayIncomingSound: hasNewRealtimeActivity && !isActiveRealtimeConversation && !mapped.isMuted,
                shouldAutoRead: shouldAutoRead
            )
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

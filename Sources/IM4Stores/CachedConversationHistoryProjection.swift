import Foundation
import IM4Domain

public enum CachedConversationHistoryProjection: Sendable {
    public typealias HistoryVisibilityBoundary = ConversationStore.HistoryVisibilityBoundary

    public static func preparedForLocalHistoryProjection(_ conversation: ConversationMessageSnapshot, conversationListPreview: (ChatMessage) -> String) -> ConversationMessageSnapshot {
        guard conversation.kind == .group else { return conversation }
        guard conversation.historyBoundaryConfirmed else {
            return awaitingHistoryBoundaryConfirmation(conversation)
        }
        let persistedBoundary = HistoryVisibilityBoundary(
            fromSeq: conversation.historyVisibleFromSeq,
            limited: conversation.historyLimited,
            confirmed: true
        )
        return applyingHistoryVisibilityBoundary(
            persistedBoundary,
            to: conversation, conversationListPreview: conversationListPreview
        ) ?? awaitingHistoryBoundaryConfirmation(conversation)
    }

    private static func awaitingHistoryBoundaryConfirmation(_ conversation: ConversationMessageSnapshot) -> ConversationMessageSnapshot {
        guard conversation.kind == .group else { return conversation }
        var updated = conversation
        updated.messages = []
        updated.lastMessage = ""
        updated.time = ""
        updated.unread = 0
        updated.hasUnreadReaction = false
        updated.unreadReactionCount = 0
        updated.firstUnreadSeq = 0
        updated.firstUnreadMessageID = ""
        updated.messageCoveredThroughSeq = 0
        updated.unreadAnchorSeq = 0
        updated.unreadAnchorState = "none"
        updated.hasMention = false
        updated.mentionCount = 0
        updated.mentionSummaryText = ""
        updated.mentionSummaryMessageID = ""
        updated.mentionSummaryChannelSeq = 0
        updated.sortTimestamp = 0
        updated.historyBoundaryConfirmed = false
        return updated
    }

    private static func applyingHistoryVisibilityBoundary(
        _ boundary: HistoryVisibilityBoundary?,
        to conversation: ConversationMessageSnapshot?,
        keepPendingLocalMessages: Bool = true,
        conversationListPreview: (ChatMessage) -> String
    ) -> ConversationMessageSnapshot? {
        guard var updated = conversation else { return nil }
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
        refreshHistoryBoundedSummary(&updated, boundary: resolvedBoundary, conversationListPreview: conversationListPreview)
        return updated
    }

    private static func historyVisibleMessages(
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

    private static func refreshHistoryBoundedSummary(_ conversation: inout ConversationMessageSnapshot, boundary: HistoryVisibilityBoundary, conversationListPreview: (ChatMessage) -> String) {
        if let latest = latestConfirmedMessage(in: conversation.messages.filter { !$0.isPinnedContextOnly })
            ?? latestConfirmedMessage(in: conversation.messages) {
            conversation.lastMessage = conversationListPreview(latest)
            conversation.time = latest.time
            conversation.sortTimestamp = effectiveCreatedAt(for: latest)?.timeIntervalSince1970 ?? conversation.sortTimestamp
        } else if boundary.isRestrictive || conversation.historyBoundaryConfirmed {
            conversation.lastMessage = ""
            conversation.time = ""
            conversation.sortTimestamp = 0
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

    private static func latestConfirmedMessage(in messages: [ChatMessage]) -> ChatMessage? {
        messages.last { message in
            message.status != .failed && message.status != .sending && !message.isDeletedLocally
        }
    }

    private static func effectiveCreatedAt(for message: ChatMessage) -> Date? {
        message.createdAt
    }

    private static func isPendingLocalMessage(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed
    }
}

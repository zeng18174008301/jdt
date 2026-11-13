import IM4Features
import SwiftUI
import UIKit

extension ChatView {
    private func clearUnreadReminderLocally(readToken: String) {
        let token = latestReadAcknowledgementToken
        let resolvedToken = readToken.isEmpty ? token : readToken
        if !resolvedToken.isEmpty {
            lastVisibleReadAckToken = resolvedToken
        }
        pendingUnreadCount = 0
        capturedUnreadCount = 0
        initialUnreadSnapshot = 0
        unreadDividerVisible = false
        didAutoScrollToUnreadAnchor = false
        didScrollTowardUnreadMessages = false
    }

    func clearUnreadReminderAndAckIfNeeded(reason: String) {
        guard didInitialScroll, !isApplyingInitialScroll else { return }
        guard hasUnreadReminder, let observation = visibleIncomingReadObservation else { return }
        guard !isClearingUnreadReminder else { return }
        let token = observation.token
        let scope = screenActions.history.activeConversationHistoryScope()
        let targetConversationID = conversationID
        let epoch = readVisibilityEpoch
        isClearingUnreadReminder = true
        screenActions.history.markConversationRead(conversationID, throughSeq: observation.seq, showToast: false) { success in
            guard scope == screenActions.history.activeConversationHistoryScope(), targetConversationID == conversationID,
                  epoch == readVisibilityEpoch else { return }
            isClearingUnreadReminder = false
            if success, conversation.lastReadSeq >= observation.seq {
                if token == latestReadAcknowledgementToken {
                    clearUnreadReminderLocally(readToken: token)
                } else {
                    markVisibleIncomingMessagesReadIfNeeded()
                }
            } else {
                if !token.isEmpty, lastVisibleReadAckToken == token {
                    lastVisibleReadAckToken = ""
                }
                if let message = chatReadSyncFailureToastMessage(isAutomaticRecoveryPath: true) {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast(message)
                }
            }
        }
    }

    func markUnreadReminderReadIfUserScrolledTowardUnread() {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              didScrollTowardUnreadMessages,
              !isUserBrowsingHistory,
              !isReadOnlySystemConversation else {
            return
        }
        clearUnreadReminderAndAckIfNeeded(reason: "scroll_toward_unread")
    }

    private func markUnreadReminderReadIfDividerPassed() {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              didScrollTowardUnreadMessages,
              !isUserBrowsingHistory,
              !isReadOnlySystemConversation else {
            return
        }
        clearUnreadReminderAndAckIfNeeded(reason: "unread_divider_passed")
    }

    private func markUnreadReminderReadIfUnreadMessageVisible(_ message: ChatMessage) {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              canClearUnreadReminderFromVisibleProgress,
              !isReadOnlySystemConversation,
              let firstUnreadMessageID,
              let firstUnreadIndex = conversation.messages.firstIndex(where: { $0.id == firstUnreadMessageID }),
              let visibleIndex = conversation.messages.firstIndex(where: { $0.id == message.id }),
              visibleIndex >= firstUnreadIndex else {
            return
        }
        clearUnreadReminderAndAckIfNeeded(reason: "unread_message_visible")
    }

    private func markUnreadReminderReadIfLatestIncomingVisible(_ message: ChatMessage) {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              canClearUnreadReminderFromVisibleProgress,
              !isReadOnlySystemConversation else {
            return
        }
        guard let latest = latestReadableIncomingMessage(), latest.id == message.id else { return }
        clearUnreadReminderAndAckIfNeeded(reason: "latest_incoming_visible")
    }

    private func markUnreadReminderReadIfBottomMessageVisible(_ message: ChatMessage) {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              canClearUnreadReminderFromVisibleProgress,
              !isReadOnlySystemConversation,
              conversation.messages.last?.id == message.id else {
            return
        }
        clearUnreadReminderAndAckIfNeeded(reason: "bottom_message_visible")
    }

    var canClearUnreadReminderFromVisibleProgress: Bool {
        chatCanClearUnreadReminderFromVisibleProgress(
            isUserBrowsingHistory: isUserBrowsingHistory,
            isAtBottom: isAtBottom,
            didScrollTowardUnreadMessages: didScrollTowardUnreadMessages
        )
    }

    private var visibleIncomingReadObservation: (token: String, seq: Int64)? {
        ChatVisibleIncomingReadInput(metrics: scrollMetricsMeasurements.metrics,
            row: scrollMetricsMeasurements.incomingRow, expectedToken: latestReadAcknowledgementToken,
            epoch: readVisibilityEpoch, isActive: scenePhase == .active,
            scopeMatches: scrollStateConversationID == conversationID
                && scrollStateSessionKey == screenActions.history.activeConversationHistoryScope()).observation
    }

    func markVisibleIncomingMessagesReadIfNeeded() {
        guard didInitialScroll, !isApplyingInitialScroll, !isUserBrowsingHistory, !isReadOnlySystemConversation,
              let observation = visibleIncomingReadObservation else { return }
        if hasUnreadReminder {
            guard canClearUnreadReminderFromVisibleProgress else { return }
            clearUnreadReminderAndAckIfNeeded(reason: "visible_incoming_with_reminder")
            return
        }
        let token = observation.token
        guard token != lastVisibleReadAckToken else { return }
        lastVisibleReadAckToken = token
        let scope = screenActions.history.activeConversationHistoryScope()
        let targetConversationID = conversationID
        let epoch = readVisibilityEpoch
        screenActions.history.markConversationRead(conversationID, throughSeq: observation.seq, showToast: false) { success in
            guard scope == screenActions.history.activeConversationHistoryScope(), targetConversationID == conversationID,
                  epoch == readVisibilityEpoch else { return }
            if (!success || conversation.lastReadSeq < observation.seq), lastVisibleReadAckToken == token {
                lastVisibleReadAckToken = ""
            }
        }
    }

    private func latestReadableIncomingMessage() -> ChatMessage? {
        conversation.messages.last { message in
            guard message.kind != .system,
                  message.status != .recalled,
                  !message.isDeletedLocally,
                  !isMessageAuthoredByCurrentUser(message) else {
                return false
            }
            return message.channelSeq > 0 || !message.id.isEmpty
        }
    }

    func updateRealtimeAutoReadGate() {
        // Receipt of the next WS message is not proof that its row is visible.
        // The measured viewport now owns read advancement for this chat.
        screenActions.history.updateRealtimeConversationAutoRead(conversationID, canAutoRead: false)
    }

}

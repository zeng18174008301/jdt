import IM4Features
import SwiftUI
import UIKit

// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_BEGIN
extension ChatView {
    var conversationHeader: some View {
        let store = screenStores.conversations
        return ChatBubbleSessionObservation(store: screenStores.tenantInteraction,
            sessionSource: screenStores.sessionIdentity, initialIdentity: screenActions.authority.chatBubbleSessionIdentity()) { binding in
            store.observeConversationPresentation(id: conversationID) { snapshot in
                let presentation = snapshot ?? conversation
                PublisherSnapshotView(initialValue: store.alertingUnreadTotal, updates: store.alertingUnreadUpdates) { total in
                    assembledConversationHeader(total: total, binding: binding, presentation: presentation)
                }
            }
        }
    }

    func assembledConversationHeader(total: Int, binding: ChatBubbleSessionBinding, presentation: ConversationMessageSnapshot) -> some View {
        let input = ChatHeaderInput(title: conversationDisplayTitle(for: presentation), isGroup: presentation.kind == .group,
            groupMemberSubtitle: groupMemberSubtitleText, isBatchSelecting: isBatchForwardSelectionActive,
            selectedSourceCount: batchForwardSelectedSourceCount, isReadOnlySystem: isReadOnlySystemConversation,
            backUnreadCount: backUnreadCount(total: total))
        let origin = screenActions.authority.chatBubbleSessionIdentity()
        let generation = binding.generation
        let actions = ChatHeaderActions(
            back: { performHeaderStatusAction(binding: binding, generation: generation, origin: origin, headerBack) },
            search: { performHeaderStatusAction(binding: binding, generation: generation, origin: origin, headerSearch) },
            more: { performHeaderStatusAction(binding: binding, generation: generation, origin: origin, headerMore) })
#if DEBUG
        ChatHeaderStatusDiagnostics.header?(ChatHeaderProbe(input: input, actions: actions, owner: self, origin: origin))
#endif
        return ChatConversationHeaderView(input: input, actions: actions)
    }

    // Existing F4 identity and scope retirement, sampled only at a new UI operation.
    // Already admitted service callbacks retain their original completion contract.
    func performHeaderStatusAction(binding: ChatBubbleSessionBinding, generation: UUID,
                                   origin: ChatBubbleSessionIdentity, _ action: () -> Void) {
        guard binding.generation == generation, screenActions.authority.chatBubbleSessionIdentity() == origin else { return }
        action()
    }

    func headerBack() {
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_BACK_TAP - 修改开始：记录返回点击是否进入 action，以及 dismiss 后页面是否消失
        chatBackDismissAttemptID &+= 1
        let attemptID = chatBackDismissAttemptID
        chatBackDismissAttemptStartedAt = CFAbsoluteTimeGetCurrent()
        chatBackStuckDiagnostic(
            "back_tap",
            force: true,
            extra: "attempt=\(attemptID) batch=\(isBatchForwardSelectionActive)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_BACK_TAP - 修改结束：记录返回点击是否进入 action，以及 dismiss 后页面是否消失
        if isBatchForwardSelectionActive {
            screenActions.forwarding.cancelBatchForward()
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_BATCH_CANCEL - 修改开始：区分多选取消与真实页面返回
            chatBackStuckDiagnostic(
                "back_batch_cancel_done",
                force: true,
                extra: "attempt=\(attemptID)"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_BATCH_CANCEL - 修改结束：区分多选取消与真实页面返回
        } else {
            dismiss()
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_DISMISS_CALLED - 修改开始：记录 dismiss 调用与延迟未消失检查
            chatBackStuckDiagnostic(
                "back_dismiss_called",
                force: true,
                extra: "attempt=\(attemptID)"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard chatBackDismissAttemptID == attemptID,
                      chatBackDisappearedAttemptID != attemptID else { return }
                chatBackStuckDiagnostic(
                    "back_dismiss_pending_after_350ms",
                    force: true,
                    extra: "attempt=\(attemptID) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: chatBackDismissAttemptStartedAt))"
                )
            }
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_DISMISS_CALLED - 修改结束：记录 dismiss 调用与延迟未消失检查
        }
    }

    func headerSearch() {
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        if showSearch { closeHistorySearch() } else { openHistorySearch() }
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
    }

    func headerMore() {
        if conversation.kind == .group {
            showDetail = true
        } else if let user = directProfilePeer {
            selectedUserProfile = user
        } else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast(DirectConversationProfilePeerResolver.unavailableMessage)
        }
    }
}

#if DEBUG
struct ChatHeaderProbe {
    let input: ChatHeaderInput
    let actions: ChatHeaderActions
    let owner: ChatView
    let origin: ChatBubbleSessionIdentity
}
struct ChatAnnouncementProbe {
    let title: String
    let preview: String
    let isBusy: Bool
    let open: () -> Void
    let close: () -> Void
    let owner: ChatView
}
@MainActor enum ChatHeaderStatusDiagnostics {
    static var header: ((ChatHeaderProbe) -> Void)?
    static var announcement: ((ChatAnnouncementProbe) -> Void)?
}
#endif
// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_END

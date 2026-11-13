import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

extension ChatView {
    private func openConversationFromProfile(_ conversationID: String) {
        guard conversationID != self.conversationID else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("已在当前会话")
            return
        }
        linkedConversationRoute = ChatLinkedConversationRoute(id: conversationID)
    }

    func openPendingProfileConversationIfNeeded() {
        guard let conversationID = pendingProfileConversationID else { return }
        pendingProfileConversationID = nil
        DispatchQueue.main.async {
            openConversationFromProfile(conversationID)
        }
    }

    func markSystemConversationReadOnOpenIfNeeded() {
        guard conversation.kind == .system, conversation.unread > 0 else { return }
        screenActions.history.markConversationRead(conversationID, showToast: false)
    }


    func performPendingPinnedJumpIfNeeded() {
        guard let message = pendingPinnedJumpMessage else { return }
        pendingPinnedJumpMessage = nil
        // 旧置顶消息可能只有 context-only 副本；sheet 完整收起后再水合，
        // 消息定位请求会继续保留到目标真正进入可渲染时间线。
        let entry = secondaryEntry()
        Task {
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
            if let targetID = await screenActions.search.prepareMessageJump(
                messageID: message.id,
                channelSeq: message.channelSeq,
                conversationID: conversationID
            ) {
                await MainActor.run { setScrollTarget(targetID, source: .pinnedJump) }
            } else {
                await MainActor.run { /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("原消息可能已删除或不可见") }
            }
        }
    }

    func applyInitialSearchJumpTargetIfNeeded() {
        guard !didApplyInitialSearchJumpTarget,
              !isPreparingInitialSearchJumpTarget,
              let initialSearchJumpTarget else { return }
        didApplyInitialSearchJumpTarget = true
        guard conversationListMessageJumpTarget(initialSearchJumpTarget) != nil else { return }
        isPreparingInitialSearchJumpTarget = true
        _ = evaluateScrollRequest(source: .searchJump, targetID: nil, anchor: .center, userInitiated: true)
        let entry = secondaryEntry()
        Task {
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
            if let messageID = await screenActions.search.prepareSearchJumpTarget(initialSearchJumpTarget, conversationID: conversationID) {
                await MainActor.run {
                    isPreparingInitialSearchJumpTarget = false
                    setScrollTarget(messageID, source: .searchJump)
                }
            } else {
                await MainActor.run {
                    isPreparingInitialSearchJumpTarget = false
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("消息可能已删除、无权限或不可见")
                }
            }
        }
    }

	    func dismissExpressionPanelFromTranscriptTap() {
        guard showEmoji || showTools else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            showEmoji = false
            showTools = false
        }
	    }

    func dismissChatKeyboardFromTranscript(
        trigger: ChatTranscriptKeyboardDismissalTrigger
    ) {
        let plan = chatTranscriptKeyboardDismissalPlan(trigger: trigger)
        guard plan.dismissesKeyboard else { return }
        dismissActiveChatKeyboard()
    }

    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_HANDLER - 修改开始：输入框聚焦时滚动到最新消息
    func scrollToLatestMessageForComposerFocus() {
        guard didInitialScroll, !isApplyingInitialScroll, !conversation.messages.isEmpty else { return }
        isUserBrowsingHistory = false
        isAtBottom = true
        didTriggerOlderHistoryLoadForScrollIntent = false
        transcriptScrollControl.clearSuppression()
        updateRealtimeAutoReadGate()
        setScrollTarget(bottomAnchorID, source: .jumpToLatest, anchor: .bottom)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard didInitialScroll, !isApplyingInitialScroll, !conversation.messages.isEmpty else { return }
            setScrollTarget(bottomAnchorID, source: .jumpToLatest, anchor: .bottom)
        }
    }
    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_HANDLER - 修改结束：输入框聚焦时滚动到最新消息

}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

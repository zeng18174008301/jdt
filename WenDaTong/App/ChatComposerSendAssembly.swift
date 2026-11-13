import IM4Features
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_BEGIN
extension ChatView {
    func sendComposerDraft(_ draft: String, mentionAll: Bool, mentionedUsers: [MentionIdentity]) {
        let allowsMention = conversation.kind == .group
        let activeMentionUsers = allowsMention
            ? mergedMentionUsers(from: mentionedUsers, externalMentions: pendingMentionUsers, in: draft)
            : []
        let activeMentionAll = allowsMention ? mentionAll : false
        let sentReplyQuote = replyQuote
        let activeReplyContext = replyQuote == nil ? nil : replyContext
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_TEXT_SEND_UI - 修改开始：定位发送文本时主线程同步耗时
        let textSendDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
        chatBackStuckDiagnostic(
            "text_send_tap",
            extra: "draft_len=\(draft.count) mention_all=\(activeMentionAll) mentions=\(activeMentionUsers.count)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_TEXT_SEND_UI - 修改结束：定位发送文本时主线程同步耗时
        // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
        let sentDraft: ComposerState.Draft = {
            var value = composerState.draft
            value.input = draft; value.mentionAll = activeMentionAll
            value.mentions = activeMentionUsers; value.externalMentions = []
            return value
        }()
        let origin = composerState.token
        // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
        let didStart = screenActions.messages.sendText(
            draft,
            conversationID: conversationID,
            quote: sentReplyQuote,
            replyContext: activeReplyContext,
            mentionAll: activeMentionAll,
            mentionedUsers: activeMentionUsers
        ) {
            // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
            if let origin { composerState.restoreFailedSend(sentDraft, origin: origin) }
            // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
        }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_TEXT_SEND_UI_RETURN - 修改开始：记录 sendText 同步返回耗时
        chatBackStuckDiagnostic(
            "text_send_return",
            force: didStart,
            extra: "started=\(didStart) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: textSendDiagnosticStartedAt))"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_TEXT_SEND_UI_RETURN - 修改结束：记录 sendText 同步返回耗时
        guard didStart else { return }
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：文本发送成功后主动收起系统键盘，不影响发送失败时的草稿回填
        dismissActiveChatKeyboard()
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
        if pendingUnreadCount > 0 {
            clearUnreadReminderAndAckIfNeeded(reason: "send_before_reply")
        }
    //                            withoutSendLayoutAnimation {
    //                                pendingOwnSendScrollBaselineCount = conversation.messages.count
    //                                isUserBrowsingHistory = false
    //                                isAtBottom = true
    //                                transcriptScrollControl.clearSuppression()
    //                            }
    //                            withoutSendLayoutAnimation {
    //                                input = ""
    //                                pendingMentionAll = false
    //                                pendingMentionUsers.removeAll()
    //                                replyQuote = nil
    //                                replyContext = nil
    //                                showEmoji = false
    //                                showTools = false
    //                            }
        // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_STATE_BATCH - 修改开始：发送后输入栏状态合并更新
        withoutSendLayoutAnimation {
            pendingOwnSendScrollBaselineCount = conversation.messages.count
            isUserBrowsingHistory = false
            isAtBottom = true
            transcriptScrollControl.clearSuppression()
            input = ""
            pendingMentionAll = false
            pendingMentionUsers.removeAll()
            replyQuote = nil
            replyContext = nil
            showEmoji = false
            showTools = false
        }
        // JHT_MOD_END CHAT_SEND_UI_PERF_END_STATE_BATCH - 修改结束：发送后输入栏状态合并更新
    }
}
// WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_END

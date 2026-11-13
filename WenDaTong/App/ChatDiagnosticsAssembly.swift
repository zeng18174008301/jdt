import IM4Features
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

extension ChatView {
    func beginChatOpenPerfTrace(reason: String, force: Bool = false) {
        guard force || chatOpenPerfConversationID != conversationID else { return }
        chatOpenStartedAt = CFAbsoluteTimeGetCurrent()
        chatOpenPerfConversationID = conversationID
        didLogChatFirstFrame = false
        didLogChatHistoryReady = false
        didLogChatSideDataReady = false
        print("[JHT Perf] chat_open_start reason=\(reason) kind=\(conversation.kind.rawValue) cached_messages=\(conversation.messages.count) unread=\(conversation.unread)")
    }

    func logChatFirstFrameIfNeeded(stage: String) {
        guard chatOpenPerfConversationID == conversationID, !didLogChatFirstFrame else { return }
        didLogChatFirstFrame = true
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - chatOpenStartedAt) * 1000)
        print("[JHT Perf] chat_first_frame_ms=\(elapsedMs) stage=\(stage) kind=\(conversation.kind.rawValue) rendered_messages=\(conversation.messages.count)")
    }

    func logChatHistoryReadyIfNeeded(reason: String) {
        guard chatOpenPerfConversationID == conversationID, !didLogChatHistoryReady else { return }
        let readiness = ChatHistoryReadinessInput(isLoading: screenStores.conversations.historyLoadingConversationIDs().contains(conversationID),
            hasVisibleMessages: !conversation.messages.isEmpty,
            hasHistoryResult: screenStores.conversations.historyMessagesByConversationID()[conversationID] != nil)
        guard readiness.isReady else { return }
        didLogChatHistoryReady = true
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - chatOpenStartedAt) * 1000)
        print("[JHT Perf] chat_visible_history_ready_ms=\(elapsedMs) reason=\(reason) messages=\(conversation.messages.count)")
    }

    func logChatSideDataReadyIfNeeded(reason: String) {
        guard chatOpenPerfConversationID == conversationID,
              conversation.kind == .group,
              !didLogChatSideDataReady else { return }
        let hasGroupDetail = currentGroup.notice != "群资料同步中" || !currentGroup.members.isEmpty
        let hasSideData = hasGroupDetail || currentGroupAnnouncement != nil || !pinnedMessages.isEmpty
        guard hasSideData else { return }
        didLogChatSideDataReady = true
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - chatOpenStartedAt) * 1000)
        print("[JHT Perf] chat_side_data_ready_ms=\(elapsedMs) reason=\(reason) pinned=\(pinnedMessages.count) announcement=\(currentGroupAnnouncement != nil)")
    }

    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_HELPERS - 修改开始：统一聊天返回卡住定位日志，避免输出消息正文和敏感标识
    func chatBackStuckDiagnostic(_ event: String, force: Bool = false, extra: String = "") {
#if DEBUG
        guard chatBackDiagnosticsEnabled else { return }
        let uploadingCount = conversation.messages.filter {
            $0.attachmentTransferProgress != nil || !$0.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        guard force || uploadingCount > 0 || chatBackDismissAttemptID > 0 else { return }
        let scrollTarget = scrollTargetID.map(Self.shortChatBackDiagnosticID) ?? "none"
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[JHT ChatBackDiag] event=\(event) conversation=\(Self.shortChatBackDiagnosticID(conversationID)) kind=\(conversation.kind.rawValue) messages=\(conversation.messages.count) input_len=\(input.count) uploading=\(uploadingCount) browsing=\(isUserBrowsingHistory) at_bottom=\(isAtBottom) pending_scroll=\(scrollTarget)\(suffix)")
#endif
    }

    private static func shortChatBackDiagnosticID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        return String(trimmed.suffix(6))
    }

    static func chatBackDiagnosticElapsedMS(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_HELPERS - 修改结束：统一聊天返回卡住定位日志，避免输出消息正文和敏感标识

}

// WDT_IOS1_CHAT_ROW_FACTORY_20261110: App owns concrete row render diagnostics.
// WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END

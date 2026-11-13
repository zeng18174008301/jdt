import IM4Features
import SwiftUI
import UIKit

extension ChatView {
    var timelineContext: ChatTimelineContext {
        return .init(
            conversationID: conversationID,
            scope: screenActions.authority.composerScope(),
            sessionGeneration: screenActions.authority.sessionGeneration(),
            historyScope: screenActions.history.activeConversationHistoryScope(),
            policy: observedTimelinePolicy.map { .init(recallEnabled: $0.actions.recallEnabled,
                editEnabled: $0.actions.editEnabled, forwardEnabled: $0.actions.forwardEnabled,
                showsProcessingNotices: $0.showsProcessingNotices) },
            isGroup: conversation.kind == .group,
            isReadOnly: isReadOnlySystemConversation,
            canManageGroup: currentGroup.canCurrentUserManage,
            showsMemberCounts: showsChatGroupMemberCount,
            readReceiptsEnabled: screenStores.files.currentUploadConfig().readReceiptsEnabled
        )
    }

    // Keep the legacy layout call signature; the model is the sole row owner.
    func cachedRowsForRendering(messages: [ChatMessage]) -> ChatMessageRenderRowsSnapshot {
        _ = updateTimelineRows(messages: messages)
        return timelineViewModel.snapshot()
    }

    @discardableResult
    private func updateTimelineRows(messages: [ChatMessage], force: Bool = false) -> Bool {
        var resolver: MessageSenderResolver?
        return timelineViewModel.update(
            messages: messages, context: timelineContext,
            unreadID: unreadDividerVisible ? firstUnreadMessageID : nil,
            unreadCount: unreadDividerVisible ? firstUnreadAnchorCount : 0,
            force: force
        ) { index in
            if resolver == nil { resolver = messageSenderResolver() }
            return messageRow(for: messages, at: index, resolver: resolver!)
        }
    }

    func refreshMessageRowCache(for messages: [ChatMessage]? = nil, allowsPrependReuse: Bool = true) {
        if updateTimelineRows(messages: messages ?? timelineMessages, force: !allowsPrependReuse) {
            timelineViewModel.objectWillChange.send()
        }
    }

    func scheduleMessageRenderCacheRefreshAfterStoreChange(_ reader: ScrollViewProxy) {
        guard messageRenderCacheRefreshTask == nil else { return }
        messageRenderCacheRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            defer { messageRenderCacheRefreshTask = nil }
            refreshMessageRowCache()
            logChatHistoryReadyIfNeeded(reason: "messages_changed")
            resolveReadStatusAnchorAfterSideDataIfNeeded(reader)
            schedulePendingScrollTargetConsumption(reader)
            scheduleIncomingBottomFollow(reader)
        }
    }
}
// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END

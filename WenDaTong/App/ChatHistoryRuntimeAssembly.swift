import IM4Features
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

extension ChatView {
    var boundedPendingUnreadCount: Int {
        let sourceCount = scrollArbiter.isJumpMode
            ? max(pendingUnreadCount, conversation.unread)
            : pendingUnreadCount
        return min(max(sourceCount, 0), max(timelineMessages.count, sourceCount))
    }

    var hasUnreadReminder: Bool {
        pendingUnreadCount > 0 || capturedUnreadCount > 0 || unreadDividerVisible
    }

    private var firstUnreadSourceCount: Int {
        let anchorCount = capturedUnreadCount > 0 ? capturedUnreadCount : pendingUnreadCount
        return max(anchorCount, 0)
    }

    var firstUnreadAnchorCount: Int {
        min(firstUnreadSourceCount, timelineMessages.count)
    }

    var latestLoadedMessageSeq: Int64 {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：避免消息多时 map/max 在主线程生成临时数组
        var latestSeq: Int64 = 0
        for message in timelineMessages where message.channelSeq > latestSeq {
            latestSeq = message.channelSeq
        }
        return latestSeq
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    var latestBottomScrollTargetID: String {
        bottomAnchorID
    }

    var shouldMeasureMessageTopAnchors: Bool {
        // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_ANCHOR_MEASURE_GATE - 修改开始：只在需要历史锚点时测量消息位置
        (oldestHistoryLoadAnchorID != nil && isLoadingConversationHistory)
            || (isUserBrowsingHistory && lastScrollVisibility.isNearHistoryBoundary)
            // Late initial pages can need autofill after entry stabilization.
            || lastScrollVisibility.isContentUnderfilled
        // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_ANCHOR_MEASURE_GATE - 修改结束：只在需要历史锚点时测量消息位置
    }

    func historyAnchorID(for messageID: String) -> String {
        "history-anchor-\(messageID)"
    }

    var isLatestMessageWindowLoaded: Bool {
        conversation.lastMsgSeq <= 0 || latestLoadedMessageSeq >= conversation.lastMsgSeq
    }

    var latestBottomTargetSeq: Int64 {
        max(conversation.lastMsgSeq, latestLoadedMessageSeq)
    }

    var hasConfirmedLatestBottomForCurrentWindow: Bool {
        let targetSeq = latestBottomTargetSeq
        guard targetSeq > 0 else { return didInitialLatestWindowCatchupScroll }
        guard isLatestMessageWindowLoaded else { return false }
        return latestBottomConfirmedSeq >= targetSeq
            || screenActions.history.rememberedConversationBottomSeq(for: conversationID) >= targetSeq
    }

    var canReuseConfirmedBottomForCurrentWindow: Bool {
        chatCanReuseConfirmedBottom(
            unreadCount: rawInitialUnreadCount(),
            latestBottomTargetSeq: latestBottomTargetSeq,
            isLatestMessageWindowLoaded: isLatestMessageWindowLoaded,
            rememberedConfirmedSeq: screenActions.history.rememberedConversationBottomSeq(for: conversationID)
        )
    }

    var needsInitialLatestMetadataRefresh: Bool {
        rawInitialUnreadCount() == 0
            && conversation.lastMsgSeq <= 0
            && !timelineMessages.isEmpty
            && initialUnreadAnchorLoadAttempts == 0
    }

    var needsInitialLatestWindowRefresh: Bool {
        !timelineMessages.isEmpty
            && (
                needsInitialLatestMetadataRefresh
                    || (conversation.lastMsgSeq > 0 && latestLoadedMessageSeq < conversation.lastMsgSeq)
            )
    }

    var hasLastReadInitialAnchorForCurrentWindow: Bool {
        initialScrollAnchor(unreadCount: initialUnreadCountForCurrentMessageWindow())?.anchorsLastReadMessage == true
    }

    var needsInitialUnreadWindowRefresh: Bool {
        rawInitialUnreadCount() > 0
            && !timelineMessages.isEmpty
            && initialUnreadAnchorLoadAttempts == 0
            && !hasConfirmedLatestBottomForCurrentWindow
    }

    var isLoadingConversationHistory: Bool {
        ChatHistoryLoadingInput(isOlderHistoryLoading: screenStores.conversations.historyLoadingConversationIDs().contains(conversationID),
            isMessageSyncInFlight: screenActions.history.isConversationMessageSyncInFlight(conversationID)).isLoading
    }

    private var isOlderConversationHistoryLoading: Bool {
        screenStores.conversations.historyLoadingConversationIDs().contains(conversationID)
    }

    var shouldShowConversationHistoryLoadingPill: Bool {
        isOlderConversationHistoryLoading && didUserInteractWithMessageScroll && isUserBrowsingHistory
    }

    var conversationHistoryMessage: String? {
        screenStores.conversations.historyMessagesByConversationID()[conversationID]
    }

    var shouldShowDirectEmptyHistoryState: Bool {
        conversation.kind == .direct
            && conversation.messages.isEmpty
            && !isLoadingConversationHistory
            && !isReadOnlySystemConversation
    }

    var directEmptyHistoryTitle: String {
        if !conversationSendDisabledReason.isEmpty {
            return "当前无法发送消息"
        }
        if let message = conversationHistoryMessage, message.contains("失败") {
            return "聊天记录同步失败"
        }
        return "暂无历史消息"
    }

    var directEmptyHistorySubtitle: String {
        if !conversationSendDisabledReason.isEmpty {
            return conversationSendDisabledReason
        }
        if let message = conversationHistoryMessage, message.contains("失败") {
            return "网络或服务暂时不可用，请稍后重试。"
        }
        return "可以发送第一条消息，后续历史同步完成后会自动显示。"
    }

    var canRetryDirectHistorySync: Bool {
        conversationHistoryMessage?.contains("失败") == true
    }

    var firstUnreadMessageID: String? {
        chatFirstUnreadMessageIDForDivider(
            messages: timelineMessages,
            firstUnreadMessageID: conversation.firstUnreadMessageID,
            firstUnreadSeq: conversation.firstUnreadSeq,
            lastReadSeq: conversation.lastReadSeq,
            unreadCount: firstUnreadSourceCount
        )
    }

    // WDT_CHAT_UNREAD_BADGE_20261021: use the same target for layout and read validation.
    var latestReadAcknowledgementToken: String {
        guard let message = chatReadAcknowledgementTarget(in: timelineMessages) else { return "" }
        return "\(conversationID):\(message.channelSeq)"
    }

    private func maybeLoadOlderMessagesIfNeeded(index: Int, message: ChatMessage, messageCount: Int) {
        guard index <= 2, didInitialScroll, !isApplyingInitialScroll, messageCount > 0 else { return }
        guard didUserInteractWithMessageScroll, isUserBrowsingHistory else { return }
        guard !isLoadingConversationHistory else { return }
        guard !didTriggerOlderHistoryLoadForScrollIntent else { return }
        let anchorID = currentViewportHistoryAnchorID() ?? message.id
        guard oldestHistoryLoadAnchorID != anchorID else { return }
        guard let anchorY = measuredHistoryAnchorY(anchorID) else { return }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_LOAD_ATTEMPT_THROTTLE_APPEAR - 修改开始：顶部行出现时节流旧消息加载尝试
        guard consumeOlderHistoryLoadAttemptIfNeeded() else { return }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_LOAD_ATTEMPT_THROTTLE_APPEAR - 修改结束：顶部行出现时节流旧消息加载尝试
        // 只有真正发起了加载才关闭重试门,否则节流/引擎拒绝会把重试永久堵死。
        guard requestOlderHistoryForTranscript() else { return }
        rememberHistoryLoadAnchor(anchorID, minY: anchorY)
        didTriggerOlderHistoryLoadForScrollIntent = true
        isUserBrowsingHistory = true
    }

    func maybeLoadOlderMessagesFromScrollMetrics(visibility: ChatScrollVisibility) {
        guard didInitialScroll, !isApplyingInitialScroll else { return }
        guard chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: didUserInteractWithMessageScroll,
            isUserBrowsingHistory: isUserBrowsingHistory,
            visibility: visibility
        ) else {
            return
        }
        guard !isLoadingConversationHistory, !conversation.messages.isEmpty else { return }
        guard let anchorID = currentViewportHistoryAnchorID() ?? timelineMessages.first?.id,
              oldestHistoryLoadAnchorID != anchorID else {
            return
        }
        guard let anchorY = measuredHistoryAnchorY(anchorID) else { return }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_LOAD_ATTEMPT_THROTTLE_METRICS - 修改开始：滚动边界几何回调节流旧消息加载尝试
        guard consumeOlderHistoryLoadAttemptIfNeeded() else { return }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_LOAD_ATTEMPT_THROTTLE_METRICS - 修改结束：滚动边界几何回调节流旧消息加载尝试
        // 只有真正发起了加载才关闭锚点门并进入历史浏览态,
        // 否则节流/引擎拒绝会让相同锚点永远不再触发加载。
        guard requestOlderHistoryForTranscript() else { return }
        rememberHistoryLoadAnchor(anchorID, minY: anchorY)
        didTriggerOlderHistoryLoadForScrollIntent = true
        isUserBrowsingHistory = true
    }

    /// 内容不满一屏时不会产生滚动事件,滚动几何驱动的旧消息加载永远不会触发。
    /// 该方法在初始定位完成、消息窗口变化、历史加载结束后主动补拉,直到内容
    /// 填满视口、连续补拉达到上限或确认没有更早历史为止。
    func autofillOlderHistoryIfUnderfilled() {
        guard didInitialScroll, !isApplyingInitialScroll else { return }
        guard lastScrollVisibility.isContentUnderfilled else {
            // WDT_IOS1_PERF_CHAT_AUTOFILL_EQUAL_RESET_20261112_BEGIN
            if underfilledOlderAutofillAttempts != 0 {
                underfilledOlderAutofillAttempts = 0
            }
            // WDT_IOS1_PERF_CHAT_AUTOFILL_EQUAL_RESET_20261112_END
            return
        }
        guard underfilledOlderAutofillAttempts < maxUnderfilledOlderAutofillAttempts else { return }
        guard !isLoadingConversationHistory else { return }
        // 这里不加 hasOlderMessagesAvailable 前置门:窗口不可用(oldestSeq 缺失)时
        // 也要进 loadOlderMessagesIfAvailable,由 AppState 触发最新窗口恢复同步。
        let anchorID = currentViewportHistoryAnchorID() ?? timelineMessages.first?.id
        let anchorY = anchorID.flatMap(measuredHistoryAnchorY)
        guard timelineMessages.isEmpty || anchorY != nil else { return }
        guard requestOlderHistoryForTranscript() else { return }
        if let anchorID, let anchorY {
            rememberHistoryLoadAnchor(anchorID, minY: anchorY)
        }
        underfilledOlderAutofillAttempts += 1
    }

    private func requestOlderHistoryForTranscript() -> Bool {
        screenActions.history.loadOlderMessagesIfAvailable(conversationID) { [mediaScrollActivity] in
            await mediaScrollActivity.waitForHistoryCommit()
        }
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_LOAD_ATTEMPT_THROTTLE_HELPER - 修改开始：减少顶部边界反复扫描历史可用性
    private func consumeOlderHistoryLoadAttemptIfNeeded(
        now: Date = Date(),
        minimumInterval: TimeInterval = 0.28
    ) -> Bool {
        guard now.timeIntervalSince(lastOlderHistoryLoadAttemptAt) >= minimumInterval else {
            return false
        }
        lastOlderHistoryLoadAttemptAt = now
        return true
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_LOAD_ATTEMPT_THROTTLE_HELPER - 修改结束：减少顶部边界反复扫描历史可用性

    private func currentViewportHistoryAnchorID() -> String? {
        let viewportHeight = scrollMetricsMeasurements.metrics.viewportHeight
        guard viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        // Prefer a marker actually in the viewport. For a tall partial row with
        // no visible marker, retain its nearest preceding marker's negative Y.
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：滚动中单次遍历锚点测量值，避免 filter/min/max 临时集合
        var nearestVisibleID: String?
        var nearestVisibleY = CGFloat.greatestFiniteMagnitude
        var nearestPrecedingID: String?
        var nearestPrecedingY = -CGFloat.greatestFiniteMagnitude
        for (id, y) in messageTopMeasurements.values where y.isFinite && y < viewportHeight {
            if y >= 0 {
                if y < nearestVisibleY {
                    nearestVisibleY = y
                    nearestVisibleID = id
                }
            } else if y > nearestPrecedingY {
                nearestPrecedingY = y
                nearestPrecedingID = id
            }
        }
        return nearestVisibleID ?? nearestPrecedingID
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private func measuredHistoryAnchorY(_ anchorID: String) -> CGFloat? {
        let viewportHeight = scrollMetricsMeasurements.metrics.viewportHeight
        guard viewportHeight.isFinite, viewportHeight > 0,
              let value = messageTopMeasurements[anchorID], value.isFinite else { return nil }
        return value
    }

    private func rememberHistoryLoadAnchor(_ anchorID: String, minY: CGFloat? = nil) {
        guard let value = minY ?? measuredHistoryAnchorY(anchorID), value.isFinite else { return }
        oldestHistoryLoadAnchorID = anchorID
        oldestHistoryLoadAnchorMinY = value
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
    func captureBottomBeforeMessageGrowth(_ updated: ConversationMessageSnapshot, previousMessages oldMessages: [ChatMessage]) {
    // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END
        guard updated.messages.count > oldMessages.count else { return }
        guard didInitialScroll, !isApplyingInitialScroll, !isLoadingConversationHistory else {
            scrollMetricsMeasurements.incomingBottomFollow.reset()
            return
        }
        // A history prepend is not a newly appended message. Keep its existing
        // anchor/restoration path, even when several rows arrive in one update.
        guard let oldTail = oldMessages.last,
              updated.messages[oldMessages.count - 1].id == oldTail.id else {
            scrollMetricsMeasurements.incomingBottomFollow.reset()
            return
        }
        scrollMetricsMeasurements.incomingBottomFollow.recordAppend(
            metrics: scrollMetricsMeasurements.metrics,
            generation: automaticBottomScrollGeneration,
            eligible: pendingUnreadCount == 0 && transcriptScrollControl.direction == nil
                && !isUserBrowsingHistory && !isAutomaticBottomScrollSuppressed
        )
    }

    var incomingBottomFollowDecision: Bool? {
        scrollMetricsMeasurements.incomingBottomFollow.decision(generation: automaticBottomScrollGeneration)
    }

    func scheduleIncomingBottomFollow(_ reader: ScrollViewProxy) {
        guard incomingBottomFollowDecision == true else { return }
        let generation = automaticBottomScrollGeneration
        let scope = conversationID
        DispatchQueue.main.async {
            guard scope == conversationID, generation == automaticBottomScrollGeneration,
                  incomingBottomFollowDecision == true,
                  didInitialScroll, !isApplyingInitialScroll,
                  transcriptScrollControl.direction == nil,
                  !isUserBrowsingHistory, !isAutomaticBottomScrollSuppressed,
                  !conversation.messages.isEmpty else { return }
            // This source is permitted after a manual return to the bottom.
            // Its pre-append decision and generation are mandatory; ordinary
            // follow/initial/search requests still use their existing arbiter.
            _ = scrollToTargetWithoutAnimation(reader, targetID: bottomAnchorID,
                                               anchor: .bottom, source: .incomingFollowBottom)
            // Actual geometry confirms visibility/read progress, not this request.
        }
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
    func refreshHistoryAnchorBeforeMessageGrowth(_ updated: ConversationMessageSnapshot, previousMessageCount: Int) {
        guard !isAtBottom,
              oldestHistoryLoadAnchorID != nil || isLoadingConversationHistory,
              updated.messages.count > previousMessageCount else { return }
        // The commit supplies the previous window. Sample the viewport before layout,
        // including continued dragging or
        // deceleration while the request waited. Do not publish geometry per frame.
    // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END
        guard let anchorID = currentViewportHistoryAnchorID(),
              let anchorY = measuredHistoryAnchorY(anchorID) else {
            oldestHistoryLoadAnchorID = nil
            oldestHistoryLoadAnchorMinY = nil
            return
        }
        rememberHistoryLoadAnchor(anchorID, minY: anchorY)
    }

    private func maybeLoadNewerMessagesFromScrollMetrics() {
        guard didInitialScroll, !isApplyingInitialScroll, !timelineMessages.isEmpty else { return }
        guard didUserInteractWithMessageScroll, !isUserBrowsingHistory, isAtBottom else { return }
        guard !isLoadingConversationHistory, !isLatestMessageWindowLoaded else { return }
        guard screenActions.history.hasNewerMessagesAvailable(conversationID) else { return }
        let anchorSeq = latestLoadedMessageSeq
        guard anchorSeq > 0, newestHistoryLoadAnchorSeq != anchorSeq else { return }
        newestHistoryLoadAnchorSeq = anchorSeq
        screenActions.history.loadNewerMessagesIfAvailable(conversationID)
    }

    func scheduleTranscriptLayoutUpdate(_ reader: ScrollViewProxy) {
        guard let generation = scrollMetricsMeasurements.layoutCallbacks.schedule() else { return }
        let scope = screenActions.history.activeConversationHistoryScope()
        let targetConversationID = conversationID
        let epoch = readVisibilityEpoch
        DispatchQueue.main.async {
            guard scrollMetricsMeasurements.layoutCallbacks.consume(generation),
                  scope == screenActions.history.activeConversationHistoryScope(),
                  targetConversationID == conversationID,
                  epoch == readVisibilityEpoch, scenePhase == .active else { return }
            handleScrollMetrics(scrollMetricsMeasurements.metrics, reader: reader)
            // A history drag may precede this layout's row anchors. Resume the
            // same guarded load only after the geometry transaction has ended.
            maybeLoadOlderMessagesFromScrollMetrics(visibility: lastScrollVisibility)
            autofillOlderHistoryIfUnderfilled()
        }
    }

    private func handleScrollMetrics(_ metrics: ChatScrollMetricsSnapshot, reader: ScrollViewProxy) {
        guard metrics.isValid else { return }
        let previousMetrics = scrollMetricsMeasurements.lastHandledMetrics
        scrollMetricsMeasurements.lastHandledMetrics = metrics
        let visibility = chatScrollVisibility(metrics: metrics)
        if canRealignBottomAfterViewportExpansion,
           chatNeedsBottomRealignmentAfterViewportExpansion(from: previousMetrics, to: metrics) {
            // Expansion can leave a large gap while semantic bottom visibility
            // stays true, so this must run before visibility deduplication.
            lastScrollVisibility = visibility
            scheduleBottomRealignmentAfterViewportExpansion(reader, previousMetrics: previousMetrics)
            return
        }
        if scrollMetricsMeasurements.incomingBottomFollow.needsLayoutCorrection(
            from: previousMetrics, to: metrics, generation: automaticBottomScrollGeneration
        ) {
            // Media growth and viewport-only shrink both need correction, even
            // when semantic visibility is unchanged across successive layouts.
            lastScrollVisibility = visibility
            isAtBottom = false
            updateRealtimeAutoReadGate()
            scheduleIncomingBottomFollow(reader)
            return
        }
        let canRepeatHistoryBoundaryCheck = chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: didUserInteractWithMessageScroll,
            isUserBrowsingHistory: isUserBrowsingHistory,
            visibility: visibility
        )
        // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_METRICS_HANDLE_THROTTLE - 修改开始：减少滚动过程中重复状态处理
        let visibilityDidChange = visibility != lastScrollVisibility
        let shouldProcessRepeatedBoundaryCheck = !visibilityDidChange
            && canRepeatHistoryBoundaryCheck
            && scrollMetricsMeasurements.consumeRepeatedBoundaryCheckIfNeeded()
        // New rendered messages can leave the bottom boolean unchanged. Their
        // layout-bound read observation still needs to advance independently.
        markVisibleIncomingMessagesReadIfNeeded()
        guard visibilityDidChange || shouldProcessRepeatedBoundaryCheck else { return }
        if visibilityDidChange {
            lastScrollVisibility = visibility
            scrollMetricsMeasurements.resetRepeatedBoundaryCheckThrottle()
        }
        // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_METRICS_HANDLE_THROTTLE - 修改结束：减少滚动过程中重复状态处理

        guard didInitialScroll, !isApplyingInitialScroll else { return }
        if visibility.isAtBottom {
            isAtBottom = true
            isUserBrowsingHistory = false
            didTriggerOlderHistoryLoadForScrollIntent = false
            transcriptScrollControl.clearSuppression()
            updateRealtimeAutoReadGate()
            rememberLatestBottomVisible()
            if hasUnreadReminder {
                if canClearUnreadReminderFromVisibleProgress {
                    clearUnreadReminderAndAckIfNeeded(reason: "bottom_visible_geometry")
                }
            } else {
                markVisibleIncomingMessagesReadIfNeeded()
            }
            maybeLoadNewerMessagesFromScrollMetrics()
        } else if isAtBottom {
            if incomingBottomFollowDecision == nil,
               canApplyAutomaticBottomScroll || canApplyEntryStabilizationBottomScroll, !conversation.messages.isEmpty {
                scrollToLatestBottomWithoutAnimation(reader)
                rememberLatestBottomVisible()
                updateRealtimeAutoReadGate()
                return
            }
            isAtBottom = false
            updateRealtimeAutoReadGate()
        }

    }

    private var canRealignBottomAfterViewportExpansion: Bool {
        didInitialScroll && !isApplyingInitialScroll && !isLoadingConversationHistory
            && isAtBottom && !isUserBrowsingHistory && pendingUnreadCount == 0
            && transcriptScrollControl.direction == nil && !isAutomaticBottomScrollSuppressed
            && incomingBottomFollowDecision != false && !conversation.messages.isEmpty
    }

    private func scheduleBottomRealignmentAfterViewportExpansion(
        _ reader: ScrollViewProxy,
        previousMetrics: ChatScrollMetricsSnapshot
    ) {
        let scope = conversationID
        let generation = automaticBottomScrollGeneration
        DispatchQueue.main.async {
            guard scope == conversationID,
                  generation == automaticBottomScrollGeneration,
                  canRealignBottomAfterViewportExpansion,
                  chatNeedsBottomRealignmentAfterViewportExpansion(
                    from: previousMetrics, to: scrollMetricsMeasurements.metrics
                  ) else { return }
            // A manual return to bottom keeps the arbiter in jump mode. Only
            // this guarded viewport correction may bypass its followBottom veto.
            // The request never confirms delivery, visibility, or read progress.
            _ = scrollToTargetWithoutAnimation(reader, targetID: bottomAnchorID, anchor: .bottom, source: .viewportBottomRealignment)
        }
    }

} // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END

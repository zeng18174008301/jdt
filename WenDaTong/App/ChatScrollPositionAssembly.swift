import IM4Features
import SwiftUI
import UIKit

extension ChatView {
    @discardableResult
    func configureInitialPosition(_ reader: ScrollViewProxy) -> Bool {
        resetScrollPositionState()
        captureInitialUnreadSnapshotIfNeeded()
        if initialSearchJumpTarget != nil,
           (!didApplyInitialSearchJumpTarget || isPreparingInitialSearchJumpTarget) {
            applyInitialSearchJumpTargetIfNeeded()
            return true
        }
        guard !conversation.messages.isEmpty, !didInitialScroll else { return false }
        let shouldWaitForLatestWindow = chatShouldWaitForInitialLatestWindowRefresh(
            needsUnreadWindowRefresh: needsInitialUnreadWindowRefresh,
            needsLatestWindowRefresh: needsInitialLatestWindowRefresh,
            canReuseConfirmedBottom: canReuseConfirmedBottomForCurrentWindow
        )
        if shouldWaitForLatestWindow {
            let waitEvent = needsInitialLatestMetadataRefresh ? "wait_latest_metadata" : "wait_window"
            logInitialAnchorDecision(waitEvent, targetID: nil, unreadCount: rawInitialUnreadCount())
            scheduleProvisionalInitialBottomIfNeeded(reader, reason: waitEvent)
            if isLoadingConversationHistory {
                return true
            }
            if initialUnreadAnchorLoadAttempts < initialUnreadAnchorMaxHistoryLoads {
                initialUnreadAnchorLoadAttempts += 1
                logInitialAnchorDecision("sync_latest_window", targetID: nil, unreadCount: rawInitialUnreadCount())
                screenActions.history.syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: true,
                    trimToLatestWindow: true
                )
                return true
            }
            logInitialAnchorDecision("window_refresh_exhausted", targetID: nil, unreadCount: rawInitialUnreadCount())
        }

        let unreadCount = initialUnreadCountForCurrentMessageWindow()
        if shouldLoadOlderHistoryForInitialAnchor(unreadCount: unreadCount) {
            loadOlderHistoryForInitialAnchor()
            return true
        }
        didInitialScroll = true
        capturedUnreadCount = unreadCount
        pendingUnreadCount = unreadCount
        unreadDividerVisible = unreadCount > 0
        isApplyingInitialScroll = true
        if unreadCount > 0 {
            isUserBrowsingHistory = false
        }
        isAtBottom = false

        guard let target = initialScrollAnchor(unreadCount: unreadCount) else {
            isApplyingInitialScroll = false
            updateRealtimeAutoReadGate()
            return false
        }
        let shouldSkipDelayedBottomConfirmation = unreadCount == 0 && hasConfirmedLatestBottomForCurrentWindow
        logInitialAnchorDecision("schedule_initial_scroll", targetID: target.id, unreadCount: unreadCount)
        let bottomScrollGeneration = target.id == bottomAnchorID ? nextAutomaticBottomScrollGeneration() : automaticBottomScrollGeneration
        DispatchQueue.main.async {
            guard target.id != bottomAnchorID || bottomScrollGeneration == automaticBottomScrollGeneration else {
                isApplyingInitialScroll = false
                updateRealtimeAutoReadGate()
                return
            }
            guard unreadCount > 0 || !isUserBrowsingHistory else {
                isApplyingInitialScroll = false
                isAtBottom = false
                updateRealtimeAutoReadGate()
                logInitialAnchorDecision("skip_initial_bottom_user_browsing_history", targetID: target.id, unreadCount: unreadCount)
                return
            }
            guard scrollToTargetWithoutAnimation(reader, targetID: target.id, anchor: target.placement.unitPoint, source: .initialAnchor) else {
                isApplyingInitialScroll = false
                updateRealtimeAutoReadGate()
                return
            }
            logInitialAnchorDecision("initial_scroll_applied", targetID: target.id, unreadCount: unreadCount)
            didAutoScrollToUnreadAnchor = unreadCount > 0
            isApplyingInitialScroll = false
            let isLatestBottom = isLatestBottomTarget(target.id)
            isAtBottom = isLatestBottom
            updateRealtimeAutoReadGate()
            if target.anchorsLastReadMessage {
                markVisibleIncomingMessagesReadIfNeeded()
            } else if unreadCount == 0 {
                if isLatestBottom && !shouldSkipDelayedBottomConfirmation {
                    scheduleLatestBottomConfirmation(reader, reason: "initial_read_bottom_confirm", force: true)
                } else if isLatestBottom {
                    rememberLatestBottomVisible()
                }
                markVisibleIncomingMessagesReadIfNeeded()
            } else if isLatestBottom {
                clearUnreadReminderAndAckIfNeeded(reason: "initial_fallback_to_latest")
                scheduleLatestBottomConfirmation(reader, reason: "initial_unread_latest_bottom_confirm", force: true)
            }
            maybeLoadOlderMessagesFromScrollMetrics(visibility: lastScrollVisibility)
            autofillOlderHistoryIfUnderfilled()
        }
        return true
    }

    func captureInitialUnreadSnapshotIfNeeded() {
        guard initialUnreadSnapshot == nil else { return }
        initialUnreadSnapshot = max(conversation.unread, 0)
    }

    func rawInitialUnreadCount() -> Int {
        max(initialUnreadSnapshot ?? max(conversation.unread, 0), 0)
    }

    func initialUnreadCountForCurrentMessageWindow() -> Int {
        let rawUnread = rawInitialUnreadCount()
        guard rawUnread > 0 else { return 0 }
        return min(rawUnread, timelineMessages.count)
    }

    func initialScrollAnchor(unreadCount: Int) -> ChatInitialScrollAnchor? {
        chatInitialScrollAnchor(
            messages: timelineMessages,
            unreadCount: unreadCount,
            lastReadSeq: conversation.lastReadSeq,
            firstUnreadMessageID: conversation.firstUnreadMessageID,
            firstUnreadSeq: conversation.firstUnreadSeq,
            firstUnreadMarkerID: firstUnreadMarkerID,
            bottomAnchorID: bottomAnchorID
        )
    }

    private func isLatestBottomTarget(_ targetID: String) -> Bool {
        targetID == bottomAnchorID || latestBottomScrollTargetID == targetID
    }

    private func firstUnreadMessageIDAfterReadCursor() -> String? {
        guard conversation.lastReadSeq > 0 else { return nil }
        return timelineMessages.first { message in
            message.channelSeq > conversation.lastReadSeq
                && message.status != .recalled
                && !message.isDeletedLocally
        }?.id
    }

    private func oldestLoadedMessageSeq() -> Int64? {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：避免上滑加载判断时 map/filter/min 分配临时数组
        var oldestSeq: Int64?
        for message in conversation.messages where message.channelSeq > 0 {
            oldestSeq = min(oldestSeq ?? message.channelSeq, message.channelSeq)
        }
        return oldestSeq
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private func shouldLoadOlderHistoryForInitialAnchor(unreadCount: Int) -> Bool {
        guard rawInitialUnreadCount() > 0, unreadCount > 0 else { return false }
        // Initial entry must stay near the latest unread/latest message window. Older
        // history is still loaded only when the user explicitly scrolls upward.
        return false
    }

    private func loadOlderHistoryForInitialAnchor() {
        guard !isLoadingConversationHistory else { return }
        initialUnreadAnchorLoadAttempts += 1
        screenActions.history.loadOlderMessagesIfAvailable(conversationID)
    }

    func handleLatestWindowProgress(_ reader: ScrollViewProxy, reason: String) {
        if !didInitialScroll {
            _ = configureInitialPosition(reader)
            return
        }
        if requestLatestWindowCatchupSyncIfNeeded(reason: reason) {
            return
        }
        _ = catchUpToLatestWindowIfNeeded(reader, reason: reason)
    }

    func resolveReadStatusAnchorAfterSideDataIfNeeded(_ reader: ScrollViewProxy) {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              !isWithinChatEntryStabilizationWindow,
              !didResolveReadStatusAnchorAfterSideData,
              rawInitialUnreadCount() == 0,
              !didUserInteractWithMessageScroll,
              let target = initialScrollAnchor(unreadCount: 0),
              target.anchorsLastReadMessage,
              conversation.messages.contains(where: { $0.id == target.id && chatMessageDisplaysReadStatusForInitialAnchor($0) }) else {
            return
        }
        didResolveReadStatusAnchorAfterSideData = true
        isApplyingInitialScroll = true
        logInitialAnchorDecision("schedule_read_status_anchor_side_data", targetID: target.id, unreadCount: 0)
        DispatchQueue.main.async {
            guard !didUserInteractWithMessageScroll,
                  conversation.messages.contains(where: { $0.id == target.id }) else {
                isApplyingInitialScroll = false
                updateRealtimeAutoReadGate()
                return
            }
            guard scrollToTargetWithoutAnimation(reader, targetID: target.id, anchor: target.placement.unitPoint, source: .readAck) else {
                isApplyingInitialScroll = false
                updateRealtimeAutoReadGate()
                return
            }
            isApplyingInitialScroll = false
            isAtBottom = false
            updateRealtimeAutoReadGate()
            logInitialAnchorDecision("read_status_anchor_side_data_applied", targetID: target.id, unreadCount: 0)
        }
    }

    @discardableResult
    private func requestLatestWindowCatchupSyncIfNeeded(reason: String) -> Bool {
        guard needsInitialLatestWindowRefresh,
              rawInitialUnreadCount() == 0,
              pendingUnreadCount == 0,
              !isUserBrowsingHistory,
              !isAutomaticBottomScrollSuppressed,
              !isLoadingConversationHistory,
              initialUnreadAnchorLoadAttempts < initialUnreadAnchorMaxHistoryLoads else {
            return false
        }
        initialUnreadAnchorLoadAttempts += 1
        logInitialAnchorDecision("catchup_sync_latest_window_\(reason)", targetID: nil, unreadCount: 0)
        screenActions.history.syncConversationMessagesIfNeeded(
            conversationID,
            force: true,
            silent: true,
            showLoadingIndicator: true,
            trimToLatestWindow: true
        )
        return true
    }

    @discardableResult
    private func catchUpToLatestWindowIfNeeded(_ reader: ScrollViewProxy, reason: String) -> Bool {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              !hasConfirmedLatestBottomForCurrentWindow,
              rawInitialUnreadCount() == 0,
              pendingUnreadCount == 0,
              isLatestMessageWindowLoaded,
              conversation.lastMsgSeq > 0,
              latestLoadedMessageSeq > 0,
              !hasLastReadInitialAnchorForCurrentWindow,
              !isUserBrowsingHistory,
              !isAutomaticBottomScrollSuppressed,
              !conversation.messages.isEmpty else {
            return false
        }
        didInitialLatestWindowCatchupScroll = true
        logInitialAnchorDecision("schedule_latest_bottom_catchup_\(reason)", targetID: latestBottomScrollTargetID, unreadCount: 0)
        scheduleLatestBottomConfirmation(reader, reason: "latest_bottom_catchup_\(reason)")
        return true
    }

    func beginNormalOpenScrollWindow(reason: String) {
        let now = Date()
        chatEntryStabilizationUntil = now.addingTimeInterval(chatEntryStabilizationDuration)
        scrollArbiter.beginNormalOpen(now: now, duration: chatEntryStabilizationDuration)
        logInitialAnchorDecision("begin_normal_open_\(reason)", targetID: latestBottomScrollTargetID, unreadCount: rawInitialUnreadCount())
    }

    @discardableResult
    func evaluateScrollRequest(
        source: ConversationScrollRequestSource,
        targetID: String?,
        anchor: UnitPoint?,
        userInitiated: Bool
    ) -> ConversationScrollVerdict {
        let request = ConversationScrollRequest(
            source: source,
            targetID: targetID,
            anchor: anchor,
            userInitiated: userInitiated,
            generation: scrollArbiter.generation
        )
        return scrollArbiter.evaluate(request, now: Date())
    }

    func setScrollTarget(
        _ targetID: String,
        source: ConversationScrollRequestSource,
        anchor: UnitPoint = .center
    ) {
        oldestHistoryLoadAnchorID = nil
        oldestHistoryLoadAnchorMinY = nil
        pendingScrollTargetSource = source
        pendingScrollTargetAnchor = anchor
        scrollTargetID = targetID
    }

    func schedulePendingScrollTargetConsumption(
        _ reader: ScrollViewProxy,
        expectedTargetID: String? = nil
    ) {
        guard let targetID = scrollTargetID,
              expectedTargetID == nil || expectedTargetID == targetID else {
            return
        }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_SCROLL_TARGET_LOOKUP_FAST_PATH - 修改开始：待滚动目标只做目标查询，避免历史多时全量建 Set
        guard canConsumePendingScrollTarget(targetID) else {
            return
        }
        // 让本轮消息状态先完成 SwiftUI diff，再交给 ScrollViewReader 定位。
        DispatchQueue.main.async {
            guard scrollTargetID == targetID else { return }
            guard canConsumePendingScrollTarget(targetID) else {
                return
            }
            consumePendingScrollTarget(reader, targetID: targetID)
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_SCROLL_TARGET_LOOKUP_FAST_PATH - 修改结束：待滚动目标只做目标查询，避免历史多时全量建 Set
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_SCROLL_TARGET_LOOKUP_HELPER - 修改开始：复用已缓存的消息行判断滚动目标
    private func canConsumePendingScrollTarget(_ targetID: String) -> Bool {
        if targetID == bottomAnchorID {
            return true
        }
        if cachedMessageRowsConversationID == conversationID,
           cachedMessageRows.contains(where: { $0.message.id == targetID }) {
            return true
        }
        return conversation.messages.contains { message in
            !message.isPinnedContextOnly && message.id == targetID
        }
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_SCROLL_TARGET_LOOKUP_HELPER - 修改结束：复用已缓存的消息行判断滚动目标

    private func consumePendingScrollTarget(_ reader: ScrollViewProxy, targetID: String) {
        let source = pendingScrollTargetSource
        let requestedAnchor = pendingScrollTargetAnchor
        let verdict = evaluateScrollRequest(
            source: source,
            targetID: targetID,
            anchor: requestedAnchor,
            userInitiated: true
        )
        guard verdict != .deny else {
            scrollTargetID = nil
            return
        }
        let isLatestBottom = isLatestBottomTarget(targetID)
        isUserBrowsingHistory = source == .jumpToLatest ? false : !isLatestBottom
        if source != .jumpToLatest {
            isAtBottom = isLatestBottom
        }
        updateRealtimeAutoReadGate()
        if source == .searchJump || (source == .pinnedJump && !isLatestBottom) { // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
            focusTimelineMessage(targetID)
        }
        if timelineMessages.first?.id == targetID {
            // The leading message has no content before it to center. A long
            // spring jump can retain an estimated offset as lazy rows resolve.
            scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: .top)
        } else {
            // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110
            applyScrollIntent(.init(position: ScrollIntent.position(for: source), targetID: targetID,
                                    anchor: isLatestBottom ? nil : requestedAnchor, motion: .spring), reader: reader)
        }
        if source != .jumpToLatest, isLatestBottom {
            rememberLatestBottomVisible()
            markVisibleIncomingMessagesReadIfNeeded()
        }
        scrollTargetID = nil
        pendingScrollTargetSource = .searchJump
        pendingScrollTargetAnchor = .center
    }

    private func focusTimelineMessage(_ messageID: String) {
        focusedTimelineMessageGeneration += 1
        let generation = focusedTimelineMessageGeneration
        focusedTimelineMessageID = messageID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard generation == focusedTimelineMessageGeneration else { return }
            focusedTimelineMessageID = nil
        }
    }

    func scrollToTargetWithoutAnimation(
        _ reader: ScrollViewProxy,
        targetID: String,
        anchor: UnitPoint?,
        source: ConversationScrollRequestSource
    ) -> Bool {
        let verdict = evaluateScrollRequest(source: source, targetID: targetID, anchor: anchor, userInitiated: false)
        guard verdict != .deny else { return false }
        scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: anchor, intentPosition: ScrollIntent.position(for: source))
        return true
    }

    func scheduleLatestBottomConfirmation(_ reader: ScrollViewProxy, reason: String, force: Bool = false) {
        if !force, incomingBottomFollowDecision != nil {
            scheduleIncomingBottomFollow(reader)
            return
        }
        guard force || !hasConfirmedLatestBottomForCurrentWindow else {
            markVisibleIncomingMessagesReadIfNeeded()
            return
        }
        let targetSeq = latestBottomTargetSeq
        let bottomScrollGeneration = nextAutomaticBottomScrollGeneration()
        let confirmationDelays = isWithinChatEntryStabilizationWindow
            ? [chatLatestBottomConfirmationDelays(force: force).first ?? 0]
            : chatLatestBottomConfirmationDelays(force: force)
        for delay in confirmationDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let targetID = latestBottomScrollTargetID
                guard bottomScrollGeneration == automaticBottomScrollGeneration,
                      didInitialScroll,
                      !isApplyingInitialScroll,
                      (force || incomingBottomFollowDecision == nil),
                      (force || rawInitialUnreadCount() == 0),
                      (force || pendingUnreadCount == 0),
                      !isUserBrowsingHistory,
                      canApplyAutomaticBottomScroll || canApplyEntryStabilizationBottomScroll,
                      !conversation.messages.isEmpty else {
                    return
                }
                guard scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: .bottom, source: .followBottom) else { return }
                didInitialLatestWindowCatchupScroll = true
                let currentTargetSeq = max(targetSeq, latestBottomTargetSeq)
                rememberLatestBottomVisible(seq: currentTargetSeq)
                isAtBottom = true
                updateRealtimeAutoReadGate()
                logInitialAnchorDecision("\(reason)_applied", targetID: targetID, unreadCount: 0)
                markVisibleIncomingMessagesReadIfNeeded()
            }
        }
    }

    func followBottomAfterMessageChangeIfNeeded(_ reader: ScrollViewProxy, oldCount: Int, newCount: Int) {
        if incomingBottomFollowDecision != nil {
            scheduleIncomingBottomFollow(reader)
            return
        }
        guard didInitialScroll, newCount > oldCount, pendingUnreadCount == 0, !conversation.messages.isEmpty else { return }
        guard canApplyAutomaticBottomScroll || canApplyEntryStabilizationBottomScroll else { return }
        let bottomScrollGeneration = nextAutomaticBottomScrollGeneration()
        DispatchQueue.main.async {
            guard bottomScrollGeneration == automaticBottomScrollGeneration,
                  canApplyAutomaticBottomScroll || canApplyEntryStabilizationBottomScroll else { return }
            let targetID = latestBottomScrollTargetID
            if isWithinChatEntryStabilizationWindow {
                guard scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: .bottom, source: .followBottom) else { return }
            } else {
                guard evaluateScrollRequest(source: .followBottom, targetID: targetID, anchor: .bottom, userInitiated: false) != .deny else { return }
                // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110
                applyScrollIntent(.init(position: .followBottom, targetID: targetID, anchor: nil, motion: .incoming), reader: reader)
            }
            rememberLatestBottomVisible()
            markVisibleIncomingMessagesReadIfNeeded()
        }
    }

    func withoutSendLayoutAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    func scrollToLatestBottomWithoutAnimation(_ reader: ScrollViewProxy, source: ConversationScrollRequestSource = .followBottom) {
        _ = scrollToTargetWithoutAnimation(reader, targetID: latestBottomScrollTargetID, anchor: .bottom, source: source)
    }

    func scrollToTargetWithoutAnimation(_ reader: ScrollViewProxy, targetID: String, anchor: UnitPoint?, intentPosition: ScrollIntent.Position = .jump) {
        // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110_BEGIN
        applyScrollIntent(.init(position: intentPosition, targetID: targetID,
                                anchor: isLatestBottomTarget(targetID) ? nil : anchor, motion: .immediate), reader: reader)
        // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110_END
    }

    // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110_BEGIN
    private func applyScrollIntent(_ intent: ScrollIntent, reader: ScrollViewProxy) {
        transcriptScrollControl.intents.apply(intent) { accepted in
            let execute = { reader.scrollTo(accepted.targetID, anchor: accepted.anchor) }
            switch accepted.motion {
            case .immediate:
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction, execute)
            case .spring:
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86), execute)
            case .incoming:
                withAnimation(.easeOut(duration: 0.25), execute)
            }
        }
    }
    // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110_END

    @discardableResult
    func scrollToBottomAfterOwnSendIfNeeded(_ reader: ScrollViewProxy, oldCount: Int, newCount: Int) -> Bool {
        guard let baselineCount = pendingOwnSendScrollBaselineCount,
              newCount > oldCount,
              newCount > baselineCount,
              !conversation.messages.isEmpty else {
            return false
        }
        let newMessageCount = max(newCount - oldCount, 1)
        let newTailMessages = conversation.messages.suffix(newMessageCount)
        guard newTailMessages.contains(where: isMessageAuthoredByCurrentUser) else {
            return false
        }

        pendingOwnSendScrollBaselineCount = nil
        isUserBrowsingHistory = false
        isAtBottom = true
        transcriptScrollControl.clearSuppression()
        didTriggerOlderHistoryLoadForScrollIntent = false
        updateRealtimeAutoReadGate()

        let bottomScrollGeneration = nextAutomaticBottomScrollGeneration()
        DispatchQueue.main.async {
            guard bottomScrollGeneration == automaticBottomScrollGeneration else { return }
            scrollToLatestBottomWithoutAnimation(reader, source: .sendEcho)
            rememberLatestBottomVisible()
            markVisibleIncomingMessagesReadIfNeeded()
        }
        return true
    }

    @discardableResult
    func preserveHistoryAnchorAfterMessageChangeIfNeeded(_ reader: ScrollViewProxy, oldCount: Int, newCount: Int) -> Bool {
        guard didInitialScroll,
              newCount > oldCount,
              !isAtBottom,
              let anchorID = oldestHistoryLoadAnchorID,
              conversation.messages.contains(where: { $0.id == anchorID }) else {
            return false
        }
        guard let anchorY = oldestHistoryLoadAnchorMinY, anchorY.isFinite else { return false }
        let capturedConversationID = conversationID
        DispatchQueue.main.async {
            guard conversationID == capturedConversationID,
                  oldestHistoryLoadAnchorID == anchorID,
                  conversation.messages.count == newCount,
                  !isAtBottom else { return }
            let viewportHeight = scrollMetricsMeasurements.metrics.viewportHeight
            guard viewportHeight.isFinite, viewportHeight > 0 else { return }
            // Align the same point in the 8pt anchor and the viewport.
            guard viewportHeight > 8 else { return }
            let anchorPoint = UnitPoint(x: 0.5, y: anchorY / (viewportHeight - 8))
            guard evaluateScrollRequest(source: .historyPrependCompensation, targetID: anchorID, anchor: anchorPoint, userInitiated: false) != .deny else { return }
            scrollToTargetWithoutAnimation(reader, targetID: historyAnchorID(for: anchorID), anchor: anchorPoint, intentPosition: .historyAnchor) // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110
            // One accepted load may apply persisted and remote pages separately.
            // Both updates must retain the measured position, not nil -> top.
        }
        return true
    }

    private func scheduleProvisionalInitialBottomIfNeeded(_ reader: ScrollViewProxy, reason: String) {
        guard !didInitialScroll,
              !didScheduleInitialProvisionalBottom,
              !isUserBrowsingHistory,
              !conversation.messages.isEmpty else {
            return
        }
        guard !hasLastReadInitialAnchorForCurrentWindow else { return }
        guard !hasConfirmedLatestBottomForCurrentWindow else { return }
        didScheduleInitialProvisionalBottom = true
        logInitialAnchorDecision("schedule_provisional_bottom_\(reason)", targetID: latestBottomScrollTargetID, unreadCount: 0)
        let bottomScrollGeneration = nextAutomaticBottomScrollGeneration()
        DispatchQueue.main.async {
            let targetID = latestBottomScrollTargetID
            guard bottomScrollGeneration == automaticBottomScrollGeneration,
                  !didInitialScroll,
                  !isUserBrowsingHistory,
                  !isAutomaticBottomScrollSuppressed,
                  !conversation.messages.isEmpty else {
                return
            }
            guard scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: .bottom, source: .initialAnchor) else { return }
            rememberLatestBottomVisible()
            isAtBottom = true
            updateRealtimeAutoReadGate()
            logInitialAnchorDecision("provisional_bottom_\(reason)_applied", targetID: targetID, unreadCount: 0)
        }
    }

    func rememberLatestBottomVisible(seq: Int64? = nil) {
        guard let targetSeq = ChatBottomConfirmationInput(targetSequence: seq ?? latestBottomTargetSeq,
            confirmedSequence: latestBottomConfirmedSeq).advancingSequence else { return }
        latestBottomConfirmedSeq = targetSeq
        screenActions.history.rememberConversationBottomSeq(targetSeq, for: conversationID)
    }

    func resetScrollPositionState(force: Bool = false) {
        let currentSessionKey = screenActions.history.activeConversationHistoryScope()
        guard force || scrollStateConversationID != conversationID || scrollStateSessionKey != currentSessionKey else { return }
        readVisibilityEpoch &+= 1
        scrollStateConversationID = conversationID
        scrollStateSessionKey = currentSessionKey
        pendingUnreadCount = 0
        didInitialScroll = false
        capturedUnreadCount = 0
        didAutoScrollToUnreadAnchor = false
        initialUnreadSnapshot = nil
        initialUnreadAnchorLoadAttempts = 0
        unreadDividerVisible = false
        oldestHistoryLoadAnchorID = nil
        oldestHistoryLoadAnchorMinY = nil
        newestHistoryLoadAnchorSeq = 0
        didTriggerOlderHistoryLoadForScrollIntent = false
        transcriptScrollControl.reset()
        isApplyingInitialScroll = false
        isUserBrowsingHistory = false
        isAtBottom = false
        transcriptScrollControl.clearSuppression()
        pendingOwnSendScrollBaselineCount = nil
        didScrollTowardUnreadMessages = false
        isClearingUnreadReminder = false
        lastScrollVisibility = .initial
        scrollMetricsMeasurements.removeAll()
        messageTopMeasurements.removeAll()
        scrollTargetID = nil
        pendingScrollTargetSource = .searchJump
        pendingScrollTargetAnchor = .center
        pendingPinnedJumpMessage = nil
        focusedTimelineMessageGeneration += 1
        focusedTimelineMessageID = nil
        underfilledOlderAutofillAttempts = 0
        didInitialLatestWindowCatchupScroll = false
        didScheduleInitialProvisionalBottom = false
        didResolveReadStatusAnchorAfterSideData = false
        latestBottomConfirmedSeq = screenActions.history.rememberedConversationBottomSeq(for: conversationID)
        didUserInteractWithMessageScroll = false
        lastVisibleReadAckToken = ""
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_RESET_RENDER_CACHE_TASK - 修改开始：切换会话时清理延迟刷新和旧消息触发节流状态
        messageRenderCacheRefreshTask?.cancel()
        messageRenderCacheRefreshTask = nil
        // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
        timelineViewModel.reset()
        // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END
        lastOlderHistoryLoadAttemptAt = .distantPast
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_RESET_RENDER_CACHE_TASK - 修改结束：切换会话时清理延迟刷新和旧消息触发节流状态
        updateRealtimeAutoReadGate()
    }

    var isAutomaticBottomScrollSuppressed: Bool {
        transcriptScrollControl.isSuppressed(now: Date())
    }

    var automaticBottomScrollGeneration: Int {
        transcriptScrollControl.generation
    }

    var canApplyAutomaticBottomScroll: Bool {
        chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: isUserBrowsingHistory,
            isLoadingConversationHistory: isLoadingConversationHistory,
            isAutomaticBottomScrollSuppressed: isAutomaticBottomScrollSuppressed,
            didUserInteractWithMessageScroll: didUserInteractWithMessageScroll,
            isAtBottom: isAtBottom
        )
    }

    /// 进入会话的稳定窗口内(用户还没碰过滚动),即使历史同步仍在飞行中也允许
    /// 底部跟随。进入会话时的窗口同步会在 in-flight 标记清除前 apply 消息批,
    /// 若只依赖 canApplyAutomaticBottomScroll(要求 !isLoadingConversationHistory),
    /// 这批消息落地后的跟底会被静默跳过,表现为“点进会话不在最底部”。
    var canApplyEntryStabilizationBottomScroll: Bool {
        isWithinChatEntryStabilizationWindow
            && !didUserInteractWithMessageScroll
            && !isUserBrowsingHistory
            && !isAutomaticBottomScrollSuppressed
    }

    func nextAutomaticBottomScrollGeneration() -> Int {
        transcriptScrollControl.nextGeneration()
    }

    private var isWithinChatEntryStabilizationWindow: Bool {
        Date() < chatEntryStabilizationUntil
    }

    func suppressAutomaticBottomScroll(reason: String) {
        transcriptScrollControl.suppress(now: Date(), interval: automaticBottomScrollSuppressionInterval)
        logInitialAnchorDecision("suppress_auto_bottom_\(reason)", targetID: bottomAnchorID, unreadCount: rawInitialUnreadCount())
    }

    func logInitialAnchorDecision(_ event: String, targetID: String?, unreadCount: Int) {
        print("[JHT ChatAnchor] event=\(event) conversation=\(conversationID) target=\(targetID ?? "none") unread=\(unreadCount) message_count=\(conversation.messages.count) latest_loaded_seq=\(latestLoadedMessageSeq) last_msg_seq=\(conversation.lastMsgSeq) last_read_seq=\(conversation.lastReadSeq) first_unread_seq=\(conversation.firstUnreadSeq) confirmed_bottom_seq=\(latestBottomConfirmedSeq) did_initial_scroll=\(didInitialScroll) loading=\(isLoadingConversationHistory) attempts=\(initialUnreadAnchorLoadAttempts) user_interacted=\(didUserInteractWithMessageScroll) browsing=\(isUserBrowsingHistory) at_bottom=\(isAtBottom) auto_bottom_suppressed=\(isAutomaticBottomScrollSuppressed)")
    }

}

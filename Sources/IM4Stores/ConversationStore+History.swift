import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN

public extension ConversationStore {
    func conversationAwaitingHistoryBoundaryConfirmation(_ conversation: ConversationMessageSnapshot) -> ConversationMessageSnapshot {
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

    func conversationPreparedForLocalHistoryProjection(_ conversation: ConversationMessageSnapshot) -> ConversationMessageSnapshot {
        CachedConversationHistoryProjection.preparedForLocalHistoryProjection(conversation, conversationListPreview: conversationListPreview)
    }

    func historyBoundary(for conversation: ConversationMessageSnapshot?) -> HistoryVisibilityBoundary? {
        guard let conversation, conversation.kind == .group else { return nil }
        guard conversation.historyBoundaryConfirmed || conversation.historyLimited || conversation.historyVisibleFromSeq > 1 else { return nil }
        return HistoryVisibilityBoundary(
            fromSeq: conversation.historyVisibleFromSeq,
            limited: conversation.historyLimited,
            confirmed: conversation.historyBoundaryConfirmed
        )
    }

    func historyVisibleMessages(
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

    func applyingHistoryVisibilityBoundary(
        _ boundary: HistoryVisibilityBoundary?,
        to conversation: ConversationMessageSnapshot?,
        keepPendingLocalMessages: Bool = true
    ) -> ConversationMessageSnapshot? {
        guard let conversation else { return nil }
        var updated = conversation
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
        // WDT_CONVERSATION_LIST_STABILITY_20261103_BEGIN: unchanged group metadata must not replace a newer summary with a partial local history.
        let refreshSummary = !conversation.historyBoundaryConfirmed
            || conversation.historyVisibleFromSeq != updated.historyVisibleFromSeq
            || conversation.historyLimited != updated.historyLimited
            || conversation.historyBoundaryConfirmed != updated.historyBoundaryConfirmed
            || conversation.messages != updated.messages
        refreshHistoryBoundedSummary(&updated, boundary: resolvedBoundary, refreshSummary: refreshSummary)
        // WDT_CONVERSATION_LIST_STABILITY_20261103_END
        return updated
    }

    @discardableResult
    func applyHistoryVisibilityBoundary(
        channelID: String,
        boundary: HistoryVisibilityBoundary,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedChannelID.isEmpty,
                  let index = conversations.firstIndex(where: { $0.id == normalizedChannelID })
                    ?? conversationMessageSnapshots().firstIndex(where: { $0.kind == .group && channelIDForConversation($0) == normalizedChannelID }),
                  let updated = applyingHistoryVisibilityBoundary(boundary, to: conversationMessageSnapshot(at: index)) else { return false }
            guard updated != conversationMessageSnapshot(at: index) else { return false }
            var next = conversationMessageSnapshots()
            next[index] = updated
            return publishConversationsIfChanged(next)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func refreshHistoryBoundedSummary(_ conversation: inout ConversationMessageSnapshot, boundary: HistoryVisibilityBoundary, refreshSummary: Bool) {
        // WDT_CONVERSATION_LIST_STABILITY_20261103_BEGIN: unread/visibility cleanup below still runs on every application.
        if refreshSummary {
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
        }
        // WDT_CONVERSATION_LIST_STABILITY_20261103_END
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

    func recentHistoryAfterSeq(for conversation: ConversationMessageSnapshot, limit: Int) -> Int64 {
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：最近历史游标计算避免生成序号临时数组
        let localMaxSeq = ConversationSequenceInspector.maximumChannelSeq(in: conversation.messages) ?? 0
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        let latestKnownSeq = max(conversation.lastMsgSeq, localMaxSeq)
        guard latestKnownSeq > 0 else { return 0 }
        return max(0, latestKnownSeq - Int64(limit))
    }

    func initialMessageSyncWindows(for conversation: ConversationMessageSnapshot, limit: Int) -> [MessageSyncWindow] {
        let boundedLimit = max(limit, 1)
        let latestWindow = MessageSyncWindow(
            afterSeq: recentHistoryAfterSeq(for: conversation, limit: boundedLimit),
            limit: boundedLimit
        )
        return [latestWindow]
    }

    func messageSyncPlan(
        for conversation: ConversationMessageSnapshot,
        historyKey: String,
        force: Bool,
        latestHistoryWindowLimit: Int
    ) -> MessageSyncPlan {
        if !force, hasUsableRemoteHistory(for: conversation) {
            return .sidecarsOnly
        }
        return .remoteHistory(
            historyKey: historyKey,
            windows: initialMessageSyncWindows(for: conversation, limit: latestHistoryWindowLimit)
        )
    }

    func oldestConfirmedMessageSeq(in conversation: ConversationMessageSnapshot) -> Int64? {
        let confirmedMessages = conversation.messages
            .filter { message in
                message.channelSeq > 0
                    && !message.id.hasPrefix("local_")
                    && message.status != .sending
                    && message.status != .failed
        }
        guard !confirmedMessages.isEmpty else { return nil }
        // Pinned messages can be older highlights, not the normal timeline boundary.
        let timelineMessages = confirmedMessages.filter { !$0.isPinned }
        return (timelineMessages.isEmpty ? confirmedMessages : timelineMessages)
            .map(\.channelSeq)
            .min()
    }

    func olderHistoryAvailabilityPlan(for conversation: ConversationMessageSnapshot, historyKey: String) -> OlderHistoryAvailabilityPlan {
        let target = OlderHistoryAvailabilityTarget(
            historyKey: historyKey,
            conversationID: conversation.id,
            oldestSeq: oldestConfirmedMessageSeq(in: conversation) ?? 0
        )
        guard !hasReachedHistoryStart(historyKey: target.historyKey) else {
            return .reachedStart(historyKey: target.historyKey, conversationID: target.conversationID)
        }
        if let boundary = historyBoundary(for: conversation),
           boundary.isRestrictive,
           target.oldestSeq > 0,
           target.oldestSeq <= boundary.fromSeq {
            return .reachedStart(historyKey: target.historyKey, conversationID: target.conversationID)
        }
        guard target.oldestSeq > 1 else {
            return .unavailable(historyKey: target.historyKey, conversationID: target.conversationID)
        }
        return .available(target)
    }

    func olderHistoryAvailabilityTarget(for conversation: ConversationMessageSnapshot, historyKey: String) -> OlderHistoryAvailabilityTarget? {
        guard case .available(let target) = olderHistoryAvailabilityPlan(for: conversation, historyKey: historyKey) else {
            return nil
        }
        return target
    }

    func newestConfirmedMessageSeq(in conversation: ConversationMessageSnapshot) -> Int64? {
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：单次扫描可用远端消息，避免 filter + map 双重临时数组
        var newestSeq: Int64?
        for message in conversation.messages
            where message.channelSeq > 0
                && !message.isPinnedContextOnly
                && isUsableRemoteHistoryMessage(message) {
            if let current = newestSeq {
                if message.channelSeq > current {
                    newestSeq = message.channelSeq
                }
            } else {
                newestSeq = message.channelSeq
            }
        }
        return newestSeq
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
    }

    func newerHistoryAvailabilityTarget(
        for conversation: ConversationMessageSnapshot,
        historyKey: String,
        limit: Int
    ) -> NewerHistoryAvailabilityTarget? {
        guard let newestSeq = newestConfirmedMessageSeq(in: conversation), newestSeq > 0 else { return nil }
        let latestKnownSeq = max(conversation.lastMsgSeq, newestSeq)
        guard latestKnownSeq > newestSeq else { return nil }
        return NewerHistoryAvailabilityTarget(
            historyKey: historyKey,
            conversationID: conversation.id,
            afterSeq: newestSeq,
            latestKnownSeq: latestKnownSeq,
            limit: limit
        )
    }

    func hasUsableRemoteHistory(for conversation: ConversationMessageSnapshot) -> Bool {
        let confirmedMessages = conversation.messages.filter(isUsableRemoteHistoryMessage)
        guard !confirmedMessages.isEmpty else { return false }
        guard confirmedMessages.count > 1 else { return false }
        let sequencedMessages = confirmedMessages.filter { $0.channelSeq > 0 }
        if conversation.lastMsgSeq > 0 {
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免历史可用性检查生成序号临时数组
            let latestLocalSeq = ConversationSequenceInspector.maximumChannelSeq(in: sequencedMessages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
            guard latestLocalSeq >= conversation.lastMsgSeq else { return false }
            let expectedRecentCount = Int(min(Int64(20), max(Int64(1), conversation.lastMsgSeq)))
            let lowerBound = max(Int64(0), conversation.lastMsgSeq - Int64(expectedRecentCount))
            let recentConfirmedIDs = Set(sequencedMessages.filter { $0.channelSeq > lowerBound }.map(\.id))
            guard recentConfirmedIDs.count >= expectedRecentCount else { return false }
        }
        if conversation.kind != .system,
           conversation.lastMsgSeq > 1,
           confirmedMessages.filter({ !$0.isPinned }).count <= 1 {
            return false
        }
        guard conversation.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return true
        }
        return confirmedMessages.contains { message in
            message.text == conversation.lastMessage || message.channelSeq > 0
        }
    }

    @discardableResult
    func trimConversationToLatestWindow(conversationID: String, limit: Int) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
            let currentMessages = conversationMessageSnapshot(at: index).messages
            let retained = retainedMessages(currentMessages, for: .latestTail(limit: limit))
            guard retained.map(\.id) != currentMessages.map(\.id) else { return false }
            mutateStoredMessageWindow(inConversationAt: index) { $0 = retained } // WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func needsHistoryHydration(
        local: ConversationMessageSnapshot?,
        remoteLatestSeq: Int64,
        remoteLastMessageID: String?
    ) -> Bool {
        guard let local else { return true }
        guard !local.messages.isEmpty else { return true }
        guard local.messages.count > 1 else { return true }
        if remoteLatestSeq > 0 {
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免历史补水判断生成序号临时数组
            let localLatestMessageSeq = ConversationSequenceInspector.maximumChannelSeq(in: local.messages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
            if remoteLatestSeq > localLatestMessageSeq {
                return true
            }
        }
        let normalizedLastMessageID = remoteLastMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedLastMessageID.isEmpty,
           !local.messages.contains(where: { $0.id == normalizedLastMessageID }) {
            return true
        }
        return !hasUsableRemoteHistory(for: local)
    }

    func historyPrefetchTargets(
        candidates: [HistoryPrefetchCandidate],
        limit: Int
    ) -> [HistoryPrefetchTarget] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        return candidates
            .filter { candidate in
                needsHistoryHydration(
                    local: candidate.local,
                    remoteLatestSeq: candidate.latestSeq,
                    remoteLastMessageID: candidate.remote.lastMessage?.messageID
                )
            }
            .sorted(by: historyPrefetchCandidatePrecedes)
            .prefix(boundedLimit)
            .map { candidate in
                HistoryPrefetchTarget(
                    remote: candidate.remote,
                    channelID: candidate.channelID,
                    reason: historyPrefetchReason(for: candidate),
                    latestSeq: candidate.latestSeq,
                    sortTimestamp: candidate.sortTimestamp,
                    logID: candidate.logID
                )
            }
    }

    func historyPrefetchExecutionPlan(
        targets: [HistoryPrefetchTarget],
        messageLimit: Int,
        maxConcurrent: Int
    ) -> HistoryPrefetchExecutionPlan {
        let boundedMessageLimit = max(1, messageLimit)
        let boundedMaxConcurrent = max(1, maxConcurrent)
        let commands = targets.map { target in
            let afterSeq = target.remote.lastMsgSeq > Int64(boundedMessageLimit)
                ? target.remote.lastMsgSeq - Int64(boundedMessageLimit)
                : 0
            return HistoryPrefetchFetchCommand(
                remote: target.remote,
                channelID: target.channelID,
                apiChannelID: target.remote.channelID,
                channelType: target.remote.channelType,
                afterSeq: afterSeq,
                limit: boundedMessageLimit,
                reason: target.reason,
                summaryFragment: target.summaryFragment
            )
        }
        return HistoryPrefetchExecutionPlan(
            commands: commands,
            maxConcurrent: boundedMaxConcurrent
        )
    }

    func historyPrefetchReadReceiptBackfillTarget(
        for command: HistoryPrefetchFetchCommand,
        readReceiptsEnabled: Bool,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> HistoryPrefetchReadReceiptBackfillTarget? {
        // Delivery receipts are a baseline transport capability, so sidecar
        // catch-up remains active even when detailed read receipts are licensed off.
        _ = readReceiptsEnabled
        let lookupID = command.apiChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lookupID.isEmpty else { return nil }
        let conversation = conversationMessageSnapshots().first { $0.id == lookupID }
            ?? conversationMessageSnapshots().first { channelIDForConversation($0) == lookupID }
        let hasOutgoingMessages = conversation?.messages.contains { $0.isOutgoing } == true
        guard hasOutgoingMessages else { return nil }
        return HistoryPrefetchReadReceiptBackfillTarget(
            channelID: command.apiChannelID,
            channelType: command.channelType
        )
    }

    private func historyPrefetchCandidatePrecedes(_ lhs: HistoryPrefetchCandidate, _ rhs: HistoryPrefetchCandidate) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
        if lhs.remote.unreadCount != rhs.remote.unreadCount { return lhs.remote.unreadCount > rhs.remote.unreadCount }
        if lhs.sortTimestamp != rhs.sortTimestamp { return lhs.sortTimestamp > rhs.sortTimestamp }
        if lhs.latestSeq != rhs.latestSeq { return lhs.latestSeq > rhs.latestSeq }
        if lhs.remote.stick != rhs.remote.stick { return lhs.remote.stick && !rhs.remote.stick }
        return lhs.channelID < rhs.channelID
    }

    private func historyPrefetchReason(for candidate: HistoryPrefetchCandidate) -> String {
        if candidate.isActive { return "active" }
        if candidate.remote.unreadCount > 0 { return "unread" }
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免预取原因判断生成序号临时数组
        let localLatestSeq = candidate.local.map {
            ConversationSequenceInspector.maximumChannelSeq(in: $0.messages) ?? 0
        } ?? 0
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        if candidate.latestSeq > localLatestSeq { return "latest_seq" }
        return "recent_activity"
    }

    func isRemoteMessageOlderThanCurrentWindow(
        _ remote: RemoteMessage,
        oldestSeq: Int64,
        existingIDs: Set<String>,
        existingSeqs: Set<Int64>
    ) -> Bool {
        remote.channelSeq > 0
            && remote.channelSeq < oldestSeq
            && !existingIDs.contains(remote.messageID)
            && !existingSeqs.contains(remote.channelSeq)
    }

    func isRemoteMessageNewerThanCurrentWindow(
        _ remote: RemoteMessage,
        newestSeq: Int64,
        existingIDs: Set<String>,
        existingSeqs: Set<Int64>
    ) -> Bool {
        remote.channelSeq > 0
            && remote.channelSeq > newestSeq
            && !existingIDs.contains(remote.messageID)
            && !existingSeqs.contains(remote.channelSeq)
    }

    private func isUsableRemoteHistoryMessage(_ message: ChatMessage) -> Bool {
        !message.id.hasPrefix("local_")
            && message.status != .sending
            && message.status != .failed
            && message.status != .recalled
            && !message.isDeletedLocally
    }

    // WDT_IOS1_STORES_MESSAGE_MEMORY_20261110: complete original retention body and two pure dependencies are in IM4Stores.
    func retainedMessages(_ messages: [ChatMessage], for retention: MessageWindowRetention) -> [ChatMessage] {
        IM4Stores.retainedConversationMessages(messages, for: retention)
    }

    func replaceWarmRefreshTask(refreshKey: String, task: Task<Void, Never>) {
        let key = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            task.cancel()
            return
        }
        warmRefreshTasks[key]?.cancel()
        warmRefreshTasks[key] = task
    }

    func finishWarmRefreshTask(refreshKey: String) {
        let key = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        warmRefreshTasks.removeValue(forKey: key)
    }

    func hasWarmRefreshTask(refreshKey: String) -> Bool {
        let key = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return warmRefreshTasks[key] != nil
    }

    func hasWarmRefreshTasks() -> Bool {
        !warmRefreshTasks.isEmpty
    }

    func cancelWarmRefreshTasks(conversationID: String) {
        let conversationKey = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conversationKey.isEmpty else { return }
        let suffix = "|\(conversationKey)"
        let keys = warmRefreshTasks.keys.filter { $0.hasSuffix(suffix) }
        for key in keys {
            warmRefreshTasks[key]?.cancel()
            warmRefreshTasks.removeValue(forKey: key)
        }
    }

    func cancelAllWarmRefreshTasks() {
        warmRefreshTasks.values.forEach { $0.cancel() }
        warmRefreshTasks.removeAll()
    }

    func shouldShowHistorySyncErrorToast(
        conversationID: String,
        now: Date = Date(),
        throttleInterval: TimeInterval = 20
    ) -> Bool {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = max(0, throttleInterval)
        if let last = historySyncErrorToastTimesByConversationID[key],
           now.timeIntervalSince(last) < interval {
            return false
        }
        historySyncErrorToastTimesByConversationID[key] = now
        return true
    }

    func historySyncErrorToastTime(conversationID: String) -> Date? {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return historySyncErrorToastTimesByConversationID[key]
    }

    func hasHistorySyncErrorToastTimes() -> Bool {
        !historySyncErrorToastTimesByConversationID.isEmpty
    }

    func isHistoryLoading(conversationID: String) -> Bool {
        historyLoadingIDs.contains(conversationID)
    }

    func hasReachedHistoryStart(historyKey: String) -> Bool {
        historyReachedStartKeys.contains(historyKey)
    }

    func hasHistoryReachedStartKeys() -> Bool {
        !historyReachedStartKeys.isEmpty
    }

    func historyBackfillAfterSeq(historyKey: String, defaultValue: Int64) -> Int64 {
        historyBackfillAfterSeqs[historyKey] ?? defaultValue
    }

    func hasHistoryBackfillAfterSeqs() -> Bool {
        !historyBackfillAfterSeqs.isEmpty
    }

    func hasHistoryLoadRequestTimes() -> Bool {
        !historyLoadRequestTimes.isEmpty
    }

    func markHistoryUnavailable(historyKey: String, conversationID: String, message: String) {
        historyReachedStartKeys.insert(historyKey)
        historyMessages[conversationID] = message
    }

    // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110_BEGIN
    func beginOlderHistoryLoad(historyKey: String, conversationID: String, now: Date, throttleInterval: TimeInterval) -> Bool {
        beginOlderHistoryLoadClaim(historyKey: historyKey, conversationID: conversationID, now: now, throttleInterval: throttleInterval) != nil
    }

    func beginOlderHistoryLoadClaim(historyKey: String, conversationID: String, now: Date, throttleInterval: TimeInterval) -> HistorySyncClaim? {
        if let lastRequestTime = historyLoadRequestTimes[historyKey],
           now.timeIntervalSince(lastRequestTime) < throttleInterval {
            return nil
        }
        let request = olderHistorySyncRequest(historyKey: historyKey, conversationID: conversationID, reason: "begin")
        guard let claim = beginHistorySyncClaim(request: request, conversationID: conversationID, showLoadingIndicator: true) else {
            return nil
        }
        historyLoadRequestTimes[historyKey] = now
        historyMessages[conversationID] = nil
        historyLoadingIDs.insert(conversationID)
        return claim
    }

    func finishOlderHistoryLoad(historyKey: String? = nil, conversationID: String) {
        guard let historyKey else { return }
        let request = olderHistorySyncRequest(historyKey: historyKey, conversationID: conversationID, reason: "finish")
        guard let claim = activeHistorySyncClaims[request.inFlightKey] else { return }
        finishHistorySync(claim)
    }
    // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110_END

    func markOlderHistoryReachedStart(historyKey: String, conversationID: String, message: String) {
        historyBackfillAfterSeqs.removeValue(forKey: historyKey)
        historyReachedStartKeys.insert(historyKey)
        historyMessages[conversationID] = message
    }

    func markOlderHistoryNeedsContinue(
        historyKey: String,
        conversationID: String,
        nextBackfillAfterSeq: Int64,
        pageLimit: Int,
        message: String
    ) {
        historyBackfillAfterSeqs[historyKey] = max(0, nextBackfillAfterSeq - Int64(pageLimit))
        historyMessages[conversationID] = message
    }

    func markOlderHistoryApplied(historyKey: String, conversationID: String) {
        historyBackfillAfterSeqs.removeValue(forKey: historyKey)
        historyReachedStartKeys.remove(historyKey)
        historyMessages[conversationID] = nil
        directDisabledMessages[conversationID] = nil
        directFriendRequestContexts[conversationID] = nil
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

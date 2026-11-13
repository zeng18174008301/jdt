import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN

public extension ConversationStore {
    @discardableResult
    func mergePersistedMessagePage(_ page: [ChatMessage], conversationID: String) -> Int {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard !page.isEmpty,
                  let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return 0 }
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_PERSISTED_PREPEND_FAST_PATH_APPLY - 修改开始：本地旧消息分页优先增量合并，减少下拉加载时全量排序
            if let inserted = mergePersistedMessagePageByPrependingIfPossible(
                page,
                conversationID: conversationID,
                at: index
            ) {
                return inserted
            }
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_PERSISTED_PREPEND_FAST_PATH_APPLY - 修改结束：本地旧消息分页优先增量合并，减少下拉加载时全量排序
            // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_BEGIN
            var updated = conversationMessageSnapshot(at: index)
            var didWrite = false
            var identifiers = Set(updated.messages.map(\.id))
            var sequences = Set(updated.messages.map(\.channelSeq).filter { $0 > 0 })
            var rtcAuthorityByCallID: [String: (conversationID: String, authority: RTCCallRecordAuthority)] = [:]
            for conversation in conversationMessageSnapshots() {
                for existingMessage in conversation.messages {
                    guard let authority = rtcAuthority(existingMessage),
                          rtcAuthorityByCallID[authority.callID] == nil else { continue }
                    rtcAuthorityByCallID[authority.callID] = (conversation.id, authority)
                }
            }
            var inserted = 0
            for message in page {
                if let authority = rtcAuthority(message),
                   let existing = rtcAuthorityByCallID[authority.callID] {
                    if existing.conversationID != conversationID || existing.authority != authority,
                       authority.channelSeq > 0 {
                        updated.messageCoveredThroughSeq = min(
                            updated.messageCoveredThroughSeq,
                            max(0, authority.channelSeq - 1)
                        )
                        updated.messageCoverageRequiresRecovery = true
                        didWrite = true
                    }
                    continue
                }
                guard !identifiers.contains(message.id),
                      message.channelSeq <= 0 || !sequences.contains(message.channelSeq) else { continue }
                updated.messages.append(message)
                didWrite = true
                identifiers.insert(message.id)
                if let authority = rtcAuthority(message) {
                    rtcAuthorityByCallID[authority.callID] = (conversationID, authority)
                }
                if message.channelSeq > 0 {
                    sequences.insert(message.channelSeq)
                }
                inserted += 1
            }
            if inserted > 0 {
                updated.messages.sort(by: messageTimelinePrecedes)
            }
            if didWrite { commitConversationSnapshot(updated, at: index) }
            // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_END
            return inserted
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_PERSISTED_PREPEND_FAST_PATH_HELPER - 修改开始：本地旧消息分页只在安全条件下线性合并
    private func mergePersistedMessagePageByPrependingIfPossible(
        _ page: [ChatMessage],
        conversationID: String,
        at index: Int
    ) -> Int? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let currentMessages = conversationMessageSnapshot(at: index).messages
            guard !currentMessages.isEmpty,
                  messagesAreTimelineSorted(currentMessages) else {
                return nil
            }
            let oldestExistingSeq = currentMessages
                .lazy
                .map(\.channelSeq)
                .filter { $0 > 0 }
                .min() ?? 0
            guard oldestExistingSeq > 0 else { return nil }

            var incomingIDs = Set<String>()
            var incomingSeqs = Set<Int64>()
            var incomingMessages: [ChatMessage] = []
            incomingMessages.reserveCapacity(page.count)
            for message in page {
                let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !messageID.isEmpty,
                      message.channelSeq > 0,
                      message.channelSeq < oldestExistingSeq,
                      rtcAuthority(message) == nil else {
                    return nil
                }
                guard !incomingIDs.contains(messageID),
                      !incomingSeqs.contains(message.channelSeq) else {
                    continue
                }
                incomingIDs.insert(messageID)
                incomingSeqs.insert(message.channelSeq)
                incomingMessages.append(message)
            }
            guard !incomingMessages.isEmpty else { return 0 }

            var existingIncomingIDs = Set<String>()
            var existingIncomingSeqs = Set<Int64>()
            for message in currentMessages {
                let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if incomingIDs.contains(messageID) {
                    existingIncomingIDs.insert(messageID)
                }
                if message.channelSeq > 0, incomingSeqs.contains(message.channelSeq) {
                    existingIncomingSeqs.insert(message.channelSeq)
                }
            }

            incomingMessages.removeAll { message in
                existingIncomingIDs.contains(message.id.trimmingCharacters(in: .whitespacesAndNewlines))
                    || existingIncomingSeqs.contains(message.channelSeq)
            }
            guard !incomingMessages.isEmpty else { return 0 }

            incomingMessages.sort(by: messageTimelinePrecedes)
            // WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110_BEGIN
            let mergedWindow = mergedTimelineMessages(incomingMessages, currentMessages)
            mutateStoredMessageWindow(inConversationAt: index) { $0 = mergedWindow }
            // WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110_END
            return incomingMessages.count
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_PERSISTED_PREPEND_FAST_PATH_HELPER - 修改结束：本地旧消息分页只在安全条件下线性合并

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_PREPEND_STORE_FAST_PATH - 修改开始：旧消息分页优先线性 prepend 合并，避免全量排序和大集合重建
    func mergeOlderHistoryPrependIfPossible(
        previous: ConversationMessageSnapshot,
        mappedRemoteMessages: [MappedRemoteMessage],
        readReceiptsEnabled: Bool,
        windowRetention: MessageWindowRetention,
        sequenceCoverageAfterSeq: Int64?,
        olderHistoryBeforeSeq: Int64,
        coveredChannelSeqs: [Int64]?,
        effectiveReadSeq: Int64
    ) -> MergedRemoteMessagesResult? {
        guard olderHistoryBeforeSeq > 1,
              windowRetention == .preserveLoadedHistory,
              !mappedRemoteMessages.isEmpty,
              !previous.messages.isEmpty,
              messagesAreTimelineSorted(previous.messages),
              previous.lastMsgSeq > 0,
              previous.messageCoveredThroughSeq > 0 || previous.messageCoverageRequiresRecovery else {
            return nil
        }

        var incomingIDs = Set<String>()
        var incomingSeqs = Set<Int64>()
        var incomingEntries: [(entry: MappedRemoteMessage, message: ChatMessage)] = []
        incomingEntries.reserveCapacity(mappedRemoteMessages.count)

        for entry in mappedRemoteMessages {
            guard entry.matchedLocalID == nil else { return nil }
            let sequence = entry.remote.channelSeq
            guard sequence > 0, sequence < olderHistoryBeforeSeq else { return nil }
            // Fast prepend is only for ordinary history. A malformed RTC record
            // has no typed authority but still needs the normal conflict/gap path.
            // A declared call ID may also refer to an authority in another chat;
            // let the existing merge resolve it rather than duplicating validation.
            guard entry.message.rtcCallRecord == nil,
                  !entry.message.isRTCCallRecordMessage,
                  entry.message.kind != .rtcCallRecord,
                  entry.remote.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "rtc_call_record",
                  entry.remote.payload["content_type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "rtc_call_record",
                  (entry.remote.payload["call_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else {
                return nil
            }

            let remoteMessageID = entry.remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let messageID = entry.message.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteMessageID.isEmpty || !messageID.isEmpty else { return nil }
            if (!remoteMessageID.isEmpty && incomingIDs.contains(remoteMessageID))
                || (!messageID.isEmpty && incomingIDs.contains(messageID))
                || incomingSeqs.contains(sequence) {
                continue
            }

            incomingEntries.append((entry: entry, message: entry.message))
            if !remoteMessageID.isEmpty {
                incomingIDs.insert(remoteMessageID)
            }
            if !messageID.isEmpty {
                incomingIDs.insert(messageID)
            }
            incomingSeqs.insert(sequence)
        }

        guard !incomingEntries.isEmpty else { return nil }

        var retainedPrevious: [ChatMessage] = []
        retainedPrevious.reserveCapacity(previous.messages.count)
        var duplicatePreviousByID: [String: ChatMessage] = [:]
        var duplicatePreviousBySeq: [Int64: ChatMessage] = [:]
        for existing in previous.messages {
            let existingID = existing.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDuplicate = (!existingID.isEmpty && incomingIDs.contains(existingID))
                || (existing.channelSeq > 0 && incomingSeqs.contains(existing.channelSeq))
            guard isDuplicate else {
                retainedPrevious.append(existing)
                continue
            }
            if existing.rtcCallRecord != nil || existing.isRTCCallRecordMessage {
                return nil
            }
            if !existingID.isEmpty {
                duplicatePreviousByID[existingID] = existing
            }
            if existing.channelSeq > 0 {
                duplicatePreviousBySeq[existing.channelSeq] = existing
            }
        }

        var incomingMessages: [ChatMessage] = []
        incomingMessages.reserveCapacity(incomingEntries.count)
        for item in incomingEntries {
            var message = item.message
            let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if let previousMessage = (!messageID.isEmpty ? duplicatePreviousByID[messageID] : nil)
                ?? (message.channelSeq > 0 ? duplicatePreviousBySeq[message.channelSeq] : nil) {
                mergeExistingRemoteState(from: previousMessage, into: &message)
            }
            applyRemoteReadSummary(from: item.entry.remote, to: &message, readReceiptsEnabled: readReceiptsEnabled)
            incomingMessages.append(message)
        }

        incomingMessages.sort(by: messageTimelinePrecedes)
        let messages = mergedTimelineMessages(incomingMessages, retainedPrevious)
        let latestKnownSeq = max(previous.lastMsgSeq, incomingSeqs.max() ?? 0)
        var coveredThrough = max(previous.messageCoveredThroughSeq, sequenceCoverageAfterSeq ?? 0)
        let observedSequences = Set(
            (coveredChannelSeqs ?? mappedRemoteMessages.map { $0.remote.channelSeq })
                .filter { $0 > coveredThrough }
        ).sorted()
        for sequence in observedSequences {
            guard sequence == coveredThrough + 1 else { break }
            coveredThrough = sequence
        }
        let messageCoverageRequiresRecovery = previous.messageCoverageRequiresRecovery || latestKnownSeq > coveredThrough
        let sequenceRecoveryAfterSeq = messageCoverageRequiresRecovery ? coveredThrough : nil
        let sequenceRecoveryThroughSeq = sequenceRecoveryAfterSeq == nil ? nil : latestKnownSeq
        let latestMessage = latestConfirmedMessage(in: retainedPrevious)
            ?? latestConfirmedMessage(in: incomingMessages)
            ?? messages.last

        return MergedRemoteMessagesResult(
            messages: messages,
            latestMessage: latestMessage,
            incomingRealtimeMessages: [],
            latestKnownSeq: latestKnownSeq,
            messageCoveredThroughSeq: coveredThrough,
            messageCoverageRequiresRecovery: messageCoverageRequiresRecovery,
            sequenceRecoveryAfterSeq: sequenceRecoveryAfterSeq,
            sequenceRecoveryThroughSeq: sequenceRecoveryThroughSeq,
            pendingLocalFinalizations: []
        )
    }

    private func mergedTimelineMessages(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> [ChatMessage] {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        var merged: [ChatMessage] = []
        merged.reserveCapacity(lhs.count + rhs.count)
        var lhsIndex = 0
        var rhsIndex = 0
        while lhsIndex < lhs.count, rhsIndex < rhs.count {
            if messageTimelinePrecedes(lhs[lhsIndex], rhs[rhsIndex]) {
                merged.append(lhs[lhsIndex])
                lhsIndex += 1
            } else {
                merged.append(rhs[rhsIndex])
                rhsIndex += 1
            }
        }
        if lhsIndex < lhs.count {
            merged.append(contentsOf: lhs[lhsIndex...])
        }
        if rhsIndex < rhs.count {
            merged.append(contentsOf: rhs[rhsIndex...])
        }
        return merged
    }

    private func messagesAreTimelineSorted(_ messages: [ChatMessage]) -> Bool {
        guard messages.count > 1 else { return true }
        for index in messages.indices.dropFirst() {
            let previousIndex = messages.index(before: index)
            if messageTimelinePrecedes(messages[index], messages[previousIndex]) {
                return false
            }
        }
        return true
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_PREPEND_STORE_FAST_PATH - 修改结束：旧消息分页优先线性 prepend 合并，避免全量排序和大集合重建

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

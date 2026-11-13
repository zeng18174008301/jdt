// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import Foundation
import IM4Domain
import IM4Data

extension ConversationMessageMergeReducer {
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

    func mergedTimelineMessages(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> [ChatMessage] {
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

    func messagesAreTimelineSorted(_ messages: [ChatMessage]) -> Bool {
        guard messages.count > 1 else { return true }
        for index in messages.indices.dropFirst() {
            let previousIndex = messages.index(before: index)
            if messageTimelinePrecedes(messages[index], messages[previousIndex]) {
                return false
            }
        }
        return true
    }

}
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END

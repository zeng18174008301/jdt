// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import Foundation
import IM4Domain
import IM4Data

extension ConversationMessageMergeReducer {
    func finish(previous: ConversationMessageSnapshot?, mappedRemoteMessages: [MappedRemoteMessage],
        fromRealtime: Bool, windowRetention: MessageWindowRetention, sequenceCoverageAfterSeq: Int64?,
        coveredChannelSeqs: [Int64]?, effectiveReadSeq: Int64, state: inout MergeState) -> MergedRemoteMessagesResult {
        state.conflictingSequences.formUnion(state.rtcAuthorityConflictingSequences)

        let incomingRealtimeMessages: [ChatMessage] = fromRealtime
            ? state.acceptedEntries.compactMap { item in
                let entry = item.entry
                let message = item.message
                guard !entry.isRemoteFromCurrentUser,
                      !message.isOutgoing,
                      (message.channelSeq <= 0 || message.channelSeq > effectiveReadSeq),
                      !state.previousMessageIDs.contains(message.id),
                      (message.channelSeq <= 0 || !state.previousMessageSeqs.contains(message.channelSeq)),
                      entry.clientMessageIDs.allSatisfy({ !state.previousLocalClientIDs.contains($0) }) else { return nil }
                return message
            }
            : []

        var messages = state.previousMessages.filter { existing in
            !isPendingLocalMessage(existing)
                && !state.remoteMessageIDs.contains(existing.id)
                && (existing.channelSeq <= 0 || !state.remoteMessageSeqs.contains(existing.channelSeq))
        }
        messages.append(contentsOf: state.acceptedEntries.map(\.message))

        let pendingLocal = state.previousMessages.filter { message in
            isPendingLocalMessage(message)
                && !state.remoteClientMessageIDs.contains(message.id)
                && !state.matchedPendingLocalIDs.contains(message.id)
        }
        if !pendingLocal.isEmpty {
            var existingMessageIDs = Set(messages.map(\.id))
            var existingMessageSeqs = Set(messages.map(\.channelSeq).filter { $0 > 0 })
            for message in pendingLocal
                where !existingMessageIDs.contains(message.id)
                    && (message.channelSeq <= 0 || !existingMessageSeqs.contains(message.channelSeq)) {
                messages.append(message)
                existingMessageIDs.insert(message.id)
                if message.channelSeq > 0 {
                    existingMessageSeqs.insert(message.channelSeq)
                }
            }
        }
        messages.sort(by: messageTimelinePrecedes)

        let latestKnownSeq = max(
            previous?.lastMsgSeq ?? 0,
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免消息合并时多次 map().max() 临时数组
            ConversationSequenceInspector.maximumInt64(mappedRemoteMessages.lazy.map { $0.remote.channelSeq }) ?? 0,
            ConversationSequenceInspector.maximumInt64(state.acceptedEntries.lazy.map { $0.entry.remote.channelSeq }) ?? 0,
            ConversationSequenceInspector.maximumChannelSeq(in: messages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        )
        var coveredThrough = max(
            previous.map { messageSequenceCoveredThrough(in: $0) } ?? 0,
            sequenceCoverageAfterSeq ?? 0
        )
        if let firstRTCConflict = state.rtcAuthorityConflictingSequences.filter({ $0 > 0 }).min() {
            coveredThrough = min(coveredThrough, max(0, firstRTCConflict - 1))
        }
        let observedSequences = Set(
            (coveredChannelSeqs ?? mappedRemoteMessages.map { $0.remote.channelSeq })
                .filter { $0 > coveredThrough }
        ).sorted()
        for sequence in observedSequences {
            if sequence <= coveredThrough {
                continue
            }
            guard sequence == coveredThrough + 1,
                  !state.conflictingSequences.contains(sequence) else {
                break
            }
            coveredThrough = sequence
        }
        let sequenceRecoveryAfterSeq = (!state.rtcAuthorityConflictingSequences.isEmpty || latestKnownSeq > coveredThrough)
            ? coveredThrough
            : nil
        let messageCoverageRequiresRecovery = sequenceRecoveryAfterSeq != nil
        let sequenceRecoveryThroughSeq = max(latestKnownSeq, state.rtcAuthorityConflictingSequences.max() ?? 0)
        messages = retainedMessages(messages, for: windowRetention)
        return MergedRemoteMessagesResult(
            messages: messages,
            latestMessage: latestConfirmedMessage(in: messages) ?? messages.last,
            incomingRealtimeMessages: incomingRealtimeMessages,
            latestKnownSeq: latestKnownSeq,
            messageCoveredThroughSeq: coveredThrough,
            messageCoverageRequiresRecovery: messageCoverageRequiresRecovery,
            sequenceRecoveryAfterSeq: sequenceRecoveryAfterSeq,
            sequenceRecoveryThroughSeq: sequenceRecoveryAfterSeq == nil ? nil : sequenceRecoveryThroughSeq,
            pendingLocalFinalizations: state.pendingLocalFinalizations
        )
        }
}
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END

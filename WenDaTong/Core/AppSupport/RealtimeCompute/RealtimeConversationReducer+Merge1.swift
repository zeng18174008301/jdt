// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import IM4Stores
import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension RealtimeConversationReducer {
    // Source Stores/ConversationStore+RemoteMerge.swift:187; pure value snapshot counterpart.
    func mergeMappedRemoteMessages(
        previous: ConversationMessageSnapshot?,
        mappedRemoteMessages: [MappedRemoteMessage],
        readReceiptsEnabled: Bool,
        fromRealtime: Bool,
        windowRetention: MessageWindowRetention = .preserveLoadedHistory,
        sequenceCoverageAfterSeq: Int64? = nil,
        olderHistoryBeforeSeq: Int64? = nil,
        coveredChannelSeqs: [Int64]? = nil,
        effectiveReadSeq: Int64 = 0
    ) -> MergedRemoteMessagesResult {
        IM4Stores.ConversationMessageMergeReducer(conversations: conversations,
            rtcAuthority: RTCCallRecordMessageDeduplicator.authority)
            .mergeMappedRemoteMessages(previous: previous, mappedRemoteMessages: mappedRemoteMessages,
            readReceiptsEnabled: readReceiptsEnabled, fromRealtime: fromRealtime,
            windowRetention: windowRetention, sequenceCoverageAfterSeq: sequenceCoverageAfterSeq,
            olderHistoryBeforeSeq: olderHistoryBeforeSeq, coveredChannelSeqs: coveredChannelSeqs,
            effectiveReadSeq: effectiveReadSeq)
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END

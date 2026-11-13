// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import Foundation
import IM4Domain
import IM4Data

/// A value-only calculator. Instances are constructed within the calling executor;
/// no AppState, UI object or authority closure is transported to the worker actor.
public struct ConversationMessageMergeReducer {
    public typealias MappedRemoteMessage = ConversationStore.MappedRemoteMessage
    public typealias MergedRemoteMessagesResult = ConversationStore.MergedRemoteMessagesResult
    public typealias PendingLocalMessageFinalization = ConversationStore.PendingLocalMessageFinalization
    public typealias MessageWindowRetention = ConversationStore.MessageWindowRetention
    let conversations: [ConversationMessageSnapshot]
    let rtcAuthority: (ChatMessage) -> RTCCallRecordAuthority?

    public init(conversations: [ConversationMessageSnapshot],
        rtcAuthority: @escaping (ChatMessage) -> RTCCallRecordAuthority?) {
        self.conversations = conversations
        self.rtcAuthority = rtcAuthority
    }

    public func mergeMappedRemoteMessages(
        previous: ConversationMessageSnapshot?,
        mappedRemoteMessages: [MappedRemoteMessage],
        readReceiptsEnabled: Bool,
        fromRealtime: Bool,
        windowRetention: MessageWindowRetention = .preserveLoadedHistory,
        sequenceCoverageAfterSeq: Int64? = nil,
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_PREPEND_STORE_PARAM - 修改开始：更早消息分页 beforeSeq 触发保守快捷合并
        olderHistoryBeforeSeq: Int64? = nil,
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_PREPEND_STORE_PARAM - 修改结束：更早消息分页 beforeSeq 触发保守快捷合并
        coveredChannelSeqs: [Int64]? = nil,
        effectiveReadSeq: Int64 = 0
    ) -> MergedRemoteMessagesResult {
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_PREPEND_STORE_GATE - 修改开始：旧消息同步优先尝试线性合并
        if let olderHistoryBeforeSeq,
           !fromRealtime,
           let previous,
           let fastResult = mergeOlderHistoryPrependIfPossible(
            previous: previous,
            mappedRemoteMessages: mappedRemoteMessages,
            readReceiptsEnabled: readReceiptsEnabled,
            windowRetention: windowRetention,
            sequenceCoverageAfterSeq: sequenceCoverageAfterSeq,
            olderHistoryBeforeSeq: olderHistoryBeforeSeq,
            coveredChannelSeqs: coveredChannelSeqs,
            effectiveReadSeq: effectiveReadSeq
           ) {
            return fastResult
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_PREPEND_STORE_GATE - 修改结束：旧消息同步优先尝试线性合并
        var state = makeState(previous: previous, mappedRemoteMessages: mappedRemoteMessages)
        accept(mappedRemoteMessages, readReceiptsEnabled: readReceiptsEnabled, state: &state)
        return finish(previous: previous, mappedRemoteMessages: mappedRemoteMessages,
            fromRealtime: fromRealtime, windowRetention: windowRetention,
            sequenceCoverageAfterSeq: sequenceCoverageAfterSeq, coveredChannelSeqs: coveredChannelSeqs,
            effectiveReadSeq: effectiveReadSeq, state: &state)
    }
}
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END

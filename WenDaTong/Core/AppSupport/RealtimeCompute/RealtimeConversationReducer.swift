import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
/// Value-only counterpart of the original algorithms. Never owns or publishes Store state.
struct RealtimeConversationReducer {
    typealias MappedRemoteMessage = ConversationStore.MappedRemoteMessage
    typealias MergedRemoteMessagesResult = ConversationStore.MergedRemoteMessagesResult
    typealias PendingLocalMessageFinalization = ConversationStore.PendingLocalMessageFinalization
    typealias MessageWindowRetention = ConversationStore.MessageWindowRetention
    typealias HistoryVisibilityBoundary = ConversationStore.HistoryVisibilityBoundary
    typealias AppliedRemoteMessagesConversationResult = ConversationStore.AppliedRemoteMessagesConversationResult
    let conversations: [ConversationMessageSnapshot]
    func conversationMessageSnapshots() -> [ConversationMessageSnapshot] { conversations }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

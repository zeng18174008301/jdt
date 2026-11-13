import Foundation
import IM4Domain
import IM4Data

public extension ConversationStore {
    func applyPreparedRealtimeConversation(_ result: AppliedRemoteMessagesConversationResult,
        previousID: String?, channelID: String, changed: Bool) -> AppliedRemoteMessagesConversationResult {
        performMemoryCommand {
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
            if previousID == result.conversation.id,
               messageMemoryStore.commitExistingRealtimeConversation(result.conversation, changed: changed) { // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
                return result
            }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
            let current = conversationMessageSnapshots()
            var next = current // Patch fresh authority; never install the worker's old whole-Store snapshot.
            if let previousID, let index = next.firstIndex(where: { $0.id == previousID }) { next[index] = result.conversation }
            else if let index = next.firstIndex(where: { $0.id == result.conversation.id || $0.id == channelID }) { next[index] = result.conversation }
            else { next.insert(result.conversation, at: 0) }
            // Only lightweight current metadata order is reconciled on Main. Window sorting was done by the worker.
            next.sort(by: conversationListPrecedes)
            if changed || current.map(\.conversation) != next.map(\.conversation) { commitConversationSnapshots(next) }
            return result
        }
    }
}

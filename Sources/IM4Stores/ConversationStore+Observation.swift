import Foundation
import Combine
import IM4Domain
import IM4Data

// WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
private struct ConversationObservationBinding: Equatable {
    let scopeHash: String?
    let bindingID: UUID
    let conversationID: String?
}

public extension ConversationStore {
    private func conversationObservationBindings(id: String) -> AnyPublisher<ConversationObservationBinding, Never> {
        memoryUpdates.compactMap { [weak self] _ -> ConversationObservationBinding? in
            guard let self else { return nil }
            return ConversationObservationBinding(scopeHash: self.messageMemoryStore.scopeHash,
                bindingID: self.messageMemoryStore.bindingID,
                conversationID: self.conversationForPresentation(id: id)?.id)
        }.removeDuplicates().eraseToAnyPublisher()
    }

    func conversationMessageUpdates(id: String) -> AnyPublisher<ConversationMessageSnapshot?, Never> {
        conversationObservationBindings(id: id).map { [weak self] binding -> AnyPublisher<ConversationMessageSnapshot?, Never> in
            guard let self, let actualID = binding.conversationID,
                  let window = self.messageMemoryStore.conversationMessages(for: actualID) else {
                return Just(nil).eraseToAnyPublisher()
            }
            // Either input reads the same already-installed atomic frame. A
            // metadata event followed by its message event produces one value.
            let metadata = self.conversationPresentationUpdates(id: id).map { _ in () }
            let messages = window.updates.map { _ in () }
            return Publishers.Merge(metadata, messages)
                .filter { [weak self] _ in
                    self?.messageMemoryStore.bindingID == binding.bindingID
                        && self?.messageMemoryStore.scopeHash == binding.scopeHash
                }
                .map { [weak self] _ in self?.conversationMessagePresentation(id: id) }
                .eraseToAnyPublisher()
        }.switchToLatest().removeDuplicates().eraseToAnyPublisher()
    }

    func conversationMemoryCommits(id: String) -> AnyPublisher<MemoryCommit, Never> {
        conversationObservationBindings(id: id).map { [weak self] binding -> AnyPublisher<MemoryCommit, Never> in
            guard let self, let actualID = binding.conversationID else { return Empty().eraseToAnyPublisher() }
            return self.memoryCommits.filter {
                $0.scopeHash == binding.scopeHash && $0.bindingID == binding.bindingID
                    && $0.messageChanges[actualID] != nil
            }.eraseToAnyPublisher()
        }.switchToLatest().eraseToAnyPublisher()
    }
}
// WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END

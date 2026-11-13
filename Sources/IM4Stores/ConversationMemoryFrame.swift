// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import Foundation
import IM4Domain
import IM4Data

struct ScopedMessageWindowKey: Hashable, Sendable {
    let scopeHash: String
    let conversationID: String
}

// WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
public enum ConversationUnreadUpdate {
    case rebuild
    case preserve
    // Physical rows, never an ID dictionary: duplicate/colliding IDs still count separately.
    case delta(removing: [Conversation], adding: [Conversation], baseRevision: UInt64)
}
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

/// One authority, with separate metadata and normalized message collections.
/// Queued command frames are immutable pending transactions, never another writer.
@MainActor
struct ConversationMemoryFrame {
    var realtimeSignposts: [MessageMemoryDiagnostic] = []
    var derivationClock = ConversationDerivationClock() // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
    var presentationPageID: UUID?
    var changedMessageIDs: Set<String> = []
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
#if DEBUG
    var incrementalRealtimeConversationID: String?
#endif
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
    var revision: UInt64 = 0
    var scope: LocalMessageScope?
    var scopeHash: String?
    var binding = UUID()
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    private(set) var conversations: [Conversation] = []
    private(set) var firstIndexByID: [String: Int] = [:]
    private(set) var hasCanonicalOrder = true
    var metadataRevision: UInt64 = 0
    var singleConversationChange: (id: String, moved: Bool)?
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
    var windows: [ScopedMessageWindowKey: [ChatMessage]] = [:]
    var alertingUnreadTotal = 0

    init(scope: LocalMessageScope?) {
        self.scope = scope
        self.scopeHash = scope?.scopeHash
    }

    func messages(for id: String) -> [ChatMessage] {
        guard let scopeHash else { return [] }
        return windows[ScopedMessageWindowKey(scopeHash: scopeHash, conversationID: id)] ?? []
    }

    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    func conversation(id: String) -> Conversation? {
        firstIndexByID[id].map { conversations[$0] }
    }

    // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_BEGIN
    var hasDuplicateConversationIDs: Bool { firstIndexByID.count < conversations.count }
    // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_END

    mutating func replaceConversations(_ rows: [Conversation]) {
        conversations = rows
        rebuildIndexAndOrder()
    }

    private mutating func rebuildIndexAndOrder() {
        firstIndexByID = [:]
        firstIndexByID.reserveCapacity(conversations.count)
        for (index, row) in conversations.enumerated() where firstIndexByID[row.id] == nil {
            firstIndexByID[row.id] = index
        }
        hasCanonicalOrder = !hasDuplicateConversationIDs // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112
            && conversations.count == windows.count
            && conversations.allSatisfy { windows[ScopedMessageWindowKey(scopeHash: scopeHash ?? "", conversationID: $0.id)] != nil }
            && conversations.indices.allSatisfy { index in
                let current = order(at: index)
                return current.timestamp.isFinite && (index == 0 || !(current < order(at: index - 1)))
            }
    }

    func order(at index: Int) -> ConversationListOrder {
        let row = conversations[index]
        return ConversationListOrder(row: row, messages: messages(for: row.id))
    }

    func destination(for order: ConversationListOrder, replacing index: Int) -> Int {
        // Search the sorted sequence with the old slot logically removed.
        // Avoid searching when the new key still fits between its neighbors.
        if (index == 0 || !(order < self.order(at: index - 1))),
           (index == conversations.count - 1 || !(self.order(at: index + 1) < order)) { return index }
        var lower = 0
        var upper = conversations.count - 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let peer = middle < index ? middle : middle + 1
            if self.order(at: peer) < order { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    mutating func replaceOrderedConversation(_ row: Conversation, at index: Int, movingTo destination: Int) {
        if index == destination {
            if conversations[index] != row { conversations[index] = row }
        } else {
            // Repair only positions affected by the move.
            conversations.remove(at: index)
            conversations.insert(row, at: destination)
            for slot in min(index, destination)...max(index, destination) {
                firstIndexByID[conversations[slot].id] = slot
            }
        }
    }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END

    var metadata: ScopedMessageMemoryStore.MemorySnapshot {
        ScopedMessageMemoryStore.MemorySnapshot(revision: revision, conversations: conversations,
                                         alertingUnreadTotal: alertingUnreadTotal,
                                         metadataRevision: metadataRevision) // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
    }
}

// WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
extension ConversationMemoryFrame {
    func unreadTotal(removing oldRows: [Conversation], adding newRows: [Conversation]) -> Int {
        var result = alertingUnreadTotal
        // Subtract all old nonnegative contributions first. A valid final total
        // must not overflow just because one row grows before another shrinks.
        for row in oldRows { result -= ConversationUnreadBadgeProjection.contribution(row) }
        for row in newRows { result += ConversationUnreadBadgeProjection.contribution(row) }
        return result
    }

    func unreadTotal(for rows: [Conversation], update: ConversationUnreadUpdate) -> Int {
        switch update {
        case .rebuild: return ConversationUnreadBadgeProjection.total(rows)
        case .preserve: return alertingUnreadTotal
        case .delta(let oldRows, let newRows, let baseRevision):
            // A callback may have staged another command since a structural
            // replacement was prepared. Recalculate this derived total only;
            // never reject the mutation or an in-flight ACK by revision.
            guard revision == baseRevision else { return ConversationUnreadBadgeProjection.total(rows) }
            return unreadTotal(removing: oldRows, adding: newRows)
        }
    }

    func unreadUpdate(for values: [ConversationMessageSnapshot], at indices: Set<Int>, preparedAt: UInt64) -> ConversationUnreadUpdate {
        guard revision == preparedAt else { return .rebuild }
        return .delta(removing: indices.map { conversations[$0] },
                      adding: indices.map { values[$0].conversation }, baseRevision: preparedAt)
    }

    mutating func replaceMessageSnapshots(_ changes: [Int: ConversationMessageSnapshot]) {
        let oldRows = changes.keys.map { conversations[$0] }
        let newRows = changes.values.map(\.conversation)
        alertingUnreadTotal = unreadTotal(removing: oldRows, adding: newRows)
        changedMessageIDs = Set(changes.values.map(\.id))
        // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
        let replacesID = changes.contains { conversations[$0.key].id != $0.value.id }
        for index in changes.keys.sorted() {
            let snapshot = changes[index]!
            if conversations[index] != snapshot.conversation { conversations[index] = snapshot.conversation }
            windows[ScopedMessageWindowKey(scopeHash: scopeHash!, conversationID: snapshot.id)] = snapshot.messages
        }
        if replacesID {
            // Preserve the legacy physical rows and orphan windows. First lookup
            // still selects the first physical row when IDs collide.
            rebuildIndexAndOrder()
        } else if hasCanonicalOrder {
            hasCanonicalOrder = !changes.keys.contains { index in
                let current = order(at: index)
                return !current.timestamp.isFinite || (index > 0 && current < order(at: index - 1))
                    || (index + 1 < conversations.count && order(at: index + 1) < current)
            }
        }
        // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
    }
}
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

// WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
struct ConversationListOrder: Comparable {
    let pinned: Bool
    let timestamp: TimeInterval
    let id: String

    init(row: Conversation, messages: [ChatMessage]) {
        pinned = row.isPinned
        id = row.id
        if row.sortTimestamp > 0 {
            timestamp = row.sortTimestamp
        } else {
            timestamp = messages.last {
                $0.status != .failed && $0.status != .sending && !$0.isDeletedLocally
            }?.createdAt?.timeIntervalSince1970 ?? 0
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        return lhs.id < rhs.id
    }
}
// WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END

@MainActor
final class ConversationMemoryCell {
    var current: ConversationMemoryFrame
    init(scope: LocalMessageScope?) { current = ConversationMemoryFrame(scope: scope) }
}

/// Read-only per-conversation observation; values never rebind across login epochs.
@MainActor
public final class ConversationMessages: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public let scope: LocalMessageScope?
        public let conversationID: String
        public let revision: UInt64
        public let messages: [ChatMessage]
    }

    private let read: () -> Snapshot
    private let changes = PassthroughSubject<Snapshot, Never>()
    public var snapshot: Snapshot { read() }
    public var messages: [ChatMessage] { snapshot.messages }
    public var updates: AnyPublisher<Snapshot, Never> { changes.eraseToAnyPublisher() }

    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    private let readConversation: () -> Conversation?
    private let rowChanges = CurrentValueSubject<Void, Never>(())
    var rowUpdates: AnyPublisher<Conversation?, Never> {
        rowChanges.map { [weak self] in self?.readConversation() }.removeDuplicates().eraseToAnyPublisher()
    }

    init(read: @escaping () -> Snapshot, readConversation: @escaping () -> Conversation?) {
        self.read = read
        self.readConversation = readConversation
    }

    func publishRow() { rowChanges.send(()) }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
    func publish() {
        objectWillChange.send()
        changes.send(snapshot)
    }
}
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END

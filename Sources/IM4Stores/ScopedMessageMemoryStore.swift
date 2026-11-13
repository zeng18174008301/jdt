// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import Foundation
import IM4Domain
import IM4Data

@MainActor
public final class ScopedMessageMemoryStore {
    public struct MemorySnapshot {
        public let revision: UInt64
        public let conversations: [Conversation]
        public let alertingUnreadTotal: Int
        let metadataRevision: UInt64 // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
    }
    public struct MemoryCommit {
        public let previous: MemorySnapshot
        public let current: MemorySnapshot
        public let messageChanges: [String: MessageWindowChange]
        public let presentationPageID: UUID?
        public let scopeHash: String?
        public let bindingID: UUID
        public let realtimeSignposts: [String: [MessageMemoryDiagnostic]]
        // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
        /// Exact IDs whose first visible metadata row changed, including removals.
        public let changedConversationRowIDs: Set<String>
        /// The ordered IDs changed or the previous scope binding retired.
        public let conversationOrderChanged: Bool
        // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
        // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_BEGIN
        /// A list-affecting commit where either frame contains duplicate physical IDs.
        /// Use the full frame so first-row deltas cannot replace per-ID aggregates.
        public let requiresFullConversationListProjection: Bool
        // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_END
    }
    public struct MessageWindowChange {
        public let previous: [ChatMessage]
        public let current: [ChatMessage]
    }

    private let memoryCell: ConversationMemoryCell
    private var commandFrame: ConversationMemoryFrame?
    private var pendingFrames: [ConversationMemoryFrame] = []
    private var isPublishingMemory = false
    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
    private var realtimeAtomicBase: UInt64?
    private var realtimeAtomicChangedIDs: Set<String> = []
    private var realtimeAtomicStaged = false
    private var allowsSingleRealtimeConversationUpdate = false // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
    public var realtimeDerivationStamp: RealtimeDerivationStamp {
        RealtimeDerivationStamp(binding: activeFrame.binding, clock: activeFrame.derivationClock)
    }
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
    public func performRealtimeAtomicCommand(allowsSingleConversationUpdate: Bool = false, _ operation: () -> Void) {
        performMemoryCommand {
            guard realtimeAtomicBase == nil else {
                let previouslyAllowed = allowsSingleRealtimeConversationUpdate
                allowsSingleRealtimeConversationUpdate = false
                defer { allowsSingleRealtimeConversationUpdate = previouslyAllowed }
                operation()
                return
            }
            let base = activeFrame.revision
            realtimeAtomicBase = base; realtimeAtomicChangedIDs = []; realtimeAtomicStaged = false
            allowsSingleRealtimeConversationUpdate = allowsSingleConversationUpdate
            defer {
                let staged = realtimeAtomicStaged, ids = realtimeAtomicChangedIDs
                realtimeAtomicBase = nil; realtimeAtomicStaged = false; realtimeAtomicChangedIDs = []
                allowsSingleRealtimeConversationUpdate = false
                if staged, var final = commandFrame {
                    final.revision = base &+ 1; final.changedMessageIDs = ids
                    final.realtimeSignposts.forEach { $0.staged() }
                    commandFrame = final; pendingFrames.append(final)
                }
            }
            operation()
        }
    }
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
    private var activeFrame: ConversationMemoryFrame { commandFrame ?? memoryCell.current }
    private let committedSnapshots = CurrentValueSubject<MemorySnapshot, Never>(
        MemorySnapshot(revision: 0, conversations: [], alertingUnreadTotal: 0, metadataRevision: 0) // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
    )
    public var memorySnapshot: MemorySnapshot { activeFrame.metadata }
    public private(set) lazy var memoryUpdates = committedSnapshots.eraseToAnyPublisher() // WDT_IOS1_MEMORY_PUBLISHER_SETTER_FIX_20261110
    public private(set) lazy var conversationUpdates: AnyPublisher<[Conversation], Never> = memoryUpdates // WDT_IOS1_MEMORY_PUBLISHER_SETTER_FIX_20261110
        .removeDuplicates { $0.metadataRevision == $1.metadataRevision }
        .map(\.conversations).eraseToAnyPublisher() // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
    private let committedChanges = PassthroughSubject<MemoryCommit, Never>()
    public private(set) lazy var memoryCommits = committedChanges.eraseToAnyPublisher() // WDT_IOS1_MEMORY_PUBLISHER_SETTER_FIX_20261110
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
#if DEBUG
    /// Read during memoryCommits delivery to identify the frame that was installed.
    public var installedIncrementalRealtimeUpdate: (revision: UInt64, conversationID: String)? {
        let frame = memoryCell.current
        guard let id = frame.incrementalRealtimeConversationID else { return nil }
        return (frame.revision, id)
    }
#endif
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END

    // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
    /// Execute synchronously against the latest queued state, retaining ordinary
    /// return values and read-after-write semantics inside the command. Notification
    /// callbacks keep reading their own published frame until all its streams finish.
    public func performMemoryCommand<Result>(presentationPageID: UUID? = nil, realtimeSignposts: [MessageMemoryDiagnostic] = [], _ operation: () throws -> Result) rethrows -> Result {
        if commandFrame != nil {
            commandFrame?.realtimeSignposts += realtimeSignposts
            return try operation()
        }
        var initial = pendingFrames.last ?? memoryCell.current
        initial.realtimeSignposts = realtimeSignposts
        initial.presentationPageID = presentationPageID
        commandFrame = initial
        defer {
            let flows = commandFrame?.realtimeSignposts ?? []
            commandFrame = nil
            drainMemoryNotifications()
            flows.forEach { $0.commandFinished() }
        }
        return try operation()
    }

    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    private func stageMemoryFrame(_ frame: ConversationMemoryFrame, singleChange: (id: String, moved: Bool)? = nil) {
        var frame = frame // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
#if DEBUG
        // A later stage replaces this frame. It must supply its own evidence.
        frame.incrementalRealtimeConversationID = singleChange?.id
#endif
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
        frame.singleConversationChange = singleChange
        if let singleChange {
            frame.derivationClock = ConversationDerivationClock.advancingSingle(previous: activeFrame, next: frame,
                id: singleChange.id, moved: singleChange.moved, rtcAuthorities: rtcAuthorities)
        } else {
            frame.derivationClock = ConversationDerivationClock.advancing(previous: activeFrame, next: frame,
                rtcAuthorities: rtcAuthorities)
        }
        // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
        // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
        #if DEBUG
        assert(frame.alertingUnreadTotal == ConversationUnreadBadgeProjection.total(frame.conversations),
               "Incremental unread contribution diverged from its authoritative projection")
        #endif
        // WDT_IOS1_INCREMENTAL_UNREAD_20261110_END
        commandFrame = frame
        if realtimeAtomicBase != nil {
            realtimeAtomicStaged = true; realtimeAtomicChangedIDs.formUnion(frame.changedMessageIDs)
        } else {
            frame.realtimeSignposts.forEach { $0.staged() }
            pendingFrames.append(frame)
        }
        // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
    }

    private func drainMemoryNotifications() {
        guard !isPublishingMemory else { return }
        isPublishingMemory = true
        defer { isPublishingMemory = false }
        while !pendingFrames.isEmpty {
            var next = pendingFrames.removeFirst() // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
            let previous = memoryCell.current
            var messageChanges: [String: MessageWindowChange] = [:]
            let ids = next.changedMessageIDs
            for id in ids {
                let old = previous.messages(for: id)
                let new = next.messages(for: id)
                if old != new { messageChanges[id] = MessageWindowChange(previous: old, current: new) }
            }
            // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
            let metadataChanged: Bool
            let orderChanged: Bool
            let rowIDs: Set<String>
            if let single = next.singleConversationChange {
                rowIDs = previous.conversation(id: single.id) == next.conversation(id: single.id) ? [] : [single.id]
                orderChanged = single.moved
                metadataChanged = orderChanged || !rowIDs.isEmpty
            } else {
                metadataChanged = previous.conversations != next.conversations
                orderChanged = previous.binding != next.binding
                    || (metadataChanged && !previous.conversations.elementsEqual(next.conversations, by: { $0.id == $1.id }))
                rowIDs = metadataChanged ? Set(previous.firstIndexByID.keys).union(next.firstIndexByID.keys).filter {
                    previous.conversation(id: $0) != next.conversation(id: $0)
                } : []
            }
            // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_BEGIN
            let requiresFullListProjection = (previous.hasDuplicateConversationIDs || next.hasDuplicateConversationIDs)
                && (metadataChanged || orderChanged || !messageChanges.isEmpty)
            // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_END
            next.metadataRevision = metadataChanged ? previous.metadataRevision &+ 1 : previous.metadataRevision
            memoryCell.current = next
            let signposts = MessageMemoryDiagnostic.installed(next, changes: messageChanges)
            committedSnapshots.send(next.metadata)
            if metadataChanged { metadataWillChanges.send() }
            committedChanges.send(MemoryCommit(previous: previous.metadata, current: next.metadata,
                                                messageChanges: messageChanges, presentationPageID: next.presentationPageID,
                                                scopeHash: next.scopeHash, bindingID: next.binding, realtimeSignposts: signposts,
                                                changedConversationRowIDs: rowIDs, conversationOrderChanged: orderChanged,
                                                requiresFullConversationListProjection: requiresFullListProjection)) // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112
            publish(previous: previous, current: next, changedIDs: Set(messageChanges.keys), changedRowIDs: rowIDs)
            // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
            next.realtimeSignposts.forEach { $0.publicationFinished() }
        }
    }
    // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END

    public var conversations: [Conversation] { activeFrame.conversations }
    public var alertingUnreadTotal: Int { activeFrame.alertingUnreadTotal }

    public func conversationMessageSnapshot(id: String) -> ConversationMessageSnapshot? {
        conversation(id: id).map {
            ConversationMessageSnapshot(conversation: $0, messages: activeFrame.messages(for: id))
        }
    }
    public func conversationMessageSnapshot(at index: Int) -> ConversationMessageSnapshot {
        let row = conversations[index]
        return ConversationMessageSnapshot(conversation: row, messages: activeFrame.messages(for: row.id))
    }
    /// Explicit values for batch reducers / persistence; never a published list.
    public func conversationMessageSnapshots() -> [ConversationMessageSnapshot] {
        conversations.map {
            ConversationMessageSnapshot(conversation: $0, messages: activeFrame.messages(for: $0.id))
        }
    }
    // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
    public func commitConversationSnapshot(_ snapshot: ConversationMessageSnapshot, at index: Int) {
        commitConversationChanges([index: snapshot])
    }

    public func commitConversationChanges(_ changes: [Int: ConversationMessageSnapshot]) {
        performMemoryCommand {
            guard activeFrame.scope != nil, !changes.isEmpty else { return }
            var next = activeFrame
            next.revision += 1
            next.replaceMessageSnapshots(changes)
            stageMemoryFrame(next)
        }
    }

    public func commitConversationChanges(in values: [ConversationMessageSnapshot], at indices: Set<Int>, preparedAt: UInt64) {
        performMemoryCommand {
            guard activeFrame.scope != nil, !indices.isEmpty else { return }
            let update = activeFrame.unreadUpdate(for: values, at: indices, preparedAt: preparedAt)
            // Keep the existing full-batch window/order semantics, including
            // repeated IDs; only unread maintenance visits the changed rows.
            commitConversationSnapshots(values, unreadUpdate: update)
        }
    }
    // WDT_IOS1_INCREMENTAL_UNREAD_20261110_END
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
    /// Handles a same-ID patch inside an admitted single-message realtime command.
    /// A false result leaves the frame untouched for the full reconciliation path.
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    func commitExistingRealtimeConversation(_ value: ConversationMessageSnapshot, changed: Bool) -> Bool {
        guard allowsSingleRealtimeConversationUpdate, !realtimeAtomicStaged, !isPublishingMemory,
              let scopeHash = activeFrame.scopeHash, activeFrame.hasCanonicalOrder,
              let index = activeFrame.firstIndexByID[value.id] else { return false }
        let order = ConversationListOrder(row: value.conversation, messages: value.messages)
        guard order.timestamp.isFinite else { return false }
        var next = activeFrame
        let destination = next.destination(for: order, replacing: index)
        let old = next.conversations[index]
        let moved = index != destination
        guard changed || old != value.conversation || moved else { return true }

        next.replaceOrderedConversation(value.conversation, at: index, movingTo: destination)
        let key = ScopedMessageWindowKey(scopeHash: scopeHash, conversationID: value.id)
        if next.windows[key] != value.messages { next.windows[key] = value.messages }
        next.alertingUnreadTotal = next.unreadTotal(removing: [old], adding: [value.conversation])
        next.changedMessageIDs = [value.id]
        next.revision += 1
        stageMemoryFrame(next, singleChange: (value.id, moved))
        return true
    }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END

    public func commitConversationSnapshots(_ input: [ConversationMessageSnapshot], unreadUpdate: ConversationUnreadUpdate = .rebuild) {
        performMemoryCommand {
            let values = activeFrame.scope == nil ? [] : input
            var next = activeFrame
            next.revision += 1
            next.changedMessageIDs = Set(next.windows.keys.map(\.conversationID)).union(values.map(\.id))
            // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
            next.windows = [:]
            if let scopeHash = next.scopeHash {
                for value in values {
                    next.windows[ScopedMessageWindowKey(scopeHash: scopeHash, conversationID: value.id)] = value.messages
                }
            }
            next.replaceConversations(values.map(\.conversation))
            // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
            next.alertingUnreadTotal = activeFrame.scope == nil ? 0 : activeFrame.unreadTotal(for: next.conversations, update: unreadUpdate)
            stageMemoryFrame(next)
        }
    }
    public func bindMessageScope(_ scope: LocalMessageScope?, preservesMessages: Bool) {
        performMemoryCommand {
            guard !preservesMessages || activeFrame.scopeHash != scope?.scopeHash else { return }
            var next = activeFrame
            next.revision += 1
            next.changedMessageIDs = Set(next.windows.keys.map(\.conversationID))
            next.scope = scope
            next.scopeHash = scope?.scopeHash
            next.binding = UUID()
            // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
            next.windows = [:]
            next.replaceConversations([])
            // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
            next.alertingUnreadTotal = 0
            stageMemoryFrame(next)
        }
    }
    // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

    public struct Commit: Sendable {
        public let scope: LocalMessageScope?
        public let revision: UInt64
        public let changedConversationIDs: Set<String>
    }

    private struct ObserverKey: Hashable {
        let window: ScopedMessageWindowKey
        let binding: UUID
    }
    private var observers: [ObserverKey: ConversationMessages] = [:]
    private let changes = PassthroughSubject<Commit, Never>()
    public var commits: AnyPublisher<Commit, Never> { changes.eraseToAnyPublisher() }
    public var scope: LocalMessageScope? { memoryCell.current.scope }
    public var revision: UInt64 { memoryCell.current.revision }
    public var scopeHash: String? { memoryCell.current.scopeHash }
    public var bindingID: UUID { memoryCell.current.binding }


    public func messages(for conversationID: String) -> [ChatMessage] {
        memoryCell.current.messages(for: conversationID)
    }

    public func snapshot(for conversationID: String) -> ConversationMessages.Snapshot {
        ConversationMessages.Snapshot(scope: scope, conversationID: conversationID,
                                      revision: revision, messages: messages(for: conversationID))
    }

    public func conversationMessages(for conversationID: String) -> ConversationMessages? {
        guard let scope else { return nil }
        let key = ObserverKey(window: ScopedMessageWindowKey(scopeHash: memoryCell.current.scopeHash!, conversationID: conversationID), binding: memoryCell.current.binding)
        if let existing = observers[key] { return existing }
        let observedScope = scope
        let observedBinding = memoryCell.current.binding
        let observer = ConversationMessages(read: { [weak self] in // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
            guard let self, self.memoryCell.current.binding == observedBinding else {
                return ConversationMessages.Snapshot(scope: observedScope, conversationID: conversationID,
                                                      revision: self?.revision ?? 0, messages: [])
            }
            return self.snapshot(for: conversationID)
        }, readConversation: { [weak self] in
            guard let self, self.memoryCell.current.binding == observedBinding else { return nil }
            return self.memoryCell.current.conversation(id: conversationID)
        }) // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
        observers[key] = observer
        return observer
    }

    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    /// Exact-ID metadata subscription. It starts with the installed value,
    /// emits nil on removal/retirement, and never follows a new scope binding.
    public func conversationRowUpdates(id: String) -> AnyPublisher<Conversation?, Never> {
        Deferred { [weak self] in
            self?.conversationMessages(for: id)?.rowUpdates ?? Just(nil).eraseToAnyPublisher()
        }.eraseToAnyPublisher()
    }

    private func publish(previous: ConversationMemoryFrame, current: ConversationMemoryFrame,
                 changedIDs: Set<String>, changedRowIDs: Set<String>) {
        if previous.binding != current.binding {
            // Metadata callbacks can already have subscribed to the new binding.
            // Retire only old objects; retain observers born in this transaction.
            let retired = observers.filter { $0.key.binding != current.binding }.map(\.value)
            observers = observers.filter { $0.key.binding == current.binding }
            for observer in retired {
                observer.publish()
                observer.publishRow()
            }
        }
        if !changedIDs.isEmpty {
            changes.send(Commit(scope: current.scope, revision: current.revision,
                                changedConversationIDs: changedIDs))
        }
        guard let scopeHash = current.scopeHash else { return }
        for id in changedIDs {
            observers[ObserverKey(window: ScopedMessageWindowKey(scopeHash: scopeHash, conversationID: id), binding: current.binding)]?.publish()
        }
        for id in changedRowIDs {
            observers[ObserverKey(window: ScopedMessageWindowKey(scopeHash: scopeHash, conversationID: id), binding: current.binding)]?.publishRow()
        }
    }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
    private let metadataWillChanges = PassthroughSubject<Void, Never>()
    public var metadataWillChange: AnyPublisher<Void, Never> { metadataWillChanges.eraseToAnyPublisher() }
    private let rtcAuthorities: @Sendable ([ChatMessage]) -> [String: [RTCCallRecordAuthority]]
    public init(scope: LocalMessageScope?,
        rtcAuthorities: @escaping @Sendable ([ChatMessage]) -> [String: [RTCCallRecordAuthority]]) {
        self.memoryCell = ConversationMemoryCell(scope: scope)
        self.rtcAuthorities = rtcAuthorities
    }
    public var commandScope: LocalMessageScope? { activeFrame.scope }
    public func commandMessages(for conversationID: String) -> [ChatMessage] { activeFrame.messages(for: conversationID) }

    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    public func conversation(id: String) -> Conversation? { activeFrame.conversation(id: id) }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
}
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END

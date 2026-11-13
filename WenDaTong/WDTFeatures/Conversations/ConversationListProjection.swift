import SwiftUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import UIKit
import IM4Features
import IM4Stores

struct ConversationRowProjectionContext: Equatable {
    let viewer: IMUser
    let viewerIDs: Set<String>
    let tenant: String
    let mentionTarget: String
    let minute: Int
    let showsGroupCount: Bool
    let showsProcessingNotices: Bool
    let certificationRevision: Int
}

final class ConversationRowProjectionCache {
    private struct Entry {
        let source: ConversationMessageSnapshot
        let item: ConversationRenderItem
    }
    private var context: ConversationRowProjectionContext?
    private var entries: [String: Entry] = [:]

    func prepare(context: ConversationRowProjectionContext, activeIDs: Set<String>) {
        if self.context != context {
            entries.removeAll(keepingCapacity: true)
            self.context = context
        } else {
            entries = entries.filter { activeIDs.contains($0.key) }
        }
    }
    func value(for source: ConversationMessageSnapshot) -> ConversationRenderItem? {
        // Relative 'just now' summaries without an authoritative timestamp retain their existing clock semantics.
        guard !(source.sortTimestamp <= 0 && source.time == "刚刚"),
              let entry = entries[source.id], entry.source == source else { return nil }
        return entry.item
    }
    func store(_ item: ConversationRenderItem, source: ConversationMessageSnapshot) {
        entries[source.id] = Entry(source: source, item: item)
    }
    func matches(context: ConversationRowProjectionContext) -> Bool { self.context == context }
    func invalidate() {
        context = nil
        entries.removeAll(keepingCapacity: true)
    }
}

struct ConversationRenderItem: Identifiable, Equatable {
    let conversation: ConversationMessageSnapshot
    let displayTitle: String
    let unreadMention: MentionPreview?
    let sortScore: Double
    let requiresClockSort: Bool
    // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_MODEL - 修改开始：会话列表行轻量展示缓存
    let directCertificationPresentation: CertificationPresentation?
    // JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_ROW_PRESENTATION_MODEL - 修改结束：会话列表行轻量展示缓存
    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：行视图只消费可见字段，降低 SwiftUI diff 和渲染压力
    let rowModel: ConversationRowModel
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束

    var id: String { rowModel.id }
}

// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
typealias ConversationRowModel = IM4Features.ConversationRowInput
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

// WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_BEGIN
#if DEBUG
@MainActor
enum ConversationListProjectionDiagnostics {
    /// Nil row IDs indicate a full projection.
    static var didProject: ((UUID, Set<String>?) -> Void)?
    static var clock: ((UUID) -> Date?)? // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112
}
#endif

@MainActor
final class ConversationListMemoryChanges {
    enum Update: Equatable {
        case none, full, rows(Set<String>)
    }

    private(set) var binding: UUID?
    private(set) var projectedRevision: UInt64?
    private var observedRevision: UInt64?
    private var needsFullProjection = true
    private var changedIDs: Set<String> = []
    private var mentionCounts: [String: Int] = [:]

    func needsRebind(to store: ScopedMessageMemoryStore) -> Bool {
        binding != store.bindingID
    }

    func reset(binding: UUID) {
        self.binding = binding
        projectedRevision = nil
        observedRevision = nil
        needsFullProjection = true
        changedIDs.removeAll()
        mentionCounts.removeAll()
    }

    @discardableResult
    func receive(_ commit: ConversationStore.MemoryCommit, activeBinding: UUID) -> Bool {
        guard commit.bindingID == activeBinding else { return false }
        if binding != activeBinding { reset(binding: activeBinding) }
        guard observedRevision.map({ $0 < commit.current.revision }) ?? true else { return false }
        observedRevision = commit.current.revision
        // WDT_IOS1_CONVERSATION_LIST_CORE_INVALIDATION_20261112_BEGIN
        if commit.conversationOrderChanged || commit.requiresFullConversationListProjection { requireFull() }
        // WDT_IOS1_CONVERSATION_LIST_CORE_INVALIDATION_20261112_END
        changedIDs.formUnion(commit.changedConversationRowIDs)
        changedIDs.formUnion(commit.messageChanges.keys)
        return pending != .none
    }

    func requireFull() { needsFullProjection = true }

    var pending: Update {
        if needsFullProjection { return .full }
        return changedIDs.isEmpty ? .none : .rows(changedIDs)
    }

    func didProject(binding: UUID, revision: UInt64) {
        self.binding = binding
        projectedRevision = revision
        observedRevision = revision
        needsFullProjection = false
        changedIDs.removeAll(keepingCapacity: true)
    }

    func replaceMentions(_ counts: [String: Int]) {
        mentionCounts = counts
    }

    func updateMentions(id: String, count: Int) -> Int {
        count - (mentionCounts.updateValue(count, forKey: id) ?? 0)
    }

    // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_BEGIN
    func representativeRows(in physicalRows: [ConversationMessageSnapshot]) -> [ConversationMessageSnapshot] {
        // The installed frame and conversation open action both resolve the first row.
        var seen = Set<String>()
        return physicalRows.filter { seen.insert($0.id).inserted }
    }

    func row(id: String, in store: ScopedMessageMemoryStore) -> ConversationMessageSnapshot? {
        guard binding == store.bindingID else { return nil }
        return store.conversationMessageSnapshot(id: id)
    }
    // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_END
}
// WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_END

// WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_BEGIN
struct ConversationRenderSections {
    private(set) var ordered: [ConversationRenderItem]
    private(set) var tableItems: [ConversationListItemInput]
    private(set) var itemsByID: [String: ConversationRenderItem]
    private let indices: [String: Int]
    let requiresClockSort: Bool

    init(ordered: [ConversationRenderItem]) {
        self.ordered = ordered
        tableItems = ordered.map { ConversationListItemInput(rowModel: $0.rowModel, unreadMention: $0.unreadMention) }
        itemsByID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        indices = Dictionary(ordered.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        requiresClockSort = ordered.contains(where: \.requiresClockSort)
    }

    /// UIKit keeps its existing ordered table and diffable data source. Replace
    /// only the affected position when the row still belongs between its neighbors.
    mutating func replaceSamePosition(_ item: ConversationRenderItem) -> Bool {
        guard indices.count == ordered.count, let index = indices[item.id],
              ordered[index].rowModel.isPinned == item.rowModel.isPinned,
              (index == 0 || !Self.precedes(item, ordered[index - 1])),
              (index + 1 == ordered.count || !Self.precedes(ordered[index + 1], item)) else { return false }
        ordered[index] = item
        tableItems[index] = ConversationListItemInput(rowModel: item.rowModel, unreadMention: item.unreadMention)
        itemsByID[item.id] = item
        return true
    }

    static func precedes(_ lhs: ConversationRenderItem, _ rhs: ConversationRenderItem) -> Bool {
        if lhs.rowModel.isPinned != rhs.rowModel.isPinned { return lhs.rowModel.isPinned }
        if lhs.sortScore != rhs.sortScore { return lhs.sortScore > rhs.sortScore }
        if lhs.conversation.lastMsgSeq != rhs.conversation.lastMsgSeq {
            return lhs.conversation.lastMsgSeq > rhs.conversation.lastMsgSeq
        }
        return lhs.id < rhs.id
    }

    static let empty = ConversationRenderSections(ordered: [])
}
// WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_END
// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

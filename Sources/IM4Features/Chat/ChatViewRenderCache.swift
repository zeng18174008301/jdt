import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
public struct ChatTimelineContext: Equatable {
    public let conversationID: String
    // Include all five scope fields, even while an incomplete scope cannot bind a Store.
    public let scope: [String?]
    public let sessionGeneration: UInt64
    public let historyScope: String
    public let policy: ChatTimelinePolicy?
    public let isGroup: Bool
    public let isReadOnly: Bool
    public let canManageGroup: Bool
    public var showsMemberCounts = true
    public var readReceiptsEnabled = true

    public init(conversationID: String,
        scope: [String?],
        sessionGeneration: UInt64,
        historyScope: String,
        policy: ChatTimelinePolicy? = nil,
        isGroup: Bool,
        isReadOnly: Bool,
        canManageGroup: Bool,
        showsMemberCounts: Bool = true,
        readReceiptsEnabled: Bool = true) {
        self.conversationID = conversationID
        self.scope = scope
        self.sessionGeneration = sessionGeneration
        self.historyScope = historyScope
        self.policy = policy
        self.isGroup = isGroup
        self.isReadOnly = isReadOnly
        self.canManageGroup = canManageGroup
        self.showsMemberCounts = showsMemberCounts
        self.readReceiptsEnabled = readReceiptsEnabled
    }
}

@MainActor
final public class ChatTimelineViewModel: ObservableObject {
    private(set) public var rows: [MessageRowModel] = []
    private(set) public var source: [ChatMessage] = []
    private(set) public var context: ChatTimelineContext?
    private(set) public var version = 0
    private(set) var rebuiltIDs: Set<String> = []
    private var generation = UUID()
    private var rowVersion: UInt64 = 0
    private var unreadID: String?
    private var unreadCount = 0
    private var expandedVersion = -1
    private var expandedUnreadID: String?
    private var expandedUnreadCount = -1
    private var expandedItems: [ChatMessageTimelineItem] = []

    @discardableResult
    public func update(
        messages: [ChatMessage], context nextContext: ChatTimelineContext,
        unreadID nextUnreadID: String?, unreadCount nextUnreadCount: Int,
        force: Bool = false, makeRow: (Int) -> MessageRowModel
    ) -> Bool {
        let reset = context != nextContext || force
        guard reset || !chatMessagesShareStorage(source, messages)
                || unreadID != nextUnreadID || unreadCount != nextUnreadCount else {
            rebuiltIDs = []
            return false
        }
        let oldByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldIndices = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let newIndices = Dictionary(messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var invalid = Set<String>()
        func invalidateNeighbors(_ index: Int, ids: [String]) {
            for neighbor in (index - 1)...(index + 1) where ids.indices.contains(neighbor) {
                invalid.insert(ids[neighbor])
            }
        }
        let oldIDs = rows.map(\.id)
        let newIDs = messages.map(\.id)
        if reset {
            generation = UUID()
            invalid = Set(newIDs)
        } else {
            for (index, message) in messages.enumerated() {
                let previous = oldByID[message.id]
                let oldIndex = oldIndices[message.id]
                let oldBefore = oldIndex.flatMap { $0 > 0 ? oldIDs[$0 - 1] : nil }
                let newBefore = index > 0 ? newIDs[index - 1] : nil
                let oldAfter = oldIndex.flatMap { $0 + 1 < oldIDs.count ? oldIDs[$0 + 1] : nil }
                let newAfter = index + 1 < newIDs.count ? newIDs[index + 1] : nil
                if previous?.message != message || oldBefore != newBefore || oldAfter != newAfter {
                    invalidateNeighbors(index, ids: newIDs)
                    if let oldIndex { invalidateNeighbors(oldIndex, ids: oldIDs) }
                }
            }
            for (index, id) in oldIDs.enumerated() where newIndices[id] == nil {
                invalidateNeighbors(index, ids: oldIDs)
            }
            if unreadID != nextUnreadID || unreadCount != nextUnreadCount {
                for id in [unreadID, nextUnreadID].compactMap({ $0 }) {
                    if let index = oldIndices[id] { invalidateNeighbors(index, ids: oldIDs) }
                    if let index = newIndices[id] { invalidateNeighbors(index, ids: newIDs) }
                }
            }
        }
        let nextRows = messages.indices.map { index -> MessageRowModel in
            let id = messages[index].id
            if !invalid.contains(id), var reused = oldByID[id] {
                reused.index = index
                return reused
            }
            var row = makeRow(index)
            rowVersion &+= 1
            row.renderVersion = rowVersion
            row.generation = generation
            return row
        }
        let changed = reset || rows != nextRows || unreadID != nextUnreadID || unreadCount != nextUnreadCount
        rows = nextRows
        source = messages
        context = nextContext
        unreadID = nextUnreadID
        unreadCount = nextUnreadCount
        rebuiltIDs = invalid.intersection(newIDs)
        if changed { version &+= 1 }
        return changed
    }

    public func snapshot() -> ChatMessageRenderRowsSnapshot {
        .init(rows: rows, conversationID: context?.conversationID ?? "", version: version, fingerprint: version)
    }

    public func items(snapshot: ChatMessageRenderRowsSnapshot, unreadID: String?, unreadCount: Int, historyAnchorID: (String) -> String, unreadMarkerID: String) -> [ChatMessageTimelineItem] {
        // Boundary changes pass through update, so rows on both sides get fresh values.
        guard expandedVersion != snapshot.version || expandedUnreadID != unreadID || expandedUnreadCount != unreadCount else { return expandedItems }
        var items: [ChatMessageTimelineItem] = []
        items.reserveCapacity(snapshot.rows.count * 2 + 4)
        for row in snapshot.rows {
            if let text = row.timeSeparatorText {
                items.append(.init(id: "time-separator-\(row.id)", row: row, kind: .timeSeparator(text)))
            }
            if row.id == unreadID {
                items.append(.init(id: unreadMarkerID, row: row, kind: .unreadDivider(unreadCount)))
            }
            items.append(.init(id: historyAnchorID(row.id), row: row, kind: .historyAnchor))
            items.append(.init(id: row.id, row: row, kind: .message))
        }
        expandedItems = items
        expandedVersion = snapshot.version
        expandedUnreadID = unreadID
        expandedUnreadCount = unreadCount
        return items
    }

    public func reset() {
        rows = []; source = []; context = nil
        unreadID = nil; unreadCount = 0; rebuiltIDs = []
        expandedItems = []; expandedVersion = -1
        generation = UUID(); version &+= 1
    }

    public init() {}
}


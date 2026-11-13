// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import IM4Domain

struct ConversationDerivationClock: Sendable {
    var nonce: UInt64 = 0
    var windows: [String: UInt64] = [:]
    var rtcCalls: [String: UInt64] = [:]
    var rtcKeysByWindow: [String: Set<String>] = [:]

    @MainActor
    static func advancing(previous: ConversationMemoryFrame, next: ConversationMemoryFrame,
        rtcAuthorities: @Sendable ([ChatMessage]) -> [String: [RTCCallRecordAuthority]]) -> Self {
        var result = previous.binding == next.binding ? previous.derivationClock : Self()
        let oldRows = Dictionary(grouping: previous.conversations, by: \.id)
        let newRows = Dictionary(grouping: next.conversations, by: \.id)
        let ids = Set(oldRows.keys).union(newRows.keys).union(next.changedMessageIDs)
        var changedCalls: Set<String> = []
        for id in ids {
            let old = previous.messages(for: id), new = next.messages(for: id)
            let changedMessages = old != new
            if oldRows[id] != newRows[id] || changedMessages {
                result.nonce &+= 1
                if newRows[id] == nil { result.windows[id] = nil }
                else { result.windows[id] = result.nonce }
            }
            if changedMessages || previous.binding != next.binding {
                let before = rtcAuthorities(old), after = rtcAuthorities(new)
                for key in Set(before.keys).union(after.keys) where before[key] != after[key] { changedCalls.insert(key) }
                if after.isEmpty { result.rtcKeysByWindow[id] = nil }
                else { result.rtcKeysByWindow[id] = Set(after.keys) }
            }
        }
        let beforeOrder = orderedRTCWindows(previous.conversations, keys: previous.derivationClock.rtcKeysByWindow)
        let afterOrder = orderedRTCWindows(next.conversations, keys: result.rtcKeysByWindow)
        for key in Set(beforeOrder.keys).union(afterOrder.keys) where beforeOrder[key] != afterOrder[key] { changedCalls.insert(key) }
        for key in changedCalls.sorted() {
            if afterOrder[key] == nil { result.rtcCalls[key] = nil }
            else { result.nonce &+= 1; result.rtcCalls[key] = result.nonce }
        }
        return result
    }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    @MainActor
    static func advancingSingle(previous: ConversationMemoryFrame, next: ConversationMemoryFrame,
        id: String, moved: Bool, rtcAuthorities: @Sendable ([ChatMessage]) -> [String: [RTCCallRecordAuthority]]) -> Self {
        let old = previous.messages(for: id), new = next.messages(for: id)
        let changedMessages = old != new
        let clock = previous.derivationClock
        // A changed RTC payload or a moved RTC-bearing window may change the
        // ordered cross-window authority. Keep the existing global derivation.
        if (moved && clock.rtcKeysByWindow[id] != nil)
            || (changedMessages && rtcAuthorities(old) != rtcAuthorities(new)) {
            return advancing(previous: previous, next: next, rtcAuthorities: rtcAuthorities)
        }
        guard changedMessages || previous.conversation(id: id) != next.conversation(id: id) else { return clock }
        var result = clock
        result.nonce &+= 1
        result.windows[id] = result.nonce
        return result
    }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END

    private static func orderedRTCWindows(_ rows: [Conversation], keys: [String: Set<String>]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for row in rows { for key in keys[row.id] ?? [] { result[key, default: []].append(row.id) } }
        return result
    }
}

public struct RealtimeDerivationStamp: Sendable {
    private let binding: UUID
    private let clock: ConversationDerivationClock
    init(binding: UUID, clock: ConversationDerivationClock) { self.binding = binding; self.clock = clock }
    public func hasRTCKeys(in conversationID: String, matching keys: Set<String>) -> Bool {
        !(clock.rtcKeysByWindow[conversationID] ?? []).isDisjoint(with: keys)
    }
    public func matches(_ current: Self, targets: Set<String>, rtcCalls: Set<String>) -> Bool {
        binding == current.binding
            && targets.allSatisfy { clock.windows[$0] == current.clock.windows[$0] }
            && rtcCalls.allSatisfy { clock.rtcCalls[$0] == current.clock.rtcCalls[$0] }
    }
}
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END

import XCTest
import Combine
@testable import WenDaTong
@testable import IM4Stores

// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
extension DomainStoreTests {
    func testMemoryModuleActualAppKeepsOneStoreAndOpaqueWindowABA() throws {
        let context = makeAuthenticatedAPIContext(accountID: "module-" + UUID().uuidString, imUID: "module-actor")
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            apiContextOverride: context)
        let owner = state.conversationStore
        let physical: IM4Stores.ScopedMessageMemoryStore = owner.messageMemoryStore
        XCTAssertTrue(String(reflecting: type(of: physical)).hasPrefix("IM4Stores."))
        XCTAssertNotNil(physical.scope, "normal App constructor binds the original scope")
        var first = makeConversation(id: "module-first", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.messages = [makeMessage(id: "module-m1", seq: 1)]
        var second = makeConversation(id: "module-second", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.messages = [makeMessage(id: "module-m2", seq: 1)]
        owner.commitConversationSnapshots([first, second])
        let window = try XCTUnwrap(physical.conversationMessages(for: first.id))
        XCTAssertTrue(String(reflecting: type(of: window)).hasPrefix("IM4Stores."))
        let original = owner.realtimeDerivationStamp
        var edited = first
        edited.messages[0].attachmentTransferProgress = 0.4
        owner.commitConversationSnapshot(edited, at: 0)
        XCTAssertFalse(original.matches(owner.realtimeDerivationStamp, targets: [first.id], rtcCalls: []))
        owner.commitConversationSnapshot(first, at: 0)
        XCTAssertFalse(original.matches(owner.realtimeDerivationStamp, targets: [first.id], rtcCalls: []), "same-value ABA remains stale")
        let unchangedWindow = owner.realtimeDerivationStamp
        second.messages[0].attachmentTransferProgress = 0.7
        owner.commitConversationSnapshot(second, at: 1)
        XCTAssertTrue(unchangedWindow.matches(owner.realtimeDerivationStamp, targets: [first.id], rtcCalls: []), "other window does not invalidate the target")
        XCTAssertTrue(physical === state.conversationStore.messageMemoryStore)
        XCTAssertTrue(window === physical.conversationMessages(for: first.id))
        XCTAssertEqual(window.messages, owner.conversationMessageSnapshot(id: first.id)?.messages)
        XCTAssertEqual(physical.messages(for: second.id), owner.conversationMessageSnapshot(id: second.id)?.messages)
        XCTAssertEqual(physical.memorySnapshot.revision, owner.memorySnapshot.revision)
    }

    func testMemoryModulePreservesAppNotificationPhaseAndPublishedOwner() throws {
        let owner = ConversationStore(scope: TestMessageMemoryScope.value)
        var row = makeConversation(id: "module-order", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.hasUnreadReaction = false; row.unreadReactionCount = 0
        row.messages = [makeMessage(id: "module-base", seq: 1)]
        owner.commitConversationSnapshots([row])
        let physical = owner.messageMemoryStore
        let window = try XCTUnwrap(physical.conversationMessages(for: row.id))
        var events: [String] = []
        let subscriptions: [AnyCancellable] = [
            owner.memoryUpdates.dropFirst().sink { frame in
                events.append("memory")
                XCTAssertEqual(physical.revision, frame.revision)
                XCTAssertEqual(window.messages, owner.conversationMessageSnapshot(id: row.id)?.messages)
            },
            owner.objectWillChange.sink { events.append("object") },
            owner.memoryCommits.sink { commit in
                events.append("commit")
                XCTAssertEqual(commit.current.revision, physical.revision)
                XCTAssertEqual(commit.messageChanges[row.id]?.current, window.messages)
            },
            physical.commits.sink { _ in events.append("messages") },
            window.updates.sink { _ in events.append("window") }
        ]
        defer { withExtendedLifetime(subscriptions) {} }
        row.unread = 2
        row.messages.append(makeMessage(id: "module-next", seq: 2))
        owner.commitConversationSnapshot(row, at: 0)
        XCTAssertEqual(events, ["memory", "object", "commit", "messages", "window"])
        XCTAssertEqual(owner.alertingUnreadTotal, 2)
        events = []
        var history: [Set<String>] = []
        let published = owner.$historyLoadingIDs.dropFirst().sink { history.append($0) }
        defer { published.cancel() }
        owner.historyLoadingIDs = [row.id]
        XCTAssertEqual(events, ["object"], "original App Published owner still emits once")
        XCTAssertEqual(history, [[row.id]])
        XCTAssertTrue(physical === owner.messageMemoryStore)
    }
}
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END

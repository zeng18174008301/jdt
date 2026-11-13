import Combine // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import XCTest
import UIKit
import SwiftUI // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110
@testable import WenDaTong

// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
extension DomainStoreTests {
    func testMessageOnlyCommitPublishesOwnWindowWithoutMetadataOrOtherConversationEvents() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.messages = [makeMessage(id: "m1", seq: 1)]
        var second = first
        second.conversation = makeConversation(id: "second", unread: 0, lastMsgSeq: 1, lastReadSeq: 1).conversation
        store.commitConversationSnapshots([first, second])
        let own = try XCTUnwrap(store.messageMemoryStore.conversationMessages(for: "first"))
        let other = try XCTUnwrap(store.messageMemoryStore.conversationMessages(for: "second"))
        let old = own.snapshot
        let revision = store.memorySnapshot.revision
        var metadataEvents = 0, objectEvents = 0, ownEvents = 0, otherEvents = 0
        var rowEvents = 0 // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
        let subscriptions: [AnyCancellable] = [
            store.messageMemoryStore.conversationRowUpdates(id: "first").dropFirst().sink { _ in rowEvents += 1 },
            store.conversationUpdates.dropFirst().sink { _ in metadataEvents += 1 },
            store.objectWillChange.sink { objectEvents += 1 },
            own.updates.sink { frame in
                ownEvents += 1
                XCTAssertEqual(frame.revision, store.memorySnapshot.revision)
                XCTAssertEqual(frame.messages, store.conversationMessageSnapshot(id: "first")?.messages)
                XCTAssertEqual(store.messageMemoryStore.revision, frame.revision)
            },
            other.updates.sink { _ in otherEvents += 1 }
        ]
        defer { withExtendedLifetime(subscriptions) {} }
        XCTAssertNotNil(store.updateAttachmentProgress(0.4, messageID: "m1", conversationID: "first"))
        XCTAssertEqual(store.memorySnapshot.revision, revision + 1)
        XCTAssertEqual(metadataEvents, 0)
        XCTAssertEqual(objectEvents, 0)
        XCTAssertEqual(ownEvents, 1)
        XCTAssertEqual(otherEvents, 0)
        XCTAssertEqual(rowEvents, 0) // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
        XCTAssertNil(old.messages[0].attachmentTransferProgress)
        XCTAssertEqual(own.messages[0].attachmentTransferProgress, 0.4)
    }

    func testFullScopeAndLoginBindingIsolateRetainedMessageObservers() throws {
        let original = TestMessageMemoryScope.value
        let variants = try [
            LocalMessageScope(accountID: "other", tenantID: original.tenantID, appID: original.appID, actorID: original.actorID, deviceID: original.deviceID),
            LocalMessageScope(accountID: original.accountID, tenantID: "other", appID: original.appID, actorID: original.actorID, deviceID: original.deviceID),
            LocalMessageScope(accountID: original.accountID, tenantID: original.tenantID, appID: "other", actorID: original.actorID, deviceID: original.deviceID),
            LocalMessageScope(accountID: original.accountID, tenantID: original.tenantID, appID: original.appID, actorID: "other", deviceID: original.deviceID),
            LocalMessageScope(accountID: original.accountID, tenantID: original.tenantID, appID: original.appID, actorID: original.actorID, deviceID: "other"),
            original
        ]
        for scope in variants {
            let store = ConversationStore(scope: original)
            var row = makeConversation(id: "same", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
            row.messages = [makeMessage(id: "old", seq: 1)]
            store.commitConversationSnapshots([row])
            let observer = try XCTUnwrap(store.messageMemoryStore.conversationMessages(for: row.id))
            // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
            var rowPresence: [Bool] = []
            let rows = store.messageMemoryStore.conversationRowUpdates(id: row.id).sink { rowPresence.append($0 != nil) }
            defer { rows.cancel() }
            // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END
            store.bindMessageScope(original, preservesMessages: true)
            XCTAssertTrue(observer === store.messageMemoryStore.conversationMessages(for: row.id))
            XCTAssertEqual(observer.messages.map(\.id), ["old"])
            store.bindMessageScope(scope, preservesMessages: false)
            XCTAssertTrue(observer.messages.isEmpty)
            XCTAssertTrue(store.conversations.isEmpty)
            row.messages = [makeMessage(id: "new", seq: 1)]
            store.commitConversationSnapshots([row])
            XCTAssertEqual(store.messageMemoryStore.messages(for: row.id).map(\.id), ["new"])
            XCTAssertTrue(observer.messages.isEmpty, "retired login must never read a later binding")
            XCTAssertEqual(rowPresence, [true, false]) // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
        }
        let unbound = ConversationStore()
        XCTAssertNil(unbound.messageMemoryStore.conversationMessages(for: "same"))
    }
}
// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
extension DomainStoreTests {
    func testPreparedSingleRealtimeCommitMatchesFullReorderUnreadAndObservers() async throws {
        let control = ConversationStore(scope: TestMessageMemoryScope.value)
        let incremental = ConversationStore(scope: TestMessageMemoryScope.value)
        func row(_ id: String, timestamp: TimeInterval, pinned: Bool = false) -> ConversationMessageSnapshot {
            var value = makeConversation(id: id, unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
            value.sortTimestamp = timestamp
            value.isPinned = pinned
            value.messages = [makeMessage(id: id + "-base", seq: 1)]
            return value
        }
        let target = row("target", timestamp: 20)
        let rows = [row("pinned", timestamp: 1, pinned: true), row("a", timestamp: 40),
                    row("b", timestamp: 40), target, row("tail", timestamp: 10)]
        control.commitConversationSnapshots(rows)
        incremental.commitConversationSnapshots(rows)
        let own = try XCTUnwrap(incremental.messageMemoryStore.conversationMessages(for: target.id))
        let peer = try XCTUnwrap(incremental.messageMemoryStore.conversationMessages(for: "a"))
        let original = own.snapshot
        let stamp = incremental.realtimeDerivationStamp
        var ownRevisions: [UInt64] = []
        var peerRevisions: [UInt64] = []
        var commits: [ConversationStore.MemoryCommit] = []
        let subscriptions = [
            own.updates.sink { ownRevisions.append($0.revision) },
            peer.updates.sink { peerRevisions.append($0.revision) },
            incremental.memoryCommits.sink { commit in
                XCTAssertEqual(incremental.memorySnapshot.revision, commit.current.revision)
                XCTAssertEqual(incremental.conversations, commit.current.conversations)
                XCTAssertEqual(own.snapshot.revision, commit.current.revision)
#if DEBUG
                let marker = incremental.messageMemoryStore.installedIncrementalRealtimeUpdate
                XCTAssertEqual(marker?.revision, commit.current.revision)
                XCTAssertEqual(marker?.conversationID, target.id)
#endif
                commits.append(commit)
            }
        ]
        defer { withExtendedLifetime(subscriptions) {} }

        var next = target
        next.sortTimestamp = 100
        next.unread += 1
        next.lastMsgSeq = 2
        next.messages.append(makeMessage(id: "target-new", seq: 2))
        let expectedOrders = [["pinned", "target", "a", "b", "tail"], ["pinned", "a", "b", "tail", "target"]]
        for (pass, order) in expectedOrders.enumerated() {
            if pass == 1 {
                next.sortTimestamp = 5
                next.isMuted = true
            }
            applyPreparedMemoryUpdate(next, in: control, previousID: target.id, allowsIncremental: false, changed: pass == 0)
            applyPreparedMemoryUpdate(next, in: incremental, previousID: target.id, allowsIncremental: true, changed: pass == 0)
#if DEBUG
            XCTAssertNil(control.messageMemoryStore.installedIncrementalRealtimeUpdate)
#endif
            XCTAssertEqual(incremental.conversationMessageSnapshots(), control.conversationMessageSnapshots())
            XCTAssertEqual(incremental.conversations.map(\.id), order)
            XCTAssertEqual(incremental.alertingUnreadTotal, control.alertingUnreadTotal)
            XCTAssertEqual(incremental.memorySnapshot.revision, control.memorySnapshot.revision)
        }
        applyPreparedMemoryUpdate(next, in: incremental, previousID: target.id, allowsIncremental: true, changed: false)
        XCTAssertEqual(commits.map(\.current.revision), [original.revision + 1, original.revision + 2])
        XCTAssertEqual(commits.map { Set($0.messageChanges.keys) }, [Set([target.id]), []])
        XCTAssertEqual(commits.map(\.changedConversationRowIDs), [[target.id], [target.id]]) // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112
        XCTAssertEqual(commits.map(\.conversationOrderChanged), [true, true])
        XCTAssertEqual(ownRevisions, [original.revision + 1])
        XCTAssertTrue(peerRevisions.isEmpty)
        XCTAssertEqual(own.messages.map(\.id), ["target-base", "target-new"])
        XCTAssertEqual(original.messages.map(\.id), ["target-base"])
        XCTAssertFalse(stamp.matches(incremental.realtimeDerivationStamp, targets: [target.id], rtcCalls: []))
        XCTAssertTrue(stamp.matches(incremental.realtimeDerivationStamp, targets: ["a"], rtcCalls: []))
    }

    func testPreparedSingleRealtimeCommitPreservesStructuralAndReentrantReconciliation() async throws {
        for allowsIncremental in [false, true] {
            let store = ConversationStore(scope: TestMessageMemoryScope.value)
            var target = makeConversation(id: "target", unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
            var peer = makeConversation(id: "peer", unread: 2, lastMsgSeq: 1, lastReadSeq: 0)
            var last = makeConversation(id: "last", unread: 3, lastMsgSeq: 1, lastReadSeq: 0)
            target.sortTimestamp = 20
            peer.sortTimestamp = 40
            last.sortTimestamp = 10
            target.messages = [makeMessage(id: "base", seq: 1)]
            peer.messages = [makeMessage(id: "peer-base", seq: 1)]
            var renamed = makeConversation(id: "replacement", unread: last.unread, lastMsgSeq: 1, lastReadSeq: 0)
            renamed.sortTimestamp = last.sortTimestamp
            // Legacy positional replacement can leave a window with no metadata row.
            last.messages = [makeMessage(id: "old-window", seq: 1)]
            store.commitConversationSnapshots([target, last, peer])
            store.commitConversationSnapshot(renamed, at: 1)
            XCTAssertEqual(store.messageMemoryStore.messages(for: last.id).map(\.id), ["old-window"])
            let start = store.memorySnapshot.revision
            var installed: [UInt64] = []
            let subscription = store.memoryCommits.sink { commit in
#if DEBUG
                XCTAssertNil(store.messageMemoryStore.installedIncrementalRealtimeUpdate)
#endif
                installed.append(commit.current.revision)
                if commit.current.revision == start + 1 {
                    XCTAssertEqual(Set(commit.messageChanges.keys), [target.id, last.id])
                    XCTAssertEqual(store.conversations.map(\.id), [peer.id, target.id, renamed.id])
                    var updatedPeer = peer
                    updatedPeer.sortTimestamp = 15
                    updatedPeer.messages.append(self.makeMessage(id: "peer-next", seq: 2))
                    self.applyPreparedMemoryUpdate(updatedPeer, in: store, previousID: peer.id,
                        allowsIncremental: allowsIncremental, changed: true)
                    XCTAssertEqual(store.memorySnapshot.revision, start + 1)
                    XCTAssertEqual(store.conversations.first?.id, peer.id)
                }
            }
            defer { subscription.cancel() }
            target.messages.append(makeMessage(id: "target-next", seq: 2))
            applyPreparedMemoryUpdate(target, in: store, previousID: target.id,
                allowsIncremental: allowsIncremental, changed: true)
            XCTAssertEqual(installed, [start + 1, start + 2])
            XCTAssertEqual(store.conversations.map(\.id), [target.id, peer.id, renamed.id])
            XCTAssertTrue(store.messageMemoryStore.messages(for: last.id).isEmpty)
            XCTAssertEqual(store.conversationMessageSnapshot(id: peer.id)?.messages.map(\.id), ["peer-base", "peer-next"])
        }
    }

    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    func testIndexedRowsKeepFirstDuplicateAndPublishDeletion() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "same", unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        first.title = "first"
        var duplicate = first
        duplicate.title = "second"
        store.commitConversationSnapshots([first, duplicate])
        var titles: [String?] = []
        var peerUpdates = 0
        let rows = store.messageMemoryStore.conversationRowUpdates(id: first.id).sink {
            XCTAssertEqual($0, store.conversation(id: first.id))
            titles.append($0?.title)
        }
        let peer = store.messageMemoryStore.conversationRowUpdates(id: "peer").dropFirst().sink { _ in peerUpdates += 1 }
        defer { rows.cancel(); peer.cancel() }
        var renamed = makeConversation(id: "renamed", unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        renamed.title = "first"
        store.commitConversationSnapshot(renamed, at: 0)
        XCTAssertEqual(store.conversation(id: "same")?.title, "second")
        XCTAssertEqual(store.conversation(id: "renamed")?.title, "first")
        XCTAssertNotNil(store.deleteConversation(conversationID: "same"))
        XCTAssertNil(store.conversation(id: "same"))
        XCTAssertEqual(titles, ["first", "second", nil])
        XCTAssertEqual(peerUpdates, 0)
    }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END

    private func applyPreparedMemoryUpdate(_ snapshot: ConversationMessageSnapshot, in store: ConversationStore,
        previousID: String?, allowsIncremental: Bool, changed: Bool) {
        let result = ConversationStore.AppliedRemoteMessagesConversationResult(conversation: snapshot,
            incomingRealtimeMessages: [], shouldPlayIncomingSound: false, shouldAutoRead: false)
        store.performRealtimeAtomicCommand(allowsSingleConversationUpdate: allowsIncremental) {
            _ = store.applyPreparedRealtimeConversation(result, previousID: previousID,
                channelID: snapshot.id, changed: changed)
        }
    }
}
// WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END

// WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
extension DomainStoreTests {
    func testReentrantMemoryCallbacksSerializeAllStreamsAndPreserveConsecutiveCommands() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var row = makeConversation(id: "c1", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.hasUnreadReaction = false
        row.unreadReactionCount = 0
        row.messages = [makeMessage(id: "m1", seq: 1)]
        store.commitConversationSnapshots([row])
        let start = store.memorySnapshot.revision
        let observer = try XCTUnwrap(store.messageMemoryStore.conversationMessages(for: row.id))
        var events: [String] = []
        var commits: [UInt64] = []
        var returnedIDs: [[String]] = []
        let subscriptions: [AnyCancellable] = [
            store.memoryUpdates.dropFirst().sink { frame in
                events.append("memory:\(frame.revision)")
                XCTAssertEqual(store.memorySnapshot.revision, frame.revision)
                XCTAssertEqual(store.messageMemoryStore.revision, frame.revision)
                if frame.revision == start + 1 {
                    let first = store.appendLocalOutgoingMessage(self.makeMessage(id: "local-a", seq: 0, status: .sending), to: row.id)
                    returnedIDs.append(first?.messages.map(\.id) ?? [])
                    let second = store.appendLocalOutgoingMessage(self.makeMessage(id: "local-b", seq: 0, status: .sending), to: row.id)
                    returnedIDs.append(second?.messages.map(\.id) ?? [])
                    XCTAssertEqual(store.memorySnapshot.revision, frame.revision)
                }
            },
            store.conversationUpdates.dropFirst().sink { _ in
                events.append("metadata:\(store.memorySnapshot.revision)")
            },
            store.memoryCommits.sink { commit in
                events.append("commit:\(commit.current.revision)")
                commits.append(commit.current.revision)
                XCTAssertEqual(store.memorySnapshot.revision, commit.current.revision)
                XCTAssertEqual(store.conversations, commit.current.conversations)
                XCTAssertEqual(observer.snapshot.revision, commit.current.revision)
            },
            observer.updates.sink { frame in
                events.append("messages:\(frame.revision)")
                XCTAssertEqual(store.memorySnapshot.revision, frame.revision)
            }
        ]
        defer { withExtendedLifetime(subscriptions) {} }
        XCTAssertTrue(store.applyLocalMessageEdit(messageID: "m1", conversationID: row.id, text: "edited"))
        XCTAssertEqual(commits, [start + 1, start + 2, start + 3])
        XCTAssertEqual(returnedIDs, [["m1", "local-a"], ["m1", "local-a", "local-b"]])
        XCTAssertEqual(observer.messages.map(\.id), ["m1", "local-a", "local-b"])
        for revision in (start + 1)...(start + 2) {
            let last = try XCTUnwrap(events.lastIndex { $0.hasSuffix(":\(revision)") })
            let next = try XCTUnwrap(events.firstIndex { $0.hasSuffix(":\(revision + 1)") })
            XCTAssertLessThan(last, next, events.joined(separator: ","))
        }
    }

    func testReentrantResetThenScopeClearCannotRefillOldWindow() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var row = makeConversation(id: "c1", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.messages = [makeMessage(id: "m1", seq: 1)]
        store.commitConversationSnapshots([row])
        let observer = try XCTUnwrap(store.messageMemoryStore.conversationMessages(for: row.id))
        let start = store.memorySnapshot.revision
        var revisions: [UInt64] = []
        var resetRan = false
        let memory = store.memoryUpdates.dropFirst().sink { frame in
            XCTAssertEqual(store.memorySnapshot.revision, frame.revision)
            if frame.revision == start + 1 {
                store.reset()
                store.bindMessageScope(nil, preservesMessages: false)
                XCTAssertNil(store.appendLocalOutgoingMessage(self.makeMessage(id: "obsolete", seq: 0), to: row.id))
                resetRan = true
            }
        }
        let commits = store.memoryCommits.sink { commit in
            revisions.append(commit.current.revision)
            XCTAssertEqual(store.memorySnapshot.revision, commit.current.revision)
            XCTAssertEqual(store.messageMemoryStore.revision, commit.current.revision)
        }
        defer { withExtendedLifetime([memory, commits]) {} }
        XCTAssertNotNil(store.updateAttachmentProgress(0.5, messageID: "m1", conversationID: row.id))
        XCTAssertTrue(resetRan)
        XCTAssertEqual(revisions, [start + 1, start + 2, start + 3])
        XCTAssertNil(store.messageMemoryStore.scope)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(observer.messages.isEmpty)
    }
}
// WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END

// WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
extension DomainStoreTests {
    func testScopedChatStreamsIgnoreOtherWindowsAndPublishAtomicMetadataAndMessagesOnce() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.messages = [makeMessage(id: "one", seq: 1)]
        var second = makeConversation(id: "second", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.messages = [makeMessage(id: "two", seq: 1)]
        store.commitConversationSnapshots([first, second])
        var values: [ConversationMessageSnapshot?] = [], commits: [UInt64] = []
        let snapshots = store.conversationMessageUpdates(id: first.id).dropFirst().sink { value in
            values.append(value)
            XCTAssertEqual(value?.conversation, store.conversation(id: first.id))
            XCTAssertEqual(value?.messages, store.messageMemoryStore.messages(for: first.id))
            XCTAssertEqual(store.memorySnapshot.revision, store.messageMemoryStore.revision)
        }
        let changes = store.conversationMemoryCommits(id: first.id).sink { commit in
            commits.append(commit.current.revision)
            XCTAssertEqual(commit.current.revision, store.memorySnapshot.revision)
            XCTAssertEqual(commit.scopeHash, TestMessageMemoryScope.value.scopeHash)
        }
        defer { snapshots.cancel(); changes.cancel() }
        XCTAssertNotNil(store.updateAttachmentProgress(0.2, messageID: "two", conversationID: second.id))
        XCTAssertTrue(values.isEmpty); XCTAssertTrue(commits.isEmpty)
        store.mutateStoredConversation(at: 0) { value in
            value.title = "updated metadata"
            value.messages[0].text = "updated window"
        }
        XCTAssertEqual(values.count, 1, "metadata and its window are one UI value")
        XCTAssertEqual(values[0]?.title, "updated metadata")
        XCTAssertEqual(values[0]?.messages[0].text, "updated window")
        XCTAssertNotNil(store.updateAttachmentProgress(0.4, messageID: "one", conversationID: first.id))
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[1]?.messages[0].attachmentTransferProgress, 0.4)
        XCTAssertEqual(commits.count, 2)
        XCTAssertLessThan(commits[0], commits[1])
    }

    func testScopedChatRebindRetainsNewObserverCreatedDuringMetadataDelivery() throws {
        let original = TestMessageMemoryScope.value
        let replacement = try LocalMessageScope(accountID: original.accountID, tenantID: "replacement",
            appID: original.appID, actorID: original.actorID, deviceID: original.deviceID)
        let store = ConversationStore(scope: original)
        var row = makeConversation(id: "same", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.messages = [makeMessage(id: "old", seq: 1)]
        store.commitConversationSnapshots([row])
        let old = try XCTUnwrap(store.messageMemoryStore.conversationMessages(for: row.id))
        var fresh: ConversationMessages?, freshUpdates: AnyCancellable?
        var freshFrames: [ConversationMessages.Snapshot] = []
        var values: [ConversationMessageSnapshot?] = []
        let valueUpdates = store.conversationMessageUpdates(id: row.id).sink { values.append($0) }
        let createDuringMetadata = store.memoryUpdates.dropFirst().sink { frame in
            guard store.messageMemoryStore.scopeHash == replacement.scopeHash, fresh == nil else { return }
            XCTAssertTrue(frame.conversations.isEmpty)
            fresh = store.messageMemoryStore.conversationMessages(for: row.id)
            freshUpdates = fresh?.updates.sink { freshFrames.append($0) }
        }
        defer { valueUpdates.cancel(); createDuringMetadata.cancel(); freshUpdates?.cancel() }
        store.bindMessageScope(replacement, preservesMessages: false)
        XCTAssertTrue(old.messages.isEmpty)
        let observer = try XCTUnwrap(fresh)
        XCTAssertTrue(observer === store.messageMemoryStore.conversationMessages(for: row.id))
        row.messages = [makeMessage(id: "new", seq: 1)]
        store.commitConversationSnapshots([row])
        XCTAssertEqual(freshFrames.last?.messages.map(\.id), ["new"])
        XCTAssertEqual(values.last??.messages.map(\.id), ["new"])
        let before = values.count
        store.bindMessageScope(replacement, preservesMessages: true)
        XCTAssertEqual(values.count, before)
        XCTAssertTrue(observer === store.messageMemoryStore.conversationMessages(for: row.id))
        store.bindMessageScope(original, preservesMessages: false)
        row.messages = [makeMessage(id: "returning-login", seq: 1)]
        store.commitConversationSnapshots([row])
        XCTAssertTrue(observer.messages.isEmpty); XCTAssertTrue(old.messages.isEmpty)
        XCTAssertEqual(values.last??.messages.map(\.id), ["returning-login"])
        store.bindMessageScope(nil, preservesMessages: false)
        XCTAssertNil(values.last!)
        XCTAssertTrue(store.messageMemoryStore.messages(for: row.id).isEmpty)
    }

    func testScopedChatDataStreamSurvivesSameScopeCredentialRotation() throws {
        let state = AppState(api: IMAPIClient(httpTransport: RTCWireOfflineHTTPTransport()),
            messageStore: RTCWireEmptyMessageStore(), protectedSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makeAuthenticatedAPIContext(accountID: UUID().uuidString))
        let store = state.conversationStore
        var row = makeConversation(id: "credential-window", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.messages = [makeMessage(id: "credential-message", seq: 1)]
        store.commitConversationSnapshots([row])
        let window = try XCTUnwrap(store.messageMemoryStore.conversationMessages(for: row.id))
        let binding = store.messageMemoryStore.bindingID
        var values: [ConversationMessageSnapshot?] = []
        let changes = store.conversationMessageUpdates(id: row.id).dropFirst().sink { values.append($0) }
        defer { changes.cancel() }
        state.apiContext.imToken = "ordinary-rotated-test-credential"
        XCTAssertEqual(store.messageMemoryStore.bindingID, binding)
        XCTAssertTrue(window === store.messageMemoryStore.conversationMessages(for: row.id))
        XCTAssertEqual(window.messages.map(\.id), ["credential-message"])
        XCTAssertNotNil(store.updateAttachmentProgress(0.3, messageID: "credential-message", conversationID: row.id))
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0]?.messages[0].attachmentTransferProgress, 0.3)
    }

    // Called inside aa's real mounted ChatView/UITextView test, before its input
    // baseline counters are captured. No stand-in view or reducer replaces Chat.
    func assertScopedChatRuntimeWiring(_ state: AppState, conversationID: String,
                                     editor: () -> UITextView?) async throws {
        let store = state.conversationStore
        let initialEditor = try XCTUnwrap(editor())
        var other = makeConversation(id: "unrelated-window", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        other.hasUnreadReaction = false; other.unreadReactionCount = 0
        other.messages = [makeMessage(id: "unrelated-message", seq: 1)]
        store.commitConversationSnapshots(store.conversationMessageSnapshots() + [other])
        try await Task.sleep(nanoseconds: 250_000_000)
        let beforeRows = ChatTimelineRenderDiagnostics.rowResolutions
        let beforeBodies = ChatTimelineRenderDiagnostics.bubbleBodies
        let beforeTimelines = ChatTimelineRenderDiagnostics.timelineBodies
        var metadataEvents = 0, presented: ChatMessage?
        let metadata = store.conversationUpdates.dropFirst().sink { _ in metadataEvents += 1 }
        let priorHook = ChatTimelineRenderDiagnostics.scopedBubbleBody
        ChatTimelineRenderDiagnostics.scopedBubbleBody = { id, message in
            if id == conversationID, message.id == "stable-ui" { presented = message }
        }
        defer { metadata.cancel(); ChatTimelineRenderDiagnostics.scopedBubbleBody = priorHook }
        XCTAssertTrue(store.applyMessageReaction(messageID: "unrelated-message", emoji: "ok", operatorUID: "reader", action: "add", currentUserIDs: []))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(ChatTimelineRenderDiagnostics.rowResolutions, beforeRows)
        XCTAssertEqual(ChatTimelineRenderDiagnostics.bubbleBodies, beforeBodies)
        XCTAssertEqual(ChatTimelineRenderDiagnostics.timelineBodies, beforeTimelines)
        XCTAssertNil(presented)
        XCTAssertTrue(store.applyMessageReaction(messageID: "stable-ui", emoji: "ok", operatorUID: "reader", action: "add", currentUserIDs: []))
        for _ in 0..<40 {
            if presented?.reactions.first?.count == 1 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(presented?.reactions.first?.count, 1, "actual MessageBubble consumed the message-only update")
        XCTAssertGreaterThan(ChatTimelineRenderDiagnostics.rowResolutions, beforeRows)
        XCTAssertEqual(metadataEvents, 0)
        XCTAssertTrue(editor() === initialEditor)
        try await Task.sleep(nanoseconds: 250_000_000)
    }
}
// WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END

// WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112: Mounted batch-forward tests live in BatchForwardStateTests.swift.

// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
extension DomainStoreTests {
    func testRealtimeFlowSignpostsJoinRawBatchAtomicCommitAndMountedProjection() async throws {
        try await assertFlowMountedProjection(scene: .active)
    }

    func testRealtimeFlowSignpostsLabelInactiveProjectionWithoutClaimingDisplay() async throws {
        try await assertFlowMountedProjection(scene: .inactive)
    }

    private func assertFlowMountedProjection(scene: ScenePhase) async throws {
        let first = flowWire(id: "private-flow-first", seq: 2)
        let second = flowWire(id: "private-flow-second", seq: 3)
        let batch = "{\"type\":\"batch\",\"payload\":{\"frames\":[" + first + "," + second + "]}}"
        let fixture = makeFlowFixture(frames: [batch])
        defer { fixture.state.setAuthenticated(false); fixture.client.disconnect(shouldReconnect: false); fixture.client.onEnvelope = nil }
        var events: [RealtimeMessageFlowSignpost.Event] = []
        var rendered: Set<String> = []
        RealtimeMessageFlowSignpost.sink = { events.append($0) }
        ChatTimelineRenderDiagnostics.reset(); ChatTimelineRenderDiagnostics.enabled = true
        ChatTimelineRenderDiagnostics.scopedBubbleBody = { id, message in
            if id == "flow-channel" { rendered.insert(message.id) }
        }
        let hosted = hostForSimulatorUI(NavigationView { AppFeatureComposition.chatRouting().makeChat("flow-channel") }
            .navigationViewStyle(.stack).appStateEnvironment(fixture.state).environment(\.scenePhase, scene),
            size: CGSize(width: 390, height: 760))
        defer { hosted.window.isHidden = true; RealtimeMessageFlowSignpost.sink = nil; ChatTimelineRenderDiagnostics.reset() }
        try await runFlowWire(fixture)
        for _ in 0..<100 {
            if events.filter({ [.projectionConsumed, .projectionInactive].contains($0.stage) }).count == 2,
               rendered.contains("private-flow-first"), rendered.contains("private-flow-second") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let arrivals = events.filter { $0.stage == .arrival }
        XCTAssertEqual(arrivals.count, 2); XCTAssertEqual(Set(arrivals.map(\.correlation)).count, 2)
        let installs = events.filter { $0.stage == .storeInstalled }
        XCTAssertEqual(installs.count, 2); XCTAssertEqual(Set(installs.compactMap(\.revision)).count, 1, "coalesced messages share the actual atomic frame")
        for arrival in arrivals {
            let chain = events.filter { $0.correlation == arrival.correlation }
            let commit = try XCTUnwrap(chain.first { $0.stage == .storeInstalled })
            let projection = try XCTUnwrap(chain.first { $0.stage == (scene == .active ? .projectionConsumed : .projectionInactive) })
            XCTAssertEqual(projection.revision, commit.revision)
            XCTAssertLessThan(try XCTUnwrap(chain.firstIndex { $0.stage == .storeInstalled }),
                              try XCTUnwrap(chain.firstIndex { $0.stage == projection.stage }))
            XCTAssertEqual(chain.filter { [.publicationObserved, .publicationUnobserved].contains($0.stage) }.count, 1)
        }
        XCTAssertTrue(rendered.contains("private-flow-first")); XCTAssertTrue(rendered.contains("private-flow-second"))
        let attachment = XCTAttachment(data: try JSONEncoder().encode(events), uniformTypeIdentifier: "public.json")
        attachment.name = "opaque-realtime-flow-events"; attachment.lifetime = .keepAlways; add(attachment)
        let metadata = String(data: try JSONEncoder().encode(events), encoding: .utf8) ?? ""
        for forbidden in ["private-flow-first", "private-flow-second", "flow-channel", "private-flow-body", "synthetic-im-token"] {
            XCTAssertFalse(metadata.contains(forbidden))
        }
    }

    func testRealtimeFlowSignpostsEndUnobservedAndClassifyTransportDuplicateAndRetirement() async throws {
        let wire = flowWire(id: "private-flow-duplicate", seq: 2)
        let fixture = makeFlowFixture(frames: [wire, wire])
        defer { fixture.state.setAuthenticated(false); fixture.client.disconnect(shouldReconnect: false); fixture.client.onEnvelope = nil }
        var events: [RealtimeMessageFlowSignpost.Event] = []
        RealtimeMessageFlowSignpost.sink = { events.append($0) }; defer { RealtimeMessageFlowSignpost.sink = nil }
        try await runFlowWire(fixture)
        XCTAssertEqual(events.filter { $0.stage == .storeInstalled }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == .publicationUnobserved }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == .transportDuplicate }.count, 1)
        XCTAssertFalse(events.contains { [.projectionConsumed, .projectionInactive].contains($0.stage) })
        fixture.client.handle(Data(flowWire(id: "stale-leg", seq: 3).utf8), generation: 0, legID: fixture.client.activeLegID)
        XCTAssertEqual(events.filter { $0.stage == .transportRetired }.count, 1)
        XCTAssertFalse(fixture.state.conversationStore.messageMemoryStore.messages(for: "flow-channel").contains { $0.id == "stale-leg" })
    }

    func testRealtimeFlowSignpostsTerminateAdmissionCancellationAndOldBinding() throws {
        let fixture = makeFlowFixture(frames: [])
        var events: [RealtimeMessageFlowSignpost.Event] = []
        RealtimeMessageFlowSignpost.sink = { events.append($0) }; defer { RealtimeMessageFlowSignpost.sink = nil; fixture.state.setAuthenticated(false) }
        fixture.state.setAuthenticated(false)
        fixture.state.handleRealtimeEnvelope(try flowEnvelope(id: "rejected", seq: 2))
        XCTAssertEqual(events.filter { $0.stage == .admissionRejected }.count, 1)
        fixture.state.setAuthenticated(true)
        fixture.state.handleRealtimeEnvelope(try flowEnvelope(id: "cancelled", seq: 2))
        fixture.state.realtimeIngestFlushTask?.cancel(); fixture.state.realtimeIngestFlushTask = nil
        fixture.state.clearPendingRealtimeMessages(reason: "testing")
        XCTAssertEqual(events.filter { $0.stage == .bufferCancelled }.count, 1)
        let beforeRetirement = events.count
        fixture.state.handleRealtimeEnvelope(try flowEnvelope(id: "old-binding", seq: 2))
        fixture.state.realtimeIngestFlushTask?.cancel(); fixture.state.realtimeIngestFlushTask = nil
        var next = fixture.state.apiContext; next.sessionEpoch = UUID().uuidString; fixture.state.apiContext = next
        fixture.state.flushPendingRealtimeMessagesForTesting()
        let retired = Array(events.dropFirst(beforeRetirement))
        let retiredID = try XCTUnwrap(retired.first { $0.stage == .arrival }?.correlation)
        XCTAssertTrue(retired.contains { $0.correlation == retiredID && [.bindingRetired, .bufferCancelled].contains($0.stage) })
        XCTAssertFalse(events.contains { $0.stage == .storeInstalled })
        XCTAssertFalse(fixture.state.conversationStore.messageMemoryStore.messages(for: "flow-channel").contains { $0.id == "old-binding" })
    }

    func testRealtimeFlowSignpostsUseActualQueuedReentrantFrameRatherThanMethodReturn() throws {
        let fixture = makeFlowFixture(frames: [])
        var events: [RealtimeMessageFlowSignpost.Event] = []
        RealtimeMessageFlowSignpost.sink = { events.append($0) }; defer { RealtimeMessageFlowSignpost.sink = nil; fixture.state.setAuthenticated(false) }
        var injected = false
        let callback = fixture.state.conversationStore.memoryUpdates.dropFirst().sink { _ in
            guard !injected else { return }; injected = true
            fixture.state.handleRealtimeEnvelope(try! self.flowEnvelope(id: "reentrant-second", seq: 3, type: "send_ack"))
            XCTAssertEqual(events.filter { $0.stage == .storeInstalled }.count, 1, "returning from apply cannot stand in for the queued frame install")
        }
        defer { callback.cancel() }
        fixture.state.handleRealtimeEnvelope(try flowEnvelope(id: "reentrant-first", seq: 2))
        fixture.state.flushPendingRealtimeMessagesForTesting()
        let installs = events.filter { $0.stage == .storeInstalled }
        XCTAssertEqual(installs.count, 2)
        XCTAssertNotEqual(installs.first?.correlation, installs.last?.correlation)
        XCTAssertLessThan(try XCTUnwrap(installs.first?.revision), try XCTUnwrap(installs.last?.revision))
        XCTAssertEqual(events.filter { $0.stage == .publicationUnobserved }.count, 2)
        XCTAssertEqual(Set(fixture.state.conversationStore.messageMemoryStore.messages(for: "flow-channel").map(\.id)), ["flow-base", "reentrant-first", "reentrant-second"])
    }

    func testRealtimeFlowSignpostsClassifyUnchangedMessageWithoutClaimingCommit() throws {
        let fixture = makeFlowFixture(frames: [])
        var events: [RealtimeMessageFlowSignpost.Event] = []
        RealtimeMessageFlowSignpost.sink = { events.append($0) }; defer { RealtimeMessageFlowSignpost.sink = nil; fixture.state.setAuthenticated(false) }
        let envelope = try flowEnvelope(id: "same-message", seq: 2)
        fixture.state.handleRealtimeEnvelope(envelope); fixture.state.flushPendingRealtimeMessagesForTesting()
        let before = events.count
        fixture.state.handleRealtimeEnvelope(envelope); fixture.state.flushPendingRealtimeMessagesForTesting()
        let replay = events.dropFirst(before)
        XCTAssertEqual(replay.filter { $0.stage == .arrival }.count, 1)
        XCTAssertEqual(replay.filter { $0.stage == .noMessageChange }.count, 1)
        XCTAssertFalse(replay.contains { $0.stage == .storeInstalled })
    }

    private func flowEnvelope(id: String, seq: Int64, type: String = "message") throws -> RealtimeEnvelope {
        try JSONDecoder().decode(RealtimeEnvelope.self, from: Data(flowWire(id: id, seq: seq, type: type).utf8))
    }
    private func flowWire(id: String, seq: Int64, type: String = "message") -> String {
        let message = remoteMessageJSON(id: id, channelID: "flow-channel", channelType: "group", seq: seq)
            .replacingOccurrences(of: "\"payload\": {}", with: "\"payload\": {\"text\":\"private-flow-body\"}, \"created_at\":\"2026-11-10T00:00:00Z\"")
        return "{\"type\":\"" + type + "\",\"payload\":{\"message\":" + message + "}}"
    }
    private func makeFlowFixture(frames: [String]) -> (state: AppState, client: RealtimeClient) {
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [.string(#"{"type":"connect_ack","request_id":"flow-ack","payload":{}}"#)]
            + frames.map { .string($0) } + [.string(#"{"type":"flow_barrier","payload":{}}"#)])
        let client = RealtimeClient(
            transport: FakeRealtimeWebSocketTransport(socket: socket),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
            requestIDProvider: { _ in "flow-ack" },
            networkMonitorFactory: nil,
            continuity: IMRuntimeWebSocketContinuity()
        )
        var context = makeAuthenticatedAPIContext(accountID: "flow-" + UUID().uuidString); context.deviceID = UUID().uuidString
        let state = AppState(api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])), realtimeClient: client,
                             voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
                             messageStore: SnapshotCache(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("flow-" + UUID().uuidString)),
                             apiContextOverride: context)
        state.setAuthenticated(true); state.suppressCurrentUserIdentityPersistence = true; state.setCurrentUser(makeUser(id: "uid-1"))
        var conversation = makeConversation(id: "flow-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.hasUnreadReaction = false; conversation.unreadReactionCount = 0
        conversation.messages = [makeMessage(id: "flow-base", senderId: "uid-1", seq: 1)]
        state.conversationStore.commitConversationSnapshots([conversation]); client.onConnected = nil
        return (state, client)
    }
    private func runFlowWire(_ fixture: (state: AppState, client: RealtimeClient)) async throws {
        let barrier = expectation(description: "actual batch dispatched and native buffer drained")
        if let downstream = fixture.client.onSerialEnvelope {
            fixture.client.onSerialEnvelope = { envelope, diagnostic, delivery in
                if envelope.type == "flow_barrier" { await fixture.state.flushPendingRealtimeMessagesSerial(); barrier.fulfill() }
                else { await downstream(envelope, diagnostic, delivery) }
            }
        } else {
            let downstream = try XCTUnwrap(fixture.client.onEnvelope)
            fixture.client.onEnvelope = { envelope in
                if envelope.type == "flow_barrier" { fixture.state.flushPendingRealtimeMessagesForTesting(); barrier.fulfill() }
                else { downstream(envelope) }
            }
        }
        fixture.client.start(url: try XCTUnwrap(URL(string: "wss://example.test/im/ws")), token: "synthetic-im-token")
        await fulfillment(of: [barrier], timeout: 3)
    }
}
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END

// WDT_IOS1_SIGNPOST_SP1_OWNERSHIP_20261110_BEGIN
extension DomainStoreTests {
    func testRealtimeFlowSignpostsKeepWireAckOwnershipDuringDirectStoreReentry() async throws {
        for legacy in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp1-" + UUID().uuidString)
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"))
        let http = FakeHTTPTransport(results: [])
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!, httpTransport: http)
        func wire(_ id: String, sequence: Int64, client: String) throws -> String {
            let object: [String: Any] = ["type": "send_ack", "payload": ["message": [
                "message_id": id, "client_msg_no": client, "channel_id": "flow-channel", "channel_type": "group",
                "channel_seq": sequence, "from_uid": "sp1-actor", "content_type": "text",
                "created_at": "2026-11-10T01:00:00Z", "payload": ["text": "private-sp1-body"]]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let firstWire = try wire("sp1-authority-a", sequence: 2, client: "local_sp1_a")
        let second = try JSONDecoder().decode(RealtimeEnvelope.self,
            from: Data(wire("sp1-authority-b", sequence: 3, client: "local_sp1_b").utf8))
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string(#"{"type":"connect_ack","request_id":"sp1-connect","payload":{}}"#), .string(firstWire),
            .string(#"{"type":"flow_barrier","payload":{}}"#)])
        let client = RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: socket),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
            heartbeatIntervalNanoseconds: 100_000_000_000, requestIDProvider: { _ in "sp1-connect" },
            networkMonitorFactory: nil, continuity: IMRuntimeWebSocketContinuity())
        var context = makeAuthenticatedAPIContext(); context.accountID = UUID().uuidString
        context.tenantID = "sp1-" + UUID().uuidString; context.imUID = "sp1-actor"; context.deviceID = UUID().uuidString
        let state = AppState(api: api, realtimeClient: client, voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshot")),
            messagePersistence: persistence, apiContextOverride: context)
        state.setAuthenticated(true); state.storeCancellables.removeAll()
        state.suppressCurrentUserIdentityPersistence = true; state.setCurrentUser(makeUser(id: "sp1-actor"))
        let ticket = try await persistence.ensureTicket(context: context, sessionGeneration: state.localMessageSessionGeneration)
        state.localMessageTicket = ticket; client.onConnected = nil
        if legacy { let original = client.onEnvelope; client.onEnvelope = original }
        var computed: [RealtimeComputeRuntime.Observation] = []
        state.realtimeComputeRuntime.onComputed = { computed.append($0) }
        var conversation = makeConversation(id: "flow-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.hasUnreadReaction = false; conversation.unreadReactionCount = 0
        let localA = makeMessage(id: "local_sp1_a", senderId: "sp1-actor", seq: 0, status: .sending, isOutgoing: true)
        let localB = makeMessage(id: "local_sp1_b", senderId: "sp1-actor", seq: 0, status: .sending, isOutgoing: true)
        conversation.messages = [makeMessage(id: "flow-base", senderId: "peer", seq: 1), localA, localB]
        state.conversationStore.commitConversationSnapshots([conversation])
        for local in [localA, localB] {
            _ = try await persistence.enqueueOutgoing(ticket: ticket, intent: LocalMessageOutgoingIntent(
                conversation: LocalMessageConversationSnapshot(conversation: conversation, channelID: conversation.id,
                    channelType: "group", currentActorID: "sp1-actor"), message: CachedMessage(message: local),
                operationKind: "send_text", attachment: nil), revision: 1)
        }
        var events: [RealtimeMessageFlowSignpost.Event] = []
        var rendered: Set<String> = []
        RealtimeMessageFlowSignpost.sink = { events.append($0) }
        ChatTimelineRenderDiagnostics.reset(); ChatTimelineRenderDiagnostics.enabled = true
        ChatTimelineRenderDiagnostics.scopedBubbleBody = { id, message in
            if id == "flow-channel" { rendered.insert(message.id) }
        }
        let hosted = hostForSimulatorUI(NavigationView { AppFeatureComposition.chatRouting().makeChat("flow-channel") }
            .navigationViewStyle(.stack).appStateEnvironment(state).environment(\.scenePhase, .active),
            size: CGSize(width: 390, height: 760))
        defer {
            client.disconnect(shouldReconnect: false); client.onEnvelope = nil; state.setAuthenticated(false)
            RealtimeMessageFlowSignpost.sink = nil; ChatTimelineRenderDiagnostics.reset(); hosted.window.isHidden = true
            // Keep owned SQLite files until all original coordinator handles have been released.
        }
        for _ in 0..<100 where !rendered.contains("flow-base") { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(rendered.contains("flow-base"), "original Chat must already be mounted")
        var injected = false
        var nativeObservationWasActive = false
        var installedRevisions: [UInt64] = []
        let callback = state.conversationStore.memoryUpdates.dropFirst().sink { snapshot in
            let ids = state.conversationStore.messageMemoryStore.messages(for: "flow-channel").map(\.id)
            if ids.contains("sp1-authority-a") { installedRevisions.append(snapshot.revision) }
            guard !injected, ids.contains("sp1-authority-a") else { return }
            injected = true
            nativeObservationWasActive = client.currentEnvelopeDiagnostic != nil
            XCTAssertTrue(nativeObservationWasActive, "ACK A must still own the native synchronous callback")
            state.handleRealtimeEnvelope(second) // Direct AppState reentry inside the actual Store notification.
            XCTAssertEqual(events.filter { $0.stage == .storeInstalled }.count, 1,
                "queued ACK B returned before its original FIFO frame was installed")
            XCTAssertFalse(state.conversationStore.messageMemoryStore.messages(for: "flow-channel").contains { $0.id == "sp1-authority-b" })
        }
        defer { callback.cancel() }
        try await runFlowWire((state, client))
        var pending = try await persistence.pendingOutbox(ticket: ticket)
        for _ in 0..<200 where !pending.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000); pending = try await persistence.pendingOutbox(ticket: ticket)
        }
        let current = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: "flow-channel"))
        let wantedProjection = state.localMessageProjectionRevision
        var persistedProjection = try await persistence.projectionRevisionFloor(ticket: ticket)
        for _ in 0..<100 where persistedProjection < wantedProjection {
            try await Task.sleep(nanoseconds: 10_000_000)
            persistedProjection = try await persistence.projectionRevisionFloor(ticket: ticket)
        }
        XCTAssertGreaterThanOrEqual(persistedProjection, wantedProjection)
        let disk = try await persistence.activateAndLoad(context: context, sessionGeneration: state.localMessageSessionGeneration)
        let rows = disk.conversations.flatMap(\.messages)
        XCTAssertTrue(injected); XCTAssertTrue(nativeObservationWasActive)
        XCTAssertEqual(computed.count, legacy ? 0 : 1)
        if let value = computed.first {
            XCTAssertFalse(value.mappedOnMainThread); XCTAssertFalse(value.mergedOnMainThread); XCTAssertFalse(value.fallback)
        }
        XCTAssertEqual(current.messages.map(\.id), ["flow-base", "sp1-authority-a", "sp1-authority-b"])
        XCTAssertEqual(current.messages.suffix(2).map(\.status), [.sent, .sent])
        XCTAssertEqual(current.unread, 0); XCTAssertEqual(current.messageCoveredThroughSeq, 3)
        XCTAssertEqual(state.conversationStore.latestReadableSequence(in: current), 3)
        XCTAssertTrue(pending.isEmpty); XCTAssertEqual(rows.map(\.channelSeq).sorted(), [1, 2, 3])
        XCTAssertEqual(sentPacketTypes(socket), ["connect"], "diagnostics must not resend business traffic")
        let control: [String: Any] = ["sequences": current.messages.map(\.channelSeq),
            "statuses": current.messages.map { String(describing: $0.status) }, "unread": current.unread,
            "covered": current.messageCoveredThroughSeq, "installedRevisions": installedRevisions,
            "pendingOutbox": pending.count, "diskSequences": rows.map(\.channelSeq).sorted(),
            "websocketTypes": sentPacketTypes(socket),
            "httpAckCount": http.requests().filter { $0.url?.path.contains("ack") == true }.count]
        let business = XCTAttachment(data: try JSONSerialization.data(withJSONObject: control, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        business.name = "SP1-business-control-" + (legacy ? "legacy" : "worker"); business.lifetime = .keepAlways; add(business)
        let trace = XCTAttachment(data: try JSONEncoder().encode(events), uniformTypeIdentifier: "public.json")
        trace.name = "SP1-opaque-flow-events-" + (legacy ? "legacy" : "worker"); trace.lifetime = .keepAlways; add(trace)
        let arrivals = events.filter { $0.stage == .arrival }; let installs = events.filter { $0.stage == .storeInstalled }
        XCTAssertEqual(arrivals.count, 2); XCTAssertEqual(Set(arrivals.map(\.correlation)).count, 2)
        XCTAssertEqual(installs.count, 2); XCTAssertEqual(installs.map(\.correlation), arrivals.map(\.correlation))
        XCTAssertEqual(installs.compactMap(\.revision), installedRevisions)
        if installs.count == 2 { XCTAssertLessThan(try XCTUnwrap(installs[0].revision), try XCTUnwrap(installs[1].revision)) }
        for arrival in arrivals {
            let chain = events.filter { $0.correlation == arrival.correlation }
            XCTAssertEqual(chain.filter { $0.stage == .storeInstalled }.count, 1)
            XCTAssertEqual(chain.filter { $0.stage == .projectionConsumed }.count, 1)
            XCTAssertFalse(chain.contains { $0.stage == .projectionFiltered })
            XCTAssertEqual(chain.filter { [.publicationObserved, .publicationUnobserved].contains($0.stage) }.count, 1)
            if let installed = chain.first(where: { $0.stage == .storeInstalled }),
               let projection = chain.first(where: { $0.stage == .projectionConsumed }) {
                XCTAssertEqual(installed.revision, projection.revision)
                XCTAssertEqual(chain.last?.stage, .publicationObserved)
            }
        }
        let metadata = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for value in ["sp1-authority-a", "sp1-authority-b", "local_sp1_a", "local_sp1_b", "private-sp1-body", "synthetic-im-token"] {
            XCTAssertFalse(metadata.contains(value))
        }
        }
    }
}
// WDT_IOS1_SIGNPOST_SP1_OWNERSHIP_20261110_END

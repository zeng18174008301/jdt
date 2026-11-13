@testable import IM4Features
@testable import IM4Data // WDT_IOS1_PHASE6_SEARCH_READ_AUTHORITY_20261111
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine // WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110
import GRDB // WDT_IOS1_PHASE6_SEARCH_READ_AUTHORITY_20261111
import XCTest
@testable import WenDaTong

// WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110_BEGIN
extension DomainStoreTests {
    func testDelayedHistoryPageCannotMutateReplacedSessionBinding() async throws {
        try await assertDelayedHistoryPageBinding(newer: false)
    }

    func testDelayedNewerHistoryPageCannotMutateReplacedSessionBinding() async throws {
        try await assertDelayedHistoryPageBinding(newer: true)
    }

    private func assertDelayedHistoryPageBinding(newer: Bool) async throws {
        for change in MessageCallbackBindingChange.allCases {
            for failure in [false, true] {
                let remote = remoteMessageJSON(id: "delayed", channelID: "same-channel", channelType: "group", seq: newer ? 101 : 99)
                let body = failure ? "{}" : "{\"ok\":true,\"data\":{\"items\":[\(remote)],\"has_more_before\":true,\"total\":1}}"
                let fixture = try await makeMessageCallbackFixture(path: "/api/im/sync", body: body, failure: failure, newer: newer)
                addTeardownBlock { @MainActor in await fixture.persistence.detach(ticket: fixture.state.localMessageTicket)
                    /* WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN: Retain only this UUID fixture backing for original projection/pool lifetime. WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END */ }
                let state = fixture.state
                let historyKey = state.conversationHistoryStateKey(for: state.conversationStore.conversationMessageSnapshots()[0])
                if newer {
                    state.loadNewerMessagesIfAvailable("same-channel")
                } else {
                    XCTAssertTrue(state.loadOlderMessagesIfAvailable("same-channel"))
                }
                try await waitForMessageCallback { await fixture.transport.gate.isWaiting() }
                let waiting = await fixture.transport.gate.isWaiting()
                XCTAssertTrue(waiting)
                change.apply(to: state)
                if change != .credentialRefresh { try await rebindMessageCallbackFixture(fixture) }
                state.conversationStore.setHistoryMessage(conversationID: "same-channel", message: "current history status")
                let before = state.conversationStore.conversationMessageSnapshots()
                let revision = state.localMessageProjectionRevision
                let acks = fixture.transport.ackCount
                await fixture.transport.gate.resumeFirst()
                try await waitForMessageCallback {
                    newer ? !state.conversationStore.isMessageSyncInFlight(historyKey: historyKey)
                        : !state.conversationStore.isHistoryLoading(conversationID: "same-channel")
                }
                XCTAssertFalse(state.conversationStore.isHistoryLoading(conversationID: "same-channel"))
                if change == .credentialRefresh {
                    if failure {
                        let status = newer ? "current history status" : "更早聊天记录同步失败，请稍后重试"
                        XCTAssertEqual(state.conversationStore.historyMessage(conversationID: "same-channel"), status)
                    } else {
                        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().flatMap(\.messages).map(\.id), newer ? ["current", "delayed"] : ["delayed", "current"])
                    }
                } else {
                    XCTAssertEqual(state.conversationStore.conversationMessageSnapshots(), before, "\(change) failure=\(failure)")
                    XCTAssertEqual(state.localMessageProjectionRevision, revision, "\(change) failure=\(failure)")
                    XCTAssertEqual(state.conversationStore.historyMessage(conversationID: "same-channel"), "current history status", "\(change) failure=\(failure)")
                    XCTAssertEqual(fixture.transport.ackCount, acks, "\(change) failure=\(failure)")
                    XCTAssertNil(state.toast, "\(change) failure=\(failure)")
                    let stored = try await fixture.persistence.activateAndLoad(context: state.apiContext, sessionGeneration: state.localMessageSessionGeneration)
                    XCTAssertFalse(stored.conversations.flatMap(\.messages).contains { $0.id == "delayed" }, "\(change)")
                }
            }
        }
    }

    func testDelayedReceiptResponseCannotMutateReplacedSessionBinding() async throws {
        for change in MessageCallbackBindingChange.allCases {
            for failure in [false, true] {
                let body = #"{"ok":true,"data":{"read":true,"can_view_details":true,"items":[{"message_id":"current","im_uid":"late-reader","receipt_type":"read","channel_seq":100}],"read_count":1,"unread_count":0}}"#
                let fixture = try await makeMessageCallbackFixture(path: "/api/im/messages/current/read-receipts", body: failure ? "{}" : body, failure: failure)
                addTeardownBlock { @MainActor in await fixture.persistence.detach(ticket: fixture.state.localMessageTicket)
                    /* WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN: Retain only this UUID fixture backing for original projection/pool lifetime. WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END */ }
                let state = fixture.state
                let task = state.loadReadReceipts(messageID: "current", in: "same-channel")
                try await waitForMessageCallback { await fixture.transport.gate.isWaiting() }
                let waiting = await fixture.transport.gate.isWaiting()
                XCTAssertTrue(waiting)
                change.apply(to: state)
                if change != .credentialRefresh { try await rebindMessageCallbackFixture(fixture) }
                let before = state.conversationStore.conversationMessageSnapshots()
                let revision = state.localMessageProjectionRevision
                let acks = fixture.transport.ackCount
                await fixture.transport.gate.resumeFirst()
                await task.value
                if change == .credentialRefresh {
                    if failure {
                        XCTAssertNotNil(state.toast)
                    } else {
                        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.first?.readBy.map(\.user.id), ["late-reader"])
                    }
                } else {
                    XCTAssertEqual(state.conversationStore.conversationMessageSnapshots(), before, "\(change) failure=\(failure)")
                    XCTAssertEqual(state.localMessageProjectionRevision, revision, "\(change) failure=\(failure)")
                    XCTAssertEqual(fixture.transport.ackCount, acks, "\(change) failure=\(failure)")
                    XCTAssertNil(state.toast, "\(change) failure=\(failure)")
                    let stored = try await fixture.persistence.activateAndLoad(context: state.apiContext, sessionGeneration: state.localMessageSessionGeneration)
                    XCTAssertTrue(stored.conversations.flatMap(\.messages).allSatisfy { $0.readBy.isEmpty }, "\(change)")
                }
            }
        }
    }

    private func makeMessageCallbackFixture(path: String, body: String, failure: Bool, newer: Bool = false) async throws -> MessageCallbackFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("message-callback-" + UUID().uuidString)
        let transport = MessageCallbackGateTransport(path: path, body: body, status: failure ? 503 : 200)
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")
        )
        var context = makeAuthenticatedAPIContext()
        context.accountID = "callback-" + UUID().uuidString
        context.deviceID = UUID().uuidString
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!, httpTransport: transport
        )
        let engine = DefaultSyncEngine()
        _ = engine.beginRemoteSnapshotRefresh()
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(),
            messageStore: MessageCallbackEmptyMessageStore(), messagePersistence: persistence,
            remoteSyncEngine: engine, apiContextOverride: context)
        state.setAuthenticated(true)
        state.storeCancellables.removeAll()
        state.suppressCurrentUserIdentityPersistence = true
        state.setCurrentUser(makeUser(id: context.imUID!))
        state.setReadReceiptsEnabled(true)
        let fixture = MessageCallbackFixture(state: state, persistence: persistence, transport: transport, root: root, newestSequence: newer ? 101 : 100)
        try await rebindMessageCallbackFixture(fixture)
        return fixture
    }

    private func rebindMessageCallbackFixture(_ fixture: MessageCallbackFixture) async throws {
        let state = fixture.state
        state.setCurrentEnterprise(Enterprise(id: state.apiContext.tenantID!, name: "Current", code: "Current", role: "admin",
            status: "normal", memberCount: 1, isDefault: true, accentHex: 0))
        var conversation = makeConversation(id: "same-channel", kind: .group, unread: 0, lastMsgSeq: fixture.newestSequence, lastReadSeq: 100)
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.firstUnreadSeq = 0
        conversation.firstUnreadMessageID = ""
        conversation.unreadAnchorSeq = 0
        conversation.unreadAnchorState = "none"
        conversation.messages = [makeMessage(id: "current", seq: 100, status: .sent, isOutgoing: true)]
        conversation.messageCoveredThroughSeq = 100
        state.conversationStore.commitConversationSnapshots([conversation])
        _ = state.conversationSelectionEpochFence.select(scope: state.remoteDataScopeKey(for: state.apiContext), conversationID: conversation.id)
        state.applyReadReceiptDetailAuthority(true, conversationID: conversation.id)
        let ticket = try await fixture.persistence.ensureTicket(context: state.apiContext, sessionGeneration: state.localMessageSessionGeneration)
        state.localMessageTicket = ticket
        state.localMessageProjectionRevision = 1
        _ = try await fixture.persistence.persist(ticket: ticket, snapshots: [LocalMessageConversationSnapshot(
            conversation: state.conversationStore.conversationMessageSnapshots()[0], channelID: conversation.id, channelType: "group", currentActorID: state.apiContext.imUID!
        )], source: .history, revision: 1)
        state.setToast(nil)
    }

    private func waitForMessageCallback(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("callback did not reach its controlled checkpoint")
    }
}

// WDT_IOS1_PHASE6_SEARCH_READ_AUTHORITY_20261111_BEGIN
extension DomainStoreTests {
    func testPhase6SearchHTTPFailureOnlyFallsBackForCurrentAuthority() async throws {
        for change in ["scope", "epoch", "same", "credential", "cancel"] {
            let transport = MessageCallbackGateTransport(path: "/api/im/messages/search",
                body: #"{"ok":false,"error":{"code":"search_unavailable","message":"fixture search unavailable"}}"#,
                status: 503)
            let (state, _, _) = try await makeScopedSearchFixture(transport: transport)
            let search = startScopedSearch(state)
            try await waitForMessageCallback { await transport.gate.isWaiting() }

            var next = state.apiContext
            switch change {
            case "scope": next.tenantID = "replacement-search-tenant"
            case "epoch": next.sessionEpoch = UUID().uuidString
            case "credential":
                next.imToken = "renewed-search-fixture"
                next.credentialRevision += 1
            default: break
            }
            state.apiContext = next
            if change == "cancel" { search.cancel() }
            let priorToast = state.toast
            let revision = state.conversationStore.memorySnapshot.revision
            await transport.gate.resumeFirst()
            let snippets = await search.value

            if change == "scope" || change == "epoch" {
                XCTAssertTrue(snippets.isEmpty, change)
                XCTAssertEqual(state.toast, priorToast, change)
            } else {
                XCTAssertEqual(snippets, ["scopeoracle local"], change)
                if change != "cancel" { XCTAssertTrue(state.toast?.contains("聊天记录搜索失败") == true, change) }
            }
            XCTAssertEqual(state.conversationStore.memorySnapshot.revision, revision, change)
        }
    }

    func testPhase6SearchRechecksAuthorityAfterSQLiteBeforeAnyRequest() async throws {
        for change in ["scope", "epoch", "offline"] {
            let transport = FakeHTTPTransport(results: [])
            let cleanup = FirstReadAckSuspensionGate()
            let (state, persistence, ticket) = try await makeScopedSearchFixture(transport: transport,
                scopePurgeBarrier: { await cleanup.wait() })
            let entered = expectation(description: "SQLite FTS completed for \(change)")
            let release = DispatchSemaphore(value: 0)
            try await holdScopedSearchFTS(persistence: persistence, ticket: ticket, entered: entered, release: release)

            let search = startScopedSearch(state)
            await fulfillment(of: [entered], timeout: 3)
            let original = state.apiContext
            var next = original
            switch change {
            case "scope": next.tenantID = "replacement-search-tenant"
            case "epoch": next.sessionEpoch = UUID().uuidString
            default: next.imToken = nil
            }
            state.apiContext = next
            let priorToast = state.toast
            let revision = state.conversationStore.memorySnapshot.revision
            release.signal()
            let snippets = await search.value
            // Exercise App retirement during the query without retaining an open test reader through file removal.
            await cleanup.resumeFirst()
            if change != "offline" {
                try await waitForMessageCallback { (try? persistence.hasPendingScopeCleanup(context: original)) == false }
            }

            XCTAssertEqual(snippets, change == "offline" ? ["scopeoracle local"] : [], change)
            XCTAssertTrue(transport.requests().isEmpty, change)
            XCTAssertEqual(state.toast, priorToast, change)
            XCTAssertEqual(state.conversationStore.memorySnapshot.revision, revision, change)
        }
    }

    private func holdScopedSearchFTS(persistence: MessagePersistenceCoordinator, ticket: LocalMessageSessionTicket,
        entered: XCTestExpectation, release: DispatchSemaphore) async throws {
        let repository = try await persistence.repository(for: ticket)
        let pool = await repository.databasePool
        try await Task.detached {
            pool.invalidateReadOnlyConnections()
            try pool.read { db in
                db.trace(options: .profile) { event in
                    guard case .profile(let statement, _) = event, statement.sql.contains("message_search MATCH") else { return }
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 8), .success)
                }
            }
        }.value
    }

    private func makeScopedSearchFixture(transport: HTTPTransport, scopePurgeBarrier: (@Sendable () async -> Void)? = nil) async throws
        -> (AppState, MessagePersistenceCoordinator, LocalMessageSessionTicket) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phase6-search-authority-\(UUID().uuidString)")
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"), scopePurgeBarrier: scopePurgeBarrier)
        let context = makeAuthenticatedAPIContext(accountID: UUID().uuidString)
        let state = AppState(api: makeSearchJumpAPI(transport: transport), voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshot")),
            messagePersistence: persistence, protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
        var row = makeConversation(id: "phase6-scope-search", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.messages = [makeMessage(id: "search-local", senderId: "uid-2", seq: 1, text: "scopeoracle local")]
        state.conversationStore.hydrateCachedConversations([row])
        let ticket = try await persistence.ensureTicket(context: context, sessionGeneration: state.localMessageSessionGeneration)
        state.localMessageTicket = ticket
        _ = try await persistence.persist(ticket: ticket, snapshots: [
            LocalMessageConversationSnapshot(conversation: row, channelID: row.id, channelType: "group", currentActorID: "uid-1")
        ], source: .history, revision: 1)
        let before = try await persistence.search(ticket: ticket, query: "scopeoracle", limit: 100)
        XCTAssertEqual(before.map(\.message.model.id), ["search-local"])
        return (state, persistence, ticket)
    }

    private func startScopedSearch(_ state: AppState) -> Task<[String], Never> {
        Task { @MainActor in
            await state.searchMessages(in: "phase6-scope-search", keyword: "scopeoracle").map(\.snippet)
        }
    }
}
// WDT_IOS1_PHASE6_SEARCH_READ_AUTHORITY_20261111_END

private enum MessageCallbackBindingChange: CaseIterable {
    case tenant, logoutLogin, aToBToA, reauthentication, credentialRefresh

    @MainActor
    func apply(to state: AppState) {
        let original = state.apiContext
        var next = original
        switch self {
        case .tenant:
            next.tenantID = "tenant-next"
            state.apiContext = next
        case .logoutLogin:
            next.imToken = nil
            next.sessionEpoch = UUID().uuidString
            state.apiContext = next
            state.setAuthenticated(false)
            next = original
            next.sessionEpoch = UUID().uuidString
            state.apiContext = next
            state.setAuthenticated(true)
        case .aToBToA:
            next.tenantID = "tenant-next"
            state.apiContext = next
            state.apiContext = original
        case .reauthentication:
            next.sessionEpoch = UUID().uuidString
            state.sessionReauthenticationCommit = (old: original.authSessionFence, new: next.authSessionFence)
            state.apiContext = next
            state.sessionReauthenticationCommit = nil
        case .credentialRefresh:
            next.credentialRevision += 1
            state.apiContext = next
        }
    }
}

private struct MessageCallbackFixture {
    let state: AppState
    let persistence: MessagePersistenceCoordinator
    let transport: MessageCallbackGateTransport
    let root: URL
    let newestSequence: Int64
}

private struct MessageCallbackEmptyMessageStore: MessageStore {
    let schemaVersion = 99
    func scopeKey(for context: IMAPIContext) -> String { (try? LocalMessageScope(context: context).scopeHash) ?? "" }
    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? { nil }
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool { true }
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool { true }
    func remove(scope: String) {}
    func removeAll() {}
}

private final class MessageCallbackGateTransport: HTTPTransport, @unchecked Sendable {
    let gate = FirstReadAckSuspensionGate()
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let path: String
    private let result: HTTPTransportResult

    init(path: String, body: String, status: Int) {
        self.path = path
        result = HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true, statusCode: status)
    }

    var ackCount: Int {
        lock.withLock { requests.filter { $0.httpMethod == "POST" && $0.url?.path.contains("ack") == true }.count }
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock { requests.append(request) }
        if request.url?.path == path {
            await gate.wait()
            return result.resolvingResponseURL(request.url)
        }
        return HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200)
            .resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        XCTFail("message callback fixture does not upload")
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110_END

// WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110_BEGIN
extension DomainStoreTests {
    func testHistoryRequestCompletionCannotReleaseReplacementAfterReset() throws {
        for older in [false, true] {
            for sameKey in [false, true] {
                let store = ConversationStore(scope: TestMessageMemoryScope.value)
                let oldKey = "tenant-a|channel"
                let newKey = sameKey ? oldKey : "tenant-b|channel"
                func begin(_ key: String) -> ConversationStore.HistorySyncClaim? {
                    older ? store.beginOlderHistoryLoadClaim(historyKey: key, conversationID: "channel", now: Date(), throttleInterval: 0)
                        : store.beginMessageSyncClaim(historyKey: key, conversationID: "channel", showLoadingIndicator: true)
                }
                let oldClaim = try XCTUnwrap(begin(oldKey))
                store.reset()
                let newClaim = try XCTUnwrap(begin(newKey))
                store.finishHistorySync(oldClaim)
                store.finishHistorySync(oldClaim)
                XCTAssertTrue(store.isHistoryLoading(conversationID: "channel"), "older=\(older) sameKey=\(sameKey)")
                XCTAssertNil(begin(newKey), "old completion released replacement duplicate protection")
                store.finishHistorySync(newClaim)
                XCTAssertFalse(store.isHistoryLoading(conversationID: "channel"))
                let completedReplacement = try XCTUnwrap(begin(newKey))
                store.finishHistorySync(completedReplacement)
            }
        }
    }

    func testHistoryLoadingSurvivesAnotherVisibleRequestFinishing() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let first = try XCTUnwrap(store.beginMessageSyncClaim(historyKey: "tenant-a|channel", conversationID: "channel", showLoadingIndicator: true))
        let second = try XCTUnwrap(store.beginOlderHistoryLoadClaim(historyKey: "tenant-b|channel", conversationID: "channel", now: Date(), throttleInterval: 0))
        store.finishHistorySync(first)
        XCTAssertTrue(store.isHistoryLoading(conversationID: "channel"))
        store.finishHistorySync(second)
        XCTAssertFalse(store.isHistoryLoading(conversationID: "channel"))
    }
}
// WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110_END

// WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110_BEGIN
extension DomainStoreTests {
    func testLocalMessageMutationKeepsPublicationOrderValueSnapshotsAndConversationIsolation() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.hasUnreadReaction = false
        first.unreadReactionCount = 0
        first.messages = [makeMessage(id: "same-id", seq: 1, status: .failed, text: "original")]
        first.lastMessage = "original"
        var second = makeConversation(id: "second", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.hasUnreadReaction = false
        second.unreadReactionCount = 0
        second.messages = first.messages
        second.lastMessage = first.lastMessage
        store.commitConversationSnapshots([first, second])
        let retained = store.conversationMessageSnapshots()
        var publications: [ConversationMessageSnapshot] = []
        let observation = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { publications.append($0[0]) } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        XCTAssertTrue(store.applyLocalMessageEdit(messageID: "same-id", conversationID: "first", text: " edited "))
        observation.cancel()
        // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
        XCTAssertEqual(publications.map { $0.messages[0].text }, ["edited"])
        XCTAssertEqual(publications.map { $0.messages[0].isEdited }, [true])
        XCTAssertEqual(publications.map { $0.messages[0].status }, [.sent])
        XCTAssertEqual(publications.map(\.lastMessage), ["edited"])
        // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END
        XCTAssertEqual(retained, [first, second])
        XCTAssertEqual(store.conversationMessageSnapshots()[1], second)
        let editedSnapshot = store.conversationMessageSnapshots()[0]
        XCTAssertTrue(store.markAttachmentUploadFailed(messageID: "same-id", conversationID: "first"))
        XCTAssertTrue(store.markAttachmentUploadRetrying(messageID: "same-id", conversationID: "first"))
        XCTAssertEqual(store.updateAttachmentUploadStatus("uploaded", messageID: "same-id", conversationID: "first")?.attachmentUploadStatus, "uploaded")
        XCTAssertTrue(store.setMessagePinned(messageID: "same-id", conversationID: "first", pinned: true))
        XCTAssertTrue(store.setMessageFavorited(messageID: "same-id", conversationID: "first", favorited: true))
        XCTAssertEqual(store.setAttachmentFileID("file-id", messageID: "same-id", conversationID: "first")?.attachmentFileID, "file-id")
        XCTAssertEqual(editedSnapshot.messages[0].status, .sent)
        XCTAssertFalse(editedSnapshot.messages[0].isPinned)
        XCTAssertFalse(editedSnapshot.messages[0].isFavorited)
        XCTAssertEqual(editedSnapshot.messages[0].attachmentFileID, retained[0].messages[0].attachmentFileID)
        let beforeAppend = store.conversationMessageSnapshots()[0]
        let appended = makeMessage(id: "local-echo", seq: 0, status: .sending, text: "pending")
        XCTAssertEqual(store.appendLocalOutgoingMessage(appended, to: "first")?.messages.map(\.id), ["same-id", "local-echo"])
        XCTAssertEqual(beforeAppend.messages.map(\.id), ["same-id"])
        XCTAssertTrue(store.removeMessage(messageID: "local-echo", conversationID: "first"))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["same-id"])
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "missing", conversationID: "first", text: "ignored"))
        XCTAssertEqual(store.conversationMessageSnapshots()[1], second)
        XCTAssertEqual(retained, [first, second])
    }
}
// WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110_END

// WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110_BEGIN
extension DomainStoreTests {
    func testReactionDetailMapperReadsCommittedStoreAndPreservesPublicationSequence() throws {
        for repair in [false, true] {
            let store = ConversationStore(scope: TestMessageMemoryScope.value)
            var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
            conversation.messages = [makeMessage(id: "m1", seq: 1, isOutgoing: true)]
            store.commitConversationSnapshots([conversation])
            let retained = store.conversationMessageSnapshots()
            let extra = try decodeRemoteExtra(#"{"message_id":"m1","channel_id":"c1","channel_type":"group","operator_uid":"reader","extra_type":"reaction","emoji":"ok","action":"add"}"#)
            var mapperReactionCounts: [Int] = []
            var mapperDetailCounts: [Int] = []
            var publishedMessages: [ChatMessage] = []
            let observation = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { publishedMessages.append($0[0].messages[0]) } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            defer { observation.cancel() }
            let mapper: (RemoteMessageExtra, String) -> ReactionDetail = { extra, id in
                mapperReactionCounts.append(store.conversationMessageSnapshots()[0].messages[0].reactions.count)
                mapperDetailCounts.append(store.conversationMessageSnapshots()[0].messages[0].reactionDetails.count)
                return self.makeReactionDetail(from: extra, id: id)
            }
            func apply() -> Bool {
                repair ? store.applyDedupedReactionExtraIfMissing(extra, currentUserIDs: ["me"], makeReactionDetail: mapper)
                    : store.applyMessageReactionDetail(extra, makeReactionDetail: mapper)
            }
            XCTAssertTrue(apply())
            // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_BEGIN
            // Atomic repair maps against the prior complete Store, then publishes once.
            XCTAssertEqual(mapperReactionCounts, [0])
            XCTAssertEqual(mapperDetailCounts, [0])
            XCTAssertEqual(publishedMessages.map { $0.reactionDetails.count }, [1])
            // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_END
            let publicationCount = publishedMessages.count
            XCTAssertEqual(apply(), !repair)
            XCTAssertEqual(mapperDetailCounts, [0], "duplicate must not call the mapper")
            XCTAssertEqual(publishedMessages.count, publicationCount)
            XCTAssertTrue(retained[0].messages[0].reactions.isEmpty)
            XCTAssertTrue(retained[0].messages[0].reactionDetails.isEmpty)
        }
    }

    func testReceiptMappersReadStoreBeforeWholeMessagePublication() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.messages = [makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)]
        store.commitConversationSnapshots([conversation])
        let retained = store.conversationMessageSnapshots()
        let response = try decodeRemoteReadReceiptResponse(#"{"read":true,"can_view_details":true,"read_count":1,"unread_count":1,"items":[{"message_id":"m1","im_uid":"reader","receipt_type":"read","channel_seq":1}],"unread_items":[{"im_uid":"unread"}],"reactions":[{"operator_uid":"reactor","emoji":"ok"}]}"#)
        var phases: [String] = []
        var published: [ChatMessage] = []
        let observation = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { published.append($0[0].messages[0]) } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        defer { observation.cancel() }
        func observe(_ phase: String) {
            phases.append(phase)
            XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].readBy.isEmpty)
            XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].reactionDetails.isEmpty)
            XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .sent)
        }
        XCTAssertTrue(store.applyRemoteReadReceiptDetails(
            response: response, messageID: "m1", conversationID: "c1",
            makeReadReceipt: { receipt, current in
                observe("read")
                return self.makeReadReceipt(from: receipt, conversation: current)
            }, makeUnreadReceipt: { participant, current in
                observe("unread")
                return self.makeUnreadReadReceipt(from: participant, conversation: current)
            }, makeReactionDetail: { reaction in
                observe("reaction")
                return self.makeReactionDetail(from: reaction)
            }
        ))
        XCTAssertEqual(phases, ["read", "unread", "reaction"])
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].readBy.map(\.user.id), ["reader"])
        XCTAssertEqual(published[0].unreadBy.map(\.user.id), ["unread"])
        XCTAssertEqual(published[0].reactionDetails.count, 1)
        XCTAssertEqual(published[0].status, .read)
        XCTAssertEqual(retained, [conversation])
    }
}
// WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110_END

// WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
extension DomainStoreTests {
    func testMemoryCommitCarriesPreviousWindowForPostCommitViewportDecisions() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.messages = [makeMessage(id: "m1", seq: 1, text: "original")]
        conversation.lastMessage = "original"
        store.commitConversationSnapshots([conversation])
        let revision = store.memorySnapshot.revision
        var commits: [ConversationStore.MemoryCommit] = []
        let changes = store.memoryCommits.sink { commit in
            commits.append(commit)
            XCTAssertEqual(store.conversations, commit.current.conversations)
            XCTAssertEqual(store.memorySnapshot.revision, commit.current.revision)
        }
        defer { changes.cancel() }
        XCTAssertTrue(commits.isEmpty, "commit events do not replay the current window as a growth event")
        let appended = makeMessage(id: "local", seq: 0, status: .sending, text: "pending")
        XCTAssertNotNil(store.appendLocalOutgoingMessage(appended, to: "c1", displayTime: "now"))
        let commit = try XCTUnwrap(commits.first)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commit.previous.revision, revision)
        XCTAssertEqual(commit.current.revision, revision + 1)
        XCTAssertEqual(commit.previous.conversations, [conversation.conversation])
        let previous = commit.messageChanges["c1"]!.previous
        let current = commit.messageChanges["c1"]!.current
        XCTAssertFalse(chatMessagesShareStorage(previous, current))
        XCTAssertEqual(previous.map(\.id), ["m1"])
        XCTAssertEqual(current.map(\.id), ["m1", "local"])
        XCTAssertGreaterThan(current.count, previous.count)
        XCTAssertEqual(current[previous.count - 1].id, previous.last?.id)
        XCTAssertEqual(commit.current.conversations[0].lastMessage, "pending")
        XCTAssertTrue(store.applyLocalMessageEdit(messageID: "m1", conversationID: "c1", text: "edited"))
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[1].messageChanges["c1"]!.previous[0].text, "original")
        XCTAssertEqual(commits[1].messageChanges["c1"]!.current[0].text, "edited")
        XCTAssertEqual(commit.messageChanges["c1"]!.current[0].text, "original")
    }

    func testConversationMemoryCommitKeepsRowsUnreadAndRevisionCoherentForSubscribers() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var frames: [CapturedConversationMemorySnapshot] = []
        let memory = store.memoryUpdates.sink { frame in
            frames.append(frame.captureMessages(from: store))
            XCTAssertEqual(store.conversations, frame.conversations)
            XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
            XCTAssertEqual(store.memorySnapshot.revision, frame.revision)
            XCTAssertEqual(frame.alertingUnreadTotal, ConversationUnreadBadgeProjection.total(frame.conversations))
        }
        let rows = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher().sink { rows in
            XCTAssertEqual(store.conversationMessageSnapshots(), rows)
            XCTAssertEqual(store.alertingUnreadTotal, ConversationUnreadBadgeProjection.total(rows.map(\.conversation)))
        }
        let unread = store.alertingUnreadUpdates.sink { total in
            XCTAssertEqual(store.alertingUnreadTotal, total)
            XCTAssertEqual(total, ConversationUnreadBadgeProjection.total(store.conversations))
        }
        defer { memory.cancel(); rows.cancel(); unread.cancel() }
        let first = makeConversation(id: "first", unread: 7, lastMsgSeq: 7, lastReadSeq: 0)
        var muted = makeConversation(id: "muted", unread: 9, lastMsgSeq: 9, lastReadSeq: 0)
        muted.isMuted = true
        store.commitConversationSnapshots([first, muted])
        var read = first
        read.unread = 0
        read.lastReadSeq = 7
        read.hasUnreadReaction = false
        read.unreadReactionCount = 0
        store.commitConversationSnapshots([read, muted])
        store.commitConversationSnapshots([])
        XCTAssertEqual(frames.map(\.revision), [0, 1, 2, 3])
        XCTAssertEqual(frames.map(\.alertingUnreadTotal), [0, 7, 0, 0])
        XCTAssertEqual(frames[1].conversations, [first, muted], "retained frames are value snapshots")
        XCTAssertNil(store.conversationMessageSnapshot(id: "first"))
    }

    func testLocalMessageOperationsCommitMessageAndSummaryInOneRevision() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.messages = [makeMessage(id: "m1", seq: 1, status: .failed, text: "original")]
        first.lastMessage = "original"
        var second = makeConversation(id: "second", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.messages = first.messages
        store.commitConversationSnapshots([first, second])
        var frames: [CapturedConversationMemorySnapshot] = []
        let changes = store.memoryUpdates.dropFirst().sink { frame in
            frames.append(frame.captureMessages(from: store))
            XCTAssertEqual(store.memorySnapshot.revision, frame.revision)
            XCTAssertEqual(store.conversation(id: "first"), frame.conversations[0])
            XCTAssertEqual(frame.conversations[1], second.conversation)
        }
        defer { changes.cancel() }
        func assertOneCommit(_ operation: () -> Void) {
            let revision = store.memorySnapshot.revision
            let count = frames.count
            operation()
            XCTAssertEqual(frames.count, count + 1)
            XCTAssertEqual(store.memorySnapshot.revision, revision + 1)
        }
        assertOneCommit { XCTAssertTrue(store.applyLocalMessageEdit(messageID: "m1", conversationID: "first", text: "edited")) }
        XCTAssertEqual(frames.last?.conversations[0].lastMessage, "edited")
        XCTAssertEqual(frames.last?.conversations[0].messages[0].text, "edited")
        XCTAssertEqual(frames.last?.conversations[0].messages[0].status, .sent)
        assertOneCommit { XCTAssertTrue(store.markAttachmentUploadFailed(messageID: "m1", conversationID: "first")) }
        XCTAssertEqual(frames.last?.conversations[0].messages[0].attachmentUploadStatus, "failed")
        assertOneCommit { XCTAssertTrue(store.markAttachmentUploadRetrying(messageID: "m1", conversationID: "first")) }
        XCTAssertEqual(frames.last?.conversations[0].messages[0].status, .sending)
        XCTAssertNil(frames.last?.conversations[0].messages[0].attachmentTransferProgress)
        XCTAssertEqual(frames.last?.conversations[0].messages[0].attachmentUploadStatus, "retrying")
        let local = makeMessage(id: "local", seq: 0, status: .sending, text: "pending")
        assertOneCommit { XCTAssertNotNil(store.appendLocalOutgoingMessage(local, to: "first", preview: "pending", displayTime: "now")) }
        XCTAssertEqual(frames.last?.conversations[0].messages.last?.id, "local")
        XCTAssertEqual(frames.last?.conversations[0].lastMessage, "pending")
        assertOneCommit { XCTAssertTrue(store.removeMessage(messageID: "local", conversationID: "first")) }
        XCTAssertFalse(store.conversationMessageSnapshots()[0].messages.contains { $0.id == "local" })
        XCTAssertEqual(frames.first?.conversations[0].messages[0].status, .sent)
        let revision = store.memorySnapshot.revision
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "missing", conversationID: "first", text: "ignored"))
        XCTAssertEqual(store.memorySnapshot.revision, revision)
        XCTAssertEqual(first.messages[0].text, "original")
    }

    func testCrossConversationApprovalAndListMergePublishOneCompleteMemoryRevision() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", kind: .system, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var message = makeMessage(id: "approval", seq: 1, kind: .system)
        message.groupInviteApproval = makeGroupInviteApproval(requestID: "request")
        first.messages = [message]
        var second = makeConversation(id: "second", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.messages = [message]
        store.commitConversationSnapshots([first, second])
        var frames: [CapturedConversationMemorySnapshot] = []
        let changes = store.memoryUpdates.dropFirst().sink { frame in
            frames.append(frame.captureMessages(from: store))
            XCTAssertEqual(store.conversations, frame.conversations)
            XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
        }
        defer { changes.cancel() }
        let revision = store.memorySnapshot.revision
        XCTAssertEqual(store.resolveGroupInviteApprovalMessages(requestID: "request", status: "approved"), 2)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].revision, revision + 1)
        XCTAssertEqual(frames[0].conversations.flatMap(\.messages).map { $0.groupInviteApproval?.status }, ["approved", "approved"])
        let remote = try decodeRemoteConversation(#"{"channel_id":"replacement","channel_type":"group","unread_count":3,"last_msg_seq":3,"version":4}"#)
        var replacement = makeConversation(id: "replacement", kind: .group, unread: 3, lastMsgSeq: 3, lastReadSeq: 0)
        replacement.messages = [makeMessage(id: "replacement-message", seq: 3)]
        replacement.messageCoveredThroughSeq = 3
        store.mergeRemoteConversationList(
            entries: [.init(channelID: replacement.id, remote: remote, conversation: replacement)],
            replacing: true, channelIDForConversation: { $0.id }
        )
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1].revision, revision + 2)
        XCTAssertEqual(frames[1].conversations, [replacement])
        XCTAssertEqual(frames[1].conversations[0].messageCoveredThroughSeq, 3)
        XCTAssertEqual(frames[1].alertingUnreadTotal, 3)
        XCTAssertEqual(frames[0].conversations.count, 2)
        XCTAssertNil(store.conversationMessageSnapshot(id: "first"))
    }

    func testMemoryRevisionRetainsMessageOnlyChangesThatReturnToTheOriginalValue() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.messages = [makeMessage(id: "m1", seq: 1)]
        store.commitConversationSnapshots([conversation])
        let revision = store.memorySnapshot.revision
        var frames: [CapturedConversationMemorySnapshot] = []
        var presentation = ConversationSnapshotPresentation(current: [conversation.id: conversation])
        let pages = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { rows in
            presentation.observe(current: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }))
        }
        let changes = store.memoryUpdates.dropFirst().sink { frames.append($0.captureMessages(from: store)) }
        defer { changes.cancel(); pages.cancel() }
        XCTAssertTrue(store.setMessagePinned(messageID: "m1", conversationID: "c1", pinned: true))
        XCTAssertTrue(store.setMessagePinned(messageID: "m1", conversationID: "c1", pinned: false))
        XCTAssertEqual(store.conversationMessageSnapshots(), [conversation])
        XCTAssertEqual(frames.map(\.revision), [revision + 1, revision + 2])
        XCTAssertEqual(frames.map { $0.conversations[0].messages[0].isPinned }, [true, false])
        let current = [conversation.id: store.conversationMessageSnapshots()[0]]
        XCTAssertFalse(presentation.accept(conversation.id, current: current))
        XCTAssertEqual(presentation.restarting(current: current), current)
        XCTAssertEqual(presentation.completing(current: current), current)
    }
}
// WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

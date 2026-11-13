import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
@testable import WenDaTong

// WDT_IOS1_REFACTOR_PAGED_SNAPSHOT_RECOVERY_CHARACTERIZATION_20261110_BEGIN
extension DomainStoreTests {
    func testPagedExpectationOwnsOnlyPageChangesAndRetainsUnseenLocalChangesAcrossRestart() {
        var rows = ["missing": 0, "local": 0, "toggle": 0, "unseen": 0]
        var presentation = ConversationSnapshotPresentation(current: rows)
        rows["local"] = 9 // Exercise the value-comparison fallback as well as events.
        XCTAssertTrue(presentation.accept("page", current: rows))
        let previous = rows
        rows["missing"] = 1 // Derived normalization performed by applying this page.
        rows["page"] = 1
        presentation.didApply(["page"], current: rows, previous: previous)
        rows["toggle"] = 1
        presentation.observe(current: rows)
        rows["toggle"] = 0
        presentation.observe(current: rows)
        rows["unseen"] = 8 // No observer call: restart must also honor the fallback.
        XCTAssertEqual(presentation.completing(current: rows), ["local": 9, "toggle": 0, "unseen": 8, "page": 1])
        rows = presentation.restarting(current: rows)
        XCTAssertEqual(rows, ["missing": 1, "local": 9, "toggle": 0, "unseen": 8])
        XCTAssertFalse(presentation.accept("local", current: rows))
        XCTAssertFalse(presentation.accept("toggle", current: rows))
        XCTAssertFalse(presentation.accept("unseen", current: rows))
        XCTAssertEqual(presentation.completing(current: rows), ["local": 9, "toggle": 0, "unseen": 8])
    }

    func testPagedSnapshotLastPagePublishesBeforeCompletionFenceRejectsCleanupAndPersistence() async throws {
        let fixture = try await makePagedCommitFixture()
        addTeardownBlock { await fixture.cleanUp() }
        let state = fixture.state
        let revision = state.localMessageProjectionRevision
        var lastPageWasPublished = false
        let changes = state.conversationStore.memoryUpdates.sink { frame in
            guard !lastPageWasPublished, frame.conversations.contains(where: { $0.id == "last" }) else { return }
            lastPageWasPublished = true
            XCTAssertEqual(state.conversationStore.conversations, frame.conversations)
            XCTAssertTrue(frame.conversations.contains { $0.id == "first" })
            XCTAssertTrue(frame.conversations.contains { $0.id == "missing" })
            _ = fixture.engine.beginRemoteSnapshotRefresh()
        }
        defer { changes.cancel() }
        let refresh = Task { await state.refreshRemoteSnapshot(silent: true, force: true) }
        defer { refresh.cancel() }
        try await waitForPagedCheckpoint { await fixture.transport.gate.isWaiting }
        XCTAssertNotNil(state.conversationStore.conversationMessageSnapshot(id: "first"), "page one must already be visible")
        XCTAssertNil(state.conversationStore.conversationMessageSnapshot(id: "last"))
        await fixture.transport.gate.release()
        let completed = await refresh.value
        XCTAssertFalse(completed)
        XCTAssertTrue(lastPageWasPublished)
        XCTAssertNotNil(state.conversationStore.conversationMessageSnapshot(id: "last"))
        XCTAssertNotNil(state.conversationStore.conversationMessageSnapshot(id: "missing"))
        XCTAssertEqual(fixture.engine.remoteConversationSyncCommand(forceFull: false).requestedVersion, 7)
        XCTAssertEqual(state.localMessageProjectionRevision, revision, "completion must not schedule its full SQLite projection")
        XCTAssertFalse(state.hasLoadedRemoteSnapshot)
        XCTAssertTrue(state.isConversationSnapshotPartial)
        let floor = try await fixture.persistence.projectionRevisionFloor(ticket: fixture.ticket)
        XCTAssertEqual(floor, revision)
        let persisted = try await fixture.persistence.activateAndLoad(context: fixture.context, sessionGeneration: 1)
        XCTAssertEqual(Set(persisted.conversations.map(\.id)), ["c1", "missing"])
        XCTAssertEqual(fixture.transport.pageCursors, ["", "next"])
    }

    func testPagedSnapshotProtectsMessageOnlyMutationBeforeLatePage() async throws {
        try await assertPagedMessageMutationSurvives(restart: false)
    }

    func testPagedSnapshotProtectsMessageOnlyMutationAcrossCursorRestart() async throws {
        try await assertPagedMessageMutationSurvives(restart: true)
    }

    // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
    func testPagedSnapshotProtectsReentrantMessageChangesDuringPagePublicationAndRestart() async throws {
        for restart in [false, true] {
            try await assertPagedMessageMutationSurvives(restart: restart, duringPublish: true)
        }
    }
    // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END

    private func assertPagedMessageMutationSurvives(restart: Bool, duringPublish: Bool = false) async throws {
        for changesBack in [false, true] {
            let fixture = try await makePagedCommitFixture(restart: restart, lastChannel: "c1")
            addTeardownBlock { await fixture.cleanUp() }
            let state = fixture.state
            let add = try decodeRemoteExtra(#"{"message_id":"m1","channel_id":"c1","channel_type":"group","operator_uid":"reader","extra_type":"reaction","emoji":"ok","action":"add"}"#)
            let remove = try decodeRemoteExtra(#"{"message_id":"m1","channel_id":"c1","channel_type":"group","operator_uid":"reader","extra_type":"reaction","emoji":"ok","action":"remove"}"#)
            if changesBack {
                XCTAssertTrue(state.conversationStore.applyMessageReactionDetail(add, makeReactionDetail: makeReactionDetail(from:id:)))
            }
            var injected = false
            let reentrant = state.conversationStore.memoryUpdates.dropFirst().sink { frame in
                guard duringPublish, !injected, frame.conversations.contains(where: { $0.id == "first" }) else { return }
                injected = true
                if changesBack {
                    XCTAssertTrue(state.conversationStore.applyMessageReactionDetail(remove, makeReactionDetail: self.makeReactionDetail(from:id:)))
                }
                XCTAssertTrue(state.conversationStore.applyMessageReactionDetail(add, makeReactionDetail: self.makeReactionDetail(from:id:)))
            }
            defer { reentrant.cancel() }
            let refresh = Task { await state.refreshRemoteSnapshot(silent: true, force: true) }
            defer { refresh.cancel() }
            try await waitForPagedCheckpoint { await fixture.transport.gate.isWaiting }
            if duringPublish { XCTAssertTrue(injected) }
            XCTAssertNotNil(state.conversationStore.conversationMessageSnapshot(id: "first"))
            XCTAssertEqual(fixture.transport.pageCursors, ["", "next"])
            let before = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: "c1"))
            if !duringPublish {
                if changesBack {
                    XCTAssertTrue(state.conversationStore.applyMessageReactionDetail(remove, makeReactionDetail: makeReactionDetail(from:id:)))
                }
                XCTAssertTrue(state.conversationStore.applyMessageReactionDetail(add, makeReactionDetail: makeReactionDetail(from:id:)))
            }
            let mutated = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: "c1"))
            XCTAssertEqual(mutated.messages[0].reactionDetails.map(\.id), ["m1_reader_ok"])
            if changesBack { XCTAssertEqual(mutated, before, "value comparison alone cannot detect this mutation") }
            await fixture.transport.gate.release()
            let completed = await refresh.value
            XCTAssertTrue(completed)
            let current = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: "c1"))
            XCTAssertEqual(current.messages[0].reactionDetails, mutated.messages[0].reactionDetails)
            XCTAssertEqual(current.lastMessage, "original", "the protected row must reject the late server summary")
            XCTAssertEqual(current.title, before.title)
            XCTAssertNil(state.conversationStore.conversationMessageSnapshot(id: "missing"), "successful completion still cleans absent rows")
            XCTAssertFalse(state.isConversationSnapshotPartial)
            XCTAssertEqual(fixture.engine.remoteConversationSyncCommand(forceFull: false).requestedVersion, restart ? 19 : 11)
            XCTAssertEqual(fixture.transport.pageCursors, restart ? ["", "next", ""] : ["", "next"])
            let scheduled = state.localMessageProjectionRevision
            XCTAssertGreaterThan(scheduled, 1)
            try await fixture.waitForDurableRevision(scheduled)
            let persisted = try await fixture.persistence.activateAndLoad(context: fixture.context, sessionGeneration: 1)
            XCTAssertEqual(Set(persisted.conversations.map(\.id)), Set(state.conversationStore.conversationMessageSnapshots().map(\.id)))
            XCTAssertFalse(persisted.conversations.contains { $0.id == "missing" })
            XCTAssertEqual(current.messages[0].readBy, before.messages[0].readBy)
        }
    }

    // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_BEGIN
    func testEditedMessageRestoresBodyAndRevisionThroughOfflineAppStateRestart() async throws {
        let fixture = try await makePagedCommitFixture(direct: true)
        addTeardownBlock { await fixture.cleanUp() }
        let edited = try await applyAndPersistFixtureEdit(fixture)
        _ = try await restoreFixtureEdit(context: fixture.context, root: fixture.root,
            expectedBody: edited.text, expectedRevision: edited.editRevision, expectedEdited: edited.isEdited)
        XCTAssertTrue(fixture.transport.pageCursors.isEmpty)
    }

    func testWriteEditedMessageBeforeOfflineProcessRestart() async throws {
        let run = try OfflineEditProcessRun()
        let context = offlineEditContext(for: run)
        guard !FileManager.default.fileExists(atPath: run.root.path) else {
            XCTFail("The writer requires a fresh fixture directory")
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: run.root, withIntermediateDirectories: false)
        addTeardownBlock { run.defaults.removePersistentDomain(forName: run.suite) }
        let fixture = try await makePagedCommitFixture(direct: true, offlineRun: run)
        addTeardownBlock { await fixture.cleanUp() }
        let edited = try await applyAndPersistFixtureEdit(fixture)
        XCTAssertTrue(fixture.transport.requestPaths.isEmpty)
        XCTAssertTrue(run.realtime.requestedURLs().isEmpty)
        let identity = try run.archiveIdentity(context: context)
        let writer = OfflineEditProcessWriter(identity: identity, pid: ProcessInfo.processInfo.processIdentifier)
        try JSONEncoder().encode(writer).write(to: run.writerReceipt, options: .atomic)
        try addOfflineEditProcessEvidence("write", writer: writer, message: edited,
            httpRequests: fixture.transport.requestPaths.count, run: run)
    }

    func testRestoreEditedMessageAfterOfflineProcessRestart() async throws {
        let run = try OfflineEditProcessRun()
        addTeardownBlock { run.defaults.removePersistentDomain(forName: run.suite) }
        let context = offlineEditContext(for: run)
        let writer = try JSONDecoder().decode(OfflineEditProcessWriter.self, from: Data(contentsOf: run.writerReceipt))
        let identity = try run.archiveIdentity(context: context)
        XCTAssertEqual(identity, writer.identity, "restore must open the writer's SQLite file and scope")
        XCTAssertNotEqual(ProcessInfo.processInfo.processIdentifier, writer.pid, "restore requires a fresh test-host process")
        let (message, requests) = try await restoreFixtureEdit(context: context, root: run.root,
            expectedBody: "durable edit", expectedRevision: 2, expectedEdited: true, offlineRun: run)
        try addOfflineEditProcessEvidence("restore", writer: writer, message: message, httpRequests: requests, run: run)
    }

    private func offlineEditContext(for run: OfflineEditProcessRun) -> IMAPIContext {
        var context = makeAuthenticatedAPIContext(accountID: "paged-" + run.id.uuidString)
        context.deviceID = run.id.uuidString
        return context
    }

    private func addOfflineEditProcessEvidence(_ phase: String, writer: OfflineEditProcessWriter,
        message: ChatMessage, httpRequests: Int, run: OfflineEditProcessRun) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "phase": phase, "pid": ProcessInfo.processInfo.processIdentifier, "writerPID": writer.pid,
            "runID": run.id.uuidString, "scopeHash": writer.identity.scopeHash,
            "sqlitePath": run.root.appendingPathComponent(writer.identity.relativePath).path,
            "relativeSQLitePath": writer.identity.relativePath,
            "sqliteInode": writer.identity.inode, "messageID": message.id, "body": message.text, "editRevision": message.editRevision,
            "isEdited": message.isEdited, "httpRequests": httpRequests, "realtimeRequests": run.realtime.requestedURLs().count,
        ])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "offline-edit-process-" + phase
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func applyAndPersistFixtureEdit(_ fixture: PagedCommitFixture) async throws -> ChatMessage {
        let state = fixture.state
        let channel = "uid-1:uid-2"
        let original = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: channel)?.messages.first)
        XCTAssertEqual(original.editRevision, 0)
        let extra = try decodeRemoteExtra(#"{"message_id":"m1","channel_id":"uid-1:uid-2","channel_type":"direct","channel_seq":1,"extra_type":"edit","payload":{"edit_revision":2,"payload":{"text":"durable edit","edit_revision":2}}}"#)
        state.applyRemoteMessageExtra(extra, fromRealtime: false)
        let edited = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: channel)?.messages.first)
        XCTAssertEqual(edited.text, "durable edit")
        XCTAssertEqual(edited.editRevision, 2)
        XCTAssertTrue(edited.isEdited)
        let scheduled = state.localMessageProjectionRevision
        XCTAssertGreaterThan(scheduled, 1, "the real edit entry must schedule its existing persistence path")
        try await fixture.waitForDurableRevision(scheduled)
        let persisted = try await fixture.persistence.activateAndLoad(context: fixture.context, sessionGeneration: 1)
        let durable = try XCTUnwrap(persisted.conversations.first { $0.id == channel }?.messages.first)
        XCTAssertEqual(durable.text, edited.text)
        XCTAssertEqual(durable.editRevision, 2)
        XCTAssertTrue(durable.isEdited)
        await fixture.persistence.detach(ticket: fixture.ticket)
        return edited
    }

    private func restoreFixtureEdit(context: IMAPIContext, root: URL, expectedBody: String,
        expectedRevision: Int64, expectedEdited: Bool, offlineRun: OfflineEditProcessRun? = nil) async throws -> (ChatMessage, Int) {
        let reopened = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"))
        let offline = ControlledPagedSnapshotTransport(results: [])
        let restored = makePagedCommitState(context: context, transport: offline, persistence: reopened,
            cache: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")), engine: DefaultSyncEngine(), offlineRun: offlineRun)
        addTeardownBlock {
            let ticket = await MainActor.run {
                restored.durableOutboxRecoveryTask?.cancel()
                restored.durableReadAckRecoveryTask?.cancel()
                restored.localMessageSessionGeneration &+= 1
                return restored.localMessageTicket
            }
            await reopened.detach(ticket: ticket)
        }
        XCTAssertTrue(restored.conversations.isEmpty)
        let loaded = await restored.applyCachedRemoteSnapshotIfAvailable(context: context)
        XCTAssertTrue(loaded)
        let recovered = try XCTUnwrap(restored.conversationStore.conversationMessageSnapshot(id: "uid-1:uid-2")?.messages.first)
        XCTAssertEqual(recovered.text, expectedBody)
        XCTAssertEqual(recovered.editRevision, expectedRevision)
        XCTAssertEqual(recovered.isEdited, expectedEdited)
        XCTAssertTrue(restored.hasLoadedRemoteSnapshot)
        XCTAssertTrue(offline.requestPaths.isEmpty, "offline restore must not obtain its edit from a network response")
        if let offlineRun {
            let outbox = restored.durableOutboxRecoveryTask
            let ack = restored.durableReadAckRecoveryTask
            outbox?.cancel()
            ack?.cancel()
            await outbox?.value
            await ack?.value
            XCTAssertTrue(offline.requestPaths.isEmpty)
            XCTAssertTrue(offlineRun.realtime.requestedURLs().isEmpty)
        }
        return (recovered, offline.requestPaths.count)
    }
    // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_END

    private func makePagedCommitFixture(restart: Bool = false, lastChannel: String = "last", direct: Bool = false, codec: (any WireCodec)? = nil,
        offlineRun: OfflineEditProcessRun? = nil) async throws -> PagedCommitFixture { // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111
        // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_BEGIN
        let root = offlineRun?.root ?? FileManager.default.temporaryDirectory.appendingPathComponent("paged-commit-" + UUID().uuidString)
        var context: IMAPIContext
        if let offlineRun {
            context = offlineEditContext(for: offlineRun)
        } else {
            context = makeAuthenticatedAPIContext(accountID: "paged-" + UUID().uuidString)
            context.deviceID = UUID().uuidString
        }
        // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_END
        let results = [try pagedCommitResponse(channels: ["first"], more: true, version: 11)]
            + (restart ? [HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"conversation_page_cursor_expired","message":"expired"}}"#.utf8),
                isHTTPResponse: true, statusCode: 410), try pagedCommitResponse(channels: ["first", lastChannel], more: false, version: 19)]
                : [try pagedCommitResponse(channels: [lastChannel], more: false, version: 11)])
        let transport = ControlledPagedSnapshotTransport(results: results)
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches"))
        let engine = DefaultSyncEngine()
        let state = makePagedCommitState(context: context, transport: transport, persistence: persistence,
            cache: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")), engine: engine, codec: codec, offlineRun: offlineRun) // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111
        state.suppressCurrentUserIdentityPersistence = true
        state.setCurrentUser(makeUser(id: context.imUID!))
        let channel = direct ? "uid-1:uid-2" : "c1"
        var conversation = makeConversation(id: channel, kind: direct ? .direct : .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.messages = [makeMessage(id: "m1", senderId: "uid-1", seq: 1, status: .sent, isOutgoing: true, text: "original")]
        conversation.lastMessage = "original"
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.firstUnreadSeq = 0
        conversation.firstUnreadMessageID = ""
        conversation.unreadAnchorSeq = 0
        conversation.unreadAnchorState = "none"
        conversation.historyBoundaryConfirmed = true
        conversation.messageCoveredThroughSeq = 1
        if direct { conversation.participants = [makeUser(id: "uid-2")] }
        var missing = makeConversation(id: "missing", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        missing.historyBoundaryConfirmed = true
        state.conversationStore.commitConversationSnapshots(direct ? [conversation] : [conversation, missing])
        let ticket = try await persistence.ensureTicket(context: context, sessionGeneration: state.localMessageSessionGeneration)
        state.localMessageTicket = ticket
        state.localMessageProjectionRevision = 1
        _ = try await persistence.persist(ticket: ticket,
            snapshots: state.conversationStore.conversationMessageSnapshots().map { state.localMessageSnapshot(from: $0, actorID: context.imUID!) }, source: .history, revision: 1)
        engine.finishRemoteConversationSync(engine.remoteConversationSyncCommand(forceFull: false), responseVersion: 7)
        XCTAssertTrue(transport.requestPaths.isEmpty)
        return PagedCommitFixture(state: state, persistence: persistence, transport: transport, engine: engine,
            context: context, root: root, ticket: ticket)
    }

    // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_BEGIN
    private func makePagedCommitState(context: IMAPIContext, transport: ControlledPagedSnapshotTransport,
        persistence: MessagePersistenceCoordinator, cache: SnapshotCache, engine: DefaultSyncEngine,
        codec: (any WireCodec)? = nil, offlineRun: OfflineEditProcessRun? = nil) -> AppState {
        let defaults = offlineRun?.defaults ?? .standard
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport, wireCodec: codec ?? JSONWireCodec(),
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults), startupContext: offlineRun.map { _ in context })
        let realtime = offlineRun?.realtime ?? FakeRealtimeWebSocketTransport(socket: FakeRealtimeWebSocketTask())
        return AppState(api: api, pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            realtimeClient: RealtimeClient(transport: realtime, networkMonitorFactory: nil),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(), messageStore: cache,
            messagePersistence: persistence, remoteSyncEngine: engine, biometricDefaults: defaults,
            rememberedLoginCredentialStore: offlineRun == nil ? KeychainRememberedLoginCredentialStore() : RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: offlineRun == nil ? UserDefaultsRememberedLoginPreferenceStore() : RecordingRememberedLoginPreferenceStore(),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            registrationSessionStore: offlineRun == nil ? IMKeychainSessionStore(registrationRecovery: true) : InMemoryProtectedSessionStore(),
            apiContextOverride: context)
    }
    // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_END

    private func pagedCommitResponse(channels: [String], more: Bool, version: Int) throws -> HTTPTransportResult {
        let rows: [[String: Any]] = channels.map { id in
            ["channel_id": id, "channel_type": "group", "display_name": "server " + id, "last_msg_seq": 1,
             "last_read_seq": 0, "unread_count": 0, "history_visible_from_seq": 1, "history_limited": false,
             "last_message": ["message_id": id == "c1" ? "m1" : id + "-m1", "channel_id": id, "channel_type": "group",
                 "channel_seq": 1, "from_uid": "uid-1", "content_type": "text", "payload": ["text": "server overwrite"],
                 "created_at": "2026-11-09T00:00:00Z"]]
        }
        var data: [String: Any] = ["conversations": rows, "has_more": more, "snapshot_id": "snapshot-\(version)", "snapshot_version": version]
        if more { data["next_cursor"] = "next" }
        return HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": data]), isHTTPResponse: true, statusCode: 200)
    }

    private func waitForPagedCheckpoint(_ condition: @escaping @MainActor () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("real paged snapshot did not reach its controlled checkpoint")
        throw URLError(.timedOut)
    }
}

// WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_BEGIN
private struct OfflineEditProcessWriter: Codable {
    struct Archive: Codable, Equatable {
        let scopeHash: String
        let relativePath: String
        let inode: UInt64
    }

    let identity: Archive
    let pid: Int32
}

private struct OfflineEditProcessRun {
    let id: UUID
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let realtime = FakeRealtimeWebSocketTransport(socket: FakeRealtimeWebSocketTask())

    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["IM4_TEST_OFFLINE_EDIT_RUN_ID"] else {
            throw XCTSkip("Requires the paired test-host runner")
        }
        id = try XCTUnwrap(UUID(uuidString: raw), "The runner must supply a unique fixture ID")
        suite = "IM4OfflineEditProcess-" + id.uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent(suite, isDirectory: true)
    }

    var writerReceipt: URL { root.appendingPathComponent("writer.json") }

    func archiveIdentity(context: IMAPIContext) throws -> OfflineEditProcessWriter.Archive {
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(scope: scope, applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"))
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.databaseURL.path)
        let inode = try XCTUnwrap(attrs[.systemFileNumber] as? NSNumber)
        let prefix = root.standardizedFileURL.path + "/"
        let path = paths.databaseURL.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
        return .init(scopeHash: scope.scopeHash, relativePath: String(path.dropFirst(prefix.count)), inode: inode.uint64Value)
    }
}
// WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_END

@MainActor
private final class PagedCommitFixture {
    let state: AppState
    let persistence: MessagePersistenceCoordinator
    let transport: ControlledPagedSnapshotTransport
    let engine: DefaultSyncEngine
    let context: IMAPIContext
    let root: URL
    let ticket: LocalMessageSessionTicket

    init(state: AppState, persistence: MessagePersistenceCoordinator, transport: ControlledPagedSnapshotTransport,
        engine: DefaultSyncEngine, context: IMAPIContext, root: URL, ticket: LocalMessageSessionTicket) {
        self.state = state; self.persistence = persistence; self.transport = transport
        self.engine = engine; self.context = context; self.root = root; self.ticket = ticket
    }

    func waitForDurableRevision(_ revision: Int64) async throws {
        for _ in 0..<500 {
            if try await persistence.projectionRevisionFloor(ticket: ticket) >= revision { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the original scheduled SQLite projection did not become durable")
        throw URLError(.timedOut)
    }

    func cleanUp() async {
        await transport.gate.release()
        engine.reset()
        let outbox = state.durableOutboxRecoveryTask, readAck = state.durableReadAckRecoveryTask
        outbox?.cancel(); readAck?.cancel()
        state.localMessageSessionGeneration &+= 1
        await outbox?.value; await readAck?.value
        await persistence.detach(ticket: state.localMessageTicket)
        await persistence.detach(ticket: ticket)
        // WDT_IOS1_CONVERSATION_FACADE_ACTUAL_764_20261111_BEGIN
        // Untracked projection tasks can still retain a SQLite repository after detach.
        // Keep this fixture-owned UUID temp root until the test process releases them.
        // WDT_IOS1_CONVERSATION_FACADE_ACTUAL_764_20261111_END
    }
}

private actor PagedSnapshotResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class ControlledPagedSnapshotTransport: HTTPTransport, @unchecked Sendable {
    let gate = PagedSnapshotResponseGate()
    private let lock = NSLock()
    private let results: [HTTPTransportResult]
    private var paths: [String] = []
    private var cursors: [String] = []
    private var authorizations: [String] = [] // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110
    init(results: [HTTPTransportResult]) { self.results = results }
    var requestPaths: [String] { lock.withLock { paths } }
    var pageCursors: [String] { lock.withLock { cursors } }
    var pageAuthorizations: [String] { lock.withLock { authorizations } } // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let index: Int? = lock.withLock {
            paths.append(request.url?.path ?? "")
            guard request.url?.path == "/api/im/conversations/page" else { return nil }
            cursors.append(body?["cursor"] as? String ?? "")
            authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "") // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110
            return cursors.count - 1
        }
        guard let index, results.indices.contains(index) else { throw URLError(.notConnectedToInternet) }
        if index == 1 { await gate.wait() }
        return results[index]
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        lock.withLock { paths.append(request.url?.path ?? "") } // WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111
        throw URLError(.notConnectedToInternet)
    }
}
// WDT_IOS1_REFACTOR_PAGED_SNAPSHOT_RECOVERY_CHARACTERIZATION_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_BEGIN
extension DomainStoreTests {
    func testActualPageDecodeSuspensionPreservesMessageOnlyChangeAndCompletion() async throws {
        let release = DispatchSemaphore(value: 0)
        let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec(), beforeConversationPageDecode: { data in
            if String(data: data, encoding: .utf8)?.contains("\"c1\"") == true { release.wait() }
        })
        let fixture = try await makePagedCommitFixture(lastChannel: "c1", codec: codec)
        addTeardownBlock { await fixture.cleanUp() }
        await fixture.transport.gate.release()
        let task = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: true) }
        defer { release.signal(); task.cancel() }
        try await waitForPagedCheckpoint { codec.decodedTypeNames().filter { $0 == "APIEnvelope<RemoteConversationPage>" }.count == 2 }
        XCTAssertNotNil(fixture.state.conversationStore.conversation(id: "first"))
        var metadataEvents = 0
        let subscription = fixture.state.conversationStore.conversationUpdates.dropFirst().sink { _ in metadataEvents += 1 }
        XCTAssertNotNil(fixture.state.conversationStore.updateAttachmentProgress(0.6, messageID: "m1", conversationID: "c1"))
        XCTAssertEqual(metadataEvents, 0); subscription.cancel()
        release.signal()
        let completed = await task.value; XCTAssertTrue(completed)
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshot(id: "c1")?.messages.first?.attachmentTransferProgress, 0.6)
        XCTAssertEqual(fixture.engine.remoteConversationSyncCommand(forceFull: false).requestedVersion, 11)
        XCTAssertTrue(fixture.state.hasLoadedRemoteSnapshot)
        XCTAssertFalse(fixture.state.isConversationSnapshotPartial)
        XCTAssertEqual(fixture.transport.pageCursors, ["", "next"])
        XCTAssertTrue(codec.decodedOnMainThread().allSatisfy { !$0 })
    }

    func testActualPageDecodeSuspensionRestartsSameScopeCredentialRotation() async throws {
        let release = DispatchSemaphore(value: 0)
        let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec(), beforeConversationPageDecode: { data in
            if String(data: data, encoding: .utf8)?.contains("first") == true { release.wait() }
        })
        let fixture = try await makePagedCommitFixture(codec: codec)
        addTeardownBlock { await fixture.cleanUp() }
        await fixture.transport.gate.release()
        let task = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: true) }
        defer { release.signal(); task.cancel() }
        try await waitForPagedCheckpoint { codec.decodedTypeNames().contains("APIEnvelope<RemoteConversationPage>") }
        var rotated = fixture.state.apiContext
        rotated.imToken = "synthetic-page-rotated-token"; rotated.credentialRevision += 1
        fixture.state.apiContext = rotated
        release.signal()
        let completed = await task.value; XCTAssertTrue(completed)
        XCTAssertNil(fixture.state.conversationStore.conversation(id: "first"))
        XCTAssertNotNil(fixture.state.conversationStore.conversation(id: "last"))
        XCTAssertEqual(fixture.transport.pageCursors, ["", ""])
        XCTAssertEqual(fixture.transport.pageAuthorizations, ["Bearer " + (fixture.context.imToken ?? ""), "Bearer synthetic-page-rotated-token"])
        XCTAssertEqual(fixture.engine.remoteConversationSyncCommand(forceFull: false).requestedVersion, 11)
    }

    func testActualPageDecodeSuspensionRejectsOldScopeBeforePublication() async throws {
        let release = DispatchSemaphore(value: 0)
        let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec(), beforeConversationPageDecode: { _ in release.wait() })
        let fixture = try await makePagedCommitFixture(codec: codec)
        addTeardownBlock { await fixture.cleanUp() }
        let task = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: true) }
        defer { release.signal(); task.cancel() }
        try await waitForPagedCheckpoint { codec.decodedTypeNames().contains("APIEnvelope<RemoteConversationPage>") }
        var replacement = fixture.state.apiContext; replacement.accountID = "different-page-account"
        fixture.state.apiContext = replacement
        release.signal()
        let completed = await task.value; XCTAssertFalse(completed)
        XCTAssertNil(fixture.state.conversationStore.conversation(id: "first"))
        XCTAssertNil(fixture.state.conversationStore.conversation(id: "last"))
        XCTAssertFalse(fixture.state.hasLoadedRemoteSnapshot)
        XCTAssertEqual(fixture.transport.pageCursors, [""])
    }

    func testActualPageDecodeSuspensionKeepsCancellationBeforePublication() async throws {
        let release = DispatchSemaphore(value: 0)
        let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec(), beforeConversationPageDecode: { _ in release.wait() })
        let fixture = try await makePagedCommitFixture(codec: codec)
        addTeardownBlock { await fixture.cleanUp() }
        let task = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: true) }
        defer { release.signal(); task.cancel() }
        try await waitForPagedCheckpoint { codec.decodedTypeNames().contains("APIEnvelope<RemoteConversationPage>") }
        task.cancel(); release.signal()
        let completed = await task.value; XCTAssertFalse(completed)
        XCTAssertNil(fixture.state.conversationStore.conversation(id: "first"))
        XCTAssertEqual(fixture.engine.remoteConversationSyncCommand(forceFull: false).requestedVersion, 7)
        XCTAssertEqual(fixture.transport.pageCursors, [""])
    }
}
// WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_END

import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import Network
import XCTest
@testable import WenDaTong

// These tests enter the real HTTP DTO -> AppState sidecar -> Store projection chain.
// Every request is intercepted in-process; persistence is restricted to a unique temporary root.
extension RealtimeTransportTests {
    func testReceiptRecoveryEmptyItemsWatermarkUpdatesOnlyCapturedOwnSentDirectMessages() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [
            fixture.message(10),
            fixture.message(11, outgoing: false),
            fixture.message(12, sender: "foreign"),
            fixture.message(13, status: .sending),
            fixture.message(14, status: .failed),
            fixture.message(0)
        ])])
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(100) }

        await fixture.sync()

        let messages = try XCTUnwrap(fixture.state.conversationStore.conversationMessageSnapshots().first?.messages)
        XCTAssertEqual(messages.map(\.status), [.read, .sent, .sent, .sending, .failed, .sent])
        XCTAssertTrue(messages[0].readStateKnown)
        XCTAssertTrue(messages[0].deliveryStateKnown)
        XCTAssertFalse(messages[0].canViewReadDetails)
        XCTAssertTrue(messages[0].readBy.isEmpty)
        XCTAssertNil(messages[0].readCount, "anonymous recovery must not invent reader/count details")
        XCTAssertEqual(fixture.transport.bodies.count, 1)
    }

    func testReceiptRecoverySkipsOldHundredRowsUsesReadWindowAndResumesWithinThreeRequestBudget() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: (501...750).map { fixture.message(Int64($0)) })])
        // Model the server's ascending LIMIT before anonymous watermark aggregation.
        fixture.transport.respond = { _, body in
            let after = (body["after_seq"] as? NSNumber)?.int64Value ?? -1
            XCTAssertEqual(body["limit"] as? Int, 100)
            XCTAssertEqual(body["receipt_type"] as? String, after == 0 ? "" : "read")
            return Self.anonymousReceiptResult(min(after + 100, 750))
        }

        await fixture.sync()
        XCTAssertEqual(fixture.transport.bodies.count, 3, "one baseline plus at most two pending windows")
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages.filter { $0.status == .read }.count, 200)
        await fixture.sync()
        XCTAssertTrue(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages.allSatisfy { $0.status == .read })
        XCTAssertEqual(fixture.transport.bodies.compactMap { ($0["after_seq"] as? NSNumber)?.int64Value }, [0, 500, 600, 0, 700])
    }

    func testReceiptRecoveryNoProgressStopsWithoutSpinningAndCanRecoverOnNextExistingSchedule() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(501)])])
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(0) }
        await fixture.sync()
        XCTAssertEqual(fixture.transport.bodies.count, 2)
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .sent)
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(501) }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .read)
        XCTAssertEqual(fixture.transport.bodies.count, 3)
    }

    func testReceiptRecoveryPartialFailureKeepsProgressAndReleasesInFlightForRetry() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(501), fixture.message(601)])])
        fixture.transport.respond = { index, _ in
            if index == 2 { throw URLError(.notConnectedToInternet) }
            return Self.anonymousReceiptResult(index == 0 ? 100 : 501)
        }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages.map(\.status), [.read, .sent])
        XCTAssertEqual(fixture.transport.bodies.count, 3)
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(601) }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages.map(\.status), [.read, .read])
        XCTAssertEqual(fixture.transport.bodies.count, 4)
    }

    func testReceiptRecoveryOldHighWatermarkDoesNotContaminateMessageArrivingDuringRequestOrLater() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
        fixture.transport.respond = { _, _ in
            fixture.state.conversationStore.mutateStoredConversation(at: 0) { $0.messages.append(fixture.message(11)) }
            return Self.anonymousReceiptResult(999)
        }
        await fixture.sync()
        fixture.state.conversationStore.mutateStoredConversation(at: 0) { $0.messages.append(fixture.message(12)) }
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages.map(\.status), [.read, .sent, .sent])
        XCTAssertEqual(fixture.transport.bodies.count, 1)
    }

    func testReceiptRecoveryLateResponseRejectsRefreshGenerationAndScopeChanges() async throws {
        for change in ["generation", "tenant", "app", "account"] {
            let fixture = ReceiptRecoveryFixture()
            addTeardownBlock { await fixture.cleanUp() }
            fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
            fixture.transport.respond = { _, _ in
                if change == "generation" {
                    _ = fixture.engine.beginRemoteSnapshotRefresh()
                } else {
                    fixture.state.overrideAPIContextForTesting(fixture.context(
                        tenant: change == "tenant" ? "other-tenant" : nil,
                        app: change == "app" ? "other-app" : nil,
                        account: change == "account" ? "other-account" : nil
                    ))
                }
                return Self.anonymousReceiptResult(100)
            }
            await fixture.sync()
            XCTAssertFalse(fixture.state.conversationStore.conversationMessageSnapshots().flatMap(\.messages).contains { $0.status == .read }, change)
            XCTAssertEqual(fixture.transport.bodies.count, 1, change)
        }
    }

    func testReceiptRecoveryLateResponseRejectsReplacedChannelAndChangedCapturedIdentity() async throws {
        for change in ["channel", "id", "sequence", "sender", "incoming", "removed"] {
            let fixture = ReceiptRecoveryFixture()
            addTeardownBlock { await fixture.cleanUp() }
            fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
            fixture.transport.respond = { _, _ in
                var replacement = fixture.message(change == "sequence" ? 9 : 10,
                                                  sender: change == "sender" ? "foreign" : "self",
                                                  outgoing: change != "incoming",
                                                  id: change == "id" ? "replacement" : nil)
                replacement.text = "local fixture only"
                fixture.state.conversationStore.commitConversationSnapshots(change == "removed" ? [] : [fixture.conversation(
                    channel: change == "channel" ? "other:self" : "peer:self", messages: [replacement]
                )])
                return Self.anonymousReceiptResult(100)
            }
            await fixture.sync()
            XCTAssertFalse(fixture.state.conversationStore.conversationMessageSnapshots().flatMap(\.messages).contains { $0.status == .read }, change)
        }
    }

    func testReceiptRecoveryResetRejectsOldResponseAndOldDeferCannotReleaseNewClaim() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
        let replacementStarted = expectation(description: "replacement request owns a new receipt claim")
        var releaseReplacement: CheckedContinuation<Void, Never>?
        var replacementTask: Task<Void, Never>?
        fixture.transport.respond = { index, _ in
            if index == 0 {
                fixture.state.conversationStore.reset()
                fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
                replacementTask = Task { await fixture.sync() }
                await self.fulfillment(of: [replacementStarted], timeout: 2)
                return Self.anonymousReceiptResult(100)
            }
            if index == 1 {
                await withCheckedContinuation { continuation in
                    releaseReplacement = continuation
                    replacementStarted.fulfill()
                }
            }
            return Self.anonymousReceiptResult(10)
        }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .sent, "old response must not enter the reset store")
        XCTAssertEqual(fixture.transport.bodies.count, 2)
        await fixture.sync()
        XCTAssertEqual(fixture.transport.bodies.count, 2, "old defer must not clear the replacement in-flight claim")
        releaseReplacement?.resume()
        await replacementTask?.value
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .read)
    }

    func testReceiptRecoveryExistingConversationSidecarScheduleRunsWithoutWebSocketOrHistoryArrival() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
        let receiptApplied = expectation(description: "existing sidecar schedule projected anonymous read")
        let observer = fixture.state.conversationStore.memoryUpdates.map { _ in fixture.state.conversationStore.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { conversations in // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            if conversations.first?.messages.first?.status == .read { receiptApplied.fulfill() }
        }
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(10) }
        fixture.state.syncReadReceiptsIfNeeded("peer:self")
        await fulfillment(of: [receiptApplied], timeout: 2)
        XCTAssertEqual(fixture.transport.bodies.count, 1)
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .read)
        try await fixture.waitForDurableRead()
        withExtendedLifetime(observer) {}
    }

    func testReceiptRecoveryDisabledAndGroupIgnoreAnonymousWatermarkButKeepDeliveryBaseline() async throws {
        for mode in ["disabled-flag", "disabled-status", "group"] {
            let fixture = ReceiptRecoveryFixture()
            addTeardownBlock { await fixture.cleanUp() }
            let kind: ConversationKind = mode == "group" ? .group : .direct
            fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(kind: kind, messages: [fixture.message(10)])])
            fixture.transport.respond = { _, _ in
                var result = Self.anonymousReceiptResult(100)
                result["items"] = [Self.receiptItem(sequence: 10, type: "delivered", channelType: mode == "group" ? "group" : "direct")]
                if mode == "disabled-flag" { result["read_receipts_enabled"] = false }
                if mode == "disabled-status" { result["feature_status"] = "disabled" }
                return result
            }
            await fixture.sync(kind: kind)
            let message = try XCTUnwrap(fixture.state.conversationStore.conversationMessageSnapshots().first?.messages.first)
            XCTAssertEqual(message.status, .sent, mode)
            XCTAssertTrue(message.deliveryStateKnown, mode)
            XCTAssertFalse(message.readStateKnown, mode)
            XCTAssertEqual(fixture.transport.bodies.count, 1, mode)
        }
    }

    func testReceiptRecoveryDeliveryOnlyAndOutOfOrderReceiptsCannotDowngradeRead() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
        fixture.transport.respond = { _, _ in
            ["items": [Self.receiptItem(sequence: 10, type: "delivered")]]
        }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .sent)
        XCTAssertTrue(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].deliveryStateKnown)
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(10) }
        await fixture.sync()
        var publications = 0
        let observer = fixture.state.conversationStore.memoryUpdates.map { _ in fixture.state.conversationStore.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { _ in publications += 1 } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        fixture.transport.respond = { _, _ in
            ["items": [Self.receiptItem(sequence: 10, type: "delivered")], "read_up_to_seq": 1]
        }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .read)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observer) {}
    }

    func testReceiptRecoveryDuplicateDoesNotPublishOrWriteAndReadSurvivesColdCacheLoad() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(10) }
        await fixture.sync()
        let before = try fixture.databaseBytes()
        XCTAssertFalse(before.isEmpty, "first semantic receipt change must persist without a message arrival")
        var publications = 0
        let observer = fixture.state.conversationStore.memoryUpdates.map { _ in fixture.state.conversationStore.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { _ in publications += 1 } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        await fixture.sync()
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(try fixture.databaseBytes(), before, "duplicate must not cause a SQLite/WAL write")
        withExtendedLifetime(observer) {}

        let reopened = MessagePersistenceCoordinator(applicationSupportBase: fixture.root.appendingPathComponent("support"), cachesBase: fixture.root.appendingPathComponent("caches"))
        let loaded = try await reopened.activateAndLoad(context: fixture.context(), sessionGeneration: 1, conversationLimit: 10, messagesPerConversation: 100)
        let persisted = try XCTUnwrap(loaded.conversations.first { $0.id == "peer:self" }?.messages.first)
        XCTAssertEqual(persisted.status, MessageDelivery.read.rawValue)
        XCTAssertTrue(persisted.readStateKnown)
        XCTAssertEqual(persisted.deliveryStateKnown, true)
        XCTAssertFalse(persisted.canViewReadDetails)
        XCTAssertTrue(persisted.readBy.isEmpty)
        await reopened.detach(ticket: loaded.ticket)
    }

    func testReceiptRealtimeRawEnvelopeKeepsSenderGuardAndDuplicateIsNoOp() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.commitConversationSnapshots([fixture.conversation(messages: [fixture.message(10)])])
        let callback = try XCTUnwrap(fixture.client.onEnvelope)
        for sender in ["", "foreign"] {
            callback(try Self.receiptEnvelope(sender: sender))
            XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .sent, "missing/foreign sender must not pass the WS privacy guard")
        }
        callback(try Self.receiptEnvelope(sender: "self"))
        XCTAssertEqual(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .read)
        XCTAssertTrue(fixture.state.conversationStore.conversationMessageSnapshots()[0].messages[0].readBy.isEmpty)
        var publications = 0
        let observer = fixture.state.conversationStore.memoryUpdates.map { _ in fixture.state.conversationStore.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { _ in publications += 1 } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        callback(try Self.receiptEnvelope(sender: "self"))
        XCTAssertEqual(publications, 0)
        try await fixture.waitForDurableRead()
        withExtendedLifetime(observer) {}
    }

    private static func anonymousReceiptResult(_ watermark: Int64) -> [String: Any] {
        ["items": [], "read_up_to_seq": watermark, "read_receipts_enabled": true, "can_view_read_receipt_details": false]
    }

    private static func receiptItem(sequence: Int64, type: String, channelType: String = "direct", sender: String = "self") -> [String: Any] {
        ["channel_id": "peer:self", "channel_type": channelType, "channel_seq": sequence,
         "from_uid": sender, "receipt_type": type]
    }

    private static func receiptEnvelope(sender: String) throws -> RealtimeEnvelope {
        let data = try JSONSerialization.data(withJSONObject: ["type": "message_receipt", "payload": ["receipt": receiptItem(sequence: 10, type: "read", sender: sender)]])
        return try JSONDecoder().decode(RealtimeEnvelope.self, from: data)
    }
}

@MainActor
private final class ReceiptRecoveryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-recovery-\(UUID().uuidString)", isDirectory: true)
    let scopeID = "receipt-fixture-\(UUID().uuidString)"
    let routeDefaultsSuite = "RealtimeTransportTests.routes.\(UUID().uuidString)"
    lazy var routeDefaults = UserDefaults(suiteName: routeDefaultsSuite)!
    let transport = ReceiptRecoveryHTTPTransport()
    let engine = DefaultSyncEngine()
    let client = RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: FakeRealtimeWebSocketTask()), networkMonitorFactory: nil)
    lazy var persistence = MessagePersistenceCoordinator(
        applicationSupportBase: root.appendingPathComponent("support"),
        cachesBase: root.appendingPathComponent("caches")
    )
    lazy var state: AppState = {
        _ = engine.beginRemoteSnapshotRefresh()
        let state = AppState(
            api: IMAPIClient(
                platformBase: URL(string: "https://platform.example.test"),
                tenantBase: URL(string: "https://tenant.example.test"),
                imBase: URL(string: "https://im.example.test"),
                httpTransport: transport,
                runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
            ),
            realtimeClient: client,
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: persistence,
            remoteSyncEngine: engine,
            apiContextOverride: context()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        return state
    }()

    func context(tenant: String? = nil, app: String? = nil, account: String? = nil) -> IMAPIContext {
        IMAPIContext(platformToken: nil, accountID: account ?? "receipt-test-account", tenantID: tenant ?? scopeID,
                     imUID: "self", imToken: "unit-test-only", platformAuthSession: nil, tenantAuthSession: nil,
                     appID: app ?? IMAPIContext.canonicalIOSAppID, deviceID: "receipt-test-device")
    }

    func message(_ sequence: Int64, sender: String = "self", outgoing: Bool = true, status: MessageDelivery = .sent, id: String? = nil) -> ChatMessage {
        ChatMessage(id: id ?? "receipt-m\(sequence)", senderId: sender, senderName: "Fixture", text: "synthetic fixture",
                    time: "", channelSeq: sequence, isOutgoing: outgoing, status: status, kind: .text,
                    reactions: [], readBy: [], unreadBy: [], isPinned: false)
    }

    func conversation(channel: String = "peer:self", kind: ConversationKind = .direct, messages: [ChatMessage]) -> ConversationMessageSnapshot {
        ConversationMessageSnapshot(id: channel, title: "Fixture", subtitle: "", kind: kind, lastMessage: "", time: "", unread: 0,
                     isPinned: false, isMuted: false, memberCount: 0, accentHex: 0, participants: [], messages: messages,
                     lastMsgSeq: messages.map(\.channelSeq).max() ?? 0, lastReadSeq: 0)
    }

    func sync(kind: ConversationKind = .direct) async {
        await state.syncReadReceiptsForConversation(channelID: "peer:self", channelType: kind == .direct ? "direct" : "group")
    }

    func databaseBytes() throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where url.lastPathComponent == "messages.sqlite" || url.lastPathComponent == "messages.sqlite-wal" {
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }

    func waitForDurableRead() async throws {
        // Opening a second coordinator while the first is still creating/migrating
        // its SQLite file is not a restart. Wait for the real writer's activation.
        _ = try await persistence.ensureTicket(context: context(), sessionGeneration: 1)
        let reader = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let syncKey = state.conversationStore.messageSidecarSyncKeyContext(
            tenantID: context().tenantID, imUID: context().imUID,
            channelID: "peer:self", channelType: "direct", suffix: "read",
            normalizeChannelID: { channelID, _ in channelID }
        ).syncKey
        for _ in 0..<200 {
            if !state.conversationStore.isMessageReceiptsSyncInFlight(syncKey: syncKey),
               !(try databaseBytes()).isEmpty {
                let loaded = try await reader.activateAndLoad(
                    context: context(), sessionGeneration: 1,
                    conversationLimit: 10, messagesPerConversation: 100
                )
                if loaded.conversations.first(where: { $0.id == "peer:self" })?.messages.first?.status == MessageDelivery.read.rawValue {
                    await reader.detach(ticket: loaded.ticket)
                    return
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("scheduled receipt must finish its durable write before temporary-store cleanup")
    }

    func cleanUp() async {
        transport.respond = nil
        state.setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        client.onEnvelope = nil
        client.disconnect(shouldReconnect: false)
        routeDefaults.removePersistentDomain(forName: routeDefaultsSuite)
        if let bytes = try? databaseBytes(), !bytes.isEmpty {
            let ticket = try? await persistence.ensureTicket(context: context(), sessionGeneration: 1)
            await persistence.detach(ticket: ticket)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ReceiptRecoveryHTTPTransport: HTTPTransport, @unchecked Sendable {
    @MainActor var respond: (@MainActor (Int, [String: Any]) async throws -> [String: Any])?
    @MainActor private(set) var bodies: [[String: Any]] = []

    @MainActor init() {}

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.host == "im.example.test", request.url?.path == "/api/im/message-receipts/sync" else {
            throw URLError(.notConnectedToInternet)
        }
        let data = try await response(for: request)
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200).resolvingResponseURL(request.url)
    }

    @MainActor private func response(for request: URLRequest) async throws -> Data {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let index = bodies.count
        bodies.append(body)
        guard let respond else { throw URLError(.notConnectedToInternet) }
        let result = try await respond(index, body)
        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": result])
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.notConnectedToInternet)
    }
}

// Automated unit seams only: no URLSession traffic or persistent message cache.
final class RTCWireOfflineHTTPTransport: HTTPTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        throw URLError(.notConnectedToInternet)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.notConnectedToInternet)
    }
}

struct RTCWireEmptyMessageStore: MessageStore {
    let schemaVersion = 1
    func scopeKey(for context: IMAPIContext) -> String { "rtc-wire|\(context.tenantID ?? "")" }
    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? { nil }
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool { true }
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool { true }
    func remove(scope: String) {}
    func removeAll() {}
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

import Combine
import XCTest
@testable import WenDaTong

// WDT_IOS1_CALL_ARCHIVE_WRITE_ADMISSION_20261112_BEGIN
extension DomainStoreTests {
    func testCallArchiveInvalidRefreshRejectsBothPollsAndHangupHistory() async throws {
        let context = callArchiveRefreshContext()
        let invalid = invalidCallArchiveContext(context)
        let transport = try CallArchivePollTransport(refresh: [callArchiveRefreshResult(invalid, token: "invalid-device")])
        let entered = expectation(description: "original scope archive load")
        let archived = callArchiveTestRecord("archived-before-refresh")
        let accepted = callArchiveTestRecord("accepted-before-refresh")
        let archive = FencedCallArchive(rows: [:], blockedScope: nil, entered: entered)
        let media = TestVideoMediaClient()
        let system = RecordingRingingSystem(presented: [CallArchivePollTransport.activeCallID])
        defer { archive.release(); transport.releaseAll() }
        let (state, defaults) = try makePolicyIsolatedCallArchiveScopeState(
            context: context, archive: archive, transport: transport, videoMediaClient: media, voiceCallSystem: system
        )
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let key = state.callRecordDataScopeKey(for: context)
        archive.seed([archived], scope: key)
        state.bindCallRecordPersistence(for: context)
        await fulfillment(of: [entered], timeout: 4)
        state.calls = [accepted]
        XCTAssertEqual(state.callStore.calls, [accepted])
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: CallArchivePollTransport.activeCallID)
        state.activeVideoMediaCallID = CallArchivePollTransport.activeCallID

        let events = Task { await state.refreshRTCCallEventsSilently() }
        let calls = Task { await state.refreshRTCCallsSilently() }
        await waitForCallEnd { transport.eventsGate.entered && transport.callsGate.entered }
        XCTAssertTrue(transport.eventsGate.entered && transport.callsGate.entered)
        let generation = state.localMessageSessionGeneration
        _ = await state.refreshStoredAuthSessionIfNeeded(reason: "foreground", silent: true, persistenceDefaults: defaults)
        XCTAssertEqual(state.apiContext.deviceID, invalid.deviceID)
        XCTAssertEqual(state.apiContext.imToken, "invalid-device")
        XCTAssertTrue(state.apiContext.hasIMSession)
        XCTAssertEqual(state.remoteDataScopeKey(for: state.apiContext), state.remoteDataScopeKey(for: context))
        XCTAssertThrowsError(try LocalMessageScope(context: state.apiContext))
        XCTAssertNotEqual(state.localMessageSessionGeneration, generation)
        XCTAssertFalse(state.callStore.hasCallRecordPersistenceBinding)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        var published: [CallRecord] = []
        let observation = state.callStore.$calls.sink { published += $0 }
        defer { observation.cancel() }
        transport.releaseAll()
        let eventsResult = await events.value
        let callsResult = await calls.value
        assertCallArchivePollCancelled(eventsResult)
        assertCallArchivePollCancelled(callsResult)
        XCTAssertEqual(state.activeVoiceCall?.callID, CallArchivePollTransport.activeCallID)
        XCTAssertNil(state.rtcTerminalMarkersByCallID[CallArchivePollTransport.replayedCallID])
        XCTAssertEqual(transport.acknowledgements, [])
        XCTAssertTrue(state.callStore.calls.isEmpty)

        state.endActiveVoiceCall()
        XCTAssertTrue(state.callStore.calls.isEmpty, "The optimistic local hangup has no archive authority")
        await waitForCallEnd { state.activeVoiceCall == nil && !media.stopReasons.isEmpty }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(media.stopReasons, ["user_ending"])
        XCTAssertEqual(system.ends, [.init(callID: CallArchivePollTransport.activeCallID, reason: "local_hangup")])
        XCTAssertEqual(transport.paths.filter { $0.hasSuffix("/hangup") }, [
            "/api/rtc/calls/\(CallArchivePollTransport.activeCallID)/hangup",
        ])
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(transport.acknowledgements, [])
        await assertCallArchiveRestores([accepted, archived], from: archive, key: key)
        XCTAssertEqual(archive.writes, [.init(scope: key, records: [accepted, archived])])
    }

    func testCallArchivePollsKeepSameScopeRenewalAndPreviouslyDispatchedAck() async throws {
        let context = callArchiveRefreshContext()
        let invalid = invalidCallArchiveContext(context)
        let transport = try CallArchivePollTransport(refresh: [
            callArchiveRefreshResult(context, token: "same-scope-renewal"),
            callArchiveRefreshResult(invalid, token: "after-ack"),
        ])
        let entered = expectation(description: "scope restore held through valid poll commits")
        let archived = callArchiveTestRecord("archived")
        let archive = FencedCallArchive(rows: [:], blockedScope: nil, entered: entered)
        defer { archive.release(); transport.releaseAll() }
        let (state, defaults) = try makePolicyIsolatedCallArchiveScopeState(context: context, archive: archive, transport: transport)
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let key = state.callRecordDataScopeKey(for: context)
        archive.seed([archived], scope: key)
        state.bindCallRecordPersistence(for: context)
        await fulfillment(of: [entered], timeout: 4)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: CallArchivePollTransport.activeCallID)
        let scope = try LocalMessageScope(context: context)
        let generation = state.localMessageSessionGeneration

        let calls = Task { await state.refreshRTCCallsSilently() }
        let events = Task { await state.refreshRTCCallEventsSilently() }
        await waitForCallEnd { transport.callsGate.entered && transport.eventsGate.entered }
        XCTAssertTrue(transport.callsGate.entered && transport.eventsGate.entered)
        let renewed = await state.refreshStoredAuthSessionIfNeeded(reason: "foreground", silent: true, persistenceDefaults: defaults)
        XCTAssertTrue(renewed)
        XCTAssertEqual(state.apiContext.imToken, "same-scope-renewal")
        XCTAssertEqual(try LocalMessageScope(context: state.apiContext), scope)
        XCTAssertEqual(state.localMessageSessionGeneration, generation)

        transport.callsGate.release()
        if case .success = await calls.value {} else { XCTFail("Current call-list result should commit") }
        XCTAssertNil(state.activeVoiceCall)
        transport.eventsGate.release()
        await waitForCallEnd { transport.ackGate.entered }
        XCTAssertTrue(transport.ackGate.entered)
        XCTAssertEqual(transport.acknowledgements, [Set(["ringing-notice", "terminal-notice"])])
        let admitted = state.callStore.calls
        XCTAssertEqual(admitted.compactMap(\.callID), [
            CallArchivePollTransport.replayedCallID, CallArchivePollTransport.activeCallID,
        ])
        XCTAssertEqual(admitted.map(\.stateVersion), [3, 3])
        XCTAssertTrue(archive.writes.isEmpty)

        _ = await state.refreshStoredAuthSessionIfNeeded(reason: "foreground", silent: true, persistenceDefaults: defaults)
        XCTAssertEqual(state.apiContext.imToken, "after-ack")
        XCTAssertFalse(state.callStore.hasCallRecordPersistenceBinding)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        transport.ackGate.release()
        if case .success = await events.value {} else { XCTFail("The admitted ACK should be allowed to complete") }
        XCTAssertEqual(transport.completedAcknowledgements, 1)
        XCTAssertEqual(transport.acknowledgements.count, 1)
        await assertCallArchiveRestores(admitted + [archived], from: archive, key: key)
        XCTAssertEqual(archive.writes, [.init(scope: key, records: admitted + [archived])])
    }

    func testCallArchivePollsRejectOldGenerationWhenRefreshRestoresSameScope() async throws {
        let context = callArchiveRefreshContext()
        let invalid = invalidCallArchiveContext(context)
        let transport = try CallArchivePollTransport(refresh: [
            callArchiveRefreshResult(invalid, token: "temporarily-invalid"),
            callArchiveRefreshResult(context, token: "valid-again"),
        ])
        let entered = expectation(description: "restored scope reads its archive")
        let archive = FencedCallArchive(rows: [:], blockedScope: nil, entered: entered)
        defer { archive.release(); transport.releaseAll() }
        let (state, defaults) = try makePolicyIsolatedCallArchiveScopeState(context: context, archive: archive, transport: transport)
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let scope = try LocalMessageScope(context: context)
        let generation = state.localMessageSessionGeneration
        let calls = Task { await state.refreshRTCCallsSilently() }
        let events = Task { await state.refreshRTCCallEventsSilently() }
        await waitForCallEnd { transport.callsGate.entered && transport.eventsGate.entered }
        XCTAssertTrue(transport.callsGate.entered && transport.eventsGate.entered)
        _ = await state.refreshStoredAuthSessionIfNeeded(reason: "foreground", silent: true, persistenceDefaults: defaults)
        XCTAssertThrowsError(try LocalMessageScope(context: state.apiContext))
        _ = await state.refreshStoredAuthSessionIfNeeded(reason: "foreground", silent: true, persistenceDefaults: defaults)
        XCTAssertEqual(state.apiContext.imToken, "valid-again")
        XCTAssertEqual(try LocalMessageScope(context: state.apiContext), scope)
        XCTAssertNotEqual(state.localMessageSessionGeneration, generation)
        XCTAssertTrue(state.callStore.hasCallRecordPersistenceBinding(for: scope))
        await fulfillment(of: [entered], timeout: 4)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: CallArchivePollTransport.activeCallID)
        transport.releaseAll()
        assertCallArchivePollCancelled(await calls.value)
        assertCallArchivePollCancelled(await events.value)
        XCTAssertEqual(state.activeVoiceCall?.callID, CallArchivePollTransport.activeCallID)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        XCTAssertEqual(transport.acknowledgements, [])
        archive.release()
        let readback = expectation(description: "restore and any old writes have drained")
        let reader = CallStore(callRecordStore: archive)
        let observation = reader.$calls.dropFirst().prefix(1).sink { _ in readback.fulfill() }
        defer { observation.cancel() }
        reader.bindCallRecordPersistence(scope: state.callRecordDataScopeKey(for: context))
        await fulfillment(of: [readback], timeout: 4)
        XCTAssertTrue(reader.calls.isEmpty)
        XCTAssertTrue(archive.writes.isEmpty)
    }

    private func makePolicyIsolatedCallArchiveScopeState(
        context: IMAPIContext, archive: FencedCallArchive, transport: any HTTPTransport,
        videoMediaClient: any VideoMediaClient = NoopVideoMediaClient(),
        voiceCallSystem: any VoiceCallSystemIntegrating = NoopVoiceCallSystemIntegration()
    ) throws -> (AppState, UserDefaults) {
        let suite = "CallArchivePolicyFixture." + UUID().uuidString
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return try IMAppPolicyLastGoodStore.$fixtureSuiteName.withValue(suite) {
            try makeCallArchiveScopeState(
                context: context, archive: archive, transport: transport,
                videoMediaClient: videoMediaClient, voiceCallSystem: voiceCallSystem
            )
        }
    }

    private func callArchiveRefreshContext() -> IMAPIContext {
        var context = callArchiveTestContext()
        context.tenantAuthSession = IMStoredAuthSession(
            sessionID: "sess_call_archive_fixture", refreshToken: "initial-refresh", tokenType: "im",
            tenantID: context.tenantID ?? "", accountID: context.accountID ?? "", appID: context.appID,
            deviceID: context.deviceID, clientType: "ios"
        )
        return context
    }

    private func invalidCallArchiveContext(_ context: IMAPIContext) -> IMAPIContext {
        var invalid = context
        invalid.deviceID = " " + context.deviceID
        return invalid
    }

    private func assertCallArchivePollCancelled(_ result: RTCRefreshResult, file: StaticString = #filePath, line: UInt = #line) {
        if case .cancelled = result { return }
        XCTFail("The original poll has no current scope and generation authority", file: file, line: line)
    }

    private func assertCallArchiveRestores(_ expected: [CallRecord], from archive: FencedCallArchive, key: String) async {
        let persisted = expectation(description: "fresh archive reader observes the original key")
        let reader = CallStore(callRecordStore: archive)
        let observation = reader.$calls.dropFirst().prefix(1).sink { _ in persisted.fulfill() }
        defer { observation.cancel() }
        reader.bindCallRecordPersistence(scope: key)
        archive.release()
        await fulfillment(of: [persisted], timeout: 4)
        XCTAssertEqual(reader.calls, expected)
        XCTAssertEqual(archive.records(for: key), expected)
    }
}

private final class CallArchivePollTransport: HTTPTransport, @unchecked Sendable {
    static let activeCallID = "archive-active"
    static let replayedCallID = "archive-replayed"
    let callsGate = SetupRaceGate()
    let eventsGate = SetupRaceGate()
    let ackGate = SetupRaceGate()
    private let lock = NSLock()
    private var refresh: [HTTPTransportResult]
    private var requests: [String] = []
    private var acks: [Set<String>] = []
    private var completedAcks = 0

    init(refresh: [HTTPTransportResult]) { self.refresh = refresh }

    var paths: [String] { lock.withLock { requests } }
    var acknowledgements: [Set<String>] { lock.withLock { acks } }
    var completedAcknowledgements: Int { lock.withLock { completedAcks } }

    func releaseAll() {
        callsGate.release()
        eventsGate.release()
        ackGate.release()
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock { requests.append(path) }
        let result: [String: Any]
        switch (request.httpMethod, path) {
        case ("GET", "/api/platform/apps/current-policy") where request.url?.host == "platform.example.test":
            result = ["app_id": IMAPIContext.canonicalIOSAppID, "status": "active", "phone_auth_enabled": true]
        case ("GET", "/api/rtc/calls"):
            await callsGate.wait()
            result = ["calls": [
                ["id": Self.activeCallID, "room_id": "room-archive-active", "status": "ended",
                 "caller_uid": "uid-1", "callee_uid": "archive-peer", "state_version": 3, "call_type": "video"],
            ]]
        case ("GET", "/api/rtc/calls/events"):
            await eventsGate.wait()
            result = ["events": [
                ["id": "ringing", "notification_id": "ringing-notice", "type": "rtc.call.ringing",
                 "payload": ["call_id": Self.replayedCallID, "status": "ringing", "caller_uid": "replay-peer",
                             "callee_uid": "uid-1", "room_id": "room-archive-replay", "state_version": 1]],
                ["id": "terminal", "notification_id": "terminal-notice", "type": "rtc.call.ended",
                 "payload": ["call_id": Self.replayedCallID, "status": "ended", "state_version": 3]],
            ]]
        case ("POST", "/api/rtc/calls/events/ack"):
            let body = try XCTUnwrap(request.httpBody)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let ids = try XCTUnwrap(payload["notification_ids"] as? [String])
            lock.withLock { acks.append(Set(ids)) }
            await ackGate.wait()
            lock.withLock { completedAcks += 1 }
            result = [:]
        case ("POST", "/api/rtc/calls/\(Self.activeCallID)/hangup"):
            result = [:]
        case ("POST", _) where path.hasSuffix("/session/refresh"):
            let response = lock.withLock { refresh.isEmpty ? nil : refresh.removeFirst() }
            return try XCTUnwrap(response).resolvingResponseURL(request.url)
        default:
            XCTFail("Unexpected call-archive fixture request: \(request.httpMethod ?? "?") \(path)")
            throw URLError(.unsupportedURL)
        }
        return HTTPTransportResult(
            data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": result]),
            isHTTPResponse: true, statusCode: 200
        ).resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        XCTFail("The call-archive fixture should never upload")
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_CALL_ARCHIVE_WRITE_ADMISSION_20261112_END

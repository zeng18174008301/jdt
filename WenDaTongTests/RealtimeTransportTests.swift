import Foundation
import Combine
import Network
import XCTest
@testable import WenDaTong

@MainActor
final class RealtimeTransportTests: XCTestCase {
    // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023_BEGIN
    func testRealtimeErrorScopeSeparatesConversationDenialFromAuthenticationFailure() {
        let local = RealtimeEnvelope(type: "error", requestID: "sub-1", payload: ["channel_id": .string("g1")])
        XCTAssertFalse(RealtimeErrorScopePolicy.isConnectionFailure(code: "forbidden", envelope: local, matchesConnectRequest: false))
        XCTAssertFalse(RealtimeErrorScopePolicy.isConnectionFailure(code: " FORBIDDEN ", envelope: local, matchesConnectRequest: false))
        XCTAssertTrue(RealtimeErrorScopePolicy.isConnectionFailure(code: "forbidden", envelope: local, matchesConnectRequest: true))
        for code in ["unauthorized", "connect_required", "connect_failed"] {
            XCTAssertTrue(RealtimeErrorScopePolicy.isConnectionFailure(code: code, envelope: local, matchesConnectRequest: false))
        }
        for scope in ["global", "tenant", "session", "connection", "account", "workspace"] {
            let envelope = RealtimeEnvelope(type: "error", requestID: nil, payload: ["error": .object(["scope": .string(scope)])])
            XCTAssertTrue(RealtimeErrorScopePolicy.isConnectionFailure(code: "forbidden", envelope: envelope, matchesConnectRequest: false))
        }
        for scope in ["channel", "conversation", "message", ""] {
            let envelope = RealtimeEnvelope(type: "error", requestID: nil, payload: ["scope": .string(scope)])
            XCTAssertFalse(RealtimeErrorScopePolicy.isConnectionFailure(code: "forbidden", envelope: envelope, matchesConnectRequest: false))
        }
        var diagnostic = RealtimeConnectionDiagnostic(generation: 1, stage: .server, result: .forbidden, transport: .webSocket, elapsedMS: 0)
        XCTAssertTrue(diagnostic.isFailure)
        diagnostic.handling = .operationRejected
        XCTAssertFalse(diagnostic.isFailure)
    }

    func testAppStateKeepsSocketAfterConversationErrorsAndStillDisconnectsUnauthorized() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let client = RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: socket),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), requestIDProvider: { "\($0)-scope-test" },
            networkMonitorFactory: nil, continuity: IMRuntimeWebSocketContinuity())
        let context = IMAPIContext(platformToken: nil, accountID: "scope-test", tenantID: "scope-\(UUID())",
            imUID: "me", imToken: "test-token", platformAuthSession: nil, tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID, deviceID: "test-device")
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"), imBase: URL(string: "https://im.example.test"),
            httpTransport: RTCWireOfflineHTTPTransport())
        let state = AppState(api: api, realtimeClient: client, voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messageStore: RTCWireEmptyMessageStore(), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        defer {
            state.setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            client.onEnvelope = nil
            client.onConnected = nil
            client.disconnect(shouldReconnect: false)
        }
        let connected = expectation(description: "connected")
        client.onConnected = { connected.fulfill() }
        client.start(url: try XCTUnwrap(URL(string: "wss://example.test/im/ws")), token: "test-token")
        socket.enqueue(.string(#"{"type":"connect_ack","request_id":"connect-scope-test","payload":{}}"#))
        await fulfillment(of: [connected], timeout: 2)
        let generation = client.connectionGeneration
        for payload: [String: JSONValue] in [
            ["code": .string("forbidden"), "channel_id": .string("g1")],
            ["error": .object(["code": .string("forbidden"), "channel_id": .string("g2")])],
            ["code": .string("forbidden")],
            ["code": .string("group_member_quota_exceeded")]
        ] {
            state.handleRealtimeEnvelope(RealtimeEnvelope(type: "error", requestID: "sub-scope-test", payload: payload))
            XCTAssertEqual(client.connectionState, .connected)
            XCTAssertEqual(client.connectionGeneration, generation)
        }
        let nextFrame = expectation(description: "other conversation traffic still arrives")
        client.onEnvelope = { envelope in
            if envelope.type == "test_barrier" { nextFrame.fulfill() }
        }
        socket.enqueue(.string(#"{"type":"test_barrier","payload":{}}"#))
        await fulfillment(of: [nextFrame], timeout: 2)
        state.handleRealtimeEnvelope(RealtimeEnvelope(type: "error", requestID: nil, payload: ["code": .string("unauthorized")]))
        XCTAssertFalse(client.isConnected)
        XCTAssertGreaterThan(client.connectionGeneration, generation)
    }
    // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023_END

    func testFirstErrorClosedCodeClassificationAndNestedPrecedenceRejectSensitiveText() throws {
        typealias Code = RealtimeConnectionDiagnostic.ServerCode
        for code in Code.allCases where ![.none, .missing, .unknown].contains(code) {
            XCTAssertEqual(Code(code: code.rawValue.lowercased()), code)
        }
        XCTAssertEqual(Code(code: " \n"), .missing)
        for raw in ["NONE", "UNKNOWN", "MISSING", "online_quota_exceeded SENSITIVE_SENTINEL", "https://private.invalid", "token=SENSITIVE_SENTINEL"] {
            XCTAssertEqual(Code(code: raw), .unknown)
        }
        let nested = RealtimeEnvelope(type: "error", requestID: "SENSITIVE_SENTINEL", payload: [
            "error": .object(["reason_code": .string("online_quota_exceeded"), "message": .string("SENSITIVE_SENTINEL")])
        ])
        XCTAssertEqual(Code.from(nested), .onlineQuotaExceeded)
        let outer = RealtimeEnvelope(type: "error", requestID: nil, payload: [
            "code": .string("forbidden"), "error": .object(["code": .string("online_quota_exceeded")])
        ])
        XCTAssertEqual(Code.from(outer), .forbidden)
        var event = RealtimeConnectionDiagnostic(generation: 3, stage: .server,
            result: .serverRejected, transport: .webSocket, elapsedMS: 20)
        event.serverCode = Code.from(nested)
        event.handlingCode = Code(code: "forbidden SENSITIVE_SENTINEL")
        XCTAssertEqual(event.handlingCode, .unknown)
        XCTAssertFalse(event.summary.contains("SENSITIVE_SENTINEL"))
        XCTAssertFalse(event.summary.contains("private.invalid"))
    }

    func testFirstErrorRequestIndexRequiresActualIDAndBoundsRetentionAndCollision() {
        var index = RealtimeDiagnosticRequestIndex()
        XCTAssertEqual(index.lookup(nil).1, .asyncOrNoID)
        XCTAssertEqual(index.lookup("").1, .asyncOrNoID)
        XCTAssertEqual(index.lookup("subscribe_channel-looks-real").1, .unmatched)
        index.record("actual-request", operation: .subscribeChannel)
        XCTAssertEqual(index.lookup("actual-request").0, .subscribeChannel)
        XCTAssertEqual(index.lookup("actual-request").1, .matched)
        index.record("actual-request", operation: .ping)
        XCTAssertEqual(index.lookup("actual-request").0, .unproven)
        XCTAssertEqual(index.lookup("actual-request").1, .unproven)
        for value in 0..<RealtimeDiagnosticRequestIndex.capacity {
            index.record("sent-\(value)", operation: .subscribeChannel)
        }
        XCTAssertEqual(index.count, RealtimeDiagnosticRequestIndex.capacity)
        XCTAssertEqual(index.lookup("actual-request").1, .unmatched)
        index.record(String(repeating: "x", count: 257), operation: .connect)
        XCTAssertEqual(index.count, RealtimeDiagnosticRequestIndex.capacity)
        index.reset()
        XCTAssertEqual(index.count, 0)
        XCTAssertEqual(index.lookup("sent-31").1, .unmatched)
    }

    func testFirstErrorRealSendAssociationAndAppCallbackObservationPreserveConnectedState() async throws {
        let socket = FakeRealtimeWebSocketTask()
        var requestNumber = 0
        let client = RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: socket),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            requestIDProvider: { type in requestNumber += 1; return "\(type)-\(requestNumber)" }, networkMonitorFactory: nil)
        let ack = expectation(description: "matching connect ACK")
        let errors = expectation(description: "three independently correlated errors")
        errors.expectedFulfillmentCount = 3
        var observed: [RealtimeConnectionDiagnostic] = []
        var callbackCount = 0
        client.diagnosticScopeProvider = { 12 }
        client.onEnvelope = { _ in
            callbackCount += 1
            client.currentEnvelopeDiagnostic?.event.handling = .errorUnhandled
        }
        client.onDiagnostic = { event, _ in
            observed.append(event)
            if event.result == .acknowledged { ack.fulfill() }
            if event.stage == .server { errors.fulfill() }
        }
        client.start(url: try XCTUnwrap(URL(string: "wss://example.test/im/ws")), token: "test-token")
        socket.enqueue(.string(#"{"type":"connect_ack","request_id":"connect-1","payload":{}}"#))
        await fulfillment(of: [ack], timeout: 1)
        client.subscribe(channelID: "SENSITIVE_CHANNEL", channelType: "group", tenantID: "SENSITIVE_TENANT", imUID: "SENSITIVE_ACCOUNT", deviceID: "SENSITIVE_DEVICE")
        socket.enqueue(.string(#"{"type":"error","request_id":"subscribe_channel-2","payload":{"error":{"code":"online_quota_exceeded","message":"SENSITIVE_SENTINEL"}}}"#))
        socket.enqueue(.string(#"{"type":"error","request_id":"not-sent","payload":{"code":"new_unknown_code"}}"#))
        socket.enqueue(.string(#"{"type":"error","payload":{}}"#))
        await fulfillment(of: [errors], timeout: 1)
        let results = observed.filter { $0.stage == .server }
        XCTAssertEqual(results.map(\.serverCode), [.onlineQuotaExceeded, .unknown, .missing])
        XCTAssertEqual(results.map(\.correlation), [.matched, .unmatched, .asyncOrNoID])
        XCTAssertEqual(results.map(\.operation), [.subscribeChannel, .unproven, .unproven])
        XCTAssertTrue(results.allSatisfy { $0.handling == .errorUnhandled && $0.scopeMatch == .current && $0.stateAfter == .connected })
        XCTAssertEqual(callbackCount, 3)
        XCTAssertEqual(client.connectionState, .connected, "Observing a server error does not disconnect")
        XCTAssertEqual(socket.sentStrings().count, 2, "No added request or retry")
        XCTAssertFalse(results.map(\.summary).joined().contains("SENSITIVE"))
        XCTAssertNil(client.currentEnvelopeDiagnostic, "Synchronous observation must not leak to later callbacks")
        client.onDiagnostic = nil
        client.disconnect(shouldReconnect: false)
        client.onEnvelope = nil
    }

    func testFirstErrorAppDisconnectKeepsOriginGenerationAndActualFinalState() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let client = RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: socket),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            requestIDProvider: deterministicRealtimeRequestID, networkMonitorFactory: nil)
        var epoch: UInt64 = 1
        client.diagnosticScopeProvider = { epoch }
        let ack = expectation(description: "connected")
        let handled = expectation(description: "origin error completed after callback changed state")
        var result: RealtimeConnectionDiagnostic?
        client.onDiagnostic = { event, _ in
            if event.result == .acknowledged { ack.fulfill() }
            if event.stage == .server { result = event; handled.fulfill() }
        }
        client.onEnvelope = { _ in
            let observation = client.currentEnvelopeDiagnostic
            client.disconnect(shouldReconnect: false)
            epoch += 1
            observation?.event.handling = .workspaceSelectionForced
        }
        client.start(url: try XCTUnwrap(URL(string: "wss://example.test/im/ws")), token: "test-token")
        socket.enqueue(.string(realtimeEnvelopeString(type: "connect_ack")))
        await fulfillment(of: [ack], timeout: 1)
        let origin = client.connectionGeneration
        socket.enqueue(.string(#"{"type":"error","payload":{"code":"tenant_service_stopped"}}"#))
        await fulfillment(of: [handled], timeout: 1)
        XCTAssertEqual(result?.generation, origin)
        XCTAssertGreaterThan(client.connectionGeneration, origin)
        XCTAssertEqual(result?.generationAfter, client.connectionGeneration)
        XCTAssertEqual(result?.handling, .workspaceSelectionForced)
        XCTAssertEqual(result?.scopeMatch, .current)
        XCTAssertEqual(result?.scopeAfter, .stale)
        XCTAssertEqual(result?.stateAfter, .idle)
        XCTAssertNil(client.currentEnvelopeDiagnostic)
        client.onEnvelope = nil
    }

    func testFirstErrorOldSocketCannotMatchNewRequestOrOverwriteNewScopeResult() async throws {
        let oldSocket = LeakyRealtimeWebSocketTask()
        let currentSocket = FakeRealtimeWebSocketTask()
        var requestNumber = 0
        let client = RealtimeClient(transport: SequencedRealtimeWebSocketTransport(tasks: [oldSocket, currentSocket]),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            requestIDProvider: { _ in requestNumber += 1; return "request-\(requestNumber)" }, networkMonitorFactory: nil)
        let diagnostics = AccessDiagnostics()
        diagnostics.bindConnectionDiagnostics(to: client)
        let oldRejected = expectation(description: "old socket error dropped")
        let currentRejected = expectation(description: "current frame has no old request match")
        let cache = try XCTUnwrap(client.onDiagnostic)
        var stale: RealtimeConnectionDiagnostic?
        var current: RealtimeConnectionDiagnostic?
        client.onDiagnostic = { event, scope in
            cache(event, scope)
            if !event.currentAtReceipt { stale = event; oldRejected.fulfill() }
            else if event.stage == .server { current = event; currentRejected.fulfill() }
        }
        let url = try XCTUnwrap(URL(string: "wss://example.test/im/ws"))
        client.start(url: url, token: "old-test-token")
        let oldGeneration = client.connectionGeneration
        for _ in 0..<20 where !oldSocket.hasPendingReceiver() { await Task.yield() }
        XCTAssertTrue(oldSocket.hasPendingReceiver())
        client.start(url: url, token: "new-test-token")
        oldSocket.emit(.string(#"{"type":"error","request_id":"request-2","payload":{"code":"online_quota_exceeded"}}"#))
        currentSocket.enqueue(.string(#"{"type":"error","request_id":"request-1","payload":{"code":"online_quota_exceeded"}}"#))
        await fulfillment(of: [oldRejected, currentRejected], timeout: 1)
        XCTAssertEqual(stale?.generation, oldGeneration)
        XCTAssertEqual(stale?.handling, .staleConnectionRejected)
        XCTAssertEqual(stale?.operation, .unproven)
        XCTAssertEqual(stale?.correlation, .unproven)
        XCTAssertEqual(current?.generation, client.connectionGeneration)
        XCTAssertEqual(current?.correlation, .unmatched, "Previous-leg IDs were reset")
        XCTAssertEqual(current?.handling, .connectionStateRejected)
        XCTAssertEqual(client.connectionState, .awaitingAck)
        client.onDiagnostic = nil
        client.disconnect(shouldReconnect: false)
    }

    func testFirstErrorTransportFailureReportsCompletedStopWithoutNewReconnect() async throws {
        let transport = FailingRealtimeWebSocketTransport()
        let client = RealtimeClient(transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), networkMonitorFactory: nil)
        client.canReconnect = { false }
        let stopped = expectation(description: "actual socket stop observed")
        var result: RealtimeConnectionDiagnostic?
        client.onDiagnostic = { event, _ in
            if event.stage == .socket, event.isFailure { result = event; stopped.fulfill() }
        }
        client.start(url: try XCTUnwrap(URL(string: "wss://example.test/im/ws")), token: "test-token")
        let origin = client.connectionGeneration
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(result?.generation, origin)
        XCTAssertEqual(result?.stateAfter, .idle)
        XCTAssertEqual(result?.generationAfter, client.connectionGeneration)
        XCTAssertGreaterThan(client.connectionGeneration, origin)
        XCTAssertEqual(transport.requestedURLs().count, 1)
        XCTAssertEqual(client.connectionState, .idle)
        client.onDiagnostic = nil
    }

    func testConnectionDiagnosticLogoutRejectsOldStopAndAcceptsNewScopeStart() throws {
        let diagnostics = AccessDiagnostics()
        let authenticated = AccessDiagnosticsActivationScope(appID: "jianhuitong-ios",
            accountID: "account-a", tenantID: "tenant-a", authPhase: .authenticated, sessionGeneration: 1)
        let loggedOut = AccessDiagnosticsActivationScope(appID: "jianhuitong-ios", authPhase: .loggedOut)
        let transport = SequencedRealtimeWebSocketTransport(tasks: [FakeRealtimeWebSocketTask(), FakeRealtimeWebSocketTask()])
        let client = RealtimeClient(transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), networkMonitorFactory: nil)
        func open(_ scope: AccessDiagnosticsActivationScope, entry: AccessDiagnosticsActivationEntry) {
            var result = AccessDiagnosticsVisibilityTransition.unchanged
            for index in 0..<5 {
                result = diagnostics.registerLogoTap(entry: entry, scope: scope,
                    nowNanoseconds: 1_000_000_000 + UInt64(index) * 120_000_000)
            }
            XCTAssertEqual(result, .opened)
        }
        diagnostics.updateScope(authenticated)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        // This is the same binding invoked by AppState's real client setup.
        diagnostics.bindConnectionDiagnostics(to: client)
        let url = try XCTUnwrap(URL(string: "wss://example.test/im/ws"))
        client.start(url: url, token: "test-old-session")
        let oldEpoch = diagnostics.connectionScopeEpoch
        open(authenticated, entry: .loggedInAboutLogo)
        let oldResult = try XCTUnwrap(diagnostics.snapshot.connectionResult)
        XCTAssertEqual(oldResult.result, .started)
        XCTAssertEqual(client.connectionState, .awaitingAck)

        // AppState.logout: isAuthenticated didSet changes scope before disconnect.
        diagnostics.updateScope(loggedOut)
        client.disconnect(shouldReconnect: false)
        XCTAssertEqual(client.connectionState, .idle)
        diagnostics.disablePreservingAllowedPolicy()
        diagnostics.updateScope(loggedOut) // The later logo tap sees the same scope.
        open(loggedOut, entry: .loggedOutLoginLogo)
        XCTAssertNil(diagnostics.snapshot.connectionResult, "Old STOP_REQUESTED must not enter the new scope")
        diagnostics.recordConnection(oldResult, scopeEpoch: oldEpoch)
        XCTAssertNil(diagnostics.snapshot.connectionResult, "Delayed old results are rejected too")

        let next = AccessDiagnosticsActivationScope(appID: "jianhuitong-ios",
            accountID: "account-a", tenantID: "tenant-a", authPhase: .authenticated, sessionGeneration: 2)
        diagnostics.updateScope(next)
        client.start(url: url, token: "test-new-session")
        open(next, entry: .loggedInAboutLogo)
        XCTAssertEqual(diagnostics.snapshot.connectionResult?.result, .started)
        XCTAssertEqual(diagnostics.snapshot.connectionResult?.generation, client.connectionGeneration)
        XCTAssertNotEqual(diagnostics.connectionScopeEpoch, oldEpoch)
        client.disconnect(shouldReconnect: false)
        XCTAssertEqual(diagnostics.snapshot.connectionResult?.result, .stopRequested,
                       "Same-scope stop remains a real observable result")
    }

    func testConnectionDiagnosticAdmissionDoesNotOpenTransport() throws {
        let socket = FakeRealtimeWebSocketTask()
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(transport: transport, networkMonitorFactory: nil)
        var events: [RealtimeConnectionDiagnostic] = []
        client.onDiagnostic = { event, _ in events.append(event) }
        client.start(url: try XCTUnwrap(URL(string: "wss://private.invalid/im/ws")), token: " ")
        XCTAssertEqual(events.map(\.result), [.missingSession])
        XCTAssertEqual(events.first?.stage, .admission)
        XCTAssertEqual(events.first?.elapsedMS, 0)
        XCTAssertTrue(transport.requestedURLs().isEmpty)
        XCTAssertEqual(client.connectionState, .idle)
    }

    func testConnectionDiagnosticRefusalThenMatchingACKUsesClosedLabelsAndElapsedTime() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let clock = TestRealtimeMonotonicClock()
        let client = RealtimeClient(
            transport: FakeRealtimeWebSocketTransport(socket: socket),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            requestIDProvider: deterministicRealtimeRequestID,
            monotonicClock: clock, networkMonitorFactory: nil
        )
        var events: [RealtimeConnectionDiagnostic] = []
        let refused = expectation(description: "actual refusal observed")
        let connected = expectation(description: "matching ACK observed")
        client.onDiagnostic = { event, _ in
            events.append(event)
            if event.result == .unauthorized { refused.fulfill() }
            if event.result == .acknowledged { connected.fulfill() }
        }
        client.start(url: try XCTUnwrap(URL(string: "wss://private.invalid/im/ws?account=SENSITIVE_SENTINEL")), token: "SENSITIVE_SENTINEL")
        clock.advance(toNanoseconds: 37_000_000)
        socket.enqueue(.string(#"{"type":"error","request_id":"connect-1","payload":{"code":"unauthorized","message":"SENSITIVE_SENTINEL"}}"#))
        await fulfillment(of: [refused], timeout: 1)
        XCTAssertEqual(client.connectionState, .awaitingAck, "Diagnostics must not change existing refusal handling")
        XCTAssertEqual(events.last?.elapsedMS, 37)
        socket.enqueue(.string(realtimeEnvelopeString(type: "connect_ack")))
        await fulfillment(of: [connected], timeout: 1)
        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertEqual(events.map(\.result), [.started, .unauthorized, .acknowledged])
        XCTAssertTrue(events.allSatisfy { $0.generation == client.connectionGeneration })
        XCTAssertFalse(events.map(\.summary).joined().contains("SENSITIVE_SENTINEL"))
        XCTAssertFalse(events.map(\.summary).joined().contains("private.invalid"))
        XCTAssertEqual(RealtimeConnectionDiagnostic.Result.serverError("SENSITIVE_SENTINEL"), .serverRejected)
        client.disconnect(shouldReconnect: false)
    }

    func testConnectionDiagnosticSocketClassificationNeverRetainsRawError() {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.secureConnectionFailed.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "SENSITIVE_SENTINEL https://private.invalid token=secret"])
        let event = RealtimeConnectionDiagnostic(generation: 3, stage: .socket,
            result: .socketFailure(error), transport: .webSocket, elapsedMS: 19)
        XCTAssertEqual(event.result, .failure(.tls))
        XCTAssertEqual(event.summary, "connection_result generation=3 stage=SOCKET result=TLS transport=WEBSOCKET elapsed_ms=19 code=NONE handled_code=NONE operation=UNPROVEN correlation=UNPROVEN scope_at_receipt=UNPROVEN handling=UNPROVEN current_at_receipt=true state_after=UNPROVEN scope_after=UNPROVEN generation_after=UNPROVEN")
        XCTAssertEqual(RealtimeConnectionDiagnostic.Result.socketFailure(RealtimeClientError.acknowledgementTimeout(transport: "SENSITIVE_SENTINEL")), .acknowledgementTimeout)
        XCTAssertEqual(RealtimeConnectionDiagnostic.Result.socketFailure(NSError(domain: "SENSITIVE_SENTINEL", code: 99)), .failure(.other))
    }

}

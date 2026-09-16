import Foundation
import Combine
import Network
import XCTest
@testable import BlueStoneIM

@MainActor
final class RealtimeTransportTests: XCTestCase {
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

    func testRealtimeClientRemovesURLCredentialsAndSendsTokenOnlyInFirstConnectFrame() throws {
        let socket = FakeRealtimeWebSocketTask()
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = FakeRealtimeQUICTransport(result: .success(FakeRealtimeQUICConnection()))
        let client = RealtimeClient(transport: transport, quicTransport: quicTransport, networkMonitorFactory: nil)
        let url = try XCTUnwrap(URL(string: "ws://example.test:9443/retired-ws?token=url-token&im_token=legacy-token&trace=1"))
        let sanitizedURL = try XCTUnwrap(URL(string: "ws://example.test:9443/im/ws?trace=1"))

        client.start(url: url, token: " token-1 ")

        XCTAssertTrue(quicTransport.requests().isEmpty)
        XCTAssertEqual(transport.requestedURLs(), [sanitizedURL])
        XCTAssertNil(transport.requestedRequests().first?.webSocketDialMetadata)
        XCTAssertEqual(socket.resumeCount(), 1)

        let packet = try XCTUnwrap(socket.sentStrings().first)
        XCTAssertFalse(packet.contains("\"capabilities\""))
        let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "connect")
        let payload = object?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["token"] as? String, "token-1")
        XCTAssertNil(payload?["capabilities"])
        XCTAssertEqual(sentPacketTypes(socket), ["connect"])

        client.disconnect(shouldReconnect: false)
        XCTAssertEqual(socket.cancelCount(), 1)
    }

    func testRealtimeConnectionRequestEnforcesCanonicalWebSocketPath() throws {
        let url = try XCTUnwrap(URL(string: "wss://example.test:9443/custom/realtime?tenant=tenant-a&token=legacy&trace=runtime"))

        let request = RealtimeConnectionRequest(url: url, token: "token-1")

        XCTAssertEqual(
            request.url.absoluteString,
            "wss://example.test:9443/im/ws?tenant=tenant-a&trace=runtime"
        )
    }

    func testRealtimeClientDeclaresBatchCapabilityOnlyWhenEnabledForWebSocket() throws {
        let socket = FakeRealtimeWebSocketTask()
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = FakeRealtimeQUICTransport(result: .success(FakeRealtimeQUICConnection()))
        let client = RealtimeClient(
            transport: transport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            networkMonitorFactory: nil,
            realtimeBatchCapabilityEnabled: true
        )
        let url = try XCTUnwrap(URL(string: "ws://example.test/im/ws"))

        client.start(url: url, token: " token-1 ")

        let payload = try XCTUnwrap(sentPacketPayload(socket))
        XCTAssertEqual(payload["token"] as? String, "token-1")
        XCTAssertEqual(payload["capabilities"] as? [String], ["batch"])

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientUsesQUICPoCWhenExplicitlyEnabled() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicConnection = FakeRealtimeQUICConnection(receiveLines: [
            Data(realtimeEnvelopeString(type: "connect_ack").utf8)
        ])
        let quicTransport = FakeRealtimeQUICTransport(result: .success(quicConnection))
        let quicURL = try XCTUnwrap(URL(string: "quic://quic.example.test:443/im/quic"))
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: true, endpointURL: quicURL, connectTimeoutNanoseconds: 500_000_000),
            requestIDProvider: deterministicRealtimeRequestID,
            networkMonitorFactory: nil
        )
        let connected = expectation(description: "quic connect ack handled")

        client.onConnected = {
            connected.fulfill()
        }
        client.start(url: try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws")), token: " token-1 ")

        await fulfillment(of: [connected], timeout: 1)
        XCTAssertTrue(webSocketTransport.requestedURLs().isEmpty)
        let quicRequest = try XCTUnwrap(quicTransport.requests().first)
        XCTAssertEqual(quicRequest.host, "quic.example.test")
        XCTAssertEqual(quicRequest.port, 443)
        XCTAssertEqual(quicRequest.path, "/im/quic")
        XCTAssertEqual(quicRequest.alpn, "im_quic_json_v1")
        XCTAssertEqual(quicRequest.tlsServerName, "quic.example.test")

        let packet = try XCTUnwrap(quicConnection.sentLineStrings().first)
        XCTAssertFalse(packet.contains("\"capabilities\""))
        let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "connect")
        let payload = object?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["token"] as? String, "token-1")
        XCTAssertNil(payload?["capabilities"])

        client.disconnect(shouldReconnect: false)
        XCTAssertEqual(quicConnection.cancelCount(), 1)
    }

    func testRealtimeClientUsesDiscoveryQUICRequestWhenFeatureFlagEnabled() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicConnection = FakeRealtimeQUICConnection(receiveLines: [
            Data(realtimeEnvelopeString(type: "connect_ack").utf8)
        ])
        let quicTransport = FakeRealtimeQUICTransport(result: .success(quicConnection))
        let quicRequest = discoveryQUICRequest(token: "token-1", path: "/im/quic?token=url-token")
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: true),
            requestIDProvider: deterministicRealtimeRequestID,
            networkMonitorFactory: nil
        )
        let connected = expectation(description: "discovery quic connect ack handled")

        client.onConnected = {
            connected.fulfill()
        }
        client.start(request: RealtimeConnectionRequest(
            url: try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws")),
            token: "token-1",
            quicRequest: quicRequest
        ))

        await fulfillment(of: [connected], timeout: 1)
        XCTAssertTrue(webSocketTransport.requestedURLs().isEmpty)
        let capturedRequest = try XCTUnwrap(quicTransport.requests().first)
        XCTAssertEqual(capturedRequest.path, "/im/quic")
        XCTAssertFalse(capturedRequest.path.localizedCaseInsensitiveContains("token"))
        XCTAssertEqual(try sentPacketPayloadToken(quicConnection), "token-1")

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientIgnoresDiscoveryQUICRequestWhenFeatureFlagDisabled() throws {
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = FakeRealtimeQUICTransport(result: .success(FakeRealtimeQUICConnection()))
        let fallbackURL = try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws"))
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            networkMonitorFactory: nil
        )

        client.start(request: RealtimeConnectionRequest(
            url: fallbackURL,
            token: "token-1",
            quicRequest: discoveryQUICRequest(token: "token-1")
        ))

        XCTAssertTrue(quicTransport.requests().isEmpty)
        XCTAssertEqual(webSocketTransport.requestedURLs(), [fallbackURL])
        XCTAssertEqual(socket.resumeCount(), 1)
        XCTAssertEqual(sentPacketTypes(socket).first, "connect")

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientFallsBackToWebSocketWhenQUICPoCFails() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = FakeRealtimeQUICTransport(result: .failure(RealtimeQUICError.connectionTimeout))
        let quicURL = try XCTUnwrap(URL(string: "quic://quic.example.test:443/im/quic"))
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: true, endpointURL: quicURL),
            networkMonitorFactory: nil
        )
        let fallback = expectation(description: "quic failure falls back to websocket")
        let fallbackURL = try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws"))

        client.onQUICFallbackToWebSocket = { error in
            XCTAssertEqual(error as? RealtimeQUICError, .connectionTimeout)
            fallback.fulfill()
        }
        client.start(url: fallbackURL, token: "token-1")

        await fulfillment(of: [fallback], timeout: 1)
        XCTAssertEqual(quicTransport.requests().count, 1)
        XCTAssertEqual(webSocketTransport.requestedURLs(), [fallbackURL])
        XCTAssertEqual(socket.resumeCount(), 1)
        XCTAssertEqual(sentPacketTypes(socket).first, "connect")

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientFallsBackToWebSocketWhenDiscoveryQUICFails() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = FakeRealtimeQUICTransport(result: .failure(RealtimeQUICError.connectionTimeout))
        let fallbackURL = try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws"))
        let metadata = try XCTUnwrap(RealtimeWebSocketDialMetadata(
            dialHost: "203.0.113.10",
            port: 443,
            tlsServerName: "fallback.example.test",
            httpHost: "fallback.example.test"
        ))
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: true),
            networkMonitorFactory: nil
        )
        let fallback = expectation(description: "discovery quic failure falls back to websocket")

        client.onQUICFallbackToWebSocket = { error in
            XCTAssertEqual(error as? RealtimeQUICError, .connectionTimeout)
            fallback.fulfill()
        }
        client.start(request: RealtimeConnectionRequest(
            url: fallbackURL,
            token: "token-1",
            webSocketDialMetadata: metadata,
            quicRequest: discoveryQUICRequest(token: "token-1")
        ))

        await fulfillment(of: [fallback], timeout: 1)
        XCTAssertEqual(quicTransport.requests().count, 1)
        XCTAssertEqual(webSocketTransport.requestedURLs(), [fallbackURL])
        XCTAssertEqual(webSocketTransport.requestedRequests().first?.webSocketDialMetadata, metadata)
        XCTAssertEqual(socket.resumeCount(), 1)
        XCTAssertEqual(sentPacketTypes(socket).first, "connect")

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientPassesWSSDialMetadataToRequestAwareTransport() throws {
        let socket = FakeRealtimeWebSocketTask()
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = FakeRealtimeQUICTransport(result: .success(FakeRealtimeQUICConnection()))
        let metadata = try XCTUnwrap(RealtimeWebSocketDialMetadata(
            dialHost: "203.0.113.10",
            port: 443,
            tlsServerName: "im-a.example.test",
            httpHost: "im-a.example.test"
        ))
        let url = try XCTUnwrap(URL(string: "wss://im-a.example.test/im/ws?token=url-token&trace=1"))
        let sanitizedURL = try XCTUnwrap(URL(string: "wss://im-a.example.test/im/ws?trace=1"))
        let client = RealtimeClient(
            transport: transport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            networkMonitorFactory: nil
        )

        client.start(request: RealtimeConnectionRequest(
            url: url,
            token: "token-1",
            webSocketDialMetadata: metadata
        ))

        XCTAssertTrue(quicTransport.requests().isEmpty)
        XCTAssertEqual(transport.requestedURLs(), [sanitizedURL])
        XCTAssertEqual(transport.requestedRequests().first?.webSocketDialMetadata, metadata)
        XCTAssertEqual(socket.resumeCount(), 1)
        XCTAssertEqual(sentPacketTypes(socket).first, "connect")

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeQUICConfigurationRequiresExplicitFlagAndDomainEndpoint() throws {
        let domainURL = try XCTUnwrap(URL(string: "quic://quic.example.test:8443/im/quic"))
        let disabled = RealtimeQUICConfiguration(isEnabled: false, endpointURL: domainURL)
        XCTAssertNil(disabled.connectionRequest(token: "token-1"))

        let enabled = RealtimeQUICConfiguration(isEnabled: true, endpointURL: domainURL, tlsServerName: "quic.example.test")
        XCTAssertNotNil(enabled.connectionRequest(token: "token-1"))
        let ipHintRequest = try XCTUnwrap(enabled.connectionRequest(
            endpointURL: domainURL,
            token: "token-1",
            tlsServerName: "quic.example.test",
            dialHost: "203.0.113.10"
        ))
        XCTAssertEqual(ipHintRequest.host, "quic.example.test")
        XCTAssertEqual(ipHintRequest.dialHost, "203.0.113.10")
        XCTAssertEqual(ipHintRequest.tlsServerName, "quic.example.test")
        XCTAssertNil(enabled.connectionRequest(
            endpointURL: domainURL,
            token: "token-1",
            tlsServerName: "quic.example.test",
            dialHost: "other.example.test"
        ))

        let ipURL = try XCTUnwrap(URL(string: "quic://203.0.113.10:8443/im/quic"))
        let ipConfig = RealtimeQUICConfiguration(isEnabled: true, endpointURL: ipURL, tlsServerName: "203.0.113.10")
        XCTAssertNil(ipConfig.connectionRequest(token: "token-1"))
    }

    func testRealtimeQUICReleaseGuardIgnoresLocalPoCResidue() throws {
        let suiteName = "im3.ios.quic-release-guard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(true, forKey: "im2.realtime.quic.enabled")
        defaults.set("quic://debug-quic.example.test:8443/im/quic", forKey: "im2.realtime.quic.url")
        defaults.set("debug-quic.example.test", forKey: "im2.realtime.quic.tlsServerName")
        defaults.set("debug_alpn", forKey: "im2.realtime.quic.alpn")
        defaults.set(900, forKey: "im2.realtime.quic.connectTimeoutMs")
        let arguments = [
            "--quic-poc-enabled",
            "--quic-poc-url=quic://argument-quic.example.test:9443/im/quic",
            "--quic-poc-tls-server-name=argument-quic.example.test"
        ]

        let releaseDefault = RealtimeQUICConfiguration.load(
            defaults: defaults,
            arguments: arguments,
            allowLocalOverride: false,
            discoveryFeatureGateEnabled: false
        )
        XCTAssertFalse(releaseDefault.isEnabled)
        XCTAssertNil(releaseDefault.endpointURL)
        XCTAssertNil(releaseDefault.tlsServerName)
        XCTAssertEqual(releaseDefault.alpn, RealtimeQUICConfiguration.defaultALPN)

        let releaseDiscoveryGate = RealtimeQUICConfiguration.load(
            defaults: defaults,
            arguments: arguments,
            allowLocalOverride: false,
            discoveryFeatureGateEnabled: true
        )
        XCTAssertTrue(releaseDiscoveryGate.isEnabled)
        XCTAssertNil(releaseDiscoveryGate.endpointURL)
        XCTAssertNil(releaseDiscoveryGate.tlsServerName)

        let debugLocal = RealtimeQUICConfiguration.load(
            defaults: defaults,
            arguments: arguments,
            allowLocalOverride: true,
            discoveryFeatureGateEnabled: false
        )
        XCTAssertTrue(debugLocal.isEnabled)
        XCTAssertEqual(debugLocal.endpointURL?.absoluteString, "quic://argument-quic.example.test:9443/im/quic")
        XCTAssertEqual(debugLocal.tlsServerName, "argument-quic.example.test")
    }

    func testNWWebSocketIPHintUsesURLConnectEndpointAndSingleDomainHostHeader() throws {
        let metadata = try XCTUnwrap(RealtimeWebSocketDialMetadata(
            dialHost: "203.0.113.10",
            port: 19006,
            tlsServerName: "im-a.example.test",
            httpHost: "im-a.example.test"
        ))
        let originalURL = try XCTUnwrap(URL(string: "wss://im-a.example.test:19006/im/ws?token=url-token"))
        let connectURL = try XCTUnwrap(NWRealtimeWebSocketTask.dialURL(for: originalURL, metadata: metadata))

        XCTAssertEqual(connectURL.scheme, "wss")
        XCTAssertEqual(connectURL.host, "203.0.113.10")
        XCTAssertEqual(connectURL.port, 19006)
        XCTAssertEqual(connectURL.path, "/im/ws")
        XCTAssertNil(URLComponents(url: connectURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(metadata.tlsServerName, "im-a.example.test")
        XCTAssertEqual(metadata.httpHost, "im-a.example.test")

        let capturedHeaders = try captureNetworkWebSocketClientHeaders(
            pathAndQuery: "/im/ws",
            httpHost: metadata.httpHost
        )
        let hostHeaders = capturedHeaders.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "host"
        }

        XCTAssertEqual(hostHeaders.count, 1)
        XCTAssertEqual(hostHeaders.first?.value, "im-a.example.test")
        XCTAssertFalse(hostHeaders.contains { $0.value == "127.0.0.1" || $0.value == "203.0.113.10" })
        XCTAssertFalse(capturedHeaders.contains {
            ["authorization", "im_token", "token"].contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        })
    }

    func testNWWebSocketIPHintRetryAfterCapabilityIsExplicitlyUnavailable() throws {
        let metadata = try XCTUnwrap(RealtimeWebSocketDialMetadata(
            dialHost: "203.0.113.10",
            port: 443,
            tlsServerName: "im-a.example.test",
            httpHost: "im-a.example.test"
        ))
        let task = try XCTUnwrap(NWRealtimeWebSocketTask(
            url: try XCTUnwrap(URL(string: "wss://im-a.example.test/im/ws")),
            metadata: metadata
        ))

        XCTAssertNil(task.realtimeRetryAfter)
    }

    func testURLSessionWebSocketUsesActualRetryAfterFrom429UpgradeResponse() async throws {
        let server = try WebSocketUpgradeRejectionServer(retryAfter: "17")
        let url = try server.start()
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: url)

        task.resume()
        do {
            _ = try await task.receive()
            XCTFail("429 WebSocket upgrade unexpectedly succeeded")
        } catch {
            // The rejected Upgrade is expected; its HTTP response remains available on the task.
        }

        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(try XCTUnwrap(task.realtimeRetryAfter), 17, accuracy: 0.001)
        task.cancel(with: .goingAway, reason: nil)
    }

    func testNWWebSocketReceiveCompleteTextFrameReturnsString() throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "test-complete-websocket-text",
            metadata: [metadata]
        )

        let message = try NWRealtimeWebSocketTask.decodeReceivedMessage(
            data: Data(realtimeEnvelopeString(type: "connect_ack").utf8),
            context: context,
            isComplete: true
        )

        guard case .string(let text)? = message else {
            XCTFail("Expected text websocket message")
            return
        }
        XCTAssertEqual(text, realtimeEnvelopeString(type: "connect_ack"))
    }

    func testNWWebSocketTransportDoesNotInstallTrustBypass() throws {
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BlueStoneIM")
            .appendingPathComponent("RealtimeTransport.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains("sec_protocol_options_set_verify_block"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("trustall"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("trust all"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("disable certificate"))
    }

    func testRealtimeClientUsesInjectedWireCodecForIncomingEnvelope() throws {
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string("codec-realtime-envelope")
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let wireCodec = RecordingRealtimeWireCodec()
        let client = RealtimeClient(
            transport: transport,
            wireCodec: wireCodec,
            requestIDProvider: { _ in "req-1" },
            networkMonitorFactory: nil
        )
        let url = try XCTUnwrap(URL(string: "ws://example.test/im/ws"))
        let connected = expectation(description: "connect ack handled")

        client.onConnected = {
            connected.fulfill()
        }
        client.start(url: url, token: "token-1")

        wait(for: [connected], timeout: 1)
        XCTAssertEqual(wireCodec.decodedTypeNames(), ["RealtimeEnvelope"])
        XCTAssertEqual(wireCodec.decodedInputTexts(), ["codec-realtime-envelope"])

        client.disconnect(shouldReconnect: false)
        XCTAssertEqual(socket.cancelCount(), 1)
    }

	func testRealtimeClientUsesSingleGlobalOwnerCanonicalDedupeAndNoPseudoCursorWire() async throws {
		let firstAck = #"{"type":"connect_ack","request_id":"ack-1","payload":{}}"#
		let canonicalMessage = #"{"type":"message","request_id":"event-1","payload":{"message":{"message_id":"message-42","channel_id":"group-1","content":"hello"}}}"#
		let firstSocket = FakeRealtimeWebSocketTask(
			receiveMessages: [.string(firstAck), .string(canonicalMessage), .string(canonicalMessage)]
		)
		let secondSocket = FakeRealtimeWebSocketTask(
			receiveMessages: [.string(#"{"type":"connect_ack","request_id":"ack-2","payload":{}}"#)]
		)
		let continuity = IMRuntimeWebSocketContinuity()
		let firstTransport = FakeRealtimeWebSocketTransport(socket: firstSocket)
		let secondTransport = FakeRealtimeWebSocketTransport(socket: secondSocket)
		let firstClient = RealtimeClient(
			transport: firstTransport,
			requestIDProvider: { _ in "ack-1" },
			networkMonitorFactory: nil,
			continuity: continuity
		)
		let secondClient = RealtimeClient(
			transport: secondTransport,
			requestIDProvider: { _ in "ack-2" },
			networkMonitorFactory: nil,
			continuity: continuity
		)
		let firstDelivery = expectation(description: "canonical message delivered exactly once")
		var deliveredMessageIDs: [String] = []
		firstClient.onEnvelope = { envelope in
			deliveredMessageIDs.append(envelope.payload["message"]?.objectValue?["message_id"]?.stringValue ?? "")
			firstDelivery.fulfill()
		}
		let primaryURL = try XCTUnwrap(URL(string: "wss://ws-primary.example.com/im/ws"))
		let backupURL = try XCTUnwrap(URL(string: "wss://ws-backup.example.net/im/ws"))

		firstClient.start(url: primaryURL, token: "token-1")
		secondClient.start(url: backupURL, token: "token-2")
		await fulfillment(of: [firstDelivery], timeout: 1)
		try await Task.sleep(nanoseconds: 20_000_000)
		firstSocket.enqueue(.string(firstAck))
		firstSocket.enqueue(.string(canonicalMessage))
		firstClient.start(url: backupURL, token: "token-rotated")
		for _ in 0..<50 where firstSocket.resumeCount() < 2 {
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		try await Task.sleep(nanoseconds: 20_000_000)

		XCTAssertEqual(deliveredMessageIDs, ["message-42"])
		XCTAssertEqual(firstSocket.resumeCount(), 2)
		XCTAssertEqual(secondSocket.resumeCount(), 0)
		XCTAssertTrue(secondTransport.requestedURLs().isEmpty)
		let connectPayloads = try firstSocket.sentStrings().compactMap { packet -> [String: Any]? in
			guard let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any],
			      object["type"] as? String == "connect" else { return nil }
			return object["payload"] as? [String: Any]
		}
		XCTAssertEqual(connectPayloads.count, 2)
		XCTAssertTrue(connectPayloads.allSatisfy { Set($0.keys) == ["token"] })

		firstClient.disconnect(shouldReconnect: false)
		secondClient.start(url: backupURL, token: "token-2")
		for _ in 0..<50 where secondSocket.resumeCount() == 0 {
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTAssertEqual(secondSocket.resumeCount(), 1)
		secondClient.disconnect(shouldReconnect: false)
	}

    func testRTCExactReplayAcrossMessagePushAndSendAckCountsUnreadOnce() async throws {
        let message = rtcWireMessage()
        let result = try await ingestRTCWireFrames([
            rtcWireEnvelope(message, type: "message"),
            rtcWireEnvelope(message, type: "message_push", nested: false),
            rtcWireEnvelope(message, type: "send_ack")
        ])

        XCTAssertEqual(result.deliveredTypes, ["message", "message_push", "send_ack"])
        XCTAssertEqual(result.conversation.messages.map(\.id), ["rtc-message-1"])
        XCTAssertEqual(result.conversation.unread, 1)
        XCTAssertEqual(result.conversation.messageCoveredThroughSeq, 1)
        XCTAssertFalse(result.conversation.messageCoverageRequiresRecovery)
        XCTAssertEqual(result.readableSequence, 1)
    }

    func testRTCWireConflictsReachAuthorityMergeAndPreserveOriginalAndAckBoundary() async throws {
        let original = rtcWireMessage()
        var payloadConflict = original
        var changedPayload = try XCTUnwrap(original["payload"] as? [String: Any])
        changedPayload["ended_at"] = "2026-08-23T10:09:42Z"
        payloadConflict["payload"] = changedPayload
        var sequenceConflict = original
        sequenceConflict["channel_seq"] = 2
        var callIDConflict = original
        changedPayload = try XCTUnwrap(original["payload"] as? [String: Any])
        changedPayload["call_id"] = "different-call"
        callIDConflict["payload"] = changedPayload
        var malformed = original
        malformed["payload"] = ["call_id": "rtc-call-1", "schema_version": "broken"]
        var malformedType = original
        malformedType["content_type"] = "text"
        malformedType["payload"] = ["text": "invalid replacement"]
        var duplicateCall = original
        duplicateCall["message_id"] = "different-message"
        duplicateCall["channel_seq"] = 2
        var sequenceIdentityConflict = callIDConflict
        sequenceIdentityConflict["message_id"] = "different-message"

        let conflicts: [(String, [String: Any], Int64)] = [
            ("payload", payloadConflict, 0),
            ("sequence", sequenceConflict, 1),
            ("call ID", callIDConflict, 0),
            ("malformed", malformed, 0),
            ("typed to ordinary replacement", malformedType, 0),
            ("same call, different message ID", duplicateCall, 1),
            ("same sequence, different call and message IDs", sequenceIdentityConflict, 0)
        ]
        // Exercise both one ingest batch and a replay after the first message was
        // already merged. The production RealtimeClient callback installed by
        // AppState is used; no decoded-message or Store-only injection occurs.
        for (name, conflict, expectedBoundary) in conflicts {
            for flushEachFrame in [false, true] {
                let result = try await ingestRTCWireFrames([
                    rtcWireEnvelope(original, type: "message"),
                    rtcWireEnvelope(conflict, type: "message_push"),
                    rtcWireEnvelope(ordinaryWireMessage(id: "after-gap", sequence: 3), type: "send_ack")
                ], flushEachFrame: flushEachFrame)
                let label = "\(name), flushEachFrame=\(flushEachFrame)"
                XCTAssertEqual(result.deliveredTypes.count, 3, label)
                let record = try XCTUnwrap(result.conversation.messages.first(where: { $0.id == "rtc-message-1" })?.rtcCallRecord)
                XCTAssertEqual(record.callID, "rtc-call-1", label)
                XCTAssertEqual(record.endedAt, ISO8601DateFormatter().date(from: "2026-08-23T10:08:42Z"), label)
                XCTAssertEqual(result.conversation.messages.map(\.id), ["rtc-message-1", "after-gap"], label)
                XCTAssertEqual(result.conversation.unread, 2, label)
                XCTAssertTrue(result.conversation.messageCoverageRequiresRecovery, label)
                XCTAssertEqual(result.conversation.messageCoveredThroughSeq, expectedBoundary, label)
                // This is the existing Store boundary consumed by read ACKs;
                // later accepted messages must not bridge an RTC conflict.
                XCTAssertEqual(result.readableSequence, expectedBoundary, label)
                XCTAssertEqual(result.recoveryTarget?.afterSeq, expectedBoundary, label)
                XCTAssertEqual(result.recoveryTarget?.throughSeq, 3, label)
            }
        }
    }

    func testRTCNestedContentTypeAndMalformedReplayBypassContinuity() async throws {
        var original = rtcWireMessage()
        original.removeValue(forKey: "content_type")
        var payload = try XCTUnwrap(original["payload"] as? [String: Any])
        payload["content_type"] = " RTC_CALL_RECORD "
        original["payload"] = payload
        var malformed = original
        payload["schema_version"] = -1
        malformed["payload"] = payload
        let result = try await ingestRTCWireFrames([
            rtcWireEnvelope(original, type: "message", nested: false),
            rtcWireEnvelope(malformed, type: "send_ack", nested: false)
        ])
        XCTAssertEqual(result.deliveredTypes, ["message", "send_ack"])
        XCTAssertEqual(result.conversation.messages.count, 1)
        XCTAssertEqual(result.conversation.messages.first?.rtcCallRecord?.callID, "rtc-call-1")
        XCTAssertEqual(result.conversation.unread, 1)
        XCTAssertTrue(result.conversation.messageCoverageRequiresRecovery)
        XCTAssertEqual(result.readableSequence, 0)
    }

    func testOrdinaryWireMessagesRetainMessageIDDedupeAcrossEnvelopeTypes() async throws {
        let original = ordinaryWireMessage(id: "text-1", sequence: 1)
        var changed = ordinaryWireMessage(id: "text-1", sequence: 2)
        changed["payload"] = ["text": "replacement"]
        let result = try await ingestRTCWireFrames([
            rtcWireEnvelope(original, type: "message"),
            rtcWireEnvelope(original, type: "message_push", nested: false),
            rtcWireEnvelope(changed, type: "send_ack")
        ])
        XCTAssertEqual(result.deliveredTypes, ["message"])
        XCTAssertEqual(result.conversation.messages.map(\.id), ["text-1"])
        XCTAssertEqual(result.conversation.messages.first?.text, "ordinary")
        XCTAssertEqual(result.conversation.unread, 1)
        XCTAssertEqual(result.readableSequence, 1)
    }

    private func rtcWireMessage() -> [String: Any] {
        [
            "message_id": "rtc-message-1", "channel_id": "caller-1:callee-1",
            "channel_type": "direct", "channel_seq": 1, "from_uid": "caller-1",
            "content_type": "rtc_call_record", "created_at": "2026-08-23T10:08:42Z",
            "payload": [
                "schema_version": 1, "call_id": "rtc-call-1", "call_type": "audio",
                "caller_uid": "caller-1", "callee_uid": "callee-1",
                "final_outcome": "no_answer", "started_at": "2026-08-23T10:00:00Z",
                "ended_at": "2026-08-23T10:08:42Z", "duration_seconds": 0,
                "reason_code": "no_answer", "text": "通话记录", "fallback_text": "通话记录"
            ]
        ]
    }

    private func ordinaryWireMessage(id: String, sequence: Int) -> [String: Any] {
        [
            "message_id": id, "channel_id": "caller-1:callee-1", "channel_type": "direct",
            "channel_seq": sequence, "from_uid": "caller-1", "content_type": "text",
            "created_at": "2026-08-23T10:10:00Z", "payload": ["text": "ordinary"]
        ]
    }

    private func rtcWireEnvelope(_ message: [String: Any], type: String, nested: Bool = true) throws -> String {
        let payload: [String: Any] = nested ? ["message": message] : message
        let object: [String: Any] = ["type": type, "payload": payload]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func ingestRTCWireFrames(
        _ frames: [String],
        flushEachFrame: Bool = false
    ) async throws -> (
        conversation: Conversation,
        deliveredTypes: [String],
        readableSequence: Int64,
        recoveryTarget: ConversationStore.MessageSequenceRecoveryTarget?
    ) {
        let socket = FakeRealtimeWebSocketTask(receiveMessages:
            [.string(#"{"type":"connect_ack","request_id":"rtc-ack","payload":{}}"#)]
                + frames.map { .string($0) }
                + [.string(#"{"type":"test_barrier","payload":{}}"#)]
        )
        let client = RealtimeClient(
            transport: FakeRealtimeWebSocketTransport(socket: socket),
            requestIDProvider: { _ in "rtc-ack" },
            networkMonitorFactory: nil,
            continuity: IMRuntimeWebSocketContinuity()
        )
        let context = IMAPIContext(
            platformToken: nil, accountID: "rtc-wire-test", tenantID: "rtc-wire-\(UUID().uuidString)",
            imUID: "callee-1", imToken: "unit-test-token", platformAuthSession: nil,
            tenantAuthSession: nil, appID: IMAPIContext.canonicalIOSAppID, deviceID: "rtc-wire-test"
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            httpTransport: RTCWireOfflineHTTPTransport()
        )
        let state = AppState(
            api: api, realtimeClient: client, voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messageStore: RTCWireEmptyMessageStore(),
            apiContextOverride: context
        )
        state.isAuthenticated = true
        let downstream = try XCTUnwrap(client.onEnvelope)
        let drained = expectation(description: "raw RTC envelopes reached AppState")
        var delivered: [String] = []
        client.onConnected = nil
        client.onEnvelope = { envelope in
            if envelope.type == "test_barrier" {
                state.flushPendingRealtimeMessagesForTesting()
                drained.fulfill()
                return
            }
            delivered.append(envelope.type)
            downstream(envelope)
            if flushEachFrame { state.flushPendingRealtimeMessagesForTesting() }
        }
        defer {
            state.isAuthenticated = false
            client.disconnect(shouldReconnect: false)
            client.onEnvelope = nil
        }
        client.start(url: try XCTUnwrap(URL(string: "wss://example.test/im/ws")), token: "unit-test-token")
        await fulfillment(of: [drained], timeout: 2)
        let conversation = try XCTUnwrap(state.conversations.first(where: { $0.id == "caller-1:callee-1" }))
        return (
            conversation, delivered,
            state.conversationStore.latestReadableSequence(in: conversation),
            state.conversationStore.messageSequenceRecoveryTarget(for: conversation)
        )
    }

    func testRealtimeClientExpandsBatchFramesInOrder() async throws {
        let batch = """
        {"type":"batch","request_id":"batch-1","payload":{"frames":[{"type":"connect_ack","request_id":"ack-1","payload":{}},{"type":"message_push","request_id":"msg-1","payload":{"channel_id":"g1","channel_type":"group"}},{"payload":{"ignored":true}},{"type":"subscribe_ack","request_id":"sub-1","payload":{"channel_id":"g1","channel_type":"group"}}]}}
        """
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string(batch)
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            quicTransport: FakeRealtimeQUICTransport(result: .success(FakeRealtimeQUICConnection())),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            requestIDProvider: { _ in "ack-1" },
            networkMonitorFactory: nil
        )
        let connected = expectation(description: "connect ack inside batch handled")
        let message = expectation(description: "message frame inside batch forwarded")
        var receivedTypes: [String] = []

        client.onConnected = {
            connected.fulfill()
        }
        client.onEnvelope = { envelope in
            receivedTypes.append(envelope.type)
            if envelope.type == "message_push" {
                XCTAssertEqual(envelope.requestID, "msg-1")
                XCTAssertEqual(envelope.payload["channel_id"]?.stringValue, "g1")
                message.fulfill()
            }
        }
        client.start(url: try XCTUnwrap(URL(string: "ws://example.test/im/ws")), token: "token-1")

        await fulfillment(of: [connected, message], timeout: 1)
        XCTAssertEqual(receivedTypes, ["message_push"])

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientIterativelyExpandsNestedBatchAndHandlesControlFrames() async throws {
        let batch = """
        {"type":"batch","request_id":"outer-batch","payload":{"frames":[{"type":"pong","request_id":"pong-1","payload":{}},{"type":"batch","request_id":"inner-batch","payload":{"frames":[{"type":"connect_ack","request_id":"ack-1","payload":{}},{"type":"message_push","request_id":"msg-1","payload":{"channel_id":"g1","channel_type":"group"}},{"type":"subscribe_ack","request_id":"sub-1","payload":{"channel_id":"g1","channel_type":"group"}}]}}]}}
        """
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string(batch)
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            quicTransport: FakeRealtimeQUICTransport(result: .success(FakeRealtimeQUICConnection())),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            requestIDProvider: { _ in "ack-1" },
            networkMonitorFactory: nil
        )
        let stateChanged = expectation(description: "pong inside batch marks connection alive")
        let connected = expectation(description: "nested connect ack handled")
        let message = expectation(description: "nested business frame forwarded")
        var receivedTypes: [String] = []

        client.onConnectionStateChanged = { connected in
            if connected {
                stateChanged.fulfill()
            }
        }
        client.onConnected = {
            connected.fulfill()
        }
        client.onEnvelope = { envelope in
            receivedTypes.append(envelope.type)
            if envelope.type == "message_push" {
                XCTAssertEqual(envelope.requestID, "msg-1")
                XCTAssertEqual(envelope.payload["channel_id"]?.stringValue, "g1")
                message.fulfill()
            }
        }
        client.start(url: try XCTUnwrap(URL(string: "ws://example.test/im/ws")), token: "token-1")

        await fulfillment(of: [stateChanged, connected, message], timeout: 1)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(receivedTypes, ["message_push"])

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeBatchExpanderCapsMaliciousDepthWithoutRecursion() {
        var nested: JSONValue = .object([
            "type": .string("message_push"),
            "request_id": .string("deep-message"),
            "payload": .object(["message_id": .string("deep-1")])
        ])
        for index in 0..<(RealtimeBatchExpander.maximumDepth + 4) {
            nested = .object([
                "type": .string("batch"),
                "request_id": .string("nested-\(index)"),
                "payload": .object(["frames": .array([nested])])
            ])
        }
        let root = RealtimeEnvelope(
            type: "batch",
            requestID: "root",
            payload: ["frames": .array([nested])]
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = RealtimeBatchExpander.expand(root)
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertGreaterThan(result.droppedForDepth, 0)
        XCTAssertLessThanOrEqual(
            result.visitedElements,
            RealtimeBatchExpander.maximumElements
        )
        XCTAssertLessThan(elapsed, 1, "malicious nesting must remain main-thread bounded")
    }

    func testRealtimeBatchWireLimitBoundsDecodeInput() {
        XCTAssertTrue(
            RealtimeBatchExpander.acceptsWirePayload(
                byteCount: RealtimeBatchExpander.maximumWireBytes
            )
        )
        XCTAssertFalse(
            RealtimeBatchExpander.acceptsWirePayload(
                byteCount: RealtimeBatchExpander.maximumWireBytes + 1
            )
        )
    }

    func testRealtimeBatchExpanderCapsWideBatchAndPreservesAcceptedOrder() {
        let inputCount = RealtimeBatchExpander.maximumElements + 88
        let frames = (0..<inputCount).map { index in
            JSONValue.object([
                "type": .string("message_push"),
                "request_id": .string("msg-\(index)"),
                "payload": .object(["message_id": .string("m-\(index)")])
            ])
        }
        let result = RealtimeBatchExpander.expand(
            RealtimeEnvelope(
                type: "batch",
                requestID: "wide",
                payload: ["frames": .array(frames)]
            )
        )

        XCTAssertEqual(result.visitedElements, RealtimeBatchExpander.maximumElements)
        XCTAssertEqual(result.frames.count, RealtimeBatchExpander.maximumFrames)
        XCTAssertEqual(result.frames.first?.requestID, "msg-0")
        XCTAssertEqual(
            result.frames.last?.requestID,
            "msg-\(RealtimeBatchExpander.maximumFrames - 1)"
        )
        XCTAssertEqual(
            result.droppedForLimit,
            inputCount - RealtimeBatchExpander.maximumFrames
        )
    }

    func testRealtimeBatchExpanderIsolatesMalformedElementsAndKeepsDuplicatesInWireOrder() {
        let message: [String: JSONValue] = [
            "type": .string("message_push"),
            "request_id": .string("duplicate"),
            "payload": .object(["message_id": .string("m-1")])
        ]
        let result = RealtimeBatchExpander.expand(
            RealtimeEnvelope(
                type: "batch",
                requestID: "mixed",
                payload: [
                    "frames": .array([
                        .int(7),
                        .object(["payload": .object([:])]),
                        .object(message),
                        .object([
                            "type": .string("batch"),
                            "payload": .object(["wrong": .array([])])
                        ]),
                        .object(message)
                    ])
                ]
            )
        )

        XCTAssertEqual(result.frames.map(\.requestID), ["duplicate", "duplicate"])
        XCTAssertEqual(result.malformedElements, 3)
        XCTAssertEqual(result.droppedForDepth, 0)
        XCTAssertEqual(result.droppedForLimit, 0)
    }

    func testRealtimeClientClosesSocketAfterTwoMissedPongs() throws {
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string(realtimeEnvelopeString(type: "connect_ack"))
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            heartbeatIntervalNanoseconds: 10_000_000,
            maximumMissedPongs: 2,
            reconnectDelayScale: 0,
            reconnectJitterProvider: { 0.30 },
            requestIDProvider: deterministicRealtimeRequestID,
            networkMonitorFactory: nil
        )
        let url = try XCTUnwrap(URL(string: "ws://example.test/im/ws"))
        let disconnected = expectation(description: "stale socket disconnected")
        let reconnectScheduled = expectation(description: "reconnect scheduled after stale close")

        client.canReconnect = { true }
        client.onDisconnected = {
            disconnected.fulfill()
        }
        client.onReconnectScheduled = { delay in
            XCTAssertEqual(delay, 0.30, accuracy: 0.001)
            reconnectScheduled.fulfill()
        }
        client.start(url: url, token: "token-1")

        wait(for: [disconnected, reconnectScheduled], timeout: 1)
        XCTAssertEqual(socket.cancelCount(), 1)
        XCTAssertEqual(sentPacketTypes(socket).filter { $0 == "ping" }.count, 2)
    }

    func testSelfPresenceTransportStillConnectsAndHeartbeatsWhenPresenceUIIsHidden() throws {
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string(realtimeEnvelopeString(type: "connect_ack"))
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            heartbeatIntervalNanoseconds: 10_000_000,
            maximumMissedPongs: 2,
            reconnectDelayScale: 0,
            reconnectJitterProvider: { 0 },
            requestIDProvider: deterministicRealtimeRequestID,
            networkMonitorFactory: nil
        )
        let url = try XCTUnwrap(URL(string: "ws://example.test/im/ws"))
        let disconnected = expectation(description: "heartbeat terminal closes stale self session")
        let reconnectScheduled = expectation(description: "self session reconnect remains enabled")
        client.canReconnect = { true }
        client.onDisconnected = { disconnected.fulfill() }
        client.onReconnectScheduled = { _ in reconnectScheduled.fulfill() }

        client.start(url: url, token: "self-session-token")

        wait(for: [disconnected, reconnectScheduled], timeout: 1)
        XCTAssertEqual(socket.resumeCount(), 1)
        XCTAssertEqual(sentPacketTypes(socket).filter { $0 == "ping" }.count, 2)
        XCTAssertEqual(socket.cancelCodes(), [.goingAway])
        XCTAssertEqual(
            AppState.presenceStatusText(
                rawStatus: "online",
                online: true,
                policy: RemoteTenantClientPolicy(showOnlineStatus: true)
            ),
            ""
        )
    }

    func testRealtimeClientReconnectBackoffUsesFullJitterAcrossFrozenCaps() throws {
        let transport = FailingRealtimeWebSocketTransport()
        let client = RealtimeClient(
            transport: transport,
            reconnectDelayScale: 0,
            reconnectJitterProvider: { 0.25 },
            networkMonitorFactory: nil
        )
        let url = try XCTUnwrap(URL(string: "ws://example.test/im/ws"))
        let scheduled = expectation(description: "full jitter reconnect delays scheduled")
        scheduled.expectedFulfillmentCount = 8
        var delays: [TimeInterval] = []

        client.canReconnect = {
            delays.count < 8
        }
        client.connectionRequestProvider = {
            RealtimeConnectionRequest(url: url, token: "token-1")
        }
        client.onReconnectScheduled = { delay in
            delays.append(delay)
            scheduled.fulfill()
        }
        client.start(url: url, token: "token-1")

        wait(for: [scheduled], timeout: 1)
        XCTAssertEqual(delays.count, 8)
        zip(delays, [0.25, 0.50, 1.00, 2.00, 4.00, 8.00, 15.00, 15.00]).forEach { actual, expected in
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
    }

    func testRealtimeClientNetworkRecoveryInterruptsPendingBackoffAndReconnectsImmediately() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let monitor = FakeRealtimeNetworkMonitor()
        let client = RealtimeClient(
            transport: transport,
            reconnectDelayScale: 1,
            reconnectJitterProvider: { 0.25 },
            networkMonitorFactory: { monitor }
        )
        let url = try XCTUnwrap(URL(string: "ws://example.test/im/ws"))

        client.canReconnect = { true }
        client.connectionRequestProvider = {
            RealtimeConnectionRequest(url: url, token: "token-1")
        }
        client.disconnect(shouldReconnect: true)
        XCTAssertTrue(transport.requestedURLs().isEmpty)

        monitor.emit(.satisfied)
        await Task.yield()
        XCTAssertTrue(transport.requestedURLs().isEmpty)
        monitor.emit(.unsatisfied)
        await Task.yield()
        monitor.emit(.satisfied)
        monitor.emit(.satisfied)

        for _ in 0..<20 where transport.requestedURLs().isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(transport.requestedURLs(), [url])
        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientReconnectUsesLatestProviderRequestAndFiresRecoveryCallback() throws {
        let transport = FailingRealtimeWebSocketTransport()
        let client = RealtimeClient(
            transport: transport,
            reconnectDelayScale: 0,
            reconnectJitterProvider: { 0.25 },
            networkMonitorFactory: nil
        )
        let acceleratedURL = try XCTUnwrap(URL(string: "wss://ga.example.test/im/ws"))
        let directURL = try XCTUnwrap(URL(string: "wss://direct.example.test/im/ws"))
        let recovered = expectation(description: "reconnect attempt triggers recovery hook")

        client.canReconnect = {
            transport.requestedURLs().count < 2
        }
        client.connectionRequestProvider = {
            RealtimeConnectionRequest(url: directURL, token: "token-1")
        }
        client.onReconnectAttempt = {
            recovered.fulfill()
        }
        client.start(url: acceleratedURL, token: "token-1")

        wait(for: [recovered], timeout: 1)
        XCTAssertEqual(transport.requestedURLs(), [acceleratedURL, directURL])
    }

    func testRealtimeClientRequiresExactConnectAckRequestID() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            acknowledgementTimeoutNanoseconds: 500_000_000,
            requestIDProvider: deterministicRealtimeRequestID,
            networkMonitorFactory: nil
        )
        let connected = expectation(description: "matching connect ack accepted")
        var events: [RealtimeConnectionDiagnostic] = []
        client.onDiagnostic = { event, _ in events.append(event) }
        var connectedCount = 0
        client.onConnected = {
            connectedCount += 1
            connected.fulfill()
        }

        client.start(
            url: try XCTUnwrap(URL(string: "wss://im.example.test/im/ws")),
            token: "token-1"
        )
        XCTAssertEqual(client.connectionState, .awaitingAck)

        socket.enqueue(.string(realtimeEnvelopeString(type: "connect_ack", requestID: "connect-other")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(client.connectionState, .awaitingAck)
        XCTAssertEqual(connectedCount, 0)
        XCTAssertEqual(events.map(\.result), [.started])

        socket.enqueue(.string(realtimeEnvelopeString(type: "connect_ack")))
        await fulfillment(of: [connected], timeout: 1)
        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertEqual(connectedCount, 1)
        XCTAssertEqual(events.map(\.result), [.started, .acknowledged])

        client.disconnect(shouldReconnect: false)
        XCTAssertEqual(client.connectionState, .idle)
    }

    func testRealtimeClientAckDeadlineIsAbsoluteAndIgnoresPreAckTraffic() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            acknowledgementTimeoutNanoseconds: 45_000_000,
            reconnectDelayScale: 1,
            reconnectJitterProvider: { 0.5 },
            requestIDProvider: deterministicRealtimeRequestID,
            networkMonitorFactory: nil
        )
        let disconnected = expectation(description: "ack deadline closes websocket")
        let scheduled = expectation(description: "ack deadline enters backoff")
        client.canReconnect = { true }
        client.onDisconnected = { disconnected.fulfill() }
        client.onReconnectScheduled = { delay in
            XCTAssertEqual(delay, 0.5, accuracy: 0.001)
            scheduled.fulfill()
        }

        let startedAt = Date()
        client.start(
            url: try XCTUnwrap(URL(string: "wss://im.example.test/im/ws")),
            token: "token-1"
        )
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 8_000_000)
            socket.enqueue(.string(realtimeEnvelopeString(type: "pong")))
        }

        await fulfillment(of: [disconnected, scheduled], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
        XCTAssertEqual(client.connectionState, .backoff)
        XCTAssertEqual(socket.cancelCount(), 1)
        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientQUICAckTimeoutFallsBackToWSSOnlyOnceInGeneration() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicConnection = FakeRealtimeQUICConnection()
        let quicTransport = FakeRealtimeQUICTransport(result: .success(quicConnection))
        let quicURL = try XCTUnwrap(URL(string: "quic://quic.example.test:443/im/quic"))
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: true, endpointURL: quicURL),
            acknowledgementTimeoutNanoseconds: 35_000_000,
            reconnectDelayScale: 1,
            reconnectJitterProvider: { 1 },
            requestIDProvider: deterministicRealtimeRequestID,
            networkMonitorFactory: nil
        )
        let fallback = expectation(description: "quic ack timeout falls back")
        let backoff = expectation(description: "wss ack timeout enters backoff")
        var fallbackCount = 0
        var fallbackGeneration: UInt64?
        client.canReconnect = { true }
        client.onQUICFallbackToWebSocket = { _ in
            fallbackCount += 1
            fallbackGeneration = client.connectionGeneration
            fallback.fulfill()
        }
        client.onReconnectScheduled = { _ in backoff.fulfill() }

        client.start(
            url: try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws")),
            token: "token-1"
        )
        let initialGeneration = client.connectionGeneration
        XCTAssertEqual(client.connectionState, .dialing)

        await fulfillment(of: [fallback, backoff], timeout: 1)
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertEqual(fallbackGeneration, initialGeneration)
        XCTAssertEqual(quicTransport.requests().count, 1)
        XCTAssertEqual(webSocketTransport.requestedURLs().count, 1)
        XCTAssertGreaterThanOrEqual(quicConnection.cancelCount(), 1)
        XCTAssertEqual(socket.cancelCount(), 1)
        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientCancelsHangingQUICDialBeforeSingleSameGenerationWSSFallback() async throws {
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = HangingRealtimeQUICTransport()
        let quicURL = try XCTUnwrap(URL(string: "quic://quic.example.test:443/im/quic"))
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: true, endpointURL: quicURL),
            acknowledgementTimeoutNanoseconds: 40_000_000,
            requestIDProvider: deterministicRealtimeRequestID,
            networkMonitorFactory: nil
        )
        let fallback = expectation(description: "hanging quic dial falls back after cancellation")
        let connected = expectation(description: "fallback websocket accepts matching ack")
        var fallbackCount = 0
        var fallbackGeneration: UInt64?
        client.canReconnect = { false }
        client.onQUICFallbackToWebSocket = { _ in
            fallbackCount += 1
            fallbackGeneration = client.connectionGeneration
            XCTAssertEqual(quicTransport.cancelCount(), 1)
            XCTAssertTrue(webSocketTransport.requestedURLs().isEmpty)
            fallback.fulfill()
        }
        client.onConnected = { connected.fulfill() }

        let startedAt = Date()
        client.start(
            url: try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws")),
            token: "token-1"
        )
        let initialGeneration = client.connectionGeneration

        await fulfillment(of: [fallback], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertEqual(fallbackGeneration, initialGeneration)
        XCTAssertEqual(quicTransport.requestCount(), 1)
        XCTAssertEqual(quicTransport.cancelCount(), 1)
        XCTAssertEqual(webSocketTransport.requestedURLs().count, 1)

        socket.enqueue(.string(realtimeEnvelopeString(type: "connect_ack")))
        await fulfillment(of: [connected], timeout: 1)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertEqual(client.connectionGeneration, initialGeneration)
        XCTAssertEqual(client.connectionState, .connected)
        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientGenerationDeadlineCapsQUICAndWSSFallbackAtEightSeconds() async throws {
        let clock = TestRealtimeMonotonicClock()
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = HangingRealtimeQUICTransport()
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(
                isEnabled: true,
                endpointURL: try XCTUnwrap(URL(string: "quic://quic.example.test:443/im/quic"))
            ),
            acknowledgementTimeoutNanoseconds: 5 * realtimeTestSecond,
            reconnectJitterProvider: { 1 },
            requestIDProvider: deterministicRealtimeRequestID,
            monotonicClock: clock,
            networkMonitorFactory: nil
        )
        let fallback = expectation(description: "quic local deadline falls back to websocket")
        let backoff = expectation(description: "shared generation deadline enters backoff")
        var fallbackCount = 0
        var fallbackGeneration: UInt64?
        client.canReconnect = { true }
        client.onQUICFallbackToWebSocket = { _ in
            fallbackCount += 1
            fallbackGeneration = client.connectionGeneration
            fallback.fulfill()
        }
        client.onReconnectScheduled = { _ in backoff.fulfill() }

        client.start(
            url: try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws")),
            token: "token-1"
        )
        let initialGeneration = client.connectionGeneration
        await waitForPendingDeadlines([5 * realtimeTestSecond], clock: clock)

        clock.advance(toNanoseconds: 5 * realtimeTestSecond)
        await fulfillment(of: [fallback], timeout: 1)
        await waitForPendingDeadlines([8 * realtimeTestSecond], clock: clock)
        XCTAssertEqual(fallbackGeneration, initialGeneration)
        XCTAssertEqual(quicTransport.cancelCount(), 1)
        XCTAssertEqual(webSocketTransport.requestedURLs().count, 1)

        clock.advance(toNanoseconds: 8 * realtimeTestSecond - 1)
        await Task.yield()
        XCTAssertEqual(client.connectionState, .awaitingAck)

        clock.advance(toNanoseconds: 8 * realtimeTestSecond)
        await fulfillment(of: [backoff], timeout: 1)
        XCTAssertEqual(clock.nowNanoseconds(), 8 * realtimeTestSecond)
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertEqual(socket.cancelCount(), 1)
        XCTAssertEqual(client.connectionState, .backoff)
        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientDirectWSSRetainsFiveSecondLocalDeadlineWithinGenerationBudget() async throws {
        let clock = TestRealtimeMonotonicClock()
        let socket = FakeRealtimeWebSocketTask()
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            acknowledgementTimeoutNanoseconds: 5 * realtimeTestSecond,
            reconnectJitterProvider: { 1 },
            monotonicClock: clock,
            networkMonitorFactory: nil
        )
        let backoff = expectation(description: "direct websocket local deadline enters backoff")
        client.canReconnect = { true }
        client.onReconnectScheduled = { _ in backoff.fulfill() }

        client.start(
            url: try XCTUnwrap(URL(string: "wss://im.example.test/im/ws")),
            token: "token-1"
        )
        await waitForPendingDeadlines([5 * realtimeTestSecond], clock: clock)

        clock.advance(toNanoseconds: 5 * realtimeTestSecond - 1)
        await Task.yield()
        XCTAssertEqual(client.connectionState, .awaitingAck)

        clock.advance(toNanoseconds: 5 * realtimeTestSecond)
        await fulfillment(of: [backoff], timeout: 1)
        XCTAssertEqual(clock.nowNanoseconds(), 5 * realtimeTestSecond)
        XCTAssertEqual(socket.cancelCount(), 1)
        XCTAssertEqual(client.connectionState, .backoff)
        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientFastQUICFailureLeavesFiveSecondLocalBudgetForWSS() async throws {
        let clock = TestRealtimeMonotonicClock()
        let socket = FakeRealtimeWebSocketTask()
        let webSocketTransport = FakeRealtimeWebSocketTransport(socket: socket)
        let quicTransport = ClockAdvancingFailingRealtimeQUICTransport(
            clock: clock,
            failureTimeNanoseconds: realtimeTestSecond
        )
        let client = RealtimeClient(
            transport: webSocketTransport,
            quicTransport: quicTransport,
            quicConfiguration: RealtimeQUICConfiguration(
                isEnabled: true,
                endpointURL: try XCTUnwrap(URL(string: "quic://quic.example.test:443/im/quic"))
            ),
            acknowledgementTimeoutNanoseconds: 5 * realtimeTestSecond,
            reconnectJitterProvider: { 1 },
            requestIDProvider: deterministicRealtimeRequestID,
            monotonicClock: clock,
            networkMonitorFactory: nil
        )
        let fallback = expectation(description: "fast quic failure falls back")
        let backoff = expectation(description: "fallback websocket local deadline enters backoff")
        var fallbackCount = 0
        var fallbackGeneration: UInt64?
        client.canReconnect = { true }
        client.onQUICFallbackToWebSocket = { _ in
            fallbackCount += 1
            fallbackGeneration = client.connectionGeneration
            fallback.fulfill()
        }
        client.onReconnectScheduled = { _ in backoff.fulfill() }

        client.start(
            url: try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws")),
            token: "token-1"
        )
        let initialGeneration = client.connectionGeneration
        await fulfillment(of: [fallback], timeout: 1)
        await waitForPendingDeadlines([6 * realtimeTestSecond], clock: clock)
        XCTAssertEqual(fallbackGeneration, initialGeneration)
        XCTAssertEqual(quicTransport.cancelCount(), 1)
        XCTAssertEqual(webSocketTransport.requestedURLs().count, 1)

        clock.advance(toNanoseconds: 6 * realtimeTestSecond - 1)
        await Task.yield()
        XCTAssertEqual(client.connectionState, .awaitingAck)

        clock.advance(toNanoseconds: 6 * realtimeTestSecond)
        await fulfillment(of: [backoff], timeout: 1)
        XCTAssertEqual(clock.nowNanoseconds(), 6 * realtimeTestSecond)
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertEqual(client.connectionState, .backoff)
        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientTokenRotationInvalidatesOldGenerationAndRebindsOnce() async throws {
        let oldSocket = LeakyRealtimeWebSocketTask()
        let currentSocket = FakeRealtimeWebSocketTask()
        let transport = SequencedRealtimeWebSocketTransport(tasks: [oldSocket, currentSocket])
        var connectRequestIndex = 0
        let client = RealtimeClient(
            transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            acknowledgementTimeoutNanoseconds: 500_000_000,
            requestIDProvider: { type in
                if type == "connect" {
                    connectRequestIndex += 1
                    return "connect-\(connectRequestIndex)"
                }
                return "\(type)-1"
            },
            networkMonitorFactory: nil
        )
        let url = try XCTUnwrap(URL(string: "wss://im.example.test/im/ws"))
        let connected = expectation(description: "new generation ack accepted")
        var events: [RealtimeConnectionDiagnostic] = []
        client.onDiagnostic = { event, _ in events.append(event) }
        var connectedCount = 0
        client.onConnected = {
            connectedCount += 1
            connected.fulfill()
        }

        client.start(url: url, token: "token-old")
        let oldGeneration = client.connectionGeneration
        for _ in 0..<20 where !oldSocket.hasPendingReceiver() {
            await Task.yield()
        }
        XCTAssertTrue(oldSocket.hasPendingReceiver())

        client.start(url: url, token: " token-old ")
        XCTAssertEqual(transport.requestedURLs().count, 1)
        XCTAssertEqual(client.connectionGeneration, oldGeneration)

        client.start(url: url, token: "token-new")
        XCTAssertEqual(transport.requestedURLs().count, 2)
        XCTAssertGreaterThan(client.connectionGeneration, oldGeneration)
        XCTAssertEqual(oldSocket.cancelCount(), 1)

        let countBeforeStale = events.count
        oldSocket.emit(.string(realtimeEnvelopeString(type: "connect_ack", requestID: "connect-1")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(client.connectionState, .awaitingAck)
        XCTAssertEqual(connectedCount, 0)
        XCTAssertEqual(events.count, countBeforeStale, "Old generation must not publish a diagnostic")

        currentSocket.enqueue(.string(realtimeEnvelopeString(type: "connect_ack", requestID: "connect-2")))
        await fulfillment(of: [connected], timeout: 1)
        XCTAssertEqual(connectedCount, 1)
        XCTAssertEqual(events.last?.result, .acknowledged)
        XCTAssertEqual(events.last?.generation, client.connectionGeneration)
        XCTAssertEqual(try sentPacketPayloadToken(oldSocket.sentStrings()), "token-old")
        XCTAssertEqual(try sentPacketPayloadToken(currentSocket.sentStrings()), "token-new")
        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientUsesActualRetryAfterAsCappedBackoffFloor() throws {
        let transport = FailingRealtimeWebSocketTransport(retryAfter: 999)
        let client = RealtimeClient(
            transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            reconnectDelayScale: 1,
            reconnectJitterProvider: { 0 },
            networkMonitorFactory: nil
        )
        var events: [RealtimeConnectionDiagnostic] = []
        client.onDiagnostic = { event, _ in events.append(event) }
        let scheduled = expectation(description: "retry after floor applied")
        client.canReconnect = { true }
        client.onReconnectScheduled = { delay in
            XCTAssertEqual(delay, 300, accuracy: 0.001)
            scheduled.fulfill()
        }

        client.start(
            url: try XCTUnwrap(URL(string: "wss://im.example.test/im/ws")),
            token: "token-1"
        )

        wait(for: [scheduled], timeout: 1)
        XCTAssertEqual(client.connectionState, .backoff)
        XCTAssertEqual(events.map(\.result), [.started, .failure(.offline)])
        XCTAssertEqual(events.last?.stage, .socket)
        client.disconnect(shouldReconnect: false)
    }

    private func waitForPendingDeadlines(
        _ expected: [UInt64],
        clock: TestRealtimeMonotonicClock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if clock.pendingDeadlines() == expected {
                return
            }
            await Task.yield()
        }
        XCTAssertEqual(clock.pendingDeadlines(), expected, file: file, line: line)
    }
}

private let realtimeTestSecond: UInt64 = 1_000_000_000

private func deterministicRealtimeRequestID(type: String) -> String {
    "\(type)-1"
}

private func realtimeEnvelopeString(type: String, requestID: String? = nil) -> String {
    let resolvedRequestID = requestID
        ?? (type == "connect_ack" ? deterministicRealtimeRequestID(type: "connect") : deterministicRealtimeRequestID(type: type))
    return #"{"type":"\#(type)","request_id":"\#(resolvedRequestID)","payload":{}}"#
}

private func sentPacketTypes(_ socket: FakeRealtimeWebSocketTask) -> [String] {
    socket.sentStrings().compactMap { text in
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["type"] as? String
    }
}

private func sentPacketPayload(_ socket: FakeRealtimeWebSocketTask) throws -> [String: Any]? {
    let packet = try XCTUnwrap(socket.sentStrings().first)
    let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any]
    return object?["payload"] as? [String: Any]
}

private func sentPacketPayloadToken(_ sentStrings: [String]) throws -> String? {
    let packet = try XCTUnwrap(sentStrings.first)
    let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any]
    let payload = object?["payload"] as? [String: Any]
    return payload?["token"] as? String
}

private func discoveryQUICRequest(token: String, path: String = "/im/quic") -> RealtimeQUICConnectionRequest {
    RealtimeQUICConnectionRequest(
        host: "im-quic.example.cn",
        port: 19006,
        path: path,
        token: token,
        alpn: "im_quic_json_v1",
        tlsServerName: "im-quic.example.cn",
        connectTimeoutNanoseconds: 3_000_000_000
    )
}

private func sentPacketPayloadToken(_ connection: FakeRealtimeQUICConnection) throws -> String? {
    let packet = try XCTUnwrap(connection.sentLineStrings().first)
    let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any]
    let payload = object?["payload"] as? [String: Any]
    return payload?["token"] as? String
}

private struct CapturedWebSocketHeader: Equatable {
    let name: String
    let value: String
}

private final class TestRealtimeMonotonicClock: RealtimeMonotonicClock, @unchecked Sendable {
    private struct Sleeper {
        let deadlineNanoseconds: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentNanoseconds: UInt64 = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []

    func nowNanoseconds() -> UInt64 {
        lock.withLock { currentNanoseconds }
    }

    func sleep(untilNanoseconds deadlineNanoseconds: UInt64) async throws {
        let sleeperID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum RegistrationResult {
                    case registered
                    case elapsed
                    case cancelled
                }
                let result = lock.withLock { () -> RegistrationResult in
                    if cancelledSleeperIDs.remove(sleeperID) != nil {
                        return .cancelled
                    }
                    if deadlineNanoseconds <= currentNanoseconds {
                        return .elapsed
                    }
                    sleepers[sleeperID] = Sleeper(
                        deadlineNanoseconds: deadlineNanoseconds,
                        continuation: continuation
                    )
                    return .registered
                }
                switch result {
                case .registered:
                    break
                case .elapsed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let sleeper = self.sleepers.removeValue(forKey: sleeperID) else {
                    self.cancelledSleeperIDs.insert(sleeperID)
                    return nil
                }
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(toNanoseconds targetNanoseconds: UInt64) {
        let dueSleepers = lock.withLock { () -> [Sleeper] in
            currentNanoseconds = max(currentNanoseconds, targetNanoseconds)
            let dueIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadlineNanoseconds <= currentNanoseconds ? id : nil
            }
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        dueSleepers.forEach { $0.continuation.resume() }
    }

    func pendingDeadlines() -> [UInt64] {
        lock.withLock {
            sleepers.values.map(\.deadlineNanoseconds).sorted()
        }
    }
}

private final class WebSocketUpgradeRejectionServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.jianhuitong.tests.websocket-429")
    private let lock = NSLock()
    private let responseData: Data
    private var connections: [NWConnection] = []

    init(retryAfter: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        responseData = Data(
            "HTTP/1.1 429 Too Many Requests\r\nRetry-After: \(retryAfter)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
        )
    }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success,
              let port = listener.port,
              let url = URL(string: "ws://127.0.0.1:\(port.rawValue)/im/ws") else {
            throw URLError(.timedOut)
        }
        return url
    }

    func cancel() {
        let activeConnections = lock.withLock { () -> [NWConnection] in
            let activeConnections = connections
            connections.removeAll()
            return activeConnections
        }
        activeConnections.forEach { $0.forceCancel() }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            connections.append(connection)
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state,
                  let self,
                  let connection else {
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak connection] _, _, _, _ in
                guard let self, let connection else { return }
                connection.send(content: self.responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        connection.start(queue: queue)
    }
}

private func captureNetworkWebSocketClientHeaders(pathAndQuery: String, httpHost: String) throws -> [CapturedWebSocketHeader] {
    final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var headers: [CapturedWebSocketHeader] = []
        private var connections: [NWConnection] = []

        func setHeaders(_ headers: [(name: String, value: String)]) {
            lock.withLock {
                self.headers = headers.map {
                    CapturedWebSocketHeader(name: $0.name, value: $0.value)
                }
            }
        }

        func keepAlive(_ connection: NWConnection) {
            lock.withLock {
                connections.append(connection)
            }
        }

        func capturedHeaders() -> [CapturedWebSocketHeader] {
            lock.withLock { headers }
        }
    }

    let queue = DispatchQueue(label: "com.jianhuitong.tests.websocket-host-capture")
    let box = CaptureBox()
    let serverWebSocketOptions = NWProtocolWebSocket.Options()
    let captured = DispatchSemaphore(value: 0)
    serverWebSocketOptions.setClientRequestHandler(queue) { _, headers in
        box.setHeaders(headers)
        captured.signal()
        return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
    }
    let listenerParameters = NWParameters.tcp
    listenerParameters.defaultProtocolStack.applicationProtocols.insert(serverWebSocketOptions, at: 0)
    let listener = try NWListener(using: listenerParameters, on: .any)
    let ready = DispatchSemaphore(value: 0)
    let accepted = DispatchSemaphore(value: 0)

    listener.stateUpdateHandler = { state in
        if case .ready = state {
            ready.signal()
        }
    }
    listener.newConnectionHandler = { connection in
        box.keepAlive(connection)
        accepted.signal()
        connection.start(queue: queue)
    }
    listener.start(queue: queue)
    XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
    let port = try XCTUnwrap(listener.port)

    let websocketOptions = NWProtocolWebSocket.Options()
    websocketOptions.setAdditionalHeaders([("Host", httpHost)])
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)
    let endpointURL = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port.rawValue)\(pathAndQuery)"))
    let connection = NWConnection(to: .url(endpointURL), using: parameters)
    connection.start(queue: queue)
    XCTAssertEqual(accepted.wait(timeout: .now() + 3), .success)
    XCTAssertEqual(captured.wait(timeout: .now() + 3), .success)
    connection.cancel()
    listener.cancel()
    return box.capturedHeaders()
}

private final class FakeRealtimeWebSocketTransport: RealtimeWebSocketTransporting, @unchecked Sendable {
    private let socket: FakeRealtimeWebSocketTask
    private let lock = NSLock()
    private var urls: [URL] = []
    private var requests: [RealtimeConnectionRequest] = []

    init(socket: FakeRealtimeWebSocketTask) {
        self.socket = socket
    }

    func webSocketTask(with url: URL) -> RealtimeWebSocketTasking {
        lock.withLock {
            urls.append(url)
        }
        return socket
    }

    func webSocketTask(with request: RealtimeConnectionRequest) -> RealtimeWebSocketTasking {
        lock.withLock {
            requests.append(request)
            urls.append(request.url)
        }
        return socket
    }

    func requestedURLs() -> [URL] {
        lock.withLock { urls }
    }

    func requestedRequests() -> [RealtimeConnectionRequest] {
        lock.withLock { requests }
    }
}

private final class FakeRealtimeWebSocketTask: RealtimeWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveMessages: [URLSessionWebSocketTask.Message]
    private var sent: [URLSessionWebSocketTask.Message] = []
    private var resumes = 0
    private var cancellationCodes: [URLSessionWebSocketTask.CloseCode] = []

    init(receiveMessages: [URLSessionWebSocketTask.Message] = []) {
        self.receiveMessages = receiveMessages
    }

    func resume() {
        lock.withLock {
            resumes += 1
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            cancellationCodes.append(closeCode)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            if let message = lock.withLock({ receiveMessages.isEmpty ? nil : receiveMessages.removeFirst() }) {
                return message
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock {
            sent.append(message)
        }
        completionHandler(nil)
    }

    func sentStrings() -> [String] {
        lock.withLock {
            sent.compactMap { message in
                if case let .string(text) = message {
                    return text
                }
                return nil
            }
        }
    }

    func enqueue(_ message: URLSessionWebSocketTask.Message) {
        lock.withLock {
            receiveMessages.append(message)
        }
    }

    func resumeCount() -> Int {
        lock.withLock { resumes }
    }

    func cancelCount() -> Int {
        lock.withLock { cancellationCodes.count }
    }

    func cancelCodes() -> [URLSessionWebSocketTask.CloseCode] {
        lock.withLock { cancellationCodes }
    }
}

private final class LeakyRealtimeWebSocketTask: RealtimeWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedMessages: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var sent: [URLSessionWebSocketTask.Message] = []
    private var cancels = 0

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            cancels += 1
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let immediateMessage = lock.withLock { () -> URLSessionWebSocketTask.Message? in
                if !queuedMessages.isEmpty {
                    return queuedMessages.removeFirst()
                }
                receiver = continuation
                return nil
            }
            if let immediateMessage {
                continuation.resume(returning: immediateMessage)
            }
        }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        lock.withLock {
            sent.append(message)
        }
        completionHandler(nil)
    }

    func emit(_ message: URLSessionWebSocketTask.Message) {
        let continuation = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            guard let receiver else {
                queuedMessages.append(message)
                return nil
            }
            self.receiver = nil
            return receiver
        }
        continuation?.resume(returning: message)
    }

    func hasPendingReceiver() -> Bool {
        lock.withLock { receiver != nil }
    }

    func sentStrings() -> [String] {
        lock.withLock {
            sent.compactMap { message in
                if case let .string(text) = message {
                    return text
                }
                return nil
            }
        }
    }

    func cancelCount() -> Int {
        lock.withLock { cancels }
    }
}

private final class SequencedRealtimeWebSocketTransport: RealtimeWebSocketTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [RealtimeWebSocketTasking]
    private var urls: [URL] = []

    init(tasks: [RealtimeWebSocketTasking]) {
        self.tasks = tasks
    }

    func webSocketTask(with url: URL) -> RealtimeWebSocketTasking {
        lock.withLock {
            precondition(!tasks.isEmpty, "missing sequenced realtime task")
            urls.append(url)
            return tasks.removeFirst()
        }
    }

    func webSocketTask(with request: RealtimeConnectionRequest) -> RealtimeWebSocketTasking {
        webSocketTask(with: request.url)
    }

    func requestedURLs() -> [URL] {
        lock.withLock { urls }
    }
}

private final class FailingRealtimeWebSocketTransport: RealtimeWebSocketTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let retryAfter: TimeInterval?

    init(retryAfter: TimeInterval? = nil) {
        self.retryAfter = retryAfter
    }

    func webSocketTask(with url: URL) -> RealtimeWebSocketTasking {
        lock.withLock {
            urls.append(url)
        }
        return FailingRealtimeWebSocketTask(retryAfter: retryAfter)
    }

    func requestedURLs() -> [URL] {
        lock.withLock { urls }
    }
}

private final class FailingRealtimeWebSocketTask: RealtimeWebSocketTasking, @unchecked Sendable {
    let realtimeRetryAfter: TimeInterval?

    init(retryAfter: TimeInterval?) {
        self.realtimeRetryAfter = retryAfter
    }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        await Task.yield()
        throw URLError(.notConnectedToInternet)
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        completionHandler(nil)
    }
}

private final class FakeRealtimeNetworkMonitor: RealtimeNetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (RealtimeNetworkPathStatus) -> Void)?

    func start(pathUpdateHandler: @escaping @Sendable (RealtimeNetworkPathStatus) -> Void) {
        lock.withLock {
            handler = pathUpdateHandler
        }
    }

    func cancel() {
        lock.withLock {
            handler = nil
        }
    }

    func emit(_ status: RealtimeNetworkPathStatus) {
        let currentHandler = lock.withLock { handler }
        currentHandler?(status)
    }
}

private final class FakeRealtimeQUICTransport: RealtimeQUICTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<RealtimeQUICConnectioning, Error>
    private var capturedRequests: [RealtimeQUICConnectionRequest] = []

    init(result: Result<RealtimeQUICConnectioning, Error>) {
        self.result = result
    }

    func connect(_ request: RealtimeQUICConnectionRequest) async throws -> RealtimeQUICConnectioning {
        lock.withLock {
            capturedRequests.append(request)
        }
        switch result {
        case .success(let connection):
            return connection
        case .failure(let error):
            throw error
        }
    }

    func requests() -> [RealtimeQUICConnectionRequest] {
        lock.withLock { capturedRequests }
    }
}

private final class HangingRealtimeQUICTransport: RealtimeQUICTransporting, RealtimeQUICConnectAttemptProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [RealtimeQUICConnectionRequest] = []
    private var continuation: CheckedContinuation<RealtimeQUICConnectioning, Error>?
    private var didCancel = false
    private var cancellations = 0

    func connect(_ request: RealtimeQUICConnectionRequest) async throws -> RealtimeQUICConnectioning {
        try await makeConnectAttempt(request).connect()
    }

    func makeConnectAttempt(_ request: RealtimeQUICConnectionRequest) -> RealtimeQUICConnectAttempt {
        lock.withLock {
            capturedRequests.append(request)
        }
        return RealtimeQUICConnectAttempt(
            operation: { [weak self] in
                guard let self else { throw RealtimeQUICError.connectionCancelled }
                return try await self.waitForever()
            },
            cancellationHandler: { [weak self] in
                self?.cancelUnderlyingConnection()
            }
        )
    }

    func requestCount() -> Int {
        lock.withLock { capturedRequests.count }
    }

    func cancelCount() -> Int {
        lock.withLock { cancellations }
    }

    private func waitForever() async throws -> RealtimeQUICConnectioning {
        try await withCheckedThrowingContinuation { continuation in
            let isAlreadyCancelled = lock.withLock { () -> Bool in
                guard !didCancel else { return true }
                self.continuation = continuation
                return false
            }
            if isAlreadyCancelled {
                continuation.resume(throwing: RealtimeQUICError.connectionCancelled)
            }
        }
    }

    private func cancelUnderlyingConnection() {
        let continuation = lock.withLock { () -> CheckedContinuation<RealtimeQUICConnectioning, Error>? in
            guard !didCancel else { return nil }
            didCancel = true
            cancellations += 1
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: RealtimeQUICError.connectionCancelled)
    }
}

private final class ClockAdvancingFailingRealtimeQUICTransport: RealtimeQUICTransporting, RealtimeQUICConnectAttemptProviding, @unchecked Sendable {
    private let clock: TestRealtimeMonotonicClock
    private let failureTimeNanoseconds: UInt64
    private let lock = NSLock()
    private var cancellations = 0
    private var didCancel = false

    init(clock: TestRealtimeMonotonicClock, failureTimeNanoseconds: UInt64) {
        self.clock = clock
        self.failureTimeNanoseconds = failureTimeNanoseconds
    }

    func connect(_ request: RealtimeQUICConnectionRequest) async throws -> RealtimeQUICConnectioning {
        try await makeConnectAttempt(request).connect()
    }

    func makeConnectAttempt(_ request: RealtimeQUICConnectionRequest) -> RealtimeQUICConnectAttempt {
        RealtimeQUICConnectAttempt(
            operation: { [clock, failureTimeNanoseconds] in
                clock.advance(toNanoseconds: failureTimeNanoseconds)
                throw RealtimeQUICError.connectionFailed("test failure")
            },
            cancellationHandler: { [weak self] in
                self?.cancelUnderlyingConnection()
            }
        )
    }

    func cancelCount() -> Int {
        lock.withLock { cancellations }
    }

    private func cancelUnderlyingConnection() {
        lock.withLock {
            guard !didCancel else { return }
            didCancel = true
            cancellations += 1
        }
    }
}

private final class FakeRealtimeQUICConnection: RealtimeQUICConnectioning, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveLines: [Data]
    private var sentLines: [Data] = []
    private var cancels = 0

    init(receiveLines: [Data] = []) {
        self.receiveLines = receiveLines
    }

    func receiveLine() async throws -> Data {
        if let line = lock.withLock({ receiveLines.isEmpty ? nil : receiveLines.removeFirst() }) {
            return line
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        throw CancellationError()
    }

    func sendLine(_ data: Data) async throws {
        lock.withLock {
            sentLines.append(data)
        }
    }

    func cancel() {
        lock.withLock {
            cancels += 1
        }
    }

    func sentLineStrings() -> [String] {
        lock.withLock {
            sentLines.compactMap { String(data: $0, encoding: .utf8) }
        }
    }

    func cancelCount() -> Int {
        lock.withLock { cancels }
    }
}

private final class RecordingRealtimeWireCodec: WireCodec, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedDecodedTypeNames: [String] = []
    private var capturedDecodedInputTexts: [String] = []

    func encodeJSONObject(_ object: Any) throws -> Data {
        try JSONWireCodec().encodeJSONObject(object)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let typeName = String(describing: T.self)
        lock.withLock {
            capturedDecodedTypeNames.append(typeName)
            capturedDecodedInputTexts.append(String(data: data, encoding: .utf8) ?? "")
        }
        guard T.self == RealtimeEnvelope.self else {
            throw RealtimeTestWireCodecError.unsupportedType(typeName)
        }
        return RealtimeEnvelope(type: "connect_ack", requestID: "req-1", payload: [:]) as! T
    }

    func decodedTypeNames() -> [String] {
        lock.withLock { capturedDecodedTypeNames }
    }

    func decodedInputTexts() -> [String] {
        lock.withLock { capturedDecodedInputTexts }
    }
}

private enum RealtimeTestWireCodecError: Error {
    case unsupportedType(String)
}

// These tests enter the real HTTP DTO -> AppState sidecar -> Store projection chain.
// Every request is intercepted in-process; persistence is restricted to a unique temporary root.
extension RealtimeTransportTests {
    func testReceiptRecoveryEmptyItemsWatermarkUpdatesOnlyCapturedOwnSentDirectMessages() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [
            fixture.message(10),
            fixture.message(11, outgoing: false),
            fixture.message(12, sender: "foreign"),
            fixture.message(13, status: .sending),
            fixture.message(14, status: .failed),
            fixture.message(0)
        ])]
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(100) }

        await fixture.sync()

        let messages = try XCTUnwrap(fixture.state.conversations.first?.messages)
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
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: (501...750).map { fixture.message(Int64($0)) })]
        // Model the server's ascending LIMIT before anonymous watermark aggregation.
        fixture.transport.respond = { _, body in
            let after = (body["after_seq"] as? NSNumber)?.int64Value ?? -1
            XCTAssertEqual(body["limit"] as? Int, 100)
            XCTAssertEqual(body["receipt_type"] as? String, after == 0 ? "" : "read")
            return Self.anonymousReceiptResult(min(after + 100, 750))
        }

        await fixture.sync()
        XCTAssertEqual(fixture.transport.bodies.count, 3, "one baseline plus at most two pending windows")
        XCTAssertEqual(fixture.state.conversations[0].messages.filter { $0.status == .read }.count, 200)
        await fixture.sync()
        XCTAssertTrue(fixture.state.conversations[0].messages.allSatisfy { $0.status == .read })
        XCTAssertEqual(fixture.transport.bodies.compactMap { ($0["after_seq"] as? NSNumber)?.int64Value }, [0, 500, 600, 0, 700])
    }

    func testReceiptRecoveryNoProgressStopsWithoutSpinningAndCanRecoverOnNextExistingSchedule() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(501)])]
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(0) }
        await fixture.sync()
        XCTAssertEqual(fixture.transport.bodies.count, 2)
        XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .sent)
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(501) }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .read)
        XCTAssertEqual(fixture.transport.bodies.count, 3)
    }

    func testReceiptRecoveryPartialFailureKeepsProgressAndReleasesInFlightForRetry() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(501), fixture.message(601)])]
        fixture.transport.respond = { index, _ in
            if index == 2 { throw URLError(.notConnectedToInternet) }
            return Self.anonymousReceiptResult(index == 0 ? 100 : 501)
        }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversations[0].messages.map(\.status), [.read, .sent])
        XCTAssertEqual(fixture.transport.bodies.count, 3)
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(601) }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversations[0].messages.map(\.status), [.read, .read])
        XCTAssertEqual(fixture.transport.bodies.count, 4)
    }

    func testReceiptRecoveryOldHighWatermarkDoesNotContaminateMessageArrivingDuringRequestOrLater() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
        fixture.transport.respond = { _, _ in
            fixture.state.conversationStore.conversations[0].messages.append(fixture.message(11))
            return Self.anonymousReceiptResult(999)
        }
        await fixture.sync()
        fixture.state.conversationStore.conversations[0].messages.append(fixture.message(12))
        XCTAssertEqual(fixture.state.conversations[0].messages.map(\.status), [.read, .sent, .sent])
        XCTAssertEqual(fixture.transport.bodies.count, 1)
    }

    func testReceiptRecoveryLateResponseRejectsRefreshGenerationAndScopeChanges() async throws {
        for change in ["generation", "tenant", "app", "account"] {
            let fixture = ReceiptRecoveryFixture()
            addTeardownBlock { await fixture.cleanUp() }
            fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
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
            XCTAssertFalse(fixture.state.conversations.flatMap(\.messages).contains { $0.status == .read }, change)
            XCTAssertEqual(fixture.transport.bodies.count, 1, change)
        }
    }

    func testReceiptRecoveryLateResponseRejectsReplacedChannelAndChangedCapturedIdentity() async throws {
        for change in ["channel", "id", "sequence", "sender", "incoming", "removed"] {
            let fixture = ReceiptRecoveryFixture()
            addTeardownBlock { await fixture.cleanUp() }
            fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
            fixture.transport.respond = { _, _ in
                var replacement = fixture.message(change == "sequence" ? 9 : 10,
                                                  sender: change == "sender" ? "foreign" : "self",
                                                  outgoing: change != "incoming",
                                                  id: change == "id" ? "replacement" : nil)
                replacement.text = "local fixture only"
                fixture.state.conversationStore.conversations = change == "removed" ? [] : [fixture.conversation(
                    channel: change == "channel" ? "other:self" : "peer:self", messages: [replacement]
                )]
                return Self.anonymousReceiptResult(100)
            }
            await fixture.sync()
            XCTAssertFalse(fixture.state.conversations.flatMap(\.messages).contains { $0.status == .read }, change)
        }
    }

    func testReceiptRecoveryResetRejectsOldResponseAndOldDeferCannotReleaseNewClaim() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
        let replacementStarted = expectation(description: "replacement request owns a new receipt claim")
        var releaseReplacement: CheckedContinuation<Void, Never>?
        var replacementTask: Task<Void, Never>?
        fixture.transport.respond = { index, _ in
            if index == 0 {
                fixture.state.conversationStore.reset()
                fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
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
        XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .sent, "old response must not enter the reset store")
        XCTAssertEqual(fixture.transport.bodies.count, 2)
        await fixture.sync()
        XCTAssertEqual(fixture.transport.bodies.count, 2, "old defer must not clear the replacement in-flight claim")
        releaseReplacement?.resume()
        await replacementTask?.value
        XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .read)
    }

    func testReceiptRecoveryExistingConversationSidecarScheduleRunsWithoutWebSocketOrHistoryArrival() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
        let receiptApplied = expectation(description: "existing sidecar schedule projected anonymous read")
        let observer = fixture.state.conversationStore.$conversations.dropFirst().sink { conversations in
            if conversations.first?.messages.first?.status == .read { receiptApplied.fulfill() }
        }
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(10) }
        fixture.state.syncReadReceiptsIfNeeded("peer:self")
        await fulfillment(of: [receiptApplied], timeout: 2)
        XCTAssertEqual(fixture.transport.bodies.count, 1)
        XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .read)
        try await fixture.waitForDurableRead()
        withExtendedLifetime(observer) {}
    }

    func testReceiptRecoveryDisabledAndGroupIgnoreAnonymousWatermarkButKeepDeliveryBaseline() async throws {
        for mode in ["disabled-flag", "disabled-status", "group"] {
            let fixture = ReceiptRecoveryFixture()
            addTeardownBlock { await fixture.cleanUp() }
            let kind: ConversationKind = mode == "group" ? .group : .direct
            fixture.state.conversationStore.conversations = [fixture.conversation(kind: kind, messages: [fixture.message(10)])]
            fixture.transport.respond = { _, _ in
                var result = Self.anonymousReceiptResult(100)
                result["items"] = [Self.receiptItem(sequence: 10, type: "delivered", channelType: mode == "group" ? "group" : "direct")]
                if mode == "disabled-flag" { result["read_receipts_enabled"] = false }
                if mode == "disabled-status" { result["feature_status"] = "disabled" }
                return result
            }
            await fixture.sync(kind: kind)
            let message = try XCTUnwrap(fixture.state.conversations.first?.messages.first)
            XCTAssertEqual(message.status, .sent, mode)
            XCTAssertTrue(message.deliveryStateKnown, mode)
            XCTAssertFalse(message.readStateKnown, mode)
            XCTAssertEqual(fixture.transport.bodies.count, 1, mode)
        }
    }

    func testReceiptRecoveryDeliveryOnlyAndOutOfOrderReceiptsCannotDowngradeRead() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
        fixture.transport.respond = { _, _ in
            ["items": [Self.receiptItem(sequence: 10, type: "delivered")]]
        }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .sent)
        XCTAssertTrue(fixture.state.conversations[0].messages[0].deliveryStateKnown)
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(10) }
        await fixture.sync()
        var publications = 0
        let observer = fixture.state.conversationStore.$conversations.dropFirst().sink { _ in publications += 1 }
        fixture.transport.respond = { _, _ in
            ["items": [Self.receiptItem(sequence: 10, type: "delivered")], "read_up_to_seq": 1]
        }
        await fixture.sync()
        XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .read)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observer) {}
    }

    func testReceiptRecoveryDuplicateDoesNotPublishOrWriteAndReadSurvivesColdCacheLoad() async throws {
        let fixture = ReceiptRecoveryFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
        fixture.transport.respond = { _, _ in Self.anonymousReceiptResult(10) }
        await fixture.sync()
        let before = try fixture.databaseBytes()
        XCTAssertFalse(before.isEmpty, "first semantic receipt change must persist without a message arrival")
        var publications = 0
        let observer = fixture.state.conversationStore.$conversations.dropFirst().sink { _ in publications += 1 }
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
        fixture.state.conversationStore.conversations = [fixture.conversation(messages: [fixture.message(10)])]
        let callback = try XCTUnwrap(fixture.client.onEnvelope)
        for sender in ["", "foreign"] {
            callback(try Self.receiptEnvelope(sender: sender))
            XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .sent, "missing/foreign sender must not pass the WS privacy guard")
        }
        callback(try Self.receiptEnvelope(sender: "self"))
        XCTAssertEqual(fixture.state.conversations[0].messages[0].status, .read)
        XCTAssertTrue(fixture.state.conversations[0].messages[0].readBy.isEmpty)
        var publications = 0
        let observer = fixture.state.conversationStore.$conversations.dropFirst().sink { _ in publications += 1 }
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
        state.isAuthenticated = true
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

    func conversation(channel: String = "peer:self", kind: ConversationKind = .direct, messages: [ChatMessage]) -> Conversation {
        Conversation(id: channel, title: "Fixture", subtitle: "", kind: kind, lastMessage: "", time: "", unread: 0,
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
        state.isAuthenticated = false
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
private final class RTCWireOfflineHTTPTransport: HTTPTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        throw URLError(.notConnectedToInternet)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.notConnectedToInternet)
    }
}

private struct RTCWireEmptyMessageStore: MessageStore {
    let schemaVersion = 1
    func scopeKey(for context: IMAPIContext) -> String { "rtc-wire|\(context.tenantID ?? "")" }
    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? { nil }
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool { true }
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool { true }
    func remove(scope: String) {}
    func removeAll() {}
}

import Foundation
import Combine
import Network
import XCTest
@testable import WenDaTong

extension RealtimeTransportTests {
    func testRealtimeClientClosesSocketAfterTwoMissedPongs() throws {
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string(realtimeEnvelopeString(type: "connect_ack"))
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
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
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
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
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
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
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
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
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
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
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN
        XCTAssertEqual(events.map(\.result), [.started, .responseObserved])
        XCTAssertEqual(events.last?.handling, .requestRejected)
        XCTAssertEqual(events.last?.stage, .auth)
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END

        socket.enqueue(.string(realtimeEnvelopeString(type: "connect_ack")))
        await fulfillment(of: [connected], timeout: 1)
        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertEqual(connectedCount, 1)
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN
        XCTAssertEqual(events.map(\.result), [.started, .responseObserved, .acknowledged])
        XCTAssertEqual(events.last?.handling, .acknowledged)
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END

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

import Foundation
import Combine
import Network
import XCTest
@testable import WenDaTong

extension RealtimeTransportTests {
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
            // WDT_IOS1_DATA17_NATIVE_REALTIME_20261111: Read the actual native producer.
            .appendingPathComponent("Sources")
            .appendingPathComponent("IM4Data")
            .appendingPathComponent("NativeRealtimeWebSocket.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains("sec_protocol_options_set_verify_block"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("trustall"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("trust all"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("disable certificate"))
    }
}

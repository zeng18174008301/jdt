import Foundation
import CryptoKit
import XCTest
@testable import WenDaTong

@MainActor
final class AccessDiscoveryTests: XCTestCase {

    func testHigherKnownKeysetRevokesExactHistoricalKeyWhileRetiredKeyRemainsUsable() {
        let retired = AccessDiscoveryKnownKeyset(
            revision: 2,
            retiredKeyIDs: ["old-key"],
            revokedKeyIDs: []
        )
        let revoked = AccessDiscoveryKnownKeyset(
            revision: 3,
            retiredKeyIDs: [],
            revokedKeyIDs: ["old-key"]
        )

        XCTAssertTrue(retired.permitsHistoricalLastGood(signedBy: "old-key"))
        XCTAssertTrue(accessDiscoveryKnownKeysetTransitionAllowed(previous: retired, candidate: revoked))
        XCTAssertFalse(revoked.permitsHistoricalLastGood(signedBy: "old-key"))
        XCTAssertTrue(revoked.permitsHistoricalLastGood(signedBy: "unrelated-key"))
        XCTAssertFalse(accessDiscoveryKnownKeysetTransitionAllowed(previous: revoked, candidate: retired))
    }

    func testIMAPIClientUsesLocalProxyWebSocketPathForDebugDevServer() throws {
        let client = IMAPIClient(
            platformBase: URL(string: "http://127.0.0.1:5174/platform")!,
            tenantBase: URL(string: "http://127.0.0.1:5174/tenant")!,
            imBase: URL(string: "http://127.0.0.1:5174/im")!,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let url = try XCTUnwrap(client.webSocketURL(context: makeContext()))

        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 5174)
        XCTAssertEqual(url.path, "/im/ws")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    func testIMAPIClientKeepsProductionWebSocketPathContract() throws {
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let url = try XCTUnwrap(client.webSocketURL(context: makeContext()))

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "im.example.test")
        XCTAssertEqual(url.path, "/im/ws")
    }

    func testRefreshStoresValidDiscoveryAndSelectsAcceleratedEndpoint() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = try makeStore()
        let manager = AccessDiscoveryManager(store: store, now: { now }, random: { 0.1 })
        let context = makeContext()
        let fetcher = FakeAccessDiscoveryFetcher(results: [
            .success(makeResponse(configVersion: "cfg-1"))
        ])

        let outcome = await manager.refresh(context: context, fetcher: fetcher, force: true)
        let request = try XCTUnwrap(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: nil
        ))

        XCTAssertEqual(outcome, .network(configVersion: "cfg-1"))
        XCTAssertEqual(request.url.host, "ga.example.test")
        XCTAssertEqual(request.url.path, "/im/ws")
        XCTAssertNil(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(request.token, "im-token")
        now = now.addingTimeInterval(10)
        let cached = try XCTUnwrap(store.load(key: accessDiscoveryCacheKey(context)))
        XCTAssertEqual(cached.response.configVersion, "cfg-1")
        XCTAssertEqual(cached.response.signature, "ignored-by-client")
    }

    func testDiscoveryQUICEndpointUsesWSSWhenFeatureFlagDisabled() async throws {
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        let context = makeContext()
        let quic = makeEndpoint(
            id: "quic-poc",
            host: "quic.example.test",
            priority: 1,
            network: "accelerated",
            protocolValue: "quic",
            url: "quic://quic.example.test:19006/im/quic"
        )
        let wss = makeEndpoint(id: "wss", host: "wss.example.test", priority: 10, network: "direct")
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-quic-disabled", endpoints: [quic, wss]))]),
            force: true
        )

        let request = try XCTUnwrap(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: nil,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false)
        ))

        XCTAssertEqual(request.url.scheme, "wss")
        XCTAssertEqual(request.url.host, "wss.example.test")
        XCTAssertNil(request.quicRequest)
    }

    func testDiscoveryQUICEndpointProducesQUICRequestWhenFeatureFlagEnabled() async throws {
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        let context = makeContext()
        let quic = makeEndpoint(
            id: "quic",
            host: "im-quic.example.cn",
            priority: 1,
            network: "accelerated",
            protocolValue: "quic",
            url: "quic://im-quic.example.cn:19006/im/quic?token=url-token"
        )
        let wss = makeEndpoint(id: "wss", host: "wss.example.test", priority: 10, network: "direct")
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-quic-enabled", endpoints: [quic, wss]))]),
            force: true
        )

        let request = try XCTUnwrap(manager.realtimeConnectionRequest(
            context: context,
            token: " im-token ",
            fallbackURL: nil,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: true, alpn: "im_quic_json_v1")
        ))

        XCTAssertEqual(request.url.scheme, "wss")
        XCTAssertEqual(request.url.host, "wss.example.test")
        let quicRequest = try XCTUnwrap(request.quicRequest)
        XCTAssertEqual(quicRequest.host, "im-quic.example.cn")
        XCTAssertEqual(quicRequest.dialHost, "203.0.113.10")
        XCTAssertEqual(quicRequest.port, 19006)
        XCTAssertEqual(quicRequest.path, "/im/quic")
        XCTAssertFalse(quicRequest.path.localizedCaseInsensitiveContains("token"))
        XCTAssertEqual(quicRequest.token, "im-token")
        XCTAssertEqual(quicRequest.tlsServerName, "im-quic.example.cn")
        XCTAssertEqual(quicRequest.alpn, "im_quic_json_v1")
    }

    func testDiscoveryWSSIPHintProducesDialMetadataWithDomainSNIAndHost() async throws {
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        let context = makeContext()
        let wss = makeEndpoint(id: "wss-ip-hint", host: "im-a.example.test", priority: 1, network: "accelerated")
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-wss-ip-hint", endpoints: [wss]))]),
            force: true
        )

        let request = try XCTUnwrap(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: nil
        ))
        let metadata = try XCTUnwrap(request.webSocketDialMetadata)

        XCTAssertEqual(request.url.host, "im-a.example.test")
        XCTAssertEqual(metadata.dialHost, "203.0.113.10")
        XCTAssertEqual(metadata.port, 443)
        XCTAssertEqual(metadata.tlsServerName, "im-a.example.test")
        XCTAssertEqual(metadata.httpHost, "im-a.example.test")
    }

    func testDiscoveryWSSIPHintFallsBackToDomainURLWhenMetadataIsUnsafe() async throws {
        let cases: [(String, RemoteAccessDiscoveryEndpoint, String)] = [
            (
                "invalid-ip",
                makeEndpoint(
                    id: "invalid-ip",
                    host: "im-invalid-ip.example.test",
                    priority: 1,
                    network: "accelerated",
                    resolvedIPs: ["999.999.999.999"]
                ),
                "im-invalid-ip.example.test"
            ),
            (
                "missing-sni",
                makeEndpoint(
                    id: "missing-sni",
                    host: "im-missing-sni.example.test",
                    priority: 1,
                    network: "accelerated",
                    includeTLSServerName: false
                ),
                "im-missing-sni.example.test"
            ),
            (
                "missing-host",
                makeEndpoint(
                    id: "missing-host",
                    host: "im-missing-host.example.test",
                    priority: 1,
                    network: "accelerated",
                    includeHTTPHost: false
                ),
                "im-missing-host.example.test"
            ),
            (
                "mismatched-sni",
                makeEndpoint(
                    id: "mismatched-sni",
                    host: "im-mismatch.example.test",
                    priority: 1,
                    network: "accelerated",
                    tlsServerName: "other.example.test"
                ),
                "im-mismatch.example.test"
            )
        ]

        for (label, endpoint, expectedHost) in cases {
            let manager = AccessDiscoveryManager(store: try makeStore(), now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
            let context = makeContext(tenantID: "tenant-\(label)")
            _ = await manager.refresh(
                context: context,
                fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-\(label)", endpoints: [endpoint]))]),
                force: true
            )

            let request = try XCTUnwrap(manager.realtimeConnectionRequest(
                context: context,
                token: "im-token",
                fallbackURL: nil
            ))

            XCTAssertEqual(request.url.host, expectedHost, label)
            XCTAssertNil(request.webSocketDialMetadata, label)
        }
    }

    func testDiscoveryWSSURLHostIPFallsBackToURLSessionDomainFallback() async throws {
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        let context = makeContext()
        let ipURL = makeEndpoint(
            id: "ip-url",
            host: "203.0.113.10",
            priority: 1,
            network: "accelerated",
            url: "wss://203.0.113.10/im/ws"
        )
        let fallbackURL = try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws"))
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-ip-url", endpoints: [ipURL]))]),
            force: true
        )

        let request = try XCTUnwrap(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: fallbackURL
        ))

        XCTAssertEqual(request.url.host, "fallback.example.test")
        XCTAssertNil(request.webSocketDialMetadata)
    }

    func testDiscoveryIgnoresIllegalQUICEndpointAndKeepsWSSFallback() async throws {
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        let context = makeContext()
        let illegalQUIC = makeEndpoint(
            id: "quic-ip",
            host: "203.0.113.10",
            priority: 1,
            network: "accelerated",
            protocolValue: "quic",
            url: "quic://203.0.113.10:19006/im/quic"
        )
        let wss = makeEndpoint(id: "wss", host: "wss.example.test", priority: 10, network: "direct")
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-quic-invalid", endpoints: [illegalQUIC, wss]))]),
            force: true
        )

        let request = try XCTUnwrap(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: nil,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: true)
        ))

        XCTAssertEqual(request.url.scheme, "wss")
        XCTAssertEqual(request.url.host, "wss.example.test")
        XCTAssertNil(request.quicRequest)
    }

    func testDiscoveryFailureUsesPersistedLastGood() async throws {
        let store = try makeStore()
        let context = makeContext()
        let seedManager = AccessDiscoveryManager(store: store, now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        let nonCanonicalEndpoint = makeEndpoint(
            id: "ga",
            host: "ga.example.test",
            priority: 10,
            network: "accelerated",
            url: "wss://ga.example.test:9443/retired-ws?tenant=tenant-a&trace=last-good&token=legacy&im_token=legacy-2",
            port: 9443,
            path: "/retired-ws"
        )
        _ = await seedManager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [
                .success(makeResponse(configVersion: "cfg-l2", endpoints: [nonCanonicalEndpoint]))
            ]),
            force: true
        )
        let manager = AccessDiscoveryManager(store: store, now: { Date(timeIntervalSince1970: 2_000) }, random: { 0 })

        let outcome = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.failure(IMAPIError.server("503"))]),
            force: true
        )
        let request = try XCTUnwrap(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: nil
        ))

        XCTAssertEqual(outcome, .cache(configVersion: "cfg-l2"))
        XCTAssertEqual(request.url.host, "ga.example.test")
        XCTAssertEqual(request.url.port, 9443)
        XCTAssertEqual(request.url.path, "/im/ws")
        XCTAssertEqual(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems,
            [
                URLQueryItem(name: "tenant", value: "tenant-a"),
                URLQueryItem(name: "trace", value: "last-good")
            ]
        )
    }

    func testUnexpiredPersistedLastGoodAvoidsRemoteDiscoveryFetch() async throws {
        let store = try makeStore()
        let context = makeContext()
        let seedManager = AccessDiscoveryManager(store: store, now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        _ = await seedManager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-l2-fresh"))]),
            force: true
        )
        let fetcher = FakeAccessDiscoveryFetcher(results: [.failure(IMAPIError.server("should not fetch"))])
        let manager = AccessDiscoveryManager(store: store, now: { Date(timeIntervalSince1970: 1_030) }, random: { 0 })

        let outcome = await manager.refresh(context: context, fetcher: fetcher, force: false)

        XCTAssertEqual(outcome, .cache(configVersion: "cfg-l2-fresh"))
        XCTAssertEqual(fetcher.requestCount, 0)
    }

    func testTerminalDiscoveryErrorsClearLastGoodAndAllowStableFallbackURL() async throws {
        for code in [
            "access_discovery_disabled",
            "access_discovery_tenant_mismatch",
            "access_discovery_app_unavailable"
        ] {
            let store = try makeStore()
            let context = makeContext()
            let manager = AccessDiscoveryManager(store: store, now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
            _ = await manager.refresh(
                context: context,
                fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-\(code)"))]),
                force: true
            )
            XCTAssertNotNil(try store.load(key: accessDiscoveryCacheKey(context)))

            let outcome = await manager.refresh(
                context: context,
                fetcher: FakeAccessDiscoveryFetcher(results: [
                    .failure(IMAPIError.businessForbidden(code: code, message: "discovery blocked", error: nil))
                ]),
                force: true
            )
            let request = manager.realtimeConnectionRequest(
                context: context,
                token: "im-token",
                fallbackURL: URL(string: "wss://fallback.example.test/im/ws")
            )

            XCTAssertEqual(outcome, .unavailable)
            XCTAssertNil(try store.load(key: accessDiscoveryCacheKey(context)))
            XCTAssertEqual(request?.url.host, "fallback.example.test")
            XCTAssertEqual(request?.url.path, "/im/ws")
        }
    }

    func testEmptyDiscoveryDoesNotOverwriteLastGood() async throws {
        let store = try makeStore()
        let context = makeContext()
        let manager = AccessDiscoveryManager(store: store, now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-good"))]),
            force: true
        )

        let outcome = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-empty", endpoints: []))]),
            force: true
        )
        let cached = try XCTUnwrap(store.load(key: accessDiscoveryCacheKey(context)))

        XCTAssertEqual(outcome, .cache(configVersion: "cfg-good"))
        XCTAssertEqual(cached.response.configVersion, "cfg-good")
        XCTAssertEqual(cached.response.endpoints.count, 2)
    }

    func testDiscoveryLastGoodCacheIsSharedAcrossAccountsAndIsolatedByEnvironmentTenantAndApp() async throws {
        let store = try makeStore()
        let manager = AccessDiscoveryManager(store: store, now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        let accountOne = makeContext(accountID: "account-1", tenantID: "tenant-1", appID: "ios-main")
        let accountTwo = makeContext(accountID: "account-2", tenantID: "tenant-1", appID: "ios-main")
        let otherTenant = makeContext(accountID: "account-1", tenantID: "tenant-2", appID: "ios-main")
        let otherApp = makeContext(accountID: "account-1", tenantID: "tenant-1", appID: "ios-other")

        _ = await manager.refresh(
            context: accountOne,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-account-1"))]),
            force: true
        )

        XCTAssertNotNil(try store.load(key: accessDiscoveryCacheKey(accountOne)))
        XCTAssertNotNil(try store.load(key: accessDiscoveryCacheKey(accountTwo)))
        XCTAssertNil(try store.load(key: accessDiscoveryCacheKey(otherTenant)))
        XCTAssertNil(try store.load(key: accessDiscoveryCacheKey(otherApp)))
    }

    func testAcceleratedFailureSwitchesToDirectEndpoint() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { now }, random: { 0 })
        let context = makeContext()
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-1"))]),
            force: true
        )

        let first = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil))
        manager.markActiveRealtimeEndpointFailed()
        now = now.addingTimeInterval(1)
        let second = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil))

        XCTAssertEqual(first.url.host, "ga.example.test")
        XCTAssertEqual(second.url.host, "direct.example.test")
    }

    func testConnectAckAloneDoesNotMarkEndpointStable() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { now }, random: { 0 })
        let context = makeContext()
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-ack"))]),
            force: true
        )

        _ = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil))
        manager.markActiveRealtimeEndpointConnected()
        now = now.addingTimeInterval(5)
        manager.markActiveRealtimeEndpointFailed()
        now = now.addingTimeInterval(1)
        let direct = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil))
        manager.markActiveRealtimeEndpointConnected()
        now = now.addingTimeInterval(305)
        let afterCooling = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil))

        XCTAssertEqual(direct.url.host, "direct.example.test")
        XCTAssertEqual(afterCooling.url.host, "ga.example.test")
    }

    func testDevelopmentLoopbackFallbackBypassesDiscoveryEndpoint() async throws {
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { Date(timeIntervalSince1970: 1_000) }, random: { 0 })
        let context = makeContext()
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-local"))]),
            force: true
        )
        let fallbackURL = try XCTUnwrap(URL(string: "ws://127.0.0.1:5174/retired-ws?tenant=tenant-a&trace=debug&token=redacted"))

        let request = try XCTUnwrap(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: fallbackURL
        ))

        XCTAssertEqual(request.url.host, "127.0.0.1")
        XCTAssertEqual(request.url.port, 5174)
        XCTAssertEqual(request.url.path, "/im/ws")
        XCTAssertEqual(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems,
            [
                URLQueryItem(name: "tenant", value: "tenant-a"),
                URLQueryItem(name: "trace", value: "debug")
            ]
        )
    }

    func testCoolingDiscoveryEndpointFallsBackInsteadOfReusingOutlier() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { now }, random: { 0 })
        let context = makeContext()
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [
                .success(makeResponse(
                    configVersion: "cfg-single",
                    endpoints: [makeEndpoint(id: "ga", host: "ga.example.test", priority: 10, network: "accelerated")]
                ))
            ]),
            force: true
        )
        let fallbackURL = try XCTUnwrap(URL(string: "wss://fallback.example.test/im/ws?token=redacted"))

        let first = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: fallbackURL))
        manager.markActiveRealtimeEndpointFailed()
        now = now.addingTimeInterval(1)
        let second = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: fallbackURL))

        XCTAssertEqual(first.url.host, "ga.example.test")
        XCTAssertEqual(second.url.host, "fallback.example.test")
        XCTAssertEqual(second.url.path, "/im/ws")
        XCTAssertNil(URLComponents(url: second.url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    func testConfigVersionUpdateRefreshesSelectionAndReleasesFailbackHold() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let manager = AccessDiscoveryManager(store: try makeStore(), now: { now }, random: { 0 })
        let context = makeContext()
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-1"))]),
            force: true
        )
        _ = manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil)
        manager.markActiveRealtimeEndpointFailed()
        now = now.addingTimeInterval(1)
        let direct = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil))
        manager.markActiveRealtimeEndpointSucceeded()

        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(makeResponse(configVersion: "cfg-2"))]),
            force: true
        )
        now = now.addingTimeInterval(1)
        let refreshed = try XCTUnwrap(manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil))

        XCTAssertEqual(direct.url.host, "direct.example.test")
        XCTAssertEqual(refreshed.url.host, "ga.example.test")
    }

}

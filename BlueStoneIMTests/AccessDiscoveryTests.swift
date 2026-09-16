import Foundation
import CryptoKit
import XCTest
@testable import BlueStoneIM

@MainActor
final class AccessDiscoveryTests: XCTestCase {
    func testSignedV2NetworkEnvelopeStaysStrictWhileVerifiedLastGoodIsPermanent() throws {
        let fixture = try makeDomainOnlySignedFixture(contractVersion: 2)
        let context = makeContext(tenantID: "tenant-fixture", appID: "app1-ios")
        let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let accepted = try fixture.trust.verify(fixture.envelope, context: context, now: acceptedAt)

        XCTAssertEqual(accepted.contractVersion, 2)
        XCTAssertEqual(accepted.lifetimeMode, .untilRevoked)
        XCTAssertEqual(accepted.publicationRevision, 42)
        XCTAssertEqual(accepted.keysetRevision, 1)
        XCTAssertThrowsError(
            try fixture.trust.verifyNetworkResponse(
                accepted,
                context: context,
                now: acceptedAt.addingTimeInterval(20 * 365 * 24 * 60 * 60)
            )
        )
        XCTAssertThrowsError(
            try fixture.trust.verifyNetworkResponse(
                accepted,
                context: context,
                now: Date(timeIntervalSince1970: 1)
            )
        )

        let longLived = try fixture.trust.verifyStored(
            accepted,
            context: context,
            now: acceptedAt.addingTimeInterval(20 * 365 * 24 * 60 * 60)
        )
        let clockRolledBack = try fixture.trust.verifyStored(
            accepted,
            context: context,
            now: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(longLived.publicationID, accepted.publicationID)
        XCTAssertEqual(clockRolledBack.profileFingerprint, accepted.profileFingerprint)
    }

    func testPublicationRevisionAllowsHigherRollbackButRejectsLowerAndSameIDConflict() throws {
        let fixture = try makeDomainOnlySignedFixture(contractVersion: 2)
        let context = makeContext(tenantID: "tenant-fixture", appID: "app1-ios")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let original = try fixture.trust.verify(fixture.envelope, context: context, now: now)
        var higherRollback = original
        higherRollback.publicationRevision = 43
        higherRollback.publicationID = "access-publication-43"
        var lower = original
        lower.publicationRevision = 41
        lower.publicationID = "access-publication-41"
        var sameIDConflict = original
        sameIDConflict.profileFingerprint = String(repeating: "f", count: 64)

        XCTAssertTrue(accessDiscoveryTrustedTransitionAllowed(previous: original, candidate: higherRollback))
        XCTAssertFalse(accessDiscoveryTrustedTransitionAllowed(previous: original, candidate: lower))
        XCTAssertFalse(accessDiscoveryTrustedTransitionAllowed(previous: original, candidate: sameIDConflict))
    }

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

    @MainActor
    func testIMAPIClientPostsDiscoveryContractBody() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"contract_version":1,"config_version":"cfg-api","server_time":1782710000,"ttl_seconds":60,"refresh_jitter_seconds":10,"source":"platform","stale":false,"degraded":false,"endpoints":[{"id":"ga","usage":"im_realtime","protocol":"wss","url":"wss://ga.example.test/im/ws","host":"ga.example.test","port":443,"priority":10,"weight":100,"network":"accelerated","status":"ready"}],"discovery_fallbacks":[]}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let response = try await client.accessDiscoveryEndpoints(context: makeContext())
        let request = try XCTUnwrap(transport.requests.first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(response.configVersion, "cfg-api")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/access/v1/endpoints")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertEqual(body["contract_version"] as? Int, 2)
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["tenant_id"] as? String, "tenant-1")
        XCTAssertNil(body["device_id"])
    }

    @MainActor
    func testIMAPIClientPostsSameAuthenticatedBodyToExplicitTrustedFallback() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"contract_version":1,"config_version":"cfg-fallback","server_time":1782710000,"ttl_seconds":60,"refresh_jitter_seconds":10,"source":"platform","stale":false,"degraded":false,"endpoints":[{"id":"ga","usage":"im_realtime","protocol":"wss","url":"wss://ga.example.test/im/ws","host":"ga.example.test","port":443,"priority":10,"weight":100,"network":"accelerated","status":"ready"}],"discovery_fallbacks":[]}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )
        let fallbackURL = try XCTUnwrap(URL(string: "https://fallback.example.test/api/tenant/access/v1/endpoints"))

        _ = try await client.accessDiscoveryEndpoints(
            context: makeContext(),
            endpointURL: fallbackURL,
            timeoutInterval: 2.5
        )
        let request = try XCTUnwrap(transport.requests.first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(request.url, fallbackURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertEqual(body["contract_version"] as? Int, 2)
        XCTAssertEqual(body["tenant_id"] as? String, "tenant-1")
    }

    @MainActor
    func testIMAPIClientRejectsMaliciousExplicitFallbackBeforeNetwork() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(),
            isHTTPResponse: true,
            statusCode: 500
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let invalidURLs = [
            "http://fallback.example.test/api/tenant/access/v1/endpoints",
            "https://user:pass@fallback.example.test/api/tenant/access/v1/endpoints",
            "https://fallback.example.test/api/tenant/access/v1/endpoints?token=attacker",
            "https://203.0.113.8/api/tenant/access/v1/endpoints",
        ]

        for rawValue in invalidURLs {
            do {
                _ = try await client.accessDiscoveryEndpoints(
                    context: makeContext(),
                    endpointURL: try XCTUnwrap(URL(string: rawValue)),
                    timeoutInterval: 2.5
                )
                XCTFail("Expected malicious fallback to fail closed")
            } catch AccessDiscoveryTrustError.endpointInvalid {
                // Expected.
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTrustedDiscoveryFallbacksAreHttpsSortedDedupedAndBounded() {
        let response = makeResponse(
            configVersion: "cfg-fallback-order",
            discoveryFallbacks: [
                makeDiscoveryFallback(id: "d", priority: 40),
                makeDiscoveryFallback(id: "b", priority: 20),
                makeDiscoveryFallback(id: "a", priority: 10),
                makeDiscoveryFallback(id: "a-duplicate", priority: 11, host: "a.example.test"),
                makeDiscoveryFallback(id: "c", priority: 30),
            ]
        )

        XCTAssertEqual(
            AccessDiscoveryManager.trustedDiscoveryFallbackURLs(from: response).map(\.absoluteString),
            [
                "https://a.example.test/api/tenant/access/v1/endpoints",
                "https://b.example.test/api/tenant/access/v1/endpoints",
                "https://c.example.test/api/tenant/access/v1/endpoints",
            ]
        )
    }

    @MainActor
    func testIMAPIClientPreservesTerminalDiscoveryErrorCode() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"access_discovery_disabled","message":"discovery disabled"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 503
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )

        do {
            _ = try await client.accessDiscoveryEndpoints(context: makeContext())
            XCTFail("Expected terminal discovery error")
        } catch IMAPIError.businessForbidden(let code, _, _) {
            XCTAssertEqual(code, "access_discovery_disabled")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSignedFixtureRejectsTamperExpiryAndCrossAPP() throws {
        let fixture = try loadSignedFixture()
        let trust = AccessDiscoveryTrustConfiguration(
            required: true,
            environment: "production",
            productID: "wenxintong",
            appID: "app1-ios",
            channel: "app1",
            clientIdentifier: "com.wenxintong.app1",
            publicKeys: ["fixture-ed25519-v1": try XCTUnwrap(Data(base64Encoded: fixture.publicKeyB64))],
            recoveryRootKeyID: fixture.recoveryRootKeyID,
            recoveryRootPublicKey: try XCTUnwrap(Data(base64Encoded: fixture.recoveryRootPublicKeyB64))
        )
        let context = makeContext(accountID: "account-a", tenantID: "tenant-fixture", appID: "app1-ios")
        let validAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        XCTAssertThrowsError(try trust.verify(fixture.ios, context: context, now: validAt))
        XCTAssertThrowsError(try trust.verify(
            fixture.ios,
            context: makeContext(accountID: "account-a", tenantID: "tenant-fixture", appID: "app2-ios"),
            now: validAt
        ))
        XCTAssertThrowsError(try trust.verify(
            fixture.ios,
            context: context,
            now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T02:00:00Z"))
        ))
        var tampered = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.ios)) as? [String: Any]
        )
        tampered["signature"] = String(fixture.ios.signature.dropLast(2)) + "AA"
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
        XCTAssertThrowsError(try trust.verify(
            JSONDecoder().decode(SignedAccessDiscoveryEnvelope.self, from: tamperedData),
            context: context,
            now: validAt
        ))
        var tamperedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.ios)) as? [String: Any]
        )
        var keyState = try XCTUnwrap(tamperedRoot["key_state"] as? [String: Any])
        var rootSignature = try XCTUnwrap(Data(base64Encoded: fixture.ios.keyState.signature))
        rootSignature[0] ^= 1
        keyState["signature"] = rootSignature.base64EncodedString()
        tamperedRoot["key_state"] = keyState
        let tamperedRootData = try JSONSerialization.data(withJSONObject: tamperedRoot, options: [.sortedKeys])
        XCTAssertThrowsError(try trust.verify(
            JSONDecoder().decode(SignedAccessDiscoveryEnvelope.self, from: tamperedRootData),
            context: context,
            now: validAt
        ))
    }

    func testSignedDomainOnlyApp2AudienceAcceptsProtectedCloudFrontPool() throws {
        let fixture = try makeDomainOnlySignedFixture(
            appID: "app2-ios",
            channel: "app2",
            clientIdentifier: "com.wenxintong.app2"
        )
        let context = makeContext(
            accountID: "account-app2",
            tenantID: "tenant-fixture",
            appID: "app2-ios"
        )
        let validAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))

        let verified = try fixture.trust.verify(fixture.envelope, context: context, now: validAt)

        XCTAssertEqual(verified.trust?.appID, "app2-ios")
        XCTAssertEqual(verified.endpoints.map(\.host), ["d111111abcdef8.cloudfront.net"])
        XCTAssertTrue(verified.endpoints.allSatisfy { endpoint in
            endpoint.resolvedIPs.isEmpty && endpoint.dialMode == "domain_only"
        })
    }

    func testSignedProtectedEndpointRejectsDirectAndOrdinaryEIP() {
        let direct = makeEndpoint(id: "direct", host: "im.fixture.invalid", priority: 1, network: "direct")
        XCTAssertFalse(direct.isSignedProtectedEndpointValid(
            at: Date(timeIntervalSince1970: 1_000),
            validUntil: Date(timeIntervalSince1970: 2_000)
        ))
        let rawIP = makeEndpoint(
            id: "eip",
            host: "203.0.113.20",
            priority: 1,
            network: "accelerated",
            resolvedIPs: []
        )
        XCTAssertFalse(rawIP.isSignedProtectedEndpointValid(
            at: Date(timeIntervalSince1970: 1_000),
            validUntil: Date(timeIntervalSince1970: 2_000)
        ))
    }

    func testAliyunGASignedPoolAcceptsExactContractAndKeepsCloudFront() throws {
        let ga = makeProductionDomainOnlyEndpoint(
            id: "ga-wss", host: "im.brand-a.example.com", network: "accelerated",
            provider: "alibaba_cloud_ga", resourceType: "controlled_load_balancer",
            resourceID: "brand-entry:" + String(repeating: "a", count: 61) + "ec2"
        )
        let discovery = makeProductionDomainOnlyEndpoint(
            id: "ga-discovery", usage: "access_discovery", protocolValue: "https",
            host: "im.brand-a.example.com", path: "/api/tenant/access/v1/endpoints",
            network: "accelerated", provider: "alibaba_cloud_ga",
            resourceType: "controlled_load_balancer", resourceID: "brand-entry:" + String(repeating: "b", count: 64),
            auth: "none"
        )
        let cf = makeProductionDomainOnlyEndpoint()
        let context = makeContext(tenantID: "tenant-fixture", appID: "app1-ios")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        for version in [1, 2] {
            let fixture = try makeDomainOnlySignedFixture(
                discoveryFallbacks: [discovery], endpoints: [ga, cf], contractVersion: version
            )
            let accepted = try fixture.trust.verify(fixture.envelope, context: context, now: now)
            XCTAssertEqual(accepted.endpoints, [ga, cf])
            XCTAssertEqual(accepted.discoveryFallbacks, [discovery])
            XCTAssertThrowsError(try fixture.trust.verify(fixture.envelope,
                context: makeContext(tenantID: "other-tenant", appID: "app1-ios"), now: now))
            XCTAssertThrowsError(try fixture.trust.verify(fixture.envelope,
                context: makeContext(tenantID: "tenant-fixture", appID: "app2-ios"), now: now))
            XCTAssertThrowsError(try fixture.trust.verify(fixture.envelope, context: context,
                now: now.addingTimeInterval(7200)))
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.envelope)) as? [String: Any])
            envelope["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
            let tampered = try JSONDecoder().decode(SignedAccessDiscoveryEnvelope.self,
                from: JSONSerialization.data(withJSONObject: envelope))
            XCTAssertThrowsError(try fixture.trust.verify(tampered, context: context, now: now))
        }
    }

    func testAliyunGARejectsWrongProtectionProjectionAndOriginBindings() throws {
        let ga = makeProductionDomainOnlyEndpoint(
            id: "ga-wss", host: "im.brand-a.example.com", network: "accelerated",
            provider: "alibaba_cloud_ga", resourceType: "controlled_load_balancer",
            resourceID: "brand-entry:" + String(repeating: "a", count: 64)
        )
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ga)) as? [String: Any])
        let mutations: [[String: Any]] = [
            ["provider": "aws_global_accelerator"], ["provider": "ALIBABA_CLOUD_GA"],
            ["protected_resource_type": "professional_high_defense"],
            ["protected_resource_id": "ga-instance-id"],
            ["protected_resource_id": "brand-entry:" + String(repeating: "A", count: 64)],
            ["protected_resource_id": "brand-entry:" + String(repeating: "a", count: 63)],
            ["network": "fallback"], ["network": "direct"],
            ["port": 8443, "url": "wss://im.brand-a.example.com:8443/im/ws"],
            ["http_host": "im.brand-b.example.com"], ["tls_server_name": "im.brand-b.example.com"],
            ["resolved_ips": ["203.0.113.1"]],
            ["protocol": "https", "usage": "access_discovery", "auth": "none",
             "url": "https://im.brand-a.example.com/wrong", "path": "/wrong"],
            ["host": "d111111abcdef8.cloudfront.net", "http_host": "d111111abcdef8.cloudfront.net",
             "tls_server_name": "d111111abcdef8.cloudfront.net", "url": "wss://d111111abcdef8.cloudfront.net/im/ws"],
            ["host": "internal-test.ap-east-1.elb.amazonaws.com", "http_host": "internal-test.ap-east-1.elb.amazonaws.com",
             "tls_server_name": "internal-test.ap-east-1.elb.amazonaws.com", "url": "wss://internal-test.ap-east-1.elb.amazonaws.com/im/ws"]
        ]
        for mutation in mutations {
            var raw = original
            raw.merge(mutation) { _, new in new }
            let bad = try JSONDecoder().decode(RemoteAccessDiscoveryEndpoint.self,
                from: JSONSerialization.data(withJSONObject: raw))
            XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([bad, makeProductionDomainOnlyEndpoint()]), "\(mutation)")
        }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-04T00:00:00Z"))
        XCTAssertFalse(ga.isSignedProtectedEndpointValid(at: now, validUntil: now.addingTimeInterval(60)))
    }

    func testUnsupportedProviderRejectsWholeSignedPoolWithValidCloudFrontFallback() throws {
        let unknown = makeProductionDomainOnlyEndpoint(
            id: "unsupported-brand-wss",
            host: "im.brand-a.example.com",
            network: "accelerated",
            provider: "unsupported_provider",
            resourceType: "controlled_load_balancer",
            resourceID: "unsupported-fixture"
        )
        let fallback = makeProductionDomainOnlyEndpoint()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let context = makeContext(tenantID: "tenant-fixture", appID: "app1-ios")
        for version in [1, 2] {
            let fixture = try makeDomainOnlySignedFixture(
                endpoints: [unknown, fallback], contractVersion: version
            )
            XCTAssertThrowsError(try fixture.trust.verify(fixture.envelope, context: context, now: now)) { error in
                XCTAssertEqual(error as? AccessDiscoveryTrustError, .endpointInvalid)
            }
            let cfOnly = try makeDomainOnlySignedFixture(endpoints: [fallback], contractVersion: version)
            XCTAssertNoThrow(try cfOnly.trust.verify(cfOnly.envelope, context: context, now: now))
        }
    }

    func testProductionDomainOnlyPoolRejectsHintsOriginsAndAmbiguity() {
        let valid = makeProductionDomainOnlyEndpoint()
        XCTAssertTrue(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([valid]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(resolvedIPs: ["203.0.113.10"], dialMode: "domain_or_ip_hint")
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(dialMode: "domain_or_ip_hint")
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(network: "direct")
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(network: "accelerated")
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(url: "wss://d111111abcdef8.cloudfront.net/im/%77s")
        ]))
        let albHost = "internal-app.ap-east-1.elb.amazonaws.com"
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(host: albHost, url: "wss://\(albHost)/im/ws", tlsServerName: albHost, httpHost: albHost)
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(provider: "private-origin.example.com")
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(provider: "AWS_CLOUDFRONT")
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(protocolValue: "quic", path: "/im/quic")
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(
                network: "accelerated",
                provider: "aws_global_accelerator",
                resourceType: "aws_global_accelerator",
                resourceID: "GA1234567890ABC"
            )
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            makeProductionDomainOnlyEndpoint(
                provider: "aws", resourceType: "aws_alb",
                resourceID: "arn:aws:elasticloadbalancing:ap-east-1:123456789012:loadbalancer/app/private"
            )
        ]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([valid, valid]))
        XCTAssertFalse(AccessDiscoveryTrustConfiguration.productionDomainOnlyPoolIsValid([
            valid, makeProductionDomainOnlyEndpoint(id: "cloudfront-wss-other-id")
        ]))
    }

    func testSignedTransitionRejectsSameGenerationDifferentHash() throws {
        let fixture = try makeDomainOnlySignedFixture()
        let trust = fixture.trust
        let context = makeContext(accountID: "account-a", tenantID: "tenant-fixture", appID: "app1-ios")
        let validAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let previous = try trust.verify(fixture.envelope, context: context, now: validAt)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
        var proof = try XCTUnwrap(raw["trust"] as? [String: Any])
        proof["content_hash"] = String(repeating: "b", count: 64)
        raw["trust"] = proof
        let candidate = try JSONDecoder().decode(
            RemoteAccessDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        )

        XCTAssertFalse(accessDiscoveryTrustedTransitionAllowed(previous: previous, candidate: candidate))
    }

    func testHigherRecoveryFenceCannotRestartAudienceGeneration() throws {
        let fixture = try makeDomainOnlySignedFixture()
        let trust = fixture.trust
        let context = makeContext(accountID: "account-a", tenantID: "tenant-fixture", appID: "app1-ios")
        let validAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let previous = try trust.verify(fixture.envelope, context: context, now: validAt)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
        var proof = try XCTUnwrap(raw["trust"] as? [String: Any])
        proof["recovery_generation"] = 8
        proof["fencing_generation"] = 8
        proof["key_state_hash"] = String(repeating: "b", count: 64)
        proof["generation"] = 1
        raw["trust"] = proof
        raw["config_version"] = "recovery-v1"
        let candidate = try JSONDecoder().decode(
            RemoteAccessDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        )

        XCTAssertFalse(accessDiscoveryTrustedTransitionAllowed(previous: previous, candidate: candidate))
    }

    func testSignedLastGoodIsReverifiedBeforeFallback() async throws {
        let fixture = try makeDomainOnlySignedFixture()
        let trust = fixture.trust
        let context = makeContext(accountID: "account-a", tenantID: "tenant-fixture", appID: "app1-ios")
        let validAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let response = try trust.verify(fixture.envelope, context: context, now: validAt)
        let manager = AccessDiscoveryManager(
            store: try makeStore(),
            now: { validAt },
            random: { 0 },
            trustConfiguration: trust
        )
        let fetcher = FakeAccessDiscoveryFetcher(results: [
            .success(response),
            .failure(IMAPIError.server("fixture unavailable")),
        ])

        let network = await manager.refresh(context: context, fetcher: fetcher, force: true)
        let cached = await manager.refresh(context: context, fetcher: fetcher, force: true)
        XCTAssertEqual(network, .network(configVersion: "fixture-v42"))
        XCTAssertEqual(cached, .cache(configVersion: "fixture-v42"))
        XCTAssertEqual(
            manager.realtimeConnectionRequest(context: context, token: "im-token", fallbackURL: nil)?.url.host,
            "d111111abcdef8.cloudfront.net"
        )
        manager.markActiveRealtimeEndpointFailed()
        XCTAssertNil(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: URL(string: "wss://unsigned.example.invalid/im/ws")
        ))
    }

    func testBusinessOrSignatureFailureDoesNotSwitchToTrustedFallback() async throws {
        let fixture = try makeDomainOnlySignedFixture(discoveryFallbacks: [
            makeProductionDomainOnlyEndpoint(
                id: "fallback-b", usage: "access_discovery", protocolValue: "https",
                host: "d311111abcdef8.cloudfront.net", path: "/api/tenant/access/v1/endpoints",
                resourceID: "E3234567890ABC", priority: 20, auth: "none"
            ),
            makeProductionDomainOnlyEndpoint(
                id: "fallback-a", usage: "access_discovery", protocolValue: "https",
                host: "d211111abcdef8.cloudfront.net", path: "/api/tenant/access/v1/endpoints",
                resourceID: "E2234567890ABC", priority: 10, auth: "none"
            ),
        ])
        let trust = fixture.trust
        let context = makeContext(accountID: "account-a", tenantID: "tenant-fixture", appID: "app1-ios")
        let validAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let trusted = try trust.verify(fixture.envelope, context: context, now: validAt)
        var monotonicNow: TimeInterval = 100
        let manager = AccessDiscoveryManager(
            store: try makeStore(),
            now: { validAt },
            monotonicNow: { monotonicNow },
            random: { 0 },
            trustConfiguration: trust
        )
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(trusted)]),
            force: true
        )
        let fetcher = FakeAccessDiscoveryFetcher(
            results: [
                .failure(IMAPIError.businessForbidden(
                    code: "access_discovery_signature_invalid",
                    message: "terminal primary response",
                    error: nil
                )),
            ],
            onRequest: { monotonicNow += 2.5 }
        )

        let outcome = await manager.refresh(context: context, fetcher: fetcher, force: true)

        XCTAssertEqual(outcome, .cache(configVersion: trusted.configVersion))
        XCTAssertEqual(fetcher.requestCount, 1)
        XCTAssertEqual(fetcher.endpointURLs.count, 1)
        XCTAssertNil(fetcher.endpointURLs[0])
        XCTAssertEqual(fetcher.timeoutIntervals, [2.5])
    }

    func testTrustedFallbacksShareEightSecondDeadlineAndStopAfterThree() async throws {
        let fixture = try makeDomainOnlySignedFixture(discoveryFallbacks: [
            makeProductionDomainOnlyEndpoint(
                id: "fallback-d", usage: "access_discovery", protocolValue: "https",
                host: "d511111abcdef8.cloudfront.net", path: "/api/tenant/access/v1/endpoints",
                resourceID: "E5234567890ABC", priority: 40, auth: "none"
            ),
            makeProductionDomainOnlyEndpoint(
                id: "fallback-b", usage: "access_discovery", protocolValue: "https",
                host: "d311111abcdef8.cloudfront.net", path: "/api/tenant/access/v1/endpoints",
                resourceID: "E3234567890ABC", priority: 20, auth: "none"
            ),
            makeProductionDomainOnlyEndpoint(
                id: "fallback-a", usage: "access_discovery", protocolValue: "https",
                host: "d211111abcdef8.cloudfront.net", path: "/api/tenant/access/v1/endpoints",
                resourceID: "E2234567890ABC", priority: 10, auth: "none"
            ),
            makeProductionDomainOnlyEndpoint(
                id: "fallback-c", usage: "access_discovery", protocolValue: "https",
                host: "d411111abcdef8.cloudfront.net", path: "/api/tenant/access/v1/endpoints",
                resourceID: "E4234567890ABC", priority: 30, auth: "none"
            ),
        ])
        let trust = fixture.trust
        let context = makeContext(accountID: "account-a", tenantID: "tenant-fixture", appID: "app1-ios")
        let validAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let trusted = try trust.verify(fixture.envelope, context: context, now: validAt)
        var monotonicNow: TimeInterval = 200
        let manager = AccessDiscoveryManager(
            store: try makeStore(),
            now: { validAt },
            monotonicNow: { monotonicNow },
            random: { 0 },
            trustConfiguration: trust
        )
        _ = await manager.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(trusted)]),
            force: true
        )
        let fetcher = FakeAccessDiscoveryFetcher(
            results: Array(repeating: .failure(URLError(.timedOut)), count: 4),
            onRequest: { monotonicNow += 2.5 }
        )

        let outcome = await manager.refresh(context: context, fetcher: fetcher, force: true)

        XCTAssertEqual(outcome, .cache(configVersion: trusted.configVersion))
        XCTAssertEqual(
            fetcher.endpointURLs.map { $0?.host },
            [nil, "d211111abcdef8.cloudfront.net", "d311111abcdef8.cloudfront.net", "d411111abcdef8.cloudfront.net"]
        )
        XCTAssertEqual(fetcher.timeoutIntervals, [2.5, 2.5, 2.5, 0.5])
        XCTAssertEqual(fetcher.timeoutIntervals.reduce(0, +), 8)
    }

    func testSignedMemoryExpiresAndIsClearedFailClosed() async throws {
        let fixture = try makeDomainOnlySignedFixture()
        let trust = fixture.trust
        let context = makeContext(accountID: "account-a", tenantID: "tenant-fixture", appID: "app1-ios")
        var clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let response = try trust.verify(fixture.envelope, context: context, now: clock)
        let store = try makeStore()
        let manager = AccessDiscoveryManager(
            store: store,
            now: { clock },
            random: { 0 },
            trustConfiguration: trust
        )
        let fetcher = FakeAccessDiscoveryFetcher(results: [
            .success(response),
            .failure(IMAPIError.server("offline")),
        ])
        let networkResult = await manager.refresh(context: context, fetcher: fetcher, force: true)
        XCTAssertEqual(networkResult, .network(configVersion: "fixture-v42"))
        clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T02:00:00Z"))
        let expiredResult = await manager.refresh(context: context, fetcher: fetcher, force: true)
        XCTAssertEqual(expiredResult, .unavailable)
        XCTAssertNil(manager.realtimeConnectionRequest(
            context: context,
            token: "im-token",
            fallbackURL: URL(string: "wss://unsigned.example.invalid/im/ws")
        ))
        let watermarkKey = accessDiscoveryTrustWatermarkKey(context, trust: trust)
        let persisted = try XCTUnwrap(store.loadTrustWatermark(key: watermarkKey))
        XCTAssertEqual(persisted.configGeneration, 42)

        let higher = AccessDiscoveryTrustWatermark(
            recoveryGeneration: persisted.recoveryGeneration + 1,
            currentFencingGeneration: persisted.currentFencingGeneration + 1,
            keyStateHash: String(repeating: "b", count: 64),
            configGeneration: persisted.configGeneration + 1,
            contentHash: String(repeating: "c", count: 64),
            configVersion: "fixture-v43"
        )
        XCTAssertTrue(try store.advanceTrustWatermark(higher, key: watermarkKey))
        clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-24T00:30:00Z"))
        let restarted = AccessDiscoveryManager(
            store: store,
            now: { clock },
            random: { 0 },
            trustConfiguration: trust
        )
        let replay = await restarted.refresh(
            context: context,
            fetcher: FakeAccessDiscoveryFetcher(results: [.success(response)]),
            force: true
        )
        XCTAssertEqual(replay, .unavailable)
    }

    func testTrustWatermarkAtomicWriteFailurePreservesExistingWatermark() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccessDiscoveryWatermarkAtomic-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        var writeCount = 0
        let store = AccessDiscoveryStore(
            baseDirectory: directory.appendingPathComponent("last-good", isDirectory: true),
            watermarkDirectory: directory.appendingPathComponent("watermark", isDirectory: true),
            watermarkWriter: { data, destination in
                writeCount += 1
                if writeCount == 2 {
                    throw NSError(domain: "AccessDiscoveryWatermarkAtomicTest", code: 1)
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        let key = "v1|production|wenxintong|app1-ios|ios|app1|com.wenxintong.app1|tenant-fixture"
        let original = AccessDiscoveryTrustWatermark(
            recoveryGeneration: 1,
            currentFencingGeneration: 1,
            keyStateHash: String(repeating: "a", count: 64),
            configGeneration: 42,
            contentHash: String(repeating: "b", count: 64),
            configVersion: "fixture-v42"
        )
        let next = AccessDiscoveryTrustWatermark(
            recoveryGeneration: 2,
            currentFencingGeneration: 2,
            keyStateHash: String(repeating: "c", count: 64),
            configGeneration: 43,
            contentHash: String(repeating: "d", count: 64),
            configVersion: "fixture-v43"
        )

        XCTAssertTrue(try store.advanceTrustWatermark(original, key: key))
        XCTAssertThrowsError(try store.advanceTrustWatermark(next, key: key))
        XCTAssertEqual(try store.loadTrustWatermark(key: key), original)
    }

    private func makeDomainOnlySignedFixture(
        appID: String = "app1-ios",
        channel: String = "app1",
        clientIdentifier: String = "com.wenxintong.app1",
        discoveryFallbacks: [RemoteAccessDiscoveryEndpoint] = [],
        endpoints suppliedEndpoints: [RemoteAccessDiscoveryEndpoint]? = nil,
        contractVersion: Int = 1
    ) throws -> IOSDomainOnlySignedFixture {
        let signingKeyID = "task267-ed25519-v1"
        let rootKeyID = "task267-recovery-root-v1"
        let signingPrivateKey = Curve25519.Signing.PrivateKey()
        let rootPrivateKey = Curve25519.Signing.PrivateKey()
        let issuedAt = "2026-07-24T00:00:00Z"
        let expiresAt = "2026-07-24T01:00:00Z"
        let keyStateExpiresAt = "2026-07-31T00:00:00Z"
        let endpoints = suppliedEndpoints ?? [makeProductionDomainOnlyEndpoint()]

        let keyAuthorization = AccessDiscoveryKeyAuthorization(
            keyID: signingKeyID,
            algorithm: "Ed25519",
            role: "primary",
            status: "active",
            environment: "production",
            productID: "wenxintong",
            appID: appID,
            platform: "ios",
            channel: channel,
            clientIdentifier: clientIdentifier,
            notBefore: issuedAt,
            notAfter: keyStateExpiresAt,
            minFencingGeneration: 1,
            maxFencingGeneration: nil
        )
        var keyStatePayload = AccessDiscoveryKeyStatePayload(
            purpose: "tenant_access_discovery_key_state",
            contractVersion: contractVersion,
            recoveryGeneration: 1,
            currentFencingGeneration: 1,
            issuedAt: issuedAt,
            expiresAt: keyStateExpiresAt,
            keys: [keyAuthorization]
        )
        if contractVersion == 2 { keyStatePayload.keysetRevision = 1 }
        let keyStateRaw = try PreloginStrictJSON.canonical(keyStatePayload)
        var keyStateMessage = AccessDiscoveryTrustConfiguration.keyStateSigningDomain
        keyStateMessage.append(keyStateRaw)
        let keyStateDigest = Data(SHA512.hash(data: keyStateMessage))
        let keyStateSignature = try rootPrivateKey.signature(for: keyStateDigest)
        let signedKeyState = SignedAccessDiscoveryKeyState(
            payloadB64: keyStateRaw.base64EncodedString(),
            rootKeyID: rootKeyID,
            signatureAlg: "Ed25519",
            signature: keyStateSignature.base64EncodedString()
        )

        func payload(contentHash: String) -> SignedAccessDiscoveryPayload {
            var payload = SignedAccessDiscoveryPayload(
                purpose: "tenant_access_discovery",
                contractVersion: contractVersion,
                canonicalizationVersion: 1,
                tenantID: "tenant-fixture",
                appID: appID,
                platform: "ios",
                environment: "production",
                productID: "wenxintong",
                channel: channel,
                clientIdentifier: clientIdentifier,
                fencingGeneration: 1,
                generation: 42,
                configVersion: "fixture-v42",
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                serverTime: 1_769_040_000,
                ttlSeconds: 60,
                refreshJitterSeconds: 10,
                source: "platform",
                stale: false,
                degraded: false,
                contentHash: contentHash,
                endpoints: endpoints,
                discoveryFallbacks: discoveryFallbacks
            )
            if contractVersion == 2 {
                payload.publicationID = "access-publication-42"
                payload.publicationRevision = 42
                payload.profileFingerprint = "sha256:\(contentHash)"
                payload.lifetimeMode = .untilRevoked
                payload.status = "active"
                payload.keysetRevision = 1
            }
            return payload
        }

        let preliminaryRaw = try PreloginStrictJSON.canonical(
            payload(contentHash: String(repeating: "0", count: 64))
        )
        let contentHash = try PreloginStrictJSON.accessDiscoveryExecutableHash(preliminaryRaw)
        let payloadRaw = try PreloginStrictJSON.canonical(payload(contentHash: contentHash))
        var payloadMessage = AccessDiscoveryTrustConfiguration.signingDomain
        payloadMessage.append(payloadRaw)
        let payloadDigest = Data(SHA512.hash(data: payloadMessage))
        let payloadSignature = try signingPrivateKey.signature(for: payloadDigest)
        let envelopeData = try JSONSerialization.data(withJSONObject: [
            "payload_b64": payloadRaw.base64EncodedString(),
            "key_id": signingKeyID,
            "signature_alg": "Ed25519",
            "signature": payloadSignature.base64EncodedString(),
            "key_state": [
                "payload_b64": signedKeyState.payloadB64,
                "root_key_id": signedKeyState.rootKeyID,
                "signature_alg": signedKeyState.signatureAlg,
                "signature": signedKeyState.signature,
            ],
        ], options: [.sortedKeys])
        let envelope = try JSONDecoder().decode(SignedAccessDiscoveryEnvelope.self, from: envelopeData)
        let trust = AccessDiscoveryTrustConfiguration(
            required: true,
            environment: "production",
            productID: "wenxintong",
            appID: appID,
            channel: channel,
            clientIdentifier: clientIdentifier,
            publicKeys: [signingKeyID: signingPrivateKey.publicKey.rawRepresentation],
            recoveryRootKeyID: rootKeyID,
            recoveryRootPublicKey: rootPrivateKey.publicKey.rawRepresentation
        )
        return IOSDomainOnlySignedFixture(trust: trust, envelope: envelope)
    }

    private func loadSignedFixture() throws -> IOSAccessDiscoveryFixture {
        let codeDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = codeDirectory.appendingPathComponent("qa/fixtures/access-discovery-signed-v1.json")
        return try JSONDecoder().decode(IOSAccessDiscoveryFixture.self, from: Data(contentsOf: url))
    }

    private func makeStore() throws -> AccessDiscoveryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccessDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return AccessDiscoveryStore(
            baseDirectory: directory.appendingPathComponent("last-good", isDirectory: true),
            watermarkDirectory: directory.appendingPathComponent("watermark", isDirectory: true)
        )
    }

    private func accessDiscoveryTrustWatermarkKey(
        _ context: IMAPIContext,
        trust: AccessDiscoveryTrustConfiguration
    ) -> String {
        [
            "v2",
            trust.environment,
            trust.appID,
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "|")
    }

    private func makeContext(
        accountID: String = "account-1",
        tenantID: String = "tenant-1",
        appID: String = "ios-main"
    ) -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: accountID,
            tenantID: tenantID,
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: appID,
            deviceID: "device-1"
        )
    }

    private func isolatedRuntimeRouteStore() -> IMRuntimeRouteStore {
        IMRuntimeRouteStore(
            defaults: UserDefaults(suiteName: "AccessDiscoveryTests.routes.\(UUID().uuidString)")!
        )
    }

    private func makeResponse(
        configVersion: String,
        endpoints: [RemoteAccessDiscoveryEndpoint]? = nil,
        discoveryFallbacks: [RemoteAccessDiscoveryEndpoint] = []
    ) -> RemoteAccessDiscoveryResponse {
        RemoteAccessDiscoveryResponse(
            contractVersion: 1,
            configVersion: configVersion,
            serverTime: 1_782_710_000,
            ttlSeconds: 60,
            refreshJitterSeconds: 10,
            source: "platform",
            stale: false,
            degraded: false,
            endpoints: endpoints ?? [
                makeEndpoint(id: "ga", host: "ga.example.test", priority: 10, network: "accelerated"),
                makeEndpoint(id: "direct", host: "direct.example.test", priority: 20, network: "direct")
            ],
            discoveryFallbacks: discoveryFallbacks,
            signatureAlg: "ignored",
            signature: "ignored-by-client"
        )
    }

    private func copyResponse(
        _ response: RemoteAccessDiscoveryResponse,
        discoveryFallbacks: [RemoteAccessDiscoveryEndpoint]
    ) -> RemoteAccessDiscoveryResponse {
        RemoteAccessDiscoveryResponse(
            contractVersion: response.contractVersion,
            configVersion: response.configVersion,
            serverTime: response.serverTime,
            ttlSeconds: response.ttlSeconds,
            refreshJitterSeconds: response.refreshJitterSeconds,
            source: response.source,
            stale: response.stale,
            degraded: response.degraded,
            endpoints: response.endpoints,
            discoveryFallbacks: discoveryFallbacks,
            signatureAlg: response.signatureAlg,
            signature: response.signature,
            trust: response.trust
        )
    }

    private func makeDiscoveryFallback(
        id: String,
        priority: Int,
        host: String? = nil
    ) -> RemoteAccessDiscoveryEndpoint {
        let hostname = host ?? "\(id).example.test"
        return RemoteAccessDiscoveryEndpoint(
            id: id,
            usage: "access_discovery",
            protocolValue: "https",
            url: "https://\(hostname)/api/tenant/access/v1/endpoints",
            host: hostname,
            port: 443,
            priority: priority,
            weight: 100,
            network: "fallback",
            tls: true,
            auth: "none",
            status: "ready"
        )
    }

    private func makeEndpoint(
        id: String,
        host: String,
        priority: Int,
        network: String,
        protocolValue: String = "wss",
        url: String? = nil,
        port: Int = 443,
        path: String = "/im/ws",
        resolvedIPs: [String] = ["203.0.113.10"],
        tlsServerName: String? = nil,
        httpHost: String? = nil,
        dialMode: String? = "domain_or_ip_hint",
        includeTLSServerName: Bool = true,
        includeHTTPHost: Bool = true
    ) -> RemoteAccessDiscoveryEndpoint {
        RemoteAccessDiscoveryEndpoint(
            id: id,
            usage: "im_realtime",
            protocolValue: protocolValue,
            url: url ?? "wss://\(host)/im/ws",
            host: host,
            port: port,
            path: path,
            resolvedIPs: resolvedIPs,
            tlsServerName: includeTLSServerName ? (tlsServerName ?? host) : nil,
            httpHost: includeHTTPHost ? (httpHost ?? host) : nil,
            dialMode: dialMode,
            priority: priority,
            weight: 100,
            network: network,
            auth: "im_token",
            connectTimeoutMs: 3_000,
            heartbeatSeconds: 25,
            minStableSeconds: 300,
            failbackAfterSeconds: 300,
            cooldownSeconds: 300,
            maxParallelRace: 2,
            status: "ready"
        )
    }

    private func makeProductionDomainOnlyEndpoint(
        id: String = "cloudfront-wss",
        usage: String = "im_realtime",
        protocolValue: String = "wss",
        host: String = "d111111abcdef8.cloudfront.net",
        url: String? = nil,
        path: String = "/im/ws",
        resolvedIPs: [String] = [],
        dialMode: String = "domain_only",
        network: String = "fallback",
        tlsServerName: String? = nil,
        httpHost: String? = nil,
        provider: String = "aws_cloudfront",
        resourceType: String = "controlled_load_balancer",
        resourceID: String = "E1234567890ABC",
        priority: Int = 10,
        auth: String = "im_token"
    ) -> RemoteAccessDiscoveryEndpoint {
        RemoteAccessDiscoveryEndpoint(
            id: id,
            usage: usage,
            protocolValue: protocolValue,
            url: url ?? "\(protocolValue)://\(host)\(path)",
            host: host,
            port: 443,
            path: path,
            resolvedIPs: resolvedIPs,
            tlsServerName: tlsServerName ?? host,
            httpHost: httpHost ?? host,
            dialMode: dialMode,
            priority: priority,
            weight: 100,
            provider: provider,
            network: network,
            tls: true,
            auth: auth,
            minStableSeconds: 300,
            failbackAfterSeconds: 300,
            cooldownSeconds: 300,
            status: "ready",
            protectedResourceID: resourceID,
            protectedResourceType: resourceType,
            protectionEvidenceHash: String(repeating: "a", count: 64),
            protectionExpiresAt: "2026-08-03T00:00:00Z"
        )
    }

    private func accessDiscoveryCacheKey(_ context: IMAPIContext) -> String {
        [
            "v3",
            AccessDiscoveryTrustConfiguration.load().environment,
            IMAPIContext.normalizedIOSAppID(context.appID),
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "|")
    }
}

private struct IOSDomainOnlySignedFixture {
    let trust: AccessDiscoveryTrustConfiguration
    let envelope: SignedAccessDiscoveryEnvelope
}

private struct IOSAccessDiscoveryFixture: Decodable {
    let publicKeyB64: String
    let recoveryRootPublicKeyB64: String
    let recoveryRootKeyID: String
    let ios: SignedAccessDiscoveryEnvelope

    enum CodingKeys: String, CodingKey {
        case publicKeyB64 = "public_key_b64"
        case recoveryRootPublicKeyB64 = "recovery_root_public_key_b64"
        case recoveryRootKeyID = "recovery_root_key_id"
        case ios
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publicKeyB64 = try container.decode(String.self, forKey: .publicKeyB64)
        recoveryRootPublicKeyB64 = try container.decode(String.self, forKey: .recoveryRootPublicKeyB64)
        recoveryRootKeyID = try container.decode(String.self, forKey: .recoveryRootKeyID)
        ios = try container.decode(SignedAccessDiscoveryEnvelope.self, forKey: .ios)
    }
}

@MainActor
private final class FakeAccessDiscoveryFetcher: AccessDiscoveryFetching {
    private var results: [Result<RemoteAccessDiscoveryResponse, Error>]
    private let onRequest: (() -> Void)?
    private(set) var requestCount = 0
    private(set) var endpointURLs: [URL?] = []
    private(set) var timeoutIntervals: [TimeInterval] = []

    init(
        results: [Result<RemoteAccessDiscoveryResponse, Error>],
        onRequest: (() -> Void)? = nil
    ) {
        self.results = results
        self.onRequest = onRequest
    }

    func accessDiscoveryEndpoints(context: IMAPIContext) async throws -> RemoteAccessDiscoveryResponse {
        try await accessDiscoveryEndpoints(context: context, endpointURL: nil, timeoutInterval: 2.5)
    }

    func accessDiscoveryEndpoints(
        context: IMAPIContext,
        endpointURL: URL?,
        timeoutInterval: TimeInterval
    ) async throws -> RemoteAccessDiscoveryResponse {
        requestCount += 1
        endpointURLs.append(endpointURL)
        timeoutIntervals.append(timeoutInterval)
        onRequest?()
        guard !results.isEmpty else {
            throw IMAPIError.server("missing fake discovery result")
        }
        let result = results.count == 1 ? results[0] : results.removeFirst()
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

private final class AccessDiscoveryHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let result: HTTPTransportResult
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    init(result: HTTPTransportResult) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            requests.append(request)
        }
        return result
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        result
    }
}

private final class AppBootstrapTestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var value: UInt64

	init(nowMS: UInt64) {
		value = nowMS
	}

	func now() -> UInt64 {
		lock.withLock { value }
	}

	func advance(by milliseconds: UInt64) {
		lock.withLock {
			value = value > UInt64.max - milliseconds ? UInt64.max : value + milliseconds
		}
	}
}

private final class AppBootstrapFailoverTransport: HTTPTransport, @unchecked Sendable {
	enum Outcome {
		case failure(URLError.Code, advanceMS: UInt64)
		case response(HTTPTransportResult, advanceMS: UInt64)
	}

	struct Request: Equatable {
		let host: String?
		let path: String
		let atMS: UInt64
	}

	private let lock = NSLock()
	private let clock: AppBootstrapTestClock
	private var outcomes: [Outcome]
	private var capturedRequests: [Request] = []

	init(clock: AppBootstrapTestClock, outcomes: [Outcome]) {
		self.clock = clock
		self.outcomes = outcomes
	}

	var requests: [Request] {
		lock.withLock { capturedRequests }
	}

	func data(for request: URLRequest) async throws -> HTTPTransportResult {
		let outcome: Outcome = try lock.withLock {
			let pathAndQuery = request.url.map { url in
				url.path + (url.query.map { "?\($0)" } ?? "")
			} ?? ""
			capturedRequests.append(.init(
				host: request.url?.host,
				path: pathAndQuery,
				atMS: clock.now()
			))
			guard !outcomes.isEmpty else { throw URLError(.unknown) }
			return outcomes.removeFirst()
		}
		switch outcome {
		case .failure(let code, let advanceMS):
			clock.advance(by: advanceMS)
			throw URLError(code)
		case .response(let result, let advanceMS):
			clock.advance(by: advanceMS)
			return result.resolvingResponseURL(request.url)
		}
	}

	func upload(
		for request: URLRequest,
		from data: Data,
		delegate: URLSessionTaskDelegate?
	) async throws -> HTTPTransportResult {
		try await self.data(for: request)
	}
}

private final class RuntimeRoutesDefaultsBox: @unchecked Sendable {
	let value: UserDefaults
	init(_ value: UserDefaults) { self.value = value }
}

@MainActor
final class RuntimeRoutesP0Tests: XCTestCase {
    func testAliyunGAHTTPAndWSSUseSameBrandAndKeepIndependentCloudFrontRecovery() throws {
        let gaHost = "im.brand-a.example.com"
        let cfHost = "d111111abcdef8.cloudfront.net"
        var services: [String: IMRuntimeRouteEndpointSet] = Dictionary(uniqueKeysWithValues:
            [IMRuntimeRouteService.tenantAPI, .imAPI, .imRealtime].map { service in
                let realtime = service == .imRealtime
                let scheme = realtime ? "wss" : "https"
                let path = realtime ? "/im/ws" : ""
                return (service.rawValue, .init(
                    preferred: ["\(scheme)://\(gaHost)\(path)"],
                    backups: ["\(scheme)://\(cfHost)\(path)"],
                    preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
                ))
            })
        services[IMRuntimeRouteService.platformAPI.rawValue] = .init(
            preferred: ["https://platform.example.com"],
            backups: ["https://platform-backup.example.com"],
            preferredSource: "app_preferred", backupSource: "common_platform_backup"
        )
        let unsigned = IMRuntimeRouteSnapshot(contractVersion: 2, appID: "app-one", tenantID: "tenant-a",
            revision: 1, source: "bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
            services: services, policy: IMRuntimeRoutePolicy())
        let routes = IMRuntimeRouteSnapshot(contractVersion: 2, appID: "app-one", tenantID: "tenant-a",
            revision: 1, source: "bootstrap", status: "ready", configHash: try XCTUnwrap(unsigned.recomputedConfigHash),
            services: services, policy: IMRuntimeRoutePolicy())
        let validated = try XCTUnwrap(routes.validated(appID: "app-one", tenantID: "tenant-a"))
        XCTAssertEqual(validated.services[IMRuntimeRouteService.platformAPI.rawValue]?.preferred,
            ["https://platform.example.com"])
        XCTAssertEqual(validated.services[IMRuntimeRouteService.platformAPI.rawValue]?.backups,
            ["https://platform-backup.example.com"])
        let client = IMAPIClient(platformBase: URL(string: "https://platform.example.com")!,
            tenantBase: URL(string: "https://old-tenant.example.com")!,
            imBase: URL(string: "https://old-im.example.com")!, runtimeRouteStore: store)
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
        let context = IMAPIContext(platformToken: "platform-token", accountID: "account-a", tenantID: "tenant-a",
            imUID: "uid-a", imToken: "im-token", platformAuthSession: nil, tenantAuthSession: nil,
            appID: "app-one", deviceID: "fixture-device")
        for service in [IMRuntimeRouteService.tenantAPI, .imAPI, .imRealtime] {
            XCTAssertEqual(client.activeRuntimeBase(service: service, appID: "app-one", tenantID: "tenant-a")?.host, gaHost)
            XCTAssertNil(client.activeRuntimeBase(service: service, appID: "app-one", tenantID: "tenant-b"))
        }
        XCTAssertEqual(client.webSocketURL(context: context)?.absoluteString, "wss://\(gaHost)/im/ws")
        let selector = IMRuntimeRouteSelector(store: store)
        let qualified = IMRuntimeColdLaunchAttempt(processWasNotRunning: true, foregroundLaunch: true,
            networkReachable: true, backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000)
        for service in [IMRuntimeRouteService.tenantAPI, .imAPI, .imRealtime] {
            for _ in 0..<routes.policy.recoveryColdLaunchFailures {
                selector.recordColdLaunch(qualified, snapshot: routes, service: service)
            }
            XCTAssertEqual(client.activeRuntimeBase(service: service, appID: "app-one", tenantID: "tenant-a")?.host, cfHost)
            XCTAssertEqual(selector.endpoints(routes, service: service).count, 2)
        }
        XCTAssertEqual(client.webSocketURL(context: context)?.absoluteString, "wss://\(cfHost)/im/ws")
    }

    private var defaults: UserDefaults!
    private var store: IMRuntimeRouteStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "RuntimeRoutesP0Tests.\(UUID().uuidString)")!
        store = IMRuntimeRouteStore(defaults: defaults)
    }

    private func snapshot(
		revision: UInt64 = 1,
		appID: String = "app-one",
		tenantID: String? = "tenant-a",
		hash: String? = nil,
		tenantPreferred: String = "https://tenant-primary.example.com"
	) -> IMRuntimeRouteSnapshot {
		let services: [String: IMRuntimeRouteEndpointSet] = [
			"platform_api": .init(
				preferred: ["https://platform-primary.example.com"], backups: ["https://platform-backup.example.net"],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"tenant_api": .init(
				preferred: [tenantPreferred], backups: ["https://tenant-backup.example.net"],
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
			"im_api": .init(
				preferred: ["https://im-primary.example.com"], backups: ["https://im-backup.example.net"],
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
			"im_realtime": .init(
				preferred: ["wss://ws-primary.example.com"], backups: ["wss://ws-backup.example.net"],
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
		]
		let policy = IMRuntimeRoutePolicy()
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: appID, tenantID: tenantID, revision: revision,
			source: "bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
			services: services, policy: policy
		)
		return .init(
			contractVersion: 2, appID: appID, tenantID: tenantID, revision: revision,
			source: "bootstrap", status: "ready", configHash: hash ?? unsigned.recomputedConfigHash!,
			services: services, policy: policy
		)
    }

	private func invalidatePersistedCurrentRouteAuthority() throws {
		let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("wxt.runtime.routes.v2.") })
		let encoded = try XCTUnwrap(defaults.data(forKey: key))
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		var current = try XCTUnwrap(object["current"] as? [String: Any])
		var services = try XCTUnwrap(current["services"] as? [String: Any])
		var tenantAPI = try XCTUnwrap(services["tenant_api"] as? [String: Any])
		tenantAPI["preferred_source"] = "app_preferred"
		services["tenant_api"] = tenantAPI
		current["services"] = services
		object["current"] = current
		defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
	}

    private func publishedSnapshot(
        revision: UInt64,
        publicationID: String,
        environment: String = "production"
    ) -> IMRuntimeRouteSnapshot {
        let base = snapshot(revision: revision)
        return IMRuntimeRouteSnapshot(
            contractVersion: base.contractVersion,
            appID: base.appID,
            tenantID: base.tenantID,
            revision: base.revision,
            source: base.source,
            status: base.status,
            configHash: base.configHash,
            services: base.services,
            policy: base.policy,
            environment: environment,
            publicationID: publicationID,
            publicationRevision: revision,
            profileFingerprint: "sha256:\(base.configHash)",
            lifetimeMode: .untilRevoked,
            publicationStatus: "active",
            keysetRevision: 7
        )
    }

	private func appBootstrapServices() -> [String: IMRuntimeRouteEndpointSet] {
		[
			"platform_api": .init(
				preferred: ["https://platform-primary.example.com"], backups: ["https://platform-backup.example.net"],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"tenant_api": .init(
				preferred: ["https://tenant-primary.example.com"], backups: [],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"im_api": .init(
				preferred: ["https://im-primary.example.com"], backups: [],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"im_realtime": .init(
				preferred: ["wss://ws-primary.example.com"], backups: [],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
		]
	}

    func testAtomicCurrentPreviousUInt64RevisionRestartAndIsolation() {
        XCTAssertEqual(store.apply(snapshot(), appID: "app-one", tenantID: "tenant-a"), .applied)
		let jsSafeMax: UInt64 = 9_007_199_254_740_991
        XCTAssertEqual(store.apply(snapshot(revision: jsSafeMax), appID: "app-one", tenantID: "tenant-a"), .applied)
        let restarted = IMRuntimeRouteStore(defaults: defaults)
		XCTAssertEqual(restarted.record(appID: "app-one", tenantID: "tenant-a").current?.revision, jsSafeMax)
        XCTAssertEqual(restarted.record(appID: "app-one", tenantID: "tenant-a").previous?.revision, 1)
        XCTAssertNil(restarted.record(appID: "app-one", tenantID: "tenant-b").current)
        XCTAssertEqual(restarted.apply(snapshot(revision: 2), appID: "app-one", tenantID: "tenant-a"), .rollback)
		let current = snapshot(revision: jsSafeMax)
		let equalDifferent = IMRuntimeRouteSnapshot(
			contractVersion: current.contractVersion, appID: current.appID, tenantID: current.tenantID,
			revision: current.revision, source: "different-source", status: current.status,
			configHash: current.configHash, services: current.services, policy: current.policy
		)
		XCTAssertEqual(restarted.apply(equalDifferent, appID: "app-one", tenantID: "tenant-a"), .conflict)
        XCTAssertEqual(restarted.apply(snapshot(revision: .max), appID: "app-one", tenantID: "tenant-a"), .identity)
    }

    func testPublicationTombstoneKeepsHighWatermarkAndHigherRevisionCanRepublishPriorContent() {
        let active = publishedSnapshot(revision: 20, publicationID: "publication-20")
        XCTAssertEqual(store.apply(active, appID: active.appID, tenantID: active.tenantID), .applied)
        XCTAssertEqual(
            store.applyRevocation(
                environment: "production",
                appID: active.appID,
                tenantID: active.tenantID,
                revision: 21,
                publicationID: "publication-21",
                profileFingerprint: active.profileFingerprint ?? "",
                status: "tombstone",
                keysetRevision: 7
            ),
            .revoked
        )
        XCTAssertNil(store.restore(appID: active.appID, tenantID: active.tenantID))
        XCTAssertEqual(store.record(appID: active.appID, tenantID: active.tenantID).publicationWatermark?.revision, 21)
        XCTAssertEqual(store.apply(active, appID: active.appID, tenantID: active.tenantID), .rollback)

        let rollbackContent = publishedSnapshot(revision: 22, publicationID: "publication-22")
        XCTAssertEqual(store.apply(rollbackContent, appID: active.appID, tenantID: active.tenantID), .applied)
        XCTAssertEqual(store.restore(appID: active.appID, tenantID: active.tenantID)?.revision, 22)

        let sameRevisionDifferentPublication = publishedSnapshot(revision: 22, publicationID: "publication-22-conflict")
        XCTAssertEqual(
            store.apply(sameRevisionDifferentPublication, appID: active.appID, tenantID: active.tenantID),
            .conflict
        )
    }

	func testApplyReplacesInvalidPersistedCurrentAtSameRevision() throws {
		let authoritative = snapshot(revision: 7)
		XCTAssertEqual(store.apply(authoritative, appID: authoritative.appID, tenantID: authoritative.tenantID), .applied)
		var recovery = IMRuntimeRouteRecoveryState()
		recovery.recovery = true
		XCTAssertTrue(store.updateRecovery(recovery, service: .tenantAPI, snapshot: authoritative))
		try invalidatePersistedCurrentRouteAuthority()

		let restarted = IMRuntimeRouteStore(defaults: defaults)
		XCTAssertEqual(
			restarted.apply(authoritative, appID: authoritative.appID, tenantID: authoritative.tenantID),
			.applied
		)
		let record = restarted.record(appID: authoritative.appID, tenantID: authoritative.tenantID)
		XCTAssertEqual(record.current, authoritative)
		XCTAssertNil(record.previous)
		XCTAssertTrue(record.recoveryByService.isEmpty)
	}

	func testApplyRejectsDifferentValidRouteAtSameRevision() {
		let current = snapshot(revision: 8)
		XCTAssertEqual(store.apply(current, appID: current.appID, tenantID: current.tenantID), .applied)
		let different = snapshot(
			revision: current.revision,
			tenantPreferred: "https://tenant-alternate.example.com"
		)
		XCTAssertNotEqual(different.configHash, current.configHash)

		XCTAssertEqual(store.apply(different, appID: current.appID, tenantID: current.tenantID), .conflict)
		XCTAssertEqual(store.record(appID: current.appID, tenantID: current.tenantID).current, current)
	}

	func testApplyRejectsLowerRevisionAgainstValidPersistedCurrent() {
		let current = snapshot(revision: 9)
		XCTAssertEqual(store.apply(current, appID: current.appID, tenantID: current.tenantID), .applied)

		XCTAssertEqual(
			store.apply(snapshot(revision: 8), appID: current.appID, tenantID: current.tenantID),
			.rollback
		)
		XCTAssertEqual(store.record(appID: current.appID, tenantID: current.tenantID).current, current)
	}

	func testRestorePromotesPreviousWhenCurrentGenerationIsStructurallyCorrupted() throws {
		let first = snapshot(revision: 1)
		let second = snapshot(revision: 2)
		XCTAssertEqual(store.apply(first, appID: first.appID, tenantID: first.tenantID), .applied)
		XCTAssertEqual(store.apply(second, appID: second.appID, tenantID: second.tenantID), .applied)
		let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("wxt.runtime.routes.v2.") })
		let encoded = try XCTUnwrap(defaults.data(forKey: key))
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		var current = try XCTUnwrap(object["current"] as? [String: Any])
		current["revision"] = "corrupted-current-revision"
		object["current"] = current
		defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)

		let restarted = IMRuntimeRouteStore(defaults: defaults)
		let restored = restarted.restore(appID: first.appID, tenantID: first.tenantID)

		XCTAssertEqual(restored, first)
		XCTAssertEqual(restarted.record(appID: first.appID, tenantID: first.tenantID).current, first)
		XCTAssertNil(restarted.record(appID: first.appID, tenantID: first.tenantID).previous)
	}

	@MainActor
	func testIMAPIClientColdInitRestoresPromotedPreviousAppRouteFromAtomicStore() throws {
		let appID = IMAPIContext.canonicalIOSAppID
		func appSnapshot(revision: UInt64) -> IMRuntimeRouteSnapshot {
			let services = appBootstrapServices()
			let unsigned = IMRuntimeRouteSnapshot(
				contractVersion: 2, appID: appID, tenantID: nil, revision: revision,
				source: "app_bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
				services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
				bootstrapHost: "bootstrap.wenxintongim.com",
				preferredEndpoints: services.mapValues(\.preferred)
			)
			return IMRuntimeRouteSnapshot(
				contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: nil,
				revision: revision, source: unsigned.source, status: unsigned.status,
				configHash: unsigned.recomputedConfigHash!, services: unsigned.services,
				policy: unsigned.policy, hashScope: .appBootstrap,
				bootstrapHost: unsigned.bootstrapHost, preferredEndpoints: unsigned.preferredEndpoints
			)
		}
		let first = appSnapshot(revision: 1)
		let second = appSnapshot(revision: 2)
		XCTAssertEqual(store.apply(first, appID: appID, tenantID: nil), .applied)
		XCTAssertEqual(store.apply(second, appID: appID, tenantID: nil), .applied)
		let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("wxt.runtime.routes.v2.") })
		let encoded = try XCTUnwrap(defaults.data(forKey: key))
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		var current = try XCTUnwrap(object["current"] as? [String: Any])
		current["revision"] = ["not": "a-number"]
		object["current"] = current
		defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)

		let client = IMAPIClient(
			platformBase: IMAPIClient.releasePlaceholderPlatformBase,
			bootstrapBases: [URL(string: "https://bootstrap.wenxintongim.com")!],
			httpTransport: AccessDiscoveryHTTPTransport(
				result: .init(data: Data(), isHTTPResponse: true, statusCode: 500)
			),
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)
		)

		XCTAssertEqual(
			client.activeRuntimeBase(service: .platformAPI, appID: appID, tenantID: nil)?.host,
			"platform-primary.example.com"
		)
		XCTAssertEqual(store.record(appID: appID, tenantID: nil).current?.revision, 1)
	}

	func testProductionEndpointValidationRequiresSecureFQDNPort443WithoutPlaceholders() {
		let validHTTP = "https://tenant-api.customer-owned.net:443"
		let validWS = "wss://realtime.customer-owned.net:443/im/ws"
		XCTAssertEqual(
			IMRuntimeRouteSnapshot.normalizedEndpoint(validHTTP, service: .tenantAPI, allowDevelopmentEndpoints: false),
			validHTTP
		)
		XCTAssertEqual(
			IMRuntimeRouteSnapshot.normalizedEndpoint(validWS, service: .imRealtime, allowDevelopmentEndpoints: false),
			validWS
		)
		for raw in [
			"http://tenant.customer.net", "https://tenant.customer.net:444", "https://tenant",
			"https://127.0.0.1", "https://[::1]", "https://placeholder.customer.net",
			"https://tenant.example.com", "https://tenant.invalid",
		] {
			XCTAssertNil(
				IMRuntimeRouteSnapshot.normalizedEndpoint(raw, service: .tenantAPI, allowDevelopmentEndpoints: false),
				raw
			)
		}
		XCTAssertNil(
			IMRuntimeRouteSnapshot.normalizedEndpoint(
				"https://realtime.customer.net", service: .imRealtime, allowDevelopmentEndpoints: false
			)
		)
		XCTAssertEqual(
			IMRuntimeRouteSnapshot.normalizedEndpoint(
				"https://TENANT-API.Customer-Owned.NET:443/", service: .tenantAPI,
				allowDevelopmentEndpoints: false
			),
			"https://tenant-api.customer-owned.net:443"
		)
	}

	func testSnapshotRequiresExactReadyFourServiceRoutesAndBoundedCanonicalEndpoints() throws {
		let base = snapshot()
		func signed(
			services: [String: IMRuntimeRouteEndpointSet],
			status: String = "ready",
			source: String = "bootstrap"
		) throws -> IMRuntimeRouteSnapshot {
			let unsigned = IMRuntimeRouteSnapshot(
				contractVersion: 2, appID: base.appID, tenantID: base.tenantID, revision: 2,
				source: source, status: status, configHash: String(repeating: "0", count: 64),
				services: services, policy: base.policy
			)
			return IMRuntimeRouteSnapshot(
				contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: unsigned.tenantID,
				revision: unsigned.revision, source: source, status: status,
				configHash: try XCTUnwrap(unsigned.recomputedConfigHash), services: services, policy: unsigned.policy
			)
		}

		for routeStatus in ["missing", "backup_only", "READY"] {
			var services = base.services
			services["tenant_api"] = .init(
				preferred: ["https://tenant-primary.example.com"], backups: ["https://tenant-backup.example.net"],
				status: routeStatus, preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			)
			XCTAssertNil(try signed(services: services).validated(appID: base.appID, tenantID: base.tenantID))
		}
		XCTAssertNil(
			try signed(services: base.services, status: "missing").validated(appID: base.appID, tenantID: base.tenantID)
		)
		XCTAssertNil(
			try signed(services: base.services, source: " bootstrap ").validated(appID: base.appID, tenantID: base.tenantID)
		)

		var tooMany = base.services
		tooMany["tenant_api"] = .init(
			preferred: (0..<17).map { "https://tenant-\($0).example.com" }, backups: [],
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(try signed(services: tooMany).validated(appID: base.appID, tenantID: base.tenantID))
		var tooManyCombined = base.services
		tooManyCombined["tenant_api"] = .init(
			preferred: (0..<8).map { "https://tenant-\($0).example.com" },
			backups: (0..<9).map { "https://tenant-backup-\($0).example.net" },
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(
			try signed(services: tooManyCombined).validated(appID: base.appID, tenantID: base.tenantID)
		)

		var tooLong = base.services
		tooLong["tenant_api"] = .init(
			preferred: ["https://tenant.example.com/\(String(repeating: "a", count: 2_049))"], backups: [],
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(try signed(services: tooLong).validated(appID: base.appID, tenantID: base.tenantID))

		var nonRootHTTP = base.services
		nonRootHTTP["tenant_api"] = .init(
			preferred: ["https://tenant.example.com/api"], backups: [],
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(try signed(services: nonRootHTTP).validated(appID: base.appID, tenantID: base.tenantID))

		var duplicate = base.services
		duplicate["tenant_api"] = .init(
			preferred: ["https://tenant-primary.example.com"],
			backups: ["https://tenant-backup.example.net", "https://TENANT-BACKUP.example.net"],
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(try signed(services: duplicate).validated(appID: base.appID, tenantID: base.tenantID))

		var wrongPreferredSource = base.services
		wrongPreferredSource["im_api"] = .init(
			preferred: ["https://im-primary.example.com"], backups: ["https://im-backup.example.net"],
			preferredSource: "app_preferred", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(
			try signed(services: wrongPreferredSource).validated(appID: base.appID, tenantID: base.tenantID)
		)

		var wrongEmptyBackupSource = base.services
		wrongEmptyBackupSource["im_api"] = .init(
			preferred: ["https://im-primary.example.com"], backups: [],
			preferredSource: "tenant_deployment_authority", backupSource: ""
		)
		XCTAssertNil(
			try signed(services: wrongEmptyBackupSource).validated(appID: base.appID, tenantID: base.tenantID)
		)
	}

	func testServerSourceTopologyCanonicalGoldenHash() throws {
		func route(_ preferred: String, _ backup: String, preferredSource: String, backupSource: String) -> [String: Any] {
			[
				"preferred": [preferred], "backups": [backup], "status": "ready",
				"preferred_source": preferredSource, "backup_source": backupSource,
			]
		}
		let payload: [String: Any] = [
			"route_source": "tenant.deployment.a3108a06-6077-4056-a346-f5e9aa58be95",
			"route_status": "ready",
			"routes": [
				"platform_api": route(
					"https://pingtai.wenxintongim.com", "https://dplatform123.cloudfront.net",
					preferredSource: "app_preferred",
					backupSource: "common_platform_backup"
				),
				"tenant_api": route(
					"https://api.wenxintongim.com", "https://dtenant123.cloudfront.net",
					preferredSource: "tenant_deployment_authority",
					backupSource: "tenant_deployment_backup"
				),
				"im_api": route(
					"https://api.wenxintongim.com", "https://dtenant123.cloudfront.net",
					preferredSource: "tenant_deployment_authority",
					backupSource: "tenant_deployment_backup"
				),
				"im_realtime": route(
					"wss://api.wenxintongim.com/im/ws", "wss://dtenant123.cloudfront.net/im/ws",
					preferredSource: "tenant_deployment_authority",
					backupSource: "tenant_deployment_backup"
				),
			],
		]
		let canonical = try JSONSerialization.data(
			withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
		)
		let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
		XCTAssertEqual(digest, "9547ac154e9d8c11dc3b029d954f5b867ab72aaa6d70bd495f374103d7acfadf")
	}

	func testFrozenRouteAuthorityRejectsCommonBackupForTenantDataPlane() throws {
		let base = snapshot()
		var invalidServices = base.services
		invalidServices["tenant_api"] = .init(
			preferred: ["https://tenant-primary.example.com"],
			backups: ["https://common-cf.example.net"],
			preferredSource: "tenant_deployment_authority",
			backupSource: "common_platform_backup"
		)
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: base.appID, tenantID: base.tenantID, revision: 2,
			source: base.source, status: base.status, configHash: String(repeating: "0", count: 64),
			services: invalidServices, policy: base.policy
		)
		let signed = IMRuntimeRouteSnapshot(
			contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: unsigned.tenantID,
			revision: unsigned.revision, source: unsigned.source, status: unsigned.status,
			configHash: try XCTUnwrap(unsigned.recomputedConfigHash), services: invalidServices, policy: unsigned.policy
		)
		XCTAssertNil(signed.validated(appID: base.appID, tenantID: base.tenantID))
	}

	func testAppBootstrapCanonicalHashCoversExactFourRoutesPreferredEndpointsAndPolicyV2() throws {
		let tenant = snapshot()
		XCTAssertEqual(tenant.configHash, "515ea2b77e827ce127654bbaeda39ce3ebdf1d110f89f4702ed496bb11e5549e")
		let services = appBootstrapServices()
		let preferred = services.mapValues(\.preferred)
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
			services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: preferred
		)
		let digest = try XCTUnwrap(unsigned.recomputedConfigHash)
		XCTAssertEqual(digest, "5f2d757ab208b16c49f00ab5949c25e9a0158caeb6bfd2779cfb2fd4f0bdce2f")
		let signed = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: digest,
			services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: preferred
		)
		XCTAssertNotNil(signed.validated(appID: "app-one", tenantID: nil))
		let incompletePreferred = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: digest,
			services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: ["platform_api": preferred["platform_api"]!]
		)
		XCTAssertNil(incompletePreferred.validated(appID: "app-one", tenantID: nil))
		let missingPolicyVersion = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: digest,
			services: services, policy: IMRuntimeRoutePolicy(contractVersion: 0), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: preferred
		)
		XCTAssertNil(missingPolicyVersion.validated(appID: "app-one", tenantID: nil))
		var invalidCommonTenantBackup = services
		invalidCommonTenantBackup["tenant_api"] = .init(
			preferred: ["https://tenant-primary.example.com"], backups: ["https://common-cf.example.net"],
			preferredSource: "app_preferred", backupSource: "common_platform_backup"
		)
		let invalidCommonUnsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
			services: invalidCommonTenantBackup, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com",
			preferredEndpoints: invalidCommonTenantBackup.mapValues(\.preferred)
		)
		let invalidCommon = IMRuntimeRouteSnapshot(
			contractVersion: invalidCommonUnsigned.contractVersion, appID: invalidCommonUnsigned.appID,
			tenantID: nil, revision: invalidCommonUnsigned.revision, source: invalidCommonUnsigned.source,
			status: invalidCommonUnsigned.status,
			configHash: try XCTUnwrap(invalidCommonUnsigned.recomputedConfigHash),
			services: invalidCommonTenantBackup, policy: invalidCommonUnsigned.policy,
			hashScope: .appBootstrap, bootstrapHost: invalidCommonUnsigned.bootstrapHost,
			preferredEndpoints: invalidCommonUnsigned.preferredEndpoints
		)
		XCTAssertNil(invalidCommon.validated(appID: "app-one", tenantID: nil))
		var changedRoutes = services
		changedRoutes["tenant_api"] = .init(
			preferred: ["https://changed.example.com"], backups: [],
			preferredSource: "app_preferred", backupSource: "common_platform_backup"
		)
		let changed = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: digest,
			services: changedRoutes, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: changedRoutes.mapValues(\.preferred)
		)
		XCTAssertNotEqual(changed.recomputedConfigHash, digest)
	}

	func testPackedRevisionLayoutFitsExactlyInJavaScriptSafeInteger() {
		let commonMax: UInt64 = (1 << 16) - 1
		let appMax: UInt64 = (1 << 18) - 1
		let tenantMax: UInt64 = (1 << 19) - 1
		let appPrelogin = ((commonMax << 18) | appMax) << 19
		let tenantPublished = appPrelogin | tenantMax
		XCTAssertEqual(appPrelogin & tenantMax, 0)
		XCTAssertEqual(tenantPublished, 9_007_199_254_740_991)
		XCTAssertNotNil(snapshot(revision: tenantPublished).validated(appID: "app-one", tenantID: "tenant-a"))
	}

    func testFiveSecondNetworkOnlyBoundaryAndFailClosedIdentityTLS() {
        let first = IMRuntimeRouteRequestWindow().recording(.connect, nowMS: 1_000)
        XCTAssertEqual(first.recording(.timeout, nowMS: 5_999).tier, .preferred)
        XCTAssertEqual(first.recording(.timeout, nowMS: 6_000).tier, .backup)
        for failure in [IMRuntimeRouteFailure.offline, .captivePortal, .authentication, .business, .cancelled,
                        .backgrounded, .websocketAuth, .websocketPreAckBusiness, .http(401), .http(403)] {
            XCTAssertEqual(failure.decision, .noFailover)
        }
		for failure in [IMRuntimeRouteFailure.tlsCertificate, .hostMismatch, .appIDMismatch, .tenantMismatch,
		                .configHashMismatch, .revisionRejected, .contractMismatch] {
            XCTAssertEqual(failure.decision, .failClosed)
        }
        for status in [502, 503, 504] { XCTAssertEqual(IMRuntimeRouteFailure.http(status).decision, .qualifiedNetwork) }
    }

	func testAppBootstrapHostConfigurationKeepsLegacyPairCompatibilityAndLeavesApp2Unconfigured() throws {
		let app1 = IMAppBootstrapHostConfigurationLoader.load(
			info: [
				"WXTAppBootstrapBaseURL": "https://bootstrap.wdatongcf.com",
				"WXTAppBootstrapBackupBaseURL": "",
			],
			appID: "jianhuitong-ios"
		)
		guard case .configured(let app1Configuration) = app1 else {
			return XCTFail("App1 must have a configured ordered Bootstrap candidate set")
		}
		XCTAssertEqual(app1Configuration.primary.host, "bootstrap.wdatongcf.com")
		XCTAssertNil(app1Configuration.backup)

		XCTAssertEqual(
			IMAppBootstrapHostConfigurationLoader.load(
				info: ["WXTAppBootstrapBaseURL": "", "WXTAppBootstrapBackupBaseURL": ""],
				appID: "WXT_UNCONFIGURED_APP2"
			),
			.unconfigured
		)
		XCTAssertEqual(
			IMAppBootstrapHostConfigurationLoader.load(
				info: [
					"WXTAppBootstrapBaseURL": "",
					"WXTAppBootstrapBackupBaseURL": "https://backup.example.test",
				],
				appID: "app-one"
			),
			.blocked
		)
		XCTAssertEqual(
			IMAppBootstrapHostConfigurationLoader.load(
				info: [
					"WXTAppBootstrapBaseURL": "https://same.example.test",
					"WXTAppBootstrapBackupBaseURL": "https://same.example.test",
				],
				appID: "app-one"
			),
			.blocked
		)
	}

	func testAppBootstrapHostConfigurationAcceptsUpToFourPackagedOrigins() throws {
		let frozen = [
				"https://bootstrap.wdatong.com",
				"https://bootstrap.wdatongcf.com",
		]
		for values in [
			[frozen[0]],
			frozen,
			frozen + ["https://third.example.com"],
			frozen + ["https://third.example.com", "https://fourth.example.com"],
		] {
			let plan = IMAppBootstrapHostConfigurationLoader.load(
				info: ["WXTAppBootstrapBaseURLs": values],
				appID: "jianhuitong-ios"
			)
			guard case .configured(let configuration) = plan else {
				return XCTFail("ordered configuration with \(values.count) entries must be accepted")
			}
			XCTAssertEqual(configuration.orderedBases.map(\.absoluteString), values)
		}

		let formal = IMAppBootstrapHostConfigurationLoader.load(
			info: [
				"WXTAppBootstrapBaseURLs": frozen,
				"WXTAppBootstrapBaseURL": frozen[0],
				"WXTAppBootstrapBackupBaseURL": frozen[1],
			],
			appID: "jianhuitong-ios"
		)
		guard case .configured(let formalConfiguration) = formal else {
			return XCTFail("formal App1 bootstrap list must be configured")
		}
		XCTAssertEqual(formalConfiguration.orderedBases.map(\.absoluteString), frozen)

		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		let backendDefaultThird = [
			"https://bootstrap-one.example.com",
			"https://bootstrap-two.example.com",
			"https://bootstrap-three.example.com",
		]
		let relaxedLegacyOrder = IMAppBootstrapHostConfigurationLoader.load(
			info: [
				"WXTAppBootstrapBaseURLs": backendDefaultThird,
				"WXTAppBootstrapBaseURL": backendDefaultThird[2],
				"WXTAppBootstrapBackupBaseURL": backendDefaultThird[0],
			],
			appID: "jianhuitong-ios"
		)
		guard case .configured(let relaxedConfiguration) = relaxedLegacyOrder else {
			return XCTFail("legacy primary/backup must not force the ordered candidate positions")
		}
		XCTAssertEqual(relaxedConfiguration.orderedBases.map(\.absoluteString), backendDefaultThird)
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

		for invalid in [
			frozen + [
				"https://third.example.com", "https://fourth.example.com", "https://fifth.example.com",
			],
			[frozen[0], "HTTPS://BOOTSTRAP.WDATONG.COM:443/"],
			["https://127.0.0.1"],
			["https://single-label"],
			["https://placeholder.example.com"],
			["https://bootstrap.example.invalid"],
			["https://bootstrap.example.com:8443"],
			["https://bootstrap.example.com/path"],
			["https://bootstrap.example.com/%2e%2e/escape"],
			["https://bootstrap.example.com?query=value"],
			["https://bootstrap.example.com#fragment"],
			["https://user@bootstrap.example.com"],
		] {
			XCTAssertEqual(
				IMAppBootstrapHostConfigurationLoader.load(
					info: ["WXTAppBootstrapBaseURLs": invalid],
					appID: "jianhuitong-ios"
				),
				.blocked,
				"invalid=\(invalid)"
			)
		}
	}

	func testPackagedApp1BootstrapOrderMatchesTheFrozenTwoOrigins() throws {
		let expected = [
				"https://bootstrap.wdatong.com",
				"https://bootstrap.wdatongcf.com",
			]
		let plan = IMAppBootstrapHostConfigurationLoader.load(
			info: try XCTUnwrap(Bundle.main.infoDictionary),
			appID: "jianhuitong-ios"
		)
		guard case .configured(let configuration) = plan else {
			return XCTFail("packaged App1 bootstrap list must be configured")
		}
		XCTAssertEqual(configuration.orderedBases.map(\.absoluteString), expected)
	}

	func testAppBootstrapAnyOriginPolicyUsesThreeSecondPerOriginAndTwentySevenSecondMaximumBudget() {
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.perOriginFailureBudgetMS, 3_000)
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(
			[
				IMRuntimeRouteFailure.dns, .connect, .timeout, .reset, .tlsCertificate,
				.hostMismatch, .appIDMismatch, .configHashMismatch, .contractMismatch,
			].map(IMAppBootstrapFailoverPolicy.decision),
			Array(repeating: .qualifiedNetwork, count: 9)
		)
		for status in [100, 200, 301, 400, 401, 403, 404, 408, 429, 500, 502, 503, 504] {
			XCTAssertEqual(IMAppBootstrapFailoverPolicy.decision(for: .http(status)), .qualifiedNetwork)
		}
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		for failure in [
			IMRuntimeRouteFailure.offline, .captivePortal, .authentication, .business, .cancelled,
			.backgrounded, .websocketAuth, .websocketPreAckBusiness,
		] {
			XCTAssertEqual(IMAppBootstrapFailoverPolicy.decision(for: failure), .noFailover)
		}
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.decision(for: .revisionRejected), .failClosed)
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 1), 3_000)
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 4), 12_000)
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 5), 15_000)
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 9), 27_000)
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 10), 27_000)
	}

	func testAppBootstrapQuickQualifiedFailureImmediatelyTriesSecondOriginExactlyOnce() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let clock = AppBootstrapTestClock(nowMS: 10_000)
		let response = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!),
			isHTTPResponse: true,
			statusCode: 200
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.cannotFindHost, advanceMS: 5),
			.response(response, advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			primary: primary, backup: backup, transport: transport, clock: clock,
			networkReachable: { true }
		)

		let bootstrap = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(bootstrap.bootstrapHost, primary.host)
		XCTAssertEqual(client.configuredAppBootstrapPrimaryBase, primary)
		XCTAssertEqual(client.configuredAppBootstrapBackupBase, backup)
		XCTAssertEqual(client.configuredAppBootstrapBases, [primary, backup])
		XCTAssertEqual(transport.requests.map(\.host), [primary.host, backup.host])
		XCTAssertEqual(transport.requests.map(\.atMS), [10_000, 10_005])
		XCTAssertEqual(
			transport.requests.map(\.path),
			Array(
				repeating: "/.well-known/wenxintong-app.json?app_id=app-one",
				count: 2
			)
		)
	}

	func testAppBootstrapCandidateOneTwo404ThenCandidateThreeSelfHostSucceeds() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...4).map { URL(string: "https://bootstrap-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 60_000)
		let response = HTTPTransportResult(
			// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: bases[2].host!),
			// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
			isHTTPResponse: true,
			statusCode: 200
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
			.response(.init(data: Data(), isHTTPResponse: true, statusCode: 404), advanceMS: 3_000),
			.response(.init(data: Data(), isHTTPResponse: true, statusCode: 404), advanceMS: 3_000),
			.response(response, advanceMS: 0),
			// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let bootstrap = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(
			client.configuredAppBootstrapBases,
			[bases[2], bases[0], bases[1], bases[3]]
		)
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(bootstrap.bootstrapHost, bases[2].host)
		XCTAssertEqual(transport.requests.map(\.host), Array(bases.prefix(3)).map(\.host))
		XCTAssertEqual(transport.requests.map(\.atMS), [60_000, 63_000, 66_000])
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(
			transport.requests.map(\.path),
			Array(repeating: "/.well-known/wenxintong-app.json?app_id=app-one", count: 3)
		)
	}

	func testAppBootstrapRequiresExactHTTP200AndAdvancesPast201And206() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...3).map { URL(string: "https://bootstrap-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 60_000)
		let data = try appBootstrapEnvelopeData(
			appID: "app-one",
			bootstrapHost: bases[0].host!,
			domains: [bases[0].host!]
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.response(.init(data: data, isHTTPResponse: true, statusCode: 201), advanceMS: 1),
			.response(.init(data: data, isHTTPResponse: true, statusCode: 206), advanceMS: 1),
			.response(.init(data: data, isHTTPResponse: true, statusCode: 200), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.bootstrapHost, bases[0].host)
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	func testPackagedCarrierAcceptsActiveDomainsThatExcludeItsServingHostAndMergesStableOrder() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let packaged = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let active = ["active-one.example.com", "active-two.example.com"]
		let clock = AppBootstrapTestClock(nowMS: 62_000)
		let response = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(
				appID: "app-one", bootstrapHost: active[0], domains: active
			),
			isHTTPResponse: true,
			statusCode: 200
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [.response(response, advanceMS: 0)])
		let client = makeAppBootstrapClient(
			bases: packaged,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let bootstrap = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(bootstrap.bootstrapHost, active[0])
		XCTAssertEqual(transport.requests.map(\.host), [packaged[0].host])
		XCTAssertEqual(
			client.configuredAppBootstrapBases.map(\.host),
			active + packaged.compactMap(\.host)
		)
	}

	func testLegacyPayloadWithoutDomainsStillAcceptsAnyPackagedBootstrapHost() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let packaged = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 63_000)
		let data = try appBootstrapEnvelopeData(
			appID: "app-one",
			bootstrapHost: packaged[1].host!,
			domains: []
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.response(.init(data: Data(), isHTTPResponse: true, statusCode: 404), advanceMS: 1),
			.response(.init(data: data, isHTTPResponse: true, statusCode: 200), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: packaged,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.bootstrapHost, packaged[1].host)
		XCTAssertEqual(client.configuredAppBootstrapBases, [packaged[1], packaged[0]])
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

	func testFourPackagedFailuresUseAtMostTwelveSecondsAndFiveOriginsAreRejected() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...5).map { URL(string: "https://bootstrap-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 70_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: Array(repeating: .failure(.timedOut, advanceMS: 3_000), count: 4)
		)
		let fourOriginClient = makeAppBootstrapClient(
			bases: Array(bases.prefix(4)),
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)
		do {
			_ = try await fourOriginClient.appBootstrap(appID: "app-one", forceRefresh: true)
			XCTFail("four qualified failures without last-good must fail")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), Array(bases.prefix(4)).map(\.host))
		XCTAssertEqual(Set(transport.requests.map(\.host)).count, 4)
		XCTAssertEqual(clock.now(), 82_000)

		let fiveClock = AppBootstrapTestClock(nowMS: 90_000)
		let fiveTransport = AppBootstrapFailoverTransport(clock: fiveClock, outcomes: [])
		let fiveOriginClient = makeAppBootstrapClient(
			bases: bases,
			transport: fiveTransport,
			clock: fiveClock,
			networkReachable: { true }
		)
		do {
			_ = try await fiveOriginClient.appBootstrap(appID: "app-one", forceRefresh: true)
			XCTFail("five packaged Bootstrap origins must be rejected before transport")
		} catch {}
		XCTAssertTrue(fiveTransport.requests.isEmpty)

		let platform = IMAppBootstrapHostConfiguration(
			orderedBases: (1...5).map { URL(string: "https://active-\($0).example.com")! }
		)
		let packaged = IMAppBootstrapHostConfiguration(
			packagedOrderedBases: Array(bases.prefix(4))
		)
		XCTAssertEqual(
			IMAPIClient.mergedBootstrapHostConfiguration(
				platformBases: try XCTUnwrap(platform).orderedBases,
				packaged: try XCTUnwrap(packaged)
			)?.orderedBases.count,
			9
		)
	}

	func testAppBootstrapContinuesAfterCandidateFailureEvenWhenReachabilityTurnsOffline() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let clock = AppBootstrapTestClock(nowMS: 20_000)
		let success = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!),
			isHTTPResponse: true,
			statusCode: 200
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.cannotConnectToHost, advanceMS: 3_000),
			.response(success, advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			primary: primary, backup: backup, transport: transport, clock: clock,
			networkReachable: { clock.now() < 23_000 }
		)

		_ = try await client.appBootstrap(appID: "app-one", forceRefresh: true)
		XCTAssertEqual(transport.requests.map(\.host), [primary.host, backup.host])
		XCTAssertEqual(clock.now(), 23_000)
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	func testAppBootstrapCandidateLevelFailuresTryNextPinnedOrigin() async throws {
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let validData = try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!)
		let backupSuccess = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!),
			isHTTPResponse: true,
			statusCode: 200
		)
		let cases: [[AppBootstrapFailoverTransport.Outcome]] = [
			[.response(.init(data: Data(), isHTTPResponse: true, statusCode: 404), advanceMS: 1)],
			[.response(.init(data: Data(), isHTTPResponse: true, statusCode: 503), advanceMS: 3_000)],
			[.failure(.serverCertificateUntrusted, advanceMS: 3_000)],
			[.failure(.notConnectedToInternet, advanceMS: 3_000)],
			[.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one",
					bootstrapHost: "wrong-bootstrap.example.test",
					domains: [primary.host!]
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 3_000)],
			[.response(.init(
				data: try appBootstrapEnvelopeData(appID: "other-app", bootstrapHost: primary.host!),
				isHTTPResponse: true,
				statusCode: 200
			), advanceMS: 3_000)],
			[.response(.init(
				data: validData, isHTTPResponse: true, statusCode: 200,
				responseURL: URL(string: "https://redirected.example.test/.well-known/wenxintong-app.json")!
			), advanceMS: 3_000)],
		]
		for outcomes in cases {
			IMAppBootstrapLastGoodStore.clearAll()
			let clock = AppBootstrapTestClock(nowMS: 30_000)
			let transport = AppBootstrapFailoverTransport(
				clock: clock,
				outcomes: outcomes + [.response(backupSuccess, advanceMS: 0)]
			)
			let client = makeAppBootstrapClient(
				primary: primary, backup: backup, transport: transport, clock: clock,
				networkReachable: { true }
			)

			let bootstrap = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

			XCTAssertEqual(bootstrap.bootstrapHost, primary.host)
			XCTAssertEqual(transport.requests.map(\.host), [primary.host, backup.host])
		}
		IMAppBootstrapLastGoodStore.clearAll()
	}

	func testAppBootstrapBusinessFailuresAdvanceToNextOrigin() async throws {
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let success = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!),
			isHTTPResponse: true,
			statusCode: 200
		)
		let cases: [AppBootstrapFailoverTransport.Outcome] = [
			.response(.init(
				data: Data(#"{"ok":false,"error":{"code":"app_disabled","message":"disabled"}}"#.utf8),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 3_000),
			.response(.init(
				data: Data(#"{"ok":false,"error":{"code":"prelogin_bootstrap_signature_invalid","message":"signature rejected"}}"#.utf8),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 3_000),
		]
		for failure in cases {
			IMAppBootstrapLastGoodStore.clearAll()
			let clock = AppBootstrapTestClock(nowMS: 30_000)
			let transport = AppBootstrapFailoverTransport(
				clock: clock,
				outcomes: [failure, .response(success, advanceMS: 0)]
			)
			let client = makeAppBootstrapClient(
				primary: primary, backup: backup, transport: transport, clock: clock,
				networkReachable: { true }
			)
			_ = try await client.appBootstrap(appID: "app-one", forceRefresh: true)
			XCTAssertEqual(transport.requests.map(\.host), [primary.host, backup.host])
		}
		IMAppBootstrapLastGoodStore.clearAll()
	}

	func testCrossHostRevisionRollbackAdvancesUntilNewerRevisionSucceeds() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...3).map { URL(string: "https://carrier-\($0).example.com")! }
		let storeDefaults = UserDefaults(suiteName: "AppBootstrapRevision.\(UUID().uuidString)")!
		let routeStore = IMRuntimeRouteStore(defaults: storeDefaults)
		let seed = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: bases[0].host!, revision: 10
		)
		XCTAssertEqual(routeStore.apply(seed.runtimeRouteSnapshot, appID: "app-one", tenantID: nil), .applied)
		let clock = AppBootstrapTestClock(nowMS: 32_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.dnsLookupFailed, advanceMS: 1),
			.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one", bootstrapHost: bases[0].host!, revision: 9
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 1),
			.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one", bootstrapHost: bases[0].host!, revision: 11
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true },
			runtimeRouteStore: routeStore
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.routeRevision, 11)
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
	}

	func testCrossHostEqualRevisionHashConflictAdvancesUntilNewerRevisionSucceeds() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...3).map { URL(string: "https://carrier-\($0).example.com")! }
		let storeDefaults = UserDefaults(suiteName: "AppBootstrapConflict.\(UUID().uuidString)")!
		let routeStore = IMRuntimeRouteStore(defaults: storeDefaults)
		let seed = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: bases[0].host!, revision: 20
		)
		XCTAssertEqual(routeStore.apply(seed.runtimeRouteSnapshot, appID: "app-one", tenantID: nil), .applied)
		let clock = AppBootstrapTestClock(nowMS: 34_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.cannotConnectToHost, advanceMS: 1),
			.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one",
					bootstrapHost: bases[0].host!,
					revision: 20,
					platformEndpoint: "https://platform-conflict.example.com"
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 1),
			.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one", bootstrapHost: bases[0].host!, revision: 21
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true },
			runtimeRouteStore: routeStore
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.routeRevision, 21)
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
	}

	func testEmptyActiveDomainListKeepsOnlyPackagedCandidates() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 36_000)
		let data = try appBootstrapEnvelopeData(
			appID: "app-one", bootstrapHost: "", domains: []
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.response(.init(data: data, isHTTPResponse: true, statusCode: 200), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.domains, [])
		XCTAssertEqual(client.configuredAppBootstrapBases, bases)
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

	func testAppBootstrapCancellationPropagatesWithoutTryingAnotherOrigin() async throws {
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let clock = AppBootstrapTestClock(nowMS: 35_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [.failure(.cancelled, advanceMS: 0)]
		)
		let client = makeAppBootstrapClient(
			primary: primary,
			backup: backup,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one", forceRefresh: true)
			XCTFail("cancellation must propagate")
		} catch let error as URLError {
			XCTAssertEqual(error.code, .cancelled)
		}
		XCTAssertEqual(transport.requests.map(\.host), [primary.host])
	}

	func testColdLaunchAlwaysTriesPrimaryBeforeUsingVerifiedLastGoodWithoutBackup() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let lastGood = try appBootstrapFixture(appID: "app-one", bootstrapHost: primary.host!)
		IMAppBootstrapLastGoodStore.save(lastGood, appID: "app-one")
		let clock = AppBootstrapTestClock(nowMS: 40_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.dnsLookupFailed, advanceMS: 5),
		])
		let client = makeAppBootstrapClient(
			primary: primary, backup: nil, transport: transport, clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one")

		XCTAssertEqual(resolved.configHash, lastGood.configHash)
		XCTAssertEqual(transport.requests.map(\.host), [primary.host])
	}

	func testAllQualifiedOriginsFailThenValidatedLastGoodIsRestored() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...4).map { URL(string: "https://bootstrap-\($0).example.com")! }
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		let lastGood = try appBootstrapFixture(appID: "app-one", bootstrapHost: bases[2].host!)
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		IMAppBootstrapLastGoodStore.save(lastGood, appID: "app-one")
		let clock = AppBootstrapTestClock(nowMS: 45_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [
				.failure(.dnsLookupFailed, advanceMS: 3_000),
				.failure(.cannotConnectToHost, advanceMS: 3_000),
				.failure(.networkConnectionLost, advanceMS: 3_000),
				.failure(.timedOut, advanceMS: 3_000),
			]
		)
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one")

		XCTAssertEqual(resolved.configHash, lastGood.configHash)
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
		XCTAssertEqual(clock.now(), 57_000)
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	func testLastGoodCacheIsIsolatedByServingHostAndAppID() throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let first = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: "active.example.com", revision: 30
		)
		let second = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: "active.example.com", revision: 31
		)
		IMAppBootstrapLastGoodStore.save(
			first, appID: "app-one", servingHost: "carrier-one.example.com"
		)
		IMAppBootstrapLastGoodStore.save(
			second, appID: "app-one", servingHost: "carrier-two.example.com"
		)

		XCTAssertEqual(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", servingHosts: ["carrier-one.example.com"]
			).map(\.bootstrap.routeRevision),
			[30]
		)
		XCTAssertEqual(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", servingHosts: ["carrier-two.example.com"]
			).map(\.bootstrap.routeRevision),
			[31]
		)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "other-app", servingHosts: ["carrier-one.example.com", "carrier-two.example.com"]
			).isEmpty
		)
	}

	func testLastGoodCacheRequiresExactEnvironmentIncludingEmptyScopeAndLegacyV2() throws {
		let defaults = UserDefaults(suiteName: "AppBootstrapEnvironment.\(UUID().uuidString)")!
		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		defer { IMAppBootstrapLastGoodStore.clearAll(defaults: defaults) }
		let host = "carrier-one.example.com"
		let scoped: [(environment: String, revision: UInt64)] = [
			("", 41), ("production", 42), ("staging", 43),
		]
		for item in scoped {
			let bootstrap = try appBootstrapFixture(
				appID: "app-one",
				bootstrapHost: host,
				revision: item.revision,
				environment: item.environment.isEmpty ? nil : item.environment
			)
			IMAppBootstrapLastGoodStore.save(
				bootstrap,
				appID: "app-one",
				environment: item.environment,
				servingHost: host,
				defaults: defaults
			)
		}

		for item in scoped {
			XCTAssertEqual(
				IMAppBootstrapLastGoodStore.snapshots(
					appID: "app-one",
					environment: item.environment,
					servingHosts: [host],
					defaults: defaults
				).map(\.bootstrap.routeRevision),
				[item.revision]
			)
		}

		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		let legacy = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: host, revision: 44, environment: "production"
		)
		try writeLegacyV2AppBootstrapCache(
			legacy, environment: "production", defaults: defaults
		)
		XCTAssertEqual(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "production", defaults: defaults
			).map(\.bootstrap.routeRevision),
			[44]
		)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "", defaults: defaults
			).isEmpty
		)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "staging", defaults: defaults
			).isEmpty
		)

		let mismatched = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: host, revision: 45, environment: "production"
		)
		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		IMAppBootstrapLastGoodStore.save(
			mismatched,
			appID: "app-one",
			environment: "",
			servingHost: host,
			defaults: defaults
		)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "production", defaults: defaults
			).isEmpty,
			"an explicit empty v3 scope must not be replaced by the payload environment"
		)

		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		try writeLegacyV2AppBootstrapCache(mismatched, environment: "", defaults: defaults)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "production", defaults: defaults
			).isEmpty,
			"an explicit empty v2 scope must not be replaced by the payload environment"
		)

		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		try writeLegacyV1AppBootstrapCache(mismatched, defaults: defaults)
		XCTAssertEqual(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "production", defaults: defaults
			).map(\.bootstrap.routeRevision),
			[45],
			"v1 has no environment field and may use its payload environment for migration"
		)
	}

	func testExplicitEmptyCacheScopeWithProductionPayloadCannotRestoreAfterLiveFailure() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let base = URL(string: "https://carrier-one.example.com")!
		let mismatched = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: base.host!, revision: 46, environment: "production"
		)
		IMAppBootstrapLastGoodStore.save(
			mismatched,
			appID: "app-one",
			environment: "",
			servingHost: base.host
		)
		try writeLegacyV2AppBootstrapCache(mismatched, environment: "", defaults: .standard)
		let clock = AppBootstrapTestClock(nowMS: 48_500)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [.failure(.dnsLookupFailed, advanceMS: 1)]
		)
		let client = makeAppBootstrapClient(
			bases: [base], transport: transport, clock: clock, networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one")
			XCTFail("scope/payload environment mismatch must not restore last-good")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), [base.host])
	}

	func testSameHostSameRevisionLegacyHashConflictBlocksLastGoodFallback() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let base = URL(string: "https://carrier-one.example.com")!
		let current = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: base.host!, revision: 50
		)
		let conflicting = try appBootstrapFixture(
			appID: "app-one",
			bootstrapHost: base.host!,
			revision: 50,
			platformEndpoint: "https://platform-conflict.example.com"
		)
		IMAppBootstrapLastGoodStore.save(
			current, appID: "app-one", servingHost: base.host
		)
		try writeLegacyV2AppBootstrapCache(conflicting, environment: "", defaults: .standard)
		let clock = AppBootstrapTestClock(nowMS: 49_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [.failure(.dnsLookupFailed, advanceMS: 1)]
		)
		let client = makeAppBootstrapClient(
			bases: [base],
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one")
			XCTFail("same revision with different hashes must fail closed")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), [base.host])
	}

	func testSameHostSameRevisionSameHashAcrossV3AndLegacyV2CanFallback() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let base = URL(string: "https://carrier-one.example.com")!
		let cached = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: base.host!, revision: 51
		)
		IMAppBootstrapLastGoodStore.save(
			cached, appID: "app-one", servingHost: base.host
		)
		try writeLegacyV2AppBootstrapCache(cached, environment: "", defaults: .standard)
		let clock = AppBootstrapTestClock(nowMS: 50_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [.failure(.dnsLookupFailed, advanceMS: 1)]
		)
		let client = makeAppBootstrapClient(
			bases: [base],
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one")

		XCTAssertEqual(resolved.routeRevision, 51)
		XCTAssertEqual(resolved.configHash, cached.configHash)
	}

	func testExpiredHigherRevisionPreventsFallbackToFreshLowerRevision() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let now = Date()
		let lower = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: bases[0].host!, revision: 30, ttlSeconds: 300
		)
		let higher = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: bases[0].host!, revision: 31, ttlSeconds: 30
		)
		IMAppBootstrapLastGoodStore.save(
			lower, appID: "app-one", servingHost: bases[0].host, now: now
		)
		IMAppBootstrapLastGoodStore.save(
			higher, appID: "app-one", servingHost: bases[1].host,
			now: now.addingTimeInterval(-60)
		)
		let clock = AppBootstrapTestClock(nowMS: 46_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.dnsLookupFailed, advanceMS: 1),
			.failure(.cannotConnectToHost, advanceMS: 1),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one")
			XCTFail("an expired higher high-water revision must block a fresh lower fallback")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
	}

	func testColdStartRestoresActiveOriginsAheadOfPackagedCarriers() throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let packaged = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let active = ["active-one.example.com", "active-two.example.com"]
		let appID = IMAPIContext.canonicalIOSAppID
		let cached = try appBootstrapFixture(
			appID: appID,
			bootstrapHost: active[0],
			domains: active,
			revision: 40
		)
		IMAppBootstrapLastGoodStore.save(
			cached,
			appID: appID,
			environment: IMAPIClient.configuredAppBootstrapEnvironment(),
			servingHost: packaged[0].host
		)
		let clock = AppBootstrapTestClock(nowMS: 48_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [])

		let client = makeAppBootstrapClient(
			bases: packaged,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		XCTAssertEqual(
			client.configuredAppBootstrapBases.map(\.host),
			active + packaged.compactMap(\.host)
		)
		XCTAssertTrue(transport.requests.isEmpty)
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

	func testNetworkFailureWithInvalidLastGoodAndNoBackupFailsClosed() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let valid = try appBootstrapFixture(appID: "app-one", bootstrapHost: primary.host!)
		let invalid = RemoteAppBootstrap(
			appID: valid.appID, displayName: valid.displayName, platform: valid.platform, status: valid.status,
			bootstrapHost: valid.bootstrapHost, appDomain: valid.appDomain, configVersion: valid.configVersion,
			ttlSeconds: valid.ttlSeconds, directory: valid.directory, legal: valid.legal,
			configHash: String(repeating: "f", count: 64), contractVersion: valid.contractVersion,
			routeRevision: valid.routeRevision, routeSource: valid.routeSource, routeStatus: valid.routeStatus,
			routes: valid.routes, preferredEndpoints: valid.preferredEndpoints, routingPolicy: valid.routingPolicy
		)
		IMAppBootstrapLastGoodStore.save(invalid, appID: "app-one")
		let clock = AppBootstrapTestClock(nowMS: 50_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.cannotFindHost, advanceMS: 5),
		])
		let client = makeAppBootstrapClient(
			primary: primary, backup: nil, transport: transport, clock: clock,
			networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one")
			XCTFail("an invalid last-good Bootstrap contract must fail closed")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), [primary.host])
	}

	private func makeAppBootstrapClient(
		primary: URL,
		backup: URL?,
		transport: HTTPTransport,
		clock: AppBootstrapTestClock,
		networkReachable: @escaping @MainActor @Sendable () -> Bool
	) -> IMAPIClient {
		makeAppBootstrapClient(
			bases: [primary] + (backup.map { [$0] } ?? []),
			transport: transport,
			clock: clock,
			networkReachable: networkReachable
		)
	}

	private func makeAppBootstrapClient(
		bases: [URL],
		transport: HTTPTransport,
		clock: AppBootstrapTestClock,
		networkReachable: @escaping @MainActor @Sendable () -> Bool,
		runtimeRouteStore: IMRuntimeRouteStore? = nil
	) -> IMAPIClient {
		let defaults = UserDefaults(suiteName: "AppBootstrapRuntimeRoutes.\(UUID().uuidString)")!
		return IMAPIClient(
			platformBase: IMAPIClient.releasePlaceholderPlatformBase,
			tenantBase: URL(string: "https://tenant-seed.example.test")!,
			imBase: URL(string: "https://im-seed.example.test")!,
			bootstrapBases: bases,
			httpTransport: transport,
			runtimeRouteStore: runtimeRouteStore ?? IMRuntimeRouteStore(defaults: defaults),
			runtimeMonotonicNowMS: { clock.now() },
			runtimeSleep: { clock.advance(by: $0) },
			bootstrapNetworkReachable: networkReachable
		)
	}

	private func writeLegacyV2AppBootstrapCache(
		_ bootstrap: RemoteAppBootstrap,
		environment: String,
		defaults: UserDefaults,
		savedAt: Date = Date()
	) throws {
		let bootstrapObject = try JSONSerialization.jsonObject(
			with: JSONEncoder().encode(bootstrap)
		)
		let scopeKey = "\(environment)\u{0}\(bootstrap.appID)"
		let payload: [String: Any] = [
			scopeKey: [
				"bootstrap": bootstrapObject,
				"savedAt": savedAt.timeIntervalSince1970,
			],
		]
		defaults.set(
			try JSONSerialization.data(withJSONObject: payload),
			forKey: "im2.appBootstrap.lastGood.v2"
		)
	}

	private func writeLegacyV1AppBootstrapCache(
		_ bootstrap: RemoteAppBootstrap,
		defaults: UserDefaults,
		savedAt: Date = Date()
	) throws {
		let bootstrapObject = try JSONSerialization.jsonObject(
			with: JSONEncoder().encode(bootstrap)
		)
		let payload: [String: Any] = [
			bootstrap.appID: [
				"bootstrap": bootstrapObject,
				"savedAt": savedAt.timeIntervalSince1970,
			],
		]
		defaults.set(
			try JSONSerialization.data(withJSONObject: payload),
			forKey: "im2.appBootstrap.lastGood.v1"
		)
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	private func appBootstrapEnvelopeData(
		appID: String,
		bootstrapHost: String,
		domains: [String]? = nil,
		revision: UInt64 = 7,
		platformEndpoint: String = "https://platform-primary.example.com",
		environment: String? = nil
	) throws -> Data {
		let bootstrap = try appBootstrapFixture(
			appID: appID,
			bootstrapHost: bootstrapHost,
			domains: domains,
			revision: revision,
			platformEndpoint: platformEndpoint,
			environment: environment
		)
		let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bootstrap))
		return try JSONSerialization.data(withJSONObject: ["ok": true, "data": object])
	}

	private func appBootstrapFixture(
		appID: String,
		bootstrapHost: String,
		domains: [String]? = nil,
		revision: UInt64 = 7,
		platformEndpoint: String = "https://platform-primary.example.com",
		ttlSeconds: Int = 300,
		environment: String? = nil
	) throws -> RemoteAppBootstrap {
		var services = appBootstrapServices()
		services[IMRuntimeRouteService.platformAPI.rawValue] = .init(
			preferred: [platformEndpoint],
			backups: ["https://platform-backup.example.com"],
			status: "ready",
			preferredSource: "app_preferred",
			backupSource: "common_platform_backup"
		)
		let preferred = services.mapValues(\.preferred)
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: appID, tenantID: nil, revision: revision,
			source: "app_bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
			services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: bootstrapHost, preferredEndpoints: preferred
		)
		let configHash = try XCTUnwrap(unsigned.recomputedConfigHash)
		return RemoteAppBootstrap(
			appID: appID, displayName: "App One", platform: "ios", status: "enabled",
			domains: domains ?? (bootstrapHost.isEmpty ? [] : [bootstrapHost]),
			bootstrapHost: bootstrapHost, appDomain: bootstrapHost, configVersion: "\(revision)",
			ttlSeconds: ttlSeconds,
			directory: .init(apiBaseURL: platformEndpoint), configHash: configHash,
			contractVersion: 2, routeRevision: revision, routeSource: "app_bootstrap", routeStatus: "ready",
			routes: services, preferredEndpoints: preferred, routingPolicy: IMRuntimeRoutePolicy(),
			environment: environment
		)
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

	func testSelectorPreservesTenantDeploymentAuthorityThenBackupOrderAndSources() throws {
		let base = snapshot()
		var services = base.services
		services[IMRuntimeRouteService.tenantAPI.rawValue] = .init(
			preferred: ["https://app-fixture-api.wenxintongim.com"],
			backups: ["https://cf-backup.fixture.example"],
			status: "ready",
			preferredSource: "tenant_deployment_authority",
			backupSource: "tenant_deployment_backup"
		)
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: base.appID, tenantID: base.tenantID, revision: 2,
			source: base.source, status: base.status, configHash: String(repeating: "0", count: 64),
			services: services, policy: base.policy
		)
		let routes = IMRuntimeRouteSnapshot(
			contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: unsigned.tenantID,
			revision: unsigned.revision, source: unsigned.source, status: unsigned.status,
			configHash: try XCTUnwrap(unsigned.recomputedConfigHash), services: services, policy: unsigned.policy
		)
		XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
		let selector = IMRuntimeRouteSelector(store: store)
		XCTAssertEqual(selector.endpoints(routes, service: .tenantAPI), [
			"https://app-fixture-api.wenxintongim.com", "https://cf-backup.fixture.example"
		])
		let tenantRoute = try XCTUnwrap(routes.services[IMRuntimeRouteService.tenantAPI.rawValue])
		XCTAssertEqual(tenantRoute.preferredSource, "tenant_deployment_authority")
		XCTAssertEqual(tenantRoute.backupSource, "tenant_deployment_backup")
	}

	func testOnlyThreeConsecutiveQualifiedColdLaunchesEnterRecovery() {
        let routes = snapshot(); XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
        let selector = IMRuntimeRouteSelector(store: store)
        let qualified = IMRuntimeColdLaunchAttempt(processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
                                                   backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000)
        selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
        selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
		selector.recordColdLaunch(.init(processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
		                                backgroundedOrCancelled: false, qualifiedFailureDurationMS: 4_999), snapshot: routes, service: .tenantAPI)
		XCTAssertEqual(selector.endpoints(routes, service: .tenantAPI).first, "https://tenant-primary.example.com")
		selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
		XCTAssertEqual(selector.endpoints(routes, service: .tenantAPI).first, "https://tenant-primary.example.com")
		selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
		selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
        XCTAssertEqual(IMRuntimeRouteSelector(store: IMRuntimeRouteStore(defaults: defaults)).endpoints(routes, service: .tenantAPI).first,
                       "https://tenant-backup.example.net")
        XCTAssertFalse(selector.recovery(routes, service: .imAPI).recovery)
    }

    func testStableSpacedHTTPAndAcknowledgedRealtimeFailback() {
        let routes = snapshot(); _ = store.apply(routes, appID: routes.appID, tenantID: routes.tenantID)
        let selector = IMRuntimeRouteSelector(store: store)
        let qualified = IMRuntimeColdLaunchAttempt(processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
                                                   backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000)
        for _ in 0..<3 { selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI) }
        selector.recordPreferredProbe(snapshot: routes, service: .tenantAPI, kind: .http, succeeded: true, stableMS: 30_000, nowMS: 100_000)
        selector.recordPreferredProbe(snapshot: routes, service: .tenantAPI, kind: .http, succeeded: true, stableMS: 30_000, nowMS: 129_999)
        XCTAssertTrue(selector.recovery(routes, service: .tenantAPI).recovery)
        selector.recordPreferredProbe(snapshot: routes, service: .tenantAPI, kind: .http, succeeded: true, stableMS: 30_000, nowMS: 130_000)
        XCTAssertFalse(selector.recovery(routes, service: .tenantAPI).recovery)
        for _ in 0..<3 { selector.recordColdLaunch(qualified, snapshot: routes, service: .imRealtime) }
        selector.recordPreferredProbe(snapshot: routes, service: .imRealtime, kind: .realtime, succeeded: true, stableMS: 30_000, nowMS: 200_000)
        XCTAssertTrue(selector.recovery(routes, service: .imRealtime).recovery)
        selector.recordPreferredProbe(snapshot: routes, service: .imRealtime, kind: .realtime, succeeded: true, stableMS: 30_000, nowMS: 230_000, connectAcknowledged: true)
        XCTAssertFalse(selector.recovery(routes, service: .imRealtime).recovery)
    }

	func testOnlyFourSelectorServicesAndAppLevelWebSocketOwnershipDedupe() {
        XCTAssertEqual(Set(snapshot().services.keys), Set(["platform_api", "tenant_api", "im_api", "im_realtime"]))
		XCTAssertFalse(snapshot().services.keys.contains("oss")); XCTAssertFalse(snapshot().services.keys.contains("turn"))
		let continuity = IMRuntimeWebSocketContinuity(); XCTAssertTrue(continuity.acquire("owner-a")); XCTAssertFalse(continuity.acquire("owner-b"))
		XCTAssertTrue(continuity.accept(messageID: "message-1")); XCTAssertFalse(continuity.accept(messageID: "message-1"))
		continuity.release("owner-a")
		XCTAssertTrue(continuity.acquire("owner-b"))
	}

	func testConcurrentStoresDoNotLoseRecoveryCountersAndLogoutDoesNotClearRoutes() async {
		let routes = snapshot()
		XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
		let attempt = IMRuntimeColdLaunchAttempt(
			processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
			backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000
		)
		let defaultsBox = RuntimeRoutesDefaultsBox(defaults)
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<24 {
				group.addTask {
					let selector = IMRuntimeRouteSelector(store: IMRuntimeRouteStore(defaults: defaultsBox.value))
					selector.recordColdLaunch(attempt, snapshot: routes, service: .tenantAPI)
				}
			}
		}
		let restarted = IMRuntimeRouteStore(defaults: defaults)
		XCTAssertEqual(
			restarted.record(appID: routes.appID, tenantID: routes.tenantID)
				.recoveryByService[IMRuntimeRouteService.tenantAPI.rawValue]?.consecutiveQualifiedColdLaunchFailures,
			24
		)
		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		XCTAssertEqual(restarted.record(appID: routes.appID, tenantID: routes.tenantID).current?.revision, 1)
	}
}

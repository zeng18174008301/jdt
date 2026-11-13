import Foundation
import CryptoKit
import XCTest
@testable import WenDaTong

extension AccessDiscoveryTests {
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

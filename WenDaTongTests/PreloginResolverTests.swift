import CryptoKit
import Foundation
import XCTest
@testable import WenDaTong

extension PreloginBootstrapTests {
    func testResolverUsesThreeSourcesAndChoosesAuthorityThenHighestVersion() async throws {
        let rootKey = Curve25519.Signing.PrivateKey()
        let artifactKey = Curve25519.Signing.PrivateKey()
        let scope = makeScope()
        let keyStateRaw = try makeSignedKeyState(
            rootKey: rootKey,
            artifactPublicKey: artifactKey.publicKey.rawRepresentation
        )
        let verifiedState = try PreloginTrust.verifyKeyState(
            raw: keyStateRaw,
            rootKeyID: "recovery-root-1",
            rootPublicKey: rootKey.publicKey.rawRepresentation,
            previousRecoveryGeneration: 0,
            previousHash: "",
            now: now
        )
        let seeds = [
            PreloginSeed(id: "primary", baseURL: URL(string: "https://one.example.test/config/")!),
            PreloginSeed(id: "account-backup", baseURL: URL(string: "https://two.example.test/config/")!),
            PreloginSeed(id: "cloud-backup", baseURL: URL(string: "https://three.example.test/config/")!)
        ]
        let low = try makeBundle(
            version: 7,
            platformHost: "api-old.example.test",
            seed: seeds[0],
            stateRaw: keyStateRaw,
            verifiedState: verifiedState,
            signingKey: artifactKey,
            scope: scope
        )
        let highTwo = try makeBundle(
            version: 8,
            platformHost: "api-new.example.test",
            seed: seeds[1],
            stateRaw: keyStateRaw,
            verifiedState: verifiedState,
            signingKey: artifactKey,
            scope: scope
        )
        let highThree = mirrorBundle(highTwo, from: seeds[1], to: seeds[2])
        for (seed, bundle) in zip(seeds, [low, highTwo, highThree]) {
            try verifyGeneratedBundle(
                seed: seed,
                bundle: bundle,
                configuration: PreloginBootstrapConfiguration(
                    seeds: seeds,
                    scope: scope,
                    rootKeyID: "recovery-root-1",
                    rootPublicKey: rootKey.publicKey.rawRepresentation,
                    artifactPublicKeys: [
                        "primary-2026": artifactKey.publicKey.rawRepresentation
                    ]
                )
            )
        }
        let mergedResponses = low.merging(highTwo) { _, rhs in rhs }
            .merging(highThree) { _, rhs in rhs }
        let fetcher = PreloginFakeFetcher(responses: mergedResponses)
        let store = PreloginMemoryStore()
        let fixedNow = now
        let resolver = PreloginBootstrapResolver(
            configuration: PreloginBootstrapConfiguration(
                seeds: seeds,
                scope: scope,
                rootKeyID: "recovery-root-1",
                rootPublicKey: rootKey.publicKey.rawRepresentation,
                artifactPublicKeys: ["primary-2026": artifactKey.publicKey.rawRepresentation]
            ),
            fetcher: fetcher,
            store: store,
            now: { fixedNow }
        )

        let selected: URL
        do {
            selected = try await resolver.resolvePlatformBase()
        } catch {
            let requestedKeys = await fetcher.requestedKeys
            XCTFail(
                "resolver error=\(error), requested=\(requestedKeys.sorted()), "
                    + "available=\(mergedResponses.keys.sorted())"
            )
            return
        }
        let contactedHosts = await fetcher.sourceHosts
        let checkpoint = await store.snapshotCheckpoint()

        XCTAssertEqual(selected.absoluteString, "https://api-new.example.test/v1")
        XCTAssertEqual(contactedHosts, Set(seeds.compactMap { $0.baseURL.host }))
        XCTAssertEqual(checkpoint?.fencingGeneration, 1)
        XCTAssertEqual(checkpoint?.configVersion, 8)
    }

    func testGeneratedResolverFixtureDocumentsVerifyEndToEnd() throws {
        let fixture = try makeResolverFixture()
        for seed in fixture.configuration.seeds {
            let prefix = sourceScopePrefix(seed, scope: fixture.configuration.scope)
            let rootPrefix = sourcePrefix(seed)
            let currentRaw = try XCTUnwrap(
                fixture.responses["\(prefix)current.json"]
            )
            let reference = try PreloginTrust.keyStateReference(
                currentRaw: currentRaw,
                scope: fixture.configuration.scope
            )
            let stateRaw = try XCTUnwrap(fixture.responses["\(rootPrefix)\(reference.key)"])
            let state = try PreloginTrust.verifyKeyState(
                raw: stateRaw,
                rootKeyID: fixture.configuration.rootKeyID,
                rootPublicKey: fixture.configuration.rootPublicKey,
                previousRecoveryGeneration: 0,
                previousHash: "",
                now: now
            )
            let current = try PreloginTrust.verifyCurrent(
                raw: currentRaw,
                scope: fixture.configuration.scope,
                keyState: state,
                publicKeys: fixture.configuration.artifactPublicKeys,
                now: now
            )
            let artifactRaw = try XCTUnwrap(
                fixture.responses["\(rootPrefix)\(current.pointer.payload.artifactKey)"]
            )
            let artifact = try PreloginTrust.verifyArtifact(
                raw: artifactRaw,
                scope: fixture.configuration.scope,
                keyState: state,
                publicKeys: fixture.configuration.artifactPublicKeys,
                now: now
            )
            try PreloginTrust.verifyPointerArtifactBinding(
                pointer: current,
                artifact: artifact
            )
        }
    }

    func testResolverIsBlockedWithoutExactlyThreeTrustedSources() async throws {
        let rootKey = Curve25519.Signing.PrivateKey()
        let artifactKey = Curve25519.Signing.PrivateKey()
        let fixedNow = now
        let resolver = PreloginBootstrapResolver(
            configuration: PreloginBootstrapConfiguration(
                seeds: [
                    PreloginSeed(
                        id: "only-one",
                        baseURL: URL(string: "https://one.example.test/config/")!
                    )
                ],
                scope: makeScope(),
                rootKeyID: "recovery-root-1",
                rootPublicKey: rootKey.publicKey.rawRepresentation,
                artifactPublicKeys: ["primary-2026": artifactKey.publicKey.rawRepresentation]
            ),
            fetcher: PreloginFakeFetcher(responses: [:]),
            store: PreloginMemoryStore(),
            now: { fixedNow }
        )

        do {
            _ = try await resolver.resolvePlatformBase()
            XCTFail("Expected fail-closed configuration gate")
        } catch {
            XCTAssertEqual(error as? PreloginBootstrapError, .configurationBlocked)
        }
    }

    func testFreshInstallWithThreeUnavailableSourcesFailsClosed() async throws {
        let rootKey = Curve25519.Signing.PrivateKey()
        let artifactKey = Curve25519.Signing.PrivateKey()
        let fixedNow = now
        let resolver = PreloginBootstrapResolver(
            configuration: PreloginBootstrapConfiguration(
                seeds: [
                    PreloginSeed(id: "one", baseURL: URL(string: "https://one.example.test/config/")!),
                    PreloginSeed(id: "two", baseURL: URL(string: "https://two.example.test/config/")!),
                    PreloginSeed(id: "three", baseURL: URL(string: "https://three.example.test/config/")!)
                ],
                scope: makeScope(),
                rootKeyID: "recovery-root-1",
                rootPublicKey: rootKey.publicKey.rawRepresentation,
                artifactPublicKeys: ["primary-2026": artifactKey.publicKey.rawRepresentation]
            ),
            fetcher: PreloginFakeFetcher(responses: [:]),
            store: PreloginMemoryStore(),
            now: { fixedNow }
        )

        do {
            _ = try await resolver.resolvePlatformBase()
            XCTFail("Expected fresh-install fail closed")
        } catch {
            XCTAssertEqual(error as? PreloginBootstrapError, .allSourcesUnavailable)
        }
    }

    func testLastGoodIsReverifiedBeforeOfflineUse() async throws {
        let fixture = try makeResolverFixture()
        let store = PreloginMemoryStore()
        let online = makeResolver(
            fixture: fixture,
            fetcher: PreloginFakeFetcher(responses: fixture.responses),
            store: store,
            now: now
        )
        let onlineURL = try await online.resolvePlatformBase()
        XCTAssertEqual(onlineURL.absoluteString, "https://api.example.test/v1")

        let offline = makeResolver(
            fixture: fixture,
            fetcher: PreloginFakeFetcher(responses: [:]),
            store: store,
            now: now.addingTimeInterval(60)
        )
        let offlineURL = try await offline.resolvePlatformBase()
        XCTAssertEqual(offlineURL.absoluteString, "https://api.example.test/v1")
    }

    func testTamperedLastGoodSignatureFailsClosed() async throws {
        let fixture = try makeResolverFixture()
        let store = PreloginMemoryStore()
        let online = makeResolver(
            fixture: fixture,
            fetcher: PreloginFakeFetcher(responses: fixture.responses),
            store: store,
            now: now
        )
        _ = try await online.resolvePlatformBase()

        let storedEnvelope = await store.snapshotEnvelope()
        let envelope = try XCTUnwrap(storedEnvelope)
        let artifact = try PreloginStrictJSON.decodeArtifact(envelope.artifact)
        let replacement = artifact.signature.first == "A" ? "B" : "A"
        let tamperedSignature = replacement + artifact.signature.dropFirst()
        let tamperedRaw = try PreloginStrictJSON.canonical(
            PreloginArtifact(
                payload: artifact.payload,
                signatureAlg: artifact.signatureAlg,
                signature: tamperedSignature
            )
        )
        await store.replaceEnvelope(
            PreloginLastGoodEnvelope(
                scopeHash: envelope.scopeHash,
                artifact: tamperedRaw,
                keyState: envelope.keyState,
                currentPointer: envelope.currentPointer,
                savedAt: envelope.savedAt
            )
        )

        let offline = makeResolver(
            fixture: fixture,
            fetcher: PreloginFakeFetcher(responses: [:]),
            store: store,
            now: now.addingTimeInterval(60)
        )
        do {
            _ = try await offline.resolvePlatformBase()
            XCTFail("Expected cached artifact signature re-verification")
        } catch {
            XCTAssertEqual(error as? PreloginBootstrapError, .signatureInvalid)
        }
    }

    func testExpiredLastGoodFailsClosed() async throws {
        let fixture = try makeResolverFixture()
        let store = PreloginMemoryStore()
        let online = makeResolver(
            fixture: fixture,
            fetcher: PreloginFakeFetcher(responses: fixture.responses),
            store: store,
            now: now
        )
        _ = try await online.resolvePlatformBase()

        let offline = makeResolver(
            fixture: fixture,
            fetcher: PreloginFakeFetcher(responses: [:]),
            store: store,
            now: ISO8601DateFormatter().date(from: "2026-07-24T13:06:00Z")!
        )
        do {
            _ = try await offline.resolvePlatformBase()
            XCTFail("Expected signed last-good expiry to fail closed")
        } catch {
            XCTAssertEqual(error as? PreloginBootstrapError, .expired)
        }
    }

    func testTrustedClockRollbackFailsClosedBeforeCacheUse() async throws {
        let fixture = try makeResolverFixture()
        let store = PreloginMemoryStore()
        let online = makeResolver(
            fixture: fixture,
            fetcher: PreloginFakeFetcher(responses: fixture.responses),
            store: store,
            now: now
        )
        _ = try await online.resolvePlatformBase()

        let rolledBack = makeResolver(
            fixture: fixture,
            fetcher: PreloginFakeFetcher(responses: [:]),
            store: store,
            now: ISO8601DateFormatter().date(from: "2026-07-24T12:20:00Z")!
        )
        do {
            _ = try await rolledBack.resolvePlatformBase()
            XCTFail("Expected trusted-clock rollback rejection")
        } catch {
            XCTAssertEqual(error as? PreloginBootstrapError, .clockRollback)
        }
    }

    func testRedirectPolicyRejectsCrossSourceAndSameSourceRedirects() {
        let original = URL(string: "https://one.example.test/config/current.json")!
        let crossSource = URLRequest(
            url: URL(string: "https://evil.example.test/config/current.json")!
        )
        let sameSource = URLRequest(
            url: URL(string: "https://one.example.test/other/current.json")!
        )

        XCTAssertNil(
            PreloginRedirectPolicy.requestToFollow(
                originalURL: original,
                proposedRequest: crossSource
            )
        )
        XCTAssertNil(
            PreloginRedirectPolicy.requestToFollow(
                originalURL: original,
                proposedRequest: sameSource
            )
        )
    }

    func testCurrentRejectsLowerFenceAndRevokedKey() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let lowerFenceState = makeVerifiedState(
            authorization: makeAuthorization(),
            payloadHash: String(repeating: "1", count: 64),
            currentFencingGeneration: 2
        )
        let lowerFenceCurrent = try makeCurrentRaw(
            fencingGeneration: 1,
            keyState: lowerFenceState,
            signingKey: signingKey
        )
        XCTAssertThrowsError(
            try PreloginTrust.verifyCurrent(
                raw: lowerFenceCurrent,
                scope: makeScope(),
                keyState: lowerFenceState,
                publicKeys: ["primary-2026": signingKey.publicKey.rawRepresentation],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .keyUnauthorized)
        }

        let revokedState = makeVerifiedState(
            authorization: makeAuthorization(status: "revoked"),
            payloadHash: String(repeating: "2", count: 64)
        )
        let revokedCurrent = try makeCurrentRaw(
            fencingGeneration: 1,
            keyState: revokedState,
            signingKey: signingKey
        )
        XCTAssertThrowsError(
            try PreloginTrust.verifyCurrent(
                raw: revokedCurrent,
                scope: makeScope(),
                keyState: revokedState,
                publicKeys: ["primary-2026": signingKey.publicKey.rawRepresentation],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .keyUnauthorized)
        }
    }

    func testHigherRecoveryGenerationCannotLowerCheckpointFence() async throws {
        let rootKey = Curve25519.Signing.PrivateKey()
        let artifactKey = Curve25519.Signing.PrivateKey()
        let scope = makeScope()
        let seeds = makeSeeds()
        let store = PreloginMemoryStore()

        let firstStateRaw = try makeSignedKeyState(
            rootKey: rootKey,
            artifactPublicKey: artifactKey.publicKey.rawRepresentation,
            recoveryGeneration: 1,
            currentFencingGeneration: 2
        )
        let firstState = try PreloginTrust.verifyKeyState(
            raw: firstStateRaw,
            rootKeyID: "recovery-root-1",
            rootPublicKey: rootKey.publicKey.rawRepresentation,
            previousRecoveryGeneration: 0,
            previousHash: "",
            now: now
        )
        let firstResponses = try makeResponses(
            seeds: seeds,
            stateRaw: firstStateRaw,
            state: firstState,
            signingKey: artifactKey,
            scope: scope,
            version: 7
        )
        let configuration = PreloginBootstrapConfiguration(
            seeds: seeds,
            scope: scope,
            rootKeyID: "recovery-root-1",
            rootPublicKey: rootKey.publicKey.rawRepresentation,
            artifactPublicKeys: ["primary-2026": artifactKey.publicKey.rawRepresentation]
        )
        let firstNow = now
        let firstResolver = PreloginBootstrapResolver(
            configuration: configuration,
            fetcher: PreloginFakeFetcher(responses: firstResponses),
            store: store,
            now: { firstNow }
        )
        _ = try await firstResolver.resolvePlatformBase()

        let lowerFenceStateRaw = try makeSignedKeyState(
            rootKey: rootKey,
            artifactPublicKey: artifactKey.publicKey.rawRepresentation,
            recoveryGeneration: 2,
            currentFencingGeneration: 1
        )
        let lowerFenceState = try PreloginTrust.verifyKeyState(
            raw: lowerFenceStateRaw,
            rootKeyID: "recovery-root-1",
            rootPublicKey: rootKey.publicKey.rawRepresentation,
            previousRecoveryGeneration: 1,
            previousHash: firstState.payloadHash,
            now: now
        )
        let lowerFenceResponses = try makeResponses(
            seeds: seeds,
            stateRaw: lowerFenceStateRaw,
            state: lowerFenceState,
            signingKey: artifactKey,
            scope: scope,
            version: 8
        )
        let secondNow = now.addingTimeInterval(60)
        let secondResolver = PreloginBootstrapResolver(
            configuration: configuration,
            fetcher: PreloginFakeFetcher(responses: lowerFenceResponses),
            store: store,
            now: { secondNow }
        )
        do {
            _ = try await secondResolver.resolvePlatformBase()
            XCTFail("Expected recovery generation advance to preserve checkpoint fence")
        } catch {
            XCTAssertEqual(error as? PreloginBootstrapError, .recoveryRollback)
        }
    }

    func testResolverFailsClosedWhenOneSourceConflictsAtPersistedRecoveryGeneration() async throws {
        let rootKey = Curve25519.Signing.PrivateKey()
        let artifactKey = Curve25519.Signing.PrivateKey()
        let scope = makeScope()
        let seeds = makeSeeds()
        let store = PreloginMemoryStore()
        let stateRaw = try makeSignedKeyState(
            rootKey: rootKey,
            artifactPublicKey: artifactKey.publicKey.rawRepresentation
        )
        let state = try PreloginTrust.verifyKeyState(
            raw: stateRaw,
            rootKeyID: "recovery-root-1",
            rootPublicKey: rootKey.publicKey.rawRepresentation,
            previousRecoveryGeneration: 0,
            previousHash: "",
            now: now
        )
        let responses = try makeResponses(
            seeds: seeds,
            stateRaw: stateRaw,
            state: state,
            signingKey: artifactKey,
            scope: scope,
            version: 7
        )
        let configuration = PreloginBootstrapConfiguration(
            seeds: seeds,
            scope: scope,
            rootKeyID: "recovery-root-1",
            rootPublicKey: rootKey.publicKey.rawRepresentation,
            artifactPublicKeys: ["primary-2026": artifactKey.publicKey.rawRepresentation]
        )
        let firstNow = now
        let online = PreloginBootstrapResolver(
            configuration: configuration,
            fetcher: PreloginFakeFetcher(responses: responses),
            store: store,
            now: { firstNow }
        )
        _ = try await online.resolvePlatformBase()

        let conflictingStateRaw = try makeSignedKeyState(
            rootKey: rootKey,
            artifactPublicKey: artifactKey.publicKey.rawRepresentation,
            expiresAt: "2026-07-25T13:00:00Z"
        )
        let conflictingState = try PreloginTrust.verifyKeyState(
            raw: conflictingStateRaw,
            rootKeyID: "recovery-root-1",
            rootPublicKey: rootKey.publicKey.rawRepresentation,
            previousRecoveryGeneration: 0,
            previousHash: "",
            now: now
        )
        var conflictingResponses = responses
        let conflictingSeed = seeds[1]
        let conflictingBundle = try makeBundle(
            version: 7,
            platformHost: "api.example.test",
            seed: conflictingSeed,
            stateRaw: conflictingStateRaw,
            verifiedState: conflictingState,
            signingKey: artifactKey,
            scope: scope
        )
        for (key, value) in conflictingBundle {
            conflictingResponses[key] = value
        }

        let secondNow = now.addingTimeInterval(60)
        let resolver = PreloginBootstrapResolver(
            configuration: configuration,
            fetcher: PreloginFakeFetcher(responses: conflictingResponses),
            store: store,
            now: { secondNow }
        )
        do {
            _ = try await resolver.resolvePlatformBase()
            XCTFail("Expected same-generation root-authorized state conflict")
        } catch {
            XCTAssertEqual(error as? PreloginBootstrapError, .recoveryConflict)
        }
    }

    private func makeSeeds() -> [PreloginSeed] {
        [
            PreloginSeed(id: "primary", baseURL: URL(string: "https://one.example.test/config/")!),
            PreloginSeed(
                id: "account-backup",
                baseURL: URL(string: "https://two.example.test/config/")!
            ),
            PreloginSeed(
                id: "cloud-backup",
                baseURL: URL(string: "https://three.example.test/config/")!
            )
        ]
    }

    func sourcePrefix(_ seed: PreloginSeed) -> String {
        let path = seed.baseURL.path.hasSuffix("/")
            ? seed.baseURL.path
            : "\(seed.baseURL.path)/"
        return "\(seed.baseURL.host!)\(path)"
    }

    func sourceScopePrefix(
        _ seed: PreloginSeed,
        scope: PreloginExpectedScope
    ) -> String {
        "\(sourcePrefix(seed))bootstrap-v1/\(PreloginTrust.scopeHash(scope))/"
    }

    private func makeResponses(
        seeds: [PreloginSeed],
        stateRaw: Data,
        state: PreloginVerifiedKeyState,
        signingKey: Curve25519.Signing.PrivateKey,
        scope: PreloginExpectedScope,
        version: UInt64
    ) throws -> [String: Data] {
        guard let first = seeds.first else { return [:] }
        let signedBundle = try makeBundle(
            version: version,
            platformHost: "api.example.test",
            seed: first,
            stateRaw: stateRaw,
            verifiedState: state,
            signingKey: signingKey,
            scope: scope
        )
        return seeds.reduce(into: [:]) { result, seed in
            result.merge(mirrorBundle(signedBundle, from: first, to: seed)) { _, rhs in rhs }
        }
    }

    private func mirrorBundle(
        _ bundle: [String: Data],
        from source: PreloginSeed,
        to destination: PreloginSeed
    ) -> [String: Data] {
        let sourcePrefixValue = sourcePrefix(source)
        let destinationPrefixValue = sourcePrefix(destination)
        return Dictionary(
            uniqueKeysWithValues: bundle.map { key, value in
                (
                    key.replacingOccurrences(
                        of: sourcePrefixValue,
                        with: destinationPrefixValue,
                        options: [.anchored]
                    ),
                    value
                )
            }
        )
    }

    private func makeResolverFixture() throws -> PreloginResolverFixture {
        let rootKey = Curve25519.Signing.PrivateKey()
        let artifactKey = Curve25519.Signing.PrivateKey()
        let scope = makeScope()
        let seeds = makeSeeds()
        let stateRaw = try makeSignedKeyState(
            rootKey: rootKey,
            artifactPublicKey: artifactKey.publicKey.rawRepresentation
        )
        let state = try PreloginTrust.verifyKeyState(
            raw: stateRaw,
            rootKeyID: "recovery-root-1",
            rootPublicKey: rootKey.publicKey.rawRepresentation,
            previousRecoveryGeneration: 0,
            previousHash: "",
            now: now
        )
        return PreloginResolverFixture(
            configuration: PreloginBootstrapConfiguration(
                seeds: seeds,
                scope: scope,
                rootKeyID: "recovery-root-1",
                rootPublicKey: rootKey.publicKey.rawRepresentation,
                artifactPublicKeys: [
                    "primary-2026": artifactKey.publicKey.rawRepresentation
                ]
            ),
            responses: try makeResponses(
                seeds: seeds,
                stateRaw: stateRaw,
                state: state,
                signingKey: artifactKey,
                scope: scope,
                version: 7
            )
        )
    }

    private func makeResolver(
        fixture: PreloginResolverFixture,
        fetcher: PreloginFakeFetcher,
        store: PreloginMemoryStore,
        now: Date
    ) -> PreloginBootstrapResolver {
        PreloginBootstrapResolver(
            configuration: fixture.configuration,
            fetcher: fetcher,
            store: store,
            now: { now }
        )
    }

    private func verifyGeneratedBundle(
        seed: PreloginSeed,
        bundle: [String: Data],
        configuration: PreloginBootstrapConfiguration
    ) throws {
        let prefix = sourceScopePrefix(seed, scope: configuration.scope)
        let rootPrefix = sourcePrefix(seed)
        let currentRaw = try XCTUnwrap(bundle["\(prefix)current.json"])
        let reference = try PreloginTrust.keyStateReference(
            currentRaw: currentRaw,
            scope: configuration.scope
        )
        let state = try PreloginTrust.verifyKeyState(
            raw: try XCTUnwrap(bundle["\(rootPrefix)\(reference.key)"]),
            rootKeyID: configuration.rootKeyID,
            rootPublicKey: configuration.rootPublicKey,
            previousRecoveryGeneration: 0,
            previousHash: "",
            now: now
        )
        let current = try PreloginTrust.verifyCurrent(
            raw: currentRaw,
            scope: configuration.scope,
            keyState: state,
            publicKeys: configuration.artifactPublicKeys,
            now: now
        )
        let artifact = try PreloginTrust.verifyArtifact(
            raw: try XCTUnwrap(
                bundle["\(rootPrefix)\(current.pointer.payload.artifactKey)"]
            ),
            scope: configuration.scope,
            keyState: state,
            publicKeys: configuration.artifactPublicKeys,
            now: now
        )
        try PreloginTrust.verifyPointerArtifactBinding(
            pointer: current,
            artifact: artifact
        )
    }
}

private struct PreloginResolverFixture {
    let configuration: PreloginBootstrapConfiguration
    let responses: [String: Data]
}

private actor PreloginFakeFetcher: PreloginHTTPFetching {
    private let responses: [String: Data]
    private(set) var sourceHosts: Set<String> = []
    private(set) var requestedKeys: Set<String> = []

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func get(_ url: URL, constrainedTo seed: PreloginSeed) throws -> Data {
        if let host = seed.baseURL.host { sourceHosts.insert(host) }
        let key = "\(url.host!)\(url.path)"
        requestedKeys.insert(key)
        guard let response = responses[key] else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        return response
    }
}

private actor PreloginMemoryStore: PreloginLastGoodStoring {
    private var envelope: PreloginLastGoodEnvelope?
    private var checkpoint: PreloginTrustCheckpoint?

    func loadEnvelope() -> PreloginLastGoodEnvelope? { envelope }
    func loadCheckpoint() -> PreloginTrustCheckpoint? { checkpoint }
    func saveEnvelope(_ value: PreloginLastGoodEnvelope) { envelope = value }
    func saveCheckpoint(_ value: PreloginTrustCheckpoint) { checkpoint = value }
    func snapshotEnvelope() -> PreloginLastGoodEnvelope? { envelope }
    func snapshotCheckpoint() -> PreloginTrustCheckpoint? { checkpoint }
    func replaceEnvelope(_ value: PreloginLastGoodEnvelope) { envelope = value }
}

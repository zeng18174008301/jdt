import CryptoKit
import Foundation
import XCTest
@testable import BlueStoneIM

@MainActor
final class PreloginBootstrapTests: XCTestCase {
    func testAppVariantsUseDifferentPreloginKeychainServices() {
        let app1 = PreloginSecureLastGoodStore.keychainServiceName(
            bundleIdentifier: "com.jianhuitongqiyetest.app"
        )
        let app2 = PreloginSecureLastGoodStore.keychainServiceName(
            bundleIdentifier: "com.wenxintong.app2.unconfigured"
        )

        XCTAssertEqual(app1, "com.jianhuitongqiyetest.app.prelogin-bootstrap")
        XCTAssertEqual(app2, "com.wenxintong.app2.unconfigured.prelogin-bootstrap")
        XCTAssertNotEqual(app1, app2)
    }

    private let now = ISO8601DateFormatter().date(from: "2026-07-24T12:30:00Z")!

    func testAcceptsFrozenGoRootStateArtifactAndCurrentPointerVectors() throws {
        let vector = try loadFixedVector()
        let rootPublicKey = try XCTUnwrap(Data(base64Encoded: vector.rootPublicKeyBase64))
        let configPublicKey = try XCTUnwrap(Data(base64Encoded: vector.configPublicKeyBase64))
        let state = try PreloginTrust.verifyKeyState(
            raw: Data(vector.keyStateRaw.utf8),
            rootKeyID: vector.rootKeyID,
            rootPublicKey: rootPublicKey,
            previousRecoveryGeneration: 0,
            previousHash: "",
            now: now
        )
        let verified = try PreloginTrust.verifyArtifact(
            raw: Data(vector.artifactRaw.utf8),
            scope: makeScope(),
            keyState: state,
            publicKeys: [vector.configKeyID: configPublicKey],
            now: now
        )
        let current = try PreloginTrust.verifyCurrent(
            raw: Data(vector.currentPointerRaw.utf8),
            scope: makeScope(),
            keyState: state,
            publicKeys: [vector.configKeyID: configPublicKey],
            now: now
        )
        try PreloginTrust.verifyPointerArtifactBinding(pointer: current, artifact: verified)

        XCTAssertEqual(verified.canonicalPayload, Data(vector.canonicalPayload.utf8))
        XCTAssertEqual(verified.artifact.payload.configVersion, 7)
        XCTAssertEqual(
            try PreloginTrust.platformBase(from: verified).absoluteString,
            "https://api.example.test/v1"
        )
        XCTAssertEqual(PreloginTrust.scopeHash(makeScope()), vector.scopeHash)
        XCTAssertEqual(state.objectHash, current.pointer.payload.keyStateHash)
        XCTAssertEqual(PreloginTrust.sha256(verified.raw), current.pointer.payload.artifactHash)
        XCTAssertEqual(vector.layoutScopes.count, 2)
        XCTAssertEqual(Set(vector.layoutScopes.map(\.scopeHash)).count, 2)
        for layout in vector.layoutScopes {
            XCTAssertEqual(
                layout.currentKey,
                "bootstrap-v1/\(layout.scopeHash)/current.json"
            )
        }
    }

    func testFrozenGoPortableCanonicalValuesMatchSwift() throws {
        let vector = try loadFixedVector()
        XCTAssertEqual(
            String(
                decoding: try PreloginStrictJSON.canonical(vector.portableStrings),
                as: UTF8.self
            ),
            vector.portableStringsCanonical
        )
        XCTAssertEqual(
            String(
                decoding: try PreloginStrictJSON.canonical(["value": UInt64.max]),
                as: UTF8.self
            ),
            vector.maximumUInt64JSON
        )
    }

    func testRejectsDuplicateUnknownAndNonCanonicalJSONBeforeDecode() throws {
        let duplicate = Data(
            #"{"payload":{},"signature":"a","signature":"b","signature_alg":"Ed25519"}"#.utf8
        )
        XCTAssertThrowsError(try PreloginStrictJSON.decodeArtifact(duplicate)) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .duplicateJSONKey)
        }

        let unknown = Data(
            #"{"payload":{},"signature":"a","signature_alg":"Ed25519","url":"https://evil.example"}"#.utf8
        )
        XCTAssertThrowsError(try PreloginStrictJSON.decodeArtifact(unknown)) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .invalidJSON)
        }

        var nonCanonicalText = try loadFixedVector().artifactRaw
        let payloadSeparator = try XCTUnwrap(
            nonCanonicalText.range(of: #""payload":"#)
        )
        nonCanonicalText.insert(" ", at: payloadSeparator.upperBound)
        XCTAssertThrowsError(
            try PreloginStrictJSON.decodeArtifact(Data(nonCanonicalText.utf8))
        ) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .nonCanonicalJSON)
        }

        let executableUnknown = Data(
            #"{"payload":{"audience":{"app_id":"a","bundle_id":"b.example","channel":"c","platform":"ios","product_id":"p"},"canonicalization_version":1,"config_version":1,"content_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","contract_version":1,"endpoints":[{"host":"api.example.test","id":"id","path":"/","port":443,"priority":1,"protocol":"https","redirect":"https://evil.example","url":"https://api.example.test/","usage":"platform_api"}],"environment":"production","expires_at":"2026-07-24T13:00:00Z","fencing_generation":1,"issued_at":"2026-07-24T12:00:00Z","key_id":"key","purpose":"prelogin_bootstrap"},"signature":"a","signature_alg":"Ed25519"}"#.utf8
        )
        XCTAssertThrowsError(try PreloginStrictJSON.decodeArtifact(executableUnknown)) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .invalidJSON)
        }
    }

    func testCanonicalizationMatchesGoHTMLAndLineSeparatorEscaping() throws {
        let canonical = try PreloginStrictJSON.canonical(
            ["value": "<tag>&\u{2028}\u{2029}"]
        )
        XCTAssertEqual(
            String(decoding: canonical, as: UTF8.self),
            #"{"value":"\u003ctag\u003e\u0026\u2028\u2029"}"#
        )
    }

    func testTimestampRequiresExactUTCSeconds() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let state = makeVerifiedState(
            authorization: makeAuthorization(),
            payloadHash: String(repeating: "1", count: 64)
        )
        for issuedAt in [
            "2026-07-24T11:59:00+00:00",
            "2026-07-24T11:59:00.000Z"
        ] {
            let raw = try makeCurrentRaw(
                fencingGeneration: 1,
                keyState: state,
                signingKey: signingKey,
                issuedAt: issuedAt
            )
            XCTAssertThrowsError(
                try PreloginTrust.verifyCurrent(
                    raw: raw,
                    scope: makeScope(),
                    keyState: state,
                    publicKeys: ["primary-2026": signingKey.publicKey.rawRepresentation],
                    now: now
                )
            ) {
                XCTAssertEqual($0 as? PreloginBootstrapError, .invalidContract)
            }
        }
    }

    func testArtifactSigningPayloadAccepts4096AndRejects4097Bytes() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let state = makeVerifiedState(
            authorization: makeAuthorization(),
            payloadHash: String(repeating: "1", count: 64)
        )
        let acceptedRaw = try makeSizedArtifactRaw(
            canonicalPayloadBytes: 4_096,
            signingKey: signingKey,
            keyState: state
        )
        let accepted = try PreloginTrust.verifyArtifact(
            raw: acceptedRaw,
            scope: makeScope(),
            keyState: state,
            publicKeys: ["primary-2026": signingKey.publicKey.rawRepresentation],
            now: now
        )
        XCTAssertEqual(accepted.canonicalPayload.count, 4_096)

        let rejectedRaw = try makeSizedArtifactRaw(
            canonicalPayloadBytes: 4_097,
            signingKey: signingKey,
            keyState: state
        )
        XCTAssertThrowsError(
            try PreloginTrust.verifyArtifact(
                raw: rejectedRaw,
                scope: makeScope(),
                keyState: state,
                publicKeys: ["primary-2026": signingKey.publicKey.rawRepresentation],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .signingPayloadTooLarge)
        }
    }

    func testKeyStateArbitrationUsesHighestGenerationAndConflictsFailClosed() throws {
        let authorization = makeAuthorization()
        let lower = makeVerifiedState(
            authorization: authorization,
            payloadHash: String(repeating: "1", count: 64),
            recoveryGeneration: 1
        )
        let higher = makeVerifiedState(
            authorization: authorization,
            payloadHash: String(repeating: "2", count: 64),
            recoveryGeneration: 2
        )
        XCTAssertEqual(
            try PreloginTrust.arbitrateKeyStates([("low", lower), ("high", higher)])
                .state.payload.recoveryGeneration,
            2
        )
        let conflicting = makeVerifiedState(
            authorization: authorization,
            payloadHash: String(repeating: "3", count: 64),
            recoveryGeneration: 2
        )
        XCTAssertThrowsError(
            try PreloginTrust.arbitrateKeyStates([("high", higher), ("conflict", conflicting)])
        ) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .recoveryConflict)
        }
    }

    func testSameFenceAndVersionWithDifferentSignedPayloadFailsClosed() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let state = makeVerifiedState(
            authorization: makeAuthorization(),
            payloadHash: String(repeating: "b", count: 64)
        )
        let first = try makeArtifact(
            version: 9,
            platformHost: "api-one.example.test",
            signingKey: signingKey,
            keyState: state
        )
        let second = try makeArtifact(
            version: 9,
            platformHost: "api-two.example.test",
            signingKey: signingKey,
            keyState: state
        )

        XCTAssertThrowsError(
            try PreloginTrust.arbitrate([("primary", first), ("backup", second)])
        ) {
            XCTAssertEqual($0 as? PreloginBootstrapError, .candidateConflict)
        }
    }

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

    func testUntrustedCurrentRejectsMaliciousKeyStatePathsBeforeSignatureUse() throws {
        let vector = try loadFixedVector()
        let current = try PreloginStrictJSON.decodeCurrent(Data(vector.currentPointerRaw.utf8))
        let valid = current.payload.keyStateKey
        let scopeHash = PreloginTrust.scopeHash(makeScope())
        for malicious in [
            "../key-state.json",
            "bootstrap-v1/\(scopeHash)/bootstrap-v1/key-states/\(current.payload.keyStateHash).json",
            "bootstrap-v1/\(String(repeating: "0", count: 64))/key-states/\(current.payload.keyStateHash).json",
            "bootstrap-v1/\(scopeHash)/key-states/\(String(repeating: "0", count: 64)).json"
        ] {
            let tampered = vector.currentPointerRaw.replacingOccurrences(
                of: #""key_state_key":"\#(valid)""#,
                with: #""key_state_key":"\#(malicious)""#
            )
            XCTAssertThrowsError(
                try PreloginTrust.keyStateReference(
                    currentRaw: Data(tampered.utf8),
                    scope: makeScope()
                ),
                "accepted malicious key_state_key=\(malicious)"
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

    private func makeScope() -> PreloginExpectedScope {
        PreloginExpectedScope(
            environment: "production",
            productID: "wenxintong",
            appID: "app-ios",
            bundleID: "com.example.app",
            channel: "appstore",
            platform: "ios"
        )
    }

    private func loadFixedVector() throws -> PreloginFixedVector {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle(for: Self.self)
#endif
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "prelogin-bootstrap-v1-test-vectors",
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(PreloginFixedVector.self, from: Data(contentsOf: url))
    }

    private func makeAuthorization(
        keyID: String = "primary-2026",
        status: String = "active"
    ) -> PreloginKeyAuthorization {
        PreloginKeyAuthorization(
            keyID: keyID,
            algorithm: "Ed25519",
            status: status,
            environment: "production",
            productID: "wenxintong",
            appID: "app-ios",
            bundleID: "com.example.app",
            packageName: nil,
            channel: "appstore",
            platform: "ios",
            minFencingGeneration: 1,
            maxFencingGeneration: nil
        )
    }

    private func makeVerifiedState(
        authorization: PreloginKeyAuthorization,
        payloadHash: String,
        recoveryGeneration: UInt64 = 1,
        currentFencingGeneration: UInt64 = 1
    ) -> PreloginVerifiedKeyState {
        let payload = PreloginKeyStatePayload(
            purpose: "prelogin_key_state",
            contractVersion: 1,
            recoveryGeneration: recoveryGeneration,
            currentFencingGeneration: currentFencingGeneration,
            issuedAt: "2026-07-24T11:59:00Z",
            expiresAt: "2026-07-25T12:59:00Z",
            keys: [authorization]
        )
        let signed = PreloginSignedKeyState(
            payload: payload,
            rootKeyID: "recovery-root-1",
            signatureAlg: "Ed25519",
            signature: "test-only"
        )
        return PreloginVerifiedKeyState(
            raw: Data(),
            state: signed,
            canonicalPayload: Data(),
            payloadHash: payloadHash,
            objectHash: payloadHash,
            authorizations: [authorization.keyID: authorization]
        )
    }

    private func makeArtifact(
        version: UInt64,
        platformHost: String,
        signingKey: Curve25519.Signing.PrivateKey,
        keyState: PreloginVerifiedKeyState,
        expiresAt: String = "2026-07-24T13:00:00Z"
    ) throws -> PreloginVerifiedArtifact {
        let endpoint = PreloginEndpoint(
            id: "platform-primary",
            usage: "platform_api",
            protocol: "https",
            url: "https://\(platformHost)/v1",
            host: platformHost,
            port: 443,
            path: "/v1",
            priority: 10
        )
        let contentHash = PreloginTrust.sha256(try PreloginStrictJSON.canonical([endpoint]))
        let payload = PreloginPayload(
            purpose: "prelogin_bootstrap",
            environment: "production",
            audience: makeScope().audience,
            contractVersion: 1,
            canonicalizationVersion: 1,
            keyID: "primary-2026",
            fencingGeneration: keyState.state.payload.currentFencingGeneration,
            configVersion: version,
            issuedAt: "2026-07-24T11:59:00Z",
            expiresAt: expiresAt,
            contentHash: contentHash,
            endpoints: [endpoint]
        )
        let signature = try signingKey.signature(for: PreloginStrictJSON.canonical(payload))
        let artifact = PreloginArtifact(
            payload: payload,
            signatureAlg: "Ed25519",
            signature: signature.base64EncodedString()
        )
        let raw = try PreloginStrictJSON.canonical(artifact)
        return try PreloginTrust.verifyArtifact(
            raw: raw,
            scope: makeScope(),
            keyState: keyState,
            publicKeys: ["primary-2026": signingKey.publicKey.rawRepresentation],
            now: now
        )
    }

    private func makeSignedKeyState(
        rootKey: Curve25519.Signing.PrivateKey,
        artifactPublicKey: Data,
        recoveryGeneration: UInt64 = 1,
        currentFencingGeneration: UInt64 = 1,
        keyStatus: String = "active",
        expiresAt: String = "2026-07-25T12:59:00Z"
    ) throws -> Data {
        _ = artifactPublicKey // Public material is injected separately by design.
        let payload = PreloginKeyStatePayload(
            purpose: "prelogin_key_state",
            contractVersion: 1,
            recoveryGeneration: recoveryGeneration,
            currentFencingGeneration: currentFencingGeneration,
            issuedAt: "2026-07-24T11:59:00Z",
            expiresAt: expiresAt,
            keys: [makeAuthorization(status: keyStatus)]
        )
        let signature = try rootKey.signature(for: PreloginStrictJSON.canonical(payload))
        return try PreloginStrictJSON.canonical(
            PreloginSignedKeyState(
                payload: payload,
                rootKeyID: "recovery-root-1",
                signatureAlg: "Ed25519",
                signature: signature.base64EncodedString()
            )
        )
    }

    private func makeBundle(
        version: UInt64,
        platformHost: String,
        seed: PreloginSeed,
        stateRaw: Data,
        verifiedState: PreloginVerifiedKeyState,
        signingKey: Curve25519.Signing.PrivateKey,
        scope: PreloginExpectedScope
    ) throws -> [String: Data] {
        let artifact = try makeArtifact(
            version: version,
            platformHost: platformHost,
            signingKey: signingKey,
            keyState: verifiedState
        )
        let artifactHash = PreloginTrust.sha256(artifact.raw)
        let fencingGeneration = verifiedState.state.payload.currentFencingGeneration
        let artifactPath = [
            "bootstrap-v1",
            PreloginTrust.scopeHash(scope),
            "fence-\(fencingGeneration)",
            "version-\(version)-\(artifactHash).json"
        ].joined(separator: "/")
        let payload = PreloginCurrentPayload(
            purpose: "prelogin_bootstrap_current",
            scopeHash: PreloginTrust.scopeHash(scope),
            keyStateKey: [
                "bootstrap-v1",
                PreloginTrust.scopeHash(scope),
                "key-states",
                "\(verifiedState.objectHash).json"
            ].joined(separator: "/"),
            keyStateHash: verifiedState.objectHash,
            artifactKey: artifactPath,
            artifactHash: artifactHash,
            artifactPayloadHash: artifact.payloadHash,
            fencingGeneration: fencingGeneration,
            configVersion: version,
            issuedAt: artifact.artifact.payload.issuedAt,
            expiresAt: artifact.artifact.payload.expiresAt
        )
        let signature = try signingKey.signature(for: PreloginStrictJSON.canonical(payload))
        let currentRaw = try PreloginStrictJSON.canonical(
            PreloginSignedCurrent(
                payload: payload,
                keyID: "primary-2026",
                signatureAlg: "Ed25519",
                signature: signature.base64EncodedString()
            )
        )
        let prefix = sourceScopePrefix(seed, scope: scope)
        let rootPrefix = sourcePrefix(seed)
        return [
            "\(rootPrefix)\(payload.keyStateKey)": stateRaw,
            "\(prefix)current.json": currentRaw,
            "\(rootPrefix)\(artifactPath)": artifact.raw
        ]
    }

    private func makeCurrentRaw(
        fencingGeneration: UInt64,
        keyState: PreloginVerifiedKeyState,
        signingKey: Curve25519.Signing.PrivateKey,
        issuedAt: String = "2026-07-24T11:59:00Z",
        expiresAt: String = "2026-07-24T13:00:00Z"
    ) throws -> Data {
        let artifactHash = String(repeating: "a", count: 64)
        let payload = PreloginCurrentPayload(
            purpose: "prelogin_bootstrap_current",
            scopeHash: PreloginTrust.scopeHash(makeScope()),
            keyStateKey: [
                "bootstrap-v1",
                PreloginTrust.scopeHash(makeScope()),
                "key-states",
                "\(keyState.objectHash).json"
            ].joined(separator: "/"),
            keyStateHash: keyState.objectHash,
            artifactKey: [
                "bootstrap-v1",
                PreloginTrust.scopeHash(makeScope()),
                "fence-\(fencingGeneration)",
                "version-7-\(artifactHash).json"
            ].joined(separator: "/"),
            artifactHash: artifactHash,
            artifactPayloadHash: String(repeating: "b", count: 64),
            fencingGeneration: fencingGeneration,
            configVersion: 7,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let signature = try signingKey.signature(
            for: PreloginStrictJSON.canonical(payload)
        )
        return try PreloginStrictJSON.canonical(
            PreloginSignedCurrent(
                payload: payload,
                keyID: "primary-2026",
                signatureAlg: "Ed25519",
                signature: signature.base64EncodedString()
            )
        )
    }

    private func makeSizedArtifactRaw(
        canonicalPayloadBytes target: Int,
        signingKey: Curve25519.Signing.PrivateKey,
        keyState: PreloginVerifiedKeyState
    ) throws -> Data {
        for idSuffixLength in 0...1 {
            for pathBodyLength in 1...2_000 {
                let path = "/" + String(repeating: "x", count: pathBodyLength)
                let endpoint = PreloginEndpoint(
                    id: "platform" + String(repeating: "i", count: idSuffixLength),
                    usage: "platform_api",
                    protocol: "https",
                    url: "https://api.example.test\(path)",
                    host: "api.example.test",
                    port: 443,
                    path: path,
                    priority: 10
                )
                let contentHash = PreloginTrust.sha256(
                    try PreloginStrictJSON.canonical([endpoint])
                )
                let payload = PreloginPayload(
                    purpose: "prelogin_bootstrap",
                    environment: "production",
                    audience: makeScope().audience,
                    contractVersion: 1,
                    canonicalizationVersion: 1,
                    keyID: "primary-2026",
                    fencingGeneration: keyState.state.payload.currentFencingGeneration,
                    configVersion: 7,
                    issuedAt: "2026-07-24T11:59:00Z",
                    expiresAt: "2026-07-24T13:00:00Z",
                    contentHash: contentHash,
                    endpoints: [endpoint]
                )
                let canonical = try PreloginStrictJSON.canonical(payload)
                guard canonical.count == target else { continue }
                let signature = try signingKey.signature(for: canonical)
                return try PreloginStrictJSON.canonical(
                    PreloginArtifact(
                        payload: payload,
                        signatureAlg: "Ed25519",
                        signature: signature.base64EncodedString()
                    )
                )
            }
        }
        throw PreloginBootstrapError.invalidContract
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

    private func sourcePrefix(_ seed: PreloginSeed) -> String {
        let path = seed.baseURL.path.hasSuffix("/")
            ? seed.baseURL.path
            : "\(seed.baseURL.path)/"
        return "\(seed.baseURL.host!)\(path)"
    }

    private func sourceScopePrefix(
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

private struct PreloginFixedVector: Decodable {
    let artifactRaw: String
    let canonicalPayload: String
    let configKeyID: String
    let configPublicKeyBase64: String
    let currentPointerRaw: String
    let keyStateRaw: String
    let layoutScopes: [PreloginLayoutScope]
    let maximumUInt64JSON: String
    let portableStrings: [String]
    let portableStringsCanonical: String
    let rootKeyID: String
    let rootPublicKeyBase64: String
    let scopeHash: String

    enum CodingKeys: String, CodingKey {
        case artifactRaw = "artifact_raw"
        case canonicalPayload = "canonical_payload"
        case configKeyID = "config_key_id"
        case configPublicKeyBase64 = "config_public_key_base64"
        case currentPointerRaw = "current_pointer_raw"
        case keyStateRaw = "key_state_raw"
        case layoutScopes = "layout_scopes"
        case maximumUInt64JSON = "maximum_uint64_json"
        case portableStrings = "portable_strings"
        case portableStringsCanonical = "portable_strings_canonical"
        case rootKeyID = "root_key_id"
        case rootPublicKeyBase64 = "root_public_key_base64"
        case scopeHash = "scope_hash"
    }
}

private struct PreloginLayoutScope: Decodable {
    let currentKey: String
    let scopeHash: String

    enum CodingKeys: String, CodingKey {
        case currentKey = "current_key"
        case scopeHash = "scope_hash"
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

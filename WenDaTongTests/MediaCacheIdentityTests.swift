import CryptoKit
import Foundation
import ImageIO
import UIKit
import XCTest
@testable import WenDaTong

extension MediaPipelineTests {
    func testMediaResourceIdentityPrefersFileIDAndIgnoresSignedURLQueryChanges() {
        let first = MediaPipelineCore.identity(
            kind: .thumbnail,
            scope: Self.fixtureScopeHash,
            fileID: "file-1",
            cacheKey: "https://cdn.example.test/file.jpg?auth_key=first",
            version: "v1"
        )
        let second = MediaPipelineCore.identity(
            kind: .thumbnail,
            scope: Self.fixtureScopeHash,
            fileID: "file-1",
            cacheKey: "https://cdn.example.test/file.jpg?auth_key=second",
            version: "v1"
        )

        XCTAssertEqual(first.stableCacheKey, second.stableCacheKey)
        XCTAssertEqual(first.stableCacheKey.count, 64)
        XCTAssertFalse(first.stableCacheKey.contains("file-1"))
        XCTAssertFalse(first.stableCacheKey.contains("auth_key"))
    }

    func testMediaResourceIdentityRejectsSignedURLOnlyPersistentIdentity() {
        let first = MediaPipelineCore.identity(
            kind: .preview,
            scope: Self.fixtureScopeHash,
            cacheKey: "https://user:password@cdn.example.test/file.jpg?auth_key=first#preview"
        )
        let second = MediaPipelineCore.identity(
            kind: .preview,
            scope: Self.fixtureScopeHash,
            cacheKey: "https://cdn.example.test/file.jpg?auth_key=second#other"
        )

        XCTAssertNil(first.persistentCacheIdentity)
        XCTAssertNil(second.persistentCacheIdentity)

        let versionedSignedURL = MediaPipelineCore.identity(
            kind: .preview,
            scope: Self.fixtureScopeHash,
            cacheKey: "https://cdn.example.test/file.jpg?auth_key=third",
            version: "v1"
        )
        XCTAssertNil(versionedSignedURL.persistentCacheIdentity)
    }

    func testFrozenIdentityVectorsMatchCanonicalContract() throws {
        let fixture = try JSONDecoder().decode(
            FrozenIdentityFixture.self,
            from: Data(contentsOf: cacheContractFixtureURL("identity-vectors.json"))
        )
        XCTAssertEqual(fixture.fixtureVersion, 1)
        XCTAssertEqual(fixture.vectors.count, 3)

        for vector in fixture.vectors {
            let scopePairs = [
                ("account_id", vector.scope.accountID),
                ("tenant_id", vector.scope.tenantID),
                ("app_id", vector.scope.appID),
                ("im_uid", vector.scope.imUID),
                ("device_id", vector.scope.deviceID)
            ]
            XCTAssertEqual(
                String(data: try MediaCacheCanonicalIdentity.canonicalData(scopePairs), encoding: .utf8),
                vector.scopeCanonical,
                vector.id
            )
            let scopeHash = try MediaCacheCanonicalIdentity.digest(scopePairs)
            XCTAssertEqual(scopeHash, vector.scopeHash, vector.id)
            let variant = try XCTUnwrap(MediaCacheVariant(rawValue: vector.variant), vector.id)
            let resourceKind: MediaResourceKind = switch variant {
            case .thumbnail320, .thumbnail640, .videoPoster: .thumbnail
            case .preview1600: .preview
            case .original: .original
            }
            let createdAt = vector.contentVersion
                .components(separatedBy: ";created_at=")
                .dropFirst()
                .first ?? ""
            let sizeBytes = vector.contentVersion
                .split(separator: ";")
                .first
                .flatMap { component -> Int64? in
                    guard component.hasPrefix("size=") else { return nil }
                    return Int64(component.dropFirst("size=".count))
                }
            let identity = MediaResourceIdentity(
                resourceKind: resourceKind,
                scope: scopeHash,
                fileID: vector.resourceIDKind == "file_id" ? vector.resourceID : "",
                attachmentID: vector.resourceIDKind == "attachment_id" ? vector.resourceID : "",
                mediaID: vector.resourceIDKind == "media_id" ? vector.resourceID : "",
                cacheKey: vector.resourceIDKind == "cache_key" ? vector.resourceID : "",
                version: vector.contentVersionKind == "version" ? vector.contentVersion : "",
                checksumSHA256: vector.contentVersionKind == "checksum_sha256" ? vector.contentVersion : "",
                createdAt: createdAt,
                variant: variant,
                sizeBytes: sizeBytes
            )
            XCTAssertEqual(identity.resourceIDKind?.rawValue, vector.resourceIDKind, vector.id)
            XCTAssertEqual(identity.contentVersionKindAndValue?.0.rawValue, vector.contentVersionKind, vector.id)
            XCTAssertEqual(identity.contentVersionKindAndValue?.1, vector.contentVersion, vector.id)
            let cachePairs = [
                ("scope_hash", vector.scopeHash),
                ("resource_id_kind", vector.resourceIDKind),
                ("resource_id", vector.resourceID),
                ("content_version_kind", vector.contentVersionKind),
                ("content_version", vector.contentVersion),
                ("variant", vector.variant)
            ]
            XCTAssertEqual(
                String(data: try MediaCacheCanonicalIdentity.canonicalData(cachePairs), encoding: .utf8),
                vector.cacheCanonical,
                vector.id
            )
            XCTAssertEqual(identity.persistentCacheIdentity, vector.cacheIdentity, vector.id)
        }
    }

    func testFrozenIdentityPrecedenceAndWhitespaceAreFailClosed() {
        let identity = MediaPipelineCore.identity(
            kind: .original,
            scope: Self.fixtureScopeHash,
            attachmentID: "attachment-preferred",
            mediaID: "media-lower-priority",
            version: "v1"
        )
        XCTAssertEqual(identity.resourceIDKind, .attachmentID)
        XCTAssertEqual(identity.primaryStableID, "attachment-preferred")

        let invalid = MediaPipelineCore.identity(
            kind: .original,
            scope: Self.fixtureScopeHash,
            fileID: " file-with-leading-space",
            version: "v1"
        )
        XCTAssertNil(invalid.persistentCacheIdentity)

        for malformedChecksum in [
            String(repeating: "A", count: 64),
            "sha256:" + String(repeating: "a", count: 64),
            " " + String(repeating: "a", count: 64)
        ] {
            let malformed = MediaPipelineCore.identity(
                kind: .original,
                scope: Self.fixtureScopeHash,
                fileID: "file-malformed-checksum",
                version: "v1",
                checksumSHA256: malformedChecksum
            )
            XCTAssertNil(malformed.persistentCacheIdentity, malformedChecksum)
        }
    }

    // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
    func testM13AppCacheDelegatesRawStorageAndPrunesOnlyRequestedTier() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m13-blob-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var policies = Dictionary(uniqueKeysWithValues: MediaResourceKind.allCases.map { ($0, MediaCachePolicy.defaultPolicy(for: $0)) })
        policies[.thumbnail]?.diskCapacityBytes = 0
        let store = MediaLayeredCacheStore(rootDirectory: root, policiesByKind: policies)
        let scope = MediaResourceIdentity.stableHash("m13-owned-synthetic-scope")
        let inputs: [(String, MediaResourceKind, Data)] = [
            ("thumb-a", .thumbnail, Data([1, 2])), ("thumb-b", .thumbnail, Data([3, 4, 5])),
            ("original-c", .original, Data([6, 7, 8, 9]))]
        var identities: [MediaResourceIdentity] = []
        var entries: [MediaCacheEntry] = []
        for (id, kind, bytes) in inputs {
            let source = root.appendingPathComponent(id + ".incoming")
            try bytes.write(to: source)
            let identity = MediaResourceIdentity(resourceKind: kind, scope: scope, fileID: id, version: "v1")
            let entry = try await store.saveDownloadedFile(from: source, identity: identity, preferredExtension: "bin")
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "Original unverified save transfers ownership by move")
            XCTAssertEqual(try Data(contentsOf: entry.localURL), bytes)
            identities.append(identity); entries.append(entry)
        }
        let before = try await store.statistics(for: .thumbnail)
        XCTAssertEqual(before.fileCount, 2); XCTAssertEqual(before.totalBytes, 5); XCTAssertEqual(before.capacityBytes, 0)
        let candidates = try await store.evictionCandidates(for: .thumbnail, limitBytes: 0)
        XCTAssertEqual(Set(candidates.map(\.localURL)), Set(entries.prefix(2).map(\.localURL)))
        let after = try await store.prune(resourceKind: .thumbnail)
        XCTAssertEqual(after.fileCount, 0); XCTAssertEqual(after.totalBytes, 0); XCTAssertEqual(after.capacityBytes, 0)
        let missing = await store.lookup(identity: identities[0], preferredExtension: "bin")
        XCTAssertEqual(missing.state, .readyRemote)
        let original = await store.lookup(identity: identities[2], preferredExtension: "bin")
        XCTAssertEqual(original.state, .downloaded(localURL: entries[2].localURL))
        XCTAssertEqual(try Data(contentsOf: entries[2].localURL), inputs[2].2, "Pruning one tier must preserve the original tier")
        let totals = try await store.statistics()
        XCTAssertEqual(totals.fileCount, 1); XCTAssertEqual(totals.totalBytes, 4); XCTAssertNil(totals.capacityBytes)
    }
    // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END

    func testMediaLayeredCacheRejectsSameSizeChecksumCorruption() async throws {
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let sourceURL = cacheRoot
            .deletingLastPathComponent()
            .appendingPathComponent("media-integrity-source-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let original = Data("expected-content".utf8)
        let corrupted = Data("corruptd-content".utf8)
        XCTAssertEqual(original.count, corrupted.count)
        try original.write(to: sourceURL, options: .atomic)
        let integrity = MediaFileIntegrityAuthority(
            expectedSizeBytes: Int64(original.count),
            expectedSHA256: SHA256.hash(data: original).map { String(format: "%02x", Int($0)) }.joined()
        )
        let identity = MediaPipelineCore.identity(
            kind: .original,
            scope: Self.fixtureScopeHash,
            fileID: "file-integrity",
            version: "v1",
            mimeType: "application/octet-stream",
            sizeBytes: Int64(original.count)
        )
        let store = MediaLayeredCacheStore(rootDirectory: cacheRoot)
        let committed = try await store.saveVerifiedDownloadedFile(
            from: sourceURL,
            identity: identity,
            preferredExtension: "bin",
            integrity: integrity
        )
        try corrupted.write(to: committed.localURL, options: .atomic)

        let lookup = await store.verifiedLookup(
            identity: identity,
            preferredExtension: "bin",
            integrity: integrity
        )

        guard case .readyRemote = lookup.state else {
            return XCTFail("same-size corrupted bytes must not be returned as a cache hit")
        }
        XCTAssertNil(lookup.entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.localURL.path))
    }

    func testMediaLayeredCacheGenerationFenceRejectsRetiredWriterBeforePromotion() async throws {
        let seed = Data(UUID().uuidString.utf8)
        let scopeHash = SHA256.hash(data: seed).map { String(format: "%02x", Int($0)) }.joined()
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let oldSource = cacheRoot.deletingLastPathComponent()
            .appendingPathComponent("old-generation-\(UUID().uuidString).bin")
        let newSource = cacheRoot.deletingLastPathComponent()
            .appendingPathComponent("new-generation-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: oldSource)
            try? FileManager.default.removeItem(at: newSource)
        }
        let oldBytes = Data("retired-generation".utf8)
        let newBytes = Data("current-generation".utf8)
        try oldBytes.write(to: oldSource, options: .atomic)
        try newBytes.write(to: newSource, options: .atomic)
        let oldContext = IOSMediaCacheScopeContext(
            scopeHash: scopeHash,
            sessionGeneration: 10,
            rootDirectory: cacheRoot
        )
        let newContext = IOSMediaCacheScopeContext(
            scopeHash: scopeHash,
            sessionGeneration: 11,
            rootDirectory: cacheRoot
        )
        let oldStore = try await IOSMediaCacheStoreRegistry.shared.store(for: oldContext)
        let newStore = try await IOSMediaCacheStoreRegistry.shared.store(for: newContext)
        XCTAssertTrue(oldStore === newStore)
        let identity = MediaPipelineCore.identity(
            kind: .original,
            scope: scopeHash,
            fileID: "generation-file",
            version: "v1",
            mimeType: "application/octet-stream"
        )
        let integrity = MediaFileIntegrityAuthority()

        do {
            _ = try await oldStore.saveVerifiedDownloadedFile(
                from: oldSource,
                identity: identity,
                preferredExtension: "bin",
                integrity: integrity,
                sessionGeneration: oldContext.sessionGeneration
            )
            XCTFail("retired generation must not promote bytes")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: identity.cacheFileURL(in: cacheRoot, preferredExtension: "bin").path
        ))

        let committed = try await newStore.saveVerifiedDownloadedFile(
            from: newSource,
            identity: identity,
            preferredExtension: "bin",
            integrity: integrity,
            sessionGeneration: newContext.sessionGeneration
        )
        XCTAssertEqual(try Data(contentsOf: committed.localURL), newBytes)

        let staleLookup = await oldStore.verifiedLookup(
            identity: identity,
            preferredExtension: "bin",
            integrity: MediaFileIntegrityAuthority(
                expectedSizeBytes: Int64(oldBytes.count),
                expectedSHA256: SHA256.hash(data: oldBytes)
                    .map { String(format: "%02x", Int($0)) }
                    .joined()
            ),
            sessionGeneration: oldContext.sessionGeneration
        )
        guard case .readyRemote = staleLookup.state else {
            return XCTFail("retired lookup must not inspect current-generation bytes")
        }
        XCTAssertEqual(try Data(contentsOf: committed.localURL), newBytes)
    }

    private func cacheContractFixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/api/message-media-cache-v1/fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}

private struct FrozenIdentityFixture: Decodable {
    let fixtureVersion: Int
    let vectors: [Vector]

    struct Vector: Decodable {
        let id: String
        let scope: Scope
        let scopeCanonical: String
        let scopeHash: String
        let resourceIDKind: String
        let resourceID: String
        let contentVersionKind: String
        let contentVersion: String
        let variant: String
        let cacheCanonical: String
        let cacheIdentity: String

        enum CodingKeys: String, CodingKey {
            case id, scope, variant
            case scopeCanonical = "scope_canonical"
            case scopeHash = "scope_hash"
            case resourceIDKind = "resource_id_kind"
            case resourceID = "resource_id"
            case contentVersionKind = "content_version_kind"
            case contentVersion = "content_version"
            case cacheCanonical = "cache_canonical"
            case cacheIdentity = "cache_identity"
        }
    }

    struct Scope: Decodable {
        let accountID: String
        let tenantID: String
        let appID: String
        let imUID: String
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case tenantID = "tenant_id"
            case appID = "app_id"
            case imUID = "im_uid"
            case deviceID = "device_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fixtureVersion = "fixture_version"
        case vectors
    }
}

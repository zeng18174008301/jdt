import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import WenDaTong

// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN
extension AttachmentDownloadTests {
    @MainActor
    func testManagedIndexedCacheProtectsNewAndLegacyHitsWithoutChangingBytesOrIndex() async throws {
        let fixture = try permissionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.context.rootDirectory) }
        let state = fixture.state; let context = fixture.context
        var observations: [String] = []
        let bytes = Data("managed-cache-permission-fixture".utf8)
        let staged = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(bytes)
        defer { try? FileManager.default.removeItem(at: staged) }
        XCTAssertEqual(try mode(staged), 0o600)
        let sourceParentMode = try mode(staged.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: context.rootDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rootParentMode = try mode(context.rootDirectory.deletingLastPathComponent())
        for kind in MediaResourceKind.allCases {
            let metadata = permissionMetadata(context: context, fileID: "new-\(kind.rawValue)")
            let messageID = "message-\(kind.rawValue)"
            let url = try await state.commitIndexedMediaCache(temporaryURL: staged, metadata: metadata,
                resourceKind: kind, integrity: permissionIntegrity(bytes), messageID: messageID,
                conversationID: "permission-chat", context: context)
            XCTAssertEqual(url, metadata.identity(for: kind).cacheFileURL(in: context.rootDirectory,
                preferredExtension: metadata.preferredExtension(for: kind)))
            XCTAssertEqual(try mode(url), 0o600)
            XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
            XCTAssertEqual(try mode(context.rootDirectory), 0o700)
            observations.append("new \(kind.rawValue): file=\(url.path) mode=\(try mode(url)); directory=\(url.deletingLastPathComponent().path) mode=\(try mode(url.deletingLastPathComponent())); root=\(context.rootDirectory.path) mode=\(try mode(context.rootDirectory))")
            let ticket = try XCTUnwrap(state.localMessageTicket)
            let identity = try XCTUnwrap(metadata.identity(for: kind).persistentCacheIdentity)
            let oldIndex = try await state.messagePersistence.mediaCacheLookup(ticket: ticket,
                cacheIdentity: identity, messageID: messageID, offline: false)
            XCTAssertEqual(oldIndex?.entry.localState, .verifiedCached)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: context.rootDirectory.path)
            observations.append("legacy \(kind.rawValue): file=\(try mode(url)); directory=\(try mode(url.deletingLastPathComponent())); root=\(try mode(context.rootDirectory))")
            let hit = await state.lookupIndexedMediaCache(metadata: metadata, messageID: messageID,
                resourceKind: kind, integrity: permissionIntegrity(bytes), context: context, offline: false)
            XCTAssertEqual(hit, url); XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try mode(url), 0o600); XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
            XCTAssertEqual(try mode(context.rootDirectory), 0o700)
            let newIndex = try await state.messagePersistence.mediaCacheLookup(ticket: ticket,
                cacheIdentity: identity, messageID: messageID, offline: false)
            XCTAssertEqual(newIndex?.entry.cacheIdentity, oldIndex?.entry.cacheIdentity)
            XCTAssertEqual(newIndex?.entry.relativePath, oldIndex?.entry.relativePath)
            XCTAssertEqual(newIndex?.entry.verifiedChecksumSHA256, oldIndex?.entry.verifiedChecksumSHA256)
            XCTAssertEqual(newIndex?.entry.verifiedSizeBytes, Int64(bytes.count))
            XCTAssertEqual(newIndex?.entry.localState, .verifiedCached)
            observations.append("repaired \(kind.rawValue): API_hit=\(String(describing: hit)); file=\(try mode(url)); directory=\(try mode(url.deletingLastPathComponent())); root=\(try mode(context.rootDirectory)); cacheIdentity=\(identity); relativePath=\(newIndex?.entry.relativePath ?? ""); verifiedSHA=\(newIndex?.entry.verifiedChecksumSHA256 ?? "")")
            // Replacement must take the protected part's metadata, even when the previous target was 0644.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            let replacement = try await state.commitIndexedMediaCache(temporaryURL: staged, metadata: metadata,
                resourceKind: kind, integrity: permissionIntegrity(bytes), messageID: messageID,
                conversationID: "permission-chat", context: context)
            XCTAssertEqual(replacement, url); XCTAssertEqual(try mode(replacement), 0o600)
            observations.append("replacement \(kind.rawValue): API_URL=\(replacement.path), file=\(try mode(replacement))")
        }
        XCTAssertEqual(try mode(staged), 0o600); XCTAssertEqual(try Data(contentsOf: staged), bytes)
        XCTAssertEqual(try mode(staged.deletingLastPathComponent()), sourceParentMode)
        XCTAssertEqual(try mode(context.rootDirectory.deletingLastPathComponent()), rootParentMode)
        let metadata = try FileManager.default.attributesOfItem(atPath: staged.path)
        let paths = XCTAttachment(string: observations.joined(separator: "\n") + "\nstager=\(staged.path), mode=\(try mode(staged)); tmp-parent mode unchanged=\(sourceParentMode), cache-parent mode unchanged=\(rootParentMode)")
        paths.lifetime = .keepAlways; add(paths)
        let note = XCTAttachment(string: "Simulator FileProtection metadata: \(String(describing: metadata[.protectionKey])); indexed UF-auth policy and photo staging complete policy remain unchanged; no hardware claim")
        note.lifetime = .keepAlways; add(note)
    }

    @MainActor
    func testManagedCacheRejectsSymlinkTargetsWithoutChmodOfExternalBytesOrIndexSuccess() async throws {
        let f = try permissionFixture(); defer { try? FileManager.default.removeItem(at: f.context.rootDirectory) }
        let state = f.state; let context = f.context; let bytes = Data("healthy-managed-bytes".utf8)
        let staged = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(bytes)
        defer { try? FileManager.default.removeItem(at: staged) }
        let metadata = permissionMetadata(context: context, fileID: "symlink-target")
        let url = try await state.commitIndexedMediaCache(temporaryURL: staged, metadata: metadata,
            resourceKind: .preview, integrity: permissionIntegrity(bytes), messageID: "symlink-message",
            conversationID: "permission-chat", context: context)
        let directory = url.deletingLastPathComponent()
        let parked = context.rootDirectory.appendingPathComponent("owned-parked-preview")
        try FileManager.default.moveItem(at: directory, to: parked)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("external-permission-\(UUID())")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: external) }
        let externalFile = external.appendingPathComponent(url.lastPathComponent)
        try bytes.write(to: externalFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: externalFile.path)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: external)
        defer { if FileManager.default.fileExists(atPath: parked.path) { try? FileManager.default.removeItem(at: directory); try? FileManager.default.moveItem(at: parked, to: directory) } }
        let hit = await state.lookupIndexedMediaCache(metadata: metadata, messageID: "symlink-message",
            resourceKind: .preview, integrity: permissionIntegrity(bytes), context: context, offline: false)
        XCTAssertNil(hit)
        let ticket = try XCTUnwrap(state.localMessageTicket)
        let existing = try await state.messagePersistence.mediaCacheLookup(ticket: ticket,
            cacheIdentity: try XCTUnwrap(metadata.identity(for: .preview).persistentCacheIdentity),
            messageID: "symlink-message", offline: false)
        XCTAssertEqual(existing?.entry.localState, .verifiedCached)
        let rejected = permissionMetadata(context: context, fileID: "new-rejected")
        do {
            _ = try await state.commitIndexedMediaCache(temporaryURL: staged, metadata: rejected,
                resourceKind: .preview, integrity: permissionIntegrity(bytes), messageID: "rejected-message",
                conversationID: "permission-chat", context: context)
            XCTFail("unsafe managed directory must fail before file promotion or index success")
        } catch { XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain) }
        let failedIndex = try await state.messagePersistence.mediaCacheLookup(ticket: ticket,
            cacheIdentity: try XCTUnwrap(rejected.identity(for: .preview).persistentCacheIdentity),
            messageID: "rejected-message", offline: false)
        XCTAssertNil(failedIndex); XCTAssertEqual(try mode(external), 0o755); XCTAssertEqual(try mode(externalFile), 0o644)
        let note = XCTAttachment(string: "symlink-managed-path=\(directory.path); rejected new index=nil; external-file=\(externalFile.path) mode=\(try mode(externalFile)); external-directory=\(external.path) mode=\(try mode(external)); existing-index-state=\(String(describing: existing?.entry.localState))")
        note.lifetime = .keepAlways; add(note)
        XCTAssertEqual(try Data(contentsOf: externalFile), bytes)
        XCTAssertEqual(try Data(contentsOf: parked.appendingPathComponent(url.lastPathComponent)), bytes)
        try FileManager.default.removeItem(at: directory); try FileManager.default.moveItem(at: parked, to: directory)
        let recovered = await state.lookupIndexedMediaCache(metadata: metadata, messageID: "symlink-message",
            resourceKind: .preview, integrity: permissionIntegrity(bytes), context: context, offline: false)
        XCTAssertEqual(recovered, url)
    }

    @MainActor
    func testManagedCacheAttributeFailurePreservesHealthyBytesAndIndexAndRejectsNewCommit() async throws {
        let f = try permissionFixture(); defer { try? FileManager.default.removeItem(at: f.context.rootDirectory) }
        let bytes = Data("immutable-owned-cache-fixture".utf8)
        let staged = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(bytes)
        defer { try? FileManager.default.removeItem(at: staged) }
        let metadata = permissionMetadata(context: f.context, fileID: "immutable-fixture")
        let url = try await f.state.commitIndexedMediaCache(temporaryURL: staged, metadata: metadata,
            resourceKind: .original, integrity: permissionIntegrity(bytes), messageID: "immutable-message",
            conversationID: "permission-chat", context: f.context)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        do { try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path) }
        catch { throw XCTSkip("Simulator does not support the owned-file immutable syscall failure fixture: \(error)") }
        let hit = await f.state.lookupIndexedMediaCache(metadata: metadata, messageID: "immutable-message",
            resourceKind: .original, integrity: permissionIntegrity(bytes), context: f.context, offline: false)
        XCTAssertNil(hit); XCTAssertEqual(try Data(contentsOf: url), bytes); XCTAssertEqual(try mode(url), 0o644)
        let ticket = try XCTUnwrap(f.state.localMessageTicket)
        let existing = try await f.state.messagePersistence.mediaCacheLookup(ticket: ticket,
            cacheIdentity: try XCTUnwrap(metadata.identity(for: .original).persistentCacheIdentity),
            messageID: "immutable-message", offline: false)
        XCTAssertEqual(existing?.entry.localState, .verifiedCached)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .immutable: true], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path) }
        let rejected = permissionMetadata(context: f.context, fileID: "immutable-rejected")
        do {
            _ = try await f.state.commitIndexedMediaCache(temporaryURL: staged, metadata: rejected,
                resourceKind: .original, integrity: permissionIntegrity(bytes), messageID: "immutable-rejected-message",
                conversationID: "permission-chat", context: f.context)
            XCTFail("failed fchmod must not report a committed URL")
        } catch {
            var cause = error as NSError
            while let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError { cause = underlying }
            XCTAssertEqual(cause.domain, NSPOSIXErrorDomain)
            XCTAssertTrue([Int(EPERM), Int(EACCES)].contains(cause.code))
            let note = XCTAttachment(string: "real attribute failure at owned directory=\(directory.path); root error=\(cause.domain):\(cause.code); no successful URL/index; existing healthy file=\(url.path)")
            note.lifetime = .keepAlways; add(note)
        }
        let failedIndex = try await f.state.messagePersistence.mediaCacheLookup(ticket: ticket,
            cacheIdentity: try XCTUnwrap(rejected.identity(for: .original).persistentCacheIdentity),
            messageID: "immutable-rejected-message", offline: false)
        XCTAssertNil(failedIndex); XCTAssertEqual(try Data(contentsOf: url), bytes)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
        let recovered = await f.state.lookupIndexedMediaCache(metadata: metadata, messageID: "immutable-message",
            resourceKind: .original, integrity: permissionIntegrity(bytes), context: f.context, offline: false)
        XCTAssertEqual(recovered, url); XCTAssertEqual(try mode(url), 0o600); XCTAssertEqual(try mode(directory), 0o700)
    }

    func testUnverifiedManagedCachePromotesOwnedPartAndRepairsLegacyLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unverified-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("unverified-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: source) }
        let bytes = Data("unverified-cache-bytes".utf8); try bytes.write(to: source)
        let identity = MediaPipelineCore.identity(kind: .original, scope: String(repeating: "a", count: 64), fileID: "unverified", version: "v1")
        let store = MediaLayeredCacheStore(rootDirectory: root)
        let entry = try await store.saveDownloadedFile(from: source, identity: identity, preferredExtension: "bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)); XCTAssertEqual(try Data(contentsOf: entry.localURL), bytes)
        XCTAssertEqual(try mode(entry.localURL), 0o600); XCTAssertEqual(try mode(root), 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entry.localURL.path)
        let hit = await store.lookup(identity: identity, preferredExtension: "bin")
        guard case .downloaded(let url) = hit.state else { return XCTFail("legacy unverified cache hit was not repaired") }
        XCTAssertEqual(url, entry.localURL); XCTAssertEqual(try mode(url), 0o600)
    }

    @MainActor private func permissionFixture() throws -> (state: AppState, context: IOSMediaCacheScopeContext, paths: MessageDatabasePaths) {
        let context = attachmentContext(tenantID: "managed-posix-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-persistence-\(UUID())")
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"))
        let state = AppState(api: makeClient(transport: FakeAttachmentHTTPTransport(results: [])),
            realtimeClient: PostLoginSilentRealtimeTransport(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: persistence, protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
        return (state, try XCTUnwrap(state.mediaCacheScopeContext), paths)
    }
    private func permissionMetadata(context: IOSMediaCacheScopeContext, fileID: String) -> MediaResourceMetadata {
        MediaResourceMetadata(scope: context.scopeHash, fileID: fileID, version: "v1", mimeType: "application/octet-stream",
            fileExtension: "bin", thumbnailVersion: "v1", thumbnailExtension: "bin", previewVersion: "v1", previewExtension: "bin")
    }
    private func permissionIntegrity(_ bytes: Data) -> MediaFileIntegrityAuthority {
        MediaFileIntegrityAuthority(expectedSizeBytes: Int64(bytes.count), expectedSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", Int($0)) }.joined())
    }
    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap((FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
    }
}
// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END

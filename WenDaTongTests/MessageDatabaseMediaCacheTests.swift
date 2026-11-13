// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
@testable import IM4Data
import Foundation
import Darwin
import GRDB
import XCTest
@testable import WenDaTong

extension MessageDatabaseScopeTests {
    func testMediaCacheIndexEnforcesOfflineLeaseAndGenerationFence() async throws {
        let root = makeRoot()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let context = LocalMessageTestFixture.context()
        let ticket = try await coordinator.ensureTicket(context: context, sessionGeneration: 21)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = try mediaCacheRecords(
            scopeHash: ticket.scopeHash,
            messageID: "message-lease",
            fileID: "file-lease",
            authorityVersion: "1",
            lastAccessedAt: now,
            offlineUntil: now.addingTimeInterval(300)
        )
        try await coordinator.upsertMediaCache(
            ticket: ticket,
            authority: records.authority,
            entry: records.entry,
            conversationID: "conversation-lease"
        )

        let validOfflineLookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: records.entry.cacheIdentity,
            messageID: "message-lease",
            now: now.addingTimeInterval(299),
            offline: true
        )
        XCTAssertNotNil(validOfflineLookup)
        let expiredOfflineLookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: records.entry.cacheIdentity,
            messageID: "message-lease",
            now: now.addingTimeInterval(301),
            offline: true
        )
        XCTAssertNil(expiredOfflineLookup)
        let onlineLookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: records.entry.cacheIdentity,
            messageID: "message-lease",
            now: now.addingTimeInterval(301),
            offline: false
        )
        XCTAssertNotNil(onlineLookup)
        try await coordinator.renewMediaCacheAuthority(
            ticket: ticket,
            cacheIdentity: records.entry.cacheIdentity,
            messageID: "message-lease",
            authorizedAt: now.addingTimeInterval(301),
            offlineAccessUntil: now.addingTimeInterval(601)
        )
        let renewedOfflineLookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: records.entry.cacheIdentity,
            messageID: "message-lease",
            now: now.addingTimeInterval(600),
            offline: true
        )
        XCTAssertNotNil(renewedOfflineLookup)

        _ = try await coordinator.ensureTicket(context: context, sessionGeneration: 22)
        do {
            _ = try await coordinator.mediaCacheLookup(
                ticket: ticket,
                cacheIdentity: records.entry.cacheIdentity,
                messageID: "message-lease",
                now: now,
                offline: false
            )
            XCTFail("stale generation unexpectedly opened media index")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
    }

    func testMediaCacheAuthorityTombstonePreventsEqualVersionResurrection() async throws {
        let root = makeRoot()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let ticket = try await coordinator.ensureTicket(
            context: LocalMessageTestFixture.context(),
            sessionGeneration: 31
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = try mediaCacheRecords(
            scopeHash: ticket.scopeHash,
            messageID: "message-recalled",
            fileID: "file-recalled",
            authorityVersion: "18",
            lastAccessedAt: now,
            offlineUntil: now.addingTimeInterval(300)
        )
        let initialAccepted = try await coordinator.upsertMediaCache(
            ticket: ticket,
            authority: records.authority,
            entry: records.entry,
            conversationID: "conversation-recalled"
        )
        XCTAssertTrue(initialAccepted)
        _ = try await coordinator.invalidateMediaCache(
            ticket: ticket,
            messageID: "message-recalled",
            state: .recalled,
            authorityVersion: "18",
            at: now.addingTimeInterval(1)
        )
        let resurrectionAccepted = try await coordinator.upsertMediaCache(
            ticket: ticket,
            authority: records.authority,
            entry: records.entry,
            conversationID: "conversation-recalled"
        )
        XCTAssertFalse(resurrectionAccepted)
        let recalledLookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: records.entry.cacheIdentity,
            messageID: "message-recalled",
            now: now,
            offline: false
        )
        XCTAssertNil(recalledLookup)
    }

    func testMediaCacheTombstoneBeforeFirstCommitRejectsEqualActiveAuthority() async throws {
        let root = makeRoot()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let ticket = try await coordinator.ensureTicket(
            context: LocalMessageTestFixture.context(),
            sessionGeneration: 36
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hugeVersion = "184467440737095516161844674407370955161"
        _ = try await coordinator.invalidateMediaCache(
            ticket: ticket,
            messageID: "message-pre-recalled",
            state: .recalled,
            authorityVersion: hugeVersion,
            at: now
        )
        let records = try mediaCacheRecords(
            scopeHash: ticket.scopeHash,
            messageID: "message-pre-recalled",
            fileID: "file-pre-recalled",
            authorityVersion: hugeVersion,
            lastAccessedAt: now.addingTimeInterval(1),
            offlineUntil: now.addingTimeInterval(300)
        )

        let accepted = try await coordinator.upsertMediaCache(
            ticket: ticket,
            authority: records.authority,
            entry: records.entry,
            conversationID: "conversation-pre-recalled"
        )
        XCTAssertFalse(accepted)
        let lookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: records.entry.cacheIdentity,
            messageID: "message-pre-recalled",
            now: now.addingTimeInterval(2),
            offline: false
        )
        XCTAssertNil(lookup)
    }

    func testMediaCacheAuthorityComparesArbitraryLengthUnsignedVersions() {
        let huge = "184467440737095516161844674407370955161"
        let larger = "184467440737095516161844674407370955162"
        XCTAssertTrue(
            SQLiteMessageRepository.shouldAcceptMediaCacheAuthority(
                currentState: .recalled,
                currentVersion: huge,
                incomingState: .active,
                incomingVersion: larger
            )
        )
        XCTAssertFalse(
            SQLiteMessageRepository.shouldAcceptMediaCacheAuthority(
                currentState: .recalled,
                currentVersion: huge,
                incomingState: .active,
                incomingVersion: "000" + huge
            )
        )
    }

    func testMediaCacheLRUProtectsPinnedOrInUseEntries() async throws {
        let root = makeRoot()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let ticket = try await coordinator.ensureTicket(
            context: LocalMessageTestFixture.context(),
            sessionGeneration: 41
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, protected) in [(0, false), (1, true), (2, false)] {
            var records = try mediaCacheRecords(
                scopeHash: ticket.scopeHash,
                messageID: "message-lru-\(index)",
                fileID: "file-lru-\(index)",
                authorityVersion: "1",
                lastAccessedAt: now.addingTimeInterval(Double(index)),
                offlineUntil: now.addingTimeInterval(300)
            )
            if protected {
                records.entry = IOSMediaCacheEntryRecord(
                    scopeHash: records.entry.scopeHash,
                    cacheIdentity: records.entry.cacheIdentity,
                    attachmentID: records.entry.attachmentID,
                    variant: records.entry.variant,
                    relativePath: records.entry.relativePath,
                    localState: records.entry.localState,
                    sizeBytes: records.entry.sizeBytes,
                    verifiedSizeBytes: records.entry.verifiedSizeBytes,
                    verifiedChecksumSHA256: records.entry.verifiedChecksumSHA256,
                    pinnedByUser: false,
                    protectionReason: "active_preview",
                    createdAt: records.entry.createdAt,
                    lastAccessedAt: records.entry.lastAccessedAt
                )
            }
            try await coordinator.upsertMediaCache(
                ticket: ticket,
                authority: records.authority,
                entry: records.entry,
                conversationID: "conversation-lru"
            )
        }
        let stats = try await coordinator.mediaCacheStatistics(ticket: ticket)
        XCTAssertEqual(stats.fileCount, 3)
        let candidates = try await coordinator.mediaCachePruneCandidates(
            ticket: ticket,
            bytesToFree: 2
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { !$0.relativePath.contains("file-lru-1") })
    }

    func testMediaCacheRecallPreservesSharedReferenceUntilLastMessageIsRevoked() async throws {
        let root = makeRoot()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let ticket = try await coordinator.ensureTicket(
            context: LocalMessageTestFixture.context(),
            sessionGeneration: 51
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try mediaCacheRecords(
            scopeHash: ticket.scopeHash,
            messageID: "message-shared-a",
            fileID: "file-shared",
            authorityVersion: "4",
            lastAccessedAt: now,
            offlineUntil: now.addingTimeInterval(300)
        )
        var secondAuthority = first.authority
        secondAuthority = IOSMediaCacheAuthorityRecord(
            scopeHash: secondAuthority.scopeHash,
            messageID: "message-shared-b",
            attachmentID: secondAuthority.attachmentID,
            identity: secondAuthority.identity,
            mimeType: secondAuthority.mimeType,
            sizeBytes: secondAuthority.sizeBytes,
            checksumSHA256: secondAuthority.checksumSHA256,
            state: secondAuthority.state,
            authorityVersion: secondAuthority.authorityVersion,
            lastAuthorizedAt: secondAuthority.lastAuthorizedAt,
            offlineAccessUntil: secondAuthority.offlineAccessUntil,
            createdAt: secondAuthority.createdAt,
            updatedAt: secondAuthority.updatedAt
        )
        try await coordinator.upsertMediaCache(
            ticket: ticket,
            authority: first.authority,
            entry: first.entry,
            conversationID: "conversation-shared-a"
        )
        try await coordinator.upsertMediaCache(
            ticket: ticket,
            authority: secondAuthority,
            entry: first.entry,
            conversationID: "conversation-shared-b"
        )

        let firstPrune = try await coordinator.invalidateMediaCache(
            ticket: ticket,
            messageID: "message-shared-a",
            state: .recalled,
            authorityVersion: "4",
            at: now.addingTimeInterval(1)
        )
        XCTAssertTrue(firstPrune.isEmpty)
        let sharedLookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: first.entry.cacheIdentity,
            messageID: "message-shared-b",
            now: now,
            offline: false
        )
        XCTAssertNotNil(sharedLookup)
        let recalledLookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: first.entry.cacheIdentity,
            messageID: "message-shared-a",
            now: now,
            offline: false
        )
        XCTAssertNil(recalledLookup)

        let finalPrune = try await coordinator.invalidateMediaCache(
            ticket: ticket,
            messageID: "message-shared-b",
            state: .deleted,
            authorityVersion: "4",
            at: now.addingTimeInterval(2)
        )
        XCTAssertEqual(finalPrune.map(\.cacheIdentity), [first.entry.cacheIdentity])
        let deletedLookup = try await coordinator.mediaCacheLookup(
            ticket: ticket,
            cacheIdentity: first.entry.cacheIdentity,
            messageID: "message-shared-b",
            now: now,
            offline: false
        )
        XCTAssertNil(deletedLookup)
    }

    func testVersionTwoDatabaseMigratesInPlaceToUnifiedCacheEntrySchema() throws {
        let root = makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("migration.sqlite").path)
        var versionTwoMigrator = DatabaseMigrator()
        versionTwoMigrator.registerMigration("local-message-v1") { db in
            try db.execute(sql: MessageDatabaseSchema.createVersionOneSQL)
        }
        versionTwoMigrator.registerMigration("local-message-v2-profile-contact") { db in
            try db.execute(sql: MessageDatabaseSchema.createProfileContactProjectionSQL)
        }
        try versionTwoMigrator.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_cache (
                    cache_key, channel_key, message_id, file_id,
                    relative_path, size_bytes, last_access_at, rebuildable
                ) VALUES ('legacy-key', 'channel', 'message', 'file', 'legacy/path', 12, 1, 1)
                """
            )
        }

        try MessageDatabaseMigrations.migrator().migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.tableExists("attachment_meta"))
            XCTAssertTrue(try db.tableExists("cache_entry"))
            XCTAssertTrue(try db.tableExists("cache_reference"))
            XCTAssertTrue(try db.tableExists("media_transfer_task"))
            XCTAssertTrue(try db.tableExists("media_authority_tombstone"))
            XCTAssertFalse(try db.tableExists("media_cache"))
        }
    }

    func testExistingVersionThreeDatabaseBackfillsReferenceAuthorityInVersionFour() throws {
        let root = makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("migration-v3.sqlite").path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("local-message-v1") { db in
            try db.execute(sql: MessageDatabaseSchema.createVersionOneSQL)
        }
        legacyMigrator.registerMigration("local-message-v2-profile-contact") { db in
            try db.execute(sql: MessageDatabaseSchema.createProfileContactProjectionSQL)
        }
        legacyMigrator.registerMigration("local-message-v3-media-cache") { db in
            try db.execute(sql: MessageDatabaseSchema.createMediaCacheVersionThreeSQL)
            try db.execute(sql: "DROP TABLE cache_reference")
            try db.execute(
                sql: """
                CREATE TABLE cache_reference (
                    scope_hash TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    conversation_key TEXT NOT NULL,
                    cache_identity TEXT NOT NULL REFERENCES cache_entry(cache_identity) ON DELETE CASCADE,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(scope_hash, message_id, cache_identity)
                );
                CREATE INDEX cache_reference_conversation
                ON cache_reference(scope_hash, conversation_key);
                DROP TABLE media_authority_tombstone;
                """
            )
        }
        try legacyMigrator.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO attachment_meta (
                    scope_hash, message_id, attachment_id, resource_id_kind, resource_id,
                    content_version_kind, content_version, variant, mime_type, size_bytes,
                    authority_state, authority_version, updated_at
                ) VALUES (
                    'scope-v3', 'message-v3', 'attachment-v3', 'file_id', 'file-v3',
                    'version', 'v1', 'original', 'application/octet-stream', 3,
                    'active', '1', 1
                )
                """
            )
            try db.execute(
                sql: """
                INSERT INTO cache_entry (
                    scope_hash, cache_identity, attachment_id, variant, relative_path,
                    local_state, size_bytes, created_at, last_accessed_at
                ) VALUES (
                    'scope-v3', 'cache-v3', 'attachment-v3', 'original', 'original/cache-v3',
                    'verified_cached', 3, 1, 1
                )
                """
            )
            try db.execute(
                sql: """
                INSERT INTO cache_reference (
                    scope_hash, message_id, conversation_key, cache_identity, created_at
                ) VALUES ('scope-v3', 'message-v3', 'conversation-v3', 'cache-v3', 1)
                """
            )
        }

        try MessageDatabaseMigrations.migrator().migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.columns(in: "cache_reference").contains(where: { $0.name == "attachment_id" }))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT attachment_id FROM cache_reference WHERE cache_identity = 'cache-v3'"),
                "attachment-v3"
            )
            XCTAssertTrue(try db.tableExists("media_authority_tombstone"))
        }
    }

    func testFrozenStateTransitionVectorsDriveAuthorityAndOfflinePolicy() throws {
        let fixture = try JSONDecoder().decode(
            FrozenMediaCacheStateFixture.self,
            from: Data(contentsOf: cacheContractFixtureURL("state-transition-vectors.json"))
        )
        XCTAssertEqual(fixture.fixtureVersion, 1)
        for vector in fixture.authorityMergeCases {
            let currentState = try XCTUnwrap(MediaCacheAuthorityState(rawValue: vector.current.state), vector.id)
            let incomingState = try XCTUnwrap(MediaCacheAuthorityState(rawValue: vector.incoming.state), vector.id)
            let accepted = SQLiteMessageRepository.shouldAcceptMediaCacheAuthority(
                currentState: currentState,
                currentVersion: vector.current.version,
                incomingState: incomingState,
                incomingVersion: vector.incoming.version
            )
            XCTAssertEqual(accepted, vector.expected == "accept_incoming", vector.id)
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = MediaPipelineCore.identity(
            kind: .original,
            scope: String(repeating: "a", count: 64),
            fileID: "fixture-file",
            version: "v1"
        )
        for vector in fixture.offlineCases {
            let state = try XCTUnwrap(MediaCacheAuthorityState(rawValue: vector.authorityState), vector.id)
            let localState = try XCTUnwrap(MediaCacheLocalState(rawValue: vector.localState), vector.id)
            let offlineUntil = vector.tenantPolicy == "high_sensitivity"
                ? nil
                : now.addingTimeInterval(TimeInterval(vector.leaseSecondsRemaining))
            let authority = IOSMediaCacheAuthorityRecord(
                scopeHash: identity.scope,
                messageID: vector.id,
                attachmentID: "fixture-file",
                identity: identity,
                mimeType: "application/octet-stream",
                sizeBytes: 1,
                checksumSHA256: nil,
                state: state,
                authorityVersion: "1",
                lastAuthorizedAt: now,
                offlineAccessUntil: offlineUntil,
                createdAt: now,
                updatedAt: now
            )
            let canOpen = localState == .verifiedCached
                && authority.permitsOpen(now: now, allowOffline: true)
            XCTAssertEqual(canOpen, vector.expectedOpen, vector.id)
        }
    }

    private func mediaCacheRecords(
        scopeHash: String,
        messageID: String,
        fileID: String,
        authorityVersion: String,
        lastAccessedAt: Date,
        offlineUntil: Date
    ) throws -> (authority: IOSMediaCacheAuthorityRecord, entry: IOSMediaCacheEntryRecord) {
        let checksum = String(repeating: String(format: "%x", abs(fileID.hashValue) % 16), count: 64)
        let identity = MediaPipelineCore.identity(
            kind: .original,
            scope: scopeHash,
            fileID: fileID,
            checksumSHA256: checksum,
            variant: .original,
            mimeType: "application/octet-stream",
            sizeBytes: 1
        )
        let cacheIdentity = try XCTUnwrap(identity.persistentCacheIdentity)
        let authority = IOSMediaCacheAuthorityRecord(
            scopeHash: scopeHash,
            messageID: messageID,
            attachmentID: fileID,
            identity: identity,
            mimeType: "application/octet-stream",
            sizeBytes: 1,
            checksumSHA256: checksum,
            state: .active,
            authorityVersion: authorityVersion,
            lastAuthorizedAt: lastAccessedAt,
            offlineAccessUntil: offlineUntil,
            createdAt: lastAccessedAt,
            updatedAt: lastAccessedAt
        )
        let entry = IOSMediaCacheEntryRecord(
            scopeHash: scopeHash,
            cacheIdentity: cacheIdentity,
            attachmentID: fileID,
            variant: .original,
            relativePath: "originals/\(fileID)-\(cacheIdentity).bin",
            localState: .verifiedCached,
            sizeBytes: 1,
            verifiedSizeBytes: 1,
            verifiedChecksumSHA256: checksum,
            pinnedByUser: false,
            protectionReason: "",
            createdAt: lastAccessedAt,
            lastAccessedAt: lastAccessedAt
        )
        return (authority, entry)
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

private struct FrozenMediaCacheStateFixture: Decodable {
    let fixtureVersion: Int
    let authorityMergeCases: [AuthorityMergeCase]
    let offlineCases: [OfflineCase]

    struct AuthorityMergeCase: Decodable {
        let id: String
        let current: StateVersion
        let incoming: StateVersion
        let expected: String
    }

    struct StateVersion: Decodable {
        let state: String
        let version: String
    }

    struct OfflineCase: Decodable {
        let id: String
        let authorityState: String
        let leaseSecondsRemaining: Int
        let localState: String
        let tenantPolicy: String?
        let expectedOpen: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case authorityState = "authority_state"
            case leaseSecondsRemaining = "lease_seconds_remaining"
            case localState = "local_state"
            case tenantPolicy = "tenant_policy"
            case expectedOpen = "expected_open"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fixtureVersion = "fixture_version"
        case authorityMergeCases = "authority_merge_cases"
        case offlineCases = "offline_cases"
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

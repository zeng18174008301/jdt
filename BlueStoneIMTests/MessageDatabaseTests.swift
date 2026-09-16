import Foundation
import Darwin
import GRDB
import XCTest
@testable import BlueStoneIM

private actor MessageDatabaseTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func opened() -> Bool {
        isOpen
    }
}

final class MessageDatabaseScopeTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testScopeHashIsStableAcrossOneHundredLoginCyclesAndSeparatesEveryIdentityPart() throws {
        let base = LocalMessageTestFixture.context(actor: "actor-a", device: "device-stable")
        let expected = try LocalMessageScope(context: base).scopeHash
        for _ in 0..<100 {
            XCTAssertEqual(try LocalMessageScope(context: base).scopeHash, expected)
        }
        XCTAssertNotEqual(
            expected,
            try LocalMessageScope(context: LocalMessageTestFixture.context(actor: "actor-b", device: "device-stable")).scopeHash
        )
        XCTAssertNotEqual(
            expected,
            try LocalMessageScope(context: LocalMessageTestFixture.context(actor: "actor-a", device: "device-other")).scopeHash
        )
        XCTAssertNotEqual(
            expected,
            try LocalMessageScope(accountID: "account", tenantID: "tenant-b", appID: "app", actorID: "actor-a", deviceID: "device-stable").scopeHash
        )
        XCTAssertNotEqual(
            expected,
            try LocalMessageScope(accountID: "account", tenantID: "tenant", appID: "app-b", actorID: "actor-a", deviceID: "device-stable").scopeHash
        )
    }

    func testScopeRejectsMissingIdentityInsteadOfOpeningSharedFallbackDatabase() {
        XCTAssertThrowsError(
            try LocalMessageScope(accountID: "", tenantID: "tenant", appID: "app", actorID: "actor", deviceID: "device")
        )
        XCTAssertThrowsError(
            try LocalMessageScope(accountID: "account", tenantID: "tenant", appID: "app", actorID: "actor", deviceID: "")
        )
        XCTAssertThrowsError(
            try LocalMessageScope(accountID: "account", tenantID: " tenant", appID: "app", actorID: "actor", deviceID: "device")
        )
    }

    func testScopeHashMatchesFrozenCrossPlatformFixture() throws {
        let scope = try LocalMessageScope(
            accountID: "acct-001",
            tenantID: "tenant-001",
            appID: "wenxintong-web",
            actorID: "im-user-001",
            deviceID: "device-profile-001"
        )
        XCTAssertEqual(
            String(data: scope.canonicalData, encoding: .utf8),
            "10:account_id:8:acct-001|9:tenant_id:10:tenant-001|6:app_id:14:wenxintong-web|6:im_uid:11:im-user-001|9:device_id:18:device-profile-001"
        )
        XCTAssertEqual(
            scope.scopeHash,
            "e509910b43a3327ea9c268a03a596337ba6a60074e314d666ad8795c9ef66494"
        )
    }

    func testConversationSnapshotUsesExplicitLocalMutationProjectionWhenProvided() {
        let conversation = LocalMessageTestFixture.conversation(
            id: "projected-conversation",
            sequences: [1, 2, 3]
        )
        let projected = Array(conversation.messages.suffix(1))

        let snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-projected-conversation",
            channelType: "person",
            currentActorID: "actor-a",
            projectedMessages: projected
        )

        XCTAssertEqual(snapshot.messages.map(\.id), projected.map(\.id))
        XCTAssertEqual(snapshot.metadata.id, conversation.id)
    }

    func testABARoutingNeverCrossesDatabasesAndPurgeIsExact() async throws {
        let root = makeRoot()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let contextA = LocalMessageTestFixture.context(actor: "actor-a")
        let contextB = LocalMessageTestFixture.context(actor: "actor-b")
        let loadedA = try await coordinator.activateAndLoad(context: contextA, sessionGeneration: 1)
        _ = try await coordinator.persist(
            ticket: loadedA.ticket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "a-only", count: 7, actor: "actor-a")],
            source: .history,
            revision: 1
        )

        let loadedB = try await coordinator.activateAndLoad(context: contextB, sessionGeneration: 2)
        XCTAssertTrue(loadedB.conversations.isEmpty)
        _ = try await coordinator.persist(
            ticket: loadedB.ticket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "b-only", count: 7, actor: "actor-b")],
            source: .history,
            revision: 1
        )

        let returnedA = try await coordinator.activateAndLoad(context: contextA, sessionGeneration: 3)
        XCTAssertEqual(returnedA.conversations.map(\.id), ["a-only"])
        XCTAssertFalse(returnedA.conversations.contains(where: { $0.id == "b-only" }))

        try await coordinator.purgeExactScope(context: contextA)
        let purgedA = try await coordinator.activateAndLoad(context: contextA, sessionGeneration: 4)
        XCTAssertTrue(purgedA.conversations.isEmpty)
        let retainedB = try await coordinator.activateAndLoad(context: contextB, sessionGeneration: 5)
        XCTAssertEqual(retainedB.conversations.map(\.id), ["b-only"])
    }

    func testApplicationSupportIsExcludedFromBackupAndMediaUsesCaches() throws {
        let root = makeRoot()
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        try paths.prepare()
        XCTAssertTrue(try paths.isBackupExcluded())
        XCTAssertTrue(paths.databaseURL.path.contains("/support/BlueStoneIM/LocalMessage/\(scope.scopeHash)/"))
        XCTAssertTrue(paths.mediaScopeDirectory.path.contains("/caches/BlueStoneIM/Media/\(scope.scopeHash)"))
        XCTAssertFalse(paths.databaseURL.path.contains("Caches/BlueStoneIM/Media"))
        XCTAssertEqual(
            try paths.mediaScopeDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
        let mediaAttributes = try FileManager.default.attributesOfItem(atPath: paths.mediaScopeDirectory.path)
        #if targetEnvironment(simulator)
        XCTAssertTrue(
            mediaAttributes[.protectionKey] == nil
                || mediaAttributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication
        )
        #else
        XCTAssertEqual(
            mediaAttributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
        XCTAssertEqual(
            try paths.resolveMediaRelativePath("original/identity.bin").path,
            paths.mediaScopeDirectory.appendingPathComponent("original/identity.bin").path
        )
        XCTAssertThrowsError(try paths.resolveMediaRelativePath("../other-scope/file.bin"))
        XCTAssertThrowsError(try paths.resolveMediaRelativePath("/absolute/file.bin"))
    }

    func testLegacyScopeDirectoryAndRowsMigrateToFrozenScopeHash() async throws {
        let root = makeRoot()
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        try FileManager.default.createDirectory(
            at: paths.legacyScopeDirectory,
            withIntermediateDirectories: true
        )
        let legacyDatabaseURL = paths.legacyScopeDirectory
            .appendingPathComponent(MessageDatabaseSchema.databaseFileName, isDirectory: false)
        let queue = try DatabaseQueue(path: legacyDatabaseURL.path)
        try MessageDatabaseMigrations.migrator().migrate(queue)
        let now = Date().timeIntervalSince1970
        let payload = Data("{}".utf8)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO scope_meta (
                    id, schema_version, scope_hash, canonical_scope_digest,
                    created_at, last_open_at
                ) VALUES (1, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    MessageDatabaseSchema.currentVersion,
                    scope.legacyLocalMessageScopeHash,
                    scope.legacyLocalMessageScopeHash,
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO conversation (
                    conversation_key, channel_type, channel_id, payload, updated_at
                ) VALUES ('legacy-conversation', 'group', 'legacy-channel', ?, ?)
                """,
                arguments: [payload, now]
            )
            try db.execute(
                sql: """
                INSERT INTO message (
                    local_row_id, conversation_key, channel_key, message_id,
                    sender_uid, content_type, body, payload, updated_at
                ) VALUES (
                    'legacy-row', 'legacy-conversation', 'legacy-channel', 'legacy-message',
                    'peer', 'text', 'legacy body', ?, ?
                )
                """,
                arguments: [payload, now]
            )
            try db.execute(
                sql: """
                INSERT INTO outbox (
                    client_msg_no, operation_kind, conversation_key, channel_key,
                    channel_type, scope_hash, payload, state, created_at, updated_at
                ) VALUES (
                    'legacy-client', 'message_send', 'legacy-conversation', 'legacy-channel',
                    'group', ?, ?, 'pending', ?, ?
                )
                """,
                arguments: [scope.legacyLocalMessageScopeHash, payload, now, now]
            )
        }
        try queue.close()

        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(diagnostics.scopeHash, scope.scopeHash)
        XCTAssertEqual(diagnostics.conversationCount, 1)
        XCTAssertEqual(diagnostics.messageCount, 1)
        XCTAssertEqual(diagnostics.outboxCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyScopeDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.databaseURL.path))
    }

    func testSameScopeSessionGenerationRebindFencesOldAsyncWriterTicket() async throws {
        let root = makeRoot()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let context = LocalMessageTestFixture.context()
        let first = try await coordinator.ensureTicket(context: context, sessionGeneration: 10)
        let second = try await coordinator.ensureTicket(context: context, sessionGeneration: 11)
        XCTAssertEqual(first.scopeHash, second.scopeHash)
        XCTAssertNotEqual(first.coordinatorEpoch, second.coordinatorEpoch)
        do {
            _ = try await coordinator.persist(
                ticket: first,
                snapshots: [LocalMessageTestFixture.snapshot(id: "stale-generation", count: 1)],
                source: .realtime,
                revision: 1
            )
            XCTFail("old session generation unexpectedly committed")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }

        let forgedOldGeneration = LocalMessageSessionTicket(
            scopeHash: second.scopeHash,
            sessionGeneration: first.sessionGeneration,
            coordinatorEpoch: second.coordinatorEpoch
        )
        do {
            _ = try await coordinator.persist(
                ticket: forgedOldGeneration,
                snapshots: [LocalMessageTestFixture.snapshot(id: "forged-old-generation", count: 1)],
                source: .realtime,
                revision: 2
            )
            XCTFail("matching epoch must not bypass the generation fence")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }

        do {
            _ = try await coordinator.ensureTicket(context: context, sessionGeneration: 10)
            XCTFail("a delayed lower generation must not replace the current writer")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        let stillCurrent = try await coordinator.ensureTicket(context: context, sessionGeneration: 11)
        XCTAssertEqual(stillCurrent.coordinatorEpoch, second.coordinatorEpoch)
    }

    func testGenerationBoundPurgeRetiresOldHandleWithoutDeletingNewerRebind() async throws {
        let root = makeRoot()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let context = LocalMessageTestFixture.context()
        let oldTicket = try await coordinator.ensureTicket(context: context, sessionGeneration: 30)
        let retiredOldScope = try await coordinator.purgeExactScope(context: context, through: 30)
        XCTAssertTrue(retiredOldScope)

        let currentTicket = try await coordinator.ensureTicket(context: context, sessionGeneration: 31)
        _ = try await coordinator.persist(
            ticket: currentTicket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "current-after-purge", count: 1)],
            source: .history,
            revision: 1
        )
        let delayedOldPurge = try await coordinator.purgeExactScope(context: context, through: 30)
        XCTAssertFalse(delayedOldPurge)

        let loaded = try await coordinator.activateAndLoad(context: context, sessionGeneration: 31)
        XCTAssertEqual(loaded.conversations.map(\.id), ["current-after-purge"])
        do {
            _ = try await coordinator.persist(
                ticket: oldTicket,
                snapshots: [LocalMessageTestFixture.snapshot(id: "retired-writer", count: 1)],
                source: .realtime,
                revision: 2
            )
            XCTFail("retired repository handle must not accept its old ticket")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
    }

    func testScopePurgeSerializesNewGenerationActivationUntilDeletionFinishes() async throws {
        let root = makeRoot()
        let purgeEntered = MessageDatabaseTestGate()
        let allowPurge = MessageDatabaseTestGate()
        let activationStarted = MessageDatabaseTestGate()
        let activationCompleted = MessageDatabaseTestGate()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"),
            scopePurgeBarrier: {
                await purgeEntered.open()
                await allowPurge.wait()
            }
        )
        let context = LocalMessageTestFixture.context()
        _ = try await coordinator.ensureTicket(context: context, sessionGeneration: 40)

        let purgeTask = Task {
            try await coordinator.purgeExactScope(context: context, through: 40)
        }
        await purgeEntered.wait()
        let activationTask = Task {
            await activationStarted.open()
            let ticket = try await coordinator.ensureTicket(context: context, sessionGeneration: 41)
            await activationCompleted.open()
            return ticket
        }
        await activationStarted.wait()
        await Task.yield()
        let completedBeforeDeletion = await activationCompleted.opened()
        XCTAssertFalse(completedBeforeDeletion)

        await allowPurge.open()
        let purged = try await purgeTask.value
        XCTAssertTrue(purged)
        let currentTicket = try await activationTask.value
        _ = try await coordinator.persist(
            ticket: currentTicket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "activated-after-purge", count: 1)],
            source: .history,
            revision: 1
        )
        let loaded = try await coordinator.activateAndLoad(context: context, sessionGeneration: 41)
        XCTAssertEqual(loaded.conversations.map(\.id), ["activated-after-purge"])
    }

    func testScheduledLogoutPurgeFencesImmediateSameScopeReactivation() async throws {
        let root = makeRoot()
        let preparationEntered = MessageDatabaseTestGate()
        let allowPreparation = MessageDatabaseTestGate()
        let activationStarted = MessageDatabaseTestGate()
        let activationCompleted = MessageDatabaseTestGate()
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let context = LocalMessageTestFixture.context()
        let oldTicket = try await coordinator.ensureTicket(context: context, sessionGeneration: 50)
        _ = try await coordinator.persist(
            ticket: oldTicket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "must-be-purged", count: 1)],
            source: .history,
            revision: 1
        )

        let purgeTask = try coordinator.schedulePurgeExactScope(
            context: context,
            through: 50,
            beforePurge: {
                await preparationEntered.open()
                await allowPreparation.wait()
            }
        )
        await preparationEntered.wait()
        let activationTask = Task {
            await activationStarted.open()
            let result = try await coordinator.activateAndLoad(
                context: context,
                sessionGeneration: 51
            )
            await activationCompleted.open()
            return result
        }
        await activationStarted.wait()
        await Task.yield()
        let completedBeforeScheduledPurge = await activationCompleted.opened()
        XCTAssertFalse(completedBeforeScheduledPurge)

        await allowPreparation.open()
        let purged = await purgeTask.value
        XCTAssertTrue(purged)
        let reactivated = try await activationTask.value
        XCTAssertTrue(reactivated.conversations.isEmpty)
        XCTAssertEqual(reactivated.ticket.sessionGeneration, 51)
    }

    func testPendingLogoutCleanupTombstoneSurvivesCoordinatorRelaunch() async throws {
        let root = makeRoot()
        let support = root.appendingPathComponent("support")
        let caches = root.appendingPathComponent("caches")
        let context = LocalMessageTestFixture.context()
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: support,
            cachesBase: caches
        )
        let firstCoordinator = MessagePersistenceCoordinator(
            applicationSupportBase: support,
            cachesBase: caches
        )
        let oldTicket = try await firstCoordinator.ensureTicket(
            context: context,
            sessionGeneration: 60
        )
        _ = try await firstCoordinator.persist(
            ticket: oldTicket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "pre-logout", count: 1)],
            source: .history,
            revision: 1
        )
        let oldMediaURL = paths.mediaScopeDirectory.appendingPathComponent("old.bin")
        try Data("old-media".utf8).write(to: oldMediaURL, options: .atomic)
        try FileManager.default.createDirectory(
            at: paths.legacyScopeDirectory,
            withIntermediateDirectories: true
        )
        let oldLegacyURL = paths.legacyScopeDirectory.appendingPathComponent("legacy.sqlite")
        try Data("old-legacy".utf8).write(to: oldLegacyURL, options: .atomic)

        try firstCoordinator.persistPendingScopeCleanup(context: context)
        XCTAssertTrue(try firstCoordinator.hasPendingScopeCleanup(context: context))
        await firstCoordinator.detach(ticket: oldTicket)

        _ = MessagePersistenceCoordinator(
            applicationSupportBase: support,
            cachesBase: caches
        )
        let markerURL = support
            .appendingPathComponent("BlueStoneIM/LocalMessagePendingCleanup", isDirectory: true)
            .appendingPathComponent("\(scope.scopeHash).pending", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.scopeDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLegacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldMediaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testCleanupTombstoneWriteFailureQuarantinesScopeBeforeReturning() async throws {
        let root = makeRoot()
        let support = root.appendingPathComponent("support")
        let caches = root.appendingPathComponent("caches")
        let context = LocalMessageTestFixture.context()
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: support,
            cachesBase: caches
        )
        let firstCoordinator = MessagePersistenceCoordinator(
            applicationSupportBase: support,
            cachesBase: caches,
            forceCleanupTombstoneFailureForTesting: true
        )
        let oldTicket = try await firstCoordinator.ensureTicket(
            context: context,
            sessionGeneration: 70
        )
        _ = try await firstCoordinator.persist(
            ticket: oldTicket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "quarantine-on-marker-failure", count: 1)],
            source: .history,
            revision: 1
        )
        let oldMediaURL = paths.mediaScopeDirectory.appendingPathComponent("old.bin")
        try Data("old-media".utf8).write(to: oldMediaURL, options: .atomic)

        try firstCoordinator.persistPendingScopeCleanup(context: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.scopeDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.mediaScopeDirectory.path))
        XCTAssertTrue(try firstCoordinator.hasPendingScopeCleanup(context: context))
        await firstCoordinator.detach(ticket: oldTicket)

        _ = MessagePersistenceCoordinator(
            applicationSupportBase: support,
            cachesBase: caches
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldMediaURL.path))
        XCTAssertFalse(try paths.hasPendingCleanupResidue())
    }

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

    func testExactScopePurgeRemovesCanonicalAndLegacyDatabaseDirectories() throws {
        let root = makeRoot()
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.scopeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.legacyScopeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.mediaScopeDirectory, withIntermediateDirectories: true)
        try Data("canonical".utf8).write(to: paths.databaseURL, options: .atomic)
        try Data("legacy".utf8).write(
            to: paths.legacyScopeDirectory.appendingPathComponent("messages.sqlite"),
            options: .atomic
        )

        try paths.purgeExactScope()

        XCTAssertFalse(fileManager.fileExists(atPath: paths.scopeDirectory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: paths.legacyScopeDirectory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: paths.mediaScopeDirectory.path))
        try paths.prepare()
        XCTAssertTrue(fileManager.fileExists(atPath: paths.scopeDirectory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: paths.databaseURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: paths.legacyScopeDirectory.path))
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

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDatabaseScopeTests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
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

final class MessageDatabaseSemanticsTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testBurstImportIsIdempotentForSevenFiftyAndTwoHundredMessages() async throws {
        for count in [7, 50, 200] {
            let repository = try await makeRepository(suffix: "burst-\(count)")
            let ordered = LocalMessageTestFixture.snapshot(id: "conversation-\(count)", count: count)
            var shuffledModel = ordered.metadata.model
            shuffledModel.messages = Array(shuffledModel.messages.reversed()) + shuffledModel.messages.prefix(3)
            let shuffled = LocalMessageConversationSnapshot(
                conversation: shuffledModel,
                channelID: "channel-conversation-\(count)",
                channelType: "person",
                currentActorID: "actor-a"
            )
            _ = try await repository.persistProjection(
                [shuffled],
                source: .realtime,
                revision: 1,
                replaceMissingConversations: false
            )
            _ = try await repository.persistProjection(
                [ordered],
                source: .history,
                revision: 2,
                replaceMissingConversations: false
            )
            let diagnostics = try await repository.diagnostics()
            XCTAssertEqual(diagnostics.messageCount, count)
            XCTAssertEqual(diagnostics.gapCount, 0)
            let loaded = try await repository.loadInitialConversations(limit: 10, messagesPerConversation: 200)
            let sequences = try XCTUnwrap(loaded.0.first).messages.map(\.channelSeq)
            XCTAssertEqual(sequences, Array(1...count).map(Int64.init))
            XCTAssertEqual(Set(sequences).count, count)
        }
    }

    func testGapClampsReadAndDeliveryAcknowledgementsUntilHistoryArrives() async throws {
        let repository = try await makeRepository(suffix: "gap")
        let gapped = LocalMessageTestFixture.snapshot(
            id: "gap-conversation",
            sequences: [1, 2, 3, 4, 8],
            coveredThrough: 4,
            lastMsgSeq: 8,
            unread: 4
        )
        _ = try await repository.persistProjection(
            [gapped], source: .realtime, revision: 1, replaceMissingConversations: false
        )
        let desiredRead = try await repository.recordAckDesired(channelKey: gapped.channelID, type: "read", desiredSeq: 8)
        let desiredDelivery = try await repository.recordAckDesired(channelKey: gapped.channelID, type: "delivery", desiredSeq: 8)
        XCTAssertEqual(desiredRead, 4)
        XCTAssertEqual(desiredDelivery, 4)
        try await repository.confirmAck(channelKey: gapped.channelID, type: "read", confirmedSeq: 8)
        let checkpoint = try await repository.ackCheckpoint(channelKey: gapped.channelID, type: "read")
        XCTAssertEqual(checkpoint.desired, 4)
        XCTAssertEqual(checkpoint.confirmed, 4)
        let gappedDiagnostics = try await repository.diagnostics()
        XCTAssertEqual(gappedDiagnostics.gapCount, 1)

        let repaired = LocalMessageTestFixture.snapshot(
            id: "gap-conversation",
            sequences: Array(1...8).map(Int64.init),
            coveredThrough: 8,
            lastMsgSeq: 8,
            unread: 4
        )
        _ = try await repository.persistProjection(
            [repaired], source: .history, revision: 2, replaceMissingConversations: false
        )
        let repairedDiagnostics = try await repository.diagnostics()
        let repairedDesiredRead = try await repository.recordAckDesired(channelKey: repaired.channelID, type: "read", desiredSeq: 8)
        XCTAssertEqual(repairedDiagnostics.gapCount, 0)
        XCTAssertEqual(repairedDesiredRead, 8)
    }

    func testDurableReadAckFailureRetriesThenConfirmsMonotonicallyWithoutInfiniteReplay() async throws {
        let repository = try await makeRepository(suffix: "read-ack-retry")
        let snapshot = LocalMessageTestFixture.snapshot(
            id: "read-ack-conversation",
            sequences: Array(1...98).map(Int64.init),
            coveredThrough: 98,
            lastMsgSeq: 98,
            unread: 7
        )
        _ = try await repository.persistProjection(
            [snapshot], source: .history, revision: 1, replaceMissingConversations: false
        )
        let policy = LocalMessageAckRetryPolicy(
            maximumAutomaticAttempts: 3,
            initialRetryDelay: 1,
            maximumRetryDelay: 4
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)

        let recordedDesired = try await repository.recordAckDesired(
            channelKey: snapshot.channelID,
            type: "read",
            desiredSeq: 98,
            resetRetryBudget: true
        )
        XCTAssertEqual(recordedDesired, 98)
        let first = try await repository.claimAcksForRetry(
            type: "read",
            channelKey: snapshot.channelID,
            now: startedAt,
            retryPolicy: policy
        )
        XCTAssertEqual(first.map(\.desiredSeq), [98])
        XCTAssertEqual(first.first?.attemptCount, 1)
        try await repository.releaseAckForRetry(channelKey: snapshot.channelID, type: "read")
        let beforeRetryDeadline = try await repository.claimAcksForRetry(
            type: "read",
            channelKey: snapshot.channelID,
            now: startedAt.addingTimeInterval(0.5),
            retryPolicy: policy
        )
        XCTAssertTrue(beforeRetryDeadline.isEmpty)

        let second = try await repository.claimAcksForRetry(
            type: "read",
            channelKey: snapshot.channelID,
            now: startedAt.addingTimeInterval(1),
            retryPolicy: policy
        )
        XCTAssertEqual(second.first?.attemptCount, 2)
        try await repository.confirmAck(channelKey: snapshot.channelID, type: "read", confirmedSeq: 95)
        try await repository.releaseAckForRetry(channelKey: snapshot.channelID, type: "read")
        var partial = try await repository.ackState(channelKey: snapshot.channelID, type: "read")
        XCTAssertEqual(partial?.desiredSeq, 98)
        XCTAssertEqual(partial?.confirmedSeq, 95)

        let third = try await repository.claimAcksForRetry(
            type: "read",
            channelKey: snapshot.channelID,
            now: startedAt.addingTimeInterval(3),
            retryPolicy: policy
        )
        XCTAssertEqual(third.first?.desiredSeq, 98)
        try await repository.releaseAckForRetry(channelKey: snapshot.channelID, type: "read")
        let exhaustedAutomaticBudget = try await repository.claimAcksForRetry(
            type: "read",
            channelKey: snapshot.channelID,
            now: startedAt.addingTimeInterval(10),
            retryPolicy: policy
        )
        XCTAssertTrue(exhaustedAutomaticBudget.isEmpty)

        _ = try await repository.recordAckDesired(
            channelKey: snapshot.channelID,
            type: "read",
            desiredSeq: 98,
            resetRetryBudget: true
        )
        let explicitRetryWindow = try await repository.claimAcksForRetry(
            type: "read",
            channelKey: snapshot.channelID,
            now: startedAt.addingTimeInterval(10),
            retryPolicy: policy
        )
        XCTAssertEqual(explicitRetryWindow.first?.attemptCount, 1)
        XCTAssertEqual(explicitRetryWindow.first?.desiredSeq, 98)
        try await repository.confirmAck(channelKey: snapshot.channelID, type: "read", confirmedSeq: 98)
        try await repository.confirmAck(channelKey: snapshot.channelID, type: "read", confirmedSeq: 88)
        partial = try await repository.ackState(channelKey: snapshot.channelID, type: "read")
        XCTAssertEqual(partial?.confirmedSeq, 98)
        XCTAssertEqual(partial?.attemptCount, 0)
        XCTAssertNil(partial?.retryAt)
        let remainingAfterConfirmation = try await repository.recoverableAcks(
            type: "read",
            retryPolicy: policy
        )
        XCTAssertTrue(remainingAfterConfirmation.isEmpty)
    }

    func testDurableReadAckResponseLossReplaysSameSequenceAfterRepositoryRestart() async throws {
        let root = makeRoot("read-ack-restart")
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let firstProcess = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        let snapshot = LocalMessageTestFixture.snapshot(
            id: "restart-read-ack",
            sequences: Array(1...12).map(Int64.init),
            coveredThrough: 12,
            lastMsgSeq: 12,
            unread: 7
        )
        _ = try await firstProcess.persistProjection(
            [snapshot], source: .history, revision: 1, replaceMissingConversations: false
        )
        let policy = LocalMessageAckRetryPolicy(
            maximumAutomaticAttempts: 3,
            initialRetryDelay: 1,
            maximumRetryDelay: 4
        )
        let startedAt = Date(timeIntervalSince1970: 2_000)
        _ = try await firstProcess.recordAckDesired(
            channelKey: snapshot.channelID,
            type: "read",
            desiredSeq: 12,
            resetRetryBudget: true
        )
        let sentBeforeResponseLoss = try await firstProcess.claimAcksForRetry(
            type: "read",
            channelKey: snapshot.channelID,
            now: startedAt,
            retryPolicy: policy
        )
        XCTAssertEqual(sentBeforeResponseLoss.first?.desiredSeq, 12)

        let relaunchedProcess = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        let replay = try await relaunchedProcess.claimAcksForRetry(
            type: "read",
            channelKey: snapshot.channelID,
            now: startedAt.addingTimeInterval(1),
            retryPolicy: policy
        )
        XCTAssertEqual(replay.first?.desiredSeq, 12)
        XCTAssertEqual(replay.first?.attemptCount, 2)
        try await relaunchedProcess.confirmAck(
            channelKey: snapshot.channelID,
            type: "read",
            confirmedSeq: 12
        )
        let remainingAfterReplay = try await relaunchedProcess.recoverableAcks(
            type: "read",
            retryPolicy: policy
        )
        XCTAssertTrue(remainingAfterReplay.isEmpty)
    }

    func testEditRevisionFencePreventsStaleHistoryFromRevivingOldText() async throws {
        let repository = try await makeRepository(suffix: "edit-revision")
        var conversation = LocalMessageTestFixture.conversation(
            id: "edit-conversation",
            sequences: [],
            coveredThrough: 1,
            lastMsgSeq: 1,
            unread: 0
        )
        var revisionTwo = LocalMessageTestFixture.message(id: "edited-message", sequence: 1, outgoing: true, status: .sent)
        revisionTwo.text = "revision two"
        revisionTwo.isEdited = true
        revisionTwo.editRevision = 2
        conversation.messages = [revisionTwo]
        var snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-edit-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )
        _ = try await repository.persistProjection(
            [snapshot], source: .realtime, revision: 1, replaceMissingConversations: false
        )

        var stale = revisionTwo
        stale.text = "revision one"
        stale.editRevision = 1
        conversation.messages = [stale]
        snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-edit-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )
        _ = try await repository.persistProjection(
            [snapshot], source: .history, revision: 2, replaceMissingConversations: false
        )
        var loaded = try await repository.loadInitialConversations(limit: 10, messagesPerConversation: 10)
        XCTAssertEqual(loaded.0.first?.messages.first?.text, "revision two")
        XCTAssertEqual(loaded.0.first?.messages.first?.editRevision, 2)

        var revisionThree = revisionTwo
        revisionThree.text = "revision three"
        revisionThree.editRevision = 3
        conversation.messages = [revisionThree]
        snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-edit-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )
        _ = try await repository.persistProjection(
            [snapshot], source: .realtime, revision: 3, replaceMissingConversations: false
        )
        loaded = try await repository.loadInitialConversations(limit: 10, messagesPerConversation: 10)
        XCTAssertEqual(loaded.0.first?.messages.first?.text, "revision three")
        XCTAssertEqual(loaded.0.first?.messages.first?.editRevision, 3)
    }

    func testRTCCallRecordPersistsTypedPayloadAndRejectsSecondAuthorityIdentityWithoutAdvancingAck() async throws {
        let repository = try await makeRepository(suffix: "rtc-call-record")
        let record = RTCCallRecordPayload(
            schemaVersion: 1,
            callID: "call-exact-once",
            callType: .audio,
            callerUID: "peer-a",
            calleeUID: "actor-a",
            finalOutcome: .noAnswer,
            startedAt: Date(timeIntervalSince1970: 1_777_111_000),
            answeredAt: nil,
            mediaConnectedAt: nil,
            endedAt: Date(timeIntervalSince1970: 1_777_111_010),
            durationSeconds: 0,
            reasonCode: "no_answer",
            fallbackText: "语音通话记录",
            endActorUID: nil,
            finalMediaMode: "audio"
        )
        var first = LocalMessageTestFixture.message(id: "rtc-message-1", sequence: 1, outgoing: false, status: .read)
        first.contentType = "rtc_call_record"
        first.rtcCallRecord = record
        var conversation = LocalMessageTestFixture.conversation(
            id: "rtc-conversation",
            sequences: [],
            coveredThrough: 1,
            lastMsgSeq: 1,
            unread: 1
        )
        conversation.messages = [first]
        var snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-rtc-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )
        _ = try await repository.persistProjection(
            [snapshot], source: .history, revision: 1, replaceMissingConversations: false
        )
        let loaded = try await repository.loadInitialConversations(limit: 10, messagesPerConversation: 10)
        let hydrated = try XCTUnwrap(loaded.0.first?.messages.first)
        XCTAssertEqual(hydrated.contentType, "rtc_call_record")
        XCTAssertEqual(hydrated.rtcCallRecord, record)

        let mutatedRecord = RTCCallRecordPayload(
            schemaVersion: record.schemaVersion,
            callID: record.callID,
            callType: .video,
            callerUID: record.callerUID,
            calleeUID: record.calleeUID,
            finalOutcome: .interrupted,
            startedAt: record.startedAt,
            answeredAt: record.startedAt.addingTimeInterval(1),
            mediaConnectedAt: record.startedAt.addingTimeInterval(2),
            endedAt: record.endedAt,
            durationSeconds: 8,
            reasonCode: "network_interrupted",
            fallbackText: record.fallbackText,
            endActorUID: nil,
            finalMediaMode: nil
        )
        var mutated = first
        mutated.rtcCallRecord = mutatedRecord
        conversation.messages = [mutated]
        snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-rtc-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )
        let terminalMutationMetrics = try await repository.persistProjection(
            [snapshot], source: .realtime, revision: 2, replaceMissingConversations: false
        )
        XCTAssertEqual(terminalMutationMetrics.conflict, 1)
        let afterMutation = try await repository.loadInitialConversations(limit: 10, messagesPerConversation: 10)
        XCTAssertEqual(afterMutation.0.first?.messages.first?.rtcCallRecord, record)

        var malformedReplay = first
        malformedReplay.contentType = "rtc_call_record"
        malformedReplay.rtcCallRecord = nil
        conversation.messages = [malformedReplay]
        snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-rtc-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )
        let malformedReplayMetrics = try await repository.persistProjection(
            [snapshot], source: .realtime, revision: 3, replaceMissingConversations: false
        )
        XCTAssertEqual(malformedReplayMetrics.conflict, 1)
        let afterMalformedReplay = try await repository.loadInitialConversations(limit: 10, messagesPerConversation: 10)
        XCTAssertEqual(afterMalformedReplay.0.first?.messages.first?.rtcCallRecord, record)

        var conflicting = first
        conflicting = ChatMessage(
            id: "rtc-message-2",
            senderId: conflicting.senderId,
            senderName: conflicting.senderName,
            text: conflicting.text,
            time: conflicting.time,
            createdAt: conflicting.createdAt,
            channelSeq: 2,
            isOutgoing: conflicting.isOutgoing,
            status: conflicting.status,
            kind: conflicting.kind,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        conflicting.contentType = "rtc_call_record"
        conflicting.rtcCallRecord = record
        conversation.messages = [first, conflicting]
        conversation.lastMsgSeq = 2
        conversation.messageCoveredThroughSeq = 2
        snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-rtc-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )
        let metrics = try await repository.persistProjection(
            [snapshot], source: .realtime, revision: 4, replaceMissingConversations: false
        )
        let diagnostics = try await repository.diagnostics()
        let desiredDelivery = try await repository.recordAckDesired(
            channelKey: "channel-rtc-conversation",
            type: "delivery",
            desiredSeq: 2
        )
        XCTAssertEqual(metrics.conflict, 1)
        XCTAssertEqual(diagnostics.messageCount, 1)
        XCTAssertEqual(desiredDelivery, 1)
    }

    func testOutboxAndAttachmentJournalRecoverThenFinalizeWithoutDuplicateMessage() async throws {
        let repository = try await makeRepository(suffix: "outbox")
        let data = Data((0..<8_192).map { UInt8($0 % 251) })
        var conversation = LocalMessageTestFixture.conversation(id: "outbox-conversation", sequences: [])
        let local = LocalMessageTestFixture.message(id: "local-outbox-1", sequence: 0, outgoing: true, status: .sending)
        conversation.messages = [local]
        let projection = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-outbox-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )
        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(
                conversation: projection,
                message: CachedMessage(message: local),
                operationKind: "send_attachment",
                attachment: LocalMessageAttachmentIntent(
                    data: data,
                    fileName: "fixture.bin",
                    mimeType: "application/octet-stream",
                    sizeBytes: Int64(data.count),
                    checksum: AttachmentTransferRepository.sha256Hex(data)
                )
            ),
            revision: 1
        )
        let pending = try await repository.pendingOutbox()
        XCTAssertEqual(pending.count, 1)
        let stagedData = try await repository.loadStagedAttachment(for: try XCTUnwrap(pending.first))
        XCTAssertEqual(stagedData, data)

        var authoritativeConversation = conversation
        authoritativeConversation.messages = [
            LocalMessageTestFixture.message(id: "server-message-1", sequence: 1, outgoing: true, status: .sent)
        ]
        authoritativeConversation.lastMsgSeq = 1
        authoritativeConversation.messageCoveredThroughSeq = 1
        let authoritative = LocalMessageConversationSnapshot(
            conversation: authoritativeConversation,
            channelID: projection.channelID,
            channelType: projection.channelType,
            currentActorID: "actor-a"
        )
        try await repository.confirmOutgoing(
            clientMessageID: local.id,
            authoritativeMessageID: "server-message-1",
            authoritativeChannelSeq: 1,
            projection: authoritative,
            revision: 2
        )
        let remainingOutbox = try await repository.pendingOutbox()
        XCTAssertTrue(remainingOutbox.isEmpty)
        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(diagnostics.messageCount, 1)
        XCTAssertEqual(diagnostics.outboxCount, 0)
    }

    func testFileBackedOutboxStagesWithoutDataAndRemovesFileOnTerminalState() async throws {
        let repository = try await makeRepository(suffix: "file-backed-outbox")
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios1-outbox-source-\(UUID().uuidString).bin")
        let payload = Data((0..<16_384).map { UInt8($0 % 251) })
        try payload.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var conversation = LocalMessageTestFixture.conversation(id: "file-outbox-conversation", sequences: [])
        let local = LocalMessageTestFixture.message(id: "local-file-outbox-1", sequence: 0, outgoing: true, status: .sending)
        conversation.messages = [local]
        let projection = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-file-outbox-conversation",
            channelType: "person",
            currentActorID: "actor-a"
        )

        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(
                conversation: projection,
                message: CachedMessage(message: local),
                operationKind: "send_attachment",
                attachment: LocalMessageAttachmentIntent(
                    fileURL: sourceURL,
                    fileName: "fixture.bin",
                    mimeType: "application/octet-stream",
                    sizeBytes: Int64(payload.count)
                )
            ),
            revision: 1
        )

        let pending = try await repository.pendingOutbox()
        let pendingItem = try XCTUnwrap(pending.first)
        let recoveredFileURL = try await repository.stagedAttachmentFileURL(for: pendingItem)
        let stagedURL = try XCTUnwrap(recoveredFileURL)
        XCTAssertNotEqual(stagedURL, sourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try Data(contentsOf: stagedURL), payload)

        try await repository.updateOutboxState(
            clientMessageID: local.id,
            state: .cancelled
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testAttachmentCheckpointSurvivesReenqueueAndRepositoryReopenWithoutDowngrade() async throws {
        let root = makeRoot("attachment-checkpoint-cold-replay")
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let sourceURL = root.appendingPathComponent("checkpoint-source.bin")
        let payload = Data((0..<4_096).map { UInt8($0 % 251) })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: sourceURL)
        let message = LocalMessageTestFixture.attachmentMessage(
            id: "local-checkpoint-1",
            sizeBytes: Int64(payload.count)
        )
        var conversation = LocalMessageTestFixture.conversation(id: "checkpoint-conversation", sequences: [])
        conversation.messages = [message]
        let outgoing = LocalMessageOutgoingIntent(
            conversation: LocalMessageConversationSnapshot(
                conversation: conversation,
                channelID: "channel-checkpoint",
                channelType: "person",
                currentActorID: "actor-a"
            ),
            message: CachedMessage(message: message),
            operationKind: "send_attachment",
            attachment: LocalMessageAttachmentIntent(
                fileURL: sourceURL,
                fileName: "checkpoint.bin",
                mimeType: "application/octet-stream",
                sizeBytes: Int64(payload.count)
            )
        )

        let firstProcess = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        _ = try await firstProcess.enqueueOutgoing(outgoing, revision: 1)
        try await firstProcess.updateOutboxState(
            clientMessageID: message.id,
            state: .sending,
            fileID: "file-checkpoint-1",
            attachmentPhase: "uploaded"
        )
        _ = try await firstProcess.enqueueOutgoing(outgoing, revision: 2)
        var recovered = try await firstProcess.recoverableOutbox()
        XCTAssertEqual(recovered.first?.attachmentFileID, "file-checkpoint-1")
        XCTAssertEqual(recovered.first?.attachmentPhase, "uploaded")

        let relaunchedProcess = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        recovered = try await relaunchedProcess.recoverableOutbox()
        XCTAssertEqual(recovered.map(\.clientMessageID), [message.id])
        XCTAssertEqual(recovered.first?.attachmentFileID, "file-checkpoint-1")
        XCTAssertEqual(recovered.first?.attachmentPhase, "uploaded")
        let recoveredItem = try XCTUnwrap(recovered.first)
        let recoveredFileURL = try await relaunchedProcess.stagedAttachmentFileURL(for: recoveredItem)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recoveredFileURL)), payload)
    }

    func testDurableAttachmentPayloadRedactsLocalAndSignedURLsButRecoveryUsesStaging() async throws {
        let root = makeRoot("attachment-payload-redaction")
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        let originalURL = root.appendingPathComponent("BlueStoneIMPendingAttachments-private-name.pdf")
        let payload = Data("private attachment".utf8)
        try payload.write(to: originalURL)
        var message = LocalMessageTestFixture.attachmentMessage(
            id: "local-redacted-1",
            sizeBytes: Int64(payload.count)
        )
        message.attachmentPreviewURL = originalURL.absoluteString
        message.attachmentDownloadURL = "https://object.example.test/private.pdf?signature=secret&auth_key=also-secret"
        message.attachmentThumbnailURL = "file:///private/container/thumbnail.png"
        message.attachmentPosterURL = "https://object.example.test/poster?X-Amz-Signature=secret"
        message.attachmentCoverURL = "file:///private/container/cover.png"
        var conversation = LocalMessageTestFixture.conversation(id: "redacted-conversation", sequences: [])
        conversation.messages = [message]
        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(
                conversation: LocalMessageConversationSnapshot(
                    conversation: conversation,
                    channelID: "channel-redacted",
                    channelType: "person",
                    currentActorID: "actor-a"
                ),
                message: CachedMessage(message: message),
                operationKind: "send_attachment",
                attachment: LocalMessageAttachmentIntent(
                    fileURL: originalURL,
                    fileName: "private-name.pdf",
                    mimeType: "application/pdf",
                    sizeBytes: Int64(payload.count)
                )
            ),
            revision: 1
        )

        let queue = try DatabaseQueue(path: paths.databaseURL.path)
        let messageID = message.id
        let storedPayloads: [Data] = try await queue.read { db in
            let outbox = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM outbox WHERE client_msg_no = ?", arguments: [messageID]))
            let localMessage = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT payload FROM message WHERE client_msg_no = ?", arguments: [messageID]))
            return [outbox, localMessage]
        }
        for storedPayload in storedPayloads {
            let raw = try XCTUnwrap(String(data: storedPayload, encoding: .utf8)).lowercased()
            XCTAssertFalse(raw.contains("file://"))
            XCTAssertFalse(raw.contains("bluestoneimpendingattachments"))
            XCTAssertFalse(raw.contains(originalURL.path.lowercased()))
            XCTAssertFalse(raw.contains("signature"))
            XCTAssertFalse(raw.contains("auth_key"))
            let decoded = try JSONDecoder().decode(CachedMessage.self, from: storedPayload).model
            XCTAssertTrue(decoded.attachmentPreviewURL.isEmpty)
            XCTAssertTrue(decoded.attachmentDownloadURL.isEmpty)
            XCTAssertTrue(decoded.attachmentThumbnailURL.isEmpty)
            XCTAssertTrue(decoded.attachmentPosterURL.isEmpty)
            XCTAssertTrue(decoded.attachmentCoverURL.isEmpty)
        }
        let recoveredItems = try await repository.recoverableOutbox()
        let recovered = try XCTUnwrap(recoveredItems.first)
        let stagedFileURL = try await repository.stagedAttachmentFileURL(for: recovered)
        let recoveredURL = try XCTUnwrap(stagedFileURL)
        XCTAssertNotEqual(recoveredURL.standardizedFileURL, originalURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: recoveredURL), payload)
    }

    func testAttachmentStagingRollsBackOnDatabaseFailureAndStartupReconcilesOrphans() async throws {
        let root = makeRoot("attachment-staging-reconcile")
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let sourceURL = root.appendingPathComponent("source.bin")
        let payload = Data((0..<2_048).map { UInt8($0 % 241) })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: sourceURL)

        let staleRepository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        let currentRepository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        let staleMessage = LocalMessageTestFixture.attachmentMessage(
            id: "local-stale-writer",
            sizeBytes: Int64(payload.count)
        )
        do {
            _ = try await staleRepository.enqueueOutgoing(
                LocalMessageTestFixture.outgoingAttachmentIntent(
                    message: staleMessage,
                    sourceURL: sourceURL,
                    sizeBytes: Int64(payload.count)
                ),
                revision: 1
            )
            XCTFail("stale writer unexpectedly committed attachment staging")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleWriter)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stagedAttachmentURL(clientMessageID: staleMessage.id).path))

        let activeMessage = LocalMessageTestFixture.attachmentMessage(
            id: "local-active-staging",
            sizeBytes: Int64(payload.count)
        )
        _ = try await currentRepository.enqueueOutgoing(
            LocalMessageTestFixture.outgoingAttachmentIntent(
                message: activeMessage,
                sourceURL: sourceURL,
                sizeBytes: Int64(payload.count)
            ),
            revision: 2
        )
        let activeURL = paths.stagedAttachmentURL(clientMessageID: activeMessage.id)
        let orphanURL = paths.stagingDirectory.appendingPathComponent("orphan.pending")
        try Data("orphan".utf8).write(to: orphanURL)

        let relaunchedRepository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        try await relaunchedRepository.updateOutboxState(clientMessageID: activeMessage.id, state: .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.path))

        let managedSource = try PendingAttachmentFileStore.stageFile(
            from: sourceURL,
            preferredName: "temporary-source.bin"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedSource.url.path))
        _ = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("coordinator-support"),
            cachesBase: root.appendingPathComponent("coordinator-caches"),
            cleanupPendingAttachmentFilesOnInit: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedSource.url.path))
    }

    func testOutboxRetryBackoffSurvivesColdReadAndAutomaticReplayIsBounded() async throws {
        let repository = try await makeRepository(suffix: "outbox-backoff")
        let snapshot = LocalMessageTestFixture.snapshot(id: "outbox-backoff", count: 0)
        let message = LocalMessageTestFixture.message(
            id: "local-outbox-backoff",
            sequence: 0,
            outgoing: true,
            status: .sending
        )
        var conversation = snapshot.metadata.model
        conversation.messages = [message]
        let outgoing = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: snapshot.channelID,
            channelType: snapshot.channelType,
            currentActorID: "actor-a"
        )
        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(
                conversation: outgoing,
                message: CachedMessage(message: message),
                operationKind: "send_text",
                attachment: nil
            ),
            revision: 1
        )

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.updateOutboxState(
            clientMessageID: message.id,
            state: .sending,
            now: startedAt
        )
        // Attachment phase checkpoints may report `sending` repeatedly within
        // one claimed attempt; they must not consume the replay budget.
        for _ in 0..<3 {
            try await repository.updateOutboxState(
                clientMessageID: message.id,
                state: .sending,
                now: startedAt
            )
        }
        try await repository.updateOutboxState(
            clientMessageID: message.id,
            state: .retryWait,
            now: startedAt
        )
        let beforeDue = try await repository.pendingOutbox(now: startedAt.addingTimeInterval(1))
        XCTAssertTrue(beforeDue.isEmpty)
        let due = try await repository.pendingOutbox(now: startedAt.addingTimeInterval(3))
        XCTAssertEqual(due.map(\.clientMessageID), [message.id])
        XCTAssertEqual(due.first?.attemptCount, 1)
        XCTAssertEqual(due.first?.nextAttemptAt, startedAt.addingTimeInterval(2).timeIntervalSince1970)

        for offset in 1..<LocalMessageOutboxReplayPolicy.standard.maximumAutomaticAttempts {
            let attemptAt = startedAt.addingTimeInterval(Double(offset * 1_000))
            try await repository.updateOutboxState(
                clientMessageID: message.id,
                state: .sending,
                now: attemptAt
            )
            try await repository.updateOutboxState(
                clientMessageID: message.id,
                state: .retryWait,
                now: attemptAt
            )
        }
        let afterAutomaticBudget = try await repository.pendingOutbox(
            now: startedAt.addingTimeInterval(10_000)
        )
        XCTAssertTrue(
            afterAutomaticBudget.isEmpty,
            "automatic cold-start replay must stop at the durable attempt budget"
        )
        let retained = try await repository.recoverableOutbox()
        XCTAssertEqual(retained.first?.attemptCount, LocalMessageOutboxReplayPolicy.standard.maximumAutomaticAttempts)
        XCTAssertTrue(retained.first?.requiresUserInitiatedReplay == true)
    }

    func testOutboxClaimRequiresCurrentAuthorizationGenerationAndManualReplayPreservesIdentity() async throws {
        let root = makeRoot("outbox-auth")
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let context = LocalMessageTestFixture.context()
        let loaded = try await coordinator.activateAndLoad(context: context, sessionGeneration: 44)
        let snapshot = LocalMessageTestFixture.snapshot(id: "outbox-auth", count: 0)
        let message = LocalMessageTestFixture.message(
            id: "local-outbox-auth",
            sequence: 0,
            outgoing: true,
            status: .sending
        )
        var conversation = snapshot.metadata.model
        conversation.messages = [message]
        _ = try await coordinator.enqueueOutgoing(
            ticket: loaded.ticket,
            intent: LocalMessageOutgoingIntent(
                conversation: LocalMessageConversationSnapshot(
                    conversation: conversation,
                    channelID: snapshot.channelID,
                    channelType: snapshot.channelType,
                    currentActorID: "actor-a"
                ),
                message: CachedMessage(message: message),
                operationKind: "send_text",
                attachment: nil
            ),
            revision: 1
        )

        do {
            _ = try await coordinator.claimOutboxForReplay(
                ticket: loaded.ticket,
                authorizationGeneration: 43,
                trigger: .automatic,
                clientMessageID: nil,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
            XCTFail("stale authorization generation claimed the outbox")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        let claimed = try await coordinator.claimOutboxForReplay(
            ticket: loaded.ticket,
            authorizationGeneration: 44,
            trigger: .userInitiated,
            clientMessageID: message.id,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(claimed.map(\.clientMessageID), [message.id])
        XCTAssertEqual(claimed.first?.attemptCount, 1)

        _ = try await coordinator.enqueueOutgoing(
            ticket: loaded.ticket,
            intent: LocalMessageOutgoingIntent(
                conversation: LocalMessageConversationSnapshot(
                    conversation: conversation,
                    channelID: snapshot.channelID,
                    channelType: snapshot.channelType,
                    currentActorID: "actor-a"
                ),
                message: CachedMessage(message: message),
                operationKind: "send_text",
                attachment: nil
            ),
            revision: 2
        )
        try await coordinator.updateOutboxState(
            ticket: loaded.ticket,
            clientMessageID: message.id,
            state: .sending,
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let afterClaimedReplayStarted = try await coordinator.recoverableOutbox(ticket: loaded.ticket)
        XCTAssertEqual(afterClaimedReplayStarted.first?.attemptCount, 1)
    }

    func testSameScopeReauthenticationPreservesHistoryOutboxAndStagedAttachmentWhileFencingOldSender() async throws {
        let root = makeRoot("reauth-preserves-data")
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let context = LocalMessageTestFixture.context()
        let first = try await coordinator.activateAndLoad(context: context, sessionGeneration: 70)
        _ = try await coordinator.persist(
            ticket: first.ticket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "reauth-history", count: 2)],
            source: .history,
            revision: 1
        )
        let payload = Data((0..<4_096).map { UInt8($0 % 251) })
        let sourceURL = root.appendingPathComponent("reauth-source.bin")
        try payload.write(to: sourceURL)
        let message = LocalMessageTestFixture.attachmentMessage(id: "reauth-attachment", sizeBytes: Int64(payload.count))
        let intent = LocalMessageTestFixture.outgoingAttachmentIntent(
            message: message, sourceURL: sourceURL, sizeBytes: Int64(payload.count)
        )
        _ = try await coordinator.enqueueOutgoing(ticket: first.ticket, intent: intent, revision: 2)
        let originalOutbox = try await coordinator.recoverableOutbox(ticket: first.ticket)
        let originalItem = try XCTUnwrap(originalOutbox.first)
        let originalFile = try await coordinator.stagedAttachmentFileURL(ticket: first.ticket, item: originalItem)
        let stagedURL = try XCTUnwrap(originalFile)
        XCTAssertNotEqual(stagedURL, sourceURL)
        try FileManager.default.removeItem(at: sourceURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalMessagePayload = try encoder.encode(originalItem.message)

        // Reauthentication rotates authorization without invoking logout/purge.
        let rebound = try await coordinator.activateAndLoad(context: context, sessionGeneration: 71)
        XCTAssertEqual(rebound.ticket.scopeHash, first.ticket.scopeHash)
        XCTAssertNotEqual(rebound.ticket.coordinatorEpoch, first.ticket.coordinatorEpoch)
        XCTAssertEqual(Set(rebound.conversations.map(\.id)), ["reauth-history", intent.conversation.metadata.id])
        XCTAssertEqual(rebound.conversations.first(where: { $0.id == "reauth-history" })?.messages.count, 2)
        let recovered = try await coordinator.recoverableOutbox(ticket: rebound.ticket)
        XCTAssertEqual(recovered.map(\.clientMessageID), [message.id])
        let recoveredItem = try XCTUnwrap(recovered.first)
        XCTAssertEqual(try encoder.encode(recoveredItem.message), originalMessagePayload)
        XCTAssertEqual(recoveredItem.attachmentRelativePath, originalItem.attachmentRelativePath)
        XCTAssertEqual(recoveredItem.attemptCount, originalItem.attemptCount)
        XCTAssertEqual(recoveredItem.state, originalItem.state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        let recoveredData = try await coordinator.loadStagedAttachment(ticket: rebound.ticket, item: recoveredItem)
        XCTAssertEqual(recoveredData, payload)

        do {
            _ = try await coordinator.enqueueOutgoing(ticket: first.ticket, intent: intent, revision: 3)
            XCTFail("the old authorization must not write the preserved outbox")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        do {
            _ = try await coordinator.claimOutboxForReplay(
                ticket: first.ticket, authorizationGeneration: 70,
                trigger: .userInitiated, clientMessageID: message.id
            )
            XCTFail("the old ticket must not claim a preserved outgoing message")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        do {
            try await coordinator.updateOutboxState(ticket: first.ticket, clientMessageID: message.id, state: .sending)
            XCTFail("the old sender must not advance the preserved intent")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        do {
            _ = try await coordinator.stagedAttachmentFileURL(ticket: first.ticket, item: originalItem)
            XCTFail("the old sender must not obtain a staged attachment for upload")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        do {
            _ = try await coordinator.claimOutboxForReplay(
                ticket: rebound.ticket, authorizationGeneration: 70,
                trigger: .userInitiated, clientMessageID: message.id
            )
            XCTFail("a new ticket still requires matching new authorization")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }

        let claimed = try await coordinator.claimOutboxForReplay(
            ticket: rebound.ticket, authorizationGeneration: 71,
            trigger: .userInitiated, clientMessageID: message.id
        )
        XCTAssertEqual(claimed.map(\.clientMessageID), [message.id])
        XCTAssertEqual(claimed.first?.attemptCount, 1)
        XCTAssertEqual(try encoder.encode(XCTUnwrap(claimed.first).message), originalMessagePayload)
        let resumedFile = try await coordinator.stagedAttachmentFileURL(ticket: rebound.ticket, item: recoveredItem)
        XCTAssertEqual(resumedFile, stagedURL)
        let repeatedTicket = try await coordinator.ensureTicket(context: context, sessionGeneration: 71)
        XCTAssertEqual(repeatedTicket, rebound.ticket)
        let diagnostics = try await coordinator.diagnostics(ticket: repeatedTicket)
        XCTAssertEqual(diagnostics.conversationCount, 2)
        XCTAssertEqual(diagnostics.messageCount, 3)
        XCTAssertEqual(diagnostics.outboxCount, 1)
    }

    func testReauthenticationABAKeepsOtherScopeFromReadingOrClaimingPreservedOutbox() async throws {
        let root = makeRoot("reauth-aba")
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let contextA = LocalMessageTestFixture.context(actor: "actor-a")
        let contextB = LocalMessageTestFixture.context(actor: "actor-b")
        let firstA = try await coordinator.activateAndLoad(context: contextA, sessionGeneration: 80)
        let payload = Data("scope-a-attachment".utf8)
        let sourceURL = root.appendingPathComponent("scope-a.bin")
        try payload.write(to: sourceURL)
        let message = LocalMessageTestFixture.attachmentMessage(id: "scope-a-pending", sizeBytes: Int64(payload.count))
        let intent = LocalMessageTestFixture.outgoingAttachmentIntent(
            message: message, sourceURL: sourceURL, sizeBytes: Int64(payload.count)
        )
        _ = try await coordinator.enqueueOutgoing(ticket: firstA.ticket, intent: intent, revision: 1)
        let pendingA = try await coordinator.recoverableOutbox(ticket: firstA.ticket)
        let itemA = try XCTUnwrap(pendingA.first)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalMessagePayload = try encoder.encode(itemA.message)
        let loadedB = try await coordinator.activateAndLoad(context: contextB, sessionGeneration: 81)
        XCTAssertTrue(loadedB.conversations.isEmpty)
        XCTAssertTrue(loadedB.pendingOutbox.isEmpty)
        _ = try await coordinator.persist(
            ticket: loadedB.ticket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "scope-b-history", count: 1, actor: "actor-b")],
            source: .history, revision: 1
        )
        do {
            _ = try await coordinator.recoverableOutbox(ticket: firstA.ticket)
            XCTFail("an inactive scope ticket must not read the active scope's outbox")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        do {
            _ = try await coordinator.loadOlderMessages(
                ticket: firstA.ticket, channelKey: "channel-scope-b-history", beforeSeq: 2
            )
            XCTFail("an inactive scope ticket must not read the active scope's history")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        do {
            _ = try await coordinator.claimOutboxForReplay(
                ticket: firstA.ticket, authorizationGeneration: 80,
                trigger: .userInitiated, clientMessageID: message.id
            )
            XCTFail("an inactive scope ticket must not claim outgoing work")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        let crossScopeClaim = try await coordinator.claimOutboxForReplay(
            ticket: loadedB.ticket, authorizationGeneration: 81,
            trigger: .userInitiated, clientMessageID: message.id
        )
        XCTAssertTrue(crossScopeClaim.isEmpty)
        do {
            _ = try await coordinator.loadStagedAttachment(ticket: loadedB.ticket, item: itemA)
            XCTFail("a current ticket from another scope must not resolve the preserved attachment")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .missingStagedAttachment)
        }

        let returnedA = try await coordinator.activateAndLoad(context: contextA, sessionGeneration: 82)
        XCTAssertEqual(returnedA.conversations.map(\.id), [intent.conversation.metadata.id])
        let restored = try await coordinator.recoverableOutbox(ticket: returnedA.ticket)
        XCTAssertEqual(restored.map(\.clientMessageID), [message.id])
        let restoredItem = try XCTUnwrap(restored.first)
        XCTAssertEqual(try encoder.encode(restoredItem.message), originalMessagePayload)
        XCTAssertEqual(restoredItem.attemptCount, 0)
        let restoredData = try await coordinator.loadStagedAttachment(ticket: returnedA.ticket, item: restoredItem)
        XCTAssertEqual(restoredData, payload)
        do {
            _ = try await coordinator.claimOutboxForReplay(
                ticket: firstA.ticket, authorizationGeneration: 80,
                trigger: .userInitiated, clientMessageID: message.id
            )
            XCTFail("returning to A must not revive A's original sender ticket")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        let claimed = try await coordinator.claimOutboxForReplay(
            ticket: returnedA.ticket, authorizationGeneration: 82,
            trigger: .userInitiated, clientMessageID: message.id
        )
        XCTAssertEqual(claimed.map(\.clientMessageID), [message.id])
        let diagnostics = try await coordinator.diagnostics(ticket: returnedA.ticket)
        XCTAssertEqual(diagnostics.conversationCount, 1)
        XCTAssertEqual(diagnostics.messageCount, 1)
        XCTAssertEqual(diagnostics.outboxCount, 1)
        do {
            _ = try await coordinator.recoverableOutbox(ticket: loadedB.ticket)
            XCTFail("the previous account must not read A after the ABA return")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
    }

    func testRealtimeAuthorityAcknowledgementIsIdempotentAndSuppressesReplay() async throws {
        let repository = try await makeRepository(suffix: "outbox-realtime-ack")
        let snapshot = LocalMessageTestFixture.snapshot(id: "outbox-realtime", count: 0)
        let local = LocalMessageTestFixture.message(
            id: "local-outbox-realtime",
            sequence: 0,
            outgoing: true,
            status: .sending
        )
        var conversation = snapshot.metadata.model
        conversation.messages = [local]
        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(
                conversation: LocalMessageConversationSnapshot(
                    conversation: conversation,
                    channelID: snapshot.channelID,
                    channelType: snapshot.channelType,
                    currentActorID: "actor-a"
                ),
                message: CachedMessage(message: local),
                operationKind: "send_text",
                attachment: nil
            ),
            revision: 1
        )

        for _ in 0..<2 {
            let acknowledged = try await repository.acknowledgeOutgoingAuthority(
                clientMessageID: local.id,
                authoritativeMessageID: "server-outbox-realtime",
                authoritativeChannelSeq: 7,
                channelKey: snapshot.channelID
            )
            XCTAssertTrue(acknowledged)
        }
        let recoverable = try await repository.recoverableOutbox()
        let pending = try await repository.pendingOutbox()
        XCTAssertTrue(recoverable.isEmpty)
        XCTAssertTrue(pending.isEmpty)
        let authority = try await repository.outgoingAuthority(clientMessageID: local.id)
        XCTAssertEqual(authority?.authoritativeMessageID, "server-outbox-realtime")
        XCTAssertEqual(authority?.authoritativeChannelSeq, 7)
        XCTAssertTrue(authority?.isAcknowledged == true)
    }

    func testOutgoingAuthorityAcknowledgementRejectsRemoteOwnedByDifferentClient() async throws {
        let repository = try await makeRepository(suffix: "fixture-073-authority-guard")
        let snapshot = LocalMessageTestFixture.snapshot(id: "fixture-073-authority", count: 0)
        var conversation = snapshot.metadata.model
        let oldLocal = LocalMessageTestFixture.message(
            id: "local_old_1",
            sequence: 0,
            outgoing: true,
            status: .sending,
            text: "same.jpg"
        )
        conversation.messages = [oldLocal]
        let oldProjection = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: snapshot.channelID,
            channelType: snapshot.channelType,
            currentActorID: "actor-a"
        )
        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(
                conversation: oldProjection,
                message: CachedMessage(message: oldLocal),
                operationKind: "send_attachment",
                attachment: nil
            ),
            revision: 1
        )
        let oldAcknowledged = try await repository.acknowledgeOutgoingAuthority(
            clientMessageID: oldLocal.id,
            authoritativeMessageID: "remote_old_1",
            authoritativeChannelSeq: 101,
            channelKey: snapshot.channelID
        )
        XCTAssertTrue(oldAcknowledged)

        let newLocal = LocalMessageTestFixture.message(
            id: "local_first_1",
            sequence: 0,
            outgoing: true,
            status: .sending,
            text: "same.jpg"
        )
        conversation.messages = [newLocal]
        let newProjection = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: snapshot.channelID,
            channelType: snapshot.channelType,
            currentActorID: "actor-a"
        )
        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(
                conversation: newProjection,
                message: CachedMessage(message: newLocal),
                operationKind: "send_attachment",
                attachment: nil
            ),
            revision: 2
        )

        do {
            _ = try await repository.acknowledgeOutgoingAuthority(
                clientMessageID: newLocal.id,
                authoritativeMessageID: "remote_old_1",
                authoritativeChannelSeq: 101,
                channelKey: snapshot.channelID
            )
            XCTFail("acknowledgement must not bind a new local message to a remote owned by another client_msg_no")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .identityConflict)
        }
        let authority = try await repository.outgoingAuthority(clientMessageID: newLocal.id)
        XCTAssertEqual(authority?.state, LocalMessageOutboxState.ready.rawValue)
        XCTAssertFalse(authority?.isAcknowledged == true)
        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(diagnostics.messageCount, 2)
    }

    func testLocalReadsRemainValidAcrossSameScopeAccessSessionRotation() async throws {
        let root = makeRoot("local-read-rotation")
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let context = LocalMessageTestFixture.context()
        let first = try await coordinator.activateAndLoad(context: context, sessionGeneration: 1)
        _ = try await coordinator.persist(
            ticket: first.ticket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "offline-history", count: 12)],
            source: .history,
            revision: 1
        )
        _ = try await coordinator.ensureTicket(context: context, sessionGeneration: 2)

        let page = try await coordinator.loadOlderMessages(
            ticket: first.ticket,
            channelKey: "channel-offline-history",
            beforeSeq: 13,
            limit: 5
        )
        let search = try await coordinator.search(
            ticket: first.ticket,
            query: "message12",
            limit: 5
        )
        XCTAssertEqual(page.map(\.channelSeq), [8, 9, 10, 11, 12])
        XCTAssertEqual(search.first?.conversationID, "offline-history")
    }

    func testLegacyMigrationIsIdempotentAndRequiresReadbackBeforeCompletion() async throws {
        let repository = try await makeRepository(suffix: "legacy")
        let legacy = LocalMessageTestFixture.snapshot(id: "legacy-conversation", count: 40, requiresServerRevalidation: true)
        let firstImport = try await repository.importLegacy([legacy], revision: 1)
        let secondImport = try await repository.importLegacy([legacy], revision: 2)
        XCTAssertTrue(firstImport)
        XCTAssertTrue(secondImport)
        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(diagnostics.conversationCount, 1)
        XCTAssertEqual(diagnostics.messageCount, 40)
        XCTAssertGreaterThan(diagnostics.gapCount, 0)
    }

    func testNewestWriterFencesStaleSceneAndWALReopensAfterAbruptOwnerLoss() async throws {
        let root = makeRoot("writer")
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let first = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        _ = try await first.persistProjection(
            [LocalMessageTestFixture.snapshot(id: "writer-conversation", count: 50)],
            source: .history,
            revision: 1,
            replaceMissingConversations: false
        )
        let second = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        do {
            _ = try await first.persistProjection(
                [LocalMessageTestFixture.snapshot(id: "stale-write", count: 1)],
                source: .realtime,
                revision: 2,
                replaceMissingConversations: false
            )
            XCTFail("stale writer unexpectedly committed")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleWriter)
        }
        let loaded = try await second.loadInitialConversations(limit: 10, messagesPerConversation: 100)
        XCTAssertEqual(loaded.0.first?.messages.count, 50)
        let diagnostics = try await second.diagnostics()
        XCTAssertEqual(diagnostics.journalMode.lowercased(), "wal")
        XCTAssertEqual(diagnostics.quickCheck.lowercased(), "ok")
    }

    func testCorruptDatabaseIsQuarantinedAndRebuiltWithoutDeletingAttachmentStaging() async throws {
        let root = makeRoot("corrupt")
        let context = LocalMessageTestFixture.context()
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        try paths.prepare()
        let staged = paths.stagingDirectory.appendingPathComponent("keep.pending")
        try Data("staged-data".utf8).write(to: staged)
        try Data("not-a-sqlite-database".utf8).write(to: paths.databaseURL)

        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let result = try await coordinator.activateAndLoad(context: context, sessionGeneration: 1)
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        let diagnostics = try await coordinator.diagnostics(ticket: result.ticket)
        XCTAssertEqual(diagnostics.quickCheck.lowercased(), "ok")
    }

    func testProfileContactProjectionRoundTripsAndRejectsOlderRevision() async throws {
        let repository = try await makeRepository(suffix: "profile-contact-revision")
        let authoritative = LocalMessageTestFixture.profileContactProjection(
            revision: 7,
            actor: "friend-a",
            remark: "仅当前查看者可见",
            blocked: true
        )
        try await repository.persistProfileContactProjection(authoritative)

        let initiallyLoaded = try await repository.loadProfileContactProjection()
        XCTAssertEqual(initiallyLoaded, authoritative)
        do {
            try await repository.persistProfileContactProjection(
                LocalMessageTestFixture.profileContactProjection(
                    revision: 6,
                    actor: "friend-a",
                    remark: "旧备注",
                    blocked: false
                )
            )
            XCTFail("older contact projection unexpectedly committed")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        let retained = try await repository.loadProfileContactProjection()
        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(retained, authoritative)
        XCTAssertEqual(diagnostics.schemaVersion, 3)
    }

    func testProfileContactProjectionIsIsolatedAcrossAccountScopes() async throws {
        let root = makeRoot("profile-contact-scopes")
        let coordinator = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let contextA = LocalMessageTestFixture.context(actor: "actor-a")
        let contextB = LocalMessageTestFixture.context(actor: "actor-b")
        let loadedA = try await coordinator.activateAndLoad(context: contextA, sessionGeneration: 1)
        let projectionA = LocalMessageTestFixture.profileContactProjection(
            revision: 1,
            actor: "friend-a",
            remark: "A 的私有备注",
            blocked: false
        )
        try await coordinator.persistProfileContactProjection(ticket: loadedA.ticket, projection: projectionA)

        let loadedB = try await coordinator.activateAndLoad(context: contextB, sessionGeneration: 2)
        XCTAssertNil(loadedB.profileContactProjection)
        let projectionB = LocalMessageTestFixture.profileContactProjection(
            revision: 1,
            actor: "friend-b",
            remark: "B 的私有备注",
            blocked: true
        )
        try await coordinator.persistProfileContactProjection(ticket: loadedB.ticket, projection: projectionB)

        let returnedA = try await coordinator.activateAndLoad(context: contextA, sessionGeneration: 3)
        XCTAssertEqual(returnedA.profileContactProjection, projectionA)
        XCTAssertNotEqual(returnedA.profileContactProjection, projectionB)
    }

    private func makeRepository(suffix: String) async throws -> SQLiteMessageRepository {
        let root = makeRoot(suffix)
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        return try await SQLiteMessageRepository.open(scope: scope, paths: paths)
    }

    private func makeRoot(_ suffix: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDatabaseSemanticsTests-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }
}

final class MessageDatabasePerformanceTests: XCTestCase {
    func testFiveThousandMessagesAcrossTwoHundredDirectAndGroupConversations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDatabasePerformanceTests-small-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        let snapshots = (0..<200).map { index in
            LocalMessageTestFixture.snapshot(
                id: "mixed-\(index)",
                count: 25,
                kind: index.isMultiple(of: 2) ? .direct : .group,
                textPrefix: "mixedpayload"
            )
        }
        let started = CFAbsoluteTimeGetCurrent()
        _ = try await repository.persistProjection(
            snapshots,
            source: .history,
            revision: 1,
            replaceMissingConversations: true
        )
        let importMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(diagnostics.conversationCount, 200)
        XCTAssertEqual(diagnostics.messageCount, 5_000)
        XCTAssertEqual(diagnostics.gapCount, 0)
        let loaded = try await repository.loadInitialConversations(limit: 200, messagesPerConversation: 25)
        XCTAssertEqual(loaded.0.filter { $0.kind == ConversationKind.direct.rawValue }.count, 100)
        XCTAssertEqual(loaded.0.filter { $0.kind == ConversationKind.group.rawValue }.count, 100)
        let attachment = XCTAttachment(string: String(format: "import_ms=%.0f conversations=200 messages=5000", importMilliseconds))
        attachment.name = "local-message-performance-5000"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFiftyThousandMessagesAcrossTwelveHundredConversationsImportPageSearchAndColdLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDatabasePerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        var snapshots: [LocalMessageConversationSnapshot] = []
        snapshots.reserveCapacity(1_200)
        var remaining = 50_000
        for index in 0..<1_200 {
            let count = min(remaining, index < 800 ? 42 : 41)
            remaining -= count
            snapshots.append(
                LocalMessageTestFixture.snapshot(
                    id: "stress-\(index)",
                    count: count,
                    textPrefix: index == 1_199 ? "stressneedle" : "payload"
                )
            )
        }
        XCTAssertEqual(snapshots.reduce(0) { $0 + $1.messages.count }, 50_000)

        let memoryBefore = residentMemoryBytes()
        let mainThreadMonitor = Task { @MainActor in
            var maximumStallMilliseconds = 0.0
            while !Task.isCancelled {
                let started = CFAbsoluteTimeGetCurrent()
                try? await Task.sleep(nanoseconds: 10_000_000)
                let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1_000
                maximumStallMilliseconds = max(maximumStallMilliseconds, elapsedMilliseconds - 10)
            }
            return maximumStallMilliseconds
        }
        let importStart = CFAbsoluteTimeGetCurrent()
        _ = try await repository.persistProjection(
            snapshots,
            source: .history,
            revision: 1,
            replaceMissingConversations: true
        )
        let importSeconds = CFAbsoluteTimeGetCurrent() - importStart
        mainThreadMonitor.cancel()
        let mainThreadStallMilliseconds = await mainThreadMonitor.value
        let memoryAfterImport = residentMemoryBytes()
        XCTAssertLessThan(importSeconds, 90)

        let coldStart = CFAbsoluteTimeGetCurrent()
        let loaded = try await repository.loadInitialConversations(limit: 1_200, messagesPerConversation: 50)
        let coldSeconds = CFAbsoluteTimeGetCurrent() - coldStart
        XCTAssertEqual(loaded.0.count, 1_200)
        XCTAssertLessThan(coldSeconds, 10)
        let allLoadedMessages = loaded.0.flatMap(\.messages)
        let missing = max(0, 50_000 - allLoadedMessages.count)
        let duplicate = allLoadedMessages.count - Set(allLoadedMessages.map(\.id)).count
        let orderViolation = loaded.0.reduce(0) { partial, conversation in
            partial + zip(conversation.messages, conversation.messages.dropFirst()).filter { pair in
                pair.0.channelSeq >= pair.1.channelSeq
            }.count
        }
        let unreadDrift = loaded.0.reduce(0) { $0 + abs($1.unread) }
        XCTAssertEqual(missing, 0)
        XCTAssertEqual(duplicate, 0)
        XCTAssertEqual(orderViolation, 0)
        XCTAssertEqual(unreadDrift, 0)

        let page = try await repository.loadOlderMessages(
            channelKey: "channel-stress-0",
            beforeSeq: 42,
            limit: 20
        )
        XCTAssertEqual(page.count, 20)
        XCTAssertEqual(page.map(\.channelSeq), Array(22...41).map(Int64.init))

        let searchStart = CFAbsoluteTimeGetCurrent()
        let search = try await repository.search("stressneedle41", limit: 10)
        let searchSeconds = CFAbsoluteTimeGetCurrent() - searchStart
        XCTAssertEqual(search.first?.conversationID, "stress-1199")
        XCTAssertLessThan(searchSeconds, 3)

        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(diagnostics.conversationCount, 1_200)
        XCTAssertEqual(diagnostics.messageCount, 50_000)
        XCTAssertEqual(diagnostics.gapCount, 0)
        XCTAssertEqual(diagnostics.quickCheck.lowercased(), "ok")
        let report = String(
            format: "import_ms=%.0f cold_load_ms=%.0f search_ms=%.1f resident_before_mb=%.1f resident_after_import_mb=%.1f resident_delta_mb=%.1f max_main_stall_ms=%.1f missing=%d duplicate=%d order_violation=%d unread_drift=%d wrong_scope=0",
            importSeconds * 1_000,
            coldSeconds * 1_000,
            searchSeconds * 1_000,
            Double(memoryBefore) / 1_048_576,
            Double(memoryAfterImport) / 1_048_576,
            Double(memoryAfterImport >= memoryBefore ? memoryAfterImport - memoryBefore : 0) / 1_048_576,
            mainThreadStallMilliseconds,
            missing,
            duplicate,
            orderViolation,
            unreadDrift
        )
        let attachment = XCTAttachment(string: report)
        attachment.name = "local-message-performance"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[LocalMessagePerformance] \(report)")
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    integerPointer,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

private enum LocalMessageTestFixture {
    static func context(actor: String = "actor-a", device: String = "device-a") -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: "account",
            tenantID: "tenant",
            imUID: actor,
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "app",
            deviceID: device
        )
    }

    static func message(
        id: String,
        sequence: Int64,
        outgoing: Bool = false,
        status: MessageDelivery = .sent,
        text: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            senderId: outgoing ? "actor-a" : "peer",
            senderName: outgoing ? "Me" : "Peer",
            text: text ?? "message \(sequence)",
            time: "09:00",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)),
            channelSeq: sequence,
            isOutgoing: outgoing,
            status: status,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
    }

    static func attachmentMessage(id: String, sizeBytes: Int64) -> ChatMessage {
        var message = ChatMessage(
            id: id,
            senderId: "actor-a",
            senderName: "Me",
            text: "fixture.bin",
            time: "09:00",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            channelSeq: 0,
            isOutgoing: true,
            status: .sending,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: [],
            attachmentName: "fixture.bin",
            attachmentSizeBytes: sizeBytes
        )
        message.contentType = "file"
        message.attachmentMimeType = "application/octet-stream"
        message.attachmentMediaCategory = "document"
        message.attachmentExtension = "bin"
        return message
    }

    static func outgoingAttachmentIntent(
        message: ChatMessage,
        sourceURL: URL,
        sizeBytes: Int64
    ) -> LocalMessageOutgoingIntent {
        var conversation = conversation(id: "attachment-\(message.id)", sequences: [])
        conversation.messages = [message]
        return LocalMessageOutgoingIntent(
            conversation: LocalMessageConversationSnapshot(
                conversation: conversation,
                channelID: "channel-\(message.id)",
                channelType: "person",
                currentActorID: "actor-a"
            ),
            message: CachedMessage(message: message),
            operationKind: "send_attachment",
            attachment: LocalMessageAttachmentIntent(
                fileURL: sourceURL,
                fileName: message.attachmentName ?? "fixture.bin",
                mimeType: message.attachmentMimeType,
                sizeBytes: sizeBytes
            )
        )
    }

    static func conversation(
        id: String,
        sequences: [Int64],
        kind: ConversationKind = .direct,
        coveredThrough: Int64? = nil,
        lastMsgSeq: Int64? = nil,
        unread: Int = 0,
        textPrefix: String = "message"
    ) -> Conversation {
        let messages = sequences.map { sequence in
            message(
                id: "\(id)-message-\(sequence)",
                sequence: sequence,
                text: "\(textPrefix)\(sequence)"
            )
        }
        var conversation = Conversation(
            id: id,
            title: id,
            subtitle: "Peer",
            kind: kind,
            lastMessage: messages.last?.text ?? "",
            time: "09:00",
            unread: unread,
            isPinned: false,
            isMuted: false,
            memberCount: 2,
            accentHex: 0x2266CC,
            participants: [],
            messages: messages,
            sortTimestamp: 1_700_000_000 + Double(sequences.last ?? 0)
        )
        conversation.lastMsgSeq = lastMsgSeq ?? sequences.max() ?? 0
        conversation.messageCoveredThroughSeq = coveredThrough ?? sequences.max() ?? 0
        return conversation
    }

    static func snapshot(
        id: String,
        count: Int,
        actor: String = "actor-a",
        kind: ConversationKind = .direct,
        requiresServerRevalidation: Bool = false,
        textPrefix: String = "message"
    ) -> LocalMessageConversationSnapshot {
        snapshot(
            id: id,
            sequences: count > 0 ? Array(1...count).map(Int64.init) : [],
            coveredThrough: Int64(count),
            lastMsgSeq: Int64(count),
            unread: 0,
            actor: actor,
            kind: kind,
            requiresServerRevalidation: requiresServerRevalidation,
            textPrefix: textPrefix
        )
    }

    static func snapshot(
        id: String,
        sequences: [Int64],
        coveredThrough: Int64,
        lastMsgSeq: Int64,
        unread: Int,
        actor: String = "actor-a",
        kind: ConversationKind = .direct,
        requiresServerRevalidation: Bool = false,
        textPrefix: String = "message"
    ) -> LocalMessageConversationSnapshot {
        let conversation = conversation(
            id: id,
            sequences: sequences,
            kind: kind,
            coveredThrough: coveredThrough,
            lastMsgSeq: lastMsgSeq,
            unread: unread,
            textPrefix: textPrefix
        )
        return LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-\(id)",
            channelType: kind == .group ? "group" : "person",
            currentActorID: actor,
            requiresServerRevalidation: requiresServerRevalidation
        )
    }

    static func profileContactProjection(
        revision: UInt64,
        actor: String,
        remark: String,
        blocked: Bool
    ) -> LocalProfileContactProjection {
        let user = IMUser(
            id: actor,
            userID: "user-\(actor)",
            username: "account-\(actor)",
            name: "Contact \(actor)",
            title: "",
            department: "Engineering",
            departmentPathNames: ["Engineering"],
            phone: "",
            email: "",
            status: "在线",
            enterprise: "Tenant",
            avatarSeed: 42,
            badges: []
        )
        return LocalProfileContactProjection(
            revision: revision,
            contacts: [PersistedContactUser(user)],
            remarks: [actor: remark],
            blacklist: blocked
                ? [PersistedBlacklistItem(BlacklistItem(id: actor, name: user.name, reason: "已拉黑"))]
                : [],
            originalNames: [actor: user.name]
        )
    }
}

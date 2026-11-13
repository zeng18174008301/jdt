// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
@testable import IM4Data
import Foundation
import Darwin
import GRDB
import XCTest
@testable import WenDaTong

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
        XCTAssertFalse(paths.databaseURL.path.contains("Caches/WenDaTong/Media"))
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

        // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_BEGIN
        let siblingContext = LocalMessageTestFixture.context(actor: "sibling-actor")
        let siblingCoordinator = MessagePersistenceCoordinator(applicationSupportBase: support, cachesBase: caches)
        let siblingTicket = try await siblingCoordinator.ensureTicket(context: siblingContext, sessionGeneration: 60)
        _ = try await siblingCoordinator.persist(
            ticket: siblingTicket,
            snapshots: [LocalMessageTestFixture.snapshot(id: "other-scope-kept", count: 1)],
            source: .history,
            revision: 1
        )
        await siblingCoordinator.detach(ticket: siblingTicket)
        let markerURL = support
            .appendingPathComponent("WenDaTong/LocalMessagePendingCleanup", isDirectory: true)
            .appendingPathComponent("\(scope.scopeHash).pending", isDirectory: false)
        // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_END

        try firstCoordinator.persistPendingScopeCleanup(context: context)
        XCTAssertTrue(try firstCoordinator.hasPendingScopeCleanup(context: context))
        // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_BEGIN
        let originalMarkerBytes = Data([
            "message-media-cache/1", "scope_hash=\(scope.scopeHash)",
            "legacy_scope_hash=\(scope.legacyLocalMessageScopeHash)", ""
        ].joined(separator: "\n").utf8)
        XCTAssertEqual(try Data(contentsOf: markerURL), originalMarkerBytes)
        // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_END
        await firstCoordinator.detach(ticket: oldTicket)

        let relaunched = MessagePersistenceCoordinator( // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111
            applicationSupportBase: support,
            cachesBase: caches
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.scopeDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLegacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldMediaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_BEGIN
        let reopened = try await relaunched.activateAndLoad(context: context, sessionGeneration: 61)
        XCTAssertTrue(reopened.conversations.isEmpty)
        let sibling = try await relaunched.activateAndLoad(context: siblingContext, sessionGeneration: 62)
        XCTAssertEqual(sibling.conversations.map(\.id), ["other-scope-kept"])
        // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_END
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

    func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDatabaseScopeTests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
extension MessageDatabaseScopeTests {
    func testDataBoundaryPreservesLegacyNSErrorIdentityAndModuleOwnership() {
        XCTAssertEqual(String(reflecting: SQLiteMessageRepository.self), "IM4Data.SQLiteMessageRepository")
        XCTAssertEqual(String(reflecting: MessagePersistenceCleanupTombstoneStore.self), // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111
            "IM4Data.MessagePersistenceCleanupTombstoneStore")
        XCTAssertEqual(String(reflecting: CachedMessage.self), "IM4Data.CachedMessage")
        XCTAssertEqual(String(reflecting: MessageStore.self), "WenDaTong.MessageStore")
        XCTAssertEqual(AttachmentUploadFailure(error: LocalMessageDatabaseError.staleWriter).code, .localPersistence)
        let samples: [(any Error, String, Int)] = [
            (LocalMessageDatabaseError.invalidScopeField("synthetic"), "BlueStoneIM.LocalMessageDatabaseError", 0),
            (LocalMessageDatabaseError.scopeMismatch, "BlueStoneIM.LocalMessageDatabaseError", 1),
            (LocalMessageDatabaseError.staleSession, "BlueStoneIM.LocalMessageDatabaseError", 2),
            (LocalMessageDatabaseError.staleWriter, "BlueStoneIM.LocalMessageDatabaseError", 3),
            (LocalMessageDatabaseError.backupExclusionFailed, "BlueStoneIM.LocalMessageDatabaseError", 4),
            (LocalMessageDatabaseError.missingStagedAttachment, "BlueStoneIM.LocalMessageDatabaseError", 5),
            (LocalMessageDatabaseError.identityConflict, "BlueStoneIM.LocalMessageDatabaseError", 6),
            (LocalMessageDatabaseError.authorityRejected, "BlueStoneIM.LocalMessageDatabaseError", 7),
            (LocalMessageDatabaseError.databaseCorrupt, "BlueStoneIM.LocalMessageDatabaseError", 8),
            (MediaCacheIdentityError.invalidRequiredField("synthetic"), "BlueStoneIM.MediaCacheIdentityError", 0),
            (MediaCacheIdentityError.invalidScopeHash, "BlueStoneIM.MediaCacheIdentityError", 1),
            (MediaCacheIdentityError.missingStableResourceID, "BlueStoneIM.MediaCacheIdentityError", 2),
            (MediaCacheIdentityError.missingContentVersion, "BlueStoneIM.MediaCacheIdentityError", 3)
        ]
        for (error, domain, code) in samples {
            let bridged = error as NSError
            XCTAssertEqual(bridged.domain, domain)
            XCTAssertEqual(bridged.code, code)
            XCTAssertTrue(bridged.userInfo.isEmpty)
            XCTAssertEqual(bridged.localizedDescription, NSError(domain: domain, code: code).localizedDescription)
        }
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

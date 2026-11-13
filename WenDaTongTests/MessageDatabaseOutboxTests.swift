import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Darwin
import GRDB
import XCTest
@testable import WenDaTong

extension MessageDatabaseSemanticsTests {
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

    func testDiscardFailedOutgoingRemovesMessageAndFencesOldSnapshotAndRetry() async throws {
        let repository = try await makeRepository(suffix: "discard-failed-outgoing")
        var conversation = LocalMessageTestFixture.conversation(id: "discard-conversation", sequences: [])
        let local = LocalMessageTestFixture.message(id: "local_discard", sequence: 0, outgoing: true, status: .failed)
        conversation.messages = [local]
        let projection = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "discard-channel",
            channelType: "person",
            currentActorID: "actor-a"
        )
        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(conversation: projection, message: CachedMessage(message: local), operationKind: "send_text", attachment: nil),
            revision: 1
        )
        try await repository.updateOutboxState(clientMessageID: local.id, state: .retryWait)

        let discarded = try await repository.discardFailedOutgoing(
            clientMessageID: local.id, conversationID: conversation.id,
            channelID: projection.channelID, channelType: projection.channelType
        )
        XCTAssertTrue(discarded)
        try await repository.updateOutboxState(clientMessageID: local.id, state: .retryWait)
        _ = try await repository.persistProjection([projection], source: .localMutation, revision: 2, replaceMissingConversations: false)

        let authority = try await repository.outgoingAuthority(clientMessageID: local.id)
        let recoverable = try await repository.recoverableOutbox()
        let (cached, _) = try await repository.loadInitialConversations()
        XCTAssertEqual(authority?.state, LocalMessageOutboxState.cancelled.rawValue)
        XCTAssertTrue(recoverable.isEmpty)
        XCTAssertTrue(try XCTUnwrap(cached.first).messages.isEmpty)
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

        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        try await coordinator.reserveOutgoingSend(ticket: loaded.ticket, clientMessageID: message.id)
        try await coordinator.updateOutboxState(ticket: loaded.ticket, clientMessageID: message.id, state: .retryWait)
        let reopened = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let restored = try await reopened.activateAndLoad(context: context, sessionGeneration: 45)
        for trigger: LocalMessageOutboxReplayTrigger in [.automatic, .userInitiated] {
            let blocked = try await reopened.claimOutboxForReplay(
                ticket: restored.ticket, authorizationGeneration: 45, trigger: trigger,
                clientMessageID: trigger == .userInitiated ? message.id : nil,
                now: Date().addingTimeInterval(600))
            XCTAssertTrue(blocked.isEmpty, "trigger=\(trigger)")
        }
        let retained = try await reopened.outgoingAuthority(ticket: restored.ticket, clientMessageID: message.id)
        XCTAssertEqual(retained?.state, LocalMessageOutboxState.confirmationRequired.rawValue)
        await reopened.releaseUnsentOutgoing(ticket: restored.ticket, clientMessageID: message.id)
        let released = try await reopened.claimOutboxForReplay(
            ticket: restored.ticket, authorizationGeneration: 45, trigger: .userInitiated, clientMessageID: message.id)
        XCTAssertEqual(released.map(\.clientMessageID), [message.id])
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    func testLegacyUnconfirmedOutboxReopenProtectsBothClaimsAcrossToggleAndReconcilesOriginalID() async throws {
        let root = makeRoot("v5-legacy-claim")
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let otherScope = try LocalMessageScope(context: LocalMessageTestFixture.context(actor: "actor-b"))
        func paths(_ scope: LocalMessageScope) throws -> MessageDatabasePaths {
            try MessageDatabasePaths(scope: scope, applicationSupportBase: root.appendingPathComponent("support"),
                                     cachesBase: root.appendingPathComponent("caches"))
        }
        let currentPaths = try paths(scope)
        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: currentPaths)
        let other = try await SQLiteMessageRepository.open(scope: otherScope, paths: paths(otherScope))
        let suite = "route-v5-outbox-upgrade.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyStore = IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: ["-WXT.RouteV5.im_api", "NO"])
        let v5Store = IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: ["-WXT.RouteV5.im_api", "YES"])
        let fixtureTime = Date(timeIntervalSince1970: 1_700_000_000)
        let claimTime = fixtureTime.addingTimeInterval(600)
        let channel = "legacy-room"
        func seed(_ repo: SQLiteMessageRepository, _ id: String, state: LocalMessageOutboxState,
                  uncertain: Bool = false, knownUnsent: Bool = false) async throws {
            var conversation = LocalMessageTestFixture.conversation(id: channel, sequences: [])
            let message = LocalMessageTestFixture.message(id: id, sequence: 0, outgoing: true, status: .failed)
            conversation.messages = [message]
            let projection = LocalMessageConversationSnapshot(conversation: conversation, channelID: channel,
                channelType: "person", currentActorID: "actor-a")
            _ = try await repo.enqueueOutgoing(.init(conversation: projection, message: CachedMessage(message: message),
                operationKind: "send_text", attachment: nil), revision: 1)
            if state != .ready {
                try await repo.updateOutboxState(clientMessageID: id, state: .sending, now: fixtureTime)
                if knownUnsent {
                    try await repo.reserveOutgoingSend(clientMessageID: id)
                    try await repo.releaseUnsentOutgoing(clientMessageID: id)
                }
                try await repo.updateOutboxState(clientMessageID: id, state: state, uncertain: uncertain, now: fixtureTime)
            }
        }
        try await seed(repository, "local-legacy-uncertain", state: .uncertain, uncertain: true)
        try await seed(repository, "local-legacy-retry", state: .retryWait)
        try await seed(repository, "local-legacy-awaiting", state: .awaitingAcknowledgement)
        try await seed(repository, "local-known-unsent", state: .retryWait, knownUnsent: true)
        try await seed(repository, "local-never-started", state: .ready)
        let source = root.appendingPathComponent("presend.bin")
        try Data([2, 4, 6]).write(to: source)
        let staged = LocalMessageTestFixture.attachmentMessage(id: "local-presend-attachment", sizeBytes: 3)
        _ = try await repository.enqueueOutgoing(LocalMessageTestFixture.outgoingAttachmentIntent(
            message: staged, sourceURL: source, sizeBytes: 3), revision: 1)
        try await repository.updateOutboxState(clientMessageID: staged.id, state: .sending, now: fixtureTime)
        try await repository.updateOutboxState(clientMessageID: staged.id, state: .retryWait,
                                               attachmentPhase: "finalized", now: fixtureTime)
        try await seed(other, "local-legacy-uncertain", state: .uncertain, uncertain: true)
        let reopened = try await SQLiteMessageRepository.open(scope: scope, paths: currentPaths)
        let stillLegacy = try await reopened.outgoingAuthority(clientMessageID: "local-legacy-retry")
        XCTAssertFalse(legacyStore.routeV5Enabled("im_api"))
        XCTAssertEqual(stillLegacy?.state, "retry_wait")

        let auto = try await reopened.claimOutboxForReplay(authorizationGeneration: 8, trigger: .automatic,
            clientMessageID: nil, now: claimTime, holdLegacyUnconfirmedSends: v5Store.routeV5Enabled("im_api"))
        XCTAssertEqual(Set(auto.map(\.clientMessageID)), ["local-known-unsent", "local-never-started", staged.id])
        try await seed(reopened, "local-legacy-manual", state: .retryWait)
        let manual = try await reopened.claimOutboxForReplay(authorizationGeneration: 8, trigger: .userInitiated,
            clientMessageID: "local-legacy-manual", now: claimTime, holdLegacyUnconfirmedSends: v5Store.routeV5Enabled("im_api"))
        XCTAssertTrue(manual.isEmpty)
        let liveClaim = try await reopened.claimOutboxForReplay(authorizationGeneration: 8, trigger: .userInitiated,
            clientMessageID: "local-known-unsent", now: claimTime, holdLegacyUnconfirmedSends: true)
        XCTAssertTrue(liveClaim.isEmpty)
        let live = try await reopened.outgoingAuthority(clientMessageID: "local-known-unsent")
        XCTAssertEqual(live?.state, "sending")

        let coldOff = try await SQLiteMessageRepository.open(scope: scope, paths: currentPaths)
        for id in ["local-legacy-uncertain", "local-legacy-retry", "local-legacy-awaiting", "local-legacy-manual"] {
            let authority = try await coldOff.outgoingAuthority(clientMessageID: id)
            XCTAssertEqual(authority?.state, "confirmation_required")
            let replay = try await coldOff.claimOutboxForReplay(authorizationGeneration: 9, trigger: .userInitiated,
                clientMessageID: id, now: claimTime, holdLegacyUnconfirmedSends: legacyStore.routeV5Enabled("im_api"))
            XCTAssertTrue(replay.isEmpty)
        }
        let autoOff = try await coldOff.claimOutboxForReplay(authorizationGeneration: 9, trigger: .automatic,
            clientMessageID: nil, now: claimTime, holdLegacyUnconfirmedSends: legacyStore.routeV5Enabled("im_api"))
        XCTAssertTrue(autoOff.isEmpty)
        let matched = try await coldOff.acknowledgeOutgoingAuthority(clientMessageID: "local-legacy-retry",
            authoritativeMessageID: "server-committed", authoritativeChannelSeq: 4, channelKey: channel)
        XCTAssertTrue(matched)
        let reconciled = try await coldOff.outgoingAuthority(clientMessageID: "local-legacy-retry")
        XCTAssertEqual(reconciled?.authoritativeMessageID, "server-committed")
        XCTAssertEqual(reconciled?.isAcknowledged, true)
        let otherAuthority = try await other.outgoingAuthority(clientMessageID: "local-legacy-uncertain")
        XCTAssertEqual(otherAuthority?.state, "uncertain")
    }

    func testProtectedMessageSendAttachmentSurvivesRealColdCleanupWhileOrphansAreRemoved() async throws {
        let root = makeRoot("v5-protected-staging")
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let otherScope = try LocalMessageScope(context: LocalMessageTestFixture.context(actor: "actor-b"))
        func paths(_ scope: LocalMessageScope) throws -> MessageDatabasePaths {
            try MessageDatabasePaths(scope: scope, applicationSupportBase: root.appendingPathComponent("support"),
                                     cachesBase: root.appendingPathComponent("caches"))
        }
        let localPaths = try paths(scope)
        let otherPaths = try paths(otherScope)
        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: localPaths)
        let other = try await SQLiteMessageRepository.open(scope: otherScope, paths: otherPaths)
        let source = root.appendingPathComponent("source.bin")
        let payload = Data([1, 3, 5, 7])
        try payload.write(to: source)
        let message = LocalMessageTestFixture.attachmentMessage(id: "local-protected-file", sizeBytes: Int64(payload.count))
        let intent = LocalMessageTestFixture.outgoingAttachmentIntent(message: message, sourceURL: source,
                                                                     sizeBytes: Int64(payload.count))
        _ = try await repository.enqueueOutgoing(intent, revision: 1)
        _ = try await other.enqueueOutgoing(intent, revision: 1)
        try await repository.updateOutboxState(clientMessageID: message.id, state: .awaitingAcknowledgement,
                                               fileID: "file-fixture", attachmentPhase: "message_send")
        try await repository.reserveOutgoingSend(clientMessageID: message.id)
        let localOrphan = localPaths.stagingDirectory.appendingPathComponent("local-orphan.pending")
        let otherOrphan = otherPaths.stagingDirectory.appendingPathComponent("other-orphan.pending")
        try payload.write(to: localOrphan)
        try payload.write(to: otherOrphan)

        let reopened = try await SQLiteMessageRepository.open(scope: scope, paths: localPaths)
        let rows = try await reopened.recoverableOutbox()
        let held = try XCTUnwrap(rows.first(where: { $0.clientMessageID == message.id }))
        XCTAssertEqual(held.state, "confirmation_required")
        XCTAssertEqual(held.attachmentPhase, "message_send")
        let recovered = try await reopened.loadStagedAttachment(for: held)
        XCTAssertEqual(recovered, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localOrphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherOrphan.path))
        let otherFile = otherPaths.stagedAttachmentURL(clientMessageID: message.id)
        XCTAssertEqual(try Data(contentsOf: otherFile), payload)

        _ = try await SQLiteMessageRepository.open(scope: otherScope, paths: otherPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherOrphan.path))
        XCTAssertEqual(try Data(contentsOf: localPaths.stagedAttachmentURL(clientMessageID: message.id)), payload)
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

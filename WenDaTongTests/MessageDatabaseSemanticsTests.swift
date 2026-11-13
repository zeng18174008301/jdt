// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
@testable import IM4Data
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
import Foundation
import Darwin
import GRDB
import XCTest
@testable import WenDaTong

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

        var recalled = revisionThree
        recalled.status = .recalled
        recalled.text = "你撤回了一条消息"
        conversation.messages = [recalled]
        func currentSnapshot() -> LocalMessageConversationSnapshot {
            LocalMessageConversationSnapshot(
                conversation: conversation, channelID: "channel-edit-conversation",
                channelType: "person", currentActorID: "actor-a"
            )
        }
        _ = try await repository.persistProjection(
            [currentSnapshot()], source: .localMutation, revision: 4, replaceMissingConversations: false
        )
        conversation.messages = [revisionThree]
        _ = try await repository.persistProjection(
            [currentSnapshot()], source: .history, revision: 5, replaceMissingConversations: false
        )
        loaded = try await repository.loadInitialConversations(limit: 10, messagesPerConversation: 10)
        XCTAssertEqual(loaded.0.first?.messages.first?.status, MessageDelivery.recalled.rawValue)
        XCTAssertEqual(loaded.0.first?.messages.first?.text, "你撤回了一条消息")
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
        XCTAssertEqual(try Data(contentsOf: staged), Data("staged-data".utf8))
        let reopened = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        _ = try await reopened.activateAndLoad(context: context, sessionGeneration: 2)
        XCTAssertEqual(try Data(contentsOf: staged), Data("staged-data".utf8))

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
        XCTAssertEqual(diagnostics.schemaVersion, 4) // Frozen0581 local-message-v4-media-authority contract.
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

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    func testSearchCalendarReadsPersistedDatesWithinVisibilityBoundary() async throws {
        let repository = try await makeRepository(suffix: "search-calendar")
        var conversation = LocalMessageTestFixture.snapshot(id: "search-calendar", count: 0).metadata.model
        let day = Date(timeIntervalSince1970: 1_730_419_200)
        let tomorrow = day.addingTimeInterval(86_400)
        conversation.messages = (1...4).map { sequence in
            var message = LocalMessageTestFixture.message(id: "calendar-\(sequence)", sequence: Int64(sequence),
                status: sequence == 4 ? .recalled : .sent)
            message.createdAt = sequence == 4 ? tomorrow : day.addingTimeInterval(Double(sequence))
            return message
        }
        let snapshot = LocalMessageConversationSnapshot(conversation: conversation, channelID: "calendar-channel",
            channelType: "person", currentActorID: "actor-a")
        _ = try await repository.persistProjection([snapshot], source: .history, revision: 1,
            replaceMissingConversations: false)
        let hits = try await repository.loadSearchDateMessages(conversationID: conversation.id,
            days: [DateInterval(start: day, end: tomorrow), DateInterval(start: tomorrow, duration: 86_400)],
            minimumSequence: 2, excludedIDs: ["calendar-2"], excludedSequences: [])
        XCTAssertEqual(hits.map(\.id), ["calendar-3"])
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    func makeRepository(suffix: String) async throws -> SQLiteMessageRepository {
        let root = makeRoot(suffix)
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        return try await SQLiteMessageRepository.open(scope: scope, paths: paths)
    }

    func makeRoot(_ suffix: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDatabaseSemanticsTests-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }
}

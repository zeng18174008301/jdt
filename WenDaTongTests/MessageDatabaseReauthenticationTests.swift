import Foundation
import Darwin
import GRDB
import XCTest
@testable import WenDaTong

extension MessageDatabaseSemanticsTests {
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
}

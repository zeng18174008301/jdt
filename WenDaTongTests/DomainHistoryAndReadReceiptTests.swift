import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import IM4Domain
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func testConversationStoreOlderHistoryAvailabilityPlanBuildsTargetAndSkipsUnavailableStates() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: " c1 ", unread: 0, lastMsgSeq: 8, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m8", seq: 8)
        ]

        let target = ConversationStore.OlderHistoryAvailabilityTarget(
            historyKey: "scope|c1",
            conversationID: "c1",
            oldestSeq: 2
        )
        XCTAssertEqual(
            store.olderHistoryAvailabilityPlan(for: conversation, historyKey: " scope|c1 "),
            .available(target)
        )
        XCTAssertEqual(
            store.olderHistoryAvailabilityTarget(for: conversation, historyKey: " scope|c1 "),
            target
        )

        store.markOlderHistoryReachedStart(historyKey: "scope|c1", conversationID: "c1", message: "done")
        XCTAssertEqual(
            store.olderHistoryAvailabilityPlan(for: conversation, historyKey: " scope|c1 "),
            .reachedStart(historyKey: "scope|c1", conversationID: "c1")
        )
        XCTAssertNil(store.olderHistoryAvailabilityTarget(for: conversation, historyKey: " scope|c1 "))

        let sparseStore = ConversationStore(scope: TestMessageMemoryScope.value)
        var boundaryConversation = makeConversation(id: "c2", unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        boundaryConversation.messages = [
            makeMessage(id: "m1", seq: 1)
        ]
        XCTAssertEqual(
            sparseStore.olderHistoryAvailabilityPlan(for: boundaryConversation, historyKey: "scope|c2"),
            .unavailable(historyKey: "scope|c2", conversationID: "c2")
        )

        var transientOnlyConversation = makeConversation(id: "c3", unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        transientOnlyConversation.messages = [
            makeMessage(id: "local_1", seq: 2),
            makeMessage(id: "failed", seq: 3, status: .failed)
        ]
        XCTAssertEqual(
            sparseStore.olderHistoryAvailabilityPlan(for: transientOnlyConversation, historyKey: "scope|c3"),
            .unavailable(historyKey: "scope|c3", conversationID: "c3")
        )
    }

    func testConversationStoreMessageReceiptsSyncPlanBuildsCommandAndSkipsInFlight() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let command = ConversationStore.MessageReceiptsSyncCommand(
            syncKey: "scope|c1",
            channelID: "c1",
            channelType: "group"
        )

        XCTAssertEqual(
            store.messageReceiptsSyncPlan(syncKey: "", channelID: "c1", channelType: "group"),
            .skip(
                ConversationStore.MessageReceiptsSyncCommand(syncKey: "", channelID: "c1", channelType: "group"),
                reason: "empty read receipt key"
            )
        )
        XCTAssertEqual(
            store.messageReceiptsSyncPlan(syncKey: "scope|c1", channelID: "c1", channelType: "group"),
            .sync(command)
        )

        XCTAssertTrue(store.beginMessageReceiptsSync(command))
        XCTAssertEqual(
            store.messageReceiptsSyncPlan(syncKey: "scope|c1", channelID: "c1", channelType: "group"),
            .skip(command, reason: "read receipts already in flight")
        )

        store.finishMessageReceiptsSync(syncKey: command.syncKey)
        XCTAssertEqual(
            store.messageReceiptsSyncPlan(
                syncKey: " scope|c2 ",
                channelID: " c2 ",
                channelType: " group ",
                afterSeq: -7,
                receiptType: " ",
                limit: 0
            ),
            .sync(
                ConversationStore.MessageReceiptsSyncCommand(
                    syncKey: "scope|c2",
                    channelID: "c2",
                    channelType: "group",
                    afterSeq: 0,
                    receiptType: "",
                    limit: 1
                )
            )
        )
    }

    func testConversationStoreMessageExtrasSyncPlanBuildsCommandAndSkipsInFlight() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let command = ConversationStore.MessageExtrasSyncCommand(
            syncKey: "scope|c1",
            channelID: "c1",
            channelType: "group"
        )

        XCTAssertEqual(
            store.messageExtrasSyncPlan(syncKey: "", channelID: "c1", channelType: "group"),
            .skip(
                ConversationStore.MessageExtrasSyncCommand(syncKey: "", channelID: "c1", channelType: "group"),
                reason: "empty message extras key"
            )
        )
        XCTAssertEqual(
            store.messageExtrasSyncPlan(syncKey: "scope|c1", channelID: "c1", channelType: "group"),
            .sync(command)
        )

        XCTAssertTrue(store.beginMessageExtrasSync(command))
        XCTAssertEqual(
            store.messageExtrasSyncPlan(syncKey: "scope|c1", channelID: "c1", channelType: "group"),
            .skip(command, reason: "message extras already in flight")
        )

        store.finishMessageExtrasSync(syncKey: command.syncKey)
        XCTAssertEqual(
            store.messageExtrasSyncPlan(
                syncKey: " scope|c2 ",
                channelID: " c2 ",
                channelType: " group ",
                afterVersion: -3,
                limit: 0
            ),
            .sync(
                ConversationStore.MessageExtrasSyncCommand(
                    syncKey: "scope|c2",
                    channelID: "c2",
                    channelType: "group",
                    afterVersion: 0,
                    limit: 1
                )
            )
        )
    }

    func testConversationStoreReadAckSyncLifecycleUsesIndependentOperation() {
        let engine = DefaultSyncEngine()
        let store = ConversationStore(messageSyncEngine: engine)
        let readAckRequest = SyncEngineRequest(
            operation: .readAck,
            historyKey: "group|c1",
            reason: "assert"
        )
        let receiptRequest = SyncEngineRequest(
            operation: .readReceipt,
            historyKey: "group|c1",
            reason: "assert"
        )

        XCTAssertFalse(store.beginReadAckSync(syncKey: ""))
        XCTAssertTrue(store.beginReadAckSync(syncKey: "group|c1"))
        XCTAssertTrue(store.isReadAckSyncInFlight(syncKey: "group|c1"))
        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1"))
        XCTAssertTrue(store.beginMessageReceiptsSync(syncKey: "group|c1"))
        XCTAssertTrue(engine.isInFlight(readAckRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))

        store.finishReadAckSync(syncKey: "group|c1")

        XCTAssertFalse(engine.isInFlight(readAckRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))
    }

    func testConversationStoreReadAckSyncPlanCoalescesHigherInFlightTargets() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let command = ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 11)

        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "", targetSeq: 11),
            .skip(ConversationStore.ReadAckCommand(syncKey: "", targetSeq: 11), reason: "empty read ack key")
        )

        store.rememberRead(key: "group|c1", readSeq: 10)
        XCTAssertEqual(store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 10), .clearLocally(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 10)))
        XCTAssertEqual(store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 11), .remoteAck(command))

        XCTAssertTrue(store.beginReadAckSync(command))
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 11),
            .skip(command, reason: "read ack target already pending")
        )
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 12),
            .queue(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 12))
        )
        XCTAssertTrue(store.queueReadAckSync(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 12)))
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 13),
            .queue(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 13))
        )
        XCTAssertTrue(store.queueReadAckSync(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 13)))
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 12),
            .skip(
                ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 12),
                reason: "read ack target already pending"
            )
        )

        let followup = try XCTUnwrap(store.finishReadAckSync(syncKey: "group|c1"))
        XCTAssertEqual(followup, ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 13))
        store.rememberRead(key: "group|c1", readSeq: 11)

        XCTAssertEqual(store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 11), .clearLocally(command))
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 13),
            .remoteAck(followup)
        )
    }

    func testConversationStoreReadAckClaimFinishCannotReleaseNewScopeGeneration() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let command = ConversationStore.ReadAckCommand(syncKey: "group|same-channel", targetSeq: 1)
        let oldClaim = try XCTUnwrap(store.beginReadAckSyncClaim(command))

        store.reset()

        let newClaim = try XCTUnwrap(store.beginReadAckSyncClaim(command))
        XCTAssertNil(store.finishReadAckSync(oldClaim))
        XCTAssertTrue(store.isReadAckSyncInFlight(syncKey: command.syncKey))
        XCTAssertNil(store.finishReadAckSync(newClaim))
        XCTAssertFalse(store.isReadAckSyncInFlight(syncKey: command.syncKey))
    }

    func testConversationStoreReadAckSyncDedupesByMonotonicTargetSeq() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.rememberRead(key: "group|c1", readSeq: 10)

        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 9))
        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 10))
        XCTAssertTrue(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 11))
        XCTAssertTrue(store.isReadAckSyncInFlight(syncKey: "group|c1"))
        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 11))
        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 12))

        store.finishReadAckSync(syncKey: "group|c1")
        store.rememberRead(key: "group|c1", readSeq: 11)

        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 11))
        XCTAssertTrue(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 12))
    }

    func testConversationStoreSidecarSyncUsesInjectedEngineOperationsIndependently() {
        let engine = DefaultSyncEngine()
        let store = ConversationStore(messageSyncEngine: engine)
        let extraRequest = SyncEngineRequest(
            operation: .messageExtra,
            historyKey: "scope|c1",
            reason: "assert"
        )
        let receiptRequest = SyncEngineRequest(
            operation: .readReceipt,
            historyKey: "scope|c1",
            reason: "assert"
        )

        XCTAssertTrue(store.beginMessageExtrasSync(syncKey: "scope|c1"))
        XCTAssertTrue(store.beginMessageReceiptsSync(syncKey: "scope|c1"))
        XCTAssertTrue(engine.isInFlight(extraRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))

        store.finishMessageExtrasSync(syncKey: "scope|c1")
        XCTAssertFalse(engine.isInFlight(extraRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))
    }

    func testConversationStoreApplyRemoteReadReceiptsMergesDetailedReceipts() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, isOutgoing: true)
        message.unreadCount = 2
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])
        let receipt = try decodeRemoteReceipt("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "im_uid": "reader-1",
          "device_id": "ios",
          "receipt_type": "read",
          "channel_seq": 1,
          "created_at": "2026-06-23T10:00:00Z",
          "display_name": "Reader One"
        }
        """)

        let didApply = store.applyRemoteReadReceipts(
            [receipt],
            channelID: "remote-c1",
            readReceiptsEnabled: true,
            channelIDForConversation: { _ in "remote-c1" },
            makeReadReceipt: makeReadReceipt(from:conversation:)
        )

        XCTAssertTrue(didApply)
        let updated = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertEqual(updated.status, .read)
        XCTAssertTrue(updated.readStateKnown)
        XCTAssertTrue(updated.canViewReadDetails)
        XCTAssertEqual(updated.readCount, 1)
        XCTAssertEqual(updated.unreadCount, 1)
        XCTAssertEqual(updated.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(updated.readBy.first?.device, "ios")
    }

    func testConversationStoreApplyRemoteReadReceiptsCanUseChannelSeqFallback() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "remote-c1", kind: .group, unread: 0, lastMsgSeq: 4, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, isOutgoing: true),
            makeMessage(id: "m4", seq: 4, isOutgoing: true),
            makeMessage(id: "incoming", seq: 2, isOutgoing: false)
        ]
        store.commitConversationSnapshots([conversation])
        let receipt = try decodeRemoteReceipt("""
        {
          "message_id": "",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "im_uid": "",
          "device_id": "",
          "receipt_type": "read",
          "channel_seq": 2
        }
        """)

        let didApply = store.applyRemoteReadReceipts(
            [receipt],
            channelID: "remote-c1",
            readReceiptsEnabled: true,
            channelIDForConversation: { $0.id },
            makeReadReceipt: makeReadReceipt(from:conversation:)
        )

        XCTAssertTrue(didApply)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .read)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].readCount, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[1].status, .sent)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[2].status, .sent)
    }

    func testConversationStoreDeliveredReceiptIsMonotonicAndNeverDowngradesRead() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "remote-c1", kind: .direct, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var first = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        var second = makeMessage(id: "m2", seq: 2, status: .read, isOutgoing: true)
        second.readStateKnown = true
        conversation.messages = [first, second]
        store.commitConversationSnapshots([conversation])
        let delivered = try decodeRemoteReceipt("""
        {
          "message_id": "",
          "channel_id": "remote-c1",
          "channel_type": "direct",
          "from_uid": "sender-1",
          "receipt_type": "delivered",
          "channel_seq": 2
        }
        """)

        XCTAssertTrue(store.applyRemoteReadReceipts(
            [delivered],
            channelID: "remote-c1",
            readReceiptsEnabled: false,
            channelIDForConversation: { $0.id },
            makeReadReceipt: makeReadReceipt(from:conversation:)
        ))

        first = store.conversationMessageSnapshots()[0].messages[0]
        second = store.conversationMessageSnapshots()[0].messages[1]
        XCTAssertTrue(first.deliveryStateKnown)
        XCTAssertEqual(first.status, .sent)
        XCTAssertTrue(second.deliveryStateKnown)
        XCTAssertEqual(second.status, .read)
        XCTAssertTrue(second.readStateKnown)
    }

    func testConversationStoreApplyRemoteReadReceiptDetailsUpdatesCountsReceiptsAndReactions() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        ]
        store.commitConversationSnapshots([conversation])
        let response = try decodeRemoteReadReceiptResponse("""
        {
          "read": false,
          "read_count": 2,
          "unread_count": 1,
          "can_view_details": true,
          "items": [
            {
              "message_id": "m1",
              "channel_id": "remote-c1",
              "channel_type": "group",
              "im_uid": "reader-1",
              "device_id": "ios",
              "receipt_type": "read",
              "channel_seq": 1,
              "created_at": "2026-06-23T10:00:00Z",
              "display_name": "Reader One"
            }
          ],
          "unread_items": [
            {
              "im_uid": "reader-2",
              "display_name": "Reader Two",
              "device_id": "",
              "read_at": null
            }
          ],
          "reactions": [
            {
              "message_id": "m1",
              "channel_id": "remote-c1",
              "channel_type": "group",
              "operator_uid": "reader-1",
              "emoji": "ok",
              "action": "add",
              "payload": { "display_name": "Reader One" },
              "created_at": "2026-06-23T10:00:01Z"
            }
          ]
        }
        """)

        let didApply = store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: " m1 ",
            conversationID: " local-c1 ",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        )

        XCTAssertTrue(didApply)
        let updated = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertEqual(updated.status, .read)
        XCTAssertTrue(updated.readStateKnown)
        XCTAssertTrue(updated.canViewReadDetails)
        XCTAssertEqual(updated.readCount, 2)
        XCTAssertEqual(updated.unreadCount, 1)
        XCTAssertEqual(updated.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(updated.unreadBy.map(\.user.id), ["reader-2"])
        XCTAssertEqual(updated.unreadBy.first?.device, "未同步")
        XCTAssertEqual(updated.reactionDetails.map(\.id), ["m1_reader-1_ok"])
    }

    func testConversationStoreApplyRemoteReadReceiptDetailsKeepsReadMembersOutOfUnreadSection() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        ]
        store.commitConversationSnapshots([conversation])
        let response = try decodeRemoteReadReceiptResponse("""
        {
          "read": true,
          "read_count": 1,
          "unread_count": 3,
          "can_view_details": true,
          "items": [
            {
              "message_id": "m1",
              "channel_id": "remote-c1",
              "channel_type": "group",
              "im_uid": "reader-1",
              "device_id": "ios",
              "receipt_type": "read",
              "channel_seq": 1,
              "created_at": "2026-06-23T10:00:00Z",
              "display_name": "Reader One"
            }
          ],
          "unread_items": [
            {
              "im_uid": "reader-1",
              "display_name": "Reader One",
              "device_id": "ios",
              "read_at": null
            },
            {
              "im_uid": "reader-2",
              "display_name": "Reader Two",
              "device_id": "",
              "read_at": null
            },
            {
              "im_uid": "reader-3",
              "display_name": "Reader Three",
              "device_id": "web",
              "readAt": "2026-06-23T10:00:02Z"
            }
          ],
          "reactions": []
        }
        """)

        XCTAssertTrue(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))

        let updated = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertEqual(updated.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(updated.unreadBy.map(\.user.id), ["reader-2"])
        XCTAssertEqual(updated.unreadCount, 1)
    }

    func testConversationStoreApplyRemoteReadReceiptDetailsClearsPrivateDetailsAndPreservesConfirmedRead() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: true)
        message.readBy = [makeReadReceipt(userID: "reader-1")]
        message.unreadBy = [makeReadReceipt(userID: "reader-2")]
        message.readCount = 1
        message.unreadCount = 2
        message.readStateKnown = true
        message.canViewReadDetails = true
        message.reactionDetails = [ReactionDetail(id: "old", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")]
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])
        let response = try decodeRemoteReadReceiptResponse("""
        {
          "read": false,
          "can_view_details": false,
          "items": [],
          "unread_items": [],
          "reactions": []
        }
        """)

        XCTAssertTrue(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))

        let updated = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertEqual(updated.status, .read)
        XCTAssertTrue(updated.readStateKnown)
        XCTAssertFalse(updated.canViewReadDetails)
        XCTAssertTrue(updated.readBy.isEmpty)
        XCTAssertTrue(updated.unreadBy.isEmpty)
        XCTAssertNil(updated.readCount)
        XCTAssertNil(updated.unreadCount)
        XCTAssertEqual(updated.reactionDetails.map(\.id), ["old"])
    }

    func testConversationStoreApplyRemoteReadReceiptDetailsSkipsInvalidMissingOrIncomingTargets() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var incoming = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: false)
        incoming.canViewReadDetails = false
        conversation.messages = [incoming]
        store.commitConversationSnapshots([conversation])
        let response = try decodeRemoteReadReceiptResponse("""
        {
          "read": true,
          "read_count": 1,
          "can_view_details": true,
          "items": [],
          "unread_items": [],
          "reactions": []
        }
        """)

        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: " ",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))
        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: " ",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))
        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "missing",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))
        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: "missing",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))
        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))

        let updated = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertEqual(updated.status, .sent)
        XCTAssertFalse(updated.readStateKnown)
        XCTAssertFalse(updated.canViewReadDetails)
        XCTAssertTrue(updated.readBy.isEmpty)
    }

    func testConversationStoreReadReceiptSummaryAndStripDetails() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "sender",
          "content_type": "text",
          "payload": {},
          "status": "normal",
          "read_status": "read",
          "read_count": 2,
          "read_at": "2026-06-23T10:00:00Z"
        }
        """)
        var message = makeMessage(id: "m1", seq: 1, isOutgoing: true)

        store.applyRemoteReadSummary(from: remote, to: &message, readReceiptsEnabled: true)

        XCTAssertEqual(message.status, .read)
        XCTAssertTrue(message.readStateKnown)
        XCTAssertEqual(message.readCount, 2)

        message.readBy = [makeReadReceipt(userID: "reader-1")]
        message.unreadBy = [makeReadReceipt(userID: "reader-2")]
        message.unreadCount = 3
        message.canViewReadDetails = true
        message.reactionDetails = [
            ReactionDetail(id: "r1", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")
        ]
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.stripReadReceiptDetailsFromAllMessages())
        let stripped = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertEqual(stripped.status, .sent)
        XCTAssertFalse(stripped.readStateKnown)
        XCTAssertFalse(stripped.canViewReadDetails)
        XCTAssertTrue(stripped.readBy.isEmpty)
        XCTAssertTrue(stripped.unreadBy.isEmpty)
        XCTAssertNil(stripped.readCount)
        XCTAssertNil(stripped.unreadCount)
        XCTAssertTrue(stripped.reactionDetails.isEmpty)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111_BEGIN
extension DomainStoreTests {
    func testPhase6AliasFallbackTracesInstalledFrameThroughMountedObservationAndReentry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phase6-alias-\(UUID().uuidString)")
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"items":[{"message_id":"alias-fallback-arrived","channel_id":"uid-1:uid-2","channel_type":"direct","channel_seq":2,"from_uid":"uid-2","content_type":"text","payload":{"text":"alias fallback"},"status":"normal","created_at":"2026-08-27T10:00:00Z"}],"has_more_before":false}}"#.utf8),
            isHTTPResponse: true, statusCode: 200)])
        let context = makeAuthenticatedAPIContext(accountID: UUID().uuidString)
        let state = AppState(api: makeSearchJumpAPI(transport: transport), voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshot")),
            messagePersistence: persistence, protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
        state.setCurrentUser(makeUser(id: "uid-1"))
        var row = makeConversation(id: "local-phase6-alias", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.participants = [makeUser(id: "uid-2")]
        row.messages = [makeMessage(id: "alias-base", senderId: "uid-2", seq: 1)]
        let localID = row.id
        XCTAssertEqual(state.remoteChannelID(for: row), "uid-1:uid-2")
        state.conversationStore.hydrateCachedConversations([row])
        let hosted = hostForSimulatorUI(NavigationView { AppFeatureComposition.chatRouting().makeChat(localID) }
            .navigationViewStyle(.stack).appStateEnvironment(state), size: CGSize(width: 390, height: 760))
        defer { hosted.window.isHidden = true }

        var samples: [MessageDerivationSample] = []
        var computed: RealtimeComputeRuntime.Observation?
        state.realtimeComputeRuntime.onDerivation = { samples += $0 }
        state.realtimeComputeRuntime.onComputed = { computed = $0 }
        let entered = (1...3).map { expectation(description: "alias worker attempt \($0)") }
        let releases = entered.map { _ in DispatchSemaphore(value: 0) }
        let gate = Phase6AliasContentionGate(entered: entered, releases: releases)
        state.realtimeComputeRuntime.probe = { phase in
            if case .mapping = phase { gate.holdAttempt() }
        }
        defer { releases.forEach { $0.signal() }; state.realtimeComputeRuntime.probe = nil }

        var installedRevision: UInt64?
        let commits = state.conversationStore.memoryCommits.sink { commit in
            guard installedRevision == nil,
                  commit.messageChanges[localID]?.current.contains(where: { $0.id == "alias-fallback-arrived" }) == true else { return }
            installedRevision = commit.current.revision
            // The real Store queues this change behind the published frame.
            _ = state.conversationStore.updateAttachmentProgress(0.9, messageID: "alias-base", conversationID: localID)
        }
        defer { commits.cancel() }
        let task = Task { await state.prepareMessageJump(messageID: "alias-fallback-arrived", channelSeq: 2, conversationID: localID) }
        for index in entered.indices {
            await fulfillment(of: [entered[index]], timeout: 3)
            XCTAssertNotNil(state.conversationStore.updateAttachmentProgress(Double(index + 1) / 10,
                messageID: "alias-base", conversationID: localID))
            releases[index].signal()
        }

        let target = await task.value
        XCTAssertEqual(target, "alias-fallback-arrived")
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/im/sync" }.count, 1)
        let observation = try XCTUnwrap(computed)
        XCTAssertEqual(observation.attempts, 3)
        XCTAssertEqual(observation.stalePlans, 3)
        XCTAssertTrue(observation.fallback)
        XCTAssertEqual(observation.fallbackReasons, ["contention"])
        XCTAssertTrue(samples.contains { $0.phase == .mapping && $0.onMainThread })
        let revision = try XCTUnwrap(installedRevision)
        XCTAssertGreaterThan(state.conversationStore.memorySnapshot.revision, revision)
        XCTAssertEqual(samples.filter { $0.phase == .storeInstalled }.map(\.outputRevision), [revision])
        XCTAssertEqual(samples.filter { $0.phase == .projectionObserved }.map(\.outputRevision), [revision])
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshot(id: localID)?.messages.map(\.id),
            ["alias-base", "alias-fallback-arrived"])
    }
}

final class Phase6AliasContentionGate: @unchecked Sendable { // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112
    private let lock = NSLock()
    private let entered: [XCTestExpectation]
    private let releases: [DispatchSemaphore]
    private var index = 0

    init(entered: [XCTestExpectation], releases: [DispatchSemaphore]) {
        self.entered = entered
        self.releases = releases
    }

    func holdAttempt() {
        let step: Int? = lock.withLock {
            guard index < entered.count else { return nil }
            defer { index += 1 }
            return index
        }
        guard let step else { return }
        entered[step].fulfill()
        XCTAssertEqual(releases[step].wait(timeout: .now() + 8), .success)
    }
}
// WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111_END

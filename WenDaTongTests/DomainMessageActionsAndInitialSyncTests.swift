import XCTest; @testable import IM4Domain // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func testMessageActionMenuShowsFavoriteImmediatelyAfterPinForAssets() {
        var imageMessage = makeMessage(id: "remote-image", seq: 1, status: .sent, kind: .image)
        var descriptors = messageActionMenuDescriptors(
            message: imageMessage,
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: true,
            canFavoriteAsset: true,
            canReportMessage: false,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        )

        XCTAssertEqual(Array(descriptors.map(\.kind).prefix(3)), [.reply, .pin, .favorite])
        XCTAssertEqual(descriptors.first { $0.kind == .favorite }?.title, "收藏")

        imageMessage.isFavorited = true
        descriptors = messageActionMenuDescriptors(
            message: imageMessage,
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: true,
            canFavoriteAsset: true,
            canReportMessage: false,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        )

        XCTAssertEqual(descriptors.first { $0.kind == .favorite }?.title, "取消收藏")
        XCTAssertFalse(messageActionMenuDescriptors(
            message: makeMessage(id: "remote-text", seq: 2, status: .sent, kind: .text),
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: false,
            canFavoriteAsset: false,
            canReportMessage: false,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        ).contains { $0.kind == .favorite })
    }

    func testMessageActionMenuKeepsIneligibleVoiceForwardVisibleDisabledWithExactReason() {
        let voice = makeMessage(
            id: "remote-voice",
            senderId: "other-user",
            seq: 1,
            status: .sent,
            isOutgoing: false,
            kind: .voice
        )

        let descriptors = messageActionMenuDescriptors(
            message: voice,
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: false,
            forwardDisabledReason: batchForwardVoiceOwnershipReason,
            canSaveAttachment: false,
            canFavoriteAsset: false,
            canReportMessage: true,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        )

        let forward = descriptors.first { $0.kind == .forward }
        XCTAssertEqual(forward?.title, "转发")
        XCTAssertEqual(forward?.disabledReason, batchForwardVoiceOwnershipReason)
        XCTAssertEqual(forward?.tone, .muted)
    }

    func testConversationStoreSetMessageReportStateUpdatesReason() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        message.reportState = nil
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.setMessageReportState(messageID: " m1 ", conversationID: " c1 ", reason: "spam"))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].reportState, "spam")
    }

    func testConversationStoreMessageActionStateSkipsInvalidOrMissingTargets() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true, isPinned: false)
        message.isFavorited = false
        message.reportState = nil
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertNil(store.messagePinnedState(messageID: " ", conversationID: "c1"))
        XCTAssertNil(store.messagePinnedState(messageID: "m1", conversationID: " "))
        XCTAssertNil(store.messagePinnedState(messageID: "missing", conversationID: "c1"))
        XCTAssertNil(store.messageFavoritedState(messageID: " ", conversationID: "c1"))
        XCTAssertNil(store.messageFavoritedState(messageID: "m1", conversationID: " "))
        XCTAssertNil(store.messageFavoritedState(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.setMessagePinned(messageID: " ", conversationID: "c1", pinned: true))
        XCTAssertFalse(store.setMessagePinned(messageID: "m1", conversationID: " ", pinned: true))
        XCTAssertFalse(store.setMessagePinned(messageID: "missing", conversationID: "c1", pinned: true))
        XCTAssertFalse(store.setMessageFavorited(messageID: " ", conversationID: "c1", favorited: true))
        XCTAssertFalse(store.setMessageFavorited(messageID: "m1", conversationID: " ", favorited: true))
        XCTAssertFalse(store.setMessageFavorited(messageID: "missing", conversationID: "c1", favorited: true))
        XCTAssertFalse(store.setMessageReportState(messageID: " ", conversationID: "c1", reason: "spam"))
        XCTAssertFalse(store.setMessageReportState(messageID: "m1", conversationID: " ", reason: "spam"))
        XCTAssertFalse(store.setMessageReportState(messageID: "missing", conversationID: "c1", reason: "spam"))

        XCTAssertFalse(store.conversationMessageSnapshots()[0].messages[0].isPinned)
        XCTAssertFalse(store.conversationMessageSnapshots()[0].messages[0].isFavorited)
        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[0].reportState)
    }

    func testConversationStoreContactCardResendStateUpdatesMetaFailedAndSending() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let createdAt = Date(timeIntervalSince1970: 1_803_456_789)
        let readReceipt = makeReadReceipt(userID: "me")
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, kind: .contactCard)
        message.attachmentMeta = nil
        message.createdAt = nil
        message.readBy = []
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.setContactCardAttachmentMeta(messageID: " m1 ", conversationID: " c1 ", contactID: " contact-1 "))
        XCTAssertTrue(store.markMessageResendFailed(messageID: " m1 ", conversationID: " c1 "))
        let prepared = try XCTUnwrap(store.prepareMessageForResend(
            messageID: " m1 ",
            conversationID: " c1 ",
            createdAt: createdAt,
            readBy: [readReceipt]
        ))

        XCTAssertEqual(prepared.attachmentMeta, "contact-1")
        XCTAssertEqual(prepared.status, .sending)
        XCTAssertEqual(prepared.createdAt, createdAt)
        XCTAssertEqual(prepared.readBy, [readReceipt])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentMeta, "contact-1")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .sending)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].createdAt, createdAt)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].readBy, [readReceipt])
    }

    func testConversationStoreContactCardResendStateSkipsInvalidOrMissingTargets() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var contactCard = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, kind: .contactCard)
        contactCard.attachmentMeta = "old-contact"
        var text = makeMessage(id: "m2", seq: 2, status: .failed, isOutgoing: true, kind: .text)
        text.attachmentMeta = "text-meta"
        conversation.messages = [contactCard, text]
        store.commitConversationSnapshots([conversation])

        XCTAssertFalse(store.markMessageResendFailed(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.markMessageResendFailed(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.markMessageResendFailed(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: " ", conversationID: "c1", contactID: "contact-1"))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: "m1", conversationID: " ", contactID: "contact-1"))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: "m1", conversationID: "c1", contactID: " "))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: "missing", conversationID: "c1", contactID: "contact-1"))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: "m2", conversationID: "c1", contactID: "contact-1"))
        XCTAssertNil(store.prepareMessageForResend(messageID: " ", conversationID: "c1", readBy: []))
        XCTAssertNil(store.prepareMessageForResend(messageID: "m1", conversationID: " ", readBy: []))
        XCTAssertNil(store.prepareMessageForResend(messageID: "missing", conversationID: "c1", readBy: []))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentMeta, "old-contact")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .failed)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[1].attachmentMeta, "text-meta")
    }

    func testConversationStoreMarkMessageFailedUpdatesStatusAndLatestPreview() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        conversation.lastMessage = "second"
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .sent, text: "first"),
            makeMessage(id: "m2", seq: 2, status: .sent, text: "second")
        ]
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.markMessageFailed(messageID: " m2 ", conversationID: " c1 "))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[1].status, .failed)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "first")
    }

    func testConversationStoreRemoveMessageDeletesTargetAndUpdatesLatestPreview() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        conversation.lastMessage = "second"
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .sent, text: "first"),
            makeMessage(id: "m2", seq: 2, status: .sent, text: "second")
        ]
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.removeMessage(messageID: " m2 ", conversationID: " c1 "))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["m1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "first")
    }

    func testConversationStoreMessageFailureAndRemovalSkipInvalidOrMissingTargets() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.lastMessage = "first"
        conversation.messages = [makeMessage(id: "m1", seq: 1, status: .sent, text: "first")]
        store.commitConversationSnapshots([conversation])

        XCTAssertFalse(store.markMessageFailed(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.markMessageFailed(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.markMessageFailed(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.removeMessage(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.removeMessage(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.removeMessage(messageID: "missing", conversationID: "c1"))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["m1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .sent)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "first")
    }

    func testConversationStoreResolveGroupInviteApprovalMessagesUpdatesAllMatches() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var systemConversation = makeConversation(id: "system", kind: .system, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var firstMatch = makeMessage(id: "m1", seq: 1, status: .sent, kind: .system)
        firstMatch.groupInviteApproval = makeGroupInviteApproval(requestID: " request-1 ", resultText: "待处理")
        var otherRequest = makeMessage(id: "m2", seq: 2, status: .sent, kind: .system)
        otherRequest.groupInviteApproval = makeGroupInviteApproval(requestID: "request-2")
        systemConversation.messages = [firstMatch, otherRequest]
        var groupConversation = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var secondMatch = makeMessage(id: "m3", seq: 1, status: .sent, kind: .system)
        secondMatch.groupInviteApproval = makeGroupInviteApproval(requestID: "request-1")
        groupConversation.messages = [secondMatch]
        store.commitConversationSnapshots([systemConversation, groupConversation])

        let updatedCount = store.resolveGroupInviteApprovalMessages(
            requestID: " request-1 ",
            status: "approved",
            approverName: "管理员",
            approverAccountID: "admin-1",
            decidedAt: "10:30",
            resultText: "已通过"
        )

        XCTAssertEqual(updatedCount, 2)
        let firstResolved = try XCTUnwrap(store.conversationMessageSnapshots()[0].messages[0].groupInviteApproval)
        XCTAssertEqual(firstResolved.status, "approved")
        XCTAssertEqual(firstResolved.resultText, "已通过")
        XCTAssertTrue(firstResolved.processed)
        XCTAssertEqual(firstResolved.approverName, "管理员")
        XCTAssertEqual(firstResolved.approverAccountID, "admin-1")
        XCTAssertEqual(firstResolved.decidedAt, "10:30")
        XCTAssertFalse(firstResolved.canApprove)
        XCTAssertFalse(firstResolved.canReject)
        let secondResolved = try XCTUnwrap(store.conversationMessageSnapshots()[1].messages[0].groupInviteApproval)
        XCTAssertEqual(secondResolved.status, "approved")
        XCTAssertTrue(secondResolved.processed)
        let untouched = try XCTUnwrap(store.conversationMessageSnapshots()[0].messages[1].groupInviteApproval)
        XCTAssertEqual(untouched.status, "pending")
        XCTAssertFalse(untouched.processed)
    }

    func testConversationStoreResolveGroupInviteApprovalMessagesSkipsEmptyOrMissingRequestID() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "system", kind: .system, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, kind: .system)
        message.groupInviteApproval = makeGroupInviteApproval(requestID: "request-1")
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertEqual(store.resolveGroupInviteApprovalMessages(requestID: " ", status: "approved", resultText: "已通过"), 0)
        XCTAssertEqual(store.resolveGroupInviteApprovalMessages(requestID: "missing", status: "approved", resultText: "已通过"), 0)

        let approval = try XCTUnwrap(store.conversationMessageSnapshots()[0].messages[0].groupInviteApproval)
        XCTAssertEqual(approval.status, "pending")
        XCTAssertFalse(approval.processed)
        XCTAssertEqual(approval.resultText, "")
        XCTAssertTrue(approval.canApprove)
        XCTAssertTrue(approval.canReject)
    }

    func testConversationStoreReadSeqHelpersKeepMaximum() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)

        store.rememberRead(key: "direct|c1", readSeq: 7)
        store.rememberRead(key: "direct|c1", readSeq: 4)
        store.rememberRead(key: "direct|c1", readSeq: 11)
        store.rememberRead(key: "", readSeq: 30)
        store.rememberRead(key: "direct|c2", readSeq: 0)

        XCTAssertEqual(store.locallyReadSeq(forKey: "direct|c1"), 11)
        XCTAssertEqual(store.locallyReadSeq(forKey: ""), 0)
        XCTAssertEqual(store.locallyReadSeq(forKey: "direct|c2"), 0)
        XCTAssertTrue(store.isLocallyReadThrough(key: "direct|c1", lastMessageSeq: 11))
        XCTAssertFalse(store.isLocallyReadThrough(key: "direct|c1", lastMessageSeq: 12))
        XCTAssertFalse(store.isLocallyReadThrough(key: "direct|c1", lastMessageSeq: 0))
    }

    func testConversationStoreReadWatermarkRequiresExactScopeAndKeepsMaximum() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let watermark = try XCTUnwrap(ConversationStore.ReadWatermark(
            eventID: "read-1",
            tenantID: " tenant-a ",
            imUID: " user-a ",
            appID: " app-ios ",
            channelID: " c1 ",
            channelType: " Direct ",
            lastReadSeq: 7,
            occurredAt: "2026-08-26T00:00:00Z"
        ))
        let sameScopeLower = try XCTUnwrap(ConversationStore.ReadWatermark(
            eventID: "read-2",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 4
        ))
        let otherApp = ConversationStore.ReadWatermarkScope(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "other-app",
            channelID: "c1",
            channelType: "direct"
        )

        XCTAssertEqual(store.rememberReadWatermark(watermark), 7)
        XCTAssertEqual(store.rememberReadWatermark(sameScopeLower), 7)
        XCTAssertEqual(store.scopedReadWatermarkSeq(for: watermark.scope), 7)
        XCTAssertEqual(store.scopedReadWatermarkSeq(for: otherApp), 0)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: watermark.scope), 7)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: otherApp), 0)
        XCTAssertEqual(store.locallyReadSeq(forKey: "direct|c1"), 0)
        store.rememberRead(key: "direct|c1", readSeq: 9)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: nil), 9)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: watermark.scope), 7)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: otherApp), 0)
        XCTAssertNil(ConversationStore.ReadWatermark(
            eventID: "missing-app",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: " ",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 8
        ))
        XCTAssertNil(ConversationStore.ReadWatermark(
            eventID: "unsupported-channel",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "unknown",
            lastReadSeq: 8
        ))
    }

    func testConversationStoreLateRealtimeMessageAtReadWatermarkDoesNotUnreadOrSound() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .direct, unread: 0, lastMsgSeq: 10, lastReadSeq: 10)
        previous.hasUnreadReaction = false
        previous.unreadReactionCount = 0
        previous.messages = [makeMessage(id: "m10", seq: 10)]
        store.commitConversationSnapshots([previous])
        let lateMessage = makeMessage(id: "m10-replay", senderId: "peer", seq: 10, isOutgoing: false)

        let merge = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: try decodeRemoteMessage(remoteMessageJSON(id: "m10-replay", channelID: "c1", channelType: "direct", seq: 10)),
                    message: lateMessage,
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: true,
            effectiveReadSeq: 10
        )
        let applied = store.applyMergedRemoteMessagesConversation(
            channelID: "c1",
            kind: .direct,
            previous: previous,
            title: "Direct",
            subtitle: "单聊",
            participants: [],
            messages: merge.messages,
            latestMessage: lateMessage,
            incomingRealtimeMessages: merge.incomingRealtimeMessages,
            latestKnownSeq: merge.latestKnownSeq,
            fromRealtime: true,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 0,
            accentHex: 0,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: "",
            effectiveReadSeq: 10
        )

        XCTAssertTrue(merge.incomingRealtimeMessages.isEmpty)
        XCTAssertFalse(applied.shouldPlayIncomingSound)
        XCTAssertEqual(applied.conversation.unread, 0)
        XCTAssertEqual(applied.conversation.lastReadSeq, 10)
        XCTAssertEqual(applied.conversation.lastMessage, previous.lastMessage)
        XCTAssertEqual(applied.conversation.sortTimestamp, previous.sortTimestamp)
    }

    func testConversationStoreMessageSyncLifecycleMatchesAppStateBehavior() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.setHistoryMessage(conversationID: "c1", message: "stale")

        XCTAssertTrue(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: true))
        XCTAssertNil(store.historyMessage(conversationID: "c1"))
        XCTAssertTrue(store.isHistoryLoading(conversationID: "c1"))
        XCTAssertEqual(store.historyLoadingConversationIDs(), ["c1"])
        XCTAssertTrue(store.hasHistoryLoadingIDs())
        XCTAssertTrue(store.isMessageSyncInFlight(historyKey: "scope|c1"))

        store.setHistoryMessage(conversationID: "c1", message: "busy")
        XCTAssertFalse(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: true))
        XCTAssertNil(store.historyMessage(conversationID: "c1"))

        store.finishMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: true)
        XCTAssertFalse(store.isHistoryLoading(conversationID: "c1"))
        XCTAssertFalse(store.hasHistoryLoadingIDs())
        XCTAssertFalse(store.isMessageSyncInFlight(historyKey: "scope|c1"))
    }

    func testConversationStoreHistoryAndDirectStatusFacadesManageSnapshots() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)

        XCTAssertFalse(store.hasHistoryMessages())
        XCTAssertFalse(store.hasDirectDisabledMessages())
        XCTAssertFalse(store.hasApplyingFriendIDs())

        store.setHistoryMessage(conversationID: "c1", message: "history")
        store.setDirectDisabledMessage(conversationID: "c1", message: "disabled")
        XCTAssertEqual(store.historyMessage(conversationID: "c1"), "history")
        XCTAssertEqual(store.historyMessagesByConversationID(), ["c1": "history"])
        XCTAssertTrue(store.hasHistoryMessages())
        XCTAssertEqual(store.directDisabledMessage(conversationID: "c1"), "disabled")
        XCTAssertEqual(store.directDisabledMessagesByConversationID(), ["c1": "disabled"])
        XCTAssertTrue(store.hasDirectDisabledMessages())

        XCTAssertTrue(store.beginApplyingFriend(conversationID: "c1"))
        XCTAssertFalse(store.beginApplyingFriend(conversationID: "c1"))
        XCTAssertTrue(store.isApplyingFriend(conversationID: "c1"))
        XCTAssertEqual(store.applyingFriendConversationIDs(), ["c1"])
        XCTAssertTrue(store.hasApplyingFriendIDs())

        store.finishApplyingFriend(conversationID: "c1")
        XCTAssertFalse(store.isApplyingFriend(conversationID: "c1"))
        XCTAssertFalse(store.hasApplyingFriendIDs())

        store.clearHistoryAndDirectDisabledMessages(conversationID: "c1")
        XCTAssertNil(store.historyMessage(conversationID: "c1"))
        XCTAssertNil(store.directDisabledMessage(conversationID: "c1"))
        XCTAssertFalse(store.hasHistoryMessages())
        XCTAssertFalse(store.hasDirectDisabledMessages())
    }

    func testConversationStoreDirectFriendRequestContextLifecycle() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let context = DirectFriendRequestContext(
            targetUID: "u1",
            canApplyFriend: true,
            friendRequestStatus: "rejected",
            reasonCode: "friendship_required"
        )

        XCTAssertFalse(store.hasDirectFriendRequestContexts())
        XCTAssertNil(store.directFriendRequestContext(conversationID: "c1"))

        store.setDirectFriendRequestContext(conversationID: "c1", context: context)
        XCTAssertTrue(store.hasDirectFriendRequestContexts())
        XCTAssertEqual(store.directFriendRequestContext(conversationID: "c1")?.targetUID, "u1")
        XCTAssertEqual(store.directFriendRequestContext(conversationID: "c1")?.actionTitle, "添加好友")
        XCTAssertEqual(store.directFriendRequestContext(conversationID: "c1")?.allowsApply, true)

        store.clearDirectFriendRequestContext(conversationID: "c1")
        XCTAssertNil(store.directFriendRequestContext(conversationID: "c1"))
        XCTAssertFalse(store.hasDirectFriendRequestContexts())
    }

    func testConversationStoreConversationPollingPlanUsesActiveFlagAndInFlightState() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "c1", unread: 0, lastMsgSeq: 10, lastReadSeq: 0)
        ])
        var historyKeyInputs: [String] = []

        let idlePlan = store.conversationPollingPlan(
            conversationID: "c1",
            shouldPollActiveConversation: true,
            historyKeyForConversation: { conversation in
                historyKeyInputs.append(conversation.id)
                return " scope|c1 "
            }
        )

        XCTAssertEqual(historyKeyInputs, ["c1"])
        XCTAssertEqual(
            idlePlan,
            ConversationStore.ConversationPollingPlan(
                conversationID: "c1",
                historyKey: "scope|c1",
                shouldPollActiveConversation: true,
                isMessageSyncInFlight: false
            )
        )
        XCTAssertTrue(idlePlan.shouldPoll)

        let realtimeConnectedPlan = store.conversationPollingPlan(
            conversationID: "c1",
            shouldPollActiveConversation: false,
            historyKeyForConversation: { _ in "scope|c1" }
        )
        XCTAssertFalse(realtimeConnectedPlan.shouldPoll)

        XCTAssertTrue(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: false))
        let inFlightPlan = store.conversationPollingPlan(
            conversationID: "c1",
            shouldPollActiveConversation: true,
            historyKeyForConversation: { _ in "scope|c1" }
        )
        XCTAssertTrue(inFlightPlan.isMessageSyncInFlight)
        XCTAssertFalse(inFlightPlan.shouldPoll)

        let missingConversationPlan = store.conversationPollingPlan(
            conversationID: "missing",
            shouldPollActiveConversation: true,
            historyKeyForConversation: { _ in
                XCTFail("Missing conversations should not request a history key")
                return "unused"
            }
        )
        XCTAssertEqual(
            missingConversationPlan,
            ConversationStore.ConversationPollingPlan(
                conversationID: "missing",
                historyKey: "",
                shouldPollActiveConversation: true,
                isMessageSyncInFlight: false
            )
        )
        XCTAssertTrue(missingConversationPlan.shouldPoll)
    }

    func testConversationStoreMessageSyncUsesInjectedEngine() {
        let engine = DefaultSyncEngine()
        let store = ConversationStore(messageSyncEngine: engine)
        let request = SyncEngineRequest(
            operation: .conversationMessages,
            conversationID: "c1",
            historyKey: "scope|c1",
            reason: "assert"
        )

        XCTAssertTrue(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: false))
        XCTAssertTrue(engine.isInFlight(request))

        store.finishMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: false)
        XCTAssertFalse(engine.isInFlight(request))
    }

    func testConversationStoreOlderHistoryLoadLifecycleThrottlesRequests() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let startedAt = Date(timeIntervalSince1970: 100)
        store.setHistoryMessage(conversationID: "c1", message: "old")

        XCTAssertTrue(store.beginOlderHistoryLoad(historyKey: "scope|c1", conversationID: "c1", now: startedAt, throttleInterval: 1))
        XCTAssertNil(store.historyMessage(conversationID: "c1"))
        XCTAssertTrue(store.isHistoryLoading(conversationID: "c1"))
        XCTAssertTrue(store.hasHistoryLoadRequestTimes())

        store.finishOlderHistoryLoad(historyKey: "scope|c1", conversationID: "c1")
        XCTAssertFalse(store.isHistoryLoading(conversationID: "c1"))
        XCTAssertFalse(store.beginOlderHistoryLoad(
            historyKey: "scope|c1",
            conversationID: "c1",
            now: startedAt.addingTimeInterval(0.5),
            throttleInterval: 1
        ))
        XCTAssertTrue(store.beginOlderHistoryLoad(
            historyKey: "scope|c1",
            conversationID: "c1",
            now: startedAt.addingTimeInterval(1.1),
            throttleInterval: 1
        ))
        XCTAssertFalse(store.beginOlderHistoryLoad(
            historyKey: "scope|c1",
            conversationID: "c1",
            now: startedAt.addingTimeInterval(2.2),
            throttleInterval: 1
        ))
        store.finishOlderHistoryLoad(historyKey: "scope|c1", conversationID: "c1")
        XCTAssertTrue(store.beginOlderHistoryLoad(
            historyKey: "scope|c1",
            conversationID: "c1",
            now: startedAt.addingTimeInterval(2.2),
            throttleInterval: 1
        ))
    }

    func testConversationStoreOlderHistoryResultStateTransitions() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)

        store.markHistoryUnavailable(historyKey: "scope|empty", conversationID: "empty", message: "empty")
        XCTAssertTrue(store.hasReachedHistoryStart(historyKey: "scope|empty"))
        XCTAssertEqual(store.historyMessage(conversationID: "empty"), "empty")

        store.markOlderHistoryNeedsContinue(
            historyKey: "scope|c1",
            conversationID: "c1",
            nextBackfillAfterSeq: 120,
            pageLimit: 100,
            message: "continue"
        )
        XCTAssertEqual(store.historyBackfillAfterSeq(historyKey: "scope|c1", defaultValue: 0), 20)
        XCTAssertTrue(store.hasHistoryBackfillAfterSeqs())
        XCTAssertEqual(store.historyMessage(conversationID: "c1"), "continue")

        store.markOlderHistoryReachedStart(historyKey: "scope|c1", conversationID: "c1", message: "done")
        XCTAssertEqual(store.historyBackfillAfterSeq(historyKey: "scope|c1", defaultValue: -1), -1)
        XCTAssertFalse(store.hasHistoryBackfillAfterSeqs())
        XCTAssertTrue(store.hasReachedHistoryStart(historyKey: "scope|c1"))
        XCTAssertTrue(store.hasHistoryReachedStartKeys())
        XCTAssertEqual(store.historyMessage(conversationID: "c1"), "done")

        store.setDirectDisabledMessage(conversationID: "c1", message: "disabled")
        store.setHistoryMessage(conversationID: "c1", message: "done")
        store.setDirectFriendRequestContext(
            conversationID: "c1",
            context: DirectFriendRequestContext(
                targetUID: "u1",
                canApplyFriend: false,
                friendRequestStatus: "pending",
                reasonCode: "friendship_required"
            )
        )
        store.markOlderHistoryApplied(historyKey: "scope|c1", conversationID: "c1")
        XCTAssertEqual(store.historyBackfillAfterSeq(historyKey: "scope|c1", defaultValue: -1), -1)
        XCTAssertFalse(store.hasReachedHistoryStart(historyKey: "scope|c1"))
        XCTAssertNil(store.historyMessage(conversationID: "c1"))
        XCTAssertNil(store.directDisabledMessage(conversationID: "c1"))
        XCTAssertNil(store.directFriendRequestContext(conversationID: "c1"))
    }

    func testConversationStoreRecentHistoryAfterSeqUsesLatestKnownSequence() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let emptyConversation = makeConversation(id: "empty", unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        let remoteLatestConversation = makeConversation(id: "remote", unread: 0, lastMsgSeq: 130, lastReadSeq: 0)
        var localLatestConversation = makeConversation(id: "local", unread: 0, lastMsgSeq: 80, lastReadSeq: 0)
        localLatestConversation.messages = [
            makeMessage(id: "m120", seq: 120),
            makeMessage(id: "m140", seq: 140)
        ]

        XCTAssertEqual(store.recentHistoryAfterSeq(for: emptyConversation, limit: 100), 0)
        XCTAssertEqual(store.recentHistoryAfterSeq(for: remoteLatestConversation, limit: 100), 30)
        XCTAssertEqual(store.recentHistoryAfterSeq(for: localLatestConversation, limit: 100), 40)
    }

    func testConversationStoreNewerHistoryTargetUsesNewestLoadedSequence() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "jumped", unread: 0, lastMsgSeq: 1_000, lastReadSeq: 0)
        conversation.messages = (451...500).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        let target = try XCTUnwrap(store.newerHistoryAvailabilityTarget(
            for: conversation,
            historyKey: "scope|jumped",
            limit: 20
        ))

        XCTAssertEqual(target.historyKey, "scope|jumped")
        XCTAssertEqual(target.conversationID, "jumped")
        XCTAssertEqual(target.afterSeq, 500)
        XCTAssertEqual(target.latestKnownSeq, 1_000)
        XCTAssertEqual(target.limit, 20)
    }

    func testConversationStoreNewerHistoryTargetSkipsWhenLatestWindowLoaded() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "latest", unread: 0, lastMsgSeq: 500, lastReadSeq: 0)
        conversation.messages = (481...500).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        XCTAssertNil(store.newerHistoryAvailabilityTarget(
            for: conversation,
            historyKey: "scope|latest",
            limit: 20
        ))
    }

    func testConversationStoreInitialMessageSyncWindowsUsesLatestWindowForLargeUnreadEntry() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "large_unread", unread: 500, lastMsgSeq: 1_000, lastReadSeq: 500)
        conversation.firstUnreadSeq = 501
        conversation.firstUnreadMessageID = "m501"
        conversation.unreadAnchorSeq = 501
        conversation.messages = [makeMessage(id: "m1000", seq: 1_000)]

        let windows = store.initialMessageSyncWindows(for: conversation, limit: 100)

        XCTAssertEqual(windows, [
            ConversationStore.MessageSyncWindow(afterSeq: 900, limit: 100)
        ])
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112_BEGIN
// WDT_IOS1_REFACTOR_FAVORITE_VIEW_OUTPUT_20261110_BEGIN
extension IdentityPresentationTests {
    @MainActor
    func testMountedFavoriteFilesConsumeReplacementResetAndIgnoreUnrelatedContacts() async throws {
        let transport = FakeHTTPTransport(results: [])
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!, httpTransport: transport
        )
        let state = AppState(api: api, apiContextOverride: remarkContractContext(tenantID: "favorite-ui", imUID: "viewer-ui"))
        state.storeCancellables.removeAll()
        func asset(_ id: String) -> FavoriteAssetItem {
            FavoriteAssetItem(
                messageID: id, tenantID: "favorite-ui", channelID: "same-channel", channelType: "group",
                channelSeq: 1, fromUID: "sender", contentType: "file", status: "sent",
                createdAt: "2026-08-17T10:00:00Z", favoritedAt: "2026-08-17T10:01:00Z",
                favoriteVersion: 1, category: .pdf, displayText: id, cursor: "cursor",
                file: FileItem(id: id, name: id + ".pdf", type: "PDF", size: "1 KB", owner: "Sender",
                    source: "Group", time: "10:01", scope: "个人收藏", status: "可预览", accentHex: 0x5D6BFF,
                    mediaCategory: "pdf"), isUnavailable: false
            )
        }
        let first = FileStore.FavoriteAssetsSnapshot(items: [asset("First favorite")])
        let second = FileStore.FavoriteAssetsSnapshot(items: [asset("Replacement favorite")])
        // An existing refresh prevents automatic entry refresh; its completion is
        // published after the view appears, just like the production loading flow.
        state.fileStore.favoriteAssetsSnapshot = .init(items: first.items, isSyncing: true)
        var globalUpdates = 0
        let observation = state.objectWillChange.sink { globalUpdates += 1 }
        defer { observation.cancel() }
        try await withMountedConversationSurface(
            FilesView().appStateEnvironment(state), settleNanoseconds: 350_000_000
        ) { snapshot in
            _ = try await snapshot()
            state.fileStore.favoriteAssetsSnapshot = first
            let initial = try await snapshot()
            state.fileStore.favoriteAssetsSnapshot = second
            let replacement = try await snapshot()
            XCTAssertNotEqual(replacement, initial, "replaced favorite was not rendered")
            state.contacts = [makeRemarkContractUser(id: "unrelated", userID: "UNRELATED", name: "Unrelated")]
            let unrelated = try await snapshot()
            XCTAssertEqual(unrelated, replacement, "unrelated contact changed the favorite page")
            state.fileStore.favoriteAssetsSnapshot = .init()
            let empty = try await snapshot()
            XCTAssertNotEqual(empty, replacement, "reset retained old favorite rows")
            state.fileStore.favoriteAssetsSnapshot = first
            let restored = try await snapshot()
            XCTAssertEqual(restored, initial)
            XCTAssertEqual(globalUpdates, 0)
            XCTAssertTrue(transport.requests().isEmpty, "the fixture must not replace its scoped snapshots through networking")
            for (name, data) in [("initial", initial), ("replacement", replacement), ("unrelated", unrelated), ("empty", empty), ("restored", restored)] {
                let attachment = XCTAttachment(image: try XCTUnwrap(UIImage(data: data)))
                attachment.name = "FavoriteFiles-" + name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
// WDT_IOS1_REFACTOR_FAVORITE_VIEW_OUTPUT_20261110_END

// WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112_END

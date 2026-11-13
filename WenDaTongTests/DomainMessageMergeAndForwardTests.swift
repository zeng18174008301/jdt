import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func testConversationStoreMessageExtraAppliesReactionDetailReadStateAndReminder() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, isOutgoing: true)
        ]
        store.commitConversationSnapshots([conversation])
        let addExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "thumbs_up",
          "action": "add",
          "payload": { "display_name": "Reader One" },
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)

        XCTAssertTrue(store.applyMessageReaction(
            messageID: addExtra.messageID,
            emoji: addExtra.emoji,
            operatorUID: addExtra.operatorUID,
            action: addExtra.action,
            currentUserIDs: ["me"]
        ))
        XCTAssertTrue(store.applyMessageReactionDetail(addExtra, makeReactionDetail: makeReactionDetail(from:id:)))
        store.applyReactionReadStateIfNeeded(addExtra, currentUserIDs: ["me"])
        store.markReactionReminderIfNeeded(
            addExtra,
            currentUserIDs: ["me"],
            activeConversationID: nil,
            channelIDForConversation: { _ in "remote-c1" }
        )

        var updated = store.conversationMessageSnapshots()[0]
        XCTAssertTrue(updated.hasUnreadReaction)
        XCTAssertEqual(updated.unread, 1)
        XCTAssertEqual(updated.unreadReactionCount, 1)
        XCTAssertEqual(updated.messages[0].reactions, [
            Reaction(id: "m1_thumbs_up", emoji: "thumbs_up", count: 1, reactedByMe: false)
        ])
        XCTAssertEqual(updated.messages[0].reactionDetails.map(\.id), ["m1_reader-1_thumbs_up"])
        XCTAssertEqual(updated.messages[0].status, .read)
        XCTAssertTrue(updated.messages[0].readStateKnown)
        XCTAssertEqual(updated.messages[0].readCount, 1)

        let removeExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "thumbs_up",
          "action": "remove",
          "payload": {}
        }
        """)
        XCTAssertTrue(store.applyMessageReaction(
            messageID: removeExtra.messageID,
            emoji: removeExtra.emoji,
            operatorUID: removeExtra.operatorUID,
            action: removeExtra.action,
            currentUserIDs: ["me"]
        ))
        XCTAssertTrue(store.applyMessageReactionDetail(removeExtra, makeReactionDetail: makeReactionDetail(from:id:)))

        updated = store.conversationMessageSnapshots()[0]
        XCTAssertTrue(updated.messages[0].reactions.isEmpty)
        XCTAssertTrue(updated.messages[0].reactionDetails.isEmpty)
    }

    func testConversationStoreOwnReactionRemoveIsIdempotentAfterOptimisticToggle() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, isOutgoing: true)
        message.reactions = [
            Reaction(id: "m1_ok", emoji: "ok", count: 2, reactedByMe: true)
        ]
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.applyMessageReaction(
            messageID: "m1",
            emoji: "ok",
            operatorUID: "me",
            action: "remove",
            currentUserIDs: ["me"]
        ))
        XCTAssertTrue(store.applyMessageReaction(
            messageID: "m1",
            emoji: "ok",
            operatorUID: "me",
            action: "remove",
            currentUserIDs: ["me"]
        ))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].reactions, [
            Reaction(id: "m1_ok", emoji: "ok", count: 1, reactedByMe: false)
        ])
    }

    func testConversationStorePinExtraAppliesByRemoteChannelID() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1)
        ]
        store.commitConversationSnapshots([conversation])
        let pinExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "admin",
          "extra_type": "pin",
          "emoji": "",
          "action": "pin",
          "payload": { "pinned": true }
        }
        """)
        let unpinExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "admin",
          "extra_type": "pin",
          "emoji": "",
          "action": "unpin",
          "payload": { "pinned": false }
        }
        """)

        XCTAssertTrue(store.applyRemotePinExtra(
            pinExtra,
            normalizedChannelID: "remote-c1",
            channelIDForConversation: { _ in "remote-c1" }
        ))
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].isPinned)

        XCTAssertTrue(store.applyRemotePinExtra(
            unpinExtra,
            normalizedChannelID: "remote-c1",
            channelIDForConversation: { _ in "remote-c1" }
        ))
        XCTAssertFalse(store.conversationMessageSnapshots()[0].messages[0].isPinned)
    }

    func testConversationStoreApplyRemoteEditExtraUpdatesLoadedMessageAndPreview() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        var message = makeMessage(id: "m1", seq: 2, status: .read, isOutgoing: false, text: "old text")
        message.isEdited = false
        conversation.messages = [message]
        conversation.lastMessage = "old text"
        store.commitConversationSnapshots([conversation])
        let extra = try decodeRemoteExtra("""
        {
          "tenant_id": "tenant-1",
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "channel_seq": 2,
          "version": 1024,
          "extra_type": "edit",
          "operator_uid": "u2",
          "action": "edit",
          "payload": {
            "content_type": "text",
            "edit_revision": 1,
            "payload": {"text": "edited from peer", "edit_revision": 1}
          },
          "created_at": "2026-06-23T10:02:00Z"
        }
        """)

        XCTAssertTrue(store.applyRemoteEditExtra(
            extra,
            normalizedChannelID: "remote-c1",
            channelIDForConversation: { _ in "remote-c1" }
        ))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].text, "edited from peer")
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].isEdited)
		XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].editRevision, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .read)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "edited from peer")
    }

	func testConversationStoreRemoteEditRevisionRejectsDuplicateAndOutOfOrderEvents() throws {
		let store = ConversationStore(scope: TestMessageMemoryScope.value)
		var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
		var message = makeMessage(id: "m1", seq: 2, status: .read, isOutgoing: false, text: "original")
		message.contentType = "text"
		conversation.messages = [message]
		store.commitConversationSnapshots([conversation])
		let revisionTwo = try decodeRemoteExtra("""
		{"tenant_id":"tenant-1","message_id":"m1","channel_id":"remote-c1","channel_type":"group","channel_seq":2,"version":2048,"extra_type":"edit","operator_uid":"u2","payload":{"edit_revision":2,"payload":{"text":"revision two","edit_revision":2}}}
		""")
		let revisionOne = try decodeRemoteExtra("""
		{"tenant_id":"tenant-1","message_id":"m1","channel_id":"remote-c1","channel_type":"group","channel_seq":2,"version":1024,"extra_type":"edit","operator_uid":"u2","payload":{"edit_revision":1,"payload":{"text":"revision one","edit_revision":1}}}
		""")
		XCTAssertTrue(store.applyRemoteEditExtra(revisionTwo, normalizedChannelID: "remote-c1", channelIDForConversation: { _ in "remote-c1" }))
		XCTAssertFalse(store.applyRemoteEditExtra(revisionTwo, normalizedChannelID: "remote-c1", channelIDForConversation: { _ in "remote-c1" }))
		XCTAssertFalse(store.applyRemoteEditExtra(revisionOne, normalizedChannelID: "remote-c1", channelIDForConversation: { _ in "remote-c1" }))
		XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].text, "revision two")
		XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].editRevision, 2)
		XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .read)
	}

    func testConversationStoreMergeMappedRemoteMessagesReplacesExistingWithEditedRemoteState() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var previousMessage = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: false, text: "old text")
        previousMessage.isEdited = false
        previous.messages = [previousMessage]
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "u2",
          "content_type": "text",
          "payload": {"text": "edited from history sync"},
          "status": "edited",
          "read_status": "read",
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)
        var mapped = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: false, text: "edited from history sync")
        mapped.isEdited = remote.isEdited

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote,
                    message: mapped,
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: false
        )

        let updated = try XCTUnwrap(result.messages.first)
        XCTAssertEqual(updated.text, "edited from history sync")
        XCTAssertTrue(updated.isEdited)
        XCTAssertEqual(updated.status, .read)
    }

    // WDT_CHAT_MEDIA_CACHE_REUSE_20261102_BEGIN
    func testHistoryRefreshRetainsOnlyMatchingAttachmentCacheMetadata() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var downloaded = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: false, text: "photo.jpg", kind: .image)
        downloaded.attachmentFileID = "photo"
        downloaded.attachmentCacheKey = "objects/photo"
        downloaded.attachmentVersion = "v1"
        downloaded.attachmentChecksum = String(repeating: "a", count: 64)
        downloaded.attachmentMimeType = "image/jpeg"
        downloaded.attachmentExtension = "jpg"
        downloaded.attachmentSizeBytes = 128
        previous.messages = [downloaded]
        let remote = try decodeRemoteMessage("""
        {"message_id":"m1","channel_id":"c1","channel_type":"group","channel_seq":1,"from_uid":"u2",
         "content_type":"image","payload":{"file_id":"photo"},"status":"normal","created_at":"2026-06-23T10:00:00Z"}
        """)
        var sparse = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: false, text: "photo.jpg", kind: .image)
        sparse.attachmentFileID = "photo"
        func merge(_ message: ChatMessage) throws -> ChatMessage {
            let result = store.mergeMappedRemoteMessages(previous: previous,
                mappedRemoteMessages: [.init(remote: remote, message: message, clientMessageIDs: [], isRemoteFromCurrentUser: false, matchedLocalID: nil)],
                readReceiptsEnabled: true, fromRealtime: false)
            return try XCTUnwrap(result.messages.first)
        }
        let retained = try merge(sparse)
        XCTAssertEqual(retained.attachmentCacheKey, downloaded.attachmentCacheKey)
        XCTAssertEqual(retained.attachmentVersion, downloaded.attachmentVersion)
        XCTAssertEqual(retained.attachmentChecksum, downloaded.attachmentChecksum)
        XCTAssertEqual(retained.attachmentMimeType, downloaded.attachmentMimeType)
        XCTAssertEqual(retained.attachmentExtension, downloaded.attachmentExtension)
        XCTAssertEqual(retained.attachmentSizeBytes, downloaded.attachmentSizeBytes)
        XCTAssertEqual(retained.text, sparse.text)
        XCTAssertEqual(retained.status, sparse.status)
        for reason in ["file", "version", "checksum", "size", "recalled", "deleted"] {
            var changed = sparse
            switch reason {
            case "file": changed.attachmentFileID = "another-file"
            case "version": changed.attachmentVersion = "v2"
            case "checksum": changed.attachmentChecksum = String(repeating: "b", count: 64)
            case "size": changed.attachmentSizeBytes = 256
            case "recalled": changed.status = .recalled
            default: changed.isDeletedLocally = true
            }
            let result = try merge(changed)
            XCTAssertEqual(result.attachmentChecksum, changed.attachmentChecksum, reason)
            XCTAssertEqual(result.attachmentVersion, changed.attachmentVersion, reason)
            XCTAssertEqual(result.attachmentCacheKey, changed.attachmentCacheKey, reason)
        }
    }
    // WDT_CHAT_MEDIA_CACHE_REUSE_20261102_END

    func testConversationStoreMergeMappedRemoteMessagesReplacesMatchedPendingLocalEcho() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        previous.messages = [
            makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "hello")
        ]
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "client_msg_no": "local_1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "me",
          "content_type": "text",
          "payload": {},
          "status": "normal",
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)
        let mapped = makeMessage(id: "m1", seq: 1, isOutgoing: true, text: "hello")

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote,
                    message: mapped,
                    clientMessageIDs: ["local_1"],
                    isRemoteFromCurrentUser: true,
                    matchedLocalID: "local_1"
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: true
        )

        XCTAssertEqual(result.messages.map(\.id), ["m1"])
        XCTAssertEqual(result.latestKnownSeq, 1)
        XCTAssertEqual(result.latestMessage?.id, "m1")
        XCTAssertTrue(result.incomingRealtimeMessages.isEmpty)
        XCTAssertEqual(result.pendingLocalFinalizations.map(\.localID), ["local_1"])
        XCTAssertEqual(result.pendingLocalFinalizations.first?.remoteMessage.id, "m1")
    }

    func testConversationStoreHistoryReplayDoesNotFinalizeDifferentPendingAttachment() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 101, lastReadSeq: 101)
        var oldRemote = makeMessage(id: "remote_old_1", seq: 101, status: .sent, isOutgoing: true, text: "same.jpg", kind: .image)
        oldRemote.attachmentName = "same.jpg"
        oldRemote.attachmentFileID = "file_old_1"
        oldRemote.attachmentSizeBytes = 200
        var pending = makeMessage(id: "local_first_1", seq: 0, status: .sending, isOutgoing: true, text: "same.jpg", kind: .image)
        pending.attachmentName = "same.jpg"
        pending.attachmentFileID = "file_first_1"
        pending.attachmentSizeBytes = 100
        previous.messages = [oldRemote, pending]
        store.commitConversationSnapshots([previous])
        let replay = try decodeRemoteMessage("""
        {
          "message_id": "remote_old_1",
          "client_msg_no": "local_old_1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 101,
          "from_uid": "me",
          "content_type": "image",
          "payload": {
            "file_name": "same.jpg",
            "file_id": "file_old_1",
            "size_bytes": 200,
            "media_category": "image"
          },
          "status": "normal",
          "created_at": "2026-06-23T10:00:01Z"
        }
        """)

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: replay,
                    message: oldRemote,
                    clientMessageIDs: ["local_old_1"],
                    isRemoteFromCurrentUser: true,
                    matchedLocalID: "local_first_1"
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: false
        )

        XCTAssertTrue(result.pendingLocalFinalizations.isEmpty)
        XCTAssertEqual(result.messages.map(\.id), ["local_first_1", "remote_old_1"])
    }

    func testConfirmedLocalMessageDoesNotUpgradeClientSuppliedSenderToAuthoritative() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeMessage(
            id: "local-voice",
            senderId: "authenticated-actor",
            seq: 0,
            status: .sending,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        previous.senderProvenance = .unknown
        var clientSuppliedRemote = makeMessage(
            id: "remote-voice",
            senderId: "spoofed-actor",
            seq: 11,
            status: .sent,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        clientSuppliedRemote.senderProvenance = .clientSupplied

        let confirmed = store.confirmedLocalMessage(
            previous: previous,
            remoteMapped: clientSuppliedRemote,
            remoteMessageID: "remote-voice",
            remoteDisplayTime: "10:00",
            remoteCreatedAt: Date(timeIntervalSince1970: 100),
            remoteChannelSeq: 11,
            readReceiptsEnabled: true
        )

        XCTAssertEqual(confirmed.senderId, "authenticated-actor")
        XCTAssertEqual(confirmed.senderProvenance, .clientSupplied)
    }

    func testConfirmedLocalMessagePreservesStructuredMentionProjection() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let localMention = MentionIdentity(
            imUID: "member-local",
            userID: "user-local",
            username: "local-account",
            displayText: "本地成员"
        )
        let authoritativeMention = MentionIdentity(
            imUID: "member-authoritative",
            userID: "user-authoritative",
            username: "authoritative-account",
            displayText: "权威成员"
        )
        var previous = makeMessage(
            id: "local-mention",
            seq: 0,
            status: .sending,
            isOutgoing: true,
            text: "@本地成员 请确认"
        )
        previous.mentionedUsers = [localMention]
        var remoteMapped = makeMessage(
            id: "remote-mention",
            seq: 13,
            status: .sent,
            isOutgoing: true,
            text: "@权威成员 请确认"
        )
        remoteMapped.mentionedUsers = [authoritativeMention]

        let confirmed = store.confirmedLocalMessage(
            previous: previous,
            remoteMapped: remoteMapped,
            remoteMessageID: "remote-mention",
            remoteDisplayTime: "10:02",
            remoteCreatedAt: Date(timeIntervalSince1970: 102),
            remoteChannelSeq: 13,
            readReceiptsEnabled: true
        )

        XCTAssertFalse(confirmed.mentionAll)
        XCTAssertEqual(confirmed.mentionedUsers, [authoritativeMention])

        var remoteWithoutMentionProjection = remoteMapped
        remoteWithoutMentionProjection.mentionedUsers = []
        let confirmedFromIncompleteAck = store.confirmedLocalMessage(
            previous: previous,
            remoteMapped: remoteWithoutMentionProjection,
            remoteMessageID: "remote-mention-fallback",
            remoteDisplayTime: "10:03",
            remoteCreatedAt: Date(timeIntervalSince1970: 103),
            remoteChannelSeq: 14,
            readReceiptsEnabled: true
        )

        XCTAssertEqual(confirmedFromIncompleteAck.mentionedUsers, [localMention])
    }

    func testMessageMentionProjectionUsesStructuredCurrentActorIdentityOnly() {
        let currentActor = makeUser(id: "member-current", name: "重名成员")
        let otherActor = makeUser(id: "member-other", name: "重名成员")

        var visibleTextOnly = makeMessage(
            id: "text-only",
            senderId: "sender",
            seq: 1,
            isOutgoing: false,
            text: "@重名成员 请确认"
        )
        visibleTextOnly.mentionedUsers = []

        var mentionsOtherStableActor = visibleTextOnly
        mentionsOtherStableActor.mentionedUsers = [MentionIdentity(user: otherActor)]

        var mentionsCurrentStableActor = visibleTextOnly
        mentionsCurrentStableActor.mentionedUsers = [MentionIdentity(user: currentActor)]

        XCTAssertFalse(MessageMentionProjection.includes(visibleTextOnly, currentActor: currentActor))
        XCTAssertFalse(MessageMentionProjection.includes(mentionsOtherStableActor, currentActor: currentActor))
        XCTAssertTrue(MessageMentionProjection.includes(mentionsCurrentStableActor, currentActor: currentActor))
    }

    func testMessageMentionProjectionCoversGroupAllAndRejectsDirectAndOutgoingNoise() {
        let currentActor = makeUser(id: "member-current", name: "当前成员")
        var groupAll = makeMessage(id: "group-all", senderId: "sender", seq: 1, isOutgoing: false)
        groupAll.mentionAll = true

        var directNoise = makeMessage(
            id: "direct-noise",
            senderId: "sender",
            seq: 2,
            isOutgoing: false,
            text: "当前成员"
        )
        directNoise.mentionedUsers = []

        var outgoing = makeMessage(id: "outgoing", senderId: currentActor.id, seq: 3, isOutgoing: true)
        outgoing.mentionedUsers = [MentionIdentity(user: currentActor)]

        XCTAssertTrue(MessageMentionProjection.includes(groupAll, currentActor: currentActor))
        XCTAssertFalse(MessageMentionProjection.includes(directNoise, currentActor: currentActor))
        XCTAssertFalse(MessageMentionProjection.includes(outgoing, currentActor: currentActor))
    }

    func testConversationStoreRealtimeSequenceGapRecoveryOrdersDedupesAndConvergesOnRetry() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 41, lastReadSeq: 41)
        previous.messages = [makeMessage(id: "m41", seq: 41)]

        let remote42 = try decodeRemoteMessage(remoteMessageJSON(id: "m42", channelID: "c1", channelType: "group", seq: 42))
        let remote43 = try decodeRemoteMessage(remoteMessageJSON(id: "m43", channelID: "c1", channelType: "group", seq: 43))
        let mapped42 = ConversationStore.MappedRemoteMessage(
            remote: remote42,
            message: makeMessage(id: "m42", seq: 42),
            clientMessageIDs: [],
            isRemoteFromCurrentUser: false,
            matchedLocalID: nil
        )
        let mapped43 = ConversationStore.MappedRemoteMessage(
            remote: remote43,
            message: makeMessage(id: "m43", seq: 43),
            clientMessageIDs: [],
            isRemoteFromCurrentUser: false,
            matchedLocalID: nil
        )

        let outOfOrderComplete = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [mapped43, mapped42, mapped43],
            readReceiptsEnabled: true,
            fromRealtime: true
        )
        XCTAssertEqual(outOfOrderComplete.messages.map(\.channelSeq), [41, 42, 43])
        XCTAssertNil(outOfOrderComplete.sequenceRecoveryAfterSeq)

        let missingMiddle = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [mapped43],
            readReceiptsEnabled: true,
            fromRealtime: true
        )
        XCTAssertEqual(missingMiddle.messages.map(\.channelSeq), [41, 43])
        XCTAssertEqual(missingMiddle.sequenceRecoveryAfterSeq, 41)

        var retryBase = previous
        retryBase.lastMsgSeq = missingMiddle.latestKnownSeq
        retryBase.messages = missingMiddle.messages
        let converged = store.mergeMappedRemoteMessages(
            previous: retryBase,
            mappedRemoteMessages: [mapped43, mapped42],
            readReceiptsEnabled: true,
            fromRealtime: false
        )
        XCTAssertEqual(converged.messages.map(\.id), ["m41", "m42", "m43"])
        XCTAssertEqual(Set(converged.messages.map(\.id)).count, 3)
    }

    func testConfirmedLocalMessageUsesAuthoritativeStoredSender() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeMessage(
            id: "local-voice",
            senderId: "local-value",
            seq: 0,
            status: .sending,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        previous.senderProvenance = .unknown
        previous.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        var authoritativeRemote = makeMessage(
            id: "remote-voice",
            senderId: "stored-actor",
            seq: 12,
            status: .sent,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        authoritativeRemote.senderProvenance = .authoritativeStored
        authoritativeRemote.attachmentUploadFailure = AttachmentUploadFailure(code: .http, httpStatus: 503)

        let confirmed = store.confirmedLocalMessage(
            previous: previous,
            remoteMapped: authoritativeRemote,
            remoteMessageID: "remote-voice",
            remoteDisplayTime: "10:01",
            remoteCreatedAt: Date(timeIntervalSince1970: 101),
            remoteChannelSeq: 12,
            readReceiptsEnabled: true
        )

        XCTAssertNil(confirmed.attachmentUploadFailure)
        XCTAssertEqual(confirmed.senderId, "stored-actor")
        XCTAssertEqual(confirmed.senderProvenance, .authoritativeStored)
    }

    func testBatchForwardActorFailsClosedWithoutAuthenticatedIMUID() {
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: nil,
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-main",
            deviceID: "device-1"
        )
        let state = AppState(
            api: IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: FakeHTTPTransport(results: [])
            ),
            apiContextOverride: context
        )
        var conversation = makeConversation(
            id: "group-voice",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var voice = makeMessage(
            id: "voice-1",
            senderId: state.currentUser.id,
            seq: 1,
            status: .sent,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        voice.senderProvenance = .authoritativeStored
        conversation.messages = [voice]
        state.conversationStore.commitConversationSnapshots([conversation])

        state.beginBatchForward(
            conversationID: conversation.id,
            initialMessageID: voice.id
        )

        XCTAssertNil(state.batchForwardState)
        XCTAssertNil(state.batchForwardSourceConversationID)
        XCTAssertEqual(state.toast, "登录会话不可用，请重新登录")
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

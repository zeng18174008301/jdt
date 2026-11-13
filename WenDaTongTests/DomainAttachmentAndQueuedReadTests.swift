import XCTest; @testable import IM4Features // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func testAppStateSyncsConversationAttachmentWithoutFileIDIntoFileList() throws {
        let state = AppState()
        var conversation = makeConversation(id: "risk-review", kind: .group, unread: 0, lastMsgSeq: 7, lastReadSeq: 7)
        conversation.title = "风控复核群"
        var attachment = ChatMessage(
            id: "message-readme",
            senderId: "u_chen",
            senderName: "陈星",
            text: "README.md",
            time: "03:44",
            channelSeq: 7,
            isOutgoing: false,
            status: .read,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        attachment.attachmentName = "README.md"
        attachment.attachmentSizeBytes = 633_000
        attachment.attachmentMimeType = "text/markdown"
        attachment.attachmentMediaCategory = "document"
        attachment.attachmentExtension = "md"
        attachment.attachmentDownloadAvailable = true
        attachment.attachmentDownloadURL = "/api/tenant/files/message-readme/download"

        conversation.messages = [attachment]

        state.syncAttachmentFilesFromConversation(conversation)

        let file = try XCTUnwrap(state.files.first(where: { $0.name == "README.md" }))
        XCTAssertTrue(file.id.hasPrefix("local-attachment|risk-review|message-readme"))
        XCTAssertEqual(file.remoteFileID, "")
        XCTAssertEqual(file.remoteLookupID, "")
        XCTAssertEqual(file.source, "风控复核群")
        XCTAssertEqual(file.scope, "群文件")
        XCTAssertFalse(file.downloadAvailable)
        XCTAssertEqual(file.downloadURL, "")
        XCTAssertEqual(state.files(for: "risk-review").map(\.name), ["README.md"])
    }

    func testConversationStoreReplaceLocalMessageWithRemoteConfirmationStripsReadDetailsWhenDisabled() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        var local = makeMessage(id: "local_1", seq: 0, status: .read, isOutgoing: true, text: "hello")
        local.readBy = [makeReadReceipt(userID: "reader-1")]
        local.unreadBy = [makeReadReceipt(userID: "reader-2")]
        local.readCount = 1
        local.unreadCount = 2
        local.readStateKnown = true
        local.canViewReadDetails = true
        local.reactions = [Reaction(id: "local_1_ok", emoji: "ok", count: 1, reactedByMe: false)]
        local.reactionDetails = [ReactionDetail(id: "d1", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")]
        conversation.messages = [local]
        store.commitConversationSnapshots([conversation])

        let replacement = try XCTUnwrap(store.replaceLocalMessageWithRemoteConfirmation(
            localID: "local_1",
            remoteMessageID: "remote-1",
            remoteMapped: makeMessage(id: "remote-1", seq: 1, isOutgoing: true),
            remoteDisplayTime: "10:01",
            remoteCreatedAt: nil,
            remoteChannelSeq: 1,
            in: "c1",
            readReceiptsEnabled: false
        ))

        let confirmed = replacement.confirmedMessage
        XCTAssertEqual(confirmed.status, .sent)
        XCTAssertTrue(confirmed.readBy.isEmpty)
        XCTAssertTrue(confirmed.unreadBy.isEmpty)
        XCTAssertNil(confirmed.readCount)
        XCTAssertNil(confirmed.unreadCount)
        XCTAssertFalse(confirmed.readStateKnown)
        XCTAssertFalse(confirmed.canViewReadDetails)
        XCTAssertEqual(confirmed.reactions, local.reactions)
        XCTAssertTrue(confirmed.reactionDetails.isEmpty)
    }

    func testConversationStoreUpdateLatestMessageSummaryIgnoresFailedAndDeletedMessages() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        var fileMessage = makeMessage(id: "file", seq: 2, text: "report.pdf", time: "10:00", kind: .file)
        fileMessage.attachmentName = "report.pdf"
        fileMessage.attachmentMediaCategory = "pdf"
        fileMessage.createdAt = Date(timeIntervalSince1970: 100)
        conversation.messages = [
            makeMessage(id: "failed", seq: 1, status: .failed, text: "failed"),
            fileMessage,
            makeMessage(id: "deleted", seq: 3, status: .sent, isDeletedLocally: true, text: "deleted")
        ]
        store.commitConversationSnapshots([conversation])

        store.updateConversationLatestFromMessages(at: 0)

        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "文件")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "10:00")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].sortTimestamp, 100)
    }

    func testConversationStoreApplyRecallUpdatesStatusAndCanUseRecallText() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1, text: "older", time: "09:59")
        older.createdAt = Date(timeIntervalSince1970: 100)
        var latest = makeMessage(id: "m2", seq: 2, isOutgoing: true, text: "latest", time: "10:00")
        latest.createdAt = Date(timeIntervalSince1970: 200)
        latest.quote = "Alice: quoted original"
        latest.attachmentName = "secret.pdf"
        latest.attachmentFileID = "file-1"
        latest.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        latest.reactions = [Reaction(id: "m2_thumb", emoji: "👍", count: 1, reactedByMe: false)]
        conversation.messages = [older, latest]
        conversation.lastMessage = "latest"
        conversation.sortTimestamp = 200
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.applyRecall(messageID: "m2"))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[1].status, .recalled)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[1].text, "你撤回了一条消息")
        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[1].quote)
        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[1].attachmentName)
        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[1].attachmentFileID)
        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[1].attachmentUploadFailure)
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[1].reactions.isEmpty)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "你撤回了一条消息")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "10:00")

        XCTAssertTrue(store.applyRecall(messageID: "m1", conversationID: "c1", recallText: "你撤回了一条消息"))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .recalled)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].text, "你撤回了一条消息")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "你撤回了一条消息")
    }

    func testReopeningChatCannotRestoreRecalledOutgoingMessageFromHistoryOrReceipts() throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: TestMessageMemoryScope.context)
        let store = state.conversationStore
        func history(status: String) throws -> RemoteMessage {
            try decodeRemoteMessage("""
            {
              "message_id": "m1", "channel_id": "c1", "channel_type": "group",
              "channel_seq": 1, "from_uid": "u1", "content_type": "image",
              "payload": {"file_id": "private-image", "file_name": "original.jpg",
                          "thumbnail_url": "https://example.com/original.jpg"},
              "status": "\(status)", "read_status": "read", "read_count": 1
            }
            """)
        }
        let stale = try history(status: "normal")
        var chat = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        chat.messages = [state.chatMessage(from: stale, forceOutgoing: true)]
        store.commitConversationSnapshots([chat])
        XCTAssertTrue(store.applyRecall(messageID: "m1", conversationID: "c1"))

        let receipt = try decodeRemoteReceipt("""
        {"message_id":"m1","channel_id":"c1","channel_type":"group","im_uid":"reader","receipt_type":"read","channel_seq":1}
        """)
        for remote in [stale, try history(status: "recalled")] {
            chat = try XCTUnwrap(store.conversationMessageSnapshot(id: "c1"))
            let mapped = state.chatMessage(from: remote, forceOutgoing: true)
            let merged = store.mergeMappedRemoteMessages(
                previous: chat,
                mappedRemoteMessages: [.init(remote: remote, message: mapped, clientMessageIDs: [],
                                             isRemoteFromCurrentUser: true, matchedLocalID: nil)],
                readReceiptsEnabled: true,
                fromRealtime: false
            )
            chat.messages = merged.messages
            store.commitConversationSnapshots([chat])
            XCTAssertFalse(store.applyRemoteReadReceipts(
                [receipt], channelID: "c1", readReceiptsEnabled: true,
                channelIDForConversation: { $0.id }, makeReadReceipt: makeReadReceipt(from:conversation:)
            ))
            let messages = try XCTUnwrap(store.conversationMessageSnapshot(id: "c1")).messages
            let message = try XCTUnwrap(messages.first)
            XCTAssertEqual(message.status, .recalled)
            XCTAssertEqual(message.text, "你撤回了一条消息")
            XCTAssertNil(message.attachmentFileID)
            XCTAssertTrue(message.attachmentThumbnailURL.isEmpty)
            XCTAssertNil(message.readCount)
            XCTAssertTrue(chatTimelineMessagesForRendering(messages, showsProcessingNotices: false).isEmpty)
        }
    }

    func testConversationListAttachmentPreviewUsesMessageTypeForExistingSummaries() {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeIsolatedAPIContext())
        var conversation = makeConversation(id: "preview-group", kind: .group, unread: 0, lastMsgSeq: 5, lastReadSeq: 5)
        let examples: [(MessageKind, String, String, String)] = [
            (.file, "股市百科全书.pdf", "[PDF] ", "文件"), (.file, "report.docx", "[文件] ", "文件"),
            (.file, "backup.7z", "[文件] ", "文件"), (.file, "README", "[文件] ", "文件"),
            (.image, "photo.jpg", "[图片] ", "图片"), (.file, "video.mp4", "[视频] ", "视频"),
            (.file, "song.mp3", "[文件] ", "音频"), (.voice, "00:10", "[语音] ", "音频"),
            (.text, "股市百科全书.pdf", "", "股市百科全书.pdf")
        ]
        for (kind, original, legacyPrefix, expected) in examples {
            let message = makeMessage(id: "m5", seq: 5, text: original, kind: kind)
            conversation.messages = [message]
            XCTAssertEqual(message.conversationListPreview, expected)
            for summary in [original, legacyPrefix + original] {
                conversation.lastMessage = summary
                let restored = CachedConversation(conversation: conversation, messageLimit: 1).model
                XCTAssertEqual(state.visibleConversationLastMessage(restored), expected)
                XCTAssertEqual(restored.messages.last?.text, original)
            }
        }
    }

    func testRemoteConversationListAttachmentPreviewDoesNotDependOnLoadedHistory() throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: TestMessageMemoryScope.context)
        var previous = makeConversation(id: "preview-group", kind: .group, unread: 0, lastMsgSeq: 4, lastReadSeq: 4)
        previous.messages = [makeMessage(id: "m4", seq: 4, text: "previous")]
        state.conversationStore.commitConversationSnapshots([previous])
        let remote = try JSONDecoder().decode(RemoteConversation.self, from: Data("""
        {
          "channel_id": "preview-group", "channel_type": "group", "last_msg_seq": 5,
          "last_message": {
            "message_id": "m5", "channel_id": "preview-group", "channel_type": "group",
            "channel_seq": 5, "content_type": "attachment", "from_uid": "peer-1",
            "payload": {"file_name": "backup.7z", "mime_type": "application/x-7z-compressed"}
          }
        }
        """.utf8))

        state.debugApplyRemoteConversationsForTesting([remote])

        let conversation = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: previous.id))
        XCTAssertEqual(conversation.messages.last?.id, "m4")
        XCTAssertEqual(state.visibleConversationLastMessage(conversation), "文件")
        let restoredWithoutMessages = CachedConversation(conversation: conversation, messageLimit: 0).model
        XCTAssertEqual(state.visibleConversationLastMessage(restoredWithoutMessages), "文件")
    }

    func testConversationStoreRealtimeRecallMatchesRemoteChannelAndHidesOriginalText() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var local = makeConversation(id: "local-group", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        local.messages = [makeMessage(id: "m1", seq: 1, text: "今天晚饭好吃", time: "18:18")]
        var system = makeConversation(id: "system_notification", kind: .system, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        system.messages = [makeMessage(id: "notice", seq: 1, status: .sent, text: "系统通知", kind: .system)]
        store.commitConversationSnapshots([system, local])

        XCTAssertFalse(store.applyRecall(
            messageID: "m1",
            conversationID: "other-group",
            channelIDForConversation: { conversation in
                conversation.id == "local-group" ? "remote-group" : conversation.id
            }
        ))
        XCTAssertEqual(store.conversationMessageSnapshots()[1].messages[0].text, "今天晚饭好吃")

        XCTAssertTrue(store.applyRecall(
            messageID: "m1",
            conversationID: "remote-group",
            channelIDForConversation: { conversation in
                conversation.id == "local-group" ? "remote-group" : conversation.id
            }
        ))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].id, "system_notification")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].text, "系统通知")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].messages[0].status, .recalled)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].messages[0].text, "User撤回了一条消息")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].lastMessage, "User撤回了一条消息")
    }

    func testConversationStoreApplyAdminDeletedMessageClearsTombstoneFieldsAndMatchesRemoteChannelID() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1, text: "older", time: "09:59")
        older.createdAt = Date(timeIntervalSince1970: 100)
        var target = makeMessage(id: "m2", seq: 2, text: "report.pdf", time: "10:00", kind: .file)
        target.createdAt = Date(timeIntervalSince1970: 200)
        target.quote = "Alice: original"
        target.replyContext = MessageReplyContext(messageID: "source", summary: "source")
        target.attachmentName = "report.pdf"
        target.attachmentMeta = "application/pdf"
        target.attachmentFileID = "file-1"
        target.attachmentSizeBytes = 123
        target.attachmentPreviewURL = "https://example.test/preview"
        target.attachmentDownloadURL = "https://example.test/download"
        target.attachmentPreviewAvailable = true
        target.attachmentDownloadAvailable = true
        target.attachmentThumbnailURL = "https://example.test/thumb"
        target.attachmentUploadStatus = "uploaded"
        target.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        target.reactions = [Reaction(id: "m2_ok", emoji: "ok", count: 1, reactedByMe: true)]
        target.reactionDetails = [ReactionDetail(id: "d1", emoji: "ok", user: makeUser(id: "u2"), time: "10:01")]
        target.readBy = [makeReadReceipt(userID: "reader-1")]
        target.readCount = 1
        target.readStateKnown = true
        target.canViewReadDetails = true
        conversation.messages = [older, target]
        conversation.lastMessage = "report.pdf"
        conversation.sortTimestamp = 200
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.applyAdminDeletedMessage(
            messageID: "m2",
            conversationID: "remote-c1",
            channelIDForConversation: { _ in "remote-c1" }
        ))

        let deleted = store.conversationMessageSnapshots()[0].messages[1]
        XCTAssertTrue(deleted.isDeletedLocally)
        XCTAssertEqual(deleted.status, .recalled)
        XCTAssertEqual(deleted.text, "原消息已删除")
        XCTAssertNil(deleted.quote)
        XCTAssertTrue(deleted.replyContext?.isUnavailable == true)
        XCTAssertNil(deleted.attachmentName)
        XCTAssertNil(deleted.attachmentMeta)
        XCTAssertNil(deleted.attachmentFileID)
        XCTAssertNil(deleted.attachmentSizeBytes)
        XCTAssertEqual(deleted.attachmentPreviewURL, "")
        XCTAssertEqual(deleted.attachmentDownloadURL, "")
        XCTAssertFalse(deleted.attachmentPreviewAvailable)
        XCTAssertFalse(deleted.attachmentDownloadAvailable)
        XCTAssertEqual(deleted.attachmentThumbnailURL, "")
        XCTAssertEqual(deleted.attachmentUploadStatus, "")
        XCTAssertNil(deleted.attachmentUploadFailure)
        XCTAssertTrue(deleted.reactions.isEmpty)
        XCTAssertTrue(deleted.reactionDetails.isEmpty)
        XCTAssertTrue(deleted.readBy.isEmpty)
        XCTAssertNil(deleted.readCount)
        XCTAssertFalse(deleted.readStateKnown)
        XCTAssertFalse(deleted.canViewReadDetails)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "older")
    }

    func testOwnMessageDeletionUsesSenderRouteAndKeepsMessageWhenRejected() async throws {
        for accepted in [true, false] {
            let json = accepted ? #"{"ok":true,"data":{"extra":{"extra_type":"delete"}}}"#
                : #"{"ok":false,"error":{"code":"permission_denied","message":"denied"}}"#
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: accepted ? 200 : 403)
            ])
            let context = makeAuthenticatedAPIContext()
            let sender = try XCTUnwrap(context.imUID)
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
            var conversation = makeConversation(id: "delete-group", kind: .group, unread: 0, lastMsgSeq: 5, lastReadSeq: 5)
            let own = makeMessage(id: "m5", senderId: sender, seq: 5, isOutgoing: true, text: "original")
            conversation.messages = [own]
            conversation.lastMessage = own.text
            state.conversationStore.commitConversationSnapshots([conversation])

            await state.deleteOwnMessage(messageID: own.id, in: conversation.id, as: .sent)

            let request = try XCTUnwrap(transport.requests().first { $0.url?.path.hasSuffix("/messages/m5/delete") == true })
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/im/messages/m5/delete")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(body["im_uid"], sender)
            XCTAssertEqual(body["tenant_id"], context.tenantID)
            XCTAssertEqual(body["device_id"], context.deviceID)
            let updated = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: conversation.id))
            XCTAssertEqual(updated.messages.first?.isDeletedLocally, accepted)
            XCTAssertEqual(updated.lastMessage, accepted ? "" : "original")
        }
    }

    func testOwnMessageDeletionRequiresSenderAndSeparatesFailedFromSynced() {
        var message = makeMessage(id: "remote", seq: 1, status: .sent, isOutgoing: true)
        XCTAssertEqual(OwnMessageDeletion.available(for: message, isCurrentSender: true), .sent)
        XCTAssertNil(OwnMessageDeletion.available(for: message, isCurrentSender: false))
        message.status = .recalled
        XCTAssertNil(OwnMessageDeletion.available(for: message, isCurrentSender: true))
        let failed = makeMessage(id: "local_1", seq: 0, status: .failed, isOutgoing: true)
        XCTAssertEqual(OwnMessageDeletion.available(for: failed, isCurrentSender: true), .failed)
    }

    func testConversationStoreRestoredDeletedOnlySnapshotIsNotUsableRemoteHistory() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "deleted", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .recalled, isDeletedLocally: true, text: "原消息已删除"),
            makeMessage(id: "m2", seq: 2, status: .recalled, isDeletedLocally: true, text: "原消息已删除")
        ]

        let restored = CachedConversation(conversation: conversation, messageLimit: 40).model

        XCTAssertTrue(restored.messages.allSatisfy(\.isDeletedLocally))
        XCTAssertFalse(store.hasUsableRemoteHistory(for: restored))
    }

    func testConversationStoreClearUnreadResetsTargetState() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "c1", unread: 4, lastMsgSeq: 12, lastReadSeq: 3),
            makeConversation(id: "c2", unread: 2, lastMsgSeq: 6, lastReadSeq: 1)
        ])

        store.clearUnread(conversationID: "c1", includeSystemConversations: false)

        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 0)
        XCTAssertEqual(
            store.conversationMessageSnapshots()[0].lastReadSeq,
            3,
            "a local clear must not acknowledge message sequences that were never loaded contiguously"
        )
        XCTAssertFalse(store.conversationMessageSnapshots()[0].hasUnreadReaction)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadReactionCount, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadSeq, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadMessageID, "")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorSeq, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorState, "none")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].unread, 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].lastReadSeq, 1)
    }

    func testConversationStoreClearUnreadCanTargetSystemConversationAlias() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "system", kind: .system, unread: 5, lastMsgSeq: 8, lastReadSeq: 1),
            makeConversation(id: "c1", unread: 3, lastMsgSeq: 4, lastReadSeq: 0)
        ])

        store.clearUnread(conversationID: "system_notification", includeSystemConversations: true)

        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastReadSeq, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].unread, 3)
    }

    func testConversationStoreClearUnreadResolvesSystemAliasWithMatcher() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var matchedIDs: [String] = []
        store.commitConversationSnapshots([
            makeConversation(id: "system", kind: .system, unread: 5, lastMsgSeq: 8, lastReadSeq: 1),
            makeConversation(id: "c1", unread: 3, lastMsgSeq: 4, lastReadSeq: 0)
        ])

        store.clearUnread(conversationID: " system_notification ") { channelID in
            matchedIDs.append(channelID)
            return channelID == "system_notification"
        }

        XCTAssertEqual(matchedIDs, ["system_notification"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastReadSeq, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].unread, 3)
    }

    func testConversationStoreReplaceSystemConversationPreservesPreferredPreviousSystemState() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let normal = makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 3, lastReadSeq: 0)
        var legacySystem = makeConversation(id: "legacy_system", kind: .system, unread: 2, lastMsgSeq: 7, lastReadSeq: 1)
        legacySystem.isPinned = false
        legacySystem.isMuted = true
        var preferredSystem = makeConversation(id: "system_notification", kind: .system, unread: 4, lastMsgSeq: 9, lastReadSeq: 2)
        preferredSystem.isPinned = true
        preferredSystem.isMuted = true
        store.commitConversationSnapshots([normal, legacySystem, preferredSystem])
        var capturedPrevious: ConversationMessageSnapshot?

        store.replaceSystemConversation { previous in
            capturedPrevious = previous
            var next = makeConversation(id: "system_notification", kind: .system, unread: 1, lastMsgSeq: previous?.lastMsgSeq ?? 0, lastReadSeq: 0)
            next.isPinned = previous?.isPinned ?? false
            next.isMuted = previous?.isMuted ?? false
            return next
        }

        XCTAssertEqual(capturedPrevious?.id, "system_notification")
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["system_notification", "c1"])
        XCTAssertTrue(store.conversationMessageSnapshots()[0].isPinned)
        XCTAssertTrue(store.conversationMessageSnapshots()[0].isMuted)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMsgSeq, 9)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].id, "c1")
    }

    func testConversationStoreReplaceSystemConversationRemovesExistingSystemRowsWhenBuilderReturnsNil() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "system_notification", kind: .system, unread: 4, lastMsgSeq: 9, lastReadSeq: 2),
            makeConversation(id: "legacy_system", kind: .system, unread: 2, lastMsgSeq: 7, lastReadSeq: 1),
            makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 3, lastReadSeq: 0)
        ])

        store.replaceSystemConversation { _ in nil }

        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["c1"])
    }

    func testSystemInboxRefreshPublishesOnlyTheReplacementUnreadTotal() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var system = makeConversation(id: "system_notification", kind: .system, unread: 3, lastMsgSeq: 4, lastReadSeq: 1)
        store.commitConversationSnapshots([system])
        var totals: [Int] = []
        let observation = store.alertingUnreadUpdates.sink { totals.append($0) } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        defer { observation.cancel() }

        store.replaceSystemConversation { $0 }
        system.unread = 2
        store.replaceSystemConversation { _ in system }

        XCTAssertEqual(totals, [3, 2])
    }

    func testAppStateMarkSystemConversationReadClearsUnreadWhenReadAckFails() async throws {
        let transport = SystemInboxReadHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var system = makeConversation(id: "system_notification", kind: .system, unread: 2, lastMsgSeq: 2, lastReadSeq: 0)
        system.messages = [
            makeMessage(id: "inbox_system-1", seq: 1, status: .sent, kind: .system),
            makeMessage(id: "inbox_system-2", seq: 2, status: .sent, kind: .system)
        ]
        state.conversationStore.commitConversationSnapshots([system])
        state.inboxItems = [
            InboxItem(id: "system-1", title: "通知一", subtitle: "内容一", time: "10:00", category: "system", isRead: false, accentHex: 0),
            InboxItem(id: "system-2", title: "通知二", subtitle: "内容二", time: "10:01", category: "system", isRead: false, accentHex: 0)
        ]

        var completionResult: Bool?
        state.markConversationRead("system_notification", showToast: false) { success in
            completionResult = success
        }
        for _ in 0..<80 where completionResult == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(completionResult, true)
        let refreshed = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first(where: { $0.id == "system_notification" }))
        XCTAssertEqual(refreshed.unread, 0)
        XCTAssertEqual(refreshed.lastReadSeq, refreshed.lastMsgSeq)
        XCTAssertTrue(state.inboxItems.allSatisfy { $0.isAnnouncement || $0.isRead })
        XCTAssertTrue(transport.requestPaths().contains("/api/tenant/inbox/system/read"))
        XCTAssertTrue(transport.requestPaths().contains("/api/im/read-ack"))
    }

    func testAppStateVisibleTextAndImageReadTargetsDrainAfterInFlightAckWithoutNewMessage() async throws {
        for kind in [MessageKind.text, .image] {
            let persistenceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("read-ack-coalescing-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: persistenceRoot) }
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: persistenceRoot.appendingPathComponent("Application Support", isDirectory: true),
                cachesBase: persistenceRoot.appendingPathComponent("Caches", isDirectory: true)
            )
            let gate = FirstReadAckSuspensionGate()
            let transport = ReadAckCoalescingHTTPTransport(firstRequestGate: gate)
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let state = AppState(
                api: api,
                voiceMediaClient: NoopVoiceMediaClient(),
                messagePersistence: persistence,
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            var conversation = makeConversation(
                id: "read-convergence-group",
                kind: .group,
                unread: 1,
                lastMsgSeq: 1,
                lastReadSeq: 0
            )
            conversation.messages = [
                makeMessage(id: "incoming-1", senderId: "peer-1", seq: 1, kind: .text)
            ]
            conversation.messageCoveredThroughSeq = 1
            state.conversationStore.commitConversationSnapshots([conversation])

            state.markConversationRead(conversation.id, showToast: false)
            for _ in 0..<80 {
                if await gate.isWaiting() { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let firstRequestIsWaiting = await gate.isWaiting()
            XCTAssertTrue(firstRequestIsWaiting, "first read ack did not reach the suspension gate for \(kind)")

            conversation.messages.append(
                makeMessage(id: "incoming-2", senderId: "peer-1", seq: 2, kind: kind)
            )
            conversation.lastMsgSeq = 2
            conversation.unread = 2
            conversation.messageCoveredThroughSeq = 2
            state.conversationStore.commitConversationSnapshots([conversation])
            state.markConversationRead(conversation.id, showToast: false)

            await gate.resumeFirst()
            let syncKey = "group|read-convergence-group"
            for _ in 0..<120 {
                if transport.requestedSequences().count == 2,
                   !state.conversationStore.isReadAckSyncInFlight(syncKey: syncKey) {
                    break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }

            XCTAssertEqual(transport.requestedSequences(), [1, 2], "queued visible target was not drained for \(kind)")
            let refreshed = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first(where: { $0.id == conversation.id }))
            XCTAssertEqual(refreshed.lastReadSeq, 2)
            XCTAssertEqual(refreshed.unread, 0)
        }
    }

    func testAppStateVisibleQueuedReadDoesNotConsumeUnseenArrival() async throws {
        for kind in [MessageKind.text, .image] {
            let persistenceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("read-ack-coalescing-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: persistenceRoot) }
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: persistenceRoot.appendingPathComponent("Application Support", isDirectory: true),
                cachesBase: persistenceRoot.appendingPathComponent("Caches", isDirectory: true)
            )
            let gate = FirstReadAckSuspensionGate()
            let transport = ReadAckCoalescingHTTPTransport(firstRequestGate: gate)
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let state = AppState(
                api: api,
                voiceMediaClient: NoopVoiceMediaClient(),
                messagePersistence: persistence,
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            var conversation = makeConversation(
                id: "read-convergence-group",
                kind: .group,
                unread: 1,
                lastMsgSeq: 1,
                lastReadSeq: 0
            )
            // WDT_IOS1_REFACTOR_VISIBLE_ACK_FIXTURE_20261110_BEGIN
            // This scenario starts with one unread message and no unread reactions.
            conversation.hasUnreadReaction = false
            conversation.unreadReactionCount = 0
            conversation.firstUnreadSeq = 1
            conversation.firstUnreadMessageID = "incoming-1"
            conversation.unreadAnchorSeq = 1
            // WDT_IOS1_REFACTOR_VISIBLE_ACK_FIXTURE_20261110_END
            conversation.messages = [
                makeMessage(id: "incoming-1", senderId: "peer-1", seq: 1, kind: .text)
            ]
            conversation.messageCoveredThroughSeq = 1
            state.conversationStore.commitConversationSnapshots([conversation])

            state.markConversationRead(conversation.id, throughSeq: 1, showToast: false)
            for _ in 0..<80 {
                if await gate.isWaiting() { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let firstRequestIsWaiting = await gate.isWaiting()
            XCTAssertTrue(firstRequestIsWaiting, "first read ack did not reach the suspension gate for \(kind)")

            conversation.messages.append(
                makeMessage(id: "incoming-2", senderId: "peer-1", seq: 2, kind: kind)
            )
            conversation.lastMsgSeq = 2
            conversation.unread = 2
            conversation.messageCoveredThroughSeq = 2
            state.conversationStore.commitConversationSnapshots([conversation])
            state.markConversationRead(conversation.id, throughSeq: 2, showToast: false)
            // A third message arrives while ACK1 is suspended, but has not been
            // observed by the viewport. Finishing the queue must retain target2.
            conversation.messages.append(makeMessage(id: "unseen-3", senderId: "peer-1", seq: 3, kind: .text))
            conversation.lastMsgSeq = 3
            conversation.messageCoveredThroughSeq = 3
            conversation.unread = 3
            state.conversationStore.commitConversationSnapshots([conversation])

            await gate.resumeFirst()
            let syncKey = "group|read-convergence-group"
            for _ in 0..<120 {
                if transport.requestedSequences().count == 2,
                   !state.conversationStore.isReadAckSyncInFlight(syncKey: syncKey) {
                    break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }

            XCTAssertEqual(transport.requestedSequences(), [1, 2], "queued visible target was not drained for \(kind)")
            let refreshed = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first(where: { $0.id == conversation.id }))
            XCTAssertEqual(refreshed.lastReadSeq, 2)
            XCTAssertEqual(refreshed.unread, 1)
            XCTAssertEqual(refreshed.firstUnreadSeq, 3)
            // Repeating the observed target must not clear unread3 locally.
            state.markConversationRead(conversation.id, throughSeq: 2, showToast: false)
            XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first(where: { $0.id == conversation.id })?.unread, 1)
            XCTAssertEqual(transport.requestedSequences(), [1, 2])
        }
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

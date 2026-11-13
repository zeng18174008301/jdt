@testable import IM4Features
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
    func testConversationStorePartialReadPreservesMissingUnreadAnchorAndReactions() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "gap-anchor", kind: .group, unread: 4, lastMsgSeq: 4, lastReadSeq: 0)
        conversation.messages = [1, 2, 4].map { makeMessage(id: "m\($0)", seq: Int64($0), isOutgoing: false) }
        conversation.messageCoveredThroughSeq = 2
        conversation.messageCoverageRequiresRecovery = true
        conversation.firstUnreadSeq = 3
        conversation.firstUnreadMessageID = "m3"
        conversation.unreadAnchorSeq = 3
        conversation.unreadAnchorState = "unresolved"
        conversation.hasUnreadReaction = true
        conversation.unreadReactionCount = 1
        store.commitConversationSnapshots([conversation])

        store.advanceRead(conversationID: conversation.id, through: 2)
        store.advanceRead(conversationID: conversation.id, through: 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadSeq, 3)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadMessageID, "m3")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorSeq, 3)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorState, "unresolved")
        XCTAssertTrue(store.conversationMessageSnapshots()[0].hasUnreadReaction)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadReactionCount, 1)
    }

    func testConversationStoreAdvanceReadClearsUnreadWhenAckedIncomingPrecedesOwnOutgoingTail() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.firstUnreadSeq = 1
        conversation.firstUnreadMessageID = "incoming-1"
        conversation.unreadAnchorSeq = 1
        conversation.messages = [
            makeMessage(id: "incoming-1", seq: 1, isOutgoing: false),
            makeMessage(id: "outgoing-2", seq: 2, isOutgoing: true)
        ]
        store.commitConversationSnapshots([conversation])

        store.advanceRead(conversationID: conversation.id, through: 1)

        let updated = store.conversationMessageSnapshots()[0]
        XCTAssertEqual(updated.lastReadSeq, 1)
        XCTAssertEqual(updated.unread, 0)
        XCTAssertEqual(updated.firstUnreadSeq, 0)
        XCTAssertEqual(updated.firstUnreadMessageID, "")
        XCTAssertEqual(updated.unreadAnchorSeq, 0)
        XCTAssertEqual(updated.unreadAnchorState, "none")
    }

    func testConversationStoreAdvanceReadPreservesActualIncomingAndReactionFrontiers() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var incoming = makeConversation(id: "incoming", kind: .group, unread: 2, lastMsgSeq: 3, lastReadSeq: 0)
        incoming.hasUnreadReaction = false
        incoming.unreadReactionCount = 0
        incoming.firstUnreadSeq = 1
        incoming.firstUnreadMessageID = "incoming-1"
        incoming.unreadAnchorSeq = 1
        incoming.messages = [
            makeMessage(id: "incoming-1", seq: 1, isOutgoing: false),
            makeMessage(id: "incoming-2", seq: 2, isOutgoing: false),
            makeMessage(id: "outgoing-3", seq: 3, isOutgoing: true)
        ]
        var reaction = makeConversation(id: "reaction", kind: .group, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        reaction.hasUnreadReaction = true
        reaction.unreadReactionCount = 1
        reaction.messages = [makeMessage(id: "outgoing-2", seq: 2, isOutgoing: true)]
        store.commitConversationSnapshots([incoming, reaction])

        store.advanceRead(conversationID: incoming.id, through: 1)
        store.advanceRead(conversationID: reaction.id, through: 1)

        let updatedIncoming = store.conversationMessageSnapshots().first { $0.id == incoming.id }
        XCTAssertEqual(updatedIncoming?.unread, 1)
        XCTAssertEqual(updatedIncoming?.firstUnreadSeq, 2)
        XCTAssertEqual(updatedIncoming?.firstUnreadMessageID, "incoming-2")
        XCTAssertEqual(updatedIncoming?.unreadAnchorSeq, 2)
        let updatedReaction = store.conversationMessageSnapshots().first { $0.id == reaction.id }
        XCTAssertEqual(updatedReaction?.unread, 1)
        XCTAssertTrue(updatedReaction?.hasUnreadReaction == true)
        XCTAssertEqual(updatedReaction?.unreadReactionCount, 1)
    }

    func testConversationListMessageJumpTargetRejectsPlainConversationResult() {
        let conversationTarget = RemoteTenantSearchJumpTarget(
            kind: "conversation",
            channelID: "c1",
            channelType: "group",
            channelSeq: 8,
            messageID: nil
        )
        let messageTarget = RemoteTenantSearchJumpTarget(
            kind: "message",
            channelID: "c1",
            channelType: "group",
            channelSeq: 8,
            messageID: "m8"
        )

        XCTAssertNil(conversationListMessageJumpTarget(conversationTarget))
        XCTAssertEqual(conversationListMessageJumpTarget(messageTarget)?.messageID, "m8")
        XCTAssertEqual(conversationListMessageJumpTarget(messageTarget)?.channelSeq, 8)
    }

    func testChatPendingJumpWaitsForRenderedMessageAndAlwaysAllowsBottomAnchor() {
        XCTAssertFalse(chatCanConsumePendingScrollTarget(
            targetID: "m8",
            renderedMessageIDs: ["m7"],
            bottomAnchorID: "chat-bottom"
        ))
        XCTAssertTrue(chatCanConsumePendingScrollTarget(
            targetID: "m8",
            renderedMessageIDs: ["m7", "m8"],
            bottomAnchorID: "chat-bottom"
        ))
        XCTAssertTrue(chatCanConsumePendingScrollTarget(
            targetID: "chat-bottom",
            renderedMessageIDs: [],
            bottomAnchorID: "chat-bottom"
        ))
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationSeedsFirstUnreadForNewInactiveRealtime() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        previous.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2)
        ]
        store.commitConversationSnapshots([previous])

        var latest = makeMessage(id: "m3", seq: 3, isOutgoing: false, text: "new unread", time: "10:03")
        latest.createdAt = Date(timeIntervalSince1970: 300)

        let result = store.applyMergedRemoteMessagesConversation(
            channelID: "c1",
            kind: .group,
            previous: previous,
            title: "Group",
            subtitle: "群聊",
            participants: [],
            messages: previous.messages + [latest],
            latestMessage: latest,
            incomingRealtimeMessages: [latest],
            latestKnownSeq: 3,
            fromRealtime: true,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 2,
            accentHex: 42,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(result.conversation.unread, 1)
        XCTAssertEqual(result.conversation.lastReadSeq, 2)
        XCTAssertEqual(result.conversation.firstUnreadSeq, 3)
        XCTAssertEqual(result.conversation.firstUnreadMessageID, "m3")
        XCTAssertEqual(result.conversation.unreadAnchorSeq, 3)
        XCTAssertEqual(result.conversation.unreadAnchorState, "unread")

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: result.conversation.messages,
            unreadCount: result.conversation.unread,
            lastReadSeq: result.conversation.lastReadSeq,
            firstUnreadMessageID: result.conversation.firstUnreadMessageID,
            firstUnreadSeq: result.conversation.firstUnreadSeq,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))
        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertFalse(anchor.anchorsLastReadMessage)
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationPreservesSortForOlderHistoryBackfill() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 10, lastReadSeq: 10)
        previous.time = "10:00"
        previous.sortTimestamp = 1_000
        var latestKnown = makeMessage(id: "m10", seq: 10, text: "current latest", time: "10:00")
        latestKnown.createdAt = Date(timeIntervalSince1970: 1_000)
        var older = makeMessage(id: "m5", seq: 5, text: "older backfill", time: "09:00")
        older.createdAt = Date(timeIntervalSince1970: 500)
        previous.messages = [latestKnown]
        previous.lastMessage = latestKnown.text
        store.commitConversationSnapshots([previous])

        let result = store.applyMergedRemoteMessagesConversation(
            channelID: "c1",
            kind: .group,
            previous: previous,
            title: "Group",
            subtitle: "群聊",
            participants: [],
            messages: [older, latestKnown],
            latestMessage: latestKnown,
            incomingRealtimeMessages: [],
            latestKnownSeq: 10,
            fromRealtime: false,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 2,
            accentHex: 42,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(result.conversation.lastMessage, "current latest")
        XCTAssertEqual(result.conversation.time, "10:00")
        XCTAssertEqual(result.conversation.sortTimestamp, 1_000)
        XCTAssertEqual(result.conversation.lastMsgSeq, 10)
    }

    func testConversationStoreMergeRemoteConversationListKeepsIncrementalRowsAndReturnsSoundCandidates() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        previous.messages = [makeMessage(id: "m1", seq: 1)]
        previous.sortTimestamp = 100
        var retained = makeConversation(id: "c2", kind: .direct, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        retained.sortTimestamp = 300
        store.commitConversationSnapshots([previous, retained])
        let remote = try decodeRemoteConversation("""
        {
          "channel_id": "c1",
          "channel_type": "group",
          "unread_count": 2,
          "last_msg_seq": 3,
          "version": 4
        }
        """)
        var mapped = makeConversation(id: "c1", kind: .group, unread: 2, lastMsgSeq: 3, lastReadSeq: 0)
        mapped.isPinned = true
        mapped.sortTimestamp = 200

        let result = store.mergeRemoteConversationList(
            entries: [
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: "c1",
                    remote: remote,
                    conversation: mapped
                )
            ],
            replacing: false,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(result.conversations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["c1", "c2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 2)
        XCTAssertEqual(result.soundCandidates.count, 1)
        XCTAssertEqual(result.soundCandidates.first?.previous.id, "c1")
        XCTAssertEqual(result.soundCandidates.first?.remote.channelID, "c1")
        XCTAssertEqual(result.soundCandidates.first?.mapped.lastMsgSeq, 3)
    }

    func testConversationStoreMergeRemoteConversationListDropsDuplicateConversationIDs() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let olderRemote = try decodeRemoteConversation("""
        {
          "channel_id": "legacy-channel",
          "channel_type": "group",
          "unread_count": 1,
          "last_msg_seq": 1,
          "version": 1
        }
        """)
        let newerRemote = try decodeRemoteConversation("""
        {
          "channel_id": "canonical-channel",
          "channel_type": "group",
          "unread_count": 5,
          "last_msg_seq": 5,
          "version": 5
        }
        """)
        var older = makeConversation(id: "same-conversation", kind: .group, unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        older.sortTimestamp = 100
        var newer = makeConversation(id: "same-conversation", kind: .group, unread: 5, lastMsgSeq: 5, lastReadSeq: 0)
        newer.sortTimestamp = 300

        let result = store.mergeRemoteConversationList(
            entries: [
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: "legacy-channel",
                    remote: olderRemote,
                    conversation: older
                ),
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: "canonical-channel",
                    remote: newerRemote,
                    conversation: newer
                )
            ],
            replacing: true,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(result.conversations.map(\.id), ["same-conversation"])
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["same-conversation"])
        XCTAssertEqual(store.conversationMessageSnapshots().first?.unread, 5)
        XCTAssertEqual(store.conversationMessageSnapshots().first?.lastMsgSeq, 5)
    }

    func testConversationStoreMergeRemoteConversationListCanReplaceWithEmptyList() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "c1", unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        ])

        let result = store.mergeRemoteConversationList(
            entries: [],
            replacing: true,
            channelIDForConversation: { $0.id }
        )

        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(result.soundCandidates.isEmpty)
        XCTAssertTrue(store.conversationMessageSnapshots().isEmpty)
    }

    func testConversationStoreMergeRemoteConversationListSkipsPublishWhenOrderAndContentUnchanged() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 3, lastReadSeq: 1)
        conversation.isPinned = true
        conversation.sortTimestamp = 200
        store.commitConversationSnapshots([conversation])

        var emissionCount = 0
        let cancellable = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher() // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            .dropFirst()
            .sink { _ in
                emissionCount += 1
            }

        let remote = try decodeRemoteConversation("""
        {
          "channel_id": "c1",
          "channel_type": "group",
          "unread_count": 1,
          "last_msg_seq": 3,
          "version": 4
        }
        """)
        let result = store.mergeRemoteConversationList(
            entries: [
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: "c1",
                    remote: remote,
                    conversation: conversation
                )
            ],
            replacing: false,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(result.conversations, [conversation])
        XCTAssertEqual(store.conversationMessageSnapshots(), [conversation])
        XCTAssertEqual(emissionCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testConversationStoreReplaceLocalMessageWithRemoteConfirmationMergesAttachmentAndSidecarState() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        var local = makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "report.pdf", time: "09:59", kind: .file)
        local.createdAt = Date(timeIntervalSince1970: 100)
        local.attachmentName = "report.pdf"
        local.attachmentMeta = "application/pdf · 2 KB"
        local.attachmentFileID = "local-file"
        local.attachmentSizeBytes = 2048
        local.attachmentPreviewURL = "file:///tmp/local-preview.jpg"
        local.attachmentDownloadURL = "https://example.test/download"
        local.attachmentPreviewAvailable = true
        local.attachmentDownloadAvailable = true
        local.attachmentThumbnailURL = "file:///tmp/thumb.jpg"
        local.attachmentPosterURL = "https://example.test/poster"
        local.attachmentUploadStatus = "uploading"
        local.reactions = [Reaction(id: "local_1_ok", emoji: "ok", count: 1, reactedByMe: true)]
        local.reactionDetails = [ReactionDetail(id: "d1", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")]
        local.readBy = [makeReadReceipt(userID: "reader-1")]
        local.readCount = 1
        local.readStateKnown = true
        local.isPinned = true
        local.isFavorited = true
        var remoteMapped = makeMessage(id: "remote-1", seq: 8, isOutgoing: true, text: "server text", time: "10:01", kind: .file)
        remoteMapped.attachmentFileID = "remote-file"
        remoteMapped.attachmentMimeType = "application/pdf"
        remoteMapped.attachmentCoverURL = "https://example.test/cover"
        remoteMapped.replyContext = MessageReplyContext(messageID: "source", summary: "source")
        conversation.messages = [local]
        store.commitConversationSnapshots([conversation])
        let remoteCreatedAt = Date(timeIntervalSince1970: 200)

        let replacement = try XCTUnwrap(store.replaceLocalMessageWithRemoteConfirmation(
            localID: "local_1",
            remoteMessageID: "remote-1",
            remoteMapped: remoteMapped,
            remoteDisplayTime: "10:01",
            remoteCreatedAt: remoteCreatedAt,
            remoteChannelSeq: 8,
            in: "c1",
            readReceiptsEnabled: true
        ))

        XCTAssertEqual(replacement.previousMessage.id, "local_1")
        let confirmed = replacement.confirmedMessage
        XCTAssertEqual(confirmed.id, "remote-1")
        XCTAssertEqual(confirmed.text, "report.pdf")
        XCTAssertEqual(confirmed.time, "10:01")
        XCTAssertEqual(confirmed.createdAt, remoteCreatedAt)
        XCTAssertEqual(confirmed.channelSeq, 8)
        XCTAssertEqual(confirmed.status, .read)
        XCTAssertEqual(confirmed.attachmentFileID, "remote-file")
        XCTAssertEqual(confirmed.attachmentPreviewURL, "")
        XCTAssertEqual(confirmed.attachmentDownloadURL, "https://example.test/download")
        XCTAssertEqual(confirmed.attachmentThumbnailURL, "")
        XCTAssertEqual(confirmed.attachmentPosterURL, "https://example.test/poster")
        XCTAssertEqual(confirmed.attachmentCoverURL, "https://example.test/cover")
        XCTAssertEqual(confirmed.attachmentUploadStatus, "uploaded")
        XCTAssertNil(confirmed.attachmentTransferProgress)
        XCTAssertEqual(confirmed.reactions, local.reactions)
        XCTAssertEqual(confirmed.reactionDetails, local.reactionDetails)
        XCTAssertEqual(confirmed.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(confirmed.readCount, 1)
        XCTAssertTrue(confirmed.isPinned)
        XCTAssertTrue(confirmed.isFavorited)
        XCTAssertEqual(confirmed.replyContext?.messageID, "source")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["remote-1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "文件")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "10:01")
    }

    func testAppStateAttachmentTransferProgressIgnoresCompletedUploadResidue() throws {
        let state = AppState()
        var message = makeMessage(id: "m1", seq: 1, status: .sending, isOutgoing: true, text: "photo.jpg", kind: .image)
        message.attachmentFileID = "file-1"
        message.attachmentUploadStatus = "uploading"
        message.attachmentTransferProgress = 0.88
        state.fileStore.setAttachmentDownloadProgress(0.88, attachmentID: "file-1")

        XCTAssertTrue(state.isAttachmentUploadInProgress(message))
        XCTAssertEqual(try XCTUnwrap(state.attachmentTransferProgress(for: message)), 0.88, accuracy: 0.001)

        message.status = .sent
        message.attachmentUploadStatus = "uploaded"

        XCTAssertFalse(state.isAttachmentUploadInProgress(message))
        XCTAssertNil(state.attachmentTransferProgress(for: message))
    }

    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
    func testChatAttachmentUpdatesMountedContentWithoutGlobalFileNotifications() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        var message = makeMessage(id: "chat-attachment", seq: 1, text: "report.pdf", kind: .file)
        message.attachmentFileID = "remote-file"
        let key = state.attachmentProgressKey(for: message)
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("report".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let resources = LocalAttachmentPreviewResources(
            previewURL: nil, downloadURL: localURL, thumbnailURL: nil, width: nil, height: nil
        )

        var rendered: [(progress: Double?, failed: Bool, downloaded: Bool, retry: Bool)] = []
        func content() -> some View {
            rendered.append((
                state.attachmentTransferProgress(for: message), state.attachmentDownloadFailed(message),
                state.isMessageAttachmentDownloaded(message), state.canRetryAttachmentUpload(message)
            ))
            return Text("report.pdf")
        }
        let hosted = hostForSimulatorUI(state.observeChatAttachment(message, content: content),
            size: CGSize(width: 320, height: 80))
        defer { hosted.window.isHidden = true }
        func renderPendingChanges() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosted.controller.view.layoutIfNeeded()
        }

        var appStateChanges = 0
        let observation = state.objectWillChange.sink { appStateChanges += 1 }
        defer { observation.cancel() }
        let initialRenderCount = rendered.count
        state.fileStore.markAttachmentDownloadFailed(attachmentID: "foreign-scope|" + key)
        state.fileStore.cacheLocalAttachmentResources(resources, cacheKey: "foreign-scope|remote-file")
        renderPendingChanges()
        XCTAssertEqual(rendered.count, initialRenderCount)

        let token = UUID()
        let task = Task<URL, Error> { localURL }
        state.fileStore.replaceAttachmentDownloadTask(attachmentID: key, with: task, token: token)
        state.fileStore.setAttachmentDownloadSnapshot(
            AttachmentDownloadSnapshot(receivedBytes: 30, totalBytes: 100), attachmentID: key, token: token
        )
        renderPendingChanges()
        XCTAssertEqual(rendered.last?.progress, 0.30)

        state.fileStore.markAttachmentDownloadFailed(attachmentID: key)
        state.fileStore.finishAttachmentDownloadTask(attachmentID: key)
        renderPendingChanges()
        XCTAssertNil(rendered.last?.progress)
        XCTAssertEqual(rendered.last?.failed, true)

        state.cacheLocalAttachmentResources(resources, messageID: message.id, fileID: message.attachmentFileID)
        state.fileStore.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .file, name: "report.pdf", mimeType: "application/pdf", sizeBytes: 6,
            data: Data("report".utf8), conversationID: "conversation", quote: nil, replyContext: nil
        ), messageID: message.id)
        renderPendingChanges()
        XCTAssertEqual(rendered.last?.downloaded, true)
        XCTAssertEqual(rendered.last?.retry, true)

        state.fileStore.clearLocalAttachmentResources()
        state.fileStore.clearPendingAttachmentUpload(messageID: message.id)
        state.fileStore.clearAttachmentDownloadFailed(attachmentID: key)
        renderPendingChanges()
        XCTAssertEqual(rendered.last?.downloaded, false)
        XCTAssertEqual(rendered.last?.retry, false)
        XCTAssertEqual(rendered.last?.failed, false)
        XCTAssertEqual(appStateChanges, 0)

        // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
        var readReceipts: [Bool] = []
        let config = state.fileStore.configurationUpdates(for: \.config.readReceiptsEnabled)
            .sink { readReceipts.append($0) }
        defer { config.cancel() }
        let rendersBeforeConfig = rendered.count
        state.fileStore.replaceUploadConfig(state.fileUploadConfig)
        state.setReadReceiptsEnabled(false)
        renderPendingChanges()
        XCTAssertEqual(readReceipts, [true, false])
        XCTAssertEqual(rendered.count, rendersBeforeConfig)
        XCTAssertEqual(appStateChanges, 0)
        // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END
    }
    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END

    func testFileStoreResetClearsAttachmentRuntimeStateAndLocalResources() throws {
        let store = FileStore()
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-store-local-resource-\(UUID().uuidString).txt")
        try Data("local-resource".utf8).write(to: localURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: localURL)
        }
        let downloadTask = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return localURL
        }
        defer {
            downloadTask.cancel()
        }

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: downloadTask)
        store.setAttachmentDownloadProgress(0.42, attachmentID: "file-1")
        store.markAttachmentDownloadFailed(attachmentID: "file-1")
        store.cacheLocalAttachmentResources(LocalAttachmentPreviewResources(
            previewURL: localURL,
            downloadURL: localURL,
            thumbnailURL: nil,
            width: nil,
            height: nil
        ), cacheKey: "scope|file-1")

        store.reset()

        XCTAssertTrue(downloadTask.isCancelled)
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "file-1"))
        XCTAssertNil(store.attachmentDownloadProgress(attachmentID: "file-1"))
        XCTAssertFalse(store.isAttachmentDownloadFailed(attachmentID: "file-1"))
        XCTAssertNil(store.localAttachmentResources(cacheKey: "scope|file-1"))
    }

    func testFileStoreLocalAttachmentResourceCacheLifecycle() throws {
        let store = FileStore()
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("local-resource".utf8).write(to: localURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: localURL)
        }
        let resources = LocalAttachmentPreviewResources(
            previewURL: localURL,
            downloadURL: localURL,
            thumbnailURL: nil,
            width: 24,
            height: 12
        )

        store.cacheLocalAttachmentResources(resources, cacheKey: " scope|file-1 ")
        store.cacheLocalAttachmentResources(resources, cacheKeys: ["scope|file-2", " "])

        XCTAssertEqual(store.localAttachmentResources(cacheKey: "scope|file-1")?.width, 24)
        XCTAssertEqual(store.localAttachmentResources(cacheKey: " scope|file-2 ")?.height, 12)
        XCTAssertNil(store.localAttachmentResources(cacheKey: ""))

        store.clearLocalAttachmentResources(cacheKey: "scope|file-1")
        XCTAssertNil(store.localAttachmentResources(cacheKey: "scope|file-1"))
        XCTAssertNotNil(store.localAttachmentResources(cacheKey: "scope|file-2"))

        store.clearLocalAttachmentResources()
        XCTAssertNil(store.localAttachmentResources(cacheKey: "scope|file-2"))
    }

    func testFileStoreGroupFilesSyncStateAndErrorsLifecycle() throws {
        let store = FileStore()
        let file = FileItem(
            id: "file-1",
            name: "report.pdf",
            type: "PDF",
            size: "2 KB",
            owner: "Mia",
            source: "产品内测群",
            time: "10:00",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group"
        )

        // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
        var updates: [FileStore.GroupFilesSnapshot] = []
        let observation = store.groupFilesUpdates(groupID: "g_files").sink { updates.append($0) }
        defer { observation.cancel() }
        _ = store.beginGroupFilesSync(groupID: "other")
        store.setGroupSyncError("unrelated error", groupID: "other")
        store.replaceGroupFiles([file], groupID: "other")
        XCTAssertEqual(updates, [store.groupFilesSnapshot(groupID: "g_files")])
        // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END

        XCTAssertFalse(store.hasGroupFiles(groupID: "g_files"))
        XCTAssertFalse(store.isGroupSyncing(groupID: "g_files"))
        XCTAssertNil(store.groupSyncError(groupID: "g_files"))

        XCTAssertTrue(store.beginGroupFilesSync(groupID: "g_files"))
        XCTAssertFalse(store.beginGroupFilesSync(groupID: "g_files"))
        XCTAssertTrue(store.isGroupSyncing(groupID: "g_files"))

        store.setGroupSyncError("群文件同步失败，请稍后重试", groupID: "g_files")
        XCTAssertEqual(store.groupSyncError(groupID: "g_files"), "群文件同步失败，请稍后重试")

        store.replaceGroupFiles([file], groupID: "g_files")
        XCTAssertTrue(store.hasGroupFiles(groupID: "g_files"))
        XCTAssertEqual(store.files(for: "g_files").map(\.id), ["file-1"])

        store.finishGroupFilesSync(groupID: "g_files")
        XCTAssertFalse(store.isGroupSyncing(groupID: "g_files"))

        XCTAssertTrue(store.beginGroupFilesSync(groupID: "g_files"))
        XCTAssertNil(store.groupSyncError(groupID: "g_files"))
        store.finishGroupFilesSync(groupID: "g_files")

        store.reset()

        XCTAssertFalse(store.hasGroupFiles(groupID: "g_files"))
        XCTAssertFalse(store.isGroupSyncing(groupID: "g_files"))
        XCTAssertNil(store.groupSyncError(groupID: "g_files"))

        // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
        XCTAssertEqual(updates.map(\.isSyncing), [false, true, true, true, false, true, true, false, false])
        XCTAssertEqual(updates[3].files.map(\.id), ["file-1"])
        XCTAssertEqual(updates[2].syncError, "群文件同步失败，请稍后重试")
        XCTAssertNil(updates[6].syncError)
        XCTAssertEqual(updates.last, store.groupFilesSnapshot(groupID: "g_files"))
        // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END
    }

    func testFileStoreExcludesVoiceMessagesFromTenantAndGroupFileLists() {
        let store = FileStore()
        let regularAudio = FileItem(
            id: "audio-track",
            name: "meeting-theme.m4a",
            type: "音频",
            size: "12 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:00",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "audio",
            contentType: "file",
            kind: "file",
            mimeType: "audio/mp4"
        )
        let contentTypeVoice = FileItem(
            id: "voice-content-type",
            name: "recording.m4a",
            type: "音频",
            size: "8 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:01",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "audio",
            contentType: "voice",
            kind: "file",
            mimeType: "audio/mp4"
        )
        let mediaCategoryVoice = FileItem(
            id: "voice-media-category",
            name: "recording.webm",
            type: "音频",
            size: "9 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:02",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "voice",
            contentType: "file",
            kind: "file",
            mimeType: "audio/webm"
        )
        let kindVoice = FileItem(
            id: "voice-kind",
            name: "recording.amr",
            type: "音频",
            size: "7 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:03",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "audio",
            contentType: "file",
            kind: "voice",
            mimeType: "audio/amr"
        )
        let legacyVoice = FileItem(
            id: "voice-legacy",
            name: "voice-20260725140831.webm",
            type: "音频",
            size: "10 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:04",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "audio",
            contentType: "file",
            kind: "file",
            mimeType: "audio/webm"
        )
        let allFiles = [regularAudio, contentTypeVoice, mediaCategoryVoice, kindVoice, legacyVoice]

        store.replaceTenantFiles(allFiles)
        store.replaceGroupFiles(allFiles, groupID: "g_files")

        XCTAssertEqual(store.tenantFiles().map(\.id), ["audio-track"])
        XCTAssertEqual(store.files(for: "g_files").map(\.id), ["audio-track"])

        store.upsertTenantFile(contentTypeVoice)

        XCTAssertEqual(store.tenantFiles().map(\.id), ["audio-track"])
        XCTAssertEqual(store.files(for: "g_files").map(\.id), ["audio-track"])

        store.mergeGroupFiles([contentTypeVoice])

        XCTAssertTrue(store.files(for: "g_files").isEmpty)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

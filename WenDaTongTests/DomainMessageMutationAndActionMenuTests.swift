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
    func testConversationStoreUpsertCreatedGroupConversationCreatesNewRowAtTop() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        ])

        let created = store.upsertCreatedGroupConversation(
            groupID: " group-1 ",
            name: "Team Blue",
            members: [makeUser(id: "u1")],
            invitedMemberCount: 3,
            accentHex: 77,
            sortTimestamp: 111,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(created?.id, "group-1")
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["group-1", "older"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "群聊已创建")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "刚刚")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].memberCount, 4)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].accentHex, 77)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].sortTimestamp, 111)
        XCTAssertNil(store.upsertCreatedGroupConversation(
            groupID: "   ",
            name: "Invalid",
            members: [],
            invitedMemberCount: 0,
            accentHex: 0,
            channelIDForConversation: { $0.id }
        ))
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["group-1", "older"])
    }

    func testConversationStoreEnsureGroupConversationMergesExistingOrAppendsMissingGroup() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var existing = makeConversation(id: "legacy", kind: .group, unread: 4, lastMsgSeq: 8, lastReadSeq: 2)
        existing.title = "Old Name"
        existing.isMuted = false
        existing.participants = [makeUser(id: "old")]
        existing.avatarURL = "https://avatar.example/group-old.png"
        existing.avatarUpdatedAt = "old-time"
        existing.messages = [makeMessage(id: "m1", seq: 8)]
        store.commitConversationSnapshots([existing])

        let updated = store.ensureGroupConversation(
            groupID: " remote-1 ",
            name: "Team Blue",
            notice: "公告",
            members: [],
            muted: true,
            memberCount: 6,
            avatarURL: "",
            avatarVersion: "v2",
            avatarUpdatedAt: "",
            accentHex: 99,
            channelIDForConversation: { conversation in conversation.id == "legacy" ? "remote-1" : conversation.id }
        )

        XCTAssertEqual(updated?.id, "legacy")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].title, "Team Blue")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "公告")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].isMuted, false)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].memberCount, 6)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["old"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarURL, "https://avatar.example/group-old.png")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarVersion, "v2")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarUpdatedAt, "old-time")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["m1"])

        let cleared = store.ensureGroupConversation(
            groupID: "remote-1",
            name: "Team Blue",
            notice: "公告",
            members: [],
            muted: true,
            memberCount: 6,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: "",
            avatarIsAuthoritative: true,
            accentHex: 99,
            channelIDForConversation: { conversation in conversation.id == "legacy" ? "remote-1" : conversation.id }
        )

        XCTAssertEqual(cleared?.avatarURL, "")
        XCTAssertEqual(cleared?.avatarVersion, "")
        XCTAssertEqual(cleared?.avatarUpdatedAt, "")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["m1"])
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["legacy"])

        let appended = store.ensureGroupConversation(
            groupID: "new-group",
            name: "New Group",
            notice: "新公告",
            members: [makeUser(id: "u2")],
            muted: true,
            memberCount: 2,
            avatarURL: "https://avatar.example/new.png",
            avatarVersion: "v1",
            avatarUpdatedAt: "now",
            accentHex: 100,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(appended?.id, "new-group")
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["legacy", "new-group"])
        XCTAssertEqual(store.conversationMessageSnapshots()[1].lastMessage, "新公告")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].isMuted, true)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["u2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[1].avatarURL, "https://avatar.example/new.png")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].avatarVersion, "v1")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].avatarUpdatedAt, "now")
        XCTAssertNil(store.ensureGroupConversation(
            groupID: "   ",
            name: "   ",
            notice: "",
            members: [],
            muted: false,
            memberCount: 0,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: "",
            accentHex: 0,
            channelIDForConversation: { $0.id }
        ))
    }

    func testConversationStoreGroupMemberCountZeroDoesNotRestoreCachedOrLoadedTotals() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var existing = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        existing.title = "Team Blue"
        existing.memberCount = 91
        existing.participants = [makeUser(id: "u1"), makeUser(id: "u2")]
        store.commitConversationSnapshots([existing])

        XCTAssertNotNil(store.ensureGroupConversation(
            groupID: "group-1",
            name: "Team Blue",
            notice: "公告",
            members: [],
            muted: false,
            memberCount: 0,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: "",
            accentHex: 42,
            channelIDForConversation: { $0.id }
        ))
        XCTAssertNil(store.conversationMessageSnapshots()[0].memberCount)

        XCTAssertTrue(store.setGroupConversationParticipants(
            groupID: "group-1",
            groupName: "Team Blue",
            participants: [],
            memberCount: 0
        ))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u1", "u2"])
        XCTAssertNil(store.conversationMessageSnapshots()[0].memberCount)
    }

    func testGroupInfoMemberCountDisplayDistinguishesUnknownFromZero() {
        let unknown = GroupInfo(
            id: "group-unknown",
            name: "交易通知群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false
        )
        var known = unknown
        known.memberCount = 91

        XCTAssertNil(unknown.visibleMemberCount)
        XCTAssertEqual(unknown.memberCountDisplayText, "人数待同步")
        XCTAssertEqual(known.visibleMemberCount, 91)
        XCTAssertEqual(known.memberCountDisplayText, "91 人")
    }

    func testConversationStoreSetGroupConversationParticipantsMatchesIDAndNameAndUpdatesCount() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var idMatch = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        idMatch.title = "Original"
        idMatch.participants = [makeUser(id: "old-1")]
        idMatch.memberCount = 1
        var nameMatch = makeConversation(id: "legacy", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        nameMatch.title = "Team Blue"
        nameMatch.participants = [makeUser(id: "old-2")]
        nameMatch.memberCount = 1
        store.commitConversationSnapshots([idMatch, nameMatch])

        XCTAssertTrue(store.setGroupConversationParticipants(
            groupID: " group-1 ",
            groupName: "Ignored",
            participants: [makeUser(id: "u1"), makeUser(id: "u2")],
            memberCount: 4
        ))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u1", "u2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].memberCount, 4)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["old-2"])

        XCTAssertTrue(store.setGroupConversationParticipants(
            groupID: "missing",
            groupName: " Team Blue ",
            participants: [],
            memberCount: 0
        ))
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["old-2"])
        XCTAssertNil(store.conversationMessageSnapshots()[1].memberCount)
    }

    func testConversationStoreSetGroupConversationParticipantsIgnoresEmptyOrMissingTarget() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var group = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        group.title = "Team"
        group.participants = [makeUser(id: "old")]
        group.memberCount = 1
        store.commitConversationSnapshots([group])

        XCTAssertFalse(store.setGroupConversationParticipants(
            groupID: " ",
            groupName: " ",
            participants: [makeUser(id: "u1")],
            memberCount: 3
        ))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["old"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].memberCount, 1)

        XCTAssertFalse(store.setGroupConversationParticipants(
            groupID: "missing",
            groupName: "Missing",
            participants: [],
            memberCount: 0
        ))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["old"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].memberCount, 1)
    }

    func testConversationStoreAppendLocalOutgoingMessageUpdatesMessagesAndExplicitPreview() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.lastMessage = "previous"
        conversation.time = "09:00"
        conversation.sortTimestamp = 100
        store.commitConversationSnapshots([conversation])

        var message = makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "hello", time: "刚刚")
        message.createdAt = Date(timeIntervalSince1970: 1_234)

        let updated = store.appendLocalOutgoingMessage(
            message,
            to: " c1 ",
            preview: "explicit preview"
        )

        XCTAssertEqual(updated?.id, "c1")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["local_1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "explicit preview")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "刚刚")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].sortTimestamp, 1_234)
    }

    func testConversationStoreAppendLocalOutgoingMessageUsesMessagePreviewAndSkipsMissingTarget() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        ])

        var fileMessage = makeMessage(id: "local_file", seq: 0, status: .sending, isOutgoing: true, text: "report.pdf", time: "刚刚", kind: .file)
        fileMessage.createdAt = Date(timeIntervalSince1970: 2_468)
        fileMessage.attachmentName = "report.pdf"
        fileMessage.attachmentMediaCategory = "pdf"

        XCTAssertNil(store.appendLocalOutgoingMessage(fileMessage, to: "missing"))
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages.isEmpty)

        let updated = store.appendLocalOutgoingMessage(fileMessage, to: "c1")

        XCTAssertEqual(updated?.messages.map(\.id), ["local_file"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "文件")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "刚刚")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].sortTimestamp, 2_468)
    }

    func testConversationStoreApplyLocalMessageEditUpdatesMessageAndPreview() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, text: "old text")
        message.isEdited = false
        conversation.messages = [message]
        conversation.lastMessage = "old text"
        conversation.time = "09:00"
        conversation.sortTimestamp = 100
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.applyLocalMessageEdit(
            messageID: " m1 ",
            conversationID: " c1 ",
            text: " updated text "
        ))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].text, "updated text")
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].isEdited)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .sent)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "updated text")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "09:00")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].sortTimestamp, 100)
    }

    func testConversationStoreApplyLocalMessageEditSkipsInvalidOrMissingTargets() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        conversation.messages = [makeMessage(id: "m1", seq: 1, status: .sent, text: "old text")]
        conversation.lastMessage = "old text"
        store.commitConversationSnapshots([conversation])

        XCTAssertFalse(store.applyLocalMessageEdit(messageID: " ", conversationID: "c1", text: "new"))
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "m1", conversationID: " ", text: "new"))
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "m1", conversationID: "c1", text: " "))
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "missing", conversationID: "c1", text: "new"))
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "m1", conversationID: "missing", text: "new"))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].text, "old text")
        XCTAssertFalse(store.conversationMessageSnapshots()[0].messages[0].isEdited)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "old text")
    }

    func testMessageEditSuccessReturnsToLatestOnlyForCurrentAuthoritativeProjection() throws {
        var current = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true, text: "updated text")
        current.editRevision = 2

        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: false,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))
        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-b|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))
        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c2",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))

        current.editRevision = 1
        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))
        current.editRevision = 2
        current.text = "different authoritative text"
        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))

        current.text = "updated text"
        let success = try XCTUnwrap(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: " updated text ",
            expectedRevision: 1,
            currentMessage: current
        ))
        XCTAssertEqual(success.authoritativeRevision, 2)
        XCTAssertTrue(messageEditAuthoritativeSuccessIsCurrent(
            success,
            currentScope: "tenant-a|user-a",
            currentConversationID: "c1",
            currentMessage: current
        ))
        XCTAssertFalse(messageEditAuthoritativeSuccessIsCurrent(
            success,
            currentScope: "tenant-b|user-a",
            currentConversationID: "c1",
            currentMessage: current
        ))
        current.text = "newer competing edit"
        current.editRevision = 3
        XCTAssertFalse(messageEditAuthoritativeSuccessIsCurrent(
            success,
            currentScope: "tenant-a|user-a",
            currentConversationID: "c1",
            currentMessage: current
        ))
    }

    func testConversationStoreMarkAttachmentUploadFailedRetainsProvidedFailure() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sending, isOutgoing: true, text: "report.pdf", kind: .file)
        message.attachmentTransferProgress = 0.4
        message.attachmentUploadStatus = "queued"
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        let failure = AttachmentUploadFailure(code: .http, httpStatus: 503, serverCode: "service_unavailable")
        XCTAssertTrue(store.markAttachmentUploadFailed(
            messageID: " m1 ", conversationID: " c1 ", failureStatus: " FAILED_PUT ", failure: failure
        ))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .failed)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentUploadStatus, "failed_put")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentUploadFailure, failure)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentTransferProgress ?? -1, 0.4, accuracy: 0.001)
    }

    func testConversationStoreMarkAttachmentUploadRetryingUpdatesStatusProgressAndUploadStatus() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, text: "report.pdf", kind: .file)
        message.attachmentTransferProgress = nil
        message.attachmentUploadStatus = "failed"
        message.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.markAttachmentUploadRetrying(messageID: " m1 ", conversationID: " c1 "))

        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[0].attachmentUploadFailure)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .sending)
        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[0].attachmentTransferProgress)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentUploadStatus, "retrying")
    }

    func testConversationStoreUpdateAttachmentUploadStatusClearsPreviousFailure() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, kind: .file)
        message.attachmentUploadStatus = "failed_put"
        message.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        let updated = try XCTUnwrap(store.updateAttachmentUploadStatus(
            " UPLOADED ", messageID: "m1", conversationID: "c1"
        ))

        XCTAssertEqual(updated.attachmentUploadStatus, "uploaded")
        XCTAssertNil(updated.attachmentUploadFailure)
        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[0].attachmentUploadFailure)
    }

    func testAttachmentUploadFailureMessageShowsOnlySafeDetailWhileFailed() throws {
        let state = AppState()
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, kind: .file)
        message.attachmentUploadStatus = "failed_put"
        message.attachmentUploadFailure = AttachmentUploadFailure(
            code: .http, httpStatus: 403, serverCode: "synthetic_token_without_punctuation"
        )

        let detail = try XCTUnwrap(state.attachmentUploadFailureMessage(for: message))
        XCTAssertEqual(detail, "文件内容上传失败，请重试\nHTTP · HTTP 403 · unrecognized_server_code")
        XCTAssertFalse(detail.contains("synthetic_token"))
        for status in [MessageDelivery.sending, .sent, .read, .recalled] {
            message.status = status
            XCTAssertNil(state.attachmentUploadFailureMessage(for: message))
        }
    }

    func testConversationStoreAttachmentUploadStateSkipsInvalidOrMissingTargets() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true, text: "report.pdf", kind: .file)
        message.attachmentTransferProgress = 0.7
        message.attachmentUploadStatus = "queued"
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertFalse(store.markAttachmentUploadFailed(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.markAttachmentUploadFailed(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.markAttachmentUploadFailed(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.markAttachmentUploadFailed(messageID: "m1", conversationID: "missing"))
        XCTAssertFalse(store.markAttachmentUploadRetrying(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.markAttachmentUploadRetrying(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.markAttachmentUploadRetrying(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.markAttachmentUploadRetrying(messageID: "m1", conversationID: "missing"))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .sent)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentTransferProgress ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentUploadStatus, "queued")
    }

    func testConversationStoreAttachmentFileIDAndProgressStateUpdatesMessage() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sending, isOutgoing: true, text: "report.pdf", kind: .file)
        message.attachmentFileID = "old-file"
        message.attachmentTransferProgress = nil
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        let fileUpdated = try XCTUnwrap(store.setAttachmentFileID(" file-2 ", messageID: " m1 ", conversationID: " c1 "))
        XCTAssertEqual(fileUpdated.attachmentFileID, "file-2")

        let progressUpdated = try XCTUnwrap(store.updateAttachmentProgress(0.42, messageID: " m1 ", conversationID: " c1 "))
        XCTAssertEqual(progressUpdated.attachmentTransferProgress ?? -1, 0.42, accuracy: 0.001)

        let cleared = try XCTUnwrap(store.updateAttachmentProgress(nil, messageID: " m1 ", conversationID: " c1 "))
        XCTAssertNil(cleared.attachmentTransferProgress)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentFileID, "file-2")
        XCTAssertNil(store.conversationMessageSnapshots()[0].messages[0].attachmentTransferProgress)
    }

    func testConversationStoreUpdateMessageAttachmentCopiesMetadataAndUpdatesLatestPreview() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, text: "old.pdf", time: "09:00", kind: .file)
        message.attachmentName = "old.pdf"
        message.attachmentMediaCategory = "pdf"
        conversation.messages = [message]
        conversation.lastMessage = "[PDF] old.pdf"
        store.commitConversationSnapshots([conversation])

        var updated = message
        updated.attachmentName = "demo.mp4"
        updated.attachmentMeta = "video/mp4 · 4 MB"
        updated.attachmentFileID = "file-video"
        updated.attachmentSizeBytes = 4_194_304
        updated.attachmentPreviewURL = "https://example.test/preview"
        updated.attachmentDownloadURL = "https://example.test/download"
        updated.attachmentPreviewAvailable = true
        updated.attachmentDownloadAvailable = true
        updated.attachmentTransferProgress = 0.66
        updated.attachmentMimeType = "video/mp4"
        updated.attachmentCacheKey = "cache-video"
        updated.attachmentVersion = "v2"
        updated.attachmentChecksum = "checksum"
        updated.attachmentMediaCategory = "video"
        updated.attachmentExtension = "mp4"
        updated.attachmentThumbnailURL = "https://example.test/thumb"
        updated.attachmentPosterURL = "https://example.test/poster"
        updated.attachmentCoverURL = "https://example.test/cover"
        updated.attachmentPreviewKind = "video"
        updated.attachmentContentDisposition = "inline"
        updated.attachmentWidth = 1280
        updated.attachmentHeight = 720
        updated.attachmentDurationSeconds = 12.5
        updated.attachmentUploadStatus = "uploaded"

        let result = try XCTUnwrap(store.updateMessageAttachment(updated, conversationID: " c1 "))

        XCTAssertEqual(result.attachmentName, "demo.mp4")
        XCTAssertEqual(result.attachmentMeta, "video/mp4 · 4 MB")
        XCTAssertEqual(result.attachmentFileID, "file-video")
        XCTAssertEqual(result.attachmentSizeBytes, 4_194_304)
        XCTAssertEqual(result.attachmentPreviewURL, "https://example.test/preview")
        XCTAssertEqual(result.attachmentDownloadURL, "https://example.test/download")
        XCTAssertTrue(result.attachmentPreviewAvailable)
        XCTAssertTrue(result.attachmentDownloadAvailable)
        XCTAssertEqual(result.attachmentTransferProgress ?? -1, 0.66, accuracy: 0.001)
        XCTAssertEqual(result.attachmentMimeType, "video/mp4")
        XCTAssertEqual(result.attachmentCacheKey, "cache-video")
        XCTAssertEqual(result.attachmentVersion, "v2")
        XCTAssertEqual(result.attachmentChecksum, "checksum")
        XCTAssertEqual(result.attachmentMediaCategory, "video")
        XCTAssertEqual(result.attachmentExtension, "mp4")
        XCTAssertEqual(result.attachmentThumbnailURL, "https://example.test/thumb")
        XCTAssertEqual(result.attachmentPosterURL, "https://example.test/poster")
        XCTAssertEqual(result.attachmentCoverURL, "https://example.test/cover")
        XCTAssertEqual(result.attachmentPreviewKind, "video")
        XCTAssertEqual(result.attachmentContentDisposition, "inline")
        XCTAssertEqual(result.attachmentWidth, 1280)
        XCTAssertEqual(result.attachmentHeight, 720)
        XCTAssertEqual(result.attachmentDurationSeconds, 12.5)
        XCTAssertEqual(result.attachmentUploadStatus, "uploaded")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "视频")
    }

    func testConversationStoreAttachmentMetadataStateSkipsInvalidOrMissingTargets() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, text: "report.pdf", kind: .file)
        message.attachmentFileID = "file-1"
        message.attachmentTransferProgress = 0.7
        message.attachmentName = "report.pdf"
        conversation.messages = [message]
        conversation.lastMessage = "[文件] report.pdf"
        store.commitConversationSnapshots([conversation])

        XCTAssertNil(store.setAttachmentFileID(" ", messageID: "m1", conversationID: "c1"))
        XCTAssertNil(store.setAttachmentFileID("file-2", messageID: " ", conversationID: "c1"))
        XCTAssertNil(store.setAttachmentFileID("file-2", messageID: "m1", conversationID: " "))
        XCTAssertNil(store.setAttachmentFileID("file-2", messageID: "missing", conversationID: "c1"))
        XCTAssertNil(store.updateAttachmentProgress(0.2, messageID: " ", conversationID: "c1"))
        XCTAssertNil(store.updateAttachmentProgress(0.2, messageID: "m1", conversationID: " "))
        XCTAssertNil(store.updateAttachmentProgress(0.2, messageID: "missing", conversationID: "c1"))
        XCTAssertNil(store.updateMessageAttachment(makeMessage(id: " ", seq: 1, kind: .file), conversationID: "c1"))
        XCTAssertNil(store.updateMessageAttachment(makeMessage(id: "missing", seq: 1, kind: .file), conversationID: "c1"))
        XCTAssertNil(store.updateMessageAttachment(message, conversationID: " "))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentFileID, "file-1")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentTransferProgress ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].attachmentName, "report.pdf")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "[文件] report.pdf")
    }

    func testConversationStoreMessageActionStateReadsAndUpdatesPinnedAndFavorite() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        message.isFavorited = true
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertEqual(store.messagePinnedState(messageID: " m1 ", conversationID: " c1 "), false)
        XCTAssertEqual(store.messageFavoritedState(messageID: " m1 ", conversationID: " c1 "), true)
        XCTAssertTrue(store.setMessagePinned(messageID: " m1 ", conversationID: " c1 ", pinned: true))
        XCTAssertTrue(store.setMessageFavorited(messageID: " m1 ", conversationID: " c1 ", favorited: false))

        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].isPinned)
        XCTAssertFalse(store.conversationMessageSnapshots()[0].messages[0].isFavorited)
    }

    func testMessageReportActionOnlyShowsForOtherRemoteMessages() {
        let incoming = makeMessage(id: "remote-1", seq: 1, status: .sent, isOutgoing: false)
        let outgoing = makeMessage(id: "remote-2", seq: 2, status: .sent, isOutgoing: true)
        let local = makeMessage(id: "local_1", seq: 0, status: .sent, isOutgoing: false)
        let recalled = makeMessage(id: "remote-3", seq: 3, status: .recalled, isOutgoing: false)

        XCTAssertTrue(messageReportActionIsAvailable(message: incoming, isCurrentUserSender: false))
        XCTAssertFalse(messageReportActionIsAvailable(message: incoming, isCurrentUserSender: true))
        XCTAssertFalse(messageReportActionIsAvailable(message: outgoing, isCurrentUserSender: true))
        XCTAssertFalse(messageReportActionIsAvailable(message: local, isCurrentUserSender: false))
        XCTAssertFalse(messageReportActionIsAvailable(message: recalled, isCurrentUserSender: false))
    }

    func testMessageActionMenuPlacesReportLastAndDangerWhenAvailable() {
        let incoming = makeMessage(id: "remote-1", seq: 1, status: .sent, isOutgoing: false)

        let descriptors = messageActionMenuDescriptors(
            message: incoming,
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: true,
            canFavoriteAsset: false,
            canReportMessage: true,
            canAdminDeleteForAll: true,
            recallDisabledReason: nil
        )

        XCTAssertEqual(descriptors.last?.kind, .report)
        XCTAssertEqual(descriptors.last?.title, "举报此消息")
        XCTAssertEqual(descriptors.last?.tone, .danger)
        XCTAssertEqual(descriptors.last?.showsDividerBefore, true)
        XCTAssertFalse(descriptors.contains { $0.kind == .delete })

        let ownDescriptors = messageActionMenuDescriptors(
            message: makeMessage(id: "remote-2", seq: 2, status: .sent, isOutgoing: true),
            canShowReadActions: true,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: false,
            canFavoriteAsset: false,
            canReportMessage: false,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        )
        XCTAssertFalse(ownDescriptors.contains { $0.kind == .report })
        XCTAssertEqual(ownDescriptors.first { $0.kind == .delete }?.title, "删除该消息")
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

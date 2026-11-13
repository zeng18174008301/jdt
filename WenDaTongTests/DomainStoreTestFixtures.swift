import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong
// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_BEGIN
import IM4Domain
import IM4Stores
// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_END

// WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_BEGIN
@MainActor
final class ConversationListMountedProjectionProbe {
    private(set) var clock = Date()
    var projected: [Set<String>?] = []

    init(binding: UUID) {
        ConversationListProjectionDiagnostics.clock = { [weak self] scope in
            scope == binding ? self?.clock : nil
        }
        ConversationListProjectionDiagnostics.didProject = { [weak self] scope, ids in
            if scope == binding { self?.projected.append(ids) }
        }
    }

    func stop() {
        ConversationListProjectionDiagnostics.clock = nil
        ConversationListProjectionDiagnostics.didProject = nil
    }

    func verifyVisibleUpdates(in table: UITableView, store: ConversationStore, index: Int) async throws {
        let targetPath = IndexPath(row: index + 1, section: 0)
        let neighborPath = IndexPath(row: index + 2, section: 0)
        table.scrollToRow(at: targetPath, at: .middle, animated: false)
        table.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(table.indexPathsForVisibleRows?.contains(targetPath) == true)
        XCTAssertTrue(table.indexPathsForVisibleRows?.contains(neighborPath) == true)
        let target = try XCTUnwrap(table.cellForRow(at: targetPath))
        let neighbor = try XCTUnwrap(table.cellForRow(at: neighborPath))
        let targetBefore = try renderedCell(target)
        let neighborBefore = try renderedCell(neighbor)
        let rowProjectionsBefore = ConversationListLayoutDiagnostics.rowProjections

        projected.removeAll()
        store.mutateStoredConversation(at: index) { $0.lastMessage = "Same-minute visible preview" }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(projected, [Set([store.conversations[index].id])])
        XCTAssertLessThan(ConversationListLayoutDiagnostics.rowProjections - rowProjectionsBefore, 10)
        XCTAssertTrue(table.cellForRow(at: targetPath) === target)
        XCTAssertTrue(table.cellForRow(at: neighborPath) === neighbor)
        let targetAfter = try renderedCell(target)
        XCTAssertNotEqual(targetAfter, targetBefore)
        XCTAssertEqual(try renderedCell(neighbor), neighborBefore)

        projected.removeAll()
        clock = clock.addingTimeInterval(60)
        store.mutateStoredConversation(at: index) { $0.lastMessage = "Preview after the minute changed" }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(projected, [nil])
        XCTAssertTrue(table.cellForRow(at: targetPath) === target)
        XCTAssertNotEqual(try renderedCell(target), targetAfter)
    }

    private func renderedCell(_ cell: UITableViewCell) throws -> Data {
        cell.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { _ in
            XCTAssertTrue(cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true))
        }
        return try XCTUnwrap(image.pngData())
    }
}

extension DomainStoreTests {
    @MainActor
    func testConversationListKeepsFirstDuplicateAndReprojectsKnownDuplicateUpdates() throws {
        let store = ConversationStore(scope: try LocalMessageScope(context: TestMessageMemoryScope.context))
        let memory = store.messageMemoryStore
        var first = makeConversation(id: "duplicate", unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        first.title = "First"
        var duplicate = first
        duplicate.title = "Duplicate search match"
        duplicate.unread = 3
        duplicate.isPinned = true
        duplicate.hasMention = true
        duplicate.mentionCount = 3
        let peer = makeConversation(id: "peer", unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        store.commitConversationSnapshots([first, peer, duplicate])
        let changes = ConversationListMemoryChanges()
        let physical = store.conversationMessageSnapshots()
        let representatives = changes.representativeRows(in: physical)
        changes.didProject(binding: memory.bindingID, revision: memory.revision)
        XCTAssertEqual(representatives, [first, peer])
        XCTAssertEqual(changes.row(id: first.id, in: memory), representatives.first)
        XCTAssertEqual(physical.filter(\.hasMention).map(\.mentionCount), [3])

        var latestCommit: ConversationStore.MemoryCommit?
        let observation = store.memoryCommits.sink { latestCommit = $0 }
        defer { observation.cancel() }
        // WDT_IOS1_CONVERSATION_LIST_CORE_INVALIDATION_20261112_BEGIN
        store.mutateStoredConversation(at: 2) {
            $0.mentionCount = 4
            $0.mentionSummaryText = "Updated secondary mention"
        }
        let commit = try XCTUnwrap(latestCommit)
        XCTAssertTrue(commit.requiresFullConversationListProjection)
        XCTAssertTrue(commit.changedConversationRowIDs.isEmpty)
        XCTAssertTrue(commit.messageChanges.isEmpty)
        XCTAssertFalse(commit.conversationOrderChanged)
        XCTAssertTrue(changes.receive(commit, activeBinding: memory.bindingID))
        XCTAssertEqual(changes.pending, .full)
        let refreshed = store.conversationMessageSnapshots()
        XCTAssertEqual(changes.representativeRows(in: refreshed), [first, peer])
        XCTAssertEqual(refreshed.filter(\.hasMention).map(\.mentionCount), [4])
        XCTAssertEqual(refreshed.filter(\.hasMention).map(\.mentionSummaryText), ["Updated secondary mention"])

        store.commitConversationSnapshots([first, peer])
        XCTAssertTrue(changes.receive(try XCTUnwrap(latestCommit), activeBinding: memory.bindingID))
        store.mutateStoredConversation(at: 1) { $0.lastMessage = "Ordinary point update" }
        let point = try XCTUnwrap(latestCommit)
        XCTAssertFalse(point.requiresFullConversationListProjection)
        XCTAssertEqual(point.changedConversationRowIDs, [peer.id])
        XCTAssertTrue(changes.receive(point, activeBinding: memory.bindingID))
        XCTAssertEqual(changes.pending, .full)
        changes.didProject(binding: memory.bindingID, revision: memory.revision)
        XCTAssertFalse(changes.receive(commit, activeBinding: memory.bindingID))
        store.mutateStoredConversation(at: 1) { $0.lastMessage = "Next point update" }
        XCTAssertTrue(changes.receive(try XCTUnwrap(latestCommit), activeBinding: memory.bindingID))
        XCTAssertEqual(changes.pending, .rows([peer.id]))
        // WDT_IOS1_CONVERSATION_LIST_CORE_INVALIDATION_20261112_END
    }
}
// WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_END

extension DomainStoreTests {
    @MainActor
    func testAppConversationFacadeOwnsAvailabilityPublishersAndRetiresOneActualModule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-facade-\(UUID().uuidString)")
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("cache"))
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messagePersistence: persistence,
            protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: makeAuthenticatedAPIContext(accountID: UUID().uuidString))
        addTeardownBlock { @MainActor in await persistence.detach(ticket: state.localMessageTicket)
            try? FileManager.default.removeItem(at: root) }
        let owner = state.conversationStore
        XCTAssertTrue(String(reflecting: type(of: owner)).hasPrefix("IM4Stores."))
        let conversationID = "actual-facade"
        var observations: [ConversationStore.ChatAvailabilitySnapshot] = []
        var projectedHistory: [String: String] = [:]
        let availability = owner.chatAvailabilityUpdates(for: conversationID).sink { observations.append($0) }
        let projected = owner.$historyMessages.sink { projectedHistory = $0 }
        defer { availability.cancel(); projected.cancel() }
        let claim = try XCTUnwrap(owner.beginMessageSyncClaim(historyKey: "facade-history", conversationID: conversationID, showLoadingIndicator: true))
        owner.setHistoryMessage(conversationID: conversationID, message: "loading")
        owner.setDirectDisabledMessage(conversationID: conversationID, message: "friend required")
        XCTAssertTrue(owner.beginApplyingFriend(conversationID: conversationID))
        let context = DirectFriendRequestContext(targetUID: "peer", canApplyFriend: true, friendRequestStatus: "none", reasonCode: "friend_required")
        owner.setDirectFriendRequestContext(conversationID: conversationID, context: context)
        let current = owner.chatAvailability(for: conversationID)
        XCTAssertTrue(current.isHistoryLoading); XCTAssertTrue(current.isApplyingFriend)
        XCTAssertEqual(current.historyMessage, "loading"); XCTAssertEqual(current.directDisabledMessage, "friend required")
        XCTAssertEqual(current.friendRequestContext, context); XCTAssertEqual(observations.last, current)
        XCTAssertEqual(projectedHistory[conversationID], "loading")
        owner.finishHistorySync(claim)
        XCTAssertFalse(owner.chatAvailability(for: conversationID).isHistoryLoading)
        owner.reset()
        XCTAssertTrue(state.conversationStore === owner)
        let retired = owner.chatAvailability(for: conversationID)
        XCTAssertFalse(retired.isHistoryLoading); XCTAssertFalse(retired.isApplyingFriend)
        XCTAssertNil(retired.historyMessage); XCTAssertNil(retired.directDisabledMessage); XCTAssertNil(retired.friendRequestContext)
        XCTAssertEqual(observations.last, retired); XCTAssertTrue(projectedHistory.isEmpty)
        for (name, url) in [("conversation-facade-actual-App", Bundle.main.executableURL),
                            ("conversation-facade-actual-XCTest", Bundle(for: DomainStoreTests.self).executableURL)] {
            let binary = try XCTUnwrap(url)
            let attachment = XCTAttachment(contentsOfFile: binary)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}

extension DomainStoreTests {
    func testGroupFilePreviewPolicyKeepsPreviewableFilesInsideTheApp() {
        var previewable = FileItem(
            id: "file-1",
            name: "image.png",
            type: "PNG",
            size: "1 KB",
            owner: "Member",
            source: "Group",
            time: "10:00",
            scope: "群文件",
            status: "可预览",
            accentHex: 0x5D6BFF
        )
        previewable.previewAvailable = true
        var unavailable = previewable
        unavailable.previewAvailable = false

        XCTAssertEqual(GroupFilePreviewPolicy.inAppDestination(for: previewable), previewable)
        XCTAssertNil(GroupFilePreviewPolicy.inAppDestination(for: unavailable))
    }

    func makeConversation(
        id: String,
        kind: ConversationKind = .direct,
        unread: Int,
        lastMsgSeq: Int64,
        lastReadSeq: Int64
    ) -> ConversationMessageSnapshot {
        ConversationMessageSnapshot(
            id: id,
            title: id,
            subtitle: "",
            kind: kind,
            lastMessage: "",
            time: "",
            unread: unread,
            isPinned: false,
            isMuted: false,
            memberCount: 0,
            accentHex: 0,
            participants: [],
            messages: [],
            hasUnreadReaction: true,
            unreadReactionCount: 2,
            lastMsgSeq: lastMsgSeq,
            lastReadSeq: lastReadSeq,
            firstUnreadSeq: 3,
            firstUnreadMessageID: "m3",
            unreadAnchorSeq: 3,
            unreadAnchorState: "unread"
        )
    }

    func makeMessage(
        id: String,
        senderId: String = "u1",
        seq: Int64,
        status: MessageDelivery = .sent,
        isOutgoing: Bool = false,
        isPinned: Bool = false,
        isDeletedLocally: Bool = false,
        text: String? = nil,
        time: String = "",
        kind: MessageKind = .text
    ) -> ChatMessage {
        var message = ChatMessage(
            id: id,
            senderId: senderId,
            senderName: "User",
            text: text ?? id,
            time: time,
            channelSeq: seq,
            isOutgoing: isOutgoing,
            status: status,
            kind: kind,
            reactions: [],
            readBy: [],
            unreadBy: [],
            isPinned: isPinned
        )
        message.isDeletedLocally = isDeletedLocally
        return message
    }

    func makeGroupInviteApproval(
        requestID: String,
        status: String = "pending",
        resultText: String = "",
        processed: Bool = false,
        approverName: String = "",
        approverAccountID: String = "",
        decidedAt: String = "",
        canApprove: Bool = true,
        canReject: Bool = true
    ) -> GroupInviteApproval {
        GroupInviteApproval(
            requestID: requestID,
            requestType: "invite",
            groupID: "group-1",
            groupName: "群聊",
            inviterName: "邀请人",
            inviterAccountID: "inviter-1",
            inviteeName: "被邀请人",
            inviteeAccountID: "invitee-1",
            status: status,
            resultText: resultText,
            processed: processed,
            approverName: approverName,
            approverAccountID: approverAccountID,
            decidedAt: decidedAt,
            canApprove: canApprove,
            canReject: canReject,
            approveEndpoint: "/approve",
            rejectEndpoint: "/reject",
            actionEndpoint: "/review",
            kind: "group_invite_approval"
        )
    }

    func decodeRemoteReceipt(_ json: String) throws -> RemoteMessageReceipt {
        try JSONDecoder().decode(RemoteMessageReceipt.self, from: Data(json.utf8))
    }

    func remoteMessageJSON(id: String, channelID: String, channelType: String, seq: Int64) -> String {
        """
        {
          "message_id": "\(id)",
          "channel_id": "\(channelID)",
          "channel_type": "\(channelType)",
          "channel_seq": \(seq),
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """
    }

    func decodeRemoteMessage(_ json: String) throws -> RemoteMessage {
        try JSONDecoder().decode(RemoteMessage.self, from: Data(json.utf8))
    }

    func decodeRemoteConversation(_ json: String) throws -> RemoteConversation {
        try JSONDecoder().decode(RemoteConversation.self, from: Data(json.utf8))
    }

    func decodeRemoteExtra(_ json: String) throws -> RemoteMessageExtra {
        try JSONDecoder().decode(RemoteMessageExtra.self, from: Data(json.utf8))
    }

    func decodeRemoteReadReceiptResponse(_ json: String) throws -> RemoteMessageReadReceiptResponse {
        try JSONDecoder().decode(RemoteMessageReadReceiptResponse.self, from: Data(json.utf8))
    }

    func makeReadReceipt(from receipt: RemoteMessageReceipt, conversation _: ConversationMessageSnapshot) -> ReadReceipt {
        ReadReceipt(
            id: "\(receipt.imUID)_\(receipt.deviceID)_\(receipt.channelSeq)",
            user: makeUser(id: receipt.imUID, name: receipt.displayName.isEmpty ? receipt.imUID : receipt.displayName),
            device: receipt.deviceID.isEmpty ? "设备未同步" : receipt.deviceID,
            time: receipt.createdAt ?? ""
        )
    }

    func makeReadReceipt(userID: String) -> ReadReceipt {
        ReadReceipt(
            id: userID,
            user: makeUser(id: userID),
            device: "ios",
            time: "10:00"
        )
    }

    func makeUnreadReadReceipt(from participant: RemoteMessageReadParticipant, conversation _: ConversationMessageSnapshot) -> ReadReceipt {
        ReadReceipt(
            id: "unread_\(participant.imUID)",
            user: makeUser(id: participant.imUID, name: participant.displayName.isEmpty ? participant.imUID : participant.displayName),
            device: participant.deviceID.isEmpty ? "未同步" : participant.deviceID,
            time: participant.readAt ?? "未读"
        )
    }

    func makeReactionDetail(from receipt: RemoteMessageReactionReceipt) -> ReactionDetail {
        ReactionDetail(
            id: "\(receipt.messageID)_\(receipt.operatorUID)_\(receipt.emoji)",
            emoji: receipt.emoji,
            user: makeUser(id: receipt.operatorUID, name: receipt.operatorName.isEmpty ? receipt.operatorUID : receipt.operatorName),
            time: receipt.createdAt ?? ""
        )
    }

    func makeReactionDetail(from extra: RemoteMessageExtra, id: String) -> ReactionDetail {
        ReactionDetail(
            id: id,
            emoji: extra.emoji,
            user: makeUser(id: extra.operatorUID, name: extra.operatorName.isEmpty ? extra.operatorUID : extra.operatorName),
            time: extra.createdAt ?? ""
        )
    }

    func makeUser(
        id: String,
        name: String? = nil,
        userID: String = "",
        username: String = "",
        status: String = "在线",
        avatarURL: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = ""
    ) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            username: username,
            name: name ?? id,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: status,
            enterprise: "",
            avatarSeed: 0,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            badges: []
        )
    }

    func makeIsolatedAPIContext() -> IMAPIContext {
        IMAPIContext(
            platformToken: nil,
            accountID: nil,
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
    }

    func videoCallRuntimeRouteSnapshot() throws -> IMRuntimeRouteSnapshot {
        let services: [String: IMRuntimeRouteEndpointSet] = [
            IMRuntimeRouteService.platformAPI.rawValue: .init(
                preferred: ["https://platform-primary.example.test"],
                backups: ["https://platform-backup.example.test"],
                preferredSource: "app_preferred",
                backupSource: "common_platform_backup"
            ),
            IMRuntimeRouteService.tenantAPI.rawValue: .init(
                preferred: ["https://tenant-primary.example.test"],
                backups: ["https://tenant-backup.example.test"],
                preferredSource: "tenant_deployment_authority",
                backupSource: "tenant_deployment_backup"
            ),
            IMRuntimeRouteService.imAPI.rawValue: .init(
                preferred: ["https://im-primary.example.test"],
                backups: ["https://im-backup.example.test"],
                preferredSource: "tenant_deployment_authority",
                backupSource: "tenant_deployment_backup"
            ),
            IMRuntimeRouteService.imRealtime.rawValue: .init(
                preferred: ["wss://realtime-primary.example.test"],
                backups: ["wss://realtime-backup.example.test"],
                preferredSource: "tenant_deployment_authority",
                backupSource: "tenant_deployment_backup"
            )
        ]
        let unsigned = IMRuntimeRouteSnapshot(
            contractVersion: 2,
            appID: IMAPIContext.canonicalIOSAppID,
            tenantID: "tenant-1",
            revision: 1,
            source: "tenant_entry",
            status: "ready",
            configHash: String(repeating: "0", count: 64),
            services: services,
            policy: IMRuntimeRoutePolicy()
        )
        return IMRuntimeRouteSnapshot(
            contractVersion: unsigned.contractVersion,
            appID: unsigned.appID,
            tenantID: unsigned.tenantID,
            revision: unsigned.revision,
            source: unsigned.source,
            status: unsigned.status,
            configHash: try XCTUnwrap(unsigned.recomputedConfigHash),
            services: services,
            policy: unsigned.policy
        )
    }

    func makeAuthenticatedAPIContext(
        accountID: String = "account-1",
        imUID: String = "uid-1"
    ) -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: accountID,
            tenantID: "tenant-1",
            imUID: imUID,
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
    }

    func successfulEmptyAPIResponse() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func makeCallEndingAPI(transport: HTTPTransport) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            httpTransport: transport
        )
    }

    func makeRTCMediaHeartbeatState(
        transport: HTTPTransport,
        now: @escaping @MainActor () -> Date = Date.init
    ) -> AppState {
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: NoopVideoMediaClient(),
            rtcMediaHeartbeatIntervalNanoseconds: 3_600_000_000_000,
            rtcMediaHeartbeatNow: now,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        return state
    }

    func makeRTCMediaHeartbeatVideoCall(callID: String) -> VoiceCallSession {
        VoiceCallSession(
            id: "local-\(callID)",
            callID: callID,
            roomID: "room-\(callID)",
            rtcToken: "rtc-token-\(callID)",
            peer: makeUser(id: "peer-\(callID)", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "连接中",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true,
            stateVersion: 1
        )
    }

    func rtcMediaHeartbeatJoinedRoom(token: String) -> RemoteRTCRoomJoinData {
        RemoteRTCRoomJoinData(
            roomID: "room-heartbeat",
            rtcToken: token,
            selfParticipant: RemoteRTCRoomParticipant(
                uid: "uid-1",
                deviceID: "ios-device-1",
                deviceType: "ios",
                role: "self"
            ),
            participants: []
        )
    }

    func rtcMediaHeartbeatCallResult(callID: String, stateVersion: Int64) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(
                """
                {"ok":true,"data":{"call":{
                  "id":"\(callID)",
                  "status":"accepted",
                  "state_version":\(stateVersion)
                }}}
                """.utf8
            ),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func rtcMediaHeartbeatErrorResult(statusCode: Int, code: String) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(
                #"{"ok":false,"error":{"code":"\#(code)","message":"rtc heartbeat failed"}}"#.utf8
            ),
            isHTTPResponse: true,
            statusCode: statusCode
        )
    }

    func waitForRTCMediaHeartbeatRequests(
        _ count: Int,
        transport: RTCMediaHeartbeatHTTPTransport
    ) async {
        for _ in 0..<200 {
            if transport.requests().count >= count {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func waitForCallEnd(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitForRequestCount(
        _ count: Int,
        path: String,
        transport: RTCDeviceCapabilityBootstrapHTTPTransport
    ) async {
        for _ in 0..<100 {
            if transport.requestCount(path: path) >= count {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func videoCallEnabledFileConfig() -> FileUploadConfig {
        callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
    }

    func callLicenseFileConfig(
        voiceEnabled: Bool,
        videoEnabled: Bool
    ) -> FileUploadConfig {
        FileUploadConfig(
            maxBytes: 20 * 1024 * 1024,
            maxMB: 20,
            source: "test",
            messageRecallMaxMinutes: 120,
            voiceCallEnabled: voiceEnabled,
            videoCallEnabled: videoEnabled,
            readReceiptsEnabled: true,
            groupAdminDeleteMessageEnabled: false
        )
    }

    func makeSearchJumpAPI(transport: HTTPTransport) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
    }
}

// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// Standalone Store tests explicitly establish all five fields. Production Stores
// stay empty until AppState binds an authenticated LocalMessageScope.
enum TestMessageMemoryScope {
    // A complete local five-tuple, with no token or authenticated-network grant.
    static let context = IMAPIContext(
        platformToken: nil, accountID: "memory-test-account", tenantID: "memory-test-tenant",
        imUID: "memory-test-actor", imToken: nil, platformAuthSession: nil, tenantAuthSession: nil,
        appID: "memory-test-app", deviceID: "memory-test-device"
    )
    static let value = try! LocalMessageScope(
        accountID: "memory-test-account", tenantID: "memory-test-tenant",
        appID: "memory-test-app", actorID: "memory-test-actor", deviceID: "memory-test-device"
    )
}

struct CapturedConversationMemorySnapshot {
    let revision: UInt64
    let conversations: [ConversationMessageSnapshot]
    let alertingUnreadTotal: Int
}

extension ConversationStore.MemorySnapshot {
    @MainActor
    func captureMessages(from store: ConversationStore) -> CapturedConversationMemorySnapshot {
        precondition(revision == store.messageMemoryStore.revision)
        return CapturedConversationMemorySnapshot(
            revision: revision, conversations: store.conversationMessageSnapshots(),
            alertingUnreadTotal: alertingUnreadTotal
        )
    }
}
// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
extension ConversationStore {
    @MainActor
    func mutateMessageSnapshotsForTesting(_ change: (inout [ConversationMessageSnapshot]) -> Void) {
        performMemoryCommand {
            var values = conversationMessageSnapshots()
            change(&values)
            commitConversationSnapshots(values)
        }
    }
}
// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_BEGIN
extension DomainStoreTests {
    @MainActor
    func testPhysicalLoginLogFamilyUsesOneOriginalAppOwnerAndDomainValue() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store: IM4Stores.LoginLogStore = state.loginLogStore
        let value: IM4Domain.LoginLog = LoginLog(id: "physical-log", device: "iOS", location: "当前账号", time: "刚刚", result: "成功")
        store.logs = [value]
        store.isLoading = true
        store.loadFailed = true
        XCTAssertEqual(state.loginLogs, [value])
        XCTAssertTrue(state.isLoginLogsLoading)
        XCTAssertTrue(state.loginLogsLoadFailed)

        state.resetAuthenticatedRemoteData(showLoading: false)
        XCTAssertTrue(store === state.loginLogStore)
        XCTAssertTrue(state.loginLogs.isEmpty)
        XCTAssertFalse(state.isLoginLogsLoading)
        XCTAssertFalse(state.loginLogsLoadFailed)
        for (label, url) in [("login-log-actual-App", Bundle.main.executableURL),
                             ("login-log-actual-XCTest", Bundle(for: DomainStoreTests.self).executableURL)] {
            let executable = try XCTUnwrap(url)
            let attachment = XCTAttachment(contentsOfFile: executable)
            attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
            let path = XCTAttachment(string: executable.path)
            path.name = label + "-path"; path.lifetime = .keepAlways; add(path)
        }
    }
}
// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_END
// Direct delegate invocation leaves UIKit's real gesture flags false. Keep
// delivering real movement callbacks during the original test wait budget.
@MainActor
func simulateConversationListScrollMovement(_ table: UITableView, intervals: Int) async throws {
    for _ in 0..<intervals {
        table.delegate?.scrollViewDidScroll?(table)
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
// WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_BEGIN
extension DomainStoreTests {
    @MainActor
    func testCompleteGroupModerationRetirementKeepsSequenceAndRetiresAllRuntimeOwners() async {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store: IM4Stores.GroupModerationStore = state.groupModerationStore
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        let key = state.groupMuteScopeKey(groupID: "owned-group", context: state.apiContext)
        let token = store.beginMuteMutation(scopeKey: key)
        store.recordMuteRealtimeGeneration(12, scopeKey: key)
        let idempotency = store.ownerTransferIdempotencyKey(scope: scope, groupID: "owned-group", targetUID: "peer")
        XCTAssertEqual(store.ownerTransferIdempotencyKey(scope: scope, groupID: "owned-group", targetUID: "peer"), idempotency)
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        defer { task.cancel() }
        store.installMuteBoundaryRefreshTask(task, scopeKey: key)
        store.setSettingsMutation(groupID: "owned-group", isMutating: true, errorMessage: "old")
        _ = store.beginListLoad(groupID: "owned-group")
        _ = store.beginAdministration(.ownerTransfer, groupID: "owned-group")

        state.resetAuthenticatedRemoteData(showLoading: false)
        XCTAssertTrue(store === state.groupModerationStore)
        XCTAssertTrue(task.isCancelled)
        task.cancel() // Cleanup only after observing the real retirement result; never wait 30s on a failure.
        await task.value
        XCTAssertFalse(store.ownsMuteMutation(token, scopeKey: key))
        XCTAssertEqual(store.muteRealtimeGeneration(scopeKey: key), 0)
        XCTAssertNotEqual(store.ownerTransferIdempotencyKey(scope: scope, groupID: "owned-group", targetUID: "peer"), idempotency)
        XCTAssertFalse(store.settingsSnapshot(for: "owned-group").isMutating)
        XCTAssertNil(store.settingsSnapshot(for: "owned-group").errorMessage)
        XCTAssertFalse(store.listSnapshot(for: "owned-group").isLoading)
        XCTAssertFalse(store.isTransferringOwner(groupID: "owned-group"))
        let replacement = store.beginMuteMutation(scopeKey: key)
        XCTAssertGreaterThan(replacement, token, "The original auth reset never reset the monotonic sequence")
        XCTAssertFalse(store.ownsMuteMutation(token, scopeKey: key))
        XCTAssertTrue(store.ownsMuteMutation(replacement, scopeKey: key))
    }
}
// WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_END

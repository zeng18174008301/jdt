@testable import IM4Features
// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_BEGIN
import XCTest
import SwiftUI
import UIKit
import CryptoKit
@testable import WenDaTong

// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
extension HTTPTransportTests {
    @MainActor
    func testActualParentBindingKeepsResourceCleanupThroughRenewalAndRejectsRetiredScope() async throws {
        // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
        // Each independent fixture owns a real matching synthetic device/session namespace.
        var original = makeRefreshableMessageSendContext()
        original.deviceID = "m13-parent-" + UUID().uuidString
        let storedSession = try XCTUnwrap(original.tenantAuthSession)
        original.tenantAuthSession = IMStoredAuthSession(sessionID: storedSession.sessionID,
            refreshToken: storedSession.refreshToken, refreshExpiresAt: storedSession.refreshExpiresAt,
            tokenType: storedSession.tokenType, tenantID: storedSession.tenantID, accountID: storedSession.accountID,
            appID: storedSession.appID, deviceID: original.deviceID, clientType: storedSession.clientType,
            authVersion: storedSession.authVersion, sessionGeneration: storedSession.sessionGeneration,
            accessExpiresAt: storedSession.accessExpiresAt, lifetimeMode: storedSession.lifetimeMode)
        let template = try sessionReauthenticationLoginResult()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: template.data) as? [String: Any])
        var payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        var platformSession = try XCTUnwrap(payload["auth_session"] as? [String: Any])
        var tenant = try XCTUnwrap(payload["session"] as? [String: Any])
        var tenantSession = try XCTUnwrap(tenant["auth_session"] as? [String: Any])
        platformSession["device_id"] = original.deviceID; tenant["device_id"] = original.deviceID; tenantSession["device_id"] = original.deviceID
        tenant["auth_session"] = tenantSession; payload["session"] = tenant; payload["auth_session"] = platformSession; envelope["data"] = payload
        let login = HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: envelope), isHTTPResponse: template.isHTTPResponse, statusCode: template.statusCode)
        let transport = RememberedLoginGateHTTPTransport(loginResult: login)
        transport.releaseLoginResponse()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parent-assembly-\(UUID())")
        let store = InMemoryProtectedSessionStore()
        // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
        XCTAssertTrue(original.save(sessionStore: store).isCommitted)
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"))
        let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            realtimeClient: PostLoginSilentRealtimeTransport(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: persistence, protectedSessionStore: store, apiContextOverride: original)
        state.setAuthenticated(true); state.beginSessionReauthentication()
        let conversationID = "uid-1:uid-2"
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let imageBytes = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).pngData { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let suffix = UUID().uuidString
        let voice = assemblyMessage("assembly-\(suffix)-voice", kind: .voice)
        let file = assemblyMessage("assembly-\(suffix)-file", kind: .file)
        var image = assemblyMessage("assembly-\(suffix)-image", kind: .image)
        image.attachmentMimeType = "image/png"; image.attachmentMediaCategory = "image"
        image.attachmentChecksum = SHA256.hash(data: imageBytes).map { String(format: "%02x", Int($0)) }.joined()
        image.attachmentSizeBytes = Int64(imageBytes.count)
        let messages = [voice, file, image]
        var conversation = makeDirectConversation(id: conversationID); conversation.messages = messages
        state.conversationStore.commitConversationSnapshots([conversation])
        let rows = messages.enumerated().map { MessageRowModel(index: $0.offset, message: $0.element,
            showsSenderHeader: false, senderUser: nil, displaySenderName: "Peer", timeSeparatorText: nil) }
        var parents: [String: ChatBubbleAssemblyProbe] = [:]
        var voiceProbe: ChatVoiceAssemblyProbe?; var fileProbe: ChatFileAttachmentProbe?; var imageProbe: ChatOriginalThumbnailProbe?
        var menus: [String] = []
        ChatBubbleAssemblyDiagnostics.capture = { parents[$0.messageID] = $0 }
        ChatMediaAssemblyDiagnostics.voice = { if $0.messageID == voice.id { voiceProbe = $0 } }
        ChatAttachmentAssemblyDiagnostics.file = { if $0.messageID == file.id { fileProbe = $0 } }
        ChatAttachmentAssemblyDiagnostics.original = { if $0.messageID == image.id { imageProbe = $0 } }
        defer { ChatBubbleAssemblyDiagnostics.capture = nil; ChatMediaAssemblyDiagnostics.voice = nil
            ChatAttachmentAssemblyDiagnostics.file = nil; ChatAttachmentAssemblyDiagnostics.original = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let host = UIHostingController(rootView: VStack {
            ForEach(rows, id: \.message.id) { row in
                ChatTimelineRow(row: row, conversationID: conversationID, isGroupConversation: false,
                    onLongPress: { menus.append(row.message.id) }, onReadTap: {})
            }
        }.appStateEnvironment(state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; state.fileStore.cancelAttachmentDownloadTasks(); state.stopVoiceMessagePlayback() }
        let hostID = ObjectIdentifier(host); let viewID = ObjectIdentifier(host.view)
        try await Task.sleep(nanoseconds: 200_000_000)
        let initialParents = parents
        let retainedVoice = try XCTUnwrap(voiceProbe); let retainedFile = try XCTUnwrap(fileProbe)
        let retainedImage = try XCTUnwrap(imageProbe)
        var rotated = state.apiContext; rotated.imToken = "synthetic-parent-normal-token"; state.apiContext = rotated
        try await Task.sleep(nanoseconds: 100_000_000)
        for message in messages { XCTAssertEqual(parents[message.id]?.presentation.actionIdentity, initialParents[message.id]?.presentation.actionIdentity) }
        let succeeded = await state.reauthenticateCurrentSession(identifier: "member1", password: "SyntheticPass123!", enterpriseCode: "")
        XCTAssertTrue(succeeded)
        for _ in 0..<50 {
            if messages.allSatisfy({ parents[$0.id]?.presentation.actionIdentity.sessionEpoch == state.apiContext.sessionEpoch }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for message in messages {
            XCTAssertEqual(parents[message.id]?.presentation.actionIdentity.sessionEpoch, state.apiContext.sessionEpoch)
            XCTAssertEqual(parents[message.id]?.presentation.actionIdentity.bindingGeneration, initialParents[message.id]?.presentation.actionIdentity.bindingGeneration)
        }
        try XCTUnwrap(initialParents[file.id]).onLongPress(); XCTAssertTrue(menus.isEmpty)
        try XCTUnwrap(parents[file.id]).onLongPress(); XCTAssertEqual(menus, [file.id])
        let normalTask = assemblyDownload(); defer { normalTask.cancel() }
        let fileKey = state.attachmentProgressKey(for: file)
        state.fileStore.replaceAttachmentDownloadTask(attachmentID: fileKey, with: normalTask)
        retainedFile.onCancelDownload(); XCTAssertTrue(normalTask.isCancelled)
        state.voiceMessagePlayerMessageID = voice.id; state.voiceMessagePlaybackStore.playingMessageID = voice.id
        state.voiceMessagePlaybackStore.state = .init(messageID: voice.id, elapsedMS: 100, durationMS: 1_000, isPlaying: true)
        retainedVoice.onDisappear(); XCTAssertNil(state.voiceMessagePlaybackStore.playingMessageID)
        let normalURL = try await assemblyCommitImage(state: state, message: image, bytes: imageBytes, conversationID: conversationID)
        defer { try? FileManager.default.removeItem(at: normalURL) }
        let retainedHit = await retainedImage.indexedCacheURL(); XCTAssertEqual(retainedHit, normalURL)
        let beforeRetirementVoice = try XCTUnwrap(voiceProbe); let beforeRetirementFile = try XCTUnwrap(fileProbe)
        let beforeRetirementImage = try XCTUnwrap(imageProbe)
        let beforeRetirementParents = parents
        var other = state.apiContext; other.tenantID = "retired-parent-other-tenant"; state.apiContext = other
        try await Task.sleep(nanoseconds: 200_000_000)
        let retiredTask = assemblyDownload(); defer { retiredTask.cancel() }
        let newKey = state.attachmentProgressKey(for: file)
        state.fileStore.replaceAttachmentDownloadTask(attachmentID: newKey, with: retiredTask)
        state.voiceMessagePlayerMessageID = voice.id; state.voiceMessagePlaybackStore.playingMessageID = voice.id
        state.voiceMessagePlaybackStore.state = .init(messageID: voice.id, elapsedMS: 200, durationMS: 1_000, isPlaying: true)
        beforeRetirementFile.onCancelDownload(); beforeRetirementVoice.onDisappear()
        XCTAssertFalse(retiredTask.isCancelled); XCTAssertTrue(state.fileStore.hasAttachmentDownloadTask(attachmentID: newKey))
        XCTAssertEqual(state.voiceMessagePlaybackStore.playingMessageID, voice.id)
        let oldImageHit = await beforeRetirementImage.indexedCacheURL(); XCTAssertNil(oldImageHit)
        let currentURL = try await assemblyCommitImage(state: state, message: image, bytes: imageBytes, conversationID: conversationID)
        defer { try? FileManager.default.removeItem(at: currentURL) }
        let currentImage = try XCTUnwrap(imageProbe)
        let newImageHit = await currentImage.indexedCacheURL(); XCTAssertEqual(newImageHit, currentURL)
        XCTAssertNotEqual(currentURL, normalURL)
        for message in messages { XCTAssertNotEqual(parents[message.id]?.presentation.actionIdentity.bindingGeneration,
            beforeRetirementParents[message.id]?.presentation.actionIdentity.bindingGeneration) }
        try XCTUnwrap(fileProbe).onCancelDownload(); XCTAssertTrue(retiredTask.isCancelled)
        try XCTUnwrap(voiceProbe).onDisappear(); XCTAssertNil(state.voiceMessagePlaybackStore.playingMessageID)
        XCTAssertEqual(ObjectIdentifier(host), hostID); XCTAssertEqual(ObjectIdentifier(host.view), viewID)
        XCTAssertEqual(rows.map(\.message), messages)
    }

    private func assemblyMessage(_ id: String, kind: MessageKind) -> ChatMessage {
        var message = ChatMessage(id: id, senderId: "uid-2", senderName: "Peer", text: "attachment", time: "",
            isOutgoing: false, status: .sent, kind: kind, reactions: [], readBy: [], unreadBy: [], isPinned: false)
        message.attachmentFileID = id + "-file"; message.attachmentVersion = "v1"
        message.attachmentName = "attachment.pdf"; message.attachmentMimeType = "application/pdf"; message.attachmentMediaCategory = "pdf"
        return message
    }
    private func assemblyDownload() -> Task<URL, Error> {
        Task { try await Task.sleep(nanoseconds: 30_000_000_000); return URL(fileURLWithPath: "/unused") }
    }
    @MainActor private func assemblyCommitImage(state: AppState, message: ChatMessage, bytes: Data, conversationID: String) async throws -> URL {
        let context = try XCTUnwrap(state.mediaCacheScopeContext)
        let staged = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(bytes)
        defer { try? FileManager.default.removeItem(at: staged) }
        return try await state.commitIndexedMediaCache(temporaryURL: staged,
            metadata: state.unifiedAttachmentMetadata(for: message, context: context), resourceKind: .original,
            integrity: MediaFileIntegrityAuthority(expectedSizeBytes: Int64(bytes.count), expectedSHA256: message.attachmentChecksum),
            messageID: message.id, conversationID: conversationID, context: context)
    }
}
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END

// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_END

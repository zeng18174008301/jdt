import XCTest; import IM4DesignSystem
import SwiftUI
import UIKit
import AVKit
import QuickLook
import Photos
import CryptoKit
@testable import IM4Domain // WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110
@testable import IM4Features // WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110
import IM4Stores // WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
@testable import WenDaTong

// WDT_IOS1_CHAT_GIF_ENTRY_MOUNT_20261111_BEGIN
@MainActor func attachmentBoundaryHost(_ content: AnyView, size: CGSize = CGSize(width: 390, height: 760)) throws -> HostedSimulatorUI<AnyView> {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let controller = UIHostingController(rootView: content)
    let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = controller; window.makeKeyAndVisible()
    controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
    return HostedSimulatorUI(window: window, controller: controller)
}
@MainActor func attachmentBoundaryWait(_ label: String = "unspecified", _ predicate: () -> Bool) async throws {
    for _ in 0..<160 { if predicate() { return }; try await Task.sleep(nanoseconds: 25_000_000) }
    XCTAssertTrue(predicate(), "Actual attachment presentation did not reach expected state: \(label)")
}
// WDT_IOS1_CHAT_GIF_ENTRY_MOUNT_20261111_END
@MainActor private func attachmentBoundaryDrainMain() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}
@MainActor func attachmentBoundaryRetire(_ hosted: HostedSimulatorUI<AnyView>) { // WDT_IOS1_CHAT_GIF_ENTRY_MOUNT_20261111
    hosted.controller.view.endEditing(true); hosted.controller.rootView = AnyView(EmptyView())
    hosted.controller.view.layoutIfNeeded(); hosted.window.isHidden = true; hosted.window.rootViewController = nil
}
@MainActor private func attachmentBoundaryControllers<T: UIViewController>(_ root: UIViewController, of type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? [] + root.children.flatMap { attachmentBoundaryControllers($0, of: type) }
}

struct AttachmentBoundaryModalHarness: View { // WDT_IOS1_CHAT_GIF_ENTRY_MOUNT_20261111
    @State private var item: AttachmentMediaPreviewItem?
    let onReturn: () -> Void
    init(message: ChatMessage, localURL: URL, onReturn: @escaping () -> Void) {
        _item = State(initialValue: AttachmentMediaPreviewItem(message: message, localURL: localURL))
        self.onReturn = onReturn
    }
    var body: some View {
        Text("Attachment return target")
            .fullScreenCover(item: $item, onDismiss: onReturn) { item in
                AttachmentImagePreviewSheet(message: item.message, conversationID: "detail-chat", localURL: item.localURL)
            }
    }
}

extension AttachmentDownloadTests {
    @MainActor
    private func detailBoundaryState(_ context: IMAPIContext, transport: any HTTPTransport, biometricAuthenticator: any LocalBiometricAuthenticating = RecordingBiometricAuthenticator()) throws -> AppState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-detail-boundary-\(UUID())")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "attachment-detail-boundary-\(UUID())"))
        return AppState(api: IMAPIClient(platformBase: URL(string: "https://platform.example.test")!, tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!, httpTransport: transport, runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)),
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            biometricAuthenticator: biometricAuthenticator, biometricDefaults: defaults, rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
    }
    private func detailBoundaryMessage(_ id: String, category: String = "pdf") -> ChatMessage {
        var message = ChatMessage(id: id, senderId: "uid-2", senderName: "Peer", text: "report.pdf", time: "",
            isOutgoing: false, status: .sent, kind: category == "image" ? .image : .file, reactions: [], readBy: [], unreadBy: [], isPinned: false)
        message.attachmentName = "report.pdf"; message.attachmentFileID = id + "-file"
        message.attachmentMimeType = "application/pdf"; message.attachmentMediaCategory = category
        message.attachmentSizeBytes = 1_000; message.attachmentVersion = "v1"
        return message
    }
    @MainActor private func detailBoundaryConversation(_ state: AppState, messages: [ChatMessage]) {
        state.conversationStore.commitConversationSnapshots([ConversationMessageSnapshot(id: "detail-chat", title: "Detail", subtitle: "", kind: .direct,
            lastMessage: "", time: "", unread: 0, isPinned: false, isMuted: false, memberCount: nil, accentHex: 0, participants: [], messages: messages)])
        var snapshot = state.tenantInteractionStore.snapshot
        snapshot.policyScope = snapshot.activeScope ?? ""; snapshot.actions.forwardEnabled = true
        state.tenantInteractionStore.snapshot = snapshot
    }
    private func detailBoundaryDownload() -> Task<URL, Error> {
        Task { try await Task.sleep(nanoseconds: 30_000_000_000); return URL(fileURLWithPath: "/unused-detail-download") }
    }

    @MainActor
    func testDetailBoundaryUsesMatchingStoreProgressAndRetiresOldScopeActionsWithoutRemount() async throws {
        let context = attachmentContext(tenantID: "detail-progress-\(UUID())")
        let state = try detailBoundaryState(context, transport: FakeAttachmentHTTPTransport(results: []))
        let a = detailBoundaryMessage("detail-a"), b = detailBoundaryMessage("detail-b")
        detailBoundaryConversation(state, messages: [a, b])
        var probes: [String: AttachmentDetailProbe] = [:], counts: [String: Int] = [:]
        var forwarded: [String] = [], updates: [String] = []
        defer { let a = XCTAttachment(string: updates.joined(separator: "\n")); a.name = "detail-progress-scope-trace"; a.lifetime = .keepAlways; add(a) }
        ChatAttachmentDetailDiagnostics.detail = {
            probes[$0.input.messageID] = $0; counts[$0.input.messageID, default: 0] += 1
            updates.append("probe=\($0.input.messageID) bytes=\(String(describing: $0.input.download?.receivedBytes)) committing=\(String(describing: $0.input.download?.isCommitting)) identity=\($0.identity) live=\(String(describing: state.attachmentDownloadSnapshot(for: a)?.receivedBytes))")
        }
        let hosted = try attachmentBoundaryHost(AnyView(HStack {
            AttachmentDetailSheet(message: a, conversationID: "detail-chat", onForward: { forwarded.append($0.id) })
            AttachmentDetailSheet(message: b, conversationID: "detail-chat")
        }.appStateEnvironment(state)), size: CGSize(width: 780, height: 760))
        defer { attachmentBoundaryRetire(hosted); state.fileStore.cancelAttachmentDownloadTasks(); ChatAttachmentDetailDiagnostics.detail = nil }
        try await attachmentBoundaryWait("initial") { probes[a.id] != nil && probes[b.id] != nil }
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        let initial = try XCTUnwrap(probes[a.id]); XCTAssertEqual(initial.input.fileName, "report.pdf")
        XCTAssertEqual(initial.input.mediaCategory, "pdf"); XCTAssertEqual(initial.input.detailTitle, "PDF 详情")
        let token = UUID(), task = detailBoundaryDownload(); defer { task.cancel() }
        let key = state.attachmentProgressKey(for: a)
        let bCount = counts[b.id]
        state.fileStore.replaceAttachmentDownloadTask(attachmentID: key, with: task, token: token)
        state.fileStore.setAttachmentDownloadSnapshot(.init(receivedBytes: 250, totalBytes: 1_000), attachmentID: key, token: token)
        try await attachmentBoundaryWait("bytes250") { probes[a.id]?.input.download?.receivedBytes == 250 }
        XCTAssertEqual(counts[b.id], bCount)
        let old = try XCTUnwrap(probes[a.id]); XCTAssertEqual(old.input.download?.fraction, 0.25)
        state.fileStore.setAttachmentDownloadSnapshot(.init(receivedBytes: 1_000, totalBytes: 1_000, isCommitting: true), attachmentID: key, token: token)
        try await attachmentBoundaryWait("committing") { probes[a.id]?.input.download?.isCommitting == true }
        XCTAssertNil(probes[a.id]?.input.download?.fraction); XCTAssertEqual(probes[a.id]?.input.download?.label, "校验/保存中")
        try XCTUnwrap(probes[a.id]).actions.cancelDownload()
        XCTAssertTrue(task.isCancelled); XCTAssertNil(state.attachmentDownloadSnapshot(for: a))
        var next = context; next.tenantID = "retired-\(context.tenantID ?? "")"
        state.apiContext = next; state.apiContext = context
        detailBoundaryConversation(state, messages: [a, b])
        let replacement = detailBoundaryDownload(), replacementToken = UUID(); defer { replacement.cancel() }
        let currentKey = state.attachmentProgressKey(for: a)
        state.fileStore.replaceAttachmentDownloadTask(attachmentID: currentKey, with: replacement, token: replacementToken)
        state.fileStore.setAttachmentDownloadSnapshot(.init(receivedBytes: 600, totalBytes: 1_000), attachmentID: currentKey, token: replacementToken)
        updates.append("after-install600 live=\(String(describing: state.attachmentDownloadSnapshot(for: a))) task=\(state.fileStore.hasAttachmentDownloadTask(attachmentID: currentKey)) key=\(currentKey)")
        try await attachmentBoundaryWait("new-scope600") { probes[a.id]?.input.download?.receivedBytes == 600 }
        old.actions.cancelDownload(); old.actions.forward()
        XCTAssertFalse(replacement.isCancelled); XCTAssertTrue(forwarded.isEmpty)
        let current = try XCTUnwrap(probes[a.id]); current.actions.forward()
        XCTAssertEqual(forwarded, [a.id]); current.actions.cancelDownload(); XCTAssertTrue(replacement.isCancelled)
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID); XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
    }

    @MainActor
    func testDetailBoundaryRetiredBeforeTaskStartsNeverRequestsPermissionOrDownload() async throws {
        for (retirement, command) in [("scope", "detail-share"), ("epoch", "detail-system-preview"), ("localgen", "detail-video-preview"), ("localgen", "image-save")] {
            let recorder = RecordingBiometricAuthenticator(), transport = FakeAttachmentHTTPTransport(results: [])
            let state = try detailBoundaryState(attachmentContext(tenantID: "detail-delayed-\(UUID())"), transport: transport, biometricAuthenticator: recorder)
            var settings = state.biometricProtectionSettings; settings.enabled = true; settings.previewFiles = true
            state.biometricAccessStore.replaceSettings(settings)
            var message = detailBoundaryMessage("delayed-\(command)", category: command == "detail-video-preview" ? "video" : "pdf")
            message.attachmentDownloadURL = "https://files.example.test/delayed.pdf"; message.attachmentDownloadAvailable = true
            message.attachmentPreviewURL = "https://files.example.test/preview.pdf"; message.attachmentPreviewAvailable = true
            if command == "detail-video-preview" { message.attachmentName = "movie.mov"; message.attachmentMimeType = "video/quicktime" }
            var probe: AttachmentDetailProbe?, imageProbe: AttachmentImagePreviewProbe?, entries: [(String, Bool)] = []
            ChatAttachmentDetailDiagnostics.detail = { probe = $0 }; ChatAttachmentDetailDiagnostics.image = { imageProbe = $0 }
            ChatAttachmentDetailDiagnostics.taskEntry = { entries.append(($0, $1)) }
            let localImage = FileManager.default.temporaryDirectory.appendingPathComponent("delayed-image-\(UUID()).png")
            let pixels = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { c in UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
            try pixels.write(to: localImage)
            let content = command == "image-save"
                ? AnyView(AttachmentImagePreviewSheet(message: message, conversationID: "detail-chat", localURL: localImage).appStateEnvironment(state))
                : AnyView(AttachmentDetailSheet(message: message, conversationID: "detail-chat").appStateEnvironment(state))
            let hosted = try attachmentBoundaryHost(content)
            defer { attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.detail = nil; ChatAttachmentDetailDiagnostics.image = nil; ChatAttachmentDetailDiagnostics.taskEntry = nil; state.fileStore.cancelAttachmentDownloadTasks() }
            try await attachmentBoundaryWait { command == "image-save" ? imageProbe != nil : probe != nil }
            let identity = state.chatBubbleSessionIdentity, hostID = ObjectIdentifier(hosted.controller)
            let photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if command == "image-save" { try XCTUnwrap(imageProbe).actions.save() }
            else if command == "detail-share" { try XCTUnwrap(probe).actions.share() }
            else { try XCTUnwrap(probe).actions.openPreview() }
            if retirement == "scope" { var context = state.apiContext; context.tenantID = "retired-before-start"; state.apiContext = context }
            else if retirement == "epoch" { var context = state.apiContext; context.sessionEpoch = UUID().uuidString; state.apiContext = context }
            else { state.localMessageSessionGeneration &+= 1 }
            state.biometricAccessStore.replaceSettings(settings)
            XCTAssertTrue(state.requiresFileBiometricProtection); XCTAssertNotEqual(state.chatBubbleSessionIdentity, identity)
            try await attachmentBoundaryWait("retired-before-Task-\(command)") { !entries.isEmpty }
            XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first?.0, command); XCTAssertEqual(entries.first?.1, false)
            try await attachmentBoundaryWait { command == "image-save" ? imageProbe?.identity == state.chatBubbleSessionIdentity : probe?.identity == state.chatBubbleSessionIdentity && probe?.input.isPreparingShare == false && probe?.input.isPreparingPreview == false }
            XCTAssertEqual(recorder.requestCount, 0); XCTAssertTrue(transport.requests().isEmpty)
            XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .addOnly), photoStatus)
            XCTAssertNil(probe?.preparedShareURL); XCTAssertNil(hosted.controller.presentedViewController)
            XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID)
            let trace = XCTAttachment(string: "command=\(command); retirement=\(retirement); original callback called while current; actual Task entered and original F4 predicate=false; permission requests=\(recorder.requestCount); HTTP requests=\(transport.requests().count); photo authorization unchanged; no prepared presentation")
            trace.name = "attachment-delayed-entry-\(command)"; trace.lifetime = .keepAlways; add(trace)
        }
    }

    @MainActor
    func testImagePreviewCurrentDismissReturnsFromOriginalModalWithoutRemount() async throws {
        let state = try detailBoundaryState(attachmentContext(tenantID: "detail-modal-\(UUID())"), transport: FakeAttachmentHTTPTransport(results: []))
        let message = detailBoundaryMessage("modal-image", category: "image")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("detail-modal-\(UUID()).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { c in UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        try XCTUnwrap(image.pngData()).write(to: url); AvatarImageCache.shared.storePrepared(image, for: url.absoluteString)
        var probe: AttachmentImagePreviewProbe?, returns = 0
        ChatAttachmentDetailDiagnostics.image = { probe = $0 }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentBoundaryModalHarness(message: message, localURL: url, onReturn: { returns += 1 }).appStateEnvironment(state)))
        defer { attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.image = nil }
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        try await attachmentBoundaryWait("actual original fullScreenCover") { probe != nil && hosted.controller.presentedViewController != nil }
        let old = try XCTUnwrap(probe)
        var context = state.apiContext; context.sessionEpoch = UUID().uuidString; state.apiContext = context
        try await attachmentBoundaryWait { probe?.identity == state.chatBubbleSessionIdentity }
        XCTAssertNotEqual(old.identity, probe?.identity)
        let current = try XCTUnwrap(probe); current.actions.dismiss(); current.actions.dismiss()
        try await attachmentBoundaryWait("current image dismiss returns to parent") { hosted.controller.presentedViewController == nil && returns == 1 }
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID); XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
        XCTAssertTrue(hosted.controller.view.window === hosted.window)
        let trace = XCTAttachment(string: "original fullScreenCover(item:) API and actual image App owner;current refreshed F4 dismiss action;two dismiss calls return once;presented controller removed;original parent host/view remains")
        trace.name = "attachment-real-modal-return"; trace.lifetime = .keepAlways; add(trace)
    }

    @MainActor
    func testDetailBoundaryFailedUploadKeepsOriginalErrorRetryAndCancel() async throws {
        let state = try detailBoundaryState(attachmentContext(tenantID: "detail-failed-\(UUID())"), transport: FakeAttachmentHTTPTransport(results: []))
        var message = detailBoundaryMessage("detail-failed"); message.status = .failed; message.attachmentUploadStatus = "failed_put"
        detailBoundaryConversation(state, messages: [message])
        state.fileStore.rememberPendingAttachmentUpload(PendingAttachmentUpload(kind: .file, name: "report.pdf", mimeType: "application/pdf", sizeBytes: 1,
            data: Data([1]), conversationID: "detail-chat", quote: nil, replyContext: nil), messageID: message.id)
        var probe: AttachmentDetailProbe?
        ChatAttachmentDetailDiagnostics.detail = { if $0.input.messageID == message.id { probe = $0 } }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentDetailSheet(message: message, conversationID: "detail-chat").appStateEnvironment(state)))
        defer { attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.detail = nil; state.fileStore.cancelAttachmentUploads() }
        try await attachmentBoundaryWait { probe?.input.canRetryUpload == true }
        let current = try XCTUnwrap(probe); XCTAssertTrue(current.input.canCancelUpload)
        XCTAssertEqual(current.input.uploadFailure, state.attachmentUploadFailureMessage(for: message))
        XCTAssertNotNil(current.input.uploadFailure)
        current.actions.cancelUpload()
        XCTAssertFalse(state.fileStore.hasPendingAttachmentUpload(messageID: message.id))
        XCTAssertEqual(state.toast, "已取消附件发送")
        XCTAssertFalse(state.conversationStore.conversationMessageSnapshot(id: "detail-chat")?.messages.contains(where: { $0.id == message.id }) ?? true)
    }

    @MainActor
    func testDetailBoundaryShareUsesRealManagedCacheAndOriginalActivityCompletion() async throws {
        let transport = FakeAttachmentHTTPTransport(results: [])
        let state = try detailBoundaryState(attachmentContext(tenantID: "detail-share-\(UUID())"), transport: transport)
        let bytes = Data("%PDF-1.4\nowned detail fixture\n".utf8)
        var message = detailBoundaryMessage("detail-share")
        message.attachmentSizeBytes = Int64(bytes.count); message.attachmentChecksum = sha256(bytes)
        message.attachmentDownloadAvailable = true; message.attachmentDownloadURL = "https://files.example.test/detail.pdf"
        detailBoundaryConversation(state, messages: [message])
        let context = try XCTUnwrap(state.mediaCacheScopeContext)
        let staged = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(bytes)
        let cached = try await state.commitIndexedMediaCache(temporaryURL: staged,
            metadata: state.unifiedAttachmentMetadata(for: message, context: context), resourceKind: .original,
            integrity: MediaFileIntegrityAuthority(expectedSizeBytes: message.attachmentSizeBytes, expectedSHA256: message.attachmentChecksum),
            messageID: message.id, conversationID: "detail-chat", context: context)
        var probe: AttachmentDetailProbe?
        ChatAttachmentDetailDiagnostics.detail = { if $0.input.messageID == message.id { probe = $0 } }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentDetailSheet(message: message, conversationID: "detail-chat").appStateEnvironment(state)))
        defer { attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.detail = nil; state.fileStore.cancelAttachmentDownloadTasks() }
        try await attachmentBoundaryWait { probe != nil }; try XCTUnwrap(probe).actions.share()
        try await attachmentBoundaryWait { probe?.preparedShareURL != nil && probe?.input.isPreparingShare == false }
        let prepared = try XCTUnwrap(probe?.preparedShareURL); XCTAssertEqual(prepared, cached); XCTAssertEqual(try Data(contentsOf: prepared), bytes)
        XCTAssertTrue(prepared.path.hasPrefix(context.rootDirectory.path)); XCTAssertTrue(transport.requests().isEmpty)
        let attrs = try FileManager.default.attributesOfItem(atPath: prepared.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await attachmentBoundaryWait { hosted.controller.presentedViewController != nil }
        let presented = try XCTUnwrap(hosted.controller.presentedViewController)
        let activity = try XCTUnwrap(attachmentBoundaryControllers(presented, of: UIActivityViewController.self).first)
        activity.completionWithItemsHandler?(nil, true, nil, nil)
        await attachmentBoundaryDrainMain()
        XCTAssertEqual(state.toast, "保存/分享已完成")
        state.setToast(""); let retained = activity.completionWithItemsHandler
        var next = state.apiContext; next.tenantID = "other-detail-share"; state.apiContext = next
        retained?(nil, true, nil, nil); await attachmentBoundaryDrainMain(); XCTAssertEqual(state.toast, "")
    }

    @MainActor
    func testPreviewBoundaryMissingSaveAndLocalQuickLookVideoLifecycle() async throws {
        let state = try detailBoundaryState(attachmentContext(tenantID: "detail-preview-\(UUID())"), transport: FakeAttachmentHTTPTransport(results: []))
        var message = detailBoundaryMessage("detail-image", category: "image")
        message.attachmentName = "photo.png"; message.attachmentMimeType = "image/png"
        var probe: AttachmentImagePreviewProbe?
        ChatAttachmentDetailDiagnostics.image = { probe = $0 }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentImagePreviewSheet(message: message, conversationID: "detail-chat", localURL: nil).appStateEnvironment(state)))
        defer { attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.image = nil }
        try await attachmentBoundaryWait { probe != nil }; let old = try XCTUnwrap(probe)
        XCTAssertFalse(old.input.hasImage); old.actions.save(); XCTAssertEqual(state.toast, "图片暂无可保存链接")
        state.setToast(""); var next = state.apiContext; next.tenantID = "detail-image-other"; state.apiContext = next
        try await attachmentBoundaryWait { probe?.identity == state.chatBubbleSessionIdentity }
        old.actions.save(); XCTAssertEqual(state.toast, ""); try XCTUnwrap(probe).actions.save(); XCTAssertEqual(state.toast, "图片暂无可保存链接")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detail-platform-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.pdf"), second = root.appendingPathComponent("second.pdf")
        try Data("%PDF-1.4\nfixture\n".utf8).write(to: first); try Data("%PDF-1.4\nsecond\n".utf8).write(to: second)
        let quick = try attachmentBoundaryHost(AnyView(AttachmentQuickLookPreview(url: first)))
        defer { attachmentBoundaryRetire(quick) }
        try await attachmentBoundaryWait { !attachmentBoundaryControllers(quick.controller, of: QLPreviewController.self).isEmpty }
        let ql = try XCTUnwrap(attachmentBoundaryControllers(quick.controller, of: QLPreviewController.self).first)
        let qlID = ObjectIdentifier(ql); XCTAssertEqual(ql.dataSource?.numberOfPreviewItems(in: ql), 1)
        XCTAssertEqual(ql.dataSource?.previewController(ql, previewItemAt: 0).previewItemURL, first)
        quick.controller.rootView = AnyView(AttachmentQuickLookPreview(url: second)); quick.controller.view.layoutIfNeeded()
        try await attachmentBoundaryWait { ql.dataSource?.previewController(ql, previewItemAt: 0).previewItemURL == second }
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(attachmentBoundaryControllers(quick.controller, of: QLPreviewController.self).first)), qlID)
        let movie = root.appendingPathComponent("owned.mov"); try Data().write(to: movie)
        let video = try attachmentBoundaryHost(AnyView(AttachmentVideoPreviewSheet(message: message, localURL: movie).appStateEnvironment(state)))
        defer { attachmentBoundaryRetire(video) }
        try await attachmentBoundaryWait { !attachmentBoundaryControllers(video.controller, of: AVPlayerViewController.self).isEmpty }
        let playerController = try XCTUnwrap(attachmentBoundaryControllers(video.controller, of: AVPlayerViewController.self).first)
        XCTAssertEqual((playerController.player?.currentItem?.asset as? AVURLAsset)?.url, movie)
        XCTAssertTrue(playerController.showsPlaybackControls)
        attachmentBoundaryRetire(video)
        try await attachmentBoundaryWait { playerController.player == nil }
        let note = XCTAttachment(string: "AVPlayer ownership/current local URL/dismantle verified; empty owned movie fixture does not prove video decoding. No Photos permission request or share export performed.")
        note.name = "attachment-platform-test-limits"; note.lifetime = .keepAlways; add(note)
    }

    @MainActor
    func testAttachmentBoundarySameBinaryOriginal710Pixels() async throws {
        let state = try detailBoundaryState(attachmentContext(tenantID: "detail-pixels-\(UUID())"), transport: FakeAttachmentHTTPTransport(results: []))
        let file = detailBoundaryMessage("detail-pixel")
        let key = state.attachmentProgressKey(for: file), token = UUID(), task = detailBoundaryDownload(); defer { task.cancel() }
        state.fileStore.replaceAttachmentDownloadTask(attachmentID: key, with: task, token: token)
        state.fileStore.setAttachmentDownloadSnapshot(.init(receivedBytes: 250, totalBytes: 1_000), attachmentID: key, token: token)
        var image = detailBoundaryMessage("image-pixel", category: "image"); image.attachmentName = "photo.png"; image.attachmentMimeType = "image/png"
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("detail-pixels-\(UUID()).png")
        let colorImage = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try XCTUnwrap(colorImage.pngData()).write(to: imageURL)
        AvatarImageCache.shared.storePrepared(colorImage, for: imageURL.absoluteString)
        let pairs: [(String, AnyView, AnyView)] = [
            ("detail-progress", AnyView(LegacyAttachmentDetailSheet(message: file, conversationID: "detail-chat").appStateEnvironment(state)), AnyView(AttachmentDetailSheet(message: file, conversationID: "detail-chat").appStateEnvironment(state))),
            ("image-unavailable", AnyView(LegacyAttachmentImagePreviewSheet(message: image, conversationID: "detail-chat", localURL: nil).appStateEnvironment(state)), AnyView(AttachmentImagePreviewSheet(message: image, conversationID: "detail-chat", localURL: nil).appStateEnvironment(state))),
            ("image-loaded", AnyView(LegacyAttachmentImagePreviewSheet(message: image, conversationID: "detail-chat", localURL: imageURL).appStateEnvironment(state)), AnyView(AttachmentImagePreviewSheet(message: image, conversationID: "detail-chat", localURL: imageURL).appStateEnvironment(state))),
            ("video-unavailable", AnyView(LegacyAttachmentVideoPreviewSheet(message: file, localURL: nil).appStateEnvironment(state)), AnyView(AttachmentVideoPreviewSheet(message: file, localURL: nil).appStateEnvironment(state)))
        ]
        for (name, before, after) in pairs {
            let leftHost = try attachmentBoundaryHost(before); try await Task.sleep(nanoseconds: 150_000_000)
            let left = hostedSnapshotImage(leftHost); attachmentBoundaryRetire(leftHost)
            let rightHost = try attachmentBoundaryHost(after); try await Task.sleep(nanoseconds: 150_000_000)
            let right = hostedSnapshotImage(rightHost); attachmentBoundaryRetire(rightHost)
            func pixels(_ image: UIImage) throws -> [UInt8] {
                let cg = try XCTUnwrap(image.cgImage); var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                let ctx = try XCTUnwrap(CGContext(data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)); return data
            }
            let a = try pixels(left), b = try pixels(right); XCTAssertEqual(a.count, b.count)
            if name == "image-loaded" {
                for pixels in [a, b] {
                    let blue = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 40 && pixels[$0 + 1] < 40 && pixels[$0 + 2] > 200 }.count
                    XCTAssertGreaterThan(blue, 1_000, "Both actual original/candidate image branches must paint the prepared image")
                }
            }
            let changed = stride(from: 0, to: min(a.count, b.count), by: 4).filter { a[$0..<$0 + 4] != b[$0..<$0 + 4] }.count
            add(snapshotAttachment(left, name: "attachment-\(name)-710-before")); add(snapshotAttachment(right, name: "attachment-\(name)-candidate-after"))
            let metric = XCTAttachment(string: "pair=\(name); changed_pixels=\(changed); baseline=original710 copied method bodies; pid=\(ProcessInfo.processInfo.processIdentifier)")
            metric.name = "attachment-\(name)-pixel-metric"; metric.lifetime = .keepAlways; add(metric); XCTAssertEqual(changed, 0)
        }
        state.fileStore.cancelAttachmentDownloadTasks()
    }
}

extension HTTPTransportTests {
    @MainActor
    func testAttachmentDetailAdmittedWorkKeepsOriginalPermissionContractThroughSameScopeRenewal() async throws {
        // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
        // Each independent fixture owns a real matching synthetic device/session namespace.
        var context = makeRefreshableMessageSendContext()
        context.deviceID = "m13-detail-" + UUID().uuidString
        let storedSession = try XCTUnwrap(context.tenantAuthSession)
        context.tenantAuthSession = IMStoredAuthSession(sessionID: storedSession.sessionID,
            refreshToken: storedSession.refreshToken, refreshExpiresAt: storedSession.refreshExpiresAt,
            tokenType: storedSession.tokenType, tenantID: storedSession.tenantID, accountID: storedSession.accountID,
            appID: storedSession.appID, deviceID: context.deviceID, clientType: storedSession.clientType,
            authVersion: storedSession.authVersion, sessionGeneration: storedSession.sessionGeneration,
            accessExpiresAt: storedSession.accessExpiresAt, lifetimeMode: storedSession.lifetimeMode)
        let template = try sessionReauthenticationLoginResult()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: template.data) as? [String: Any])
        var payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        var platformSession = try XCTUnwrap(payload["auth_session"] as? [String: Any])
        var tenant = try XCTUnwrap(payload["session"] as? [String: Any])
        var tenantSession = try XCTUnwrap(tenant["auth_session"] as? [String: Any])
        platformSession["device_id"] = context.deviceID; tenant["device_id"] = context.deviceID; tenantSession["device_id"] = context.deviceID
        tenant["auth_session"] = tenantSession; payload["session"] = tenant; payload["auth_session"] = platformSession; envelope["data"] = payload
        let login = HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: envelope), isHTTPResponse: template.isHTTPResponse, statusCode: template.statusCode)
        let transport = RememberedLoginGateHTTPTransport(loginResult: login)
        transport.releaseLoginResponse()
        let protected = InMemoryProtectedSessionStore(), gate = SuspendedBiometricAuthenticator()
        // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
        XCTAssertTrue(context.save(sessionStore: protected).isCommitted)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detail-admitted-\(UUID())")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "detail-admitted-\(UUID())"))
        let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults), realtimeClient: PostLoginSilentRealtimeTransport(),
            voiceMediaClient: NoopVoiceMediaClient(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            biometricAuthenticator: gate, biometricDefaults: defaults, rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults), protectedSessionStore: protected, apiContextOverride: context)
        state.setAuthenticated(true)
        gate.succeed()
        let saved = await state.saveBiometricProtectionSettings(enabled: true, unlockChats: false, previewFiles: true)
        XCTAssertTrue(saved); XCTAssertEqual(gate.requestCount, 1)
        XCTAssertTrue(state.requiresFileBiometricProtection)
        let bytes = Data("%PDF-1.4\nadmitted fixture\n".utf8)
        var message = ChatMessage(id: "detail-admitted", senderId: "uid-2", senderName: "Peer", text: "owned.pdf", time: "", isOutgoing: false,
            status: .sent, kind: .file, reactions: [], readBy: [], unreadBy: [], isPinned: false)
        message.attachmentFileID = "admitted-file"; message.attachmentName = "owned.pdf"; message.attachmentMimeType = "application/pdf"; message.attachmentMediaCategory = "pdf"
        message.attachmentSizeBytes = Int64(bytes.count); message.attachmentVersion = "v1"
        message.attachmentChecksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        message.attachmentDownloadAvailable = true; message.attachmentDownloadURL = "https://files.example.test/admitted.pdf"
        var conversation = makeDirectConversation(id: "detail-chat"); conversation.messages = [message]
        state.conversationStore.commitConversationSnapshots([conversation])
        let cacheContext = try XCTUnwrap(state.mediaCacheScopeContext)
        let staged = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(bytes)
        let cached = try await state.commitIndexedMediaCache(temporaryURL: staged,
            metadata: state.unifiedAttachmentMetadata(for: message, context: cacheContext), resourceKind: .original,
            integrity: MediaFileIntegrityAuthority(expectedSizeBytes: message.attachmentSizeBytes, expectedSHA256: message.attachmentChecksum),
            messageID: message.id, conversationID: "detail-chat", context: cacheContext)
        var probe: AttachmentDetailProbe?, entries: [(String, Bool)] = []
        ChatAttachmentDetailDiagnostics.detail = { probe = $0 }; ChatAttachmentDetailDiagnostics.taskEntry = { entries.append(($0, $1)) }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentDetailSheet(message: message, conversationID: "detail-chat").appStateEnvironment(state)))
        defer { gate.succeed(); attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.detail = nil; ChatAttachmentDetailDiagnostics.taskEntry = nil; state.fileStore.cancelAttachmentDownloadTasks() }
        try await attachmentBoundaryWait { probe != nil }; let original = try XCTUnwrap(probe)
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        original.actions.share()
        try await attachmentBoundaryWait("original permission admitted") { gate.isWaiting }
        XCTAssertEqual(entries.first?.0, "detail-share"); XCTAssertEqual(entries.first?.1, true)
        state.beginSessionReauthentication()
        let result = await state.reauthenticateCurrentSession(identifier: "member1", password: "SyntheticPass123!", enterpriseCode: "")
        XCTAssertTrue(result); try await attachmentBoundaryWait { probe?.identity == state.chatBubbleSessionIdentity }
        XCTAssertNotEqual(probe?.identity, original.identity); XCTAssertEqual(probe?.bindingGeneration, original.bindingGeneration)
        // Real reauthentication reloads persisted settings and retires the original permission prompt revision.
        XCTAssertTrue(state.requiresFileBiometricProtection)
        state.setToast(""); gate.succeed()
        try await attachmentBoundaryWait("original permission cancellation cleanup") { !gate.isWaiting && probe?.input.isPreparingShare == false && state.toast == "登录状态已变化，请重新验证" }
        XCTAssertFalse(state.isProtectedAccessAuthorized(.filePreview))
        XCTAssertNil(probe?.preparedShareURL); XCTAssertEqual(state.toast, "登录状态已变化，请重新验证")
        XCTAssertEqual(gate.requestCount, 2)
        // A fresh legitimate operation is admitted under the new session, using the original protected/cache path.
        state.setToast(""); gate.succeed(); try XCTUnwrap(probe).actions.share()
        try await attachmentBoundaryWait("current admitted share publication") { probe?.preparedShareURL != nil && probe?.input.isPreparingShare == false }
        XCTAssertEqual(probe?.preparedShareURL, cached); XCTAssertEqual(try Data(contentsOf: cached), bytes)
        XCTAssertEqual(gate.requestCount, 3)
        try await attachmentBoundaryWait { hosted.controller.presentedViewController != nil }
        let activity = try XCTUnwrap(attachmentBoundaryControllers(try XCTUnwrap(hosted.controller.presentedViewController), of: UIActivityViewController.self).first)
        let completion = activity.completionWithItemsHandler
        let admittedIdentity = state.chatBubbleSessionIdentity, admittedBinding = try XCTUnwrap(probe).bindingGeneration
        var renewed = state.apiContext; renewed.sessionEpoch = UUID().uuidString; state.apiContext = renewed
        try await attachmentBoundaryWait { probe?.identity == state.chatBubbleSessionIdentity }
        XCTAssertNotEqual(admittedIdentity, state.chatBubbleSessionIdentity); XCTAssertEqual(probe?.bindingGeneration, admittedBinding)
        XCTAssertTrue(attachmentBoundaryControllers(try XCTUnwrap(hosted.controller.presentedViewController), of: UIActivityViewController.self).contains { $0 === activity })
        state.setToast(""); completion?(nil, true, nil, nil); await attachmentBoundaryDrainMain()
        XCTAssertEqual(state.toast, "保存/分享已完成", "An already admitted system activity completion must survive same-scope identity renewal")
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID); XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
        let trace = XCTAttachment(string: "original Task admitted=true before genuine reauth; persisted original settings retained; original permission revision cancels pending prompt, requestCount2, preparing cleared, no share; fresh current operation admitted and original managed file published, requestCount3; already admitted UIActivity completion after actual owner sessionEpoch renewal succeeds through unchanged original main callback, binding unchanged; same host/view")
        trace.name = "attachment-admitted-original-contract"; trace.lifetime = .keepAlways; add(trace)
    }

    @MainActor
    func testAttachmentDetailBoundarySameScopeReauthenticationRefreshesOnlyCurrentActions() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult()); transport.releaseLoginResponse()
        let context = makeRefreshableMessageSendContext(), protected = InMemoryProtectedSessionStore()
        XCTAssertTrue(context.save(sessionStore: protected).isCommitted)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detail-reauth-\(UUID())")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "detail-reauth-\(UUID())"))
        let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults), realtimeClient: PostLoginSilentRealtimeTransport(),
            voiceMediaClient: NoopVoiceMediaClient(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            biometricDefaults: defaults, rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults), protectedSessionStore: protected, apiContextOverride: context)
        state.setAuthenticated(true)
        var message = ChatMessage(id: "detail-reauth", senderId: "uid-2", senderName: "Peer", text: "photo.png", time: "", isOutgoing: false,
            status: .sent, kind: .image, reactions: [], readBy: [], unreadBy: [], isPinned: false)
        message.attachmentName = "photo.png"; message.attachmentMimeType = "image/png"; message.attachmentMediaCategory = "image"
        var probe: AttachmentImagePreviewProbe?
        ChatAttachmentDetailDiagnostics.image = { probe = $0 }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentImagePreviewSheet(message: message, conversationID: "detail-chat", localURL: nil).appStateEnvironment(state)))
        defer { attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.image = nil }
        try await attachmentBoundaryWait { probe != nil }; let old = try XCTUnwrap(probe)
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        state.beginSessionReauthentication()
        let result = await state.reauthenticateCurrentSession(identifier: "member1", password: "SyntheticPass123!", enterpriseCode: "")
        XCTAssertTrue(result); try await attachmentBoundaryWait { probe?.identity == state.chatBubbleSessionIdentity }
        let current = try XCTUnwrap(probe); XCTAssertNotEqual(old.identity, current.identity)
        state.setToast(""); old.actions.save(); XCTAssertEqual(state.toast, "")
        current.actions.save(); XCTAssertEqual(state.toast, "图片暂无可保存链接")
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID); XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
    }
}

// WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_BEGIN
@MainActor
private func attachmentAdmissionFeatureClose(_ controller: UIViewController) -> UIKeyCommand? {
    guard !controller.isBeingPresented else { return nil }
    return (controller.keyCommands ?? []).first { command in
        guard command.input == UIKeyCommand.inputEscape, let selector = command.action,
              let target = controller.view.target(forAction: selector, withSender: command) as? NSObject else { return false }
        // UIKit's fallback belongs to the controller; the actual Feature shortcut
        // resolves through its SwiftUI view/bridge responder.
        return target !== controller
    }
}

@MainActor
private func attachmentAdmissionPerform(_ command: UIKeyCommand, in controller: UIViewController) -> Bool {
    guard let selector = command.action,
          let target = controller.view.target(forAction: selector, withSender: command) as? NSObject else { return false }
    return UIApplication.shared.sendAction(selector, to: target, from: command, for: nil)
}

extension AttachmentDownloadTests {
    @MainActor
    func testImagePreviewRejectedFeatureCancelThenCurrentCancelClosesSameHostOnce() async throws {
        let state = try detailBoundaryState(attachmentContext(tenantID: "dismiss-admission-\(UUID())"), transport: FakeAttachmentHTTPTransport(results: []))
        let message = detailBoundaryMessage("dismiss-admission-image", category: "image")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dismiss-admission-\(UUID()).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        AvatarImageCache.shared.storePrepared(image, for: url.absoluteString)
        var probe: AttachmentImagePreviewProbe?, returns = 0
        var trace: [String] = []
        ChatAttachmentDetailDiagnostics.image = { probe = $0 }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentBoundaryModalHarness(
            message: message, localURL: url, onReturn: { returns += 1 }).appStateEnvironment(state)))
        defer {
            attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.image = nil
            try? FileManager.default.removeItem(at: url)
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "attachment-feature-dismiss-admission-trace"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await attachmentBoundaryWait("actual Feature cancel shortcut installed") {
            guard let controller = hosted.controller.presentedViewController else { return false }
            return probe != nil && attachmentAdmissionFeatureClose(controller) != nil
        }
        let presented = try XCTUnwrap(hosted.controller.presentedViewController)
        trace.append("keycommands=\((presented.keyCommands ?? []).map { ($0.input ?? "nil") + ":" + ($0.action.map { NSStringFromSelector($0) } ?? "nil") })")
        let oldAction = try XCTUnwrap(attachmentAdmissionFeatureClose(presented))
        let old = try XCTUnwrap(probe)
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        let presentationID = ObjectIdentifier(presented)
        trace.append("actual Feature close Button cancel keyboard shortcut captured; no App dismiss closure invoked by test")
        var context = state.apiContext; context.sessionEpoch = UUID().uuidString
        state.apiContext = context
        XCTAssertNotEqual(old.identity, state.chatBubbleSessionIdentity)
        XCTAssertTrue(attachmentAdmissionPerform(oldAction, in: presented))
        XCTAssertEqual(returns, 0)
        XCTAssertTrue(hosted.controller.presentedViewController === presented)
        trace.append("old Feature entry requested after F4 identity change; original presentation remains; returns=\(returns)")
        try await attachmentBoundaryWait("current action refresh in original Feature host") {
            probe?.identity == state.chatBubbleSessionIdentity
        }
        await attachmentBoundaryDrainMain()
        hosted.window.layoutIfNeeded(); presented.view.setNeedsLayout(); presented.view.layoutIfNeeded()
        let currentFrame = UIGraphicsImageRenderer(bounds: presented.view.bounds).image { _ in
            XCTAssertTrue(presented.view.drawHierarchy(in: presented.view.bounds, afterScreenUpdates: true))
        }
        add(snapshotAttachment(currentFrame, name: "same-host-current-Feature-cancel-before-action"))
        XCTAssertFalse(presented.isBeingDismissed, "Rejected old Feature action cannot start dismissal")
        XCTAssertEqual(returns, 0)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(hosted.controller.presentedViewController)), presentationID)
        let currentAction = try XCTUnwrap(attachmentAdmissionFeatureClose(presented))
        XCTAssertTrue(attachmentAdmissionPerform(currentAction, in: presented))
        XCTAssertTrue(attachmentAdmissionPerform(currentAction, in: presented))
        try await attachmentBoundaryWait("current Feature close shortcut accepted once after old rejection") {
            hosted.controller.presentedViewController == nil && returns == 1
        }
        XCTAssertEqual(returns, 1)
        XCTAssertNil(hosted.controller.presentedViewController)
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID)
        XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
        trace.append("fresh Feature entry invoked twice; returns=\(returns); removed=\(hosted.controller.presentedViewController == nil); same parent host/view")
    }
}
// WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_END

// WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_BEGIN
extension AttachmentDownloadTests {
    func testImagePreviewRejectedAdmissionReopensAllOriginalTriggersAndAcceptedRequestsRemainOneShot() {
        let triggers: [IM4DesignSystem.AttachmentImagePreviewDismissalTrigger] = [.closeButton, .accessibilityEscape, .downwardSwipe, .leadingEdgeSwipe]
        for trigger in triggers {
            var coordinator = IM4DesignSystem.AttachmentImagePreviewDismissalCoordinator()
            XCTAssertTrue(coordinator.request(trigger))
            coordinator.reject(trigger)
            XCTAssertNil(coordinator.acceptedTrigger)
            XCTAssertTrue(coordinator.request(trigger), "A rejected old operation must not consume the current Feature entry")
            XCTAssertEqual(coordinator.acceptedTrigger, trigger)
            for another in triggers { XCTAssertFalse(coordinator.request(another), "An admitted close is still single-shot") }
        }
        var coordinator = IM4DesignSystem.AttachmentImagePreviewDismissalCoordinator()
        XCTAssertTrue(coordinator.request(.closeButton))
        coordinator.reject(.accessibilityEscape)
        XCTAssertEqual(coordinator.acceptedTrigger, .closeButton)
        XCTAssertFalse(coordinator.request(.downwardSwipe))
    }
}
// WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_END

// WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111_BEGIN
@MainActor private func attachmentDragSnapshot(_ hosted: HostedSimulatorUI<AnyView>) throws -> (UIImage, Data, Int) {
    hosted.window.layoutIfNeeded(); hosted.controller.view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
    let image = UIGraphicsImageRenderer(bounds: hosted.window.bounds, format: format).image { _ in
        hosted.window.drawHierarchy(in: hosted.window.bounds, afterScreenUpdates: true)
    }
    let cg = try XCTUnwrap(image.cgImage)
    var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
        let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    var blue = 0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        if pixels[i] < 40, pixels[i + 1] < 40, pixels[i + 2] > 180 { blue += 1 }
    }
    return (image, Data(pixels), blue)
}

extension AttachmentDownloadTests {
    @MainActor
    func testImagePreviewRejectedNonzeroProductionDragRestoresRetainedRenderThenFreshDragClosesOnce() async throws {
        let state = try detailBoundaryState(attachmentContext(tenantID: "drag-recovery-\(UUID())"), transport: FakeAttachmentHTTPTransport(results: []))
        let message = detailBoundaryMessage("drag-recovery-image", category: "image")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drag-recovery-\(UUID()).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        AvatarImageCache.shared.storePrepared(image, for: url.absoluteString)
        var presentation: AttachmentImagePreviewDragProbe?, app: AttachmentImagePreviewProbe?, returns = 0
        var trace: [String] = []
        AttachmentImagePreviewDragDiagnostics.capture = { presentation = $0 }
        ChatAttachmentDetailDiagnostics.image = { app = $0 }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentBoundaryModalHarness(
            message: message, localURL: url, onReturn: { returns += 1 }).appStateEnvironment(state)))
        defer {
            attachmentBoundaryRetire(hosted); AttachmentImagePreviewDragDiagnostics.capture = nil
            ChatAttachmentDetailDiagnostics.image = nil; try? FileManager.default.removeItem(at: url)
            let note = XCTAttachment(string: trace.joined(separator: "\n")); note.name = "attachment-production-drag-rejection-trace"
            note.lifetime = .keepAlways; add(note)
        }
        try await attachmentBoundaryWait("actual preview production drag caller installed") {
            guard let presented = hosted.controller.presentedViewController else { return false }
            return presentation != nil && app != nil && !presented.isBeingPresented
                && !presented.isBeingDismissed && presented.transitionCoordinator == nil
        }
        await attachmentBoundaryDrainMain()
        try await Task.sleep(nanoseconds: 400_000_000)
        let presented = try XCTUnwrap(hosted.controller.presentedViewController)
        let parentID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        let presentedID = ObjectIdentifier(presented)
        let initial = try XCTUnwrap(presentation)
        XCTAssertEqual(initial.offset, .zero); XCTAssertEqual(initial.scale, 1)
        XCTAssertEqual(initial.viewportSize.width, 390)
        let start = CGPoint(x: 5, y: 320), translation = CGSize(width: 380, height: 0)
        trace.append("resting controller=\(presented.view.frame), safeArea=\(presented.view.safeAreaInsets), viewport=\(initial.viewportSize)")
        let before = try attachmentDragSnapshot(hosted)
        XCTAssertGreaterThan(before.2, 1_000, "Real prepared image must be rendered before dragging")
        let beforePNG = XCTAttachment(image: before.0); beforePNG.name = "attachment-drag-resting"; beforePNG.lifetime = .keepAlways; add(beforePNG)
        initial.changed(start, translation)
        try await attachmentBoundaryWait("actual nonzero production State rendered") { presentation?.offset.width == 380 }
        let displaced = try attachmentDragSnapshot(hosted)
        XCTAssertFalse(displaced.1 == before.1)
        XCTAssertLessThan(displaced.2, before.2)
        let displacedPNG = XCTAttachment(image: displaced.0); displacedPNG.name = "attachment-drag-nonzero"; displacedPNG.lifetime = .keepAlways; add(displacedPNG)
        let old = try XCTUnwrap(presentation), oldApp = try XCTUnwrap(app)
        trace.append("actual viewport=\(old.viewportSize), scale=\(old.scale), nonzero State=\(old.offset), blue before=\(before.2), displaced=\(displaced.2)")
        let original = state.apiContext
        var renewed = original; renewed.sessionEpoch = UUID().uuidString
        state.sessionReauthenticationCommit = (old: original.authSessionFence, new: renewed.authSessionFence)
        state.apiContext = renewed; state.sessionReauthenticationCommit = nil
        XCTAssertNotEqual(oldApp.identity, state.chatBubbleSessionIdentity)
        // This is the exact production onEnded caller with nonzero installed State,
        // retained before renewal. The test never calls App actions.dismiss directly.
        old.ended(start, translation, translation)
        try await attachmentBoundaryWait("current actions refresh without replacing preview") { app?.identity == state.chatBubbleSessionIdentity }
        try await Task.sleep(nanoseconds: 800_000_000)
        let current = try XCTUnwrap(presentation)
        trace.append("after rejected real caller: State=\(current.offset), latch=\(String(describing: current.acceptedTrigger)), returns=\(returns)")
        XCTAssertEqual(current.offset, .zero, "Rejected qualifying drag must restore actual retained production offset")
        XCTAssertNil(current.acceptedTrigger)
        XCTAssertEqual(returns, 0)
        XCTAssertFalse(presented.isBeingDismissed)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(hosted.controller.presentedViewController)), presentedID)
        trace.append("after controller=\(presented.view.frame), safeArea=\(presented.view.safeAreaInsets), viewport=\(current.viewportSize)")
        let restored = try attachmentDragSnapshot(hosted)
        let restoredPNG = XCTAttachment(image: restored.0); restoredPNG.name = "attachment-drag-after-rejection"; restoredPNG.lifetime = .keepAlways; add(restoredPNG)
        XCTAssertTrue(restored.1 == before.1, "Actual retained image and top-control rendering must return exactly to resting pixels")
        trace.append("render restored=\(restored.1 == before.1), blue=\(restored.2); no OS touch/drag synthesized")
        current.ended(start, translation, translation)
        current.ended(start, translation, translation)
        try await attachmentBoundaryWait("fresh production close accepted once") { hosted.controller.presentedViewController == nil && returns == 1 }
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(ObjectIdentifier(hosted.controller), parentID)
        XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
        trace.append("fresh qualifying production caller twice; returns=\(returns); same parent host/view")
    }
}
// WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111_END

// WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
extension AttachmentDownloadTests {
    @MainActor
    func testPhysicalFileStoreFourIdentityRetirementsRejectOldUIActionsAndKeepCurrentOwner() async throws {
        let context = attachmentContext(tenantID: "filestore-four-\(UUID())")
        let state = try detailBoundaryState(context, transport: FakeAttachmentHTTPTransport(results: []))
        let store: IM4Stores.FileStore = state.fileStore
        let owner = ObjectIdentifier(store)
        let message = detailBoundaryMessage("filestore-four")
        detailBoundaryConversation(state, messages: [message])
        var probe: AttachmentDetailProbe?, trace: [String] = []
        ChatAttachmentDetailDiagnostics.detail = { if $0.input.messageID == message.id { probe = $0 } }
        let hosted = try attachmentBoundaryHost(AnyView(AttachmentDetailSheet(message: message, conversationID: "detail-chat").appStateEnvironment(state)))
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        defer {
            attachmentBoundaryRetire(hosted); ChatAttachmentDetailDiagnostics.detail = nil
            store.cancelAttachmentUploads(); store.cancelAttachmentDownloadTasks()
            let evidence = XCTAttachment(string: trace.joined(separator: "\n"))
            evidence.name = "physical-filestore-four-identity-ui-trace"; evidence.lifetime = .keepAlways; add(evidence)
        }
        try await attachmentBoundaryWait { probe != nil }
        for field in ["tenant", "app", "actor", "device"] {
            let retired = try XCTUnwrap(probe)
            var next = context
            switch field {
            case "tenant": next.tenantID = "other-\(context.tenantID ?? "")"
            case "app": next.appID = "other-app"
            case "actor": next.imUID = "other-actor"
            default: next.deviceID = "other-device"
            }
            state.apiContext = next; state.apiContext = context
            detailBoundaryConversation(state, messages: [message])
            let download = detailBoundaryDownload(), token = UUID()
            let upload = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
            defer { download.cancel(); upload.cancel() }
            let key = state.attachmentProgressKey(for: message)
            store.replaceAttachmentDownloadTask(attachmentID: key, with: download, token: token)
            store.setAttachmentDownloadSnapshot(.init(receivedBytes: 600, totalBytes: 1_000), attachmentID: key, token: token)
            store.rememberPendingAttachmentUpload(PendingAttachmentUpload(kind: .file, name: "report.pdf", mimeType: "application/pdf", sizeBytes: 1,
                data: Data([1]), conversationID: "detail-chat", quote: nil, replyContext: nil), messageID: message.id)
            store.replaceAttachmentUploadTask(messageID: message.id, with: upload)
            try await attachmentBoundaryWait { probe?.identity != retired.identity && probe?.input.download?.receivedBytes == 600 && probe?.input.canCancelUpload == true }
            retired.actions.cancelDownload(); retired.actions.cancelUpload()
            XCTAssertFalse(download.isCancelled, field); XCTAssertFalse(upload.isCancelled, field)
            XCTAssertTrue(store.hasPendingAttachmentUpload(messageID: message.id), field)
            let current = try XCTUnwrap(probe)
            current.actions.cancelDownload(); current.actions.cancelUpload()
            XCTAssertTrue(download.isCancelled, field); XCTAssertTrue(upload.isCancelled, field)
            XCTAssertFalse(store.hasPendingAttachmentUpload(messageID: message.id), field)
            XCTAssertEqual(ObjectIdentifier(state.fileStore), owner)
            XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID)
            XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
            trace.append("\(field): old-actions-rejected current-download-upload-cancelled same-owner same-host")
        }
    }
}

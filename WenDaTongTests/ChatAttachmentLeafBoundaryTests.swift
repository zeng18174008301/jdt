// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_BEGIN
import XCTest; @testable import IM4Features
import SwiftUI
import UIKit
import Combine
import CryptoKit
@testable import IM4Domain // WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110
@testable import WenDaTong

// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_BEGIN
extension AttachmentDownloadTests {
    @MainActor
    func testMountedFileLeafProjectsMatchingDownloadAndRejectsRetiredCancelWithoutRemount() async throws {
        let context = attachmentContext(tenantID: "leaf-cancel-\(UUID())")
        let state = AppState(api: makeClient(transport: FakeAttachmentHTTPTransport(results: [])), apiContextOverride: context)
        let a = leafMessage("leaf-a", fileID: "asset-a")
        let b = leafMessage("leaf-b", fileID: "asset-b")
        var probes: [String: ChatFileAttachmentProbe] = [:]; var counts: [String: Int] = [:]
        ChatAttachmentAssemblyDiagnostics.file = { probes[$0.messageID] = $0; counts[$0.messageID, default: 0] += 1 }
        defer { ChatAttachmentAssemblyDiagnostics.file = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 360, height: 440)
        let host = UIHostingController(rootView: VStack {
            FileBubbleContent(message: a, outgoing: false, conversationID: "leaf-chat")
            FileBubbleContent(message: b, outgoing: false, conversationID: "leaf-chat")
        }.appStateEnvironment(state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; state.fileStore.cancelAttachmentDownloadTasks() }
        let hostID = ObjectIdentifier(host); let viewID = ObjectIdentifier(host.view)
        try await Task.sleep(nanoseconds: 150_000_000)
        let bCount = counts[b.id]
        let first = try XCTUnwrap(probes[a.id]); XCTAssertEqual(first.layout.fileTypeBadge, "PDF")
        let key = state.attachmentProgressKey(for: a); let token = UUID(); let task = leafPendingDownload()
        defer { task.cancel() }
        state.fileStore.replaceAttachmentDownloadTask(attachmentID: key, with: task, token: token)
        state.fileStore.setAttachmentDownloadSnapshot(.init(receivedBytes: 250, totalBytes: 1_000), attachmentID: key, token: token)
        try await Task.sleep(nanoseconds: 150_000_000)
        let old = try XCTUnwrap(probes[a.id]); XCTAssertEqual(old.presentation.download?.receivedBytes, 250)
        XCTAssertEqual(old.presentation.progress, 0.25); XCTAssertEqual(counts[b.id], bCount)
        var next = context; next.tenantID = "other-\(context.tenantID ?? "")"
        state.apiContext = next; state.apiContext = context
        let newKey = state.attachmentProgressKey(for: a); let replacement = leafPendingDownload(); let replacementToken = UUID()
        defer { replacement.cancel() }
        state.fileStore.replaceAttachmentDownloadTask(attachmentID: newKey, with: replacement, token: replacementToken)
        state.fileStore.setAttachmentDownloadSnapshot(.init(receivedBytes: 600, totalBytes: 1_000), attachmentID: newKey, token: replacementToken)
        try await Task.sleep(nanoseconds: 150_000_000)
        old.onCancelDownload(); XCTAssertTrue(state.fileStore.hasAttachmentDownloadTask(attachmentID: newKey))
        XCTAssertFalse(replacement.isCancelled)
        let current = try XCTUnwrap(probes[a.id]); XCTAssertEqual(current.presentation.download?.receivedBytes, 600)
        current.onCancelTransfer(); XCTAssertFalse(state.fileStore.hasAttachmentDownloadTask(attachmentID: newKey)); XCTAssertTrue(replacement.isCancelled)
        XCTAssertEqual(ObjectIdentifier(host), hostID); XCTAssertEqual(ObjectIdentifier(host.view), viewID)
    }

    @MainActor
    func testOriginalThumbnailRealCacheHitWaitsForSharedLocalDecodeAdmissionAndKeepsProtection() async throws {
        let context = attachmentContext(tenantID: "leaf-admission-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let bytes = leafImageBytes(.red)
        var message = leafMessage("leaf-cache", fileID: "cached-image", kind: .image)
        message.attachmentMimeType = "image/png"; message.attachmentName = "cache.png"
        message.attachmentMediaCategory = "image"; message.attachmentChecksum = sha256(bytes)
        message.attachmentSizeBytes = Int64(bytes.count); message.attachmentVersion = "v1"
        let transport = FakeAttachmentHTTPTransport(results: [])
        let state = actualLeafCacheState(context: context, transport: transport)
        let cacheContext = try XCTUnwrap(state.mediaCacheScopeContext)
        let staged = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(bytes)
        defer { try? FileManager.default.removeItem(at: staged) }
        let url = try await state.commitIndexedMediaCache(temporaryURL: staged,
            metadata: state.unifiedAttachmentMetadata(for: message, context: cacheContext), resourceKind: .original,
            integrity: MediaFileIntegrityAuthority(expectedSizeBytes: message.attachmentSizeBytes, expectedSHA256: message.attachmentChecksum),
            messageID: message.id, conversationID: "leaf-chat", context: cacheContext)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        if let protection = attributes[.protectionKey] as? FileProtectionType { XCTAssertEqual(protection.rawValue, FileProtectionType.completeUntilFirstUserAuthentication.rawValue) }
        let protection = XCTAttachment(string: "Simulator file protection metadata: \(String(describing: attributes[.protectionKey])); physical iOS15 protection not verified")
        protection.lifetime = .keepAlways; add(protection)
        var hits: [URL?] = []
        ChatAttachmentAssemblyDiagnostics.originalLookup = { if $0 == message.id { hits.append($1) } }
        defer { ChatAttachmentAssemblyDiagnostics.originalLookup = nil }
        let gate = AttachmentThumbnailLoadGate.localDecodes
        let firstAdmission = await gate.acquire(); let secondAdmission = await gate.acquire()
        XCTAssertTrue(firstAdmission); XCTAssertTrue(secondAdmission)
        var held = 2
        defer { let remaining = held; if remaining > 0 { Task { for _ in 0..<remaining { await gate.release() } } } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        let host = UIHostingController(rootView: AttachmentOriginalThumbnail(message: message, conversationID: "leaf-chat").frame(width: 64, height: 64).appStateEnvironment(state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 150_000_000); XCTAssertTrue(hits.isEmpty)
        await gate.release(); held -= 1
        for _ in 0..<100 { if !hits.isEmpty { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(try XCTUnwrap(hits.first ?? nil), url); XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(transport.requests().isEmpty)
        await gate.release(); held -= 1
    }

    @MainActor
    func testPosterAppTaskRejectsLateOldScopeAndPaintsCurrentResourceInSameHost() async throws {
        let context = attachmentContext(tenantID: "leaf-poster-\(UUID())")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).jpegData(withCompressionQuality: 0.8) { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let transport = LeafPosterGateTransport(bytes: bytes)
        let state = actualLeafCacheState(context: context, transport: transport)
        var message = leafMessage("leaf-poster", fileID: "leaf-parent", kind: .video)
        message.attachmentMediaCategory = "video"; message.attachmentMimeType = "video/mp4"
        message.attachmentChecksum = String(repeating: "a", count: 64)
        message.attachmentVersion = "v1"
        state.conversationStore.commitConversationSnapshots([ConversationMessageSnapshot(id: "leaf-chat", title: "", subtitle: "", kind: .direct,
            lastMessage: "", time: "", unread: 0, isPinned: false, isMuted: false, memberCount: nil,
            accentHex: 0, participants: [], messages: [message])])
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context)); defer { try? paths.purgeExactScope() }
        var probes: [ChatPosterThumbnailProbe] = []
        ChatAttachmentAssemblyDiagnostics.poster = { if $0.messageID == message.id { probes.append($0) } }
        defer { ChatAttachmentAssemblyDiagnostics.poster = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 200, height: 160)
        let host = UIHostingController(rootView: ServerVideoPosterThumbnail(message: message, conversationID: "leaf-chat").appStateEnvironment(state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; Task { await transport.cancelAll() } }
        let hostID = ObjectIdentifier(host); let viewID = ObjectIdentifier(host.view)
        for _ in 0..<100 { if await transport.statusCount() == 1 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        let firstStatusCount = await transport.statusCount(); XCTAssertEqual(firstStatusCount, 1)
        var next = context; next.tenantID = "next-\(context.tenantID ?? "")"; state.apiContext = next
        // WDT_IOS1_CHAT_ACTUAL_POSTER_SCOPE_FIXTURE_20261110_BEGIN
        // The actual Store retires A's message window. Install B's real source before the main actor yields;
        // this leaf observes scope/network recovery, not message-window updates, so this cannot force a UI rebind.
        state.conversationStore.commitConversationSnapshots([ConversationMessageSnapshot(id: "leaf-chat", title: "", subtitle: "", kind: .direct,
            lastMessage: "", time: "", unread: 0, isPinned: false, isMuted: false, memberCount: nil,
            accentHex: 0, participants: [], messages: [message])])
        // WDT_IOS1_CHAT_ACTUAL_POSTER_SCOPE_FIXTURE_20261110_END
        let nextPaths = try MessageDatabasePaths(scope: LocalMessageScope(context: next)); defer { try? nextPaths.purgeExactScope() }
        for _ in 0..<100 { if await transport.statusCount() == 2 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        let secondStatusCount = await transport.statusCount(); XCTAssertEqual(secondStatusCount, 2)
        let currentResource = try XCTUnwrap(probes.last).resource
        XCTAssertEqual(probes.last?.scopeGeneration, state.localMessageSessionGeneration)
        try await transport.releaseFirst()
        try await Task.sleep(nanoseconds: 100_000_000)
        let stalePosterCount = await transport.posterCount(); XCTAssertEqual(stalePosterCount, 0); XCTAssertEqual(probes.last?.resource, currentResource)
        try await transport.releaseFirst()
        var ready: URL?
        for _ in 0..<150 {
            if let current = probes.last, case .ready(let url) = current.presentation { ready = url; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let url = try XCTUnwrap(ready); XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(url.path.hasPrefix(try XCTUnwrap(state.mediaCacheScopeContext).rootDirectory.path))
        let currentPosterCount = await transport.posterCount(); XCTAssertEqual(currentPosterCount, 1)
        XCTAssertEqual(ObjectIdentifier(host), hostID); XCTAssertEqual(ObjectIdentifier(host.view), viewID)
    }

    // WDT_IOS1_CHAT_ACTUAL_CACHE_FIXTURE_ISOLATION_20261110_BEGIN
    @MainActor
    private func actualLeafCacheState(context: IMAPIContext, transport: any HTTPTransport) -> AppState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("actual-leaf-persistence-\(UUID())")
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"))
        // Only the UUID media scope is purged by these tests; never unlink an active shared SQLite repository.
        return AppState(api: makeClient(transport: transport), realtimeClient: PostLoginSilentRealtimeTransport(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: persistence, protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
    }
    // WDT_IOS1_CHAT_ACTUAL_CACHE_FIXTURE_ISOLATION_20261110_END

    private func leafMessage(_ id: String, fileID: String, kind: MessageKind = .file) -> ChatMessage {
        var message = ChatMessage(id: id, senderId: "uid-2", senderName: "Peer", text: "document.pdf", time: "",
                                  isOutgoing: false, status: .sent, kind: kind, reactions: [], readBy: [], unreadBy: [], isPinned: false)
        message.attachmentFileID = fileID; message.attachmentName = "document.pdf"
        message.attachmentMimeType = "application/pdf"; message.attachmentMediaCategory = "pdf"
        message.attachmentSizeBytes = 1_000; message.attachmentVersion = "v1"
        return message
    }

    private func leafPendingDownload() -> Task<URL, Error> {
        Task { try await Task.sleep(nanoseconds: 30_000_000_000); return URL(fileURLWithPath: "/unused") }
    }

    @MainActor
    private func leafImageBytes(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).pngData { c in
            color.setFill(); c.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}

private actor LeafPosterGateTransport: HTTPTransport {
    private var statuses = 0
    private var posters = 0
    private var pending: [CheckedContinuation<HTTPTransportResult, Error>] = []
    private let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    func statusCount() -> Int { statuses }
    func posterCount() -> Int { posters }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        if request.url?.path.hasSuffix("/poster-status") == true {
            statuses += 1
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        if request.url?.path.hasSuffix("/poster") == true {
            posters += 1
            return HTTPTransportResult(data: bytes, isHTTPResponse: true, statusCode: 200, headers: ["Content-Type": "image/jpeg"])
        }
        throw URLError(.resourceUnavailable)
    }
    nonisolated func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
    func releaseFirst() throws {
        guard !pending.isEmpty else { return }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", Int($0)) }.joined()
        let payload: [String: Any] = ["file_id": "leaf-parent", "checksum_sha256": String(repeating: "a", count: 64),
            "poster_source_checksum": String(repeating: "a", count: 64), "thumbnail_status": "ready", "poster_file_id": "leaf-cover",
            "poster_checksum": hash, "thumbnail_version": hash, "poster_mime_type": "image/jpeg", "poster_size_bytes": bytes.count,
            "poster_width": 2, "poster_height": 2]
        let response = HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload]), isHTTPResponse: true, statusCode: 200)
        pending.removeFirst().resume(returning: response)
    }
    func cancelAll() { let values = pending; pending = []; values.forEach { $0.resume(throwing: CancellationError()) } }
}

extension HTTPTransportTests {
    @MainActor
    func testFileLeafRetainedCancelKeepsNormalTokenAndLegitimateSameScopeRenewalContract() async throws {
        for renewal in [false, true] {
            let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
            transport.releaseLoginResponse()
            let fixture = try makeSessionReauthenticationFixture(transport: transport, store: InMemoryProtectedSessionStore())
            addTeardownBlock { @MainActor in
                await fixture.persistence.detach(ticket: fixture.state.localMessageTicket)
                // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
            }
            let state = fixture.state
            var message = ChatMessage(id: "retained-file", senderId: "uid-2", senderName: "Peer", text: "file.pdf", time: "",
                                      isOutgoing: false, status: .sent, kind: .file, reactions: [], readBy: [], unreadBy: [], isPinned: false)
            message.attachmentFileID = "retained-file-id"; message.attachmentName = "file.pdf"; message.attachmentMimeType = "application/pdf"
            var probe: ChatFileAttachmentProbe?
            ChatAttachmentAssemblyDiagnostics.file = { if $0.messageID == message.id { probe = $0 } }
            defer { ChatAttachmentAssemblyDiagnostics.file = nil }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 220)
            let host = UIHostingController(rootView: FileBubbleContent(message: message, outgoing: false, conversationID: "leaf-chat").appStateEnvironment(state))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; state.fileStore.cancelAttachmentDownloadTasks() }
            let hostID = ObjectIdentifier(host)
            try await Task.sleep(nanoseconds: 150_000_000)
            let original = try XCTUnwrap(probe)
            if renewal {
                let succeeded = await state.reauthenticateCurrentSession(identifier: "member1", password: "SyntheticPass123!", enterpriseCode: "")
                XCTAssertTrue(succeeded)
                XCTAssertNotEqual(state.apiContext.sessionEpoch, fixture.original.sessionEpoch)
            } else {
                var rotated = state.apiContext; rotated.imToken = "normal-rotated-synthetic-token"; state.apiContext = rotated
            }
            // Register a real current-scope task without publishing a fake message/row update.
            let key = state.attachmentProgressKey(for: message)
            let task = Task<URL, Error> { try await Task.sleep(nanoseconds: 30_000_000_000); return URL(fileURLWithPath: "/unused") }
            defer { task.cancel() }
            state.fileStore.replaceAttachmentDownloadTask(attachmentID: key, with: task)
            original.onCancelDownload()
            XCTAssertFalse(state.fileStore.hasAttachmentDownloadTask(attachmentID: key)); XCTAssertTrue(task.isCancelled)
            XCTAssertEqual(ObjectIdentifier(host), hostID)
        }
    }
}
// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_END

// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_END

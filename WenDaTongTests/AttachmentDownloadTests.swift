@testable import IM4Features
import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import CryptoKit
import Foundation
import XCTest
import UIKit
import SwiftUI
@testable import IM4Domain // WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110
@testable import WenDaTong

final class AttachmentDownloadTests: XCTestCase {
    @MainActor
    func testWarmChatImagesAndPostersPaintTheirFirstFrameFromMemory() async throws {
        let transport = FakeAttachmentHTTPTransport(results: [])
        let (state, source) = posterState(transport, context: attachmentContext(tenantID: "first-frame-\(UUID())"), parent: "warm-parent")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let red = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        for isPoster in [false, true] {
            var message = source
            message.attachmentMediaCategory = isPoster ? "video" : "image"
            let key = AttachmentThumbnailCacheIdentity.generationKey(
                baseKey: state.chatAttachmentImageCacheKey(for: message, videoPoster: isPoster),
                generation: state.mediaCacheScopeContext?.sessionGeneration ?? 0)
            AvatarImageCache.shared.storePrepared(red, for: key, maxPixelSize: 768)
            let content = isPoster
                ? AnyView(ServerVideoPosterThumbnail(message: message, conversationID: "poster-chat"))
                : AnyView(AttachmentOriginalThumbnail(message: message, conversationID: "poster-chat"))
            let host = UIHostingController(rootView: content.frame(width: 64, height: 64).ignoresSafeArea().appStateEnvironment(state))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            window.rootViewController = host; window.makeKeyAndVisible()
            window.layoutIfNeeded(); host.view.layoutIfNeeded()
            defer { window.isHidden = true; window.rootViewController = nil }

            func assertRedFrame(_ reason: String) throws {
                let frame = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                var pixel = [UInt8](repeating: 0, count: 4)
                let bitmap = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.draw(try XCTUnwrap(frame.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
                XCTAssertGreaterThan(pixel[0], 200, reason)
                XCTAssertLessThan(pixel[1], 50, reason)
                XCTAssertLessThan(pixel[2], 50, reason)
            }

            try assertRedFrame("The first frame should show the cached image")
            try await Task.sleep(nanoseconds: 100_000_000)
            AvatarImageCache.shared.removeAllImages()
            state.objectWillChange.send()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNil(AvatarImageCache.shared.peekImage(for: key, maxPixelSize: 768))
            try assertRedFrame("A visible image should survive cache eviction and an unrelated refresh")
        }
    }

    // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedThumbnailRetriesFromFileStoreWithoutAppStatePublication() async throws {
        let state = AppState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let failed = expectation(description: "initial thumbnail failure is visible")
        failed.assertForOverFulfill = false
        let retried = expectation(description: "file store reconnect triggers another request")
        var attempts = 0
        let cacheKey = "file-recovery-\(UUID())"
        let content = state.fileStore.observeMediaNetworkRecovery { generation in
            AttachmentThumbnailImage(
                url: nil, cacheKey: cacheKey, networkRecoveryGeneration: generation,
                recoveryURL: {
                    attempts += 1
                    if attempts == 2 { retried.fulfill() }
                    return nil
                },
                placeholder: { Color.clear },
                failure: { Text("failed").onAppear { failed.fulfill() } }
            )
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        await fulfillment(of: [failed], timeout: 3)
        var globalUpdates = 0
        let app = state.objectWillChange.sink { globalUpdates += 1 }
        state.fileStore.noteMediaNetworkRecovery()
        app.cancel()
        XCTAssertEqual(globalUpdates, 0)
        await fulfillment(of: [retried], timeout: 3)
        XCTAssertEqual(attempts, 2)
    }
    // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END

    @MainActor
    private func posterState(_ transport: FakeAttachmentHTTPTransport, context: IMAPIContext, parent: String) -> (AppState, ChatMessage) {
        var message = makeEndpointOnlyAttachmentMessage(fileID: parent)
        message.attachmentMediaCategory = "video"
        message.attachmentChecksum = String(repeating: "a", count: 64)
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let state = AppState(api: makeClient(transport: transport), conversationStore: store,
            messagePersistence: MessagePersistenceCoordinator(), apiContextOverride: context)
        store.commitConversationSnapshots([ConversationMessageSnapshot(id: "poster-chat", title: "", subtitle: "", kind: .direct,
            lastMessage: "", time: "", unread: 0, isPinned: false, isMuted: false, memberCount: nil,
            accentHex: 0, participants: [], messages: [message])])
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshot(id: "poster-chat")?.messages.first?.id, message.id)
        return (state, message)
    }

    private func posterReply(parent: String, state: String, bytes: Data? = nil) throws -> HTTPTransportResult {
        var data: [String: Any] = ["file_id": parent, "checksum_sha256": String(repeating: "a", count: 64),
            "poster_source_checksum": String(repeating: "a", count: 64), "thumbnail_status": state]
        if let bytes {
            data.merge(["poster_file_id": "child", "poster_checksum": sha256(bytes), "thumbnail_version": sha256(bytes),
                "poster_mime_type": "image/jpeg", "poster_size_bytes": bytes.count, "poster_width": 2, "poster_height": 2]) { _, new in new }
        }
        return HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": data]), isHTTPResponse: true, statusCode: 200)
    }

    @MainActor
    func testServerVideoPosterIsPersistedAndReopenedWithoutMovieDownload() async throws {
        let context = attachmentContext(tenantID: "server-poster-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).jpegData(withCompressionQuality: 0.8) { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let reply = try posterReply(parent: "parent", state: "ready", bytes: bytes)
        let transport = FakeAttachmentHTTPTransport(results: [reply,
            HTTPTransportResult(data: bytes, isHTTPResponse: true, statusCode: 200, headers: ["Content-Type": "image/jpeg"])])
        let (state, message) = posterState(transport, context: context, parent: "parent")
        var result: URL?
        await state.loadServerVideoPoster(message, conversationID: "poster-chat") {
            if case .ready(let url) = $0 { result = url }
        }
        let url = try XCTUnwrap(result)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/parent/poster-status", "/api/tenant/files/parent/poster"])
        XCTAssertTrue(transport.requests().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        // Recycled cells must read disk before consuming the five-attempt network budget.
        for _ in 0..<8 {
            var visibleAgain: URL?
            await state.loadServerVideoPoster(message, conversationID: "poster-chat") {
                if case .ready(let hit) = $0 { visibleAgain = hit }
            }
            XCTAssertEqual(visibleAgain, url)
        }
        XCTAssertEqual(transport.requests().count, 2)
        let secondTransport = FakeAttachmentHTTPTransport(results: [])
        let (second, secondMessage) = posterState(secondTransport, context: context, parent: "parent")
        var reopened: URL?
        await second.loadServerVideoPoster(secondMessage, conversationID: "poster-chat") {
            if case .ready(let url) = $0 { reopened = url }
        }
        XCTAssertEqual(reopened, url)
        XCTAssertTrue(secondTransport.requests().isEmpty, "Cold reopen must restore the indexed cover without a network request")
    }

    func testPosterReceiptRejectsChangedSourceAndVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("poster-checksum-fixture".utf8)
        let response = try posterReply(parent: "bound-parent", state: "ready", bytes: bytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.data) as? [String: Any])
        let payload = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["data"]))
        let status = try JSONDecoder().decode(IOSServerVideoPosterStatus.self, from: payload)
        await IOSServerVideoPosterReceiptStore.shared.save(status, root: root, sourceVersion: "v1")
        let same = await IOSServerVideoPosterReceiptStore.shared.load(root: root, parentID: "bound-parent", checksum: String(repeating: "a", count: 64), sourceVersion: "v1")
        let changed = await IOSServerVideoPosterReceiptStore.shared.load(root: root, parentID: "bound-parent", checksum: String(repeating: "b", count: 64), sourceVersion: "v1")
        let changedVersion = await IOSServerVideoPosterReceiptStore.shared.load(root: root, parentID: "bound-parent", checksum: String(repeating: "a", count: 64), sourceVersion: "v2")
        let otherParent = await IOSServerVideoPosterReceiptStore.shared.load(root: root, parentID: "other-parent", checksum: String(repeating: "a", count: 64), sourceVersion: "v1")
        XCTAssertNotNil(same)
        XCTAssertNil(changed)
        XCTAssertNil(changedVersion)
        XCTAssertNil(otherParent)
    }

    @MainActor
    func testColdPosterCacheActivatesRegistryBeforeLookup() async throws {
        let context = attachmentContext(tenantID: "cold-poster-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let bytes = Data("existing-poster-bytes".utf8)
        let transport = FakeAttachmentHTTPTransport(results: [])
        let (state, message) = posterState(transport, context: context, parent: "parent")
        let cacheContext = try XCTUnwrap(state.mediaCacheScopeContext)
        let metadata = MediaResourceMetadata(scope: cacheContext.scopeHash, fileID: "cold-server-poster", version: "v1",
            mimeType: "image/jpeg", thumbnailMimeType: "image/jpeg", thumbnailExtension: "jpg")
        let identity = metadata.identity(for: .thumbnail, variant: .videoPoster)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Seed disk using a separate store, without touching the process-wide registry.
        let disk = MediaLayeredCacheStore(rootDirectory: cacheContext.rootDirectory)
        let entry = try await disk.saveVerifiedDownloadedFile(from: staging, identity: identity,
            preferredExtension: "jpg", integrity: MediaFileIntegrityAuthority())
        let ticket = try await state.messagePersistence.ensureTicket(context: context, sessionGeneration: cacheContext.sessionGeneration)
        let now = Date()
        let authority = IOSMediaCacheAuthorityRecord(scopeHash: cacheContext.scopeHash, messageID: message.id,
            attachmentID: identity.primaryStableID, identity: identity, mimeType: "image/jpeg", sizeBytes: Int64(bytes.count),
            checksumSHA256: nil, state: .active, authorityVersion: "0", lastAuthorizedAt: now,
            offlineAccessUntil: now.addingTimeInterval(86400), createdAt: now, updatedAt: now)
        let record = IOSMediaCacheEntryRecord(scopeHash: cacheContext.scopeHash,
            cacheIdentity: try XCTUnwrap(identity.persistentCacheIdentity), attachmentID: identity.primaryStableID,
            variant: .videoPoster, relativePath: String(entry.localURL.path.dropFirst(cacheContext.rootDirectory.path.count + 1)),
            localState: .verifiedCached, sizeBytes: Int64(bytes.count), verifiedSizeBytes: Int64(bytes.count),
            verifiedChecksumSHA256: sha256(bytes), pinnedByUser: false, protectionReason: "", createdAt: now, lastAccessedAt: now)
        let accepted = try await state.messagePersistence.upsertMediaCache(ticket: ticket, authority: authority, entry: record, conversationID: "poster-chat")
        XCTAssertTrue(accepted)
        let wasActive = await IOSMediaCacheStoreRegistry.shared.accepts(cacheContext)
        XCTAssertFalse(wasActive)
        let hit = await state.lookupIndexedMediaCache(metadata: metadata, messageID: message.id,
            resourceKind: .thumbnail, variant: .videoPoster, integrity: MediaFileIntegrityAuthority(), context: cacheContext, offline: true)
        XCTAssertEqual(hit, entry.localURL)
        XCTAssertTrue(transport.requests().isEmpty)
    }

    @MainActor
    func testChatImageOriginalReusesDiskAfterReopening() async throws {
        let context = attachmentContext(tenantID: "image-original-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let bytes = Data("image-original-fixture".utf8)
        let remote = URL(string: "https://cdn.example.test/photo.jpg")!
        AttachmentDownloadURLProtocol.reset(statusCodes: [200], data: bytes)
        let payload: [String: Any] = ["ok": true, "data": ["file": ["id": "photo", "file_name": "photo.jpg",
            "mime_type": "image/jpeg", "media_category": "image", "extension": "jpg", "size_bytes": bytes.count,
            "status": "uploaded", "version": "v1", "checksum": sha256(bytes)], "download_available": true, "download_url": remote.absoluteString]]
        let transport = FakeAttachmentHTTPTransport(results: [HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: payload), isHTTPResponse: true, statusCode: 200)])
        var message = makeEndpointOnlyAttachmentMessage(fileID: "photo")
        message.attachmentMediaCategory = "image"; message.attachmentMimeType = "image/jpeg"
        message.attachmentName = "photo.jpg"; message.attachmentExtension = "jpg"
        message.attachmentChecksum = sha256(bytes); message.attachmentVersion = "v1"; message.attachmentSizeBytes = Int64(bytes.count)
        let first = AppState(api: makeClient(transport: transport), messagePersistence: MessagePersistenceCoordinator(),
            apiContextOverride: context, attachmentDownloadSessionFactory: makeSessionFactory())
        let url = try await first.prepareMessageAttachmentLocalFile(message, conversationID: "image-chat")
        let second = AppState(api: makeClient(transport: transport), messagePersistence: MessagePersistenceCoordinator(),
            apiContextOverride: context, attachmentDownloadSessionFactory: makeSessionFactory())
        let hit = try await second.prepareMessageAttachmentLocalFile(message, conversationID: "image-chat")
        XCTAssertEqual(hit, url)
        XCTAssertEqual(try Data(contentsOf: hit), bytes)
        // WDT_CHAT_MEDIA_CACHE_REUSE_20261102: recycled cells and preview taps share the downloaded original.
        for _ in 0..<3 {
            let cached = await second.cachedMessageAttachmentLocalFile(message, conversationID: "image-chat")
            XCTAssertEqual(cached, url)
            let preview = try await second.prepareMessageAttachmentLocalFile(message, conversationID: "image-chat", preferPreview: true)
            XCTAssertEqual(preview, url)
        }
        XCTAssertEqual(transport.requests().count, 1)
        XCTAssertEqual(AttachmentDownloadURLProtocol.recordedRequests().count, 1)
    }

    // WDT_CHAT_MEDIA_CACHE_REUSE_20261102_BEGIN
    @MainActor
    func testDownloadedVideoOriginalIsReusedForPreviewAfterReopening() async throws {
        let context = attachmentContext(tenantID: "video-reuse-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let transport = FakeAttachmentHTTPTransport(results: [])
        let (first, source) = posterState(transport, context: context, parent: "video-reuse")
        var message = source
        let bytes = Data("cached-video-original".utf8)
        message.attachmentChecksum = sha256(bytes)
        message.attachmentVersion = "v1"
        message.attachmentSizeBytes = Int64(bytes.count)
        message.attachmentMimeType = "video/mp4"
        message.attachmentExtension = "mp4"
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let cacheContext = try XCTUnwrap(first.mediaCacheScopeContext)
        let url = try await first.commitIndexedMediaCache(temporaryURL: staging,
            metadata: MediaResourceMetadata(scope: cacheContext.scopeHash, fileID: "video-reuse", version: "v1",
                checksumSHA256: message.attachmentChecksum, mimeType: "video/mp4", sizeBytes: Int64(bytes.count), fileExtension: "mp4"),
            resourceKind: .original,
            integrity: MediaFileIntegrityAuthority(expectedSizeBytes: Int64(bytes.count), expectedSHA256: message.attachmentChecksum),
            messageID: message.id, conversationID: "video-chat", context: cacheContext)
        let second = AppState(api: makeClient(transport: transport), messagePersistence: MessagePersistenceCoordinator(), apiContextOverride: context)
        let hit = try await second.prepareMessageAttachmentLocalFile(message, conversationID: "video-chat", preferPreview: true)
        XCTAssertEqual(hit, url)
        XCTAssertTrue(transport.requests().isEmpty)
        var changed = message
        changed.attachmentChecksum = String(repeating: "b", count: 64)
        let changedHit = await second.cachedMessageAttachmentLocalFile(changed, conversationID: "video-chat")
        XCTAssertNil(changedHit, "A different original must not reuse the old file")
        try FileManager.default.removeItem(at: url)
        let missingHit = await second.cachedMessageAttachmentLocalFile(message, conversationID: "video-chat")
        XCTAssertNil(missingHit, "An evicted file must fall back to the existing download path")
    }

    @MainActor
    func testDerivedVideoPosterReopensWithoutPosterStatusRequest() async throws {
        let context = attachmentContext(tenantID: "derived-cover-reuse-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let transport = FakeAttachmentHTTPTransport(results: [])
        let (first, message) = posterState(transport, context: context, parent: "derived-cover")
        let bytes = Data("verified-derived-cover".utf8)
        let cached = await first.cacheUnifiedAttachmentThumbnail(bytes, for: message, conversationID: "poster-chat")
        let url = try XCTUnwrap(cached)
        let (second, reopened) = posterState(transport, context: context, parent: "derived-cover")
        for _ in 0..<3 {
            var result: URL?
            await second.loadServerVideoPoster(reopened, conversationID: "poster-chat") {
                if case .ready(let hit) = $0 { result = hit }
            }
            XCTAssertEqual(result, url)
        }
        XCTAssertTrue(transport.requests().isEmpty, "A cached local cover must not poll or download again")
    }
    // WDT_CHAT_MEDIA_CACHE_REUSE_20261102_END

    @MainActor
    func testAbsentServerPosterNeverStartsMovieDownload() async throws {
        AttachmentDownloadURLProtocol.reset(statusCodes: [200], data: Data("movie".utf8))
        let context = attachmentContext(tenantID: "missing-poster-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let transport = FakeAttachmentHTTPTransport(results: [try posterReply(parent: "parent", state: "none")])
        let (state, message) = posterState(transport, context: context, parent: "parent")
        var missing = false
        await state.loadServerVideoPoster(message, conversationID: "poster-chat") { if case .missing = $0 { missing = true } }
        XCTAssertTrue(missing)
        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/parent/poster-status"])
        XCTAssertTrue(AttachmentDownloadURLProtocol.recordedRequests().isEmpty)
    }

    @MainActor
    func testPendingServerPosterPollingIsBounded() async throws {
        let context = attachmentContext(tenantID: "pending-poster-\(UUID())")
        let transport = FakeAttachmentHTTPTransport(results: [try posterReply(parent: "parent", state: "pending")])
        let (state, message) = posterState(transport, context: context, parent: "parent")
        var sleeps = 0
        await state.loadServerVideoPoster(message, conversationID: "poster-chat", pause: { _ in sleeps += 1 }) { _ in }
        XCTAssertEqual(transport.requests().count, 5)
        XCTAssertEqual(sleeps, 4)
        var limited = false
        await state.loadServerVideoPoster(message, conversationID: "poster-chat") { if case .limited = $0 { limited = true } }
        XCTAssertTrue(limited)
        XCTAssertEqual(transport.requests().count, 5)
    }

    @MainActor
    func testServerPosterRejectsChangedParentAndInvalidBytes() throws {
        let bytes = Data([0xff, 0xd8, 0xff, 0x00])
        let reply = try posterReply(parent: "parent", state: "ready", bytes: bytes)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.data) as? [String: Any])
        let raw = try JSONSerialization.data(withJSONObject: XCTUnwrap(envelope["data"]))
        let status = try JSONDecoder().decode(IOSServerVideoPosterStatus.self, from: raw)
        try status.validate(parentID: "parent", expectedChecksum: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try status.validate(parentID: "parent", expectedChecksum: String(repeating: "b", count: 64)))
        XCTAssertThrowsError(try IMAPIClient.validateVideoPosterBytes(bytes, status: status))
    }

    func testPresignedDownloadAddressAcceptsAndroidResponseShapes() throws {
        for payload in [
            #"{"download_url":"https://cdn.test/movie.mp4"}"#,
            #"{"signed_url":"https://cdn.test/movie.mp4"}"#,
            #"{"download":{"url":"https://cdn.test/movie.mp4"}}"#,
            #"{"download_url":"","url":"https://cdn.test/movie.mp4"}"#
        ] {
            let response = try JSONDecoder().decode(RemoteAttachmentDownloadAddress.self, from: Data(payload.utf8))
            XCTAssertEqual(response.value, "https://cdn.test/movie.mp4")
        }
    }

    @MainActor
    func testVideoPosterEndpointIsRenderableButJSONEndpointsAreRejected() throws {
        let state = AppState(api: makeClient(transport: FakeAttachmentHTTPTransport(results: [])),
                             apiContextOverride: attachmentContext(tenantID: "poster-endpoint-\(UUID())"))
        var message = makeEndpointOnlyAttachmentMessage(fileID: "poster-file")
        message.attachmentMediaCategory = "video"
        for path in ["/api/tenant/files/poster-file/poster", "https://cdn.example.test/api/tenant/files/poster-file/poster?version=2"] {
            message.attachmentPosterURL = path
            let poster = try XCTUnwrap(state.resolvedAttachmentThumbnailURL(for: message))
            XCTAssertEqual(poster.path, "/api/tenant/files/poster-file/poster")
            // A poster must not become the movie download URL.
            message.attachmentDownloadURL = path
            XCTAssertNil(state.resolvedAttachmentDownloadURL(for: message))
        }
        for path in ["/api/tenant/files/poster-file", "/api/tenant/files/poster-file/presign-download"] {
            message.attachmentPosterURL = path
            XCTAssertNil(state.resolvedAttachmentThumbnailURL(for: message))
        }
    }

    @MainActor
    func testChatVideoPosterUsesOriginalFrameInsteadOfRemoteImage() {
        let state = AppState(api: makeClient(transport: FakeAttachmentHTTPTransport(results: [])),
                             apiContextOverride: attachmentContext(tenantID: "android-poster-\(UUID())"))
        var message = makeEndpointOnlyAttachmentMessage(fileID: "android-poster")
        message.attachmentMediaCategory = "video"
        message.attachmentPosterURL = "https://cdn.test/api/tenant/files/android-poster/poster"
        XCTAssertNotNil(state.resolvedAttachmentThumbnailURL(for: message))
        XCTAssertNil(state.resolvedAttachmentBubbleThumbnailURL(for: message))
        message.attachmentMediaCategory = "image"
        XCTAssertEqual(state.resolvedAttachmentBubbleThumbnailURL(for: message)?.absoluteString, message.attachmentPosterURL)
    }

    @MainActor
    func testImageMediaEndpointsAreNotBlockedByFilesPrefix() {
        let state = AppState(api: makeClient(transport: FakeAttachmentHTTPTransport(results: [])),
                             apiContextOverride: attachmentContext(tenantID: "image-endpoints-\(UUID())"))
        var message = makeEndpointOnlyAttachmentMessage(fileID: "image-endpoints")
        message.attachmentMediaCategory = "video"
        for endpoint in ["poster", "thumbnail", "cover"] {
            let url = "https://cdn.test/api/tenant/files/image-endpoints/\(endpoint)?v=2"
            message.attachmentThumbnailURL = "/api/tenant/files/image-endpoints"
            message.attachmentPosterURL = url
            XCTAssertEqual(state.resolvedAttachmentThumbnailURL(for: message)?.absoluteString, url)
            let file = FileItem(id: "image-endpoints", name: "movie.mp4", type: "MP4", size: "1 MB", owner: "", source: "", time: "", scope: "", status: "uploaded", accentHex: 0, mediaCategory: "video", thumbnailURL: url)
            XCTAssertEqual(file.thumbnailRemoteURL?.absoluteString, url)
        }
    }

    @MainActor
    func testChecksumOnlyVideoPosterSurvivesNewAppState() async throws {
        let context = attachmentContext(tenantID: "poster-reopen-\(UUID())")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let transport = FakeAttachmentHTTPTransport(results: [])
        var message = makeEndpointOnlyAttachmentMessage(fileID: "persistent-poster")
        message.attachmentMediaCategory = "video"
        message.attachmentMimeType = "video/mp4"
        message.attachmentVersion = ""
        message.attachmentChecksum = String(repeating: "a", count: 64)
        let bytes = Data("cached-poster-content".utf8)
        let first = AppState(api: makeClient(transport: transport), messagePersistence: MessagePersistenceCoordinator(), apiContextOverride: context)
        let committed = await first.cacheUnifiedAttachmentThumbnail(bytes, for: message, conversationID: "poster-chat")
        let committedURL = try XCTUnwrap(committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedURL.path))
        let second = AppState(api: makeClient(transport: transport), messagePersistence: MessagePersistenceCoordinator(), apiContextOverride: context)
        let hit = await second.cachedUnifiedAttachmentThumbnailURL(for: message)
        XCTAssertEqual(hit, committedURL)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(hit)), bytes)
        XCTAssertTrue(transport.requests().isEmpty)
        message.attachmentChecksum = String(repeating: "b", count: 64)
        let changed = await second.cachedUnifiedAttachmentThumbnailURL(for: message)
        XCTAssertNil(changed)
    }

    // WDT_CHAT_FIX3_VIDEO_COVER_20261023_BEGIN
    @MainActor
    func testVideoThumbnailUsesServerCoverAndNeverMoviePreview() {
        let state = AppState(api: makeClient(transport: FakeAttachmentHTTPTransport(results: [])),
                             apiContextOverride: attachmentContext(tenantID: "cover-\(UUID())"))
        var message = makeEndpointOnlyAttachmentMessage(fileID: "cover-\(UUID())")
        message.attachmentMediaCategory = "video"
        message.attachmentMimeType = "video/mp4"
        message.attachmentPreviewURL = "https://cdn.example.test/movie.mp4"
        message.attachmentDownloadURL = message.attachmentPreviewURL
        XCTAssertNil(state.resolvedAttachmentThumbnailURL(for: message))
        message.attachmentPosterURL = "https://cdn.example.test/poster.jpg"
        XCTAssertEqual(state.resolvedAttachmentThumbnailURL(for: message)?.absoluteString, message.attachmentPosterURL)
        message.attachmentThumbnailURL = "https://cdn.example.test/thumbnail.jpg"
        XCTAssertEqual(state.resolvedAttachmentThumbnailURL(for: message)?.absoluteString, message.attachmentThumbnailURL)
        message.attachmentMediaCategory = "image"
        message.attachmentMimeType = "image/jpeg"
        message.attachmentThumbnailURL = ""
        message.attachmentPosterURL = ""
        message.attachmentDownloadURL = ""
        message.attachmentPreviewURL = "https://cdn.example.test/original.jpg"
        XCTAssertEqual(state.resolvedAttachmentThumbnailURL(for: message)?.absoluteString, message.attachmentPreviewURL)
    }

    @MainActor
    func testVideoCoverRecoveryOnlyFetchesMetadataAndDoesNotDownloadMovie() async {
        AttachmentDownloadURLProtocol.reset(statusCodes: [200], data: Data("movie".utf8))
        let payload = #"{"ok":true,"data":{"file":{"id":"video-cover","file_name":"movie.mp4","mime_type":"video/mp4","size_bytes":1000000,"media_category":"video","thumbnail_url":"https://cdn.example.test/fresh-cover.jpg"},"preview_available":true,"preview_url":"https://cdn.example.test/movie.mp4","download_available":true,"download_url":"https://cdn.example.test/movie.mp4"}}"#
        let transport = FakeAttachmentHTTPTransport(results: [HTTPTransportResult(data: Data(payload.utf8), isHTTPResponse: true, statusCode: 200)])
        let state = AppState(api: makeClient(transport: transport),
                             apiContextOverride: attachmentContext(tenantID: "cover-recovery-\(UUID())"),
                             attachmentDownloadSessionFactory: makeSessionFactory())
        var message = makeEndpointOnlyAttachmentMessage(fileID: "video-cover")
        message.attachmentMediaCategory = "video"
        message.attachmentMimeType = "video/mp4"
        let result = await state.refreshedAttachmentThumbnailURL(message, conversationID: "g_endpoint", forceLocalPoster: false)
        XCTAssertEqual(result?.absoluteString, "https://cdn.example.test/fresh-cover.jpg")
        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/video-cover"])
        XCTAssertTrue(AttachmentDownloadURLProtocol.recordedRequests().isEmpty)
    }
    // WDT_CHAT_FIX3_VIDEO_COVER_20261023_END

    @MainActor
    func testDownloadAliasesShareStateAndRejectCallbacksFromCancelledOwner() async throws {
        let store = FileStore()
        let first = UUID()
        let task = Task<URL, Error> { URL(fileURLWithPath: "/tmp/contract-download-test") }
        store.replaceAttachmentDownloadTask(attachmentID: "unknown-version", with: task, token: first)
        XCTAssertNil(store.coalesceAttachmentDownload(from: "unknown-version", to: "version-2", token: first))
        let progress = AttachmentDownloadSnapshot(receivedBytes: 25, totalBytes: 100)
        store.updateVisibleAttachmentDownloadProgress(progress, attachmentID: "unknown-version", token: first)
        XCTAssertNil(store.attachmentDownloadSnapshot(attachmentID: "version-2"))
        store.beginAttachmentDownloadProgress(attachmentID: "version-2")
        store.updateVisibleAttachmentDownloadProgress(progress, attachmentID: "unknown-version", token: first)
        XCTAssertEqual(store.attachmentDownloadSnapshot(attachmentID: "version-2")?.receivedBytes, 25)
        store.cancelAttachmentDownloadTask(attachmentID: "version-2")
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "unknown-version"))
        let second = UUID()
        let replacement = Task<URL, Error> { URL(fileURLWithPath: "/tmp/contract-download-test") }
        store.replaceAttachmentDownloadTask(attachmentID: "version-2", with: replacement, token: second)
        store.setAttachmentDownloadSnapshot(AttachmentDownloadSnapshot(receivedBytes: 99), attachmentID: "version-2", token: first)
        XCTAssertNil(store.attachmentDownloadSnapshot(attachmentID: "version-2"))
        store.setAttachmentDownloadSnapshot(AttachmentDownloadSnapshot(receivedBytes: 50, isCommitting: true), attachmentID: "version-2", token: second)
        store.setAttachmentDownloadSnapshot(AttachmentDownloadSnapshot(receivedBytes: 40), attachmentID: "version-2", token: second)
        XCTAssertEqual(store.attachmentDownloadSnapshot(attachmentID: "version-2")?.isCommitting, true)
        store.cancelAttachmentDownloadTasks()
        _ = try? await task.value
        _ = try? await replacement.value
    }

    func testGIFPresentationRequiresGIFIdentityAndRejectsRecalledDeletedOrOversizedMedia() {
        var message = makeEndpointOnlyAttachmentMessage()
        message.attachmentMimeType = "image/gif"
        message.attachmentSizeBytes = 10_485_760
        XCTAssertTrue(AttachmentGIFPresentation.canPlay(message))
        message.attachmentSizeBytes = 10_485_761
        XCTAssertFalse(AttachmentGIFPresentation.canPlay(message))
        message.attachmentSizeBytes = 128
        message.status = .recalled
        XCTAssertFalse(AttachmentGIFPresentation.canPlay(message))
        message.status = .read
        message.isDeletedLocally = true
        XCTAssertFalse(AttachmentGIFPresentation.canPlay(message))
        message.isDeletedLocally = false
        message.attachmentName = "animation.GIF"
        message.attachmentMimeType = "image/png"
        XCTAssertFalse(AttachmentGIFPresentation.isGIF(message))
        message.attachmentMimeType = ""
        XCTAssertTrue(AttachmentGIFPresentation.isGIF(message))
        message.attachmentMimeType = "application/octet-stream"
        XCTAssertTrue(AttachmentGIFPresentation.isGIF(message))
    }

    func testGIFPresentationSelectsOriginalAssetWithoutThumbnailFallback() throws {
        let local = URL(fileURLWithPath: "/original/animation.gif")
        let original = try XCTUnwrap(URL(string: "https://files.example.test/original.gif"))
        let preview = try XCTUnwrap(URL(string: "https://files.example.test/preview.gif"))
        XCTAssertEqual(AttachmentGIFPresentation.originalURL(localURL: local, downloadURL: original, previewURL: preview), local)
        XCTAssertEqual(AttachmentGIFPresentation.originalURL(localURL: nil, downloadURL: original, previewURL: preview), original)
        XCTAssertEqual(AttachmentGIFPresentation.originalURL(localURL: nil, downloadURL: nil, previewURL: preview), preview)
        XCTAssertNil(AttachmentGIFPresentation.originalURL(localURL: nil, downloadURL: nil, previewURL: nil))
        XCTAssertNil(AttachmentGIFPresentation.originalURL(localURL: nil, downloadURL: original, previewURL: preview, downloadAllowed: false, previewAllowed: false))
        XCTAssertEqual(AttachmentGIFPresentation.originalURL(localURL: nil, downloadURL: original, previewURL: preview, downloadAllowed: false), preview)
    }

    func testGIFBubblePreviewAndSaveUseOriginalLifecycleAwarePlayer() throws {
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
        // WDT_IOS1_REFACTOR_CHAT_ATTACHMENTS_20261109_BEGIN
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let attachmentActions = try String(contentsOf: root.appendingPathComponent("WenDaTong/App/ChatAttachmentActions.swift"), encoding: .utf8)
        let timeline = try String(contentsOf: root.appendingPathComponent("WenDaTong/App/ChatTimelineAssembly.swift"), encoding: .utf8)
        let scrollSurface = try String(contentsOf: root.appendingPathComponent("Sources/IM4Features/Chat/ChatViewTimeline.swift"), encoding: .utf8)
        let preview = try String(
            contentsOf: root.appendingPathComponent("Sources/IM4Features/ChatAttachmentPreview.swift"),
            encoding: .utf8
        ) + String(contentsOf: root.appendingPathComponent("WenDaTong/App/ChatAttachmentPreviewAssembly.swift"), encoding: .utf8) + String(contentsOf: root.appendingPathComponent("WenDaTong/App/ChatAttachmentPhotoServices.swift"), encoding: .utf8)
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
        // WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
        // WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_BEGIN
        let mediaBubbles = try String(
            contentsOf: root.appendingPathComponent("Sources/IM4Features/Chat/ChatMediaBubbleViews.swift"),
            encoding: .utf8
        ) + String(contentsOf: root.appendingPathComponent("WenDaTong/App/ChatMediaBubbleAssembly.swift"), encoding: .utf8)
            + String(contentsOf: root.appendingPathComponent("WenDaTong/App/ChatFileAttachmentAssembly.swift"), encoding: .utf8)
        // WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_END
        // WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END
        XCTAssertTrue(mediaBubbles.contains("AttachmentGIFImage(message: message, conversationID: conversationID)"))
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END
        XCTAssertTrue(preview.contains("AttachmentGIFImage(message: message, conversationID: conversationID, localURL: localURL, maxPixelSize: 1024)"))
        XCTAssertTrue(attachmentActions.contains("preferPreview: !AttachmentGIFPresentation.isGIF(message)"))
        XCTAssertTrue(timeline.contains("hidesGIFPlayback: previewImageAttachment != nil") && scrollSurface.contains(".environment(\\.stickerGIFPlaybackViewport, hidesGIFPlayback ? .zero : viewportProxy.frame(in: .global))"))
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
        XCTAssertTrue(mediaBubbles.contains("state.refreshedGIFAttachmentOriginalURL(message, conversationID: conversationID)"))
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END
        XCTAssertTrue(preview.contains("PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)"))
        // WDT_IOS1_REFACTOR_CHAT_ATTACHMENTS_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }

    override func tearDown() {
        AttachmentDownloadURLProtocol.reset()
        IMAPIContext.clearStoredSession()
        super.tearDown()
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

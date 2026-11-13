// WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110_BEGIN
import CryptoKit
import Foundation
import XCTest; import IM4DesignSystem
@testable import IM4Features // WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110
@testable import WenDaTong

final class FilePreviewTests: XCTestCase {
    // WDT_IOS1_CALL_DURATION_20261023_BEGIN
    func testCallDurationProjectionAndCachedDetailRejectUnsafeBoundaries() throws {
        XCTAssertNil(RTCCallRecordTimeProjection.exactDurationSeconds(Int.max))
        XCTAssertNil(RTCCallRecordTimeProjection.exactDurationSeconds(9_007_199_254_740_993))
        for invalid in [Double(Int.max), .nan, .infinity, -.infinity, -1, 1e100] {
            let record = CallRecord(id: "legacy", title: "peer", subtitle: "call", time: "", status: "已结束", durationSeconds: invalid)
            XCTAssertNil(RTCCallRecordTimeProjection.validatedDurationSeconds(record.durationSeconds))
            XCTAssertEqual(RTCCallRecordTimeProjection.durationText(seconds: record.durationSeconds), "未记录")
        }
        let oldRecord = CallRecord(id: "cached", title: "peer", subtitle: "call", time: "", status: "已结束", durationSeconds: Double(Int.max))
        let restored = try JSONDecoder().decode(CallRecord.self, from: JSONEncoder().encode(oldRecord))
        XCTAssertEqual(RTCCallRecordTimeProjection.durationText(seconds: restored.durationSeconds), "未记录")
        for (seconds, expected) in [(0, "0秒"), (61, "1分1秒"), (3661, "1小时1分1秒")] {
            XCTAssertEqual(RTCCallRecordTimeProjection.exactDurationSeconds(seconds), Double(seconds))
            XCTAssertEqual(RTCCallRecordTimeProjection.durationText(seconds: Double(seconds)), expected)
        }
        XCTAssertEqual(RTCCallRecordTimeProjection.durationText(seconds: 61.5), "1分2秒")
        XCTAssertEqual(RTCCallRecordTimeProjection.durationText(seconds: nil), "未记录")
        XCTAssertNotNil(RTCCallRecordTimeProjection.validatedDurationSeconds(Double(Int.max).nextDown))
    }
    // WDT_IOS1_CALL_DURATION_20261023_END

    func testAttachmentSaveUsesSemanticMediaCapabilityForLegacyMessageKind() {
        XCTAssertTrue(AttachmentSaveCapabilityPolicy.canSave(
            kind: .text,
            mediaCategory: "image",
            status: .sent,
            isDeletedLocally: false,
            hasResolvableAsset: true
        ))
        XCTAssertFalse(AttachmentSaveCapabilityPolicy.canSave(
            kind: .image,
            mediaCategory: "image",
            status: .recalled,
            isDeletedLocally: false,
            hasResolvableAsset: true
        ))
        XCTAssertFalse(AttachmentSaveCapabilityPolicy.canSave(
            kind: .image,
            mediaCategory: "image",
            status: .sent,
            isDeletedLocally: false,
            hasResolvableAsset: false
        ))
    }

    func testImagePreviewDismissalGesturesWorkInPortraitAndLandscape() {
        let portrait = CGSize(width: 390, height: 844)
        XCTAssertEqual(
            IM4DesignSystem.AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                startLocation: CGPoint(x: 195, y: 240),
                translation: CGSize(width: 2, height: 110),
                predictedEndTranslation: CGSize(width: 4, height: 150),
                viewportSize: portrait,
                scale: 1
            ),
            .downwardSwipe
        )
        XCTAssertEqual(
            IM4DesignSystem.AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                startLocation: CGPoint(x: 18, y: 420),
                translation: CGSize(width: 110, height: 2),
                predictedEndTranslation: CGSize(width: 150, height: 4),
                viewportSize: portrait,
                scale: 1
            ),
            .leadingEdgeSwipe
        )

        let landscape = CGSize(width: 844, height: 390)
        XCTAssertEqual(
            IM4DesignSystem.AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                startLocation: CGPoint(x: 18, y: 190),
                translation: CGSize(width: 150, height: 3),
                predictedEndTranslation: CGSize(width: 190, height: 4),
                viewportSize: landscape,
                scale: 1
            ),
            .leadingEdgeSwipe
        )
        XCTAssertEqual(
            IM4DesignSystem.AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                startLocation: CGPoint(x: 422, y: 120),
                translation: CGSize(width: 2, height: 90),
                predictedEndTranslation: CGSize(width: 4, height: 120),
                viewportSize: landscape,
                scale: 1
            ),
            .downwardSwipe
        )
    }

    func testImagePreviewDismissalPreservesZoomGestures() {
        let viewport = CGSize(width: 390, height: 844)
        XCTAssertNil(
            IM4DesignSystem.AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                startLocation: CGPoint(x: 18, y: 190),
                translation: CGSize(width: 180, height: 0),
                predictedEndTranslation: CGSize(width: 220, height: 0),
                viewportSize: viewport,
                scale: 2
            )
        )
        XCTAssertEqual(
            IM4DesignSystem.AttachmentImagePreviewDismissalPolicy.interactiveOffset(
                startLocation: CGPoint(x: 180, y: 200),
                translation: CGSize(width: 0, height: 180),
                viewportSize: viewport,
                scale: 2
            ),
            .zero
        )
    }

    func testImagePreviewCloseAndAccessibilityEscapeAreIdempotent() {
        var closeCoordinator = IM4DesignSystem.AttachmentImagePreviewDismissalCoordinator()
        XCTAssertTrue(closeCoordinator.request(.closeButton))
        XCTAssertFalse(closeCoordinator.request(.downwardSwipe))
        XCTAssertEqual(closeCoordinator.acceptedTrigger, .closeButton)

        var accessibilityCoordinator = IM4DesignSystem.AttachmentImagePreviewDismissalCoordinator()
        XCTAssertTrue(accessibilityCoordinator.request(.accessibilityEscape))
        XCTAssertEqual(accessibilityCoordinator.acceptedTrigger, .accessibilityEscape)
    }

    func testImagePreviewRepeatedOpenCloseDismissesOncePerPresentation() {
        for cycle in 0..<50 {
            var coordinator = IM4DesignSystem.AttachmentImagePreviewDismissalCoordinator()
            let trigger: IM4DesignSystem.AttachmentImagePreviewDismissalTrigger = cycle.isMultiple(of: 2) ? .closeButton : .accessibilityEscape
            XCTAssertTrue(coordinator.request(trigger))
            XCTAssertFalse(coordinator.request(.downwardSwipe))
            XCTAssertEqual(coordinator.acceptedTrigger, trigger)
        }
    }

    func testImagePreviewPresentationPreservesOriginAndExposesPermanentDismissalControls() throws {
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
        // WDT_IOS1_REFACTOR_CHAT_ATTACHMENTS_20261109_BEGIN
        let testFile = URL(fileURLWithPath: #filePath)
        let source = try String(
            contentsOf: testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("WenDaTong/ChatViews.swift"),
            encoding: .utf8
        )

        let layout = try String(
            contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/IM4Features/Chat/ChatViewLayout.swift"),
            encoding: .utf8
        ) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/IM4Features/Chat/ChatConversationSheets.swift"), encoding: .utf8) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WenDaTong/App/ChatPresentationAssembly.swift"), encoding: .utf8) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WenDaTong/App/ChatTranscriptLayoutAssembly.swift"), encoding: .utf8)
        let previewFile = try String(
            contentsOf: testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/IM4Features/ChatAttachmentPreview.swift"),
            encoding: .utf8
        ) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WenDaTong/App/ChatAttachmentPreviewAssembly.swift"), encoding: .utf8) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WenDaTong/App/ChatAttachmentPhotoServices.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("@State var previewImageAttachment: AttachmentMediaPreviewItem?"))
        XCTAssertTrue(layout.contains(".fullScreenCover(item: $previewImageAttachment) { item in"))
        XCTAssertTrue(previewFile.contains(".accessibilityAction(.escape)"))
        XCTAssertTrue(previewFile.contains("attachment_image_preview_close_button"))
        XCTAssertTrue(previewFile.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertFalse(source.contains("@State private var controlsVisible = false") || layout.contains("@State private var controlsVisible = false"))
        XCTAssertFalse(previewFile.contains("@State private var controlsVisible = false"))

        let previewStart = try XCTUnwrap(previewFile.range(of: "struct AttachmentImagePreviewSheet: View"))
        let previewEnd = try XCTUnwrap(
            previewFile.range(
                of: "struct AttachmentVideoPreviewSheet: View",
                range: previewStart.upperBound..<previewFile.endIndex
            )
        )
        let previewSource = previewFile[previewStart.lowerBound..<previewEnd.lowerBound]
        XCTAssertFalse(previewSource.contains("scrollTo("))
        XCTAssertFalse(previewSource.contains("resetScrollPositionState"))
        // WDT_IOS1_REFACTOR_CHAT_ATTACHMENTS_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }

    func testFileItemSystemPreviewFallsBackToDownloadURLWhenPreviewIsAttachmentOnly() throws {
        let file = makeFileItem(
            name: "group-local.txt",
            type: "TXT",
            downloadURL: "https://files.example.test/download/group-local.txt",
            downloadAvailable: true,
            mediaCategory: "file",
            mimeType: "text/plain",
            fileExtension: "txt",
            previewKind: "download",
            contentDisposition: "attachment"
        )

        XCTAssertNil(file.bestPreviewURL)
        XCTAssertEqual(file.systemPreviewRemoteURL?.absoluteString, "https://files.example.test/download/group-local.txt")
        XCTAssertTrue(file.canAttemptSystemPreview)
    }

    func testFileItemSystemPreviewKeepsUnsupportedArchiveInDetailFlow() {
        let file = makeFileItem(
            name: "archive.zip",
            type: "ZIP",
            downloadURL: "https://files.example.test/download/archive.zip",
            downloadAvailable: true,
            mediaCategory: "file",
            mimeType: "application/zip",
            fileExtension: "zip"
        )

        XCTAssertNil(file.systemPreviewRemoteURL)
        XCTAssertFalse(file.canAttemptSystemPreview)
    }

    func testFileItemImageThumbnailUsesPreviewURLWhenNoExplicitThumbnail() {
        let file = makeFileItem(
            name: "图片消息.jpeg",
            type: "图片",
            previewURL: "https://files.example.test/image-preview.jpg",
            downloadURL: "https://files.example.test/image-original.jpg",
            previewAvailable: true,
            downloadAvailable: true,
            mediaCategory: "image",
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )

        XCTAssertEqual(file.thumbnailRemoteURL?.absoluteString, "https://files.example.test/image-preview.jpg")
        XCTAssertNil(file.videoFrameRemoteURL)
    }

    func testFileItemImageThumbnailFallsBackToDownloadURL() {
        let file = makeFileItem(
            name: "图片消息.jpeg",
            type: "图片",
            downloadURL: "https://files.example.test/image-original.jpg",
            previewAvailable: false,
            downloadAvailable: true,
            mediaCategory: "image",
            mimeType: "image/jpeg",
            fileExtension: "jpg",
            contentDisposition: "attachment"
        )

        XCTAssertEqual(file.thumbnailRemoteURL?.absoluteString, "https://files.example.test/image-original.jpg")
    }

    func testFileItemVideoThumbnailUsesPosterBeforeFrameURL() {
        let file = makeFileItem(
            name: "meeting.mp4",
            type: "视频",
            downloadURL: "https://files.example.test/video.mp4",
            downloadAvailable: true,
            mediaCategory: "video",
            mimeType: "video/mp4",
            fileExtension: "mp4",
            posterURL: "https://files.example.test/video-poster.jpg"
        )

        XCTAssertEqual(file.thumbnailRemoteURL?.absoluteString, "https://files.example.test/video-poster.jpg")
        XCTAssertEqual(file.videoFrameRemoteURL?.absoluteString, "https://files.example.test/video.mp4")
    }

    func testFileItemVideoFrameURLFiltersTenantEndpoint() {
        let file = makeFileItem(
            name: "meeting.mp4",
            type: "视频",
            previewURL: "/api/tenant/files/video-1",
            downloadURL: "/api/tenant/files/video-1/presign-download",
            downloadAvailable: true,
            mediaCategory: "video",
            mimeType: "video/mp4",
            fileExtension: "mp4"
        )

        XCTAssertNil(file.thumbnailRemoteURL)
        XCTAssertNil(file.videoFrameRemoteURL)
    }

    func testFileItemMediaThumbnailCacheKeyIgnoresSignedQueryChanges() {
        var first = makeFileItem(
            name: "图片消息.jpeg",
            type: "图片",
            previewURL: "https://cdn.example.test/file-1.jpg?auth_key=first",
            previewAvailable: true,
            downloadAvailable: true,
            mediaCategory: "image",
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )
        first.remoteFileID = "file-1"
        var second = first
        second.previewURL = "https://cdn.example.test/file-1.jpg?auth_key=second"

        let firstKey = first.mediaThumbnailCacheKey(for: .image)
        let secondKey = second.mediaThumbnailCacheKey(for: .image)

        XCTAssertEqual(firstKey, secondKey)
        XCTAssertTrue(firstKey.contains("file-1"))
        XCTAssertFalse(firstKey.contains("auth_key"))
    }

    func testSystemPreviewCacheIdentityPrefersStableFileID() {
        var first = makeFileItem(
            name: "report.pdf",
            type: "PDF",
            previewURL: "https://cdn.example.test/file-preview.pdf?auth_key=first",
            downloadURL: "https://cdn.example.test/file-preview.pdf?auth_key=download-first",
            previewAvailable: true,
            downloadAvailable: true,
            mediaCategory: "document",
            mimeType: "application/pdf",
            fileExtension: "pdf"
        )
        first.remoteFileID = "file-preview-stable"
        var second = first
        second.previewURL = "https://cdn.example.test/file-preview.pdf?auth_key=second"
        second.downloadURL = "https://cdn.example.test/file-preview.pdf?auth_key=download-second"

        let firstKey = first.systemPreviewCacheIdentity(scope: "tenant-a|user-a")
        let secondKey = second.systemPreviewCacheIdentity(scope: "tenant-a|user-a")

        XCTAssertEqual(firstKey, secondKey)
        XCTAssertTrue(firstKey?.contains("file_id:file-preview-stable") == true)
        XCTAssertFalse(firstKey?.contains("auth_key") == true)
    }

    func testFilesMediaIdentityUsesRemoteLookupIDAndRejectsLocalSyntheticFallback() throws {
        var remote = makeFileItem(
            name: "remote-report.pdf",
            type: "PDF",
            mediaCategory: "document",
            mimeType: "application/pdf",
            fileExtension: "pdf"
        )
        remote.remoteFileID = "authoritative-file-id"
        let scopeHash = String(repeating: "a", count: 64)
        let remoteMetadata = remote.mediaResourceMetadata(scope: scopeHash)
        let remoteIdentity = remoteMetadata.identity(for: .original)
        XCTAssertEqual(remoteMetadata.fileID, "authoritative-file-id")
        XCTAssertEqual(remoteIdentity.resourceIDKind, .fileID)
        XCTAssertEqual(remoteIdentity.primaryStableID, "authoritative-file-id")
        XCTAssertNotNil(remoteIdentity.persistentCacheIdentity)

        let local = makeFileItem(
            id: "local-attachment|pending-upload",
            name: "pending.pdf",
            type: "PDF",
            mediaCategory: "document",
            mimeType: "application/pdf",
            fileExtension: "pdf"
        )
        let localMetadata = local.mediaResourceMetadata(scope: scopeHash)
        XCTAssertTrue(localMetadata.fileID.isEmpty)
        XCTAssertTrue(localMetadata.cacheKey.isEmpty)
        XCTAssertNil(localMetadata.identity(for: .original).persistentCacheIdentity)
    }

    @MainActor
    func testIndexedMediaCommitRejectsMissingRequesterBeforeWriting() async throws {
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "requester-account",
            tenantID: "requester-tenant-\(UUID().uuidString)",
            imUID: "requester-user",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "requester-device"
        )
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(scope: scope)
        defer { try? paths.purgeExactScope() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-requester-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.bin")
        try Data("requester-bytes".utf8).write(to: sourceURL, options: .atomic)
        let state = AppState(
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")
            ),
            apiContextOverride: context
        )
        let cacheContext = try XCTUnwrap(state.mediaCacheScopeContext)
        let metadata = MediaResourceMetadata(
            scope: cacheContext.scopeHash,
            fileID: "requester-file",
            version: "v1",
            mimeType: "application/octet-stream",
            fileName: "requester.bin",
            fileExtension: "bin"
        )
        let destination = metadata.identity(for: .original).cacheFileURL(
            in: cacheContext.rootDirectory,
            preferredExtension: "bin"
        )

        do {
            _ = try await state.commitIndexedMediaCache(
                temporaryURL: sourceURL,
                metadata: metadata,
                resourceKind: .original,
                integrity: MediaFileIntegrityAuthority(),
                messageID: "",
                conversationID: "__files__",
                context: cacheContext
            )
            XCTFail("missing requester must fail closed")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .identityConflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testExistingScopedFilesPreviewLazilyMigratesIntoSharedIndexedStore() async throws {
        let payload = Data("existing-files-preview-\(UUID().uuidString)".utf8)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", Int($0)) }.joined()
        var file = makeFileItem(
            name: "existing-preview.pdf",
            type: "PDF",
            previewURL: "https://cdn.example.test/existing-preview.pdf?auth_key=old",
            previewAvailable: true,
            downloadAvailable: true,
            mediaCategory: "document",
            mimeType: "application/pdf",
            fileExtension: "pdf"
        )
        file.sizeBytes = Int64(payload.count)
        file.checksum = checksum
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "files-account",
            tenantID: "files-tenant-\(UUID().uuidString)",
            imUID: "files-user",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "files-device"
        )
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(scope: scope)
        defer { try? paths.purgeExactScope() }
        let databaseRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-preview-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: databaseRoot) }
        let state = AppState(
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: databaseRoot.appendingPathComponent("support"),
                cachesBase: databaseRoot.appendingPathComponent("caches")
            ),
            apiContextOverride: context
        )
        let cacheContext = try XCTUnwrap(state.mediaCacheScopeContext)
        let metadata = file.mediaResourceMetadata(scope: cacheContext.scopeHash)
        let legacyURL = FilesPreviewCacheAdapter.legacyURL(
            file: file,
            resourceKind: file.mediaPipelinePreviewResourceKind,
            scope: state.contentCacheScopeKey,
            preferredExtension: metadata.preferredExtension(for: file.mediaPipelinePreviewResourceKind)
        )
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: legacyURL, options: .atomic)

        let offlineCandidate = await FilesPreviewCacheAdapter.cachedPreviewURL(
            for: file,
            state: state,
            context: cacheContext
        )
        XCTAssertNil(offlineCandidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        let migratedCandidate = await FilesPreviewCacheAdapter.migrateAuthorizedLegacyPreview(
            for: file,
            state: state,
            context: cacheContext
        )
        let migrated = try XCTUnwrap(migratedCandidate)
        XCTAssertEqual(try Data(contentsOf: migrated), payload)
        XCTAssertTrue(migrated.path.contains("/BlueStoneIM/Media/\(scope.scopeHash)/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let indexedAgain = await FilesPreviewCacheAdapter.cachedPreviewURL(
            for: file,
            state: state,
            context: cacheContext
        )
        XCTAssertEqual(indexedAgain?.standardizedFileURL, migrated.standardizedFileURL)
    }

    @MainActor
    func testIndexedCacheRecordsLocalChecksumWhenServerChecksumIsAbsent() async throws {
        let original = Data("local-checksum-a".utf8)
        let corrupted = Data("local-checksum-b".utf8)
        XCTAssertEqual(original.count, corrupted.count)
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "checksum-account",
            tenantID: "checksum-tenant-\(UUID().uuidString)",
            imUID: "checksum-user",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "checksum-device"
        )
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(scope: scope)
        defer { try? paths.purgeExactScope() }
        let databaseRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-checksum-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: databaseRoot) }
        let sourceURL = databaseRoot.appendingPathComponent("source.bin", isDirectory: false)
        try FileManager.default.createDirectory(at: databaseRoot, withIntermediateDirectories: true)
        try original.write(to: sourceURL, options: .atomic)
        let state = AppState(
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: databaseRoot.appendingPathComponent("support"),
                cachesBase: databaseRoot.appendingPathComponent("caches")
            ),
            apiContextOverride: context
        )
        let cacheContext = try XCTUnwrap(state.mediaCacheScopeContext)
        let metadata = MediaResourceMetadata(
            scope: cacheContext.scopeHash,
            fileID: "file-local-checksum",
            version: "v1",
            mimeType: "application/octet-stream",
            sizeBytes: Int64(original.count),
            fileName: "local-checksum.bin",
            fileExtension: "bin"
        )

        let committed = try await state.commitIndexedMediaCache(
            temporaryURL: sourceURL,
            metadata: metadata,
            resourceKind: .original,
            integrity: MediaFileIntegrityAuthority(expectedSizeBytes: Int64(original.count)),
            messageID: "message-local-checksum",
            conversationID: "conversation-local-checksum",
            context: cacheContext
        )
        try corrupted.write(to: committed, options: .atomic)

        let lookup = await state.lookupIndexedMediaCache(
            metadata: metadata,
            messageID: "message-local-checksum",
            resourceKind: .original,
            integrity: MediaFileIntegrityAuthority(expectedSizeBytes: Int64(original.count)),
            context: cacheContext,
            offline: false
        )
        XCTAssertNil(lookup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
    }

    private func makeFileItem(
        id: String? = nil,
        name: String,
        type: String,
        previewURL: String = "",
        downloadURL: String = "",
        previewAvailable: Bool = false,
        downloadAvailable: Bool = false,
        mediaCategory: String = "",
        mimeType: String = "",
        fileExtension: String = "",
        thumbnailURL: String = "",
        posterURL: String = "",
        coverURL: String = "",
        previewKind: String = "",
        contentDisposition: String = ""
    ) -> FileItem {
        FileItem(
            id: id ?? "file-\(name)",
            name: name,
            type: type,
            size: "1 KB",
            sizeBytes: 1024,
            owner: "admin5",
            source: "交易通知群",
            time: "刚刚",
            scope: "群文件",
            status: "可查看",
            accentHex: 0x5D6BFF,
            previewURL: previewURL,
            downloadURL: downloadURL,
            previewAvailable: previewAvailable,
            downloadAvailable: downloadAvailable,
            channelID: "g1",
            channelType: "group",
            mediaCategory: mediaCategory,
            mimeType: mimeType,
            cacheKey: "cache-\(name)",
            version: "v1",
            checksum: "",
            fileExtension: fileExtension,
            thumbnailURL: thumbnailURL,
            posterURL: posterURL,
            coverURL: coverURL,
            previewKind: previewKind,
            contentDisposition: contentDisposition
        )
    }
}
// WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110_END

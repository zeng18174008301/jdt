import CryptoKit
import Foundation
import XCTest
@testable import BlueStoneIM

final class AttachmentDownloadTests: XCTestCase {
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
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BlueStoneIM/ChatViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("AttachmentGIFImage(message: message, conversationID: conversationID)"))
        XCTAssertTrue(source.contains("AttachmentGIFImage(message: message, conversationID: conversationID, localURL: localURL, maxPixelSize: 1024)"))
        XCTAssertTrue(source.contains("preferPreview: !AttachmentGIFPresentation.isGIF(message)"))
        XCTAssertTrue(source.contains(".environment(\\.stickerGIFPlaybackViewport, previewImageAttachment == nil ? viewportProxy.frame(in: .global) : .zero)"))
        XCTAssertTrue(source.contains("state.refreshedGIFAttachmentOriginalURL(message, conversationID: conversationID)"))
        XCTAssertTrue(source.contains("PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)"))
    }

    override func tearDown() {
        AttachmentDownloadURLProtocol.reset()
        IMAPIContext.clearStoredSession()
        super.tearDown()
    }

    func testAttachmentDownloadCachePolicyBuildsStableSanitizedDestination() throws {
        let firstRemoteURL = try XCTUnwrap(URL(string: "https://files.example.test/raw/report"))
        let secondRemoteURL = try XCTUnwrap(URL(string: "https://files.example.test/other/report"))

        let firstURL = try AttachmentDownloadCachePolicy.destinationURL(
            remoteURL: firstRemoteURL,
            suggestedName: " unsafe/name ",
            cacheKey: " stable-cache-key ",
            fallbackExtension: "pdf"
        )
        let secondURL = try AttachmentDownloadCachePolicy.destinationURL(
            remoteURL: secondRemoteURL,
            suggestedName: " unsafe/name ",
            cacheKey: " stable-cache-key ",
            fallbackExtension: "pdf"
        )
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
        }

        XCTAssertEqual(firstURL.deletingLastPathComponent(), secondURL.deletingLastPathComponent())
        XCTAssertEqual(firstURL.lastPathComponent, "unsafe-name.pdf")
    }

    func testAttachmentDownloadCachePolicyFallsBackToRemoteExtensionAndDefaultName() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://files.example.test/image/photo.jpg?token=redacted"))

        let destination = try AttachmentDownloadCachePolicy.destinationURL(
            remoteURL: remoteURL,
            suggestedName: "   ",
            cacheKey: "",
            fallbackExtension: ""
        )
        defer {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        XCTAssertEqual(destination.lastPathComponent, "attachment-file.jpg")
    }

    func testAttachmentDownloadCachePolicyReusesOnlyNonEmptyExpectedSizeMatches() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-download-cache-\(UUID().uuidString)", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let payload = Data("cached-attachment".utf8)
        try payload.write(to: cacheURL, options: .atomic)

        XCTAssertTrue(AttachmentDownloadCachePolicy.canReuseCachedDownload(at: cacheURL, expectedSizeBytes: nil))
        XCTAssertTrue(AttachmentDownloadCachePolicy.canReuseCachedDownload(at: cacheURL, expectedSizeBytes: Int64(payload.count)))
        XCTAssertFalse(AttachmentDownloadCachePolicy.canReuseCachedDownload(at: cacheURL, expectedSizeBytes: Int64(payload.count + 1)))

        try FileManager.default.removeItem(at: cacheURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: cacheURL.path, contents: Data()))
        XCTAssertFalse(AttachmentDownloadCachePolicy.canReuseCachedDownload(at: cacheURL, expectedSizeBytes: nil))
    }

    func testAttachmentDownloadProgressDelegateUsesInjectedSessionAndStoresDownload() async throws {
        let payload = Data("downloaded-attachment".utf8)
        AttachmentDownloadURLProtocol.reset(statusCode: 200, data: payload)
        let remoteURL = try XCTUnwrap(URL(string: "https://attachment.example.test/download/file.txt"))
        let cacheKey = "stage65-success-\(UUID().uuidString)"
        let destination = try AttachmentDownloadCachePolicy.destinationURL(
            remoteURL: remoteURL,
            suggestedName: "downloaded file",
            cacheKey: cacheKey,
            fallbackExtension: "txt"
        )
        defer {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }
        let progress = AttachmentDownloadProgressRecorder()
        let downloader = AttachmentDownloadProgressDelegate(
            suggestedName: "downloaded file",
            cacheKey: cacheKey,
            fallbackExtension: "txt",
            expectedSizeBytes: Int64(payload.count),
            sessionFactory: makeSessionFactory()
        ) { fraction in
            progress.record(fraction)
        }

        let localURL = try await downloader.start(remoteURL: remoteURL)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        XCTAssertNotEqual(localURL, destination)
        XCTAssertTrue(localURL.path.contains("/BlueStoneIMAttachmentDownloadStaging/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: localURL), payload)
        XCTAssertEqual(AttachmentDownloadURLProtocol.recordedRequests().map(\.url), [remoteURL])
        let progressValues = progress.snapshot()
        XCTAssertEqual(progressValues.first, 0.02)
        XCTAssertEqual(progressValues.last, 1)
    }

    func testAttachmentDownloadProgressDelegateRejectsHTTPFailureWithoutSavingFile() async throws {
        AttachmentDownloadURLProtocol.reset(statusCode: 404, data: Data("missing".utf8))
        let remoteURL = try XCTUnwrap(URL(string: "https://attachment.example.test/download/missing.bin"))
        let cacheKey = "stage65-missing-\(UUID().uuidString)"
        let destination = try AttachmentDownloadCachePolicy.destinationURL(
            remoteURL: remoteURL,
            suggestedName: "missing",
            cacheKey: cacheKey,
            fallbackExtension: "bin"
        )
        defer {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }
        let downloader = AttachmentDownloadProgressDelegate(
            suggestedName: "missing",
            cacheKey: cacheKey,
            fallbackExtension: "bin",
            expectedSizeBytes: nil,
            sessionFactory: makeSessionFactory()
        ) { _ in }

        do {
            _ = try await downloader.start(remoteURL: remoteURL)
            XCTFail("Expected HTTP failure")
        } catch let error as AttachmentDownloadHTTPStatusError {
            XCTAssertEqual(error.statusCode, 404)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(AttachmentDownloadURLProtocol.recordedRequests().map(\.url), [remoteURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAttachmentDownloadProgressDelegateDoesNotReuseUnscopedLegacyCache() async throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://attachment.example.test/download/cached.pdf"))
        let payload = Data("cached-download".utf8)
        AttachmentDownloadURLProtocol.reset(statusCode: 200, data: payload)
        let cacheKey = "stage65-cached-\(UUID().uuidString)"
        let destination = try AttachmentDownloadCachePolicy.destinationURL(
            remoteURL: remoteURL,
            suggestedName: "cached",
            cacheKey: cacheKey,
            fallbackExtension: "pdf"
        )
        defer {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: destination)
        let progress = AttachmentDownloadProgressRecorder()
        let sessionFactory = AttachmentDownloadSessionFactoryCounter()
        let downloader = AttachmentDownloadProgressDelegate(
            suggestedName: "cached",
            cacheKey: cacheKey,
            fallbackExtension: "pdf",
            expectedSizeBytes: Int64(payload.count),
            sessionFactory: sessionFactory.makeFactory()
        ) { fraction in
            progress.record(fraction)
        }

        let localURL = try await downloader.start(remoteURL: remoteURL)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        XCTAssertNotEqual(localURL, destination)
        XCTAssertEqual(sessionFactory.count(), 1)
        XCTAssertEqual(try Data(contentsOf: localURL), payload)
        XCTAssertEqual(progress.snapshot().first, 0.02)
        XCTAssertEqual(progress.snapshot().last, 1)
        XCTAssertEqual(AttachmentDownloadURLProtocol.recordedRequests().map(\.url), [remoteURL])
    }

    @MainActor
    func testAppStateRefreshesEndpointOnlyAttachmentBeforeDownload() async throws {
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("endpoint-only-attachment-\(UUID().uuidString).md")
        try Data("signed-detail-file".utf8).write(to: localFile, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: localFile)
        }
        let transport = FakeAttachmentHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("""
                {
                  "ok": true,
                  "data": {
                    "file": {
                      "id": "file-endpoint",
                      "file_name": "README.md",
                      "mime_type": "text/markdown",
                      "size_bytes": 18,
                      "uploader_uid": "uid-2",
                      "status": "uploaded",
                      "media_category": "document",
                      "extension": "md"
                    },
                    "preview_available": false,
                    "download_available": true,
                    "download_url": "\(localFile.absoluteString)"
                  }
                }
                """.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        saveAttachmentTestContext()
        let client = makeClient(transport: transport)
        let state = AppState(api: client)
        var message = makeEndpointOnlyAttachmentMessage()

        XCTAssertEqual(message.attachmentFileID, "file-endpoint")
        XCTAssertEqual(message.attachmentDownloadURL, "/api/tenant/files/file-endpoint/presign-download")
        XCTAssertEqual(message.attachmentPreviewURL, "/api/tenant/files/file-endpoint")
        XCTAssertNil(state.resolvedAttachmentDownloadURL(for: message))
        let localURL = try await state.prepareMessageAttachmentLocalFile(message, conversationID: "g_endpoint", preferPreview: false)

        XCTAssertEqual(localURL, localFile)
        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/file-endpoint"])
        message.attachmentDownloadURL = "/api/tenant/files/file-endpoint/presign-download"
        XCTAssertEqual(state.resolvedAttachmentDownloadURL(for: message), localFile)
    }

    @MainActor
    func testAppStateSigned403RefreshesTenantFileOnceThenDownloads() async throws {
        let fileID = "file-oss-recovery-\(UUID().uuidString)"
        let payload = Data("restored-from-new-oss".utf8)
        let expiredURL = try XCTUnwrap(URL(string: "https://cdn.example.test/\(fileID).bin?auth_key=expired"))
        let refreshedURL = try XCTUnwrap(URL(string: "https://cdn.example.test/\(fileID).bin?auth_key=fresh"))
        AttachmentDownloadURLProtocol.reset(statusCodes: [403, 200], data: payload)
        let transport = FakeAttachmentHTTPTransport(results: [
            tenantFileResult(fileID: fileID, downloadURL: expiredURL, sizeBytes: payload.count, checksum: sha256(payload)),
            tenantFileResult(fileID: fileID, downloadURL: refreshedURL, sizeBytes: payload.count, checksum: sha256(payload))
        ])
        saveAttachmentTestContext()
        let state = AppState(
            api: makeClient(transport: transport),
            attachmentDownloadSessionFactory: makeSessionFactory()
        )

        let localURL = try await state.prepareMessageAttachmentLocalFile(
            makeEndpointOnlyAttachmentMessage(fileID: fileID),
            conversationID: "g_endpoint",
            preferPreview: false
        )
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        XCTAssertEqual(try Data(contentsOf: localURL), payload)
        XCTAssertEqual(transport.requests().map { $0.url?.path }, [
            "/api/tenant/files/\(fileID)",
            "/api/tenant/files/\(fileID)"
        ])
        XCTAssertEqual(AttachmentDownloadURLProtocol.recordedRequests().map(\.url), [expiredURL, refreshedURL])
    }

    @MainActor
    func testAppStateStopsAfterRefreshedSignedURLStillReturns403() async throws {
        let fileID = "file-oss-bounded-\(UUID().uuidString)"
        let expiredURL = try XCTUnwrap(URL(string: "https://cdn.example.test/\(fileID).bin?auth_key=expired"))
        let refreshedURL = try XCTUnwrap(URL(string: "https://cdn.example.test/\(fileID).bin?auth_key=still-invalid"))
        AttachmentDownloadURLProtocol.reset(statusCodes: [403, 403], data: Data("forbidden".utf8))
        let transport = FakeAttachmentHTTPTransport(results: [
            tenantFileResult(fileID: fileID, downloadURL: expiredURL, sizeBytes: 9),
            tenantFileResult(fileID: fileID, downloadURL: refreshedURL, sizeBytes: 9)
        ])
        saveAttachmentTestContext()
        let state = AppState(
            api: makeClient(transport: transport),
            attachmentDownloadSessionFactory: makeSessionFactory()
        )

        do {
            _ = try await state.prepareMessageAttachmentLocalFile(
                makeEndpointOnlyAttachmentMessage(fileID: fileID),
                conversationID: "g_endpoint",
                preferPreview: false
            )
            XCTFail("Expected the bounded retry to stop")
        } catch let error as AttachmentDownloadHTTPStatusError {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertEqual(error.requestURL, refreshedURL)
        }

        XCTAssertEqual(transport.requests().count, 2)
        XCTAssertEqual(AttachmentDownloadURLProtocol.recordedRequests().map(\.url), [expiredURL, refreshedURL])
    }

    @MainActor
    func testAppStateTenantAPI401DoesNotTriggerSignedURLRefresh() async throws {
        let fileID = "file-login-401-\(UUID().uuidString)"
        let transport = FakeAttachmentHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"unauthorized","message":"session expired"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            )
        ])
        saveAttachmentTestContext()
        let state = AppState(
            api: makeClient(transport: transport),
            attachmentDownloadSessionFactory: makeSessionFactory()
        )

        do {
            _ = try await state.prepareMessageAttachmentLocalFile(
                makeEndpointOnlyAttachmentMessage(fileID: fileID),
                conversationID: "g_endpoint",
                preferPreview: false
            )
            XCTFail("Expected login authentication failure")
        } catch {
            XCTAssertFalse(error is AttachmentDownloadHTTPStatusError)
        }

        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/\(fileID)"])
        XCTAssertTrue(AttachmentDownloadURLProtocol.recordedRequests().isEmpty)
    }

    @MainActor
    func testUnscopedLegacyDownloadMigratesOnlyAfterOnlineScopedValidation() async throws {
        let payload = Data("authorized-legacy-migration-\(UUID().uuidString)".utf8)
        let fileID = "file-legacy-migration-\(UUID().uuidString)"
        let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.test/\(fileID).bin?auth_key=fresh"))
        let context = attachmentContext(tenantID: "tenant-online-\(UUID().uuidString)")
        let scope = try LocalMessageScope(context: context)
        let mediaPaths = try MessageDatabasePaths(scope: scope)
        defer { try? mediaPaths.purgeExactScope() }
        let legacyDirectory = try AttachmentDownloadCachePolicy.legacyRootURL()
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("foreign.bin", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try payload.write(to: legacyURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-migration-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeAttachmentHTTPTransport(results: [
            tenantFileResult(
                fileID: fileID,
                downloadURL: remoteURL,
                sizeBytes: payload.count,
                checksum: sha256(payload)
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")
            ),
            apiContextOverride: context,
            attachmentDownloadSessionFactory: makeSessionFactory()
        )

        let migrated = try await state.prepareMessageAttachmentLocalFile(
            makeEndpointOnlyAttachmentMessage(fileID: fileID),
            conversationID: "g_legacy",
            preferPreview: false
        )

        XCTAssertEqual(try Data(contentsOf: migrated), payload)
        XCTAssertTrue(migrated.path.contains("/BlueStoneIM/Media/\(scope.scopeHash)/"))
        XCTAssertFalse(migrated.path.contains("BlueStoneIMAttachmentDownloads"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/\(fileID)"])
        XCTAssertTrue(AttachmentDownloadURLProtocol.recordedRequests().isEmpty)
    }

    @MainActor
    func testUnscopedLegacyDownloadIsNotAnOfflineCrossTenantHit() async throws {
        let payload = Data("foreign-tenant-legacy-\(UUID().uuidString)".utf8)
        let legacyDirectory = try AttachmentDownloadCachePolicy.legacyRootURL()
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("foreign.bin", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try payload.write(to: legacyURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        let transport = FakeAttachmentHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"unauthorized","message":"offline"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            )
        ])
        let context = attachmentContext(tenantID: "different-tenant-\(UUID().uuidString)")
        let paths = try MessageDatabasePaths(scope: LocalMessageScope(context: context))
        defer { try? paths.purgeExactScope() }
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: context,
            attachmentDownloadSessionFactory: makeSessionFactory()
        )

        do {
            _ = try await state.prepareMessageAttachmentLocalFile(
                makeEndpointOnlyAttachmentMessage(fileID: "foreign-file"),
                conversationID: "g_foreign",
                preferPreview: false
            )
            XCTFail("unscoped legacy bytes must not be returned before online authority succeeds")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/foreign-file"])
    }

    @MainActor
    func testAttachmentStableCacheKeyIgnoresSignedQueryChanges() {
        saveAttachmentTestContext()
        let state = AppState(api: makeClient(transport: FakeAttachmentHTTPTransport(results: [])))
        var first = makeEndpointOnlyAttachmentMessage(fileID: "file-stable")
        first.attachmentVersion = "v2"
        first.attachmentCacheKey = "objects/file-stable"
        first.attachmentThumbnailURL = "https://cdn.example.test/file-stable.jpg?auth_key=first"
        var second = first
        second.attachmentThumbnailURL = "https://cdn.example.test/file-stable.jpg?auth_key=second"
        second.attachmentDownloadURL = "https://cdn.example.test/file-stable.jpg?auth_key=other"

        let firstKey = state.attachmentThumbnailCacheKey(for: first)
        let secondKey = state.attachmentThumbnailCacheKey(for: second)

        XCTAssertEqual(firstKey, secondKey)
        XCTAssertTrue(firstKey.contains("file_id:file-stable"))
        XCTAssertFalse(firstKey.contains("auth_key"))
    }

    @MainActor
    func testAppStateEndpointOnlyAttachmentFileNotFoundUsesStableChineseError() async throws {
        let transport = FakeAttachmentHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"file_not_found","message":"file_not_found"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 404
            )
        ])
        saveAttachmentTestContext()
        let state = AppState(api: makeClient(transport: transport))

        do {
            _ = try await state.prepareMessageAttachmentLocalFile(makeEndpointOnlyAttachmentMessage(), conversationID: "g_endpoint", preferPreview: false)
            XCTFail("Expected file_not_found")
        } catch IMAPIError.server(let message) {
            XCTAssertEqual(message, "文件不存在或已被清理")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/file-endpoint"])
    }

    private func makeSessionFactory() -> AttachmentDownloadSessionFactory {
        { delegate in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AttachmentDownloadURLProtocol.self]
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    @MainActor
    private func makeClient(transport: HTTPTransport) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
    }

    private func saveAttachmentTestContext() {
        IMAPIContext.clearStoredSession()
        IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-main",
            deviceID: "device-1"
        ).save()
    }

    private func tenantFileResult(
        fileID: String,
        downloadURL: URL,
        sizeBytes: Int,
        checksum: String = ""
    ) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data("""
            {
              "ok": true,
              "data": {
                "file": {
                  "id": "\(fileID)",
                  "file_name": "payload.bin",
                  "mime_type": "application/octet-stream",
                  "size_bytes": \(sizeBytes),
                  "uploader_uid": "uid-2",
                  "status": "uploaded",
                  "media_category": "file",
                  "extension": "bin",
                  "cache_key": "objects/\(fileID)",
                  "version": "v1",
                  "checksum": "\(checksum)"
                },
                "preview_available": false,
                "download_available": true,
                "download_url": "\(downloadURL.absoluteString)"
              }
            }
            """.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    private func attachmentContext(tenantID: String) -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: tenantID,
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "device-\(tenantID)"
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }

    private func makeEndpointOnlyAttachmentMessage(fileID: String = "file-endpoint") -> ChatMessage {
        var message = ChatMessage(
            id: "m-endpoint",
            senderId: "uid-2",
            senderName: "陈星",
            text: "README.md",
            time: "03:44",
            channelSeq: 8,
            isOutgoing: false,
            status: .read,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        message.attachmentName = "README.md"
        message.attachmentFileID = fileID
        message.attachmentSizeBytes = 18
        message.attachmentMimeType = "text/markdown"
        message.attachmentMediaCategory = "document"
        message.attachmentExtension = "md"
        message.attachmentDownloadAvailable = true
        message.attachmentDownloadURL = "/api/tenant/files/\(fileID)/presign-download"
        message.attachmentPreviewURL = "/api/tenant/files/\(fileID)"
        return message
    }
}

private final class FakeAttachmentHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResults: [HTTPTransportResult]
    private var capturedRequests: [URLRequest] = []

    init(results: [HTTPTransportResult]) {
        self.queuedResults = results
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
        }
        return lock.withLock {
            if queuedResults.count <= 1 {
                return queuedResults[0]
            }
            return queuedResults.removeFirst()
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requests() -> [URLRequest] {
        lock.withLock { capturedRequests }
    }
}

private final class AttachmentDownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Double] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

private final class AttachmentDownloadSessionFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func makeFactory() -> AttachmentDownloadSessionFactory {
        { [self] delegate in
            lock.lock()
            value += 1
            lock.unlock()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AttachmentDownloadURLProtocol.self]
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    func count() -> Int {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }
}

private final class AttachmentDownloadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusCodes = [200]
    nonisolated(unsafe) private static var data = Data()
    nonisolated(unsafe) private static var error: Error?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(statusCode: Int = 200, data: Data = Data(), error: Error? = nil) {
        reset(statusCodes: [statusCode], data: data, error: error)
    }

    static func reset(statusCodes: [Int], data: Data = Data(), error: Error? = nil) {
        lock.lock()
        self.statusCodes = statusCodes.isEmpty ? [200] : statusCodes
        self.data = data
        self.error = error
        requests = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        let snapshot = requests
        lock.unlock()
        return snapshot
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let requestIndex = Self.requests.count
        Self.requests.append(request)
        let statusCode = Self.statusCodes[min(requestIndex, Self.statusCodes.count - 1)]
        let data = Self.data
        let error = Self.error
        Self.lock.unlock()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

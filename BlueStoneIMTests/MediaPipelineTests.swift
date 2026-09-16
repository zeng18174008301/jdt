import CryptoKit
import Foundation
import ImageIO
import UIKit
import XCTest
@testable import BlueStoneIM

final class MediaPipelineTests: XCTestCase {
    func testVideoStageAndControlsRemainDisjointAcrossRotationAndSmallWindows() {
        for available in [
            CGSize.zero, CGSize(width: 390, height: 700), CGSize(width: 844, height: 300),
            CGSize(width: 160, height: 120), CGSize(width: 100, height: 600),
            CGSize(width: 1024, height: 768), CGSize(width: 768, height: 1024)
        ] {
            let layout = VideoCallStageLayout(available: available)
            let video = CGRect(origin: .zero, size: layout.videoSize)
            let controls = layout.controlsFrame
            XCTAssertEqual(video.width, available.width)
            XCTAssertEqual(controls.minX, 0)
            XCTAssertEqual(controls.width, available.width)
            XCTAssertGreaterThanOrEqual(video.width, 0)
            XCTAssertGreaterThanOrEqual(video.height, 0)
            XCTAssertLessThanOrEqual(video.maxX, available.width)
            XCTAssertLessThanOrEqual(video.maxY, available.height)
            XCTAssertLessThanOrEqual(controls.maxX, available.width)
            XCTAssertLessThanOrEqual(controls.maxY, available.height)
            XCTAssertTrue(video.intersection(controls).isEmpty)
            XCTAssertEqual(video.width * video.height + controls.width * controls.height,
                           available.width * available.height, accuracy: 0.0001)
        }
    }

    func testVideoPreviewRemainsInsideResizedRegionAfterDragAndRotation() {
        var previous = CGPoint(x: 120, y: 640)
        for available in [
            CGSize(width: 148, height: 700),
            CGSize(width: 110, height: 150),
            CGSize(width: 90, height: 70),
            CGSize(width: 148, height: 700)
        ] {
            let layout = VideoCallLocalPreviewLayout(available: available)
            for proposed in [previous, CGPoint(x: -1000, y: -1000), CGPoint(x: 1000, y: 1000)] {
                for snapping in [false, true] {
                    let center = layout.center(for: proposed, snapping: snapping)
                    XCTAssertGreaterThanOrEqual(center.x - layout.size.width / 2, -0.0001)
                    XCTAssertGreaterThanOrEqual(center.y - layout.size.height / 2, -0.0001)
                    XCTAssertLessThanOrEqual(center.x + layout.size.width / 2, available.width + 0.0001)
                    XCTAssertLessThanOrEqual(center.y + layout.size.height / 2, available.height + 0.0001)
                    previous = center
                }
            }
        }
    }

    func testFloatingPreviewStaysInsideActualAspectFitVideoAcrossRotation() {
        var previous = CGPoint(x: 120, y: 640)
        for available in [CGSize(width: 390, height: 700), CGSize(width: 844, height: 300),
                          CGSize(width: 160, height: 120), CGSize(width: 768, height: 1024)] {
            let stage = VideoCallStageLayout(available: available)
            for source in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920),
                           CGSize(width: 300, height: 2400), CGSize(width: 2400, height: 300)] {
                let region = VideoCallStageLayout.videoRect(source: source, available: stage.videoSize)
                XCTAssertEqual(region.width / region.height, source.width / source.height, accuracy: 0.0001)
                XCTAssertEqual(region.midX, stage.videoSize.width / 2, accuracy: 0.0001)
                XCTAssertEqual(region.midY, stage.videoSize.height / 2, accuracy: 0.0001)
                XCTAssertTrue(region.intersection(stage.controlsFrame).isEmpty)
                let preview = VideoCallLocalPreviewLayout(available: region.size)
                for proposed in [previous, CGPoint(x: -1000, y: -1000), CGPoint(x: 1000, y: 1000),
                                 CGPoint(x: -1000, y: 1000), CGPoint(x: 1000, y: -1000)] {
                    for snapping in [false, true] {
                        let center = preview.center(for: proposed, snapping: snapping)
                        let frame = CGRect(x: region.minX + center.x - preview.size.width / 2,
                                           y: region.minY + center.y - preview.size.height / 2,
                                           width: preview.size.width, height: preview.size.height)
                        XCTAssertGreaterThanOrEqual(frame.minX, region.minX - 0.0001)
                        XCTAssertGreaterThanOrEqual(frame.minY, region.minY - 0.0001)
                        XCTAssertLessThanOrEqual(frame.maxX, region.maxX + 0.0001)
                        XCTAssertLessThanOrEqual(frame.maxY, region.maxY + 0.0001)
                        previous = center
                    }
                }
            }
        }
    }

    func testVideoPreviewReservesBorderOutsideUnclippedVideoArea() {
        for available in [CGSize(width: 148, height: 700), CGSize(width: 40, height: 30)] {
            let layout = VideoCallLocalPreviewLayout(available: available)
            let contentWidth = layout.size.width - 2 * layout.contentInset
            let contentHeight = layout.size.height - 2 * layout.contentInset
            XCTAssertGreaterThan(layout.contentInset, 0)
            XCTAssertGreaterThan(contentWidth, 0)
            XCTAssertGreaterThan(contentHeight, 0)
            XCTAssertEqual(contentWidth / contentHeight, 118.0 / 166.0, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(contentWidth, 118)
            XCTAssertLessThanOrEqual(contentHeight, 166)
        }
    }

    func testVideoPreviewHandlesZeroSizeDuringViewTransition() {
        for available in [CGSize.zero, CGSize(width: 100, height: 0), CGSize(width: 0, height: 100)] {
            let layout = VideoCallLocalPreviewLayout(available: available)
            XCTAssertEqual(layout.size, .zero)
            XCTAssertEqual(layout.contentInset, 0)
            let center = layout.center(for: nil)
            XCTAssertTrue(center.x.isFinite && center.y.isFinite)
            XCTAssertGreaterThanOrEqual(center.x, 0)
            XCTAssertGreaterThanOrEqual(center.y, 0)
            XCTAssertLessThanOrEqual(center.x, available.width)
            XCTAssertLessThanOrEqual(center.y, available.height)
        }
    }

    override func tearDown() {
        MediaPipelineURLProtocol.reset()
        super.tearDown()
    }

    func testAttachmentUploadFailureRetainsSafeCodesAndRedactsUntrustedDetails() throws {
        for status in [99, 100, 503, 599, 600, Int.max, Int.min] {
            let failure = AttachmentUploadFailure(
                code: .http,
                httpStatus: status,
                serverCode: " TENANT_STORAGE_SECRET_UNRESOLVED "
            )
            XCTAssertEqual(failure.httpStatus, (100...599).contains(status) ? status : nil)
            XCTAssertEqual(failure.serverCode, "tenant_storage_secret_unresolved")
        }
        for rawValue in [
            "https://private.example.test/file?signature=synthetic-secret",
            "synthetic_token_without_punctuation",
            "Bearer synthetic-secret",
            "/private/device/file",
            "secret\nline"
        ] {
            let failure = AttachmentUploadFailure(code: .envelope, serverCode: rawValue)
            XCTAssertEqual(failure.serverCode, "unrecognized_server_code")
            XCTAssertEqual(failure.detail, "ENVELOPE · unrecognized_server_code")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(failure)) as? [String: Any]
            XCTAssertEqual(encoded?["serverCode"] as? String, "unrecognized_server_code")
        }
        XCTAssertNil(AttachmentUploadFailure(code: .unknown).serverCode)
    }

    func testAttachmentUploadFailureDecoderSanitizesPersistedFields() throws {
        for payload in [
            #"{"code":"RAW_TOKEN","httpStatus":700,"serverCode":"synthetic_token_without_punctuation"}"#,
            #"{"code":4,"httpStatus":"503","serverCode":{"token":"synthetic-secret"}}"#,
            #"{}"#
        ] {
            let failure = try JSONDecoder().decode(AttachmentUploadFailure.self, from: Data(payload.utf8))
            XCTAssertEqual(failure.code, .unknown)
            XCTAssertNil(failure.httpStatus)
            let encoded = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
            XCTAssertFalse(encoded.contains("synthetic_token"))
            XCTAssertFalse(encoded.contains("synthetic-secret"))
            XCTAssertFalse(encoded.contains("RAW_TOKEN"))
        }
        let failure = try JSONDecoder().decode(
            AttachmentUploadFailure.self,
            from: Data(#"{"code":"HTTP","httpStatus":422,"serverCode":" INVALID_PAYLOAD "}"#.utf8)
        )
        XCTAssertEqual(failure, AttachmentUploadFailure(code: .http, httpStatus: 422, serverCode: "invalid_payload"))
        XCTAssertEqual(failure.detail, "HTTP · HTTP 422 · invalid_payload")
    }

    func testMediaURLSessionDownloadExecutorStoresSuccessfulDownloadAndSendsHeaders() async throws {
        let payload = Data("downloaded-media".utf8)
        MediaPipelineURLProtocol.reset(statusCode: 206, data: payload)
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let request = makeRequest(cacheKey: "stage63-success", preferredExtension: "txt")
        let endpointURL = try XCTUnwrap(URL(string: "https://media.example.test/file.txt"))
        let provider = MediaSignedURLProvider { _ in
            MediaSignedDownloadEndpoint(
                url: endpointURL,
                headers: ["X-Signed": "yes"],
                expiresAt: Date().addingTimeInterval(600)
            )
        }
        let executor = makeExecutor()
        let resumeMetadata = MediaDownloadResumeMetadata(
            identity: request.identity,
            partialFileURL: cacheRoot.appendingPathComponent("partial"),
            bytesWritten: 4
        )

        let stream = await executor.events(
            for: request,
            provider: provider,
            cacheRoot: cacheRoot,
            resumeMetadata: resumeMetadata
        )
        let events = await collectEvents(from: stream)

        XCTAssertEqual(events.count, 3)
        guard case .started(let startedTaskID) = events[0] else {
            return XCTFail("Expected started event")
        }
        XCTAssertEqual(startedTaskID, request.taskID)
        guard case .progress(let progressTaskID, let fraction) = events[1] else {
            return XCTFail("Expected progress event")
        }
        XCTAssertEqual(progressTaskID, request.taskID)
        XCTAssertNil(fraction)
        guard case .completed(let completedTaskID, let localURL) = events[2] else {
            return XCTFail("Expected completed event")
        }
        XCTAssertEqual(completedTaskID, request.taskID)
        XCTAssertEqual(localURL, request.cacheFileURL(in: cacheRoot))
        XCTAssertEqual(try Data(contentsOf: localURL), payload)

        let recordedRequests = MediaPipelineURLProtocol.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 1)
        XCTAssertEqual(recordedRequests.first?.url, endpointURL)
        XCTAssertEqual(recordedRequests.first?.value(forHTTPHeaderField: "X-Signed"), "yes")
        XCTAssertEqual(recordedRequests.first?.value(forHTTPHeaderField: "Range"), "bytes=4-")
    }

    func testMediaURLSessionDownloadExecutorMapsHTTPFailureToReasonWithoutSavingFile() async throws {
        MediaPipelineURLProtocol.reset(statusCode: 404, data: Data("missing".utf8))
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let request = makeRequest(cacheKey: "stage63-missing", preferredExtension: "bin")
        let endpointURL = try XCTUnwrap(URL(string: "https://media.example.test/missing.bin"))
        let provider = MediaSignedURLProvider { _ in
            MediaSignedDownloadEndpoint(url: endpointURL, expiresAt: Date().addingTimeInterval(600))
        }
        let executor = makeExecutor()

        let stream = await executor.events(
            for: request,
            provider: provider,
            cacheRoot: cacheRoot,
            resumeMetadata: nil
        )
        let events = await collectEvents(from: stream)

        XCTAssertEqual(events.count, 2)
        guard case .started(let startedTaskID) = events[0] else {
            return XCTFail("Expected started event")
        }
        XCTAssertEqual(startedTaskID, request.taskID)
        guard case .failed(let failedTaskID, let reason) = events[1] else {
            return XCTFail("Expected failed event")
        }
        XCTAssertEqual(failedTaskID, request.taskID)
        XCTAssertEqual(reason, .notFound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.cacheFileURL(in: cacheRoot).path))
    }

    func testMediaURLSessionDownloadExecutorSkipsNetworkWhenSignatureNeedsRefresh() async throws {
        MediaPipelineURLProtocol.reset(statusCode: 200, data: Data("unused".utf8))
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let request = makeRequest(cacheKey: "stage63-expired", preferredExtension: "dat")
        let endpointURL = try XCTUnwrap(URL(string: "https://media.example.test/expired.dat"))
        let provider = MediaSignedURLProvider { _ in
            MediaSignedDownloadEndpoint(url: endpointURL, expiresAt: Date().addingTimeInterval(1))
        }
        let executor = makeExecutor()

        let stream = await executor.events(
            for: request,
            provider: provider,
            cacheRoot: cacheRoot,
            resumeMetadata: nil
        )
        let events = await collectEvents(from: stream)

        XCTAssertEqual(events.count, 2)
        guard case .started(let startedTaskID) = events[0] else {
            return XCTFail("Expected started event")
        }
        XCTAssertEqual(startedTaskID, request.taskID)
        guard case .signatureExpired(let expiredTaskID) = events[1] else {
            return XCTFail("Expected signatureExpired event")
        }
        XCTAssertEqual(expiredTaskID, request.taskID)
        XCTAssertTrue(MediaPipelineURLProtocol.recordedRequests().isEmpty)
    }

    func testMediaURLSessionDownloadExecutorRefreshesOnceAfterSigned403ThenSucceeds() async throws {
        let payload = Data("recovered-media".utf8)
        MediaPipelineURLProtocol.reset(statusCodes: [403, 200], data: payload)
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let request = makeRequest(cacheKey: "stage-oss-403-recovery", preferredExtension: "txt")
        let endpoints = [
            try XCTUnwrap(URL(string: "https://media.example.test/file.txt?auth_key=expired")),
            try XCTUnwrap(URL(string: "https://media.example.test/file.txt?auth_key=fresh"))
        ]
        let providerCalls = LockedInteger()
        let provider = MediaSignedURLProvider { _ in
            let call = providerCalls.incrementAndGetPrevious()
            return MediaSignedDownloadEndpoint(
                url: endpoints[min(call, endpoints.count - 1)],
                expiresAt: Date().addingTimeInterval(600)
            )
        }
        let executor = makeExecutor()

        let stream = await executor.events(
            for: request,
            provider: provider,
            cacheRoot: cacheRoot,
            resumeMetadata: nil
        )
        let events = await collectEvents(from: stream)

        XCTAssertEqual(providerCalls.value(), 2)
        XCTAssertEqual(MediaPipelineURLProtocol.recordedRequests().map(\.url), endpoints)
        guard case .completed(_, let localURL) = events.last else {
            return XCTFail("Expected recovered completion")
        }
        XCTAssertEqual(try Data(contentsOf: localURL), payload)
    }

    func testMediaURLSessionDownloadExecutorStopsAfterOneSignedURLRefresh() async throws {
        MediaPipelineURLProtocol.reset(statusCodes: [403, 403], data: Data("expired".utf8))
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let request = makeRequest(cacheKey: "stage-oss-403-bounded", preferredExtension: "txt")
        let providerCalls = LockedInteger()
        let provider = MediaSignedURLProvider { _ in
            let call = providerCalls.incrementAndGetPrevious()
            let url = URL(string: "https://media.example.test/file.txt?auth_key=attempt-\(call)")!
            return MediaSignedDownloadEndpoint(url: url, expiresAt: Date().addingTimeInterval(600))
        }
        let executor = makeExecutor()

        let stream = await executor.events(
            for: request,
            provider: provider,
            cacheRoot: cacheRoot,
            resumeMetadata: nil
        )
        let events = await collectEvents(from: stream)

        XCTAssertEqual(providerCalls.value(), 2)
        XCTAssertEqual(MediaPipelineURLProtocol.recordedRequests().count, 2)
        guard case .signatureExpired(let taskID) = events.last else {
            return XCTFail("Expected bounded signature failure")
        }
        XCTAssertEqual(taskID, request.taskID)
    }

    func testMediaURLSessionDownloadExecutorDoesNotTreatTenantAPI401AsSignedURLExpiry() async throws {
        MediaPipelineURLProtocol.reset(statusCode: 401, data: Data("unauthorized".utf8))
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let request = makeRequest(cacheKey: "stage-api-401", preferredExtension: "json")
        let providerCalls = LockedInteger()
        let endpointURL = try XCTUnwrap(URL(string: "https://tenant.example.test/api/tenant/files/file-1"))
        let provider = MediaSignedURLProvider { _ in
            _ = providerCalls.incrementAndGetPrevious()
            return MediaSignedDownloadEndpoint(url: endpointURL, expiresAt: Date().addingTimeInterval(600))
        }
        let executor = makeExecutor()

        let stream = await executor.events(
            for: request,
            provider: provider,
            cacheRoot: cacheRoot,
            resumeMetadata: nil
        )
        let events = await collectEvents(from: stream)

        XCTAssertEqual(providerCalls.value(), 1)
        XCTAssertEqual(MediaPipelineURLProtocol.recordedRequests().count, 1)
        guard case .failed(_, let reason) = events.last else {
            return XCTFail("Expected authenticated API failure")
        }
        XCTAssertEqual(reason, .unauthorized)
    }

    func testMediaURLSessionDownloadExecutorDoesNotRefreshUnsignedThirdParty403() async throws {
        MediaPipelineURLProtocol.reset(statusCode: 403, data: Data("forbidden".utf8))
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let request = makeRequest(cacheKey: "unsigned-third-party", preferredExtension: "txt")
        let providerCalls = LockedInteger()
        let endpointURL = try XCTUnwrap(URL(string: "https://media.example.test/public/file.txt"))
        let provider = MediaSignedURLProvider { _ in
            _ = providerCalls.incrementAndGetPrevious()
            return MediaSignedDownloadEndpoint(url: endpointURL, expiresAt: Date().addingTimeInterval(600))
        }

        let events = await collectEvents(from: await makeExecutor().events(
            for: request,
            provider: provider,
            cacheRoot: cacheRoot,
            resumeMetadata: nil
        ))

        XCTAssertEqual(providerCalls.value(), 1)
        XCTAssertEqual(MediaPipelineURLProtocol.recordedRequests().count, 1)
        guard case .failed(_, let reason) = events.last else {
            return XCTFail("Expected unsigned third-party failure")
        }
        XCTAssertEqual(reason, .forbidden)
    }

    func testMediaResourceIdentityPrefersFileIDAndIgnoresSignedURLQueryChanges() {
        let first = MediaPipelineCore.identity(
            kind: .thumbnail,
            scope: Self.fixtureScopeHash,
            fileID: "file-1",
            cacheKey: "https://cdn.example.test/file.jpg?auth_key=first",
            version: "v1"
        )
        let second = MediaPipelineCore.identity(
            kind: .thumbnail,
            scope: Self.fixtureScopeHash,
            fileID: "file-1",
            cacheKey: "https://cdn.example.test/file.jpg?auth_key=second",
            version: "v1"
        )

        XCTAssertEqual(first.stableCacheKey, second.stableCacheKey)
        XCTAssertEqual(first.stableCacheKey.count, 64)
        XCTAssertFalse(first.stableCacheKey.contains("file-1"))
        XCTAssertFalse(first.stableCacheKey.contains("auth_key"))
    }

    func testMediaResourceIdentityRejectsSignedURLOnlyPersistentIdentity() {
        let first = MediaPipelineCore.identity(
            kind: .preview,
            scope: Self.fixtureScopeHash,
            cacheKey: "https://user:password@cdn.example.test/file.jpg?auth_key=first#preview"
        )
        let second = MediaPipelineCore.identity(
            kind: .preview,
            scope: Self.fixtureScopeHash,
            cacheKey: "https://cdn.example.test/file.jpg?auth_key=second#other"
        )

        XCTAssertNil(first.persistentCacheIdentity)
        XCTAssertNil(second.persistentCacheIdentity)

        let versionedSignedURL = MediaPipelineCore.identity(
            kind: .preview,
            scope: Self.fixtureScopeHash,
            cacheKey: "https://cdn.example.test/file.jpg?auth_key=third",
            version: "v1"
        )
        XCTAssertNil(versionedSignedURL.persistentCacheIdentity)
    }

    func testFrozenIdentityVectorsMatchCanonicalContract() throws {
        let fixture = try JSONDecoder().decode(
            FrozenIdentityFixture.self,
            from: Data(contentsOf: cacheContractFixtureURL("identity-vectors.json"))
        )
        XCTAssertEqual(fixture.fixtureVersion, 1)
        XCTAssertEqual(fixture.vectors.count, 3)

        for vector in fixture.vectors {
            let scopePairs = [
                ("account_id", vector.scope.accountID),
                ("tenant_id", vector.scope.tenantID),
                ("app_id", vector.scope.appID),
                ("im_uid", vector.scope.imUID),
                ("device_id", vector.scope.deviceID)
            ]
            XCTAssertEqual(
                String(data: try MediaCacheCanonicalIdentity.canonicalData(scopePairs), encoding: .utf8),
                vector.scopeCanonical,
                vector.id
            )
            let scopeHash = try MediaCacheCanonicalIdentity.digest(scopePairs)
            XCTAssertEqual(scopeHash, vector.scopeHash, vector.id)
            let variant = try XCTUnwrap(MediaCacheVariant(rawValue: vector.variant), vector.id)
            let resourceKind: MediaResourceKind = switch variant {
            case .thumbnail320, .thumbnail640, .videoPoster: .thumbnail
            case .preview1600: .preview
            case .original: .original
            }
            let createdAt = vector.contentVersion
                .components(separatedBy: ";created_at=")
                .dropFirst()
                .first ?? ""
            let sizeBytes = vector.contentVersion
                .split(separator: ";")
                .first
                .flatMap { component -> Int64? in
                    guard component.hasPrefix("size=") else { return nil }
                    return Int64(component.dropFirst("size=".count))
                }
            let identity = MediaResourceIdentity(
                resourceKind: resourceKind,
                scope: scopeHash,
                fileID: vector.resourceIDKind == "file_id" ? vector.resourceID : "",
                attachmentID: vector.resourceIDKind == "attachment_id" ? vector.resourceID : "",
                mediaID: vector.resourceIDKind == "media_id" ? vector.resourceID : "",
                cacheKey: vector.resourceIDKind == "cache_key" ? vector.resourceID : "",
                version: vector.contentVersionKind == "version" ? vector.contentVersion : "",
                checksumSHA256: vector.contentVersionKind == "checksum_sha256" ? vector.contentVersion : "",
                createdAt: createdAt,
                variant: variant,
                sizeBytes: sizeBytes
            )
            XCTAssertEqual(identity.resourceIDKind?.rawValue, vector.resourceIDKind, vector.id)
            XCTAssertEqual(identity.contentVersionKindAndValue?.0.rawValue, vector.contentVersionKind, vector.id)
            XCTAssertEqual(identity.contentVersionKindAndValue?.1, vector.contentVersion, vector.id)
            let cachePairs = [
                ("scope_hash", vector.scopeHash),
                ("resource_id_kind", vector.resourceIDKind),
                ("resource_id", vector.resourceID),
                ("content_version_kind", vector.contentVersionKind),
                ("content_version", vector.contentVersion),
                ("variant", vector.variant)
            ]
            XCTAssertEqual(
                String(data: try MediaCacheCanonicalIdentity.canonicalData(cachePairs), encoding: .utf8),
                vector.cacheCanonical,
                vector.id
            )
            XCTAssertEqual(identity.persistentCacheIdentity, vector.cacheIdentity, vector.id)
        }
    }

    func testFrozenIdentityPrecedenceAndWhitespaceAreFailClosed() {
        let identity = MediaPipelineCore.identity(
            kind: .original,
            scope: Self.fixtureScopeHash,
            attachmentID: "attachment-preferred",
            mediaID: "media-lower-priority",
            version: "v1"
        )
        XCTAssertEqual(identity.resourceIDKind, .attachmentID)
        XCTAssertEqual(identity.primaryStableID, "attachment-preferred")

        let invalid = MediaPipelineCore.identity(
            kind: .original,
            scope: Self.fixtureScopeHash,
            fileID: " file-with-leading-space",
            version: "v1"
        )
        XCTAssertNil(invalid.persistentCacheIdentity)

        for malformedChecksum in [
            String(repeating: "A", count: 64),
            "sha256:" + String(repeating: "a", count: 64),
            " " + String(repeating: "a", count: 64)
        ] {
            let malformed = MediaPipelineCore.identity(
                kind: .original,
                scope: Self.fixtureScopeHash,
                fileID: "file-malformed-checksum",
                version: "v1",
                checksumSHA256: malformedChecksum
            )
            XCTAssertNil(malformed.persistentCacheIdentity, malformedChecksum)
        }
    }

    func testMediaLayeredCacheRejectsSameSizeChecksumCorruption() async throws {
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let sourceURL = cacheRoot
            .deletingLastPathComponent()
            .appendingPathComponent("media-integrity-source-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let original = Data("expected-content".utf8)
        let corrupted = Data("corruptd-content".utf8)
        XCTAssertEqual(original.count, corrupted.count)
        try original.write(to: sourceURL, options: .atomic)
        let integrity = MediaFileIntegrityAuthority(
            expectedSizeBytes: Int64(original.count),
            expectedSHA256: SHA256.hash(data: original).map { String(format: "%02x", Int($0)) }.joined()
        )
        let identity = MediaPipelineCore.identity(
            kind: .original,
            scope: Self.fixtureScopeHash,
            fileID: "file-integrity",
            version: "v1",
            mimeType: "application/octet-stream",
            sizeBytes: Int64(original.count)
        )
        let store = MediaLayeredCacheStore(rootDirectory: cacheRoot)
        let committed = try await store.saveVerifiedDownloadedFile(
            from: sourceURL,
            identity: identity,
            preferredExtension: "bin",
            integrity: integrity
        )
        try corrupted.write(to: committed.localURL, options: .atomic)

        let lookup = await store.verifiedLookup(
            identity: identity,
            preferredExtension: "bin",
            integrity: integrity
        )

        guard case .readyRemote = lookup.state else {
            return XCTFail("same-size corrupted bytes must not be returned as a cache hit")
        }
        XCTAssertNil(lookup.entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.localURL.path))
    }

    func testMediaLayeredCacheGenerationFenceRejectsRetiredWriterBeforePromotion() async throws {
        let seed = Data(UUID().uuidString.utf8)
        let scopeHash = SHA256.hash(data: seed).map { String(format: "%02x", Int($0)) }.joined()
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let oldSource = cacheRoot.deletingLastPathComponent()
            .appendingPathComponent("old-generation-\(UUID().uuidString).bin")
        let newSource = cacheRoot.deletingLastPathComponent()
            .appendingPathComponent("new-generation-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: oldSource)
            try? FileManager.default.removeItem(at: newSource)
        }
        let oldBytes = Data("retired-generation".utf8)
        let newBytes = Data("current-generation".utf8)
        try oldBytes.write(to: oldSource, options: .atomic)
        try newBytes.write(to: newSource, options: .atomic)
        let oldContext = IOSMediaCacheScopeContext(
            scopeHash: scopeHash,
            sessionGeneration: 10,
            rootDirectory: cacheRoot
        )
        let newContext = IOSMediaCacheScopeContext(
            scopeHash: scopeHash,
            sessionGeneration: 11,
            rootDirectory: cacheRoot
        )
        let oldStore = try await IOSMediaCacheStoreRegistry.shared.store(for: oldContext)
        let newStore = try await IOSMediaCacheStoreRegistry.shared.store(for: newContext)
        XCTAssertTrue(oldStore === newStore)
        let identity = MediaPipelineCore.identity(
            kind: .original,
            scope: scopeHash,
            fileID: "generation-file",
            version: "v1",
            mimeType: "application/octet-stream"
        )
        let integrity = MediaFileIntegrityAuthority()

        do {
            _ = try await oldStore.saveVerifiedDownloadedFile(
                from: oldSource,
                identity: identity,
                preferredExtension: "bin",
                integrity: integrity,
                sessionGeneration: oldContext.sessionGeneration
            )
            XCTFail("retired generation must not promote bytes")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: identity.cacheFileURL(in: cacheRoot, preferredExtension: "bin").path
        ))

        let committed = try await newStore.saveVerifiedDownloadedFile(
            from: newSource,
            identity: identity,
            preferredExtension: "bin",
            integrity: integrity,
            sessionGeneration: newContext.sessionGeneration
        )
        XCTAssertEqual(try Data(contentsOf: committed.localURL), newBytes)

        let staleLookup = await oldStore.verifiedLookup(
            identity: identity,
            preferredExtension: "bin",
            integrity: MediaFileIntegrityAuthority(
                expectedSizeBytes: Int64(oldBytes.count),
                expectedSHA256: SHA256.hash(data: oldBytes)
                    .map { String(format: "%02x", Int($0)) }
                    .joined()
            ),
            sessionGeneration: oldContext.sessionGeneration
        )
        guard case .readyRemote = staleLookup.state else {
            return XCTFail("retired lookup must not inspect current-generation bytes")
        }
        XCTAssertEqual(try Data(contentsOf: committed.localURL), newBytes)
    }

    func testGIFFallbackDecodesExactColorsTransparencyAndDisposalTwoAndThree() throws {
        let original = try publicTransparentGIFFixture()
        let metadata = try StickerGIFFallbackDecoder.metadata(data: original)
        XCTAssertEqual(metadata.width, 4)
        XCTAssertEqual(metadata.height, 2)
        XCTAssertEqual(metadata.frameCount, 2)
        let first = try StickerGIFFallbackDecoder.frame(data: original, index: 0, maxPixelSize: 4)
        let second = try StickerGIFFallbackDecoder.frame(data: original, index: 1, maxPixelSize: 4)
        XCTAssertEqual(try fallbackBGRA(first, x: 0, y: 0), [0, 0, 128, 255])
        XCTAssertEqual(try fallbackBGRA(first, x: 2, y: 1), [0, 0, 224, 255])
        XCTAssertEqual(try fallbackBGRA(second, x: 1, y: 1), [255, 0, 0, 255])
        XCTAssertEqual(try fallbackBGRA(second, x: 2, y: 1), [0, 0, 224, 255], "transparent overlay must preserve the red pixel beneath")
        XCTAssertEqual(try fallbackBGRA(second, x: 3, y: 1), [85, 0, 0, 255])
        XCTAssertEqual(first.delay, 0.1, accuracy: 0.001)
        XCTAssertEqual(second.delay, 0.2, accuracy: 0.001)

        for disposal in [UInt8(2), 3] {
            let data = try publicTransparentGIFFixture(disposal: disposal)
            XCTAssertEqual(try StickerGIFFallbackDecoder.metadata(data: data).frameCount, 3)
            let beforeDisposal = try StickerGIFFallbackDecoder.frame(data: data, index: 1, maxPixelSize: 4)
            XCTAssertEqual(try fallbackBGRA(beforeDisposal, x: 1, y: 1), [255, 0, 0, 255])
            let third = try StickerGIFFallbackDecoder.frame(data: data, index: 2, maxPixelSize: 4)
            XCTAssertEqual(try fallbackBGRA(third, x: 0, y: 0), [0, 0, 16, 255])
            XCTAssertEqual(try fallbackBGRA(third, x: 0, y: 1), [0, 0, 192, 255], "disposal must not clear pixels outside the previous frame rectangle")
            for x in 1...3 {
                let expected: [UInt8] = disposal == 2 ? [0, 0, 0, 0] : [0, 0, UInt8(192 + x * 16), 255]
                XCTAssertEqual(try fallbackBGRA(third, x: x, y: 1), expected, "disposal=\(disposal), x=\(x)")
            }
            let rereadFirst = try StickerGIFFallbackDecoder.frame(data: data, index: 0, maxPixelSize: 4)
            XCTAssertEqual(try fallbackBGRA(rereadFirst, x: 0, y: 0), [0, 0, 128, 255], "random access must not retain a later composite")
        }
    }

    func testGIFFallbackBoundsOutputAndRejectsTruncatedForgedAndOversizedInputs() throws {
        let wide = try makeGIFFixture(frameCount: 2, width: 1100, height: 2)
        for index in [0, 1] {
            let decoded = try StickerGIFFallbackDecoder.frame(data: wide, index: index, maxPixelSize: 5000)
            let image = try XCTUnwrap(decoded.image.cgImage)
            XCTAssertEqual(image.width, 1024)
            XCTAssertLessThanOrEqual(image.height, 1024)
            XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, StickerGIFImageDecoder.maximumFrameBytes)
        }
        let valid = try publicTransparentGIFFixture()
        var badLZW = valid
        badLZW[127] = 12 // GIF LZW minimum code size cannot exceed 8.
        for invalid in [Data(valid.prefix(20)), Data(valid.prefix(160)), Data("GIF89a forged image".utf8), badLZW] {
            XCTAssertThrowsError(try StickerGIFFallbackDecoder.frame(data: invalid, index: 1, maxPixelSize: 4))
        }
        XCTAssertThrowsError(try StickerGIFFallbackDecoder.frame(data: valid, index: -1, maxPixelSize: 4))
        XCTAssertThrowsError(try StickerGIFFallbackDecoder.frame(data: valid, index: 2, maxPixelSize: 4))
        var giantCanvas = valid
        giantCanvas[6] = 0x01; giantCanvas[7] = 0x10 // 4097 × 4096 exceeds 16 Mi source pixels.
        giantCanvas[8] = 0x00; giantCanvas[9] = 0x10
        var oversizedBody = valid
        oversizedBody.append(Data(repeating: 0, count: StickerGIFResourceReader.maximumBytes + 1 - valid.count))
        for oversized in [giantCanvas, oversizedBody] {
            XCTAssertThrowsError(try StickerGIFFallbackDecoder.metadata(data: oversized)) {
                XCTAssertEqual($0 as? StickerGIFResourceError, .tooLarge)
            }
            XCTAssertThrowsError(try StickerGIFFallbackDecoder.frame(data: oversized, index: 0, maxPixelSize: 4)) {
                XCTAssertEqual($0 as? StickerGIFResourceError, .tooLarge)
            }
        }
    }

    func testGIFFallbackCancelledTaskCannotReturnFrameAndNextDecodeStillWorks() async throws {
        let data = try publicTransparentGIFFixture(disposal: 3)
        let gate = GIFTestDataGate()
        let task = Task.detached {
            await gate.wait()
            return try StickerGIFFallbackDecoder.frame(data: data, index: 2, maxPixelSize: 4)
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("a cancelled decode must not publish a frame")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let next = try StickerGIFFallbackDecoder.frame(data: data, index: 2, maxPixelSize: 4)
        XCTAssertEqual(try fallbackBGRA(next, x: 1, y: 1), [0, 0, 208, 255])
    }

    func testGIFDecoderPreservesAllFramesBeyondSeventyTwoAndLongDelay() async throws {
        let data = try makeGIFFixture(frameCount: 80, delay: 0.7)
        let decoder = try StickerGIFImageDecoder(data: data, maxPixelSize: 32, requiresGIF: true)
        let frameCount = await decoder.frameCount
        XCTAssertEqual(frameCount, 80)
        let first = try await decoder.frame(at: 0)
        let last = try await decoder.frame(at: 79)
        XCTAssertNotEqual(first.image.pngData(), last.image.pngData())
        XCTAssertEqual(last.delay, 0.7, accuracy: 0.011)
        let repeatedFirst = try await decoder.frame(at: 0)
        XCTAssertEqual(first.image.pngData(), repeatedFirst.image.pngData())
    }

    func testGIFDecoderBoundsPixelsAndRejectsOversizedLogicalCanvasBeforeDecode() async throws {
        let data = try makeGIFFixture(frameCount: 1, width: 1100, height: 2)
        let decoder = try StickerGIFImageDecoder(data: data, maxPixelSize: 5000, requiresGIF: true)
        let frame = try await decoder.frame(at: 0)
        let image = try XCTUnwrap(frame.image.cgImage)
        XCTAssertLessThanOrEqual(image.width, 1024)
        XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, StickerGIFImageDecoder.maximumFrameBytes)
        var oversizedCanvas = try makeGIFFixture(frameCount: 1)
        oversizedCanvas[6] = 0xff
        oversizedCanvas[7] = 0xff
        oversizedCanvas[8] = 0xff
        oversizedCanvas[9] = 0xff
        XCTAssertThrowsError(try StickerGIFImageDecoder(data: oversizedCanvas, maxPixelSize: 32, requiresGIF: true)) {
            XCTAssertEqual($0 as? StickerGIFResourceError, .tooLarge)
        }
    }

    func testGIFDecoderKeepsStaticStickerCompatibilityButRejectsMislabeledGIF() async throws {
        let png = try XCTUnwrap(UIImage(cgImage: makeGIFFrame(width: 2, height: 2, blue: false)).pngData())
        let decoder = try StickerGIFImageDecoder(data: png, maxPixelSize: 32)
        let frameCount = await decoder.frameCount
        XCTAssertEqual(frameCount, 1)
        _ = try await decoder.frame(at: 0)
        XCTAssertThrowsError(try StickerGIFImageDecoder(data: png, maxPixelSize: 32, requiresGIF: true))
        XCTAssertThrowsError(try StickerGIFImageDecoder(data: Data("not an image".utf8), maxPixelSize: 32))
    }

    @MainActor
    func testGIFPlaybackLimiterCountsInstancesNotSharedAssetKeysAndReleases() {
        let limiter = StickerGIFPlaybackLimiter()
        let players = (0..<5).map { _ in UUID() }
        for player in players.prefix(4) { XCTAssertTrue(limiter.acquire(player)) }
        XCTAssertTrue(limiter.acquire(players[0]))
        XCTAssertEqual(limiter.activePlayers.count, 4)
        XCTAssertFalse(limiter.acquire(players[4]))
        limiter.release(players[0])
        XCTAssertTrue(limiter.acquire(players[4]))
        for player in players { limiter.release(player) }
        XCTAssertTrue(limiter.activePlayers.isEmpty)
    }

    @MainActor
    func testGIFFifthVisiblePlayerGetsFirstFrameAndExplicitPlaybackPriority() async throws {
        let bytes = try makeGIFFixture(frameCount: 2, width: 16, height: 16)
        let limiter = StickerGIFPlaybackLimiter()
        let players = (0..<5).map { _ in UUID() }
        var loaders: [StickerGIFFrameLoader] = []
        for (index, player) in players.enumerated() {
            limiter.setVisible(player, true)
            let loader = StickerGIFFrameLoader { _ in bytes }
            await loader.load(url: URL(string: "https://gif.example.test/\(index).gif"), cacheKey: "asset-\(index)", maxPixelSize: 16, requiresGIF: true, retainDecoder: false)
            XCTAssertNotNil(loader.frame)
            XCTAssertFalse(loader.retainsDecoder)
            limiter.requestAnimation(player, eligible: true)
            loaders.append(loader)
        }
        XCTAssertEqual(limiter.activePlayers.count, 4)
        XCTAssertFalse(limiter.activePlayers.contains(players[4]))
        XCTAssertNotNil(loaders[4].frame, "Animation saturation must not suppress the fifth first frame")
        limiter.prioritize(players[4])
        XCTAssertTrue(limiter.activePlayers.contains(players[4]))
        let prepared = await loaders[4].prepareForPlayback()
        XCTAssertTrue(prepared)
        let advanced = await loaders[4].showFrame(at: 1)
        XCTAssertTrue(advanced)
        XCTAssertEqual(loaders[4].currentFrameIndex, 1)
        loaders[4].releaseAnimation()
        XCTAssertFalse(loaders[4].retainsDecoder)
        XCTAssertNotNil(loaders[4].frame)
        XCTAssertEqual(loaders[4].currentFrameIndex, 0)
        for (player, loader) in zip(players, loaders) {
            loader.stop()
            limiter.setVisible(player, false)
            XCTAssertNil(loader.frame)
        }
        XCTAssertTrue(limiter.activePlayers.isEmpty)
        XCTAssertTrue(limiter.visiblePlayers.isEmpty)
    }

    @MainActor
    func testGIFFailedStaticAndPowerRestrictedPlayersDoNotHoldAnimationSlots() async throws {
        let animated = try makeGIFFixture(frameCount: 2)
        let still = try XCTUnwrap(UIImage(cgImage: makeGIFFrame(width: 2, height: 2, blue: false)).pngData())
        for restriction in ["failed", "static", "reduceMotion", "lowPower"] {
            let limiter = StickerGIFPlaybackLimiter()
            let players = (0..<5).map { _ in UUID() }
            for (index, player) in players.enumerated() {
                limiter.setVisible(player, true)
                let restricted = index < 4
                let bytes = restricted && restriction == "failed" ? Data("invalid".utf8)
                    : restricted && restriction == "static" ? still : animated
                let loader = StickerGIFFrameLoader { _ in bytes }
                await loader.load(url: URL(string: "https://gif.example.test/item"), cacheKey: "item", maxPixelSize: 16, retainDecoder: false)
                let eligible = StickerGIFPlaybackEligibility.allowsAnimation(visible: true, frameCount: loader.frameCount,
                    failed: loader.failed, reduceMotion: restricted && restriction == "reduceMotion", lowPower: restricted && restriction == "lowPower")
                limiter.requestAnimation(player, eligible: eligible)
                if restricted { XCTAssertFalse(limiter.activePlayers.contains(player), restriction) }
                if restriction != "failed" || !restricted { XCTAssertNotNil(loader.frame) }
                XCTAssertFalse(loader.retainsDecoder)
                loader.stop()
            }
            XCTAssertEqual(limiter.activePlayers, Set([players[4]]), restriction)
            limiter.requestAnimation(players[0], eligible: true)
            XCTAssertTrue(limiter.activePlayers.contains(players[0]), "Power/static state recovery may acquire a free slot")
        }
    }

    @MainActor
    func testGIFFullscreenPriorityAndVisiblePreviewMemoryBudget() {
        let limiter = StickerGIFPlaybackLimiter()
        let players = (0..<48).map { _ in UUID() }
        for player in players { limiter.setVisible(player, true) }
        let limit = limiter.previewPixelLimit(requested: 1024)
        XCTAssertLessThanOrEqual(players.count * limit * limit * 4, StickerGIFPlaybackLimiter.previewBudgetBytes)
        for player in players.prefix(4) { limiter.requestAnimation(player, eligible: true) }
        limiter.requestAnimation(players[4], eligible: true, priority: true)
        XCTAssertTrue(limiter.activePlayers.contains(players[4]))
        XCTAssertEqual(limiter.activePlayers.count, 4)
        limiter.setVisible(players[4], false)
        XCTAssertEqual(limiter.activePlayers, Set(players.prefix(4)))
        for player in players { limiter.setVisible(player, false) }
        XCTAssertTrue(limiter.activePlayers.isEmpty)
        XCTAssertEqual(limiter.previewPixelLimit(requested: 1024), 1024)
    }

    func testGIFHighResolutionUploadCandidateDecodesFirstAndLaterFramesWithinBudget() async throws {
        let bytes = try autoreleasepool { try makeGIFFixture(frameCount: 2, width: 2560, height: 1920) }
        XCTAssertLessThan(bytes.count, Int(GIFAttachmentUploadPolicy.maximumBytes))
        XCTAssertTrue(try GIFAttachmentUploadPolicy.isGIF(data: bytes, fileURL: nil, name: "normal-high-resolution.gif", mimeType: "image/gif"))
        let decoder = try StickerGIFImageDecoder(data: bytes, maxPixelSize: 1024, requiresGIF: true)
        let first = try await decoder.frame(at: 0)
        let later = try await decoder.frame(at: 1)
        for frame in [first, later] {
            let image = try XCTUnwrap(frame.image.cgImage)
            XCTAssertEqual(image.width, 1024)
            XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, StickerGIFImageDecoder.maximumFrameBytes)
        }
        XCTAssertNotEqual(first.image.pngData(), later.image.pngData())
        XCTAssertEqual(StickerGIFImageDecoder.maximumSourcePixels * 3 * 4, StickerGIFImageDecoder.maximumCompositeWorkingBytes)
    }

    func testGIFTexturedHighResolutionUploadCandidateDecodesFirstAndLaterFrames() async throws {
        let bytes = try autoreleasepool { try makeGIFFixture(frameCount: 2, width: 2560, height: 1920, textured: true) }
        XCTAssertLessThan(bytes.count, Int(GIFAttachmentUploadPolicy.maximumBytes))
        XCTAssertTrue(try GIFAttachmentUploadPolicy.isGIF(data: bytes, fileURL: nil, name: "high-resolution.gif", mimeType: "image/gif"))
        let decoder = try StickerGIFImageDecoder(data: bytes, maxPixelSize: 1024, requiresGIF: true)
        let first = try await decoder.frame(at: 0)
        let later = try await decoder.frame(at: 1)
        for frame in [first, later] {
            let image = try XCTUnwrap(frame.image.cgImage)
            XCTAssertEqual(image.width, 1024)
            XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, StickerGIFImageDecoder.maximumFrameBytes)
        }
        XCTAssertNotEqual(first.image.pngData(), later.image.pngData())
    }

    @MainActor
    func testGIFLatePlaybackPreparationCannotRestoreDecoderAfterPauseOrOffscreenStop() async throws {
        let bytes = try makeGIFFixture(frameCount: 2)
        for offscreen in [false, true] {
            let gate = GIFTestDataGate()
            let counter = GIFTestReadCounter()
            let loader = StickerGIFFrameLoader { _ in
                if await counter.next() > 1 { await gate.wait() }
                return bytes
            }
            await loader.load(url: URL(string: "https://gif.example.test/a.gif"), cacheKey: "a", maxPixelSize: 16, requiresGIF: true, retainDecoder: false)
            let preparation = Task { await loader.prepareForPlayback() }
            await gate.waitUntilStarted()
            if offscreen { loader.stop() } else { loader.releaseAnimation() }
            await gate.release()
            let prepared = await preparation.value
            XCTAssertFalse(prepared)
            XCTAssertFalse(loader.retainsDecoder)
            XCTAssertFalse(loader.failed)
            if offscreen { XCTAssertNil(loader.frame) } else { XCTAssertNotNil(loader.frame) }
        }
    }

    func testGIFViewportRejectsOffscreenAndZeroViewportWithoutHistoryScanning() {
        let viewport = CGRect(x: 0, y: 50, width: 300, height: 500)
        XCTAssertTrue(StickerGIFVisibility.intersects(frame: CGRect(x: 10, y: 40, width: 30, height: 30), viewport: viewport))
        XCTAssertFalse(StickerGIFVisibility.intersects(frame: CGRect(x: 10, y: 550, width: 30, height: 30), viewport: viewport))
        XCTAssertFalse(StickerGIFVisibility.intersects(frame: viewport, viewport: .zero))
        XCTAssertFalse(StickerGIFVisibility.intersects(frame: .null, viewport: viewport))
    }

    @MainActor
    func testGIFLoaderURLPixelAndGenerationFenceRejectLateLoadAfterReuseAndStop() async throws {
        let gate = GIFTestDataGate()
        let data = try makeGIFFixture(frameCount: 2, width: 16, height: 16)
        let loader = StickerGIFFrameLoader { url in
            if url.lastPathComponent == "old.gif" { await gate.wait() }
            return data
        }
        let oldURL = URL(string: "https://gif.example.test/old.gif")!
        let newURL = URL(string: "https://gif.example.test/new.gif")!
        let oldLoad = Task { await loader.load(url: oldURL, cacheKey: "same-asset", maxPixelSize: 16, requiresGIF: true) }
        await gate.waitUntilStarted()
        await loader.load(url: newURL, cacheKey: "same-asset", maxPixelSize: 4, requiresGIF: true)
        XCTAssertEqual(loader.loadedIdentity?.url, newURL)
        XCTAssertEqual(loader.loadedIdentity?.maxPixelSize, 4)
        XCTAssertEqual(loader.frame?.image.cgImage?.width, 4)
        await gate.release()
        await oldLoad.value
        XCTAssertEqual(loader.loadedIdentity?.url, newURL)
        XCTAssertEqual(loader.frame?.image.cgImage?.width, 4)
        loader.stop()
        XCTAssertNil(loader.frame)
        XCTAssertNil(loader.loadedIdentity)
        XCTAssertEqual(loader.frameCount, 0)
        XCTAssertFalse(loader.failed)
    }

    @MainActor
    func testGIFLoaderStopCancelsAndDropsLateCompletion() async throws {
        let gate = GIFTestDataGate()
        let data = try makeGIFFixture(frameCount: 2)
        let loader = StickerGIFFrameLoader { _ in await gate.wait(); return data }
        let load = Task { await loader.load(url: URL(string: "https://gif.example.test/a.gif"), cacheKey: "a", maxPixelSize: 32) }
        await gate.waitUntilStarted()
        loader.stop()
        await gate.release()
        await load.value
        XCTAssertNil(loader.frame)
        XCTAssertNil(loader.loadedIdentity)
        XCTAssertEqual(loader.frameCount, 0)
        XCTAssertFalse(loader.failed)
    }

    @MainActor
    func testGIFLoaderRecoversSignedURLOnlyOnceAndSupportsMissingPrimary() async throws {
        let data = try makeGIFFixture(frameCount: 2)
        let attempts = LockedInteger()
        let loader = StickerGIFFrameLoader { _ in
            if attempts.incrementAndGetPrevious() == 0 { throw StickerGIFResourceError.unauthorized }
            return data
        }
        var recoveryCount = 0
        await loader.load(url: URL(string: "https://gif.example.test/expired.gif"), cacheKey: "a", maxPixelSize: 32) {
            recoveryCount += 1
            return URL(string: "https://gif.example.test/fresh.gif")
        }
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(attempts.value(), 2)
        XCTAssertEqual(loader.frameCount, 2)
        let denied = StickerGIFFrameLoader { _ in throw StickerGIFResourceError.unauthorized }
        recoveryCount = 0
        await denied.load(url: nil, cacheKey: "b", maxPixelSize: 32) {
            recoveryCount += 1
            return URL(string: "https://gif.example.test/denied.gif")
        }
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertTrue(denied.failed)
    }

    func testGIFResourceReaderRejectsHTTPFailuresAndUnboundedBodies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaPipelineURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://gif.example.test/a.gif")!
        for (status, expected) in [(403, StickerGIFResourceError.unauthorized), (500, .invalidResponse)] {
            MediaPipelineURLProtocol.reset(statusCode: status, data: Data())
            do { _ = try await StickerGIFResourceReader.read(url, session: session); XCTFail("HTTP failure accepted") }
            catch { XCTAssertEqual(error as? StickerGIFResourceError, expected) }
        }
        MediaPipelineURLProtocol.reset(statusCode: 200, data: Data(repeating: 0, count: StickerGIFResourceReader.maximumBytes + 1))
        do { _ = try await StickerGIFResourceReader.read(url, session: session); XCTFail("Oversized streamed body accepted") }
        catch { XCTAssertEqual(error as? StickerGIFResourceError, .tooLarge) }
        let gif = try makeGIFFixture(frameCount: 2)
        MediaPipelineURLProtocol.reset(statusCode: 200, data: gif)
        let result = try await StickerGIFResourceReader.read(url, session: session)
        XCTAssertEqual(result, gif)
    }

    func testGIFResourceReaderBoundsLocalFilesAndRejectsUnsupportedTransport() async throws {
        let root = makeCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("too-large.gif")
        try Data(repeating: 0, count: StickerGIFResourceReader.maximumBytes + 1).write(to: url)
        do { _ = try await StickerGIFResourceReader.read(url); XCTFail("Oversized local file accepted") }
        catch { XCTAssertEqual(error as? StickerGIFResourceError, .tooLarge) }
        do { _ = try await StickerGIFResourceReader.read(URL(string: "ftp://gif.example.test/a.gif")!); XCTFail("Unsupported transport accepted") }
        catch { XCTAssertEqual(error as? StickerGIFResourceError, .invalidTransport) }
    }

    private func publicTransparentGIFFixture(disposal: UInt8? = nil) throws -> Data {
        // Source: google/wuffs test/data/artificial-gif/transparent-index.gif
        // https://github.com/google/wuffs/blob/main/test/data/artificial-gif/transparent-index.gif
        // Copyright The Wuffs Authors; Apache-2.0 (see bundled Wuffs license).
        // The original 165-byte fixture has a 4x2 red frame and a 3x1 blue overlay
        // whose middle pixel is transparent. Derived variants change only frame 2's
        // disposal bits and append a one-pixel third frame to observe disposal.
        var data = try XCTUnwrap(Data(base64Encoded: "R0lGODlhBAACAIQAAAAAABAAACAAADAAAEAAAFAAAGAAAHAAAIAAAJAAAKAAALAAAMAAANAAAOAAAPAAAAAAAAAAEQAAIgAAMwAARAAAVQAAZgAAdwAAiAAAmQAAqgAAuwAAzAAA3QAA7gAA/yH5BAAKAAAALAAAAAAEAAIAAAcJCAkKCwwNDg+BACH5BAEUABoALAEAAQADAAEAAAcEHxoVgQA7"))
        if let disposal {
            XCTAssertTrue(disposal == 2 || disposal == 3)
            XCTAssertEqual(Array(data[139...142]), [0x21, 0xf9, 0x04, 0x01])
            data[142] = 0x01 | (disposal << 2)
            XCTAssertEqual(data.removeLast(), 0x3b)
            data.append(contentsOf: [
                0x21, 0xf9, 4, 0, 30, 0, 0, 0, // GCE, 300 ms, keep frame.
                0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, // One pixel at (0, 0).
                7, 2, 1, 0x81, 0, 0x3b // Literal palette index 1, LZW end, trailer.
            ])
        }
        return data
    }

    private func fallbackBGRA(_ frame: StickerGIFDecodedFrame, x: Int, y: Int) throws -> [UInt8] {
        let image = try XCTUnwrap(frame.image.cgImage)
        XCTAssertEqual(image.alphaInfo, .premultipliedFirst)
        XCTAssertTrue(image.bitmapInfo.contains(.byteOrder32Little))
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let start = y * image.bytesPerRow + x * 4
        guard x >= 0, y >= 0, x < image.width, y < image.height, start + 4 <= bytes.count else {
            XCTFail("pixel coordinate outside decoded buffer")
            return []
        }
        return Array(bytes[start..<(start + 4)])
    }

    private func makeGIFFrame(width: Int, height: Int, blue: Bool, textured: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: blue ? 0 : 1, green: 0, blue: blue ? 1 : 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if textured {
            for y in stride(from: 0, to: height, by: 16) {
                for x in stride(from: 0, to: width, by: 16) {
                    let shade = (x / 16 + y / 16 * 7 + (blue ? 5 : 0)) % 64
                    context.setFillColor(red: CGFloat(shade % 4) / 3, green: CGFloat(shade / 4 % 4) / 3, blue: CGFloat(shade / 16) / 3, alpha: 1)
                    context.fill(CGRect(x: x, y: y, width: 16, height: 16))
                }
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeGIFFixture(frameCount: Int, width: Int = 2, height: Int = 2, delay: Double = 0.1, textured: Bool = false) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frameCount, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frameCount {
            let frame = try makeGIFFrame(width: width, height: height, blue: !index.isMultiple(of: 2), textured: textured)
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeExecutor() -> MediaURLSessionDownloadExecutor {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaPipelineURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return MediaURLSessionDownloadExecutor(session: session, policy: makePolicy())
    }

    private func makePolicy() -> MediaCachePolicy {
        MediaCachePolicy(
            memoryCostLimitBytes: 1024 * 1024,
            diskCapacityBytes: 16 * 1024 * 1024,
            maxConcurrentDownloads: 2,
            signatureRefreshLeadTime: 60,
            allowsCellularAutoDownload: true
        )
    }

    private func makeRequest(cacheKey: String, preferredExtension: String) -> MediaDownloadRequest {
        MediaDownloadRequest(
            identity: MediaPipelineCore.identity(
                kind: .original,
                scope: Self.fixtureScopeHash,
                cacheKey: cacheKey,
                version: "v1",
                mimeType: "text/plain"
            ),
            source: .provider(key: "stage63-provider"),
            priority: .userInitiated,
            preferredExtension: preferredExtension
        )
    }

    private static let fixtureScopeHash = "e509910b43a3327ea9c268a03a596337ba6a60074e314d666ad8795c9ef66494"

    private func cacheContractFixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/api/message-media-cache-v1/fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private func makeCacheRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("media-pipeline-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func collectEvents(
        from stream: AsyncStream<MediaDownloadExecutorEvent>
    ) async -> [MediaDownloadExecutorEvent] {
        var events: [MediaDownloadExecutorEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }
}

private actor GIFTestReadCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private struct FrozenIdentityFixture: Decodable {
    let fixtureVersion: Int
    let vectors: [Vector]

    struct Vector: Decodable {
        let id: String
        let scope: Scope
        let scopeCanonical: String
        let scopeHash: String
        let resourceIDKind: String
        let resourceID: String
        let contentVersionKind: String
        let contentVersion: String
        let variant: String
        let cacheCanonical: String
        let cacheIdentity: String

        enum CodingKeys: String, CodingKey {
            case id, scope, variant
            case scopeCanonical = "scope_canonical"
            case scopeHash = "scope_hash"
            case resourceIDKind = "resource_id_kind"
            case resourceID = "resource_id"
            case contentVersionKind = "content_version_kind"
            case contentVersion = "content_version"
            case cacheCanonical = "cache_canonical"
            case cacheIdentity = "cache_identity"
        }
    }

    struct Scope: Decodable {
        let accountID: String
        let tenantID: String
        let appID: String
        let imUID: String
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case tenantID = "tenant_id"
            case appID = "app_id"
            case imUID = "im_uid"
            case deviceID = "device_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fixtureVersion = "fixture_version"
        case vectors
    }
}

private final class MediaPipelineURLProtocol: URLProtocol {
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

private actor GIFTestDataGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    func wait() async {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    func incrementAndGetPrevious() -> Int {
        lock.withLock {
            let previous = storedValue
            storedValue += 1
            return previous
        }
    }

    func value() -> Int {
        lock.withLock { storedValue }
    }
}

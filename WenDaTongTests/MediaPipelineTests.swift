import CryptoKit
import Foundation
import ImageIO
import UIKit
import XCTest
@testable import WenDaTong
@testable import IM4Features // WDT_IOS1_FEATURES_CALLS_UI_20261111

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

    static let fixtureScopeHash = "e509910b43a3327ea9c268a03a596337ba6a60074e314d666ad8795c9ef66494"

    func makeCacheRoot() -> URL {
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

final class MediaPipelineURLProtocol: URLProtocol {
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

final class LockedInteger: @unchecked Sendable {
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

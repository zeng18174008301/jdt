import CryptoKit
import Foundation
import XCTest
@testable import WenDaTong

extension FilePreviewTests {
    func testSystemPreviewDownloadStoreTreatsCompletedPreviewAsTransientMaterialization() async throws {
        let downloader = FakeSystemPreviewDownloader(results: [
            .success(Data("cached-preview".utf8)),
            .success(Data("cached-preview".utf8))
        ])
        let store = SystemPreviewDownloadStore(downloader: downloader)
        let remoteURL = try XCTUnwrap(URL(string: "https://files.example.test/report.pdf"))
        let identity = "stage61-cache-\(UUID().uuidString)"

        let firstURL = try await store.download(remoteURL, suggestedName: "report.pdf", cacheIdentity: identity)
        let secondURL = try await store.download(remoteURL, suggestedName: "report.pdf", cacheIdentity: identity)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("cached-preview".utf8))
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("cached-preview".utf8))
        let requests = await downloader.requestedURLStrings()
        XCTAssertEqual(requests, [
            "https://files.example.test/report.pdf",
            "https://files.example.test/report.pdf"
        ])
        try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
    }

    func testSystemPreviewDownloadStoreCreatesTransientPreviewWithoutCacheIdentity() async throws {
        let downloader = FakeSystemPreviewDownloader(results: [
            .success(Data("transient-preview".utf8))
        ])
        let store = SystemPreviewDownloadStore(downloader: downloader)
        let remoteURL = try XCTUnwrap(URL(string: "https://files.example.test/raw"))

        let localURL = try await store.download(remoteURL, suggestedName: " unsafe/name ", cacheIdentity: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertEqual(localURL.lastPathComponent, "unsafe-name")
        XCTAssertEqual(try Data(contentsOf: localURL), Data("transient-preview".utf8))
        let requests = await downloader.requestedURLStrings()
        XCTAssertEqual(requests, ["https://files.example.test/raw"])
        try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
    }

    func testSystemPreviewDownloadStoreDedupesInFlightCachedPreview() async throws {
        let downloader = FakeSystemPreviewDownloader(results: [
            .success(Data("deduped-preview".utf8), delayNanoseconds: 50_000_000)
        ])
        let store = SystemPreviewDownloadStore(downloader: downloader)
        let remoteURL = try XCTUnwrap(URL(string: "https://files.example.test/manual.docx"))
        let identity = "stage61-inflight-\(UUID().uuidString)"

        async let firstURL = store.download(remoteURL, suggestedName: "manual.docx", cacheIdentity: identity)
        async let secondURL = store.download(remoteURL, suggestedName: "manual.docx", cacheIdentity: identity)
        let urls = try await [firstURL, secondURL]

        XCTAssertNotEqual(urls[0], urls[1])
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data("deduped-preview".utf8))
        XCTAssertEqual(try Data(contentsOf: urls[1]), Data("deduped-preview".utf8))
        let requests = await downloader.requestedURLStrings()
        XCTAssertEqual(requests.count, 1)
        try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent())
        try? FileManager.default.removeItem(at: urls[1].deletingLastPathComponent())
    }

    func testSystemPreviewDownloadStoreClearsInFlightAfterDownloadFailure() async throws {
        let downloader = FakeSystemPreviewDownloader(results: [
            .failure(FakeSystemPreviewDownloadError.failed),
            .success(Data("recovered-preview".utf8))
        ])
        let store = SystemPreviewDownloadStore(downloader: downloader)
        let remoteURL = try XCTUnwrap(URL(string: "https://files.example.test/retry.pptx"))
        let identity = "stage61-retry-\(UUID().uuidString)"

        do {
            _ = try await store.download(remoteURL, suggestedName: "retry.pptx", cacheIdentity: identity)
            XCTFail("Expected first download to fail")
        } catch FakeSystemPreviewDownloadError.failed {
        }

        let recoveredURL = try await store.download(remoteURL, suggestedName: "retry.pptx", cacheIdentity: identity)

        XCTAssertEqual(try Data(contentsOf: recoveredURL), Data("recovered-preview".utf8))
        let requests = await downloader.requestedURLStrings()
        XCTAssertEqual(requests.count, 2)
        try? FileManager.default.removeItem(at: recoveredURL.deletingLastPathComponent())
    }

    func testURLSessionSystemPreviewDownloaderUsesInjectedSessionAndReturnsTemporaryFile() async throws {
        let payload = Data("preview-downloader".utf8)
        SystemPreviewURLProtocol.reset(statusCode: 200, data: payload)
        let remoteURL = try XCTUnwrap(URL(string: "https://files.example.test/download/manual.pdf"))
        let downloader = URLSessionSystemPreviewDownloader(session: makeURLProtocolSession())

        let temporaryURL = try await downloader.download(from: remoteURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        XCTAssertEqual(try Data(contentsOf: temporaryURL), payload)
        XCTAssertEqual(SystemPreviewURLProtocol.recordedRequests().map(\.url), [remoteURL])
    }

    func testURLSessionSystemPreviewDownloaderRejectsHTTPFailure() async throws {
        SystemPreviewURLProtocol.reset(statusCode: 404, data: Data("missing".utf8))
        let remoteURL = try XCTUnwrap(URL(string: "https://files.example.test/download/missing.pdf"))
        let downloader = URLSessionSystemPreviewDownloader(session: makeURLProtocolSession())

        do {
            _ = try await downloader.download(from: remoteURL)
            XCTFail("Expected HTTP failure")
        } catch let error as SystemPreviewDownloadHTTPStatusError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertEqual(error.requestURL, remoteURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(SystemPreviewURLProtocol.recordedRequests().map(\.url), [remoteURL])
    }

    private func makeURLProtocolSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SystemPreviewURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private enum FakeSystemPreviewDownloadError: Error {
    case failed
}

private enum FakeSystemPreviewDownloadResult {
    case success(Data, delayNanoseconds: UInt64 = 0)
    case failure(Error)
}

private actor FakeSystemPreviewDownloader: SystemPreviewDownloading {
    private var results: [FakeSystemPreviewDownloadResult]
    private var requestedURLs: [URL] = []

    init(results: [FakeSystemPreviewDownloadResult]) {
        self.results = results
    }

    func download(from remoteURL: URL) async throws -> URL {
        requestedURLs.append(remoteURL)
        let result = results.isEmpty ? .success(Data()) : results.removeFirst()
        switch result {
        case .success(let data, let delayNanoseconds):
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-system-preview-\(UUID().uuidString)", isDirectory: false)
            try data.write(to: temporaryURL, options: .atomic)
            return temporaryURL
        case .failure(let error):
            throw error
        }
    }

    func requestedURLStrings() -> [String] {
        requestedURLs.map(\.absoluteString)
    }
}

private final class SystemPreviewURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var data = Data()
    nonisolated(unsafe) private static var error: Error?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(statusCode: Int = 200, data: Data = Data(), error: Error? = nil) {
        lock.lock()
        self.statusCode = statusCode
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
        Self.requests.append(request)
        let statusCode = Self.statusCode
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

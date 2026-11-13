import ImageIO
import UIKit
import SwiftUI
import XCTest
@testable import WenDaTong

extension DesignSystemTests {
    func testAvatarImageCacheRemoteImageUsesInjectedTransportAndCachesSuccessfulImage() async throws {
        let transport = FakeRemoteImageTransport(results: [
            RemoteImageTransportResult(data: Self.makePNGData(), statusCode: 200)
        ])
        let cache = AvatarImageCache(imageTransport: transport)

        let image = await cache.remoteImage(
            for: " https://image.example.test/avatar.png ",
            cacheKey: " avatar-key "
        )

        XCTAssertNotNil(image)
        XCTAssertNotNil(cache.peekImage(for: "avatar-key"))
        let firstRequests = await transport.requestedURLStrings()
        XCTAssertEqual(firstRequests, ["https://image.example.test/avatar.png"])

        let cachedImage = await cache.remoteImage(
            for: "https://image.example.test/avatar.png",
            cacheKey: "avatar-key"
        )
        XCTAssertNotNil(cachedImage)
        let secondRequests = await transport.requestedURLStrings()
        XCTAssertEqual(secondRequests.count, 1)
    }

    func testAvatarImageCacheRemoteImageDoesNotCacheHTTPFailure() async throws {
        let transport = FakeRemoteImageTransport(results: [
            RemoteImageTransportResult(data: Self.makePNGData(), statusCode: 404)
        ])
        let cache = AvatarImageCache(imageTransport: transport)

        let image = await cache.remoteImage(
            for: "https://image.example.test/missing.png",
            cacheKey: "missing-key"
        )

        XCTAssertNil(image)
        XCTAssertNil(cache.peekImage(for: "missing-key"))
        let requests = await transport.requestedURLStrings()
        XCTAssertEqual(requests, ["https://image.example.test/missing.png"])
    }

    func testGroupAvatarCacheIdentityScopesTenantGroupMemberAndVersionWithoutSignedURLMaterial() throws {
        let first = GroupAvatarCacheIdentity.cacheKey(
            groupID: "group-a",
            memberID: "member-a",
            stableAssetIdentity: "/api/tenant/avatar/file-a",
            version: "v1"
        )
        let otherGroup = GroupAvatarCacheIdentity.cacheKey(
            groupID: "group-b",
            memberID: "member-a",
            stableAssetIdentity: "/api/tenant/avatar/file-a",
            version: "v1"
        )
        let otherMember = GroupAvatarCacheIdentity.cacheKey(
            groupID: "group-a",
            memberID: "member-b",
            stableAssetIdentity: "/api/tenant/avatar/file-a",
            version: "v1"
        )
        let nextVersion = GroupAvatarCacheIdentity.cacheKey(
            groupID: "group-a",
            memberID: "member-a",
            stableAssetIdentity: "/api/tenant/avatar/file-a",
            version: "v2"
        )

        XCTAssertFalse(first.isEmpty)
        XCTAssertNotEqual(first, otherGroup)
        XCTAssertNotEqual(first, otherMember)
        XCTAssertNotEqual(first, nextVersion)
        XCTAssertFalse(first.contains("?"))
        XCTAssertFalse(first.localizedCaseInsensitiveContains("signature"))
        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(
                "/api/tenant/avatar/file-a",
                routeContext: nil
            )
        )
        let tenantA = Self.makeRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 1,
            routeHosts: ["tenant-a.example.test"]
        )
        let tenantB = Self.makeRouteContext(
            authorityID: "app-a|tenant-b",
            revision: 1,
            routeHosts: ["tenant-b.example.test"]
        )
        XCTAssertNotEqual(
            request.storageCacheKey(first, routeContext: tenantA),
            request.storageCacheKey(first, routeContext: tenantB)
        )
    }

    func testGroupAvatarImageRetryIsBoundedAndCachesOnlySuccessfulAttempt() async throws {
        let transport = FakeRemoteImageTransport(results: [])
        let fetcher = SequencedAvatarRouteFetcher(results: [Data(), Self.makePNGData()])
        let cache = AvatarImageCache(imageTransport: transport)
        let routeContext = AvatarImageRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 21,
            routeBases: [URL(string: "https://tenant-a.example.test")!],
            fetcher: { path in
                await fetcher.fetch(path)
            }
        )
        let path = "/api/tenant/avatar/group-file"
        let cacheKey = GroupAvatarCacheIdentity.cacheKey(
            groupID: "group-a",
            memberID: "member-a",
            stableAssetIdentity: path,
            version: "version-2"
        )

        let image = await cache.remoteImage(
            for: path,
            routeContext: routeContext,
            cacheKey: cacheKey,
            retryPolicy: AvatarImageRetryPolicy(maximumAttempts: 2, delayNanoseconds: 0)
        )

        XCTAssertNotNil(image)
        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(path, routeContext: routeContext)
        )
        let storageKey = try XCTUnwrap(
            request.storageCacheKey(cacheKey, routeContext: routeContext)
        )
        XCTAssertNotNil(cache.peekImage(for: storageKey))
        let requestCount = await fetcher.requestCount()
        let directRequests = await transport.requestedURLStrings()
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(directRequests.isEmpty)
    }

    func testGroupAvatarLateOldVersionStateCannotPublishIntoNewerIdentity() throws {
        let path = "/api/tenant/avatar/group-file"
        let routeContext = Self.makeRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 22,
            routeHosts: ["tenant-a.example.test"]
        )
        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(path, routeContext: routeContext)
        )
        let oldKey = GroupAvatarCacheIdentity.cacheKey(
            groupID: "group-a",
            memberID: "member-a",
            stableAssetIdentity: path,
            version: "version-1"
        )
        let newKey = GroupAvatarCacheIdentity.cacheKey(
            groupID: "group-a",
            memberID: "member-a",
            stableAssetIdentity: path,
            version: "version-2"
        )
        let oldIdentity = request.loadIdentity(
            routeContext: routeContext,
            cacheKey: oldKey,
            maxPixelSize: 256
        )
        let newIdentity = request.loadIdentity(
            routeContext: routeContext,
            cacheKey: newKey,
            maxPixelSize: 256
        )
        let lateOldState = CachedRemoteImageState(identity: oldIdentity, image: UIImage())

        XCTAssertNotEqual(oldKey, newKey)
        XCTAssertNotEqual(oldIdentity, newIdentity)
        XCTAssertNil(lateOldState.visibleImage(currentIdentity: newIdentity, isAuthorized: true))
        XCTAssertNotNil(lateOldState.visibleImage(currentIdentity: oldIdentity, isAuthorized: true))
    }

    func testGroupAvatarRetryStopsAfterBoundedFailureWithoutCachingPlaceholder() async throws {
        let transport = FakeRemoteImageTransport(results: [])
        let fetcher = SequencedAvatarRouteFetcher(results: [Data(), Data(), Self.makePNGData()])
        let cache = AvatarImageCache(imageTransport: transport)
        let routeContext = AvatarImageRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 23,
            routeBases: [URL(string: "https://tenant-a.example.test")!],
            fetcher: { path in
                await fetcher.fetch(path)
            }
        )
        let path = "/api/tenant/avatar/group-file"
        let cacheKey = GroupAvatarCacheIdentity.cacheKey(
            groupID: "group-a",
            memberID: "member-a",
            stableAssetIdentity: path,
            version: "version-error"
        )

        let image = await cache.remoteImage(
            for: path,
            routeContext: routeContext,
            cacheKey: cacheKey,
            retryPolicy: AvatarImageRetryPolicy(maximumAttempts: 2, delayNanoseconds: 0)
        )

        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(path, routeContext: routeContext)
        )
        let storageKey = try XCTUnwrap(
            request.storageCacheKey(cacheKey, routeContext: routeContext)
        )
        let requestCount = await fetcher.requestCount()
        XCTAssertNil(image)
        XCTAssertNil(cache.peekImage(for: storageKey))
        XCTAssertEqual(requestCount, 2)
    }

    func testTenantRelativeAvatarUsesInjectedFetcherAndNeverFallsBackToPlainTransport() async throws {
        let transport = FakeRemoteImageTransport(results: [])
        let routeFetcher = FakeAvatarRouteFetcher(data: Self.makePNGData())
        let routeContext = AvatarImageRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 11,
            routeBases: [
                URL(string: "https://tenant.example.test")!,
                URL(string: "https://tenant-cf.example.test")!
            ],
            fetcher: { path in
                await routeFetcher.fetch(path)
            }
        )
        let cache = AvatarImageCache(imageTransport: transport)
        let relativePath = "/api/tenant/static/avatars/default-user.webp"
        let stableKey = AvatarImageCache.cacheKey(url: relativePath, version: "version-11")

        let image = await cache.remoteImage(
            for: relativePath,
            routeContext: routeContext,
            cacheKey: stableKey
        )

        XCTAssertNotNil(image)
        let routedPaths = await routeFetcher.requestedPaths()
        let directRequests = await transport.requestedURLStrings()
        XCTAssertEqual(routedPaths, [relativePath])
        XCTAssertTrue(directRequests.isEmpty)
        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(relativePath, routeContext: routeContext)
        )
        let storageKey = try XCTUnwrap(request.storageCacheKey(stableKey, routeContext: routeContext))
        XCTAssertNotNil(cache.peekImage(for: storageKey))

        let missingContextCache = AvatarImageCache(imageTransport: transport)
        let missingContextImage = await missingContextCache.remoteImage(
            for: relativePath,
            routeContext: nil,
            cacheKey: stableKey
        )
        XCTAssertNil(missingContextImage)
        let directRequestsAfterMissingContext = await transport.requestedURLStrings()
        XCTAssertTrue(directRequestsAfterMissingContext.isEmpty)
    }

    func testTenantSwitchDiscardsLateRelativeAvatarFetchResult() async throws {
        let transport = FakeRemoteImageTransport(results: [])
        let authority = AvatarRouteAuthorityBox()
        let relativePath = "/api/tenant/avatar/current"
        let routeContext = AvatarImageRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 12,
            routeBases: [URL(string: "https://tenant.example.test")!],
            fetcher: { _ in
                authority.isCurrent = false
                return Self.makePNGData()
            },
            authorityCheck: {
                authority.isCurrent
            }
        )
        let cache = AvatarImageCache(imageTransport: transport)
        let stableKey = AvatarImageCache.cacheKey(url: relativePath, version: "version-12")

        let image = await cache.remoteImage(
            for: relativePath,
            routeContext: routeContext,
            cacheKey: stableKey
        )

        XCTAssertNil(image)
        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(relativePath, routeContext: routeContext)
        )
        let storageKey = try XCTUnwrap(request.storageCacheKey(stableKey, routeContext: routeContext))
        XCTAssertNil(cache.peekImage(for: storageKey))
        let directRequests = await transport.requestedURLStrings()
        XCTAssertTrue(directRequests.isEmpty)
    }

    func testStaleTenantRouteContextCannotReadPrepopulatedAvatarCache() async throws {
        let transport = FakeRemoteImageTransport(results: [])
        let routeFetcher = FakeAvatarRouteFetcher(data: Self.makePNGData())
        let authority = AvatarRouteAuthorityBox()
        authority.isCurrent = false
        let relativePath = "/api/tenant/avatar/current"
        let routeContext = AvatarImageRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 14,
            routeBases: [URL(string: "https://tenant.example.test")!],
            fetcher: { path in
                await routeFetcher.fetch(path)
            },
            authorityCheck: {
                authority.isCurrent
            }
        )
        let cache = AvatarImageCache(imageTransport: transport)
        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(relativePath, routeContext: routeContext)
        )
        let stableKey = AvatarImageCache.cacheKey(url: relativePath, version: "version-14")
        let storageKey = try XCTUnwrap(request.storageCacheKey(stableKey, routeContext: routeContext))
        cache.store(Self.makePNGData(), for: storageKey)
        XCTAssertNotNil(cache.peekImage(for: storageKey))

        let image = await cache.remoteImage(
            for: relativePath,
            routeContext: routeContext,
            cacheKey: stableKey
        )

        XCTAssertNil(image)
        XCTAssertFalse(request.isAuthorized(routeContext: routeContext))
        let routedPaths = await routeFetcher.requestedPaths()
        let directRequests = await transport.requestedURLStrings()
        XCTAssertTrue(routedPaths.isEmpty)
        XCTAssertTrue(directRequests.isEmpty)
    }

    func testCachedRemoteImageStateDoesNotCrossTenantForSameRelativePath() throws {
        let relativePath = "/api/tenant/avatar/current"
        let tenantA = Self.makeRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 14,
            routeHosts: ["tenant-a.example.test"]
        )
        let tenantB = Self.makeRouteContext(
            authorityID: "app-a|tenant-b",
            revision: 14,
            routeHosts: ["tenant-b.example.test"]
        )
        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(relativePath, routeContext: tenantA)
        )
        let stableCacheKey = AvatarImageCache.cacheKey(url: relativePath, version: "version-14")
        let tenantAIdentity = request.loadIdentity(
            routeContext: tenantA,
            cacheKey: stableCacheKey,
            maxPixelSize: 256
        )
        let tenantBIdentity = request.loadIdentity(
            routeContext: tenantB,
            cacheKey: stableCacheKey,
            maxPixelSize: 256
        )
        let state = CachedRemoteImageState(identity: tenantAIdentity, image: UIImage())

        XCTAssertNotNil(state.visibleImage(currentIdentity: tenantAIdentity, isAuthorized: true))
        XCTAssertNil(state.visibleImage(currentIdentity: tenantBIdentity, isAuthorized: true))
        XCTAssertNil(state.visibleImage(currentIdentity: tenantAIdentity, isAuthorized: false))
        XCTAssertNotEqual(tenantAIdentity, tenantBIdentity)
    }

    func testAttachmentThumbnailMemoryIdentityIsGenerationScoped() {
        let first = AttachmentThumbnailCacheIdentity.generationKey(
            baseKey: "attachment-thumbnail-v1",
            generation: 41
        )
        let second = AttachmentThumbnailCacheIdentity.generationKey(
            baseKey: "attachment-thumbnail-v1",
            generation: 42
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, "generation:41|attachment-thumbnail-v1")
        XCTAssertEqual(
            first,
            AttachmentThumbnailCacheIdentity.generationKey(
                baseKey: "attachment-thumbnail-v1",
                generation: 41
            )
        )
    }

    func testAbsolutePresignedAvatarRemainsDirectAndPreservesQuery() async {
        let transport = FakeRemoteImageTransport(results: [
            RemoteImageTransportResult(data: Self.makePNGData(), statusCode: 200)
        ])
        let routeFetcher = FakeAvatarRouteFetcher(data: Data())
        let routeContext = AvatarImageRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 13,
            routeBases: [URL(string: "https://tenant.example.test")!],
            fetcher: { path in
                await routeFetcher.fetch(path)
            }
        )
        let cache = AvatarImageCache(imageTransport: transport)
        let absolute = "https://oss.example.test/avatar/object?X-Signature=opaque&version=3"

        let image = await cache.remoteImage(
            for: absolute,
            routeContext: routeContext,
            cacheKey: AvatarImageCache.cacheKey(url: absolute, version: "3")
        )

        XCTAssertNotNil(image)
        let directRequests = await transport.requestedURLStrings()
        let routedPaths = await routeFetcher.requestedPaths()
        XCTAssertEqual(directRequests, [absolute])
        XCTAssertTrue(routedPaths.isEmpty)
    }

    func testDataAvatarURLDecodesLocallyWithoutNetworkTransport() async {
        let transport = FakeRemoteImageTransport(results: [])
        let cache = AvatarImageCache(imageTransport: transport)
        let dataURL = "data:image/png;base64,\(Self.makePNGData().base64EncodedString())"

        let image = await cache.remoteImage(for: dataURL, cacheKey: "data-avatar")

        XCTAssertNotNil(image)
        let directRequests = await transport.requestedURLStrings()
        XCTAssertTrue(directRequests.isEmpty)
    }

    func testAvatarImageCacheLocalFileURLBypassesInjectedTransport() async throws {
        let transport = FakeRemoteImageTransport(results: [])
        let cache = AvatarImageCache(imageTransport: transport)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-image-cache-\(UUID().uuidString).png")
        try Self.makePNGData().write(to: fileURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let image = await cache.remoteImage(for: fileURL.absoluteString, cacheKey: "local-key")

        XCTAssertNotNil(image)
        XCTAssertNotNil(cache.peekImage(for: "local-key"))
        let requests = await transport.requestedURLStrings()
        XCTAssertTrue(requests.isEmpty)
    }

    func testURLSessionRemoteImageTransportUsesInjectedSessionAndPreservesStatusCode() async throws {
        let payload = Data("remote-image-data".utf8)
        RemoteImageURLProtocol.reset(statusCode: 206, data: payload)
        let remoteURL = try XCTUnwrap(URL(string: "https://image.example.test/raw/avatar.bin"))
        let transport = URLSessionRemoteImageTransport(session: Self.makeURLProtocolSession())

        let result = try await transport.data(from: remoteURL)

        XCTAssertEqual(result.data, payload)
        XCTAssertEqual(result.statusCode, 206)
        XCTAssertEqual(RemoteImageURLProtocol.recordedRequests().map(\.url), [remoteURL])
    }

    func testAttachmentThumbnailTransportDecodesWithoutWritingParallelDiskCache() async throws {
        let transport = FakeRemoteImageTransport(results: [
            RemoteImageTransportResult(data: Self.makePNGData(), statusCode: 200)
        ])
        let cacheKey = "stage62-thumbnail-\(UUID().uuidString)"
        let remoteURL = try XCTUnwrap(URL(string: "https://image.example.test/thumb.png"))

        let image = await AttachmentThumbnailDiskCache.downloadImage(
            from: remoteURL,
            cacheKey: cacheKey,
            imageTransport: transport
        )

        XCTAssertNotNil(image)
        let requests = await transport.requestedURLStrings()
        XCTAssertEqual(requests, [remoteURL.absoluteString])
        let cached = await AttachmentThumbnailDiskCache.image(for: cacheKey)
        XCTAssertNil(cached)
    }

    func testAttachmentThumbnailDiskCacheDownloadDoesNotStoreHTTPFailure() async throws {
        let transport = FakeRemoteImageTransport(results: [
            RemoteImageTransportResult(data: Self.makePNGData(), statusCode: 404)
        ])
        let cacheKey = "stage62-thumbnail-missing-\(UUID().uuidString)"
        let remoteURL = try XCTUnwrap(URL(string: "https://image.example.test/missing-thumb.png"))

        let image = await AttachmentThumbnailDiskCache.downloadImage(
            from: remoteURL,
            cacheKey: cacheKey,
            imageTransport: transport
        )

        XCTAssertNil(image)
        let requests = await transport.requestedURLStrings()
        XCTAssertEqual(requests, [remoteURL.absoluteString])
        let cached = await AttachmentThumbnailDiskCache.image(for: cacheKey)
        XCTAssertNil(cached)
    }

    func testAttachmentThumbnailDiskCacheFileURLBypassesInjectedTransport() async throws {
        let transport = FakeRemoteImageTransport(results: [])
        let cacheKey = "stage62-thumbnail-local-\(UUID().uuidString)"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-thumbnail-\(UUID().uuidString).png")
        try Self.makePNGData().write(to: fileURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let image = await AttachmentThumbnailDiskCache.downloadImage(
            from: fileURL,
            cacheKey: cacheKey,
            imageTransport: transport
        )

        XCTAssertNotNil(image)
        let requests = await transport.requestedURLStrings()
        XCTAssertTrue(requests.isEmpty)
        let cached = await AttachmentThumbnailDiskCache.image(for: cacheKey)
        XCTAssertNil(cached)
    }

    static func makeRouteContext(
        authorityID: String,
        revision: UInt64,
        routeHosts: Set<String>
    ) -> AvatarImageRouteContext {
        AvatarImageRouteContext(
            authorityID: authorityID,
            revision: revision,
            routeBases: routeHosts.compactMap { URL(string: "https://\($0)") },
            fetcher: { _ in Data() }
        )
    }

    private static func makeURLProtocolSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteImageURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
private final class AvatarRouteAuthorityBox {
    var isCurrent = true
}

private actor FakeAvatarRouteFetcher {
    private let data: Data
    private var paths: [String] = []

    init(data: Data) {
        self.data = data
    }

    func fetch(_ path: String) -> Data {
        paths.append(path)
        return data
    }

    func requestedPaths() -> [String] {
        paths
    }
}

private actor SequencedAvatarRouteFetcher {
    private var results: [Data]
    private var paths: [String] = []

    init(results: [Data]) {
        self.results = results
    }

    func fetch(_ path: String) -> Data {
        paths.append(path)
        return results.isEmpty ? Data() : results.removeFirst()
    }

    func requestCount() -> Int {
        paths.count
    }
}

private actor FakeRemoteImageTransport: RemoteImageTransporting {
    private var results: [RemoteImageTransportResult]
    private var requestedURLs: [URL] = []

    init(results: [RemoteImageTransportResult]) {
        self.results = results
    }

    func data(from url: URL) async throws -> RemoteImageTransportResult {
        requestedURLs.append(url)
        if results.isEmpty {
            return RemoteImageTransportResult(data: Data(), statusCode: 204)
        }
        return results.removeFirst()
    }

    func requestedURLStrings() -> [String] {
        requestedURLs.map(\.absoluteString)
    }
}

private final class RemoteImageURLProtocol: URLProtocol {
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

// WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
actor SuspendedImageTransport: RemoteImageTransporting {
    let data: Data
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(data: Data) { self.data = data }
    func data(from url: URL) async throws -> RemoteImageTransportResult {
        requestCount += 1
        await withCheckedContinuation { continuation = $0 }
        return RemoteImageTransportResult(data: data, statusCode: 200)
    }
    func resume() { continuation?.resume(); continuation = nil }
}
// WDT_IOS1_IMAGE_BUDGET_20261023_END

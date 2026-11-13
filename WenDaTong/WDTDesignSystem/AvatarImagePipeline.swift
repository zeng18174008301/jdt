import Foundation
import ImageIO
import IM4Data
import SwiftUI
import UIKit

typealias RemoteImageTransportResult = IM4Data.RemoteImageTransportResult // WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111

typealias RemoteImageTransporting = IM4Data.RemoteImageTransporting // WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111

struct AvatarImageRetryPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let delayNanoseconds: UInt64

    init(maximumAttempts: Int, delayNanoseconds: UInt64) {
        self.maximumAttempts = max(1, min(maximumAttempts, 3))
        self.delayNanoseconds = min(delayNanoseconds, 2_000_000_000)
    }

    static let none = AvatarImageRetryPolicy(maximumAttempts: 1, delayNanoseconds: 0)
    static let groupAvatar = AvatarImageRetryPolicy(maximumAttempts: 2, delayNanoseconds: 350_000_000)
}

enum GroupAvatarCacheIdentity {
    nonisolated static func cacheKey(
        groupID: String,
        memberID: String,
        stableAssetIdentity: String,
        version: String,
        updatedAt: String = ""
    ) -> String {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMemberID = memberID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAsset = stableAssetIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty,
              !normalizedMemberID.isEmpty,
              let parsedAsset = URL(string: normalizedAsset),
              parsedAsset.host == nil,
              parsedAsset.query == nil,
              parsedAsset.fragment == nil,
              TenantRelativeImageURLResolver.isStableTenantAvatarPath(parsedAsset.path) else {
            return ""
        }
        let revision = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackRevision = updatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let revisionToken = revision.isEmpty ? fallbackRevision : revision
        return "group_avatar|group=\(stableToken(normalizedGroupID))|member=\(stableToken(normalizedMemberID))|asset=\(parsedAsset.path)|version=\(stableToken(revisionToken))"
    }

    private nonisolated static func stableToken(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

typealias URLSessionRemoteImageTransport = IM4Data.URLSessionRemoteImageTransport // WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111

struct AvatarImageRouteOrigin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard url.user == nil,
              url.password == nil,
              let rawScheme = url.scheme?.lowercased(),
              let rawHost = url.host?.lowercased() else {
            return nil
        }
        let defaultPort: Int
        switch rawScheme {
        case "https": defaultPort = 443
        case "http": defaultPort = 80
        default: return nil
        }
        scheme = rawScheme
        host = rawHost
        port = url.port ?? defaultPort
    }
}

struct AvatarImageRouteContext: Sendable {
    let authorityID: String
    let revision: UInt64
    let routeOrigins: Set<AvatarImageRouteOrigin>
    private let fetcher: @MainActor @Sendable (String) async throws -> Data
    private let authorityCheck: @MainActor @Sendable () -> Bool

    init(
        authorityID: String,
        revision: UInt64,
        routeBases: [URL],
        fetcher: @escaping @MainActor @Sendable (String) async throws -> Data,
        authorityCheck: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.authorityID = authorityID
        self.revision = revision
        routeOrigins = Set(routeBases.compactMap(AvatarImageRouteOrigin.init(url:)))
        self.fetcher = fetcher
        self.authorityCheck = authorityCheck
    }

    var requestIdentity: String {
        "\(authorityID)#route_revision=\(revision)"
    }

    func matchesRouteOrigin(_ url: URL) -> Bool {
        guard let origin = AvatarImageRouteOrigin(url: url) else { return false }
        return routeOrigins.contains(origin)
    }

    @MainActor
    func fetch(_ relativePath: String) async throws -> Data {
        try await fetcher(relativePath)
    }

    @MainActor
    func isCurrent() -> Bool {
        authorityCheck()
    }
}

private struct AvatarImageRouteContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: AvatarImageRouteContext? = nil
}

extension EnvironmentValues {
    var avatarImageRouteContext: AvatarImageRouteContext? {
        get { self[AvatarImageRouteContextEnvironmentKey.self] }
        set { self[AvatarImageRouteContextEnvironmentKey.self] = newValue }
    }
}

enum AvatarRemoteImageRequest: Equatable, Sendable {
    case tenantRelative(path: String)
    case direct(urlString: String)

    var stableIdentity: String {
        switch self {
        case let .tenantRelative(path): path
        case let .direct(urlString): urlString
        }
    }

    func storageCacheKey(_ stableCacheKey: String, routeContext: AvatarImageRouteContext?) -> String? {
        switch self {
        case .tenantRelative:
            guard let routeContext else { return nil }
            return "tenant=\(routeContext.authorityID)|\(stableCacheKey)"
        case .direct:
            return stableCacheKey
        }
    }

    func loadingTaskKey(_ storageCacheKey: String, routeContext: AvatarImageRouteContext?) -> String? {
        switch self {
        case .tenantRelative:
            guard let routeContext else { return nil }
            return "\(storageCacheKey)|\(routeContext.requestIdentity)"
        case .direct:
            return storageCacheKey
        }
    }

    func taskIdentity(routeContext: AvatarImageRouteContext?) -> String {
        switch self {
        case let .tenantRelative(path):
            return "tenant|\(routeContext?.requestIdentity ?? "unavailable")|\(path)"
        case let .direct(urlString):
            return "direct|\(urlString)"
        }
    }

    func loadIdentity(
        routeContext: AvatarImageRouteContext?,
        cacheKey: String,
        maxPixelSize: Int?
    ) -> String {
        "\(taskIdentity(routeContext: routeContext))|cache=\(cacheKey)|max_px=\(maxPixelSize ?? 0)"
    }

    @MainActor
    func isAuthorized(routeContext: AvatarImageRouteContext?) -> Bool {
        switch self {
        case .tenantRelative:
            return routeContext?.isCurrent() == true
        case .direct:
            return true
        }
    }
}

// WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
typealias RemoteImageDataURLDecoder = IM4Data.RemoteImageDataURLDecoder // WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111
// WDT_IOS1_IMAGE_BUDGET_20261023_END

@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()
    // WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
    private static let remoteLoadGate = AttachmentThumbnailLoadGate.shared
    private var cacheGeneration = UUID()
    // WDT_IOS1_IMAGE_BUDGET_20261023_END
    private let maxImageCount = 160
    private let maxDecodedImageBytes = 64 * 1024 * 1024
    private let imageTransport: any RemoteImageTransporting
    private var images: [String: UIImage] = [:]
    private var imageCosts: [String: Int] = [:]
    private var decodedImageBytes = 0
    private var accessOrder: [String] = []
    private var loadingTasks: [String: Task<UIImage?, Never>] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    init(imageTransport: any RemoteImageTransporting = URLSessionRemoteImageTransport()) {
        self.imageTransport = imageTransport
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearCompletedImages()
            }
        }
    }

    func image(for url: String, maxPixelSize: Int? = nil) -> UIImage? {
        let key = Self.scopedCacheKey(url, maxPixelSize: maxPixelSize)
        guard let image = images[key] else { return nil }
        markRecentlyUsed(key)
        return image
    }

    func peekImage(for url: String, maxPixelSize: Int? = nil) -> UIImage? {
        let key = Self.scopedCacheKey(url, maxPixelSize: maxPixelSize)
        return images[key]
    }

    func store(_ data: Data, for url: String, maxPixelSize: Int? = nil) {
        let key = Self.scopedCacheKey(url, maxPixelSize: maxPixelSize)
        guard !key.isEmpty, let image = RemoteImageDecoder.preparedImage(from: data, maxPixelSize: maxPixelSize) else { return }
        storePreparedImage(image.preparingForDisplay() ?? image, for: key)
    }

    func store(_ image: UIImage, for url: String, maxPixelSize: Int? = nil) {
        let key = Self.scopedCacheKey(url, maxPixelSize: maxPixelSize)
        guard !key.isEmpty else { return }
        storePreparedImage(image.preparingForDisplay() ?? image, for: key)
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_PREPARED_CACHE_STORE - 修改开始：聊天缩略图后台解码后直接入内存缓存，避免主线程重复 prepare
    func storePrepared(_ image: UIImage, for url: String, maxPixelSize: Int? = nil) {
        let key = Self.scopedCacheKey(url, maxPixelSize: maxPixelSize)
        guard !key.isEmpty else { return }
        storePreparedImage(image, for: key)
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_PREPARED_CACHE_STORE - 修改结束：聊天缩略图后台解码后直接入内存缓存，避免主线程重复 prepare

    func remoteImage(
        for rawValue: String,
        routeContext: AvatarImageRouteContext? = nil,
        cacheKey explicitCacheKey: String? = nil,
        maxPixelSize: Int? = nil,
        retryPolicy: AvatarImageRetryPolicy = .none
    ) async -> UIImage? {
        guard let request = TenantRelativeImageURLResolver.request(rawValue, routeContext: routeContext) else {
            return nil
        }
        let rawKey = (explicitCacheKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? explicitCacheKey!
            : request.stableIdentity)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let storageCacheKey = request.storageCacheKey(rawKey, routeContext: routeContext),
              let loadingTaskKey = request.loadingTaskKey(storageCacheKey, routeContext: routeContext) else {
            return nil
        }
        let key = Self.scopedCacheKey(storageCacheKey, maxPixelSize: maxPixelSize)
        let retryTaskKey = "\(loadingTaskKey)|attempts=\(retryPolicy.maximumAttempts)"
        let taskKey = Self.scopedCacheKey(retryTaskKey, maxPixelSize: maxPixelSize)
        guard !rawKey.isEmpty,
              !key.isEmpty,
              !taskKey.isEmpty,
              request.isAuthorized(routeContext: routeContext) else { return nil }
        if let image = image(for: storageCacheKey, maxPixelSize: maxPixelSize) {
            return image
        }
        if let task = loadingTasks[taskKey] {
            // WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
            let generation = cacheGeneration
            let image = await task.value
            guard generation == cacheGeneration, !Task.isCancelled else { return nil }
            // WDT_IOS1_IMAGE_BUDGET_20261023_END
            if case .tenantRelative = request,
               routeContext?.isCurrent() != true {
                return nil
            }
            return image
        }
        let imageTransport = self.imageTransport
        let boundedMaxPixelSize = RemoteImageDecoder.boundedMaxPixelSize(maxPixelSize)
        // WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
        let generation = cacheGeneration
        let loadGate = Self.remoteLoadGate
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard await loadGate.acquire() else { return nil }
            let result: UIImage? = await {
                for attempt in 0..<retryPolicy.maximumAttempts {
                    guard !Task.isCancelled else { return nil }
                    do {
                        let data: Data?
                        switch request {
                        case let .tenantRelative(path):
                            guard let routeContext, await routeContext.isCurrent() else { return nil }
                            data = try await routeContext.fetch(path)
                            guard !Task.isCancelled, await routeContext.isCurrent() else { return nil }
                        case let .direct(urlString):
                            guard let url = URL(string: urlString), url.scheme?.isEmpty == false else { return nil }
                            if url.scheme?.lowercased() == "data" {
                                data = RemoteImageDataURLDecoder.data(from: urlString)
                            } else if url.isFileURL {
                                data = try RemoteImageDecoder.previewData(fromFileURL: url) // WDT_IOS1_IMAGE_BUDGET_20261023
                            } else {
                                let result = try await imageTransport.data(from: url)
                                if let statusCode = result.statusCode, !(200..<300).contains(statusCode) {
                                    data = nil
                                } else {
                                    data = result.data
                                }
                            }
                        }
                        guard !Task.isCancelled else { return nil }
                        if let data,
                           let image = RemoteImageDecoder.preparedImage(from: data, maxPixelSize: boundedMaxPixelSize) {
                            return image
                        }
                    } catch {
                        // A bounded retry below handles transient transport failures.
                    }
                    guard attempt + 1 < retryPolicy.maximumAttempts else { break }
                    if retryPolicy.delayNanoseconds > 0 {
                        do {
                            try await Task.sleep(nanoseconds: retryPolicy.delayNanoseconds)
                        } catch {
                            return nil
                        }
                    }
                }
                return nil
            }()
            await loadGate.release()
            return result
        }
        loadingTasks[taskKey] = task
        let image = await task.value
        guard cacheGeneration == generation else { return nil }
        loadingTasks[taskKey] = nil
        // WDT_IOS1_IMAGE_BUDGET_20261023_END
        if case .tenantRelative = request,
           routeContext?.isCurrent() != true {
            return nil
        }
        if let image, !Task.isCancelled {
            storePreparedImage(image, for: key)
        }
        return image
    }

    nonisolated static func cacheKey(url: String, version: String = "", updatedAt: String = "") -> String {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return "" }
        let versionToken = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if !versionToken.isEmpty {
            return "\(trimmedURL)#avatar_version=\(versionToken)"
        }
        let updatedToken = updatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !updatedToken.isEmpty {
            return "\(trimmedURL)#avatar_updated_at=\(updatedToken)"
        }
        return trimmedURL
    }

    nonisolated static func scopedCacheKey(_ key: String, maxPixelSize: Int?) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let maxPixelSize = RemoteImageDecoder.boundedMaxPixelSize(maxPixelSize) else {
            return trimmedKey
        }
        return "\(trimmedKey)#max_px=\(maxPixelSize)"
    }

    private func storePreparedImage(_ image: UIImage, for key: String) {
        if let oldCost = imageCosts[key] {
            decodedImageBytes -= oldCost
        }
        images[key] = image
        let cost = decodedCost(of: image)
        imageCosts[key] = cost
        decodedImageBytes += cost
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private func markRecentlyUsed(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimIfNeeded() {
        while (images.count > maxImageCount || decodedImageBytes > maxDecodedImageBytes),
              let oldest = accessOrder.first {
            removeImage(for: oldest)
        }
        if accessOrder.count > images.count {
            accessOrder.removeAll { images[$0] == nil }
        }
    }

    private func removeImage(for key: String) {
        accessOrder.removeAll { $0 == key }
        images.removeValue(forKey: key)
        if let cost = imageCosts.removeValue(forKey: key) {
            decodedImageBytes = max(0, decodedImageBytes - cost)
        }
    }

    private func decodedCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let scale = max(image.scale, 1)
        let width = max(1, Int(image.size.width * scale))
        let height = max(1, Int(image.size.height * scale))
        return width * height * 4
    }

    private func clearCompletedImages() {
        images.removeAll(keepingCapacity: false)
        imageCosts.removeAll(keepingCapacity: false)
        decodedImageBytes = 0
        accessOrder.removeAll(keepingCapacity: false)
    }

    func removeAllImages() {
        cacheGeneration = UUID() // WDT_IOS1_IMAGE_BUDGET_20261023: old completions cannot overwrite a new request.
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll(keepingCapacity: false)
        clearCompletedImages()
    }
}

// WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
enum RemoteImageDecoder {
    static let maximumEncodedByteCount = RemoteImageFile.maximumEncodedByteCount

    nonisolated static func previewData(fromFileURL url: URL) throws -> Data {
        try RemoteImageFile.previewData(fromFileURL: url)
    }

    nonisolated static func boundedMaxPixelSize(_ value: Int?) -> Int? {
        let value = value ?? 2_048
        let bounded = max(64, min(value, 2_048))
        return bounded
    }

    nonisolated static func image(from data: Data, maxPixelSize: Int? = nil) -> UIImage? {
        guard data.count <= maximumEncodedByteCount else { return nil }
        guard let maxPixelSize = boundedMaxPixelSize(maxPixelSize) else { return nil }
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func image(fromFileURL url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, min(maxPixelSize, 2_048))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func pixelSize(fromFileURL url: URL) -> CGSize? {
        RemoteImageFile.pixelSize(fromFileURL: url)
    }

    nonisolated static func preparedImage(from data: Data, maxPixelSize: Int? = nil) -> UIImage? {
        guard let image = image(from: data, maxPixelSize: maxPixelSize) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

// WDT_IOS1_IMAGE_BUDGET_20261023_END

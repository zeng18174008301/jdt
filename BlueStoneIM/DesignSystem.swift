import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteImageTransportResult: Sendable {
    let data: Data
    let statusCode: Int?
}

protocol RemoteImageTransporting: Sendable {
    func data(from url: URL) async throws -> RemoteImageTransportResult
}

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

struct URLSessionRemoteImageTransport: RemoteImageTransporting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(from url: URL) async throws -> RemoteImageTransportResult {
        let (data, response) = try await session.data(from: url)
        return RemoteImageTransportResult(
            data: data,
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
    }
}

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

enum RemoteImageDataURLDecoder {
    static func data(from value: String) -> Data? {
        guard value.lowercased().hasPrefix("data:"),
              let separator = value.firstIndex(of: ",") else {
            return nil
        }
        let metadata = value[value.index(value.startIndex, offsetBy: 5)..<separator]
        let payload = String(value[value.index(after: separator)...])
        if metadata.lowercased().split(separator: ";").contains("base64") {
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        guard let decoded = payload.removingPercentEncoding else { return nil }
        return Data(decoded.utf8)
    }
}

@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()
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
            let image = await task.value
            if case .tenantRelative = request,
               routeContext?.isCurrent() != true {
                return nil
            }
            return image
        }
        let imageTransport = self.imageTransport
        let boundedMaxPixelSize = RemoteImageDecoder.boundedMaxPixelSize(maxPixelSize)
        let task = Task.detached(priority: .utility) { () -> UIImage? in
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
                            data = try Data(contentsOf: url)
                        } else {
                            let result = try await imageTransport.data(from: url)
                            if let statusCode = result.statusCode, !(200..<300).contains(statusCode) {
                                data = nil
                            } else {
                                data = result.data
                            }
                        }
                    }
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
        }
        loadingTasks[taskKey] = task
        let image = await task.value
        loadingTasks[taskKey] = nil
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
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll(keepingCapacity: false)
        clearCompletedImages()
    }
}

enum RemoteImageDecoder {
    nonisolated static func boundedMaxPixelSize(_ value: Int?) -> Int? {
        guard let value else { return nil }
        let bounded = max(64, min(value, 2_048))
        return bounded
    }

    nonisolated static func image(from data: Data, maxPixelSize: Int? = nil) -> UIImage? {
        guard let maxPixelSize = boundedMaxPixelSize(maxPixelSize) else {
            return UIImage(data: data)
        }
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return UIImage(data: data)
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
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let width = CGFloat(rawWidth.doubleValue)
        let height = CGFloat(rawHeight.doubleValue)
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    nonisolated static func preparedImage(from data: Data, maxPixelSize: Int? = nil) -> UIImage? {
        guard let image = image(from: data, maxPixelSize: maxPixelSize) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

enum IMColor {
    static let brand = Color(hex: 0x5D6BFF)
    static let peerName = Color(hex: 0x4F6F9F)
    static let violet = Color(hex: 0x7C6BFF)
    static let cyan = Color(hex: 0x50D2FF)
    static let ink = Color(hex: 0x172033)
    static let muted = Color(hex: 0x7A8397)
    static let page = Color(hex: 0xF3F6FC)
    static let card = Color.white
    static let line = Color(hex: 0xE8ECF5)
    static let danger = Color(hex: 0xFF5D73)
    static let success = Color(hex: 0x23C48E)
    static let warning = Color(hex: 0xFFB246)
}

func presenceBadgeColor(for status: String, offlineColor: Color = IMColor.muted) -> Color? {
    nil
}

enum JHTPresentationDetentCompat {
    case medium
    case large
    case height(CGFloat)

    @available(iOS 16.0, *)
    var native: PresentationDetent {
        switch self {
        case .medium:
            return .medium
        case .large:
            return .large
        case .height(let value):
            return .height(value)
        }
    }
}

enum JHTPresentationVisibilityCompat {
    case hidden
    case visible

    var native: Visibility {
        switch self {
        case .hidden:
            return .hidden
        case .visible:
            return .visible
        }
    }
}

extension View {
    func imReadableInputText() -> some View {
        foregroundStyle(IMColor.ink)
            .tint(IMColor.brand)
            .colorScheme(.light)
    }

    @ViewBuilder
    func navigationDestinationCompat<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            background(
                NavigationLink(
                    destination: destination(),
                    isActive: isPresented,
                    label: { EmptyView() }
                )
                .hidden()
            )
        }
    }

    @ViewBuilder
    func navigationDestinationCompat<Item: Identifiable & Hashable, Destination: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        background(
            NavigationLink(
                destination: Group {
                    if let value = item.wrappedValue {
                        AnyView(destination(value))
                    } else {
                        AnyView(EmptyView())
                    }
                },
                isActive: Binding(
                    get: { item.wrappedValue != nil },
                    set: { isActive in
                        if !isActive {
                            item.wrappedValue = nil
                        }
                    }
                ),
                label: { EmptyView() }
            )
            .hidden()
        )
    }

    @ViewBuilder
    func presentationDetentsCompat(_ detents: [JHTPresentationDetentCompat]) -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents(Set(detents.map(\.native)))
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationDragIndicatorCompat(_ visibility: JHTPresentationVisibilityCompat) -> some View {
        if #available(iOS 16.0, *) {
            presentationDragIndicator(visibility.native)
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationCornerRadiusCompat(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) {
            presentationCornerRadius(radius)
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationBackgroundClearCompat() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(.clear)
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationBackgroundUltraThinMaterialCompat() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(.ultraThinMaterial)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollBounceBehaviorBasedOnSizeCompat() -> some View {
        if #available(iOS 16.4, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollContentBackgroundHiddenCompat() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func toolbarTabBarHiddenCompat() -> some View {
        if #available(iOS 16.0, *) {
            toolbar(.hidden, for: .tabBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func toolbarNavigationBarDarkCompat() -> some View {
        if #available(iOS 16.0, *) {
            toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func toolbarNavigationBarPageBackgroundCompat() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(IMColor.page, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func contentTransitionOpacityCompat() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.opacity)
        } else {
            self
        }
    }

    @ViewBuilder
    func safeAreaPaddingTopCompat(_ length: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            safeAreaPadding(.top, length)
        } else {
            padding(.top, length)
        }
    }
}

struct NavigationStackCompat<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(.stack)
        }
    }
}

struct ViewThatFitsCompat<Content: View>: View {
    let axes: Axis.Set
    private let content: () -> Content

    init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: @escaping () -> Content) {
        self.axes = axes
        self.content = content
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: axes) {
                content()
            }
        } else {
            content()
        }
    }
}

struct LabeledContentCompat: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(IMColor.muted)
        }
    }
}

struct PhotoLibraryPickedItem: Identifiable, Equatable {
    let id = UUID()
    let data: Data?
    let fileURL: URL?
    let sizeBytes: Int64?
    let contentTypes: [UTType]

    init(data: Data, contentTypes: [UTType]) {
        self.data = data
        fileURL = nil
        sizeBytes = Int64(data.count)
        self.contentTypes = contentTypes
    }

    init(file: PendingAttachmentFile, contentTypes: [UTType]) {
        data = nil
        fileURL = file.url
        sizeBytes = file.sizeBytes
        self.contentTypes = contentTypes
    }
}

struct PhotoLibraryPickerCompat: UIViewControllerRepresentable {
    let selectionLimit: Int
    let filter: PHPickerFilter
    let onPicked: ([PhotoLibraryPickedItem]) -> Void
    let prefersFileBackedItems: Bool
    let onCancel: () -> Void

    init(
        selectionLimit: Int,
        filter: PHPickerFilter,
        prefersFileBackedItems: Bool = false,
        onCancel: @escaping () -> Void = {},
        onPicked: @escaping ([PhotoLibraryPickedItem]) -> Void
    ) {
        self.selectionLimit = selectionLimit
        self.filter = filter
        self.prefersFileBackedItems = prefersFileBackedItems
        self.onCancel = onCancel
        self.onPicked = onPicked
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = selectionLimit
        configuration.filter = filter
        configuration.preferredAssetRepresentationMode = .current
        if #available(iOS 15.0, *) {
            configuration.selection = .ordered
        }
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPickerCompat

        init(parent: PhotoLibraryPickerCompat) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }
            Task {
                let items = await Self.loadItems(
                    from: results,
                    prefersFileBackedItems: parent.prefersFileBackedItems
                )
                await MainActor.run {
                    parent.onPicked(items)
                }
            }
        }

        private static func loadItems(
            from results: [PHPickerResult],
            prefersFileBackedItems: Bool
        ) async -> [PhotoLibraryPickedItem] {
            var loaded: [PhotoLibraryPickedItem] = []
            // JHT_MOD_BEGIN CHAT_PHOTO_PICKER_FILE_FALLBACK_20260914 - 修改开始：记录多选读取结果，定位选择 9 张只进入部分发送队列
            for (index, result) in results.enumerated() {
                if let item = await loadItem(
                    from: result.itemProvider,
                    prefersFileBackedItems: prefersFileBackedItems
                ) {
                    loaded.append(item)
                } else {
                    #if DEBUG
                    print("[JHT PhotoPicker] item_load_failed index=\(index) identifiers=\(result.itemProvider.registeredTypeIdentifiers.count) prefers_file=\(prefersFileBackedItems)")
                    #endif
                }
            }
            #if DEBUG
            let fileBackedCount = loaded.filter { $0.fileURL != nil }.count
            let dataBackedCount = loaded.filter { $0.data != nil }.count
            print("[JHT PhotoPicker] load_finished requested=\(results.count) loaded=\(loaded.count) file_backed=\(fileBackedCount) data_backed=\(dataBackedCount) prefers_file=\(prefersFileBackedItems)")
            #endif
            // JHT_MOD_END CHAT_PHOTO_PICKER_FILE_FALLBACK_20260914 - 修改结束
            return loaded
        }

        private static func loadItem(
            from provider: NSItemProvider,
            prefersFileBackedItems: Bool
        ) async -> PhotoLibraryPickedItem? {
            let preferredIdentifiers = preferredTypeIdentifiers(from: provider.registeredTypeIdentifiers)
            let gifIdentifiers = preferredIdentifiers.filter { UTType($0)?.conforms(to: .gif) == true }
            // A provider's JPEG/PNG fallback is often only the first GIF frame.
            let identifiers = gifIdentifiers.isEmpty ? preferredIdentifiers : gifIdentifiers
            for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
                let contentTypes = [identifier].compactMap(UTType.init)
                // JHT_MOD_BEGIN CHAT_PHOTO_PICKER_FILE_FALLBACK_20260914 - 修改开始：聊天附件优先使用临时文件；文件表示失败时兜底读取 data，避免多选图片被静默丢弃
                if prefersFileBackedItems,
                   let file = try? await loadManagedFile(
                    from: provider,
                    typeIdentifier: identifier
                   ) {
                    return PhotoLibraryPickedItem(file: file, contentTypes: contentTypes)
                }
                // JHT_MOD_END CHAT_PHOTO_PICKER_FILE_FALLBACK_20260914 - 修改结束
                guard let data = try? await loadItemData(from: provider, typeIdentifier: identifier),
                      !data.isEmpty else {
                    continue
                }
                return PhotoLibraryPickedItem(data: data, contentTypes: contentTypes)
            }
            return nil
        }

        private static func loadManagedFile(
            from provider: NSItemProvider,
            typeIdentifier: String
        ) async throws -> PendingAttachmentFile {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let url else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                        return
                    }
                    do {
                        let type = UTType(typeIdentifier)
                        var name = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if name.isEmpty {
                            name = type?.conforms(to: .movie) == true ? "视频消息" : "图片消息"
                        }
                        if (name as NSString).pathExtension.isEmpty,
                           let fileExtension = type?.preferredFilenameExtension {
                            name += ".\(fileExtension)"
                        }
                        continuation.resume(returning: try PendingAttachmentFileStore.stageFile(
                            from: url,
                            preferredName: name
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private static func loadItemData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
            if let data = try? await loadData(from: provider, typeIdentifier: typeIdentifier),
               !data.isEmpty {
                return data
            }
            return try await loadFileData(from: provider, typeIdentifier: typeIdentifier)
        }

        private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    }
                }
            }
        }

        private static func loadFileData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        do {
                            continuation.resume(returning: try Data(contentsOf: url))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    }
                }
            }
        }

        private static func preferredTypeIdentifiers(from identifiers: [String]) -> [String] {
            let preferred = identifiers.sorted { lhs, rhs in
                priority(for: lhs) < priority(for: rhs)
            }
            return preferred.isEmpty ? identifiers : preferred
        }

        private static func priority(for identifier: String) -> Int {
            guard let type = UTType(identifier) else { return 100 }
            if type.conforms(to: .gif) { return 0 }
            if type.conforms(to: .png) { return 1 }
            if type.conforms(to: .jpeg) { return 2 }
            if type.conforms(to: .movie) { return 3 }
            if type.conforms(to: .image) { return 4 }
            return 10
        }
    }
}

enum UnreadBadgeFormatter {
    static let maximumVisibleCount = 99

    static func text(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(min(count, maximumVisibleCount))"
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init?(hexString: String, alpha: Double = 1) {
        var normalized = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") {
            normalized.removeFirst()
        }
        guard normalized.count == 6, let value = UInt(normalized, radix: 16) else { return nil }
        self.init(hex: value, alpha: alpha)
    }
}

extension View {
    func glassCard(radius: CGFloat = 26) -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .shadow(color: Color(hex: 0x5D6BFF, alpha: 0.10), radius: 24, y: 12)
            )
    }

    func plainCard(radius: CGFloat = 22) -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(IMColor.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(IMColor.line, lineWidth: 1)
                    )
            )
    }
}

struct AuroraBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    IMColor.page,
                    Color(hex: 0xEEF1FF),
                    Color(hex: 0xEAF8FF)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [IMColor.brand.opacity(0.12), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 360
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [IMColor.cyan.opacity(0.10), .clear],
                center: .trailing,
                startRadius: 30,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - 登录 / 注册 动态背景(方案 B:Metal 流动极光 + 稀疏粒子)
// 仅用于 AuthRootView;聊天页仍用静态的 AuroraBackground。
// 性能:着色器走 GPU(不占主线程)、限 20fps、慢速流动;开启「减弱动态效果」时退回静态背景。
struct AuthBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var pausedDate = Date()
    @State private var pausedElapsed: TimeInterval = 0

    var isAnimating = true
    private let frameInterval: TimeInterval = 1.0 / 30.0

    var body: some View {
        ZStack {
            if reduceMotion {
                AuroraBackground()
            } else {
                GeometryReader { geo in
                    if isAnimating {
                        TimelineView(.periodic(from: .now, by: frameInterval)) { tl in
                            auroraFrame(size: geo.size, date: tl.date)
                        }
                    } else {
                        auroraFrame(size: geo.size, date: pausedDate)
                    }
                }
                .ignoresSafeArea()
                .onChangeCompat(of: isAnimating) { _, animating in
                    if animating {
                        start = Date().addingTimeInterval(-pausedElapsed)
                    } else {
                        pausedDate = Date()
                        pausedElapsed = pausedDate.timeIntervalSince(start)
                    }
                }

                AuthParticles(isAnimating: isAnimating)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func auroraFrame(size: CGSize, date: Date) -> some View {
        let t = Float(date.timeIntervalSince(start)) * 0.06
        if #available(iOS 17.0, *) {
            Rectangle()
                .colorEffect(
                ShaderLibrary.auroraFlow(
                    .float2(Float(size.width), Float(size.height)),
                    .float(t)
                )
            )
        } else {
            LinearGradient(
                colors: [
                    Color(hex: 0xAEB8FF),
                    Color(hex: 0xDDE3FF),
                    Color(hex: 0xF7FAFF)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct AuthParticles: View {
    var isAnimating = true
    @State private var start = Date()
    @State private var pausedDate = Date()
    @State private var pausedElapsed: TimeInterval = 0

    private let frameInterval: TimeInterval = 1.0 / 30.0

    private struct Dot { var x0, y0, vx, vy, r, a, ph: Double }
    @State private var dots: [Dot] = (0..<20).map { _ in
        Dot(x0: .random(in: 0...1),
            y0: .random(in: 0...1),
            vx: .random(in: -0.006...0.006),
            vy: -Double.random(in: 0.005...0.020),
            r:  .random(in: 1.2...3.2),
            a:  .random(in: 0.36...0.88),
            ph: .random(in: 0...6.2832))
    }

    var body: some View {
        Group {
            if isAnimating {
                TimelineView(.periodic(from: .now, by: frameInterval)) { tl in
                    particleCanvas(date: tl.date)
                }
            } else {
                particleCanvas(date: pausedDate)
            }
        }
        .onChangeCompat(of: isAnimating) { _, animating in
            if animating {
                start = Date().addingTimeInterval(-pausedElapsed)
            } else {
                pausedDate = Date()
                pausedElapsed = pausedDate.timeIntervalSince(start)
            }
        }
    }

    private func particleCanvas(date: Date) -> some View {
        Canvas { ctx, size in
            let t = date.timeIntervalSince(start) * 1.5
            for d in dots {
                var x = (d.x0 + d.vx * t).truncatingRemainder(dividingBy: 1.0)
                var y = (d.y0 + d.vy * t).truncatingRemainder(dividingBy: 1.0)
                if x < 0 { x += 1 }
                if y < 0 { y += 1 }
                let cx = CGFloat(x) * size.width
                let cy = CGFloat(y) * size.height
                let alpha = max(0.0, d.a * (0.6 + 0.4 * sin(d.ph + t * 0.6)))
                let rr = CGFloat(d.r * 3.9)
                let rect = CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)
                let grad = Gradient(stops: [
                    .init(color: .white.opacity(alpha), location: 0),
                    .init(color: .white.opacity(0), location: 1)
                ])
                ctx.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(grad, center: CGPoint(x: cx, y: cy),
                                          startRadius: 0, endRadius: rr)
                )
            }
        }
    }
}

enum TenantRelativeImageURLResolver {
    static func request(
        _ rawValue: String,
        routeContext: AvatarImageRouteContext?
    ) -> AvatarRemoteImageRequest? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return .direct(urlString: "https:\(trimmed)")
        }
        guard let parsed = URL(string: trimmed) else { return nil }
        if parsed.scheme?.isEmpty == false {
            if parsed.scheme?.lowercased() == "https",
               parsed.query == nil,
               parsed.fragment == nil,
               routeContext?.matchesRouteOrigin(parsed) == true,
               isStableTenantAvatarPath(parsed.path) {
                return .tenantRelative(path: parsed.path)
            }
            return .direct(urlString: trimmed)
        }
        guard parsed.host == nil else { return nil }
        let path = parsed.path.isEmpty ? "/" : parsed.path
        guard path.hasPrefix("/api/tenant/") else { return nil }
        let relativePath = parsed.query.map { "\(path)?\($0)" } ?? path
        return .tenantRelative(path: relativePath)
    }

    static func isStableTenantAvatarPath(_ path: String) -> Bool {
        let prefixes = [
            "/api/tenant/avatar/",
            "/api/tenant/static/avatars/"
        ]
        return prefixes.contains { prefix in
            path.hasPrefix(prefix) && path.count > prefix.count
        }
    }
}

struct AvatarView: View {
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext

    let name: String
    let seed: UInt
    var size: CGFloat = 48
    var badgeColor: Color?
    var imageURL: String = ""
    var avatarVersion: String = ""
    var avatarUpdatedAt: String = ""
    var imageCacheKey: String = ""
    var retryPolicy: AvatarImageRetryPolicy = .none
    var usesGroupDefaultFallback = false
    var certification: CertificationPresentation?

    private var maxPixelSize: Int {
        max(96, Int(ceil(size * UIScreen.main.scale * 1.5)))
    }

    private var isCancelledAvatar: Bool {
        isCancelledUserAvatarURL(imageURL)
    }

    private var visibleCertification: CertificationPresentation? {
        isCancelledAvatar || usesGroupDefaultFallback ? nil : certification
    }

    private var resolvedName: String {
        isCancelledAvatar ? cancelledUserDisplayName : name
    }

    var initials: String {
        String(resolvedName.prefix(2))
    }

    var body: some View {
        ZStack {
            avatarBody
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        visibleCertification == nil
                            ? .white.opacity(0.65)
                            : Color(hex: 0x2F6BFF).opacity(0.92),
                        lineWidth: visibleCertification == nil ? 1 : max(1.5, size * 0.045)
                    )
                )
            if let badgeColor, !isCancelledAvatar {
                Circle()
                    .fill(badgeColor)
                    .frame(width: size * 0.24, height: size * 0.24)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(
                        width: size,
                        height: size,
                        alignment: .bottomLeading
                    )
            }
            if visibleCertification != nil {
                Image(systemName: "checkmark.shield.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(hex: 0x2F6BFF))
                    .font(.system(size: max(11, size * 0.28), weight: .bold))
                    .padding(max(1, size * 0.025))
                    .background(Circle().fill(Color.white))
                    .frame(
                        width: size,
                        height: size,
                        alignment: .bottomTrailing
                    )
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [resolvedName, visibleCertification?.accessibilityLabel]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "，")
        )
    }

    @ViewBuilder
    private var avatarBody: some View {
        let request = TenantRelativeImageURLResolver.request(
            imageURL,
            routeContext: avatarImageRouteContext
        )
        let explicitCacheKey = imageCacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableCacheKey = explicitCacheKey.isEmpty
            ? AvatarImageCache.cacheKey(
                url: request?.stableIdentity ?? "",
                version: avatarVersion,
                updatedAt: avatarUpdatedAt
            )
            : explicitCacheKey
        let storageCacheKey = request?.storageCacheKey(
            stableCacheKey,
            routeContext: avatarImageRouteContext
        )
        let canReadCache = request?.isAuthorized(routeContext: avatarImageRouteContext) == true
        if isCancelledAvatar {
            cancelledFallbackAvatar
        } else if canReadCache,
                  let storageCacheKey,
                  let cached = AvatarImageCache.shared.peekImage(for: storageCacheKey, maxPixelSize: maxPixelSize) {
            Image(uiImage: cached)
                .resizable()
                .scaledToFill()
        } else if request != nil {
            CachedRemoteImage(
                urlString: imageURL,
                cacheKey: stableCacheKey,
                maxPixelSize: maxPixelSize,
                retryPolicy: retryPolicy
            ) {
                fallbackAvatar
            }
        } else {
            fallbackAvatar
        }
    }

    private var cancelledFallbackAvatar: some View {
        Circle()
            .fill(Color(hex: 0xD8DEE8))
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Color(hex: 0x8F98A8))
            )
    }

    @ViewBuilder
    private var fallbackAvatar: some View {
        if usesGroupDefaultFallback {
            GroupDefaultAvatarView(size: size)
        } else {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: seed).opacity(0.92), Color(hex: seed).opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }
}

struct CertificationPillView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    let exactUID: String
    var compact = false
    var maximumLineCount: Int? = 2
    var presentation: CertificationPresentation? = nil
    // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_PILL_PREFETCH_MODE - 修改开始：支持通讯录行使用已预取认证展示，滚动时不再逐行查询全局状态
    var usesProvidedPresentationOnly = false
    // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_PILL_PREFETCH_MODE - 修改结束：支持通讯录行使用已预取认证展示，滚动时不再逐行查询全局状态

    private var normalizedUID: String {
        exactUID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_PILL_TASK_ID - 修改开始：通讯录预取模式下不把全局认证 revision 作为行视图依赖
    private var certificationTaskID: String {
        if usesProvidedPresentationOnly {
            return "provided|\(normalizedUID)"
        }
        return "\(normalizedUID)\u{1f}\(state.certificationPresentationScopeRevision)"
    }
    // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_PILL_TASK_ID - 修改结束：通讯录预取模式下不把全局认证 revision 作为行视图依赖

    var body: some View {
        // Keep a mounted view while the presentation is nil so the fetch task runs.
        VStack(alignment: .leading, spacing: 0) {
            // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_PILL_RESOLVE - 修改开始：通讯录行使用预取结果，避免滚动时逐行访问 AppState
            let resolvedPresentation = presentation ?? (usesProvidedPresentationOnly ? nil : state.certificationPresentation(
                forExactUID: normalizedUID
            ))
            // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_PILL_RESOLVE - 修改结束：通讯录行使用预取结果，避免滚动时逐行访问 AppState
            if let resolvedPresentation {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .fixedSize()
                    Text(resolvedPresentation.visibleLabel)
                }
                .font(
                    compact
                        ? Font.caption2.weight(.semibold)
                        : Font.caption.weight(.semibold)
                )
                .foregroundStyle(
                    colorScheme == .dark
                        ? Color(hex: 0xA9C2FF)
                        : Color(hex: 0x245DE8)
                )
                .lineLimit(compact ? nil : maximumLineCount)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, compact ? 5 : 6)
                .padding(.vertical, compact ? 2 : 3)
                .background(
                    RoundedRectangle(
                        cornerRadius: compact ? 7 : 9,
                        style: .continuous
                    )
                        .fill(
                            Color(hex: 0x2F6BFF)
                                .opacity(colorScheme == .dark ? 0.28 : 0.10)
                        )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: compact ? 7 : 9,
                        style: .continuous
                    )
                        .stroke(
                            Color(hex: 0x2F6BFF)
                                .opacity(colorScheme == .dark ? 0.58 : 0.22),
                            lineWidth: 0.75
                        )
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(resolvedPresentation.accessibilityLabel)
            }
        }
        .task(
            id: certificationTaskID
        ) {
            // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_PILL_SKIP_ROW_TASK - 修改开始：通讯录行已由列表统一预取，跳过逐行认证检查任务
            guard !usesProvidedPresentationOnly else { return }
            // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_PILL_SKIP_ROW_TASK - 修改结束：通讯录行已由列表统一预取，跳过逐行认证检查任务
            guard !normalizedUID.isEmpty else { return }
            state.ensureCertificationPresentations(
                forExactUIDs: [normalizedUID]
            )
        }
    }
}

struct GroupAvatarView: View {
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext

    let name: String
    let seed: UInt
    var size: CGFloat = 48
    var imageURL: String = ""
    var avatarVersion: String = ""
    var avatarUpdatedAt: String = ""
    var imageCacheKey: String = ""
    var defaultContentScale: CGFloat = 1

    private var trustedCustomAvatarPath: String? {
        guard !isDefaultGroupAvatarURL(imageURL),
              let request = TenantRelativeImageURLResolver.request(
                imageURL,
                routeContext: avatarImageRouteContext
              ), case let .tenantRelative(relativeValue) = request,
              let parsed = URL(string: relativeValue),
              parsed.host == nil,
              parsed.query == nil,
              parsed.fragment == nil,
              TenantRelativeImageURLResolver.isStableTenantAvatarPath(parsed.path) else {
            return nil
        }
        return parsed.path
    }

    var body: some View {
        if let trustedCustomAvatarPath {
            AvatarView(
                name: name,
                seed: seed,
                size: size,
                imageURL: trustedCustomAvatarPath,
                avatarVersion: avatarVersion,
                avatarUpdatedAt: avatarUpdatedAt,
                imageCacheKey: imageCacheKey,
                retryPolicy: .groupAvatar,
                usesGroupDefaultFallback: true
            )
        } else {
            GroupDefaultAvatarView(size: size, contentScale: defaultContentScale)
                .accessibilityLabel(name)
        }
    }
}

func isDefaultGroupAvatarURL(_ value: String) -> Bool {
    let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowercased.contains("group-default-avatar")
        || lowercased.contains("default-group-avatar")
}

struct GroupDefaultAvatarView: View {
    var size: CGFloat
    var contentScale: CGFloat = 1

    var body: some View {
        let scale = max(contentScale, 1)
        Image("GroupDefaultAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size * scale, height: size * scale)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
            .accessibilityLabel("群聊")
    }
}

struct SystemNoticeLogoAvatar: View {
    var size: CGFloat

    var body: some View {
        Image("SystemNoticeLogo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .scaleEffect(1.28)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
            .accessibilityLabel("系统通知")
    }
}

struct CachedRemoteImageState {
    let identity: String
    let image: UIImage

    func visibleImage(currentIdentity: String, isAuthorized: Bool) -> UIImage? {
        guard isAuthorized, identity == currentIdentity else { return nil }
        return image
    }
}

struct CachedRemoteImage<Placeholder: View>: View {
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext

    let urlString: String
    var cacheKey: String = ""
    var contentMode: ContentMode = .fill
    var maxPixelSize: Int?
    var retryPolicy: AvatarImageRetryPolicy = .none
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loadedState: CachedRemoteImageState?

    private var request: AvatarRemoteImageRequest? {
        TenantRelativeImageURLResolver.request(
            urlString,
            routeContext: avatarImageRouteContext
        )
    }

    private var loadIdentity: String {
        guard let request else { return "invalid|cache=\(cacheKey)|max_px=\(maxPixelSize ?? 0)|attempts=\(retryPolicy.maximumAttempts)" }
        return request.loadIdentity(
            routeContext: avatarImageRouteContext,
            cacheKey: cacheKey,
            maxPixelSize: maxPixelSize
        ) + "|attempts=\(retryPolicy.maximumAttempts)"
    }

    var body: some View {
        Group {
            if let image = loadedState?.visibleImage(
                currentIdentity: loadIdentity,
                isAuthorized: request?.isAuthorized(routeContext: avatarImageRouteContext) == true
            ) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: loadIdentity) {
            let requestedIdentity = loadIdentity
            guard let request else {
                loadedState = nil
                return
            }
            guard request.isAuthorized(routeContext: avatarImageRouteContext) else {
                loadedState = nil
                return
            }
            let stableCacheKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? request.stableIdentity
                : cacheKey
            guard let storageCacheKey = request.storageCacheKey(
                stableCacheKey,
                routeContext: avatarImageRouteContext
            ), request.isAuthorized(routeContext: avatarImageRouteContext) else {
                loadedState = nil
                return
            }
            if let cached = AvatarImageCache.shared.image(for: storageCacheKey, maxPixelSize: maxPixelSize) {
                guard requestedIdentity == loadIdentity,
                      request.isAuthorized(routeContext: avatarImageRouteContext) else { return }
                loadedState = CachedRemoteImageState(identity: requestedIdentity, image: cached)
                return
            }
            loadedState = nil
            let loadedImage = await AvatarImageCache.shared.remoteImage(
                for: urlString,
                routeContext: avatarImageRouteContext,
                cacheKey: stableCacheKey,
                maxPixelSize: maxPixelSize,
                retryPolicy: retryPolicy
            )
            guard !Task.isCancelled,
                  requestedIdentity == loadIdentity,
                  request.isAuthorized(routeContext: avatarImageRouteContext) else { return }
            loadedState = loadedImage.map {
                CachedRemoteImageState(identity: requestedIdentity, image: $0)
            }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool
    var placeholder = "搜索"
    var onSearch: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IMColor.muted)
            TextField(placeholder, text: $text)
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit(performSearch)
                .imReadableInputText()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(hex: 0xB7BED0))
                }
                .buttonStyle(.plain)
            }
            Button(action: performSearch) {
                Text("搜索")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(IMColor.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
        )
    }

    private func performSearch() {
        onSearch()
    }
}

struct PinnedSearchHeader<Content: View>: View {
    var topPadding: CGFloat = 10
    var bottomPadding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 18)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PinnedSearchBackground())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(IMColor.line.opacity(0.68))
                    .frame(height: 1)
            }
            .zIndex(2)
    }
}

struct PinnedSearchTopMask: View {
    var body: some View {
        GeometryReader { proxy in
            PinnedSearchBackground()
                .frame(height: proxy.safeAreaInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
    }
}

private struct PinnedSearchBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                IMColor.page.opacity(0.99),
                Color(hex: 0xEEF1FF).opacity(0.98),
                Color(hex: 0xEAF8FF).opacity(0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum AvatarCropBounds {
    static func clampedScale(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func clampedOffset(imageSize: CGSize, previewSize: CGFloat, scale: CGFloat, proposed: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, previewSize > 0 else { return .zero }
        let baseScale = max(previewSize / imageSize.width, previewSize / imageSize.height)
        let effectiveScale = max(scale, 0.0001)
        let displayedWidth = imageSize.width * baseScale * effectiveScale
        let displayedHeight = imageSize.height * baseScale * effectiveScale
        let maxX = max(0, (displayedWidth - previewSize) / 2)
        let maxY = max(0, (displayedHeight - previewSize) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

struct Chip: View {
    let title: String
    var isSelected = false
    var count: Int?
    var countColor: Color = IMColor.brand
    var countFilled = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count, let badgeText = UnreadBadgeFormatter.text(count) {
                Text(badgeText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(countColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? .white.opacity(0.96) : countColor.opacity(0.10))
                    )
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isSelected ? .white : IMColor.ink)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(
            Capsule()
                .fill(isSelected ? IMColor.brand : .white)
                .overlay(Capsule().stroke(isSelected ? IMColor.brand : IMColor.line))
        )
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = IMColor.brand
    var filled = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(filled ? color : color.opacity(0.11)))
    }
}

struct GroupInviteApprovalCard: View {
    @EnvironmentObject private var state: AppState
    let approval: GroupInviteApproval
    var compact = false

    private var statusColor: Color {
        if approval.isApproved {
            return IMColor.success
        }
        if approval.isRejected {
            return IMColor.danger
        }
        if approval.isCanceled || approval.isExpired {
            return IMColor.muted
        }
        return IMColor.warning
    }

    private var inviteSummary: String {
        let inviter = approval.inviterName.isEmpty ? "成员" : approval.inviterName
        let invitee = approval.inviteeName.isEmpty ? "用户" : approval.inviteeName
        if approval.isJoinRequest {
            if approval.kind == "group_invite_receipt", approval.isPending {
                return "\(invitee) 的入群申请等待群主或管理员审核"
            }
            return "\(invitee) 申请加入群聊"
        }
        if approval.kind == "group_invite_receipt", approval.isPending {
            return "\(invitee) 的入群邀请等待群主或管理员审核"
        }
        return "\(inviter) 邀请 \(invitee) 入群"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: approval.isPending ? "person.2.badge.gearshape.fill" : "person.2.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(statusColor)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(statusColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 5) {
                    Text(approval.groupName.isEmpty ? "群邀请审批" : approval.groupName)
                        .font(.system(size: compact ? 15 : 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    Text(inviteSummary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                StatusPill(title: approval.statusText, color: statusColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                if approval.isJoinRequest {
                    approvalMetaRow(title: "申请人", value: accountText(name: approval.inviteeName, accountID: approval.inviteeAccountID), copyValue: approval.inviteeAccountID)
                } else {
                    approvalMetaRow(title: "邀请人", value: accountText(name: approval.inviterName, accountID: approval.inviterAccountID), copyValue: approval.inviterAccountID)
                    approvalMetaRow(title: "被邀请人", value: accountText(name: approval.inviteeName, accountID: approval.inviteeAccountID), copyValue: approval.inviteeAccountID)
                }
                if !approval.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !approval.isPending {
                    approvalMetaRow(title: "处理结果", value: approval.resultText)
                }
                if !approval.actedSummary.isEmpty {
                    approvalMetaRow(title: "处理记录", value: approval.actedSummary)
                }
                if !approval.approverAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    approvalMetaRow(title: "处理人ID", value: approval.approverAccountID, copyValue: approval.approverAccountID)
                }
            }

            if approval.kind == "group_invite_receipt", approval.isPending {
                Label(approval.isJoinRequest ? "已提交申请，等待审核结果" : "已提交邀请，等待审核结果", systemImage: "clock.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IMColor.warning.opacity(0.10)))
            }

            if approval.kind == "group_invite_approval", approval.isPending {
                let isProcessing = state.groupInviteApprovalProcessingIDs.contains(approval.requestID)
                let rejectDisabled = !approval.canReject || approval.rejectEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing
                let approveDisabled = !approval.canApprove || approval.approveEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing
                HStack(spacing: 10) {
                    Button {
                        state.reviewGroupInviteApproval(approval, approve: false)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .foregroundStyle(IMColor.danger)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IMColor.danger.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .disabled(rejectDisabled)
                    .opacity(rejectDisabled ? 0.46 : 1)

                    Button {
                        state.reviewGroupInviteApproval(approval, approve: true)
                    } label: {
                        Label("通过", systemImage: "checkmark")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .foregroundStyle(.white)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IMColor.brand))
                    }
                    .buttonStyle(.plain)
                    .disabled(approveDisabled)
                    .opacity(approveDisabled ? 0.46 : 1)
                }
            }
        }
        .padding(compact ? 12 : 15)
        .background(
            RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
                .fill(.white.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
                        .stroke(statusColor.opacity(approval.isPending ? 0.28 : 0.16), lineWidth: 1)
                )
        )
    }

    private func approvalMetaRow(title: String, value: String, copyValue: String? = nil) -> some View {
        let normalizedCopyValue = copyValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.ink.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
            guard let normalizedCopyValue else { return }
            state.copyUserID(normalizedCopyValue)
        })
        .accessibilityLabel(normalizedCopyValue == nil ? "\(title) \(value)" : "\(title) \(value)，点击复制用户ID")
    }

    private func accountText(name: String, accountID: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAccount.isEmpty { return trimmedName.isEmpty ? "未知用户" : trimmedName }
        if trimmedName.isEmpty { return trimmedAccount }
        return "\(trimmedName) · \(trimmedAccount)"
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var disabled = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("处理中")
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: (disabled || isLoading) ? [Color(hex: 0xB8C0D8), Color(hex: 0xAEB6D0)] : [IMColor.brand, IMColor.violet],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
        }
        .disabled(disabled || isLoading)
        .buttonStyle(.plain)
    }
}

struct CopyableUserIDText: View {
    @EnvironmentObject private var state: AppState
    let value: String
    var prefix: String = ""
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = IMColor.muted

    private var normalizedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Text(prefix + normalizedValue)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded {
                state.copyUserID(normalizedValue)
            })
            .accessibilityLabel(normalizedValue.isEmpty ? "用户ID为空" : "用户ID \(normalizedValue)，点击复制")
    }
}

struct EnterpriseLogoView: View {
    let enterprise: Enterprise
    var size: CGFloat
    var cornerRadius: CGFloat = 18
    var cacheKey: String = ""

    private var remoteURL: URL? {
        guard enterprise.isLogoRenderable else { return nil }
        let raw = enterprise.logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("data:image") else { return nil }
        return URL(string: raw)
    }

    private var dataImage: UIImage? {
        guard enterprise.isLogoRenderable else { return nil }
        let raw = enterprise.logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("data:image"),
              let commaIndex = raw.firstIndex(of: ",") else { return nil }
        let encoded = String(raw[raw.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return RemoteImageDecoder.preparedImage(from: data, maxPixelSize: maxPixelSize)
    }

    private var maxPixelSize: Int {
        max(96, Int(ceil(size * UIScreen.main.scale * 1.5)))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: enterprise.accentHex), IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                if let dataImage {
                    Image(uiImage: dataImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else if let remoteURL {
                    CachedRemoteImage(urlString: remoteURL.absoluteString, cacheKey: cacheKey, maxPixelSize: maxPixelSize) {
                        enterpriseFallbackIcon
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else {
                    enterpriseFallbackIcon
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.42), lineWidth: 1)
            )
            .accessibilityLabel("\(enterprise.name) Logo")
    }

    private var enterpriseFallbackIcon: some View {
        Image(systemName: "building.2.crop.circle.fill")
            .font(.system(size: size * 0.40, weight: .bold))
            .foregroundStyle(.white)
    }
}

struct IconButton: View {
    let symbol: String
    var tint: Color = IMColor.brand
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(Circle().fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

struct FormInput: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var textContentType: UITextContentType?
    @State private var isSecureTextVisible = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            HStack(spacing: 8) {
                inputField
                    .focused($isInputFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 16, weight: .semibold))
                    .imReadableInputText()

                if secure {
                    Button {
                        let shouldRestoreFocus = isInputFocused
                        isSecureTextVisible.toggle()
                        if shouldRestoreFocus {
                            DispatchQueue.main.async {
                                isInputFocused = true
                            }
                        }
                    } label: {
                        Image(systemName: isSecureTextVisible ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSecureTextVisible ? "隐藏密码" : "显示密码")
                    .accessibilityHint(title)
                    .accessibilityValue(isSecureTextVisible ? "已显示" : "已隐藏")
                }
            }
            .frame(height: 48)
            .padding(.leading, 14)
            .padding(.trailing, secure ? 4 : 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
            )
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if secure && !isSecureTextVisible {
            SecureField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textContentType(resolvedTextContentType)
        } else if secure {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textContentType(resolvedTextContentType)
        } else {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textContentType(resolvedTextContentType)
        }
    }

    private var resolvedTextContentType: UITextContentType? {
        secure ? (textContentType ?? .password) : textContentType
    }
}

enum SliderVerificationPolicy {
    static let completionRatio: CGFloat = 0.58

    static func clampedOffset(locationX: CGFloat, width: CGFloat) -> CGFloat {
        min(max(locationX - 25, 0), max(width - 50, 0))
    }

    static func completes(offset: CGFloat, width: CGFloat) -> Bool {
        offset > width * completionRatio
    }
}

struct SliderVerification: View {
    @Binding var verified: Bool
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(verified ? IMColor.success.opacity(0.14) : Color(hex: 0xEDF1FA))
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(verified ? IMColor.success.opacity(0.22) : IMColor.brand.opacity(0.16))
                    .frame(width: verified ? width : max(50, dragOffset + 50))
                Text(verified ? "验证通过" : "向右滑动完成验证")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(verified ? IMColor.success : IMColor.muted)
                    .frame(maxWidth: .infinity)
                Circle()
                    .fill(verified ? IMColor.success : IMColor.brand)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: verified ? "checkmark" : "chevron.right")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.white)
                    )
                    .offset(x: verified ? width - 50 : dragOffset)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !verified else { return }
                        dragOffset = SliderVerificationPolicy.clampedOffset(locationX: value.location.x, width: width)
                    }
                    .onEnded { _ in
                        guard !verified else { return }
                        if SliderVerificationPolicy.completes(offset: dragOffset, width: width) {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                verified = true
                                dragOffset = width - 50
                            }
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityIdentifier("slider_verification")
            .accessibilityLabel(verified ? "验证通过" : "向右滑动完成验证")
            .accessibilityValue(verified ? "验证通过" : "未完成")
            .accessibilityAdjustableAction { direction in
                guard !verified else { return }
                switch direction {
                case .increment:
                    dragOffset = width - 50
                    verified = true
                case .decrement:
                    dragOffset = 0
                @unknown default:
                    break
                }
            }
        }
        .frame(height: 50)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(IMColor.brand)
                .frame(width: 68, height: 68)
                .background(Circle().fill(IMColor.brand.opacity(0.12)))
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(IMColor.ink)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(IMColor.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(IMColor.brand)
            }
        }
        .frame(maxWidth: .infinity)
        .plainCard(radius: 26)
    }
}

struct RemoteLoadingStateView: View {
    var title = "正在同步真实数据"
    var subtitle = "正在拉取会话、成员和消息，请稍候。"

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(IMColor.brand)
                .scaleEffect(1.1)
                .frame(width: 68, height: 68)
                .background(Circle().fill(IMColor.brand.opacity(0.10)))
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(IMColor.ink)
            Text(subtitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .plainCard(radius: 26)
        .redacted(reason: .placeholder)
    }
}

struct GlobalBackSwipeInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let window = uiView.window else { return }
            context.coordinator.installOrRefresh(on: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let globalFallbackSwipeName = "JHTGlobalLeftHalfBackSwipe"
        private let leftSideInteractivePopName = "JHTLeftSideInteractivePopSwipe"
        private let chatInteractivePopName = "JHTChatLeftSideInteractivePopSwipe"
        private weak var installedWindow: UIWindow?
        private var startPoint: CGPoint = .zero

        func installOrRefresh(on window: UIWindow) {
            enableInteractivePopGestures(in: window)
            guard installedWindow !== window else { return }
            installedWindow?.gestureRecognizers?
                .filter { $0.name == globalFallbackSwipeName }
                .forEach { installedWindow?.removeGestureRecognizer($0) }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.name = globalFallbackSwipeName
            pan.cancelsTouchesInView = false
            pan.delegate = self
            window.addGestureRecognizer(pan)
            installedWindow = window
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            startPoint = pan.location(in: view)
            let velocity = pan.velocity(in: view)
            let isFromLeftSide = startPoint.x <= view.bounds.width * 0.5
            let isRightSwipe = velocity.x > 120 && abs(velocity.x) > abs(velocity.y) * 1.2
            guard isFromLeftSide, isRightSwipe else { return false }
            if gestureRecognizer.name == leftSideInteractivePopName {
                let navigation = view.jhtOwningNavigationController()
                return (navigation?.viewControllers.count ?? 0) > 1
            }
            if gestureRecognizer.name == globalFallbackSwipeName {
                if canPopNavigationBack(), hasInstalledInteractivePopPanForCurrentNavigation() {
                    return false
                }
                return canNavigateBack()
            }
            return canNavigateBack()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended,
                  let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            guard startPoint.x <= view.bounds.width * 0.5,
                  translation.x > 72,
                  abs(translation.x) > abs(translation.y) * 1.35,
                  velocity.x > 120 else { return }
            triggerBackAction()
        }

        private func enableInteractivePopGestures(in window: UIWindow) {
            for navigation in window.rootViewController?.jhtNavigationControllers() ?? [] {
                guard let popGesture = navigation.interactivePopGestureRecognizer else { continue }
                popGesture.isEnabled = true
                popGesture.delegate = self
                installLeftSideInteractivePopPan(on: navigation, from: popGesture)
            }
        }

        private func installLeftSideInteractivePopPan(on navigation: UINavigationController, from popGesture: UIGestureRecognizer) {
            if navigation.view.gestureRecognizers?.contains(where: { $0.name == leftSideInteractivePopName }) == true {
                return
            }
            guard let targets = popGesture.value(forKey: "targets") as? [NSObject],
                  let internalTarget = targets.first?.value(forKey: "target") else {
                return
            }
            let pan = UIPanGestureRecognizer(target: internalTarget, action: Selector(("handleNavigationTransition:")))
            pan.name = leftSideInteractivePopName
            pan.cancelsTouchesInView = true
            pan.delegate = self
            navigation.view.addGestureRecognizer(pan)
        }

        private func canNavigateBack() -> Bool {
            guard let top = UIApplication.shared.jhtTopViewController() else { return false }
            if let navigation = top.navigationController, navigation.viewControllers.count > 1 {
                return true
            }
            if let navigation = top as? UINavigationController, navigation.viewControllers.count > 1 {
                return true
            }
            if top.navigationController?.presentingViewController != nil {
                return true
            }
            return top.presentingViewController != nil
        }

        private func canPopNavigationBack() -> Bool {
            guard let navigation = currentNavigationControllerForPop() else { return false }
            return navigation.viewControllers.count > 1
        }

        private func hasInstalledInteractivePopPanForCurrentNavigation() -> Bool {
            currentNavigationControllerForPop()?.view.gestureRecognizers?.contains {
                $0.name == leftSideInteractivePopName || $0.name == chatInteractivePopName
            } == true
        }

        private func currentNavigationControllerForPop() -> UINavigationController? {
            guard let top = UIApplication.shared.jhtTopViewController() else { return nil }
            return (top as? UINavigationController) ?? top.navigationController
        }

        private func triggerBackAction() {
            guard let top = UIApplication.shared.jhtTopViewController() else { return }
            if let navigation = top.navigationController, navigation.viewControllers.count > 1 {
                navigation.popViewController(animated: true)
                return
            }
            if let navigation = top as? UINavigationController, navigation.viewControllers.count > 1 {
                navigation.popViewController(animated: true)
                return
            }
            if let navigation = top.navigationController, navigation.presentingViewController != nil {
                navigation.dismiss(animated: true)
                return
            }
            if top.presentingViewController != nil {
                top.dismiss(animated: true)
            }
        }
    }
}

struct ChatBackSwipeInstaller: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> HostController {
        let controller = HostController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: HostController, context: Context) {
        uiViewController.coordinator = context.coordinator
        DispatchQueue.main.async {
            context.coordinator.install(from: uiViewController)
        }
    }

    final class HostController: UIViewController {
        weak var coordinator: Coordinator?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            coordinator?.install(from: self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let chatInteractivePopName = "JHTChatLeftSideInteractivePopSwipe"
        private weak var installedNavigation: UINavigationController?

        func install(from hostController: UIViewController) {
            guard let navigation = navigationController(for: hostController),
                  let popGesture = navigation.interactivePopGestureRecognizer else { return }
            installedNavigation = navigation
            popGesture.isEnabled = true
            popGesture.delegate = self
            if let existingPan = navigation.view.gestureRecognizers?.first(where: { $0.name == chatInteractivePopName }) as? UIPanGestureRecognizer {
                existingPan.isEnabled = true
                existingPan.delegate = self
                return
            }
            guard let targets = popGesture.value(forKey: "targets") as? [NSObject],
                  let internalTarget = targets.first?.value(forKey: "target") else {
                return
            }
            let pan = UIPanGestureRecognizer(target: internalTarget, action: Selector(("handleNavigationTransition:")))
            pan.name = chatInteractivePopName
            pan.cancelsTouchesInView = true
            pan.delegate = self
            navigation.view.addGestureRecognizer(pan)
        }

        private func navigationController(for controller: UIViewController) -> UINavigationController? {
            var current: UIViewController? = controller
            while let candidate = current {
                if let navigation = candidate as? UINavigationController {
                    return navigation
                }
                if let navigation = candidate.navigationController {
                    return navigation
                }
                current = candidate.parent
            }
            guard let top = UIApplication.shared.jhtTopViewController() else { return nil }
            return (top as? UINavigationController) ?? top.navigationController
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let navigation = installedNavigation ?? view.jhtOwningNavigationController()
            guard (navigation?.viewControllers.count ?? 0) > 1 else { return false }
            let startPoint = pan.location(in: view)
            let velocity = pan.velocity(in: view)
            let isFromLeftSide = startPoint.x <= view.bounds.width * 0.5
            let isRightSwipe = velocity.x > 120 && abs(velocity.x) > abs(velocity.y) * 1.2
            if gestureRecognizer.name == chatInteractivePopName {
                return isFromLeftSide && isRightSwipe
            }
            return isRightSwipe
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 自定义“左半屏返回”拖拽必须能与列表的 ScrollView / DragGesture 同时识别，
            // 否则在对话页会被消息列表的滚动手势抢占，导致左滑返回失效。
            gestureRecognizer.name == chatInteractivePopName
        }
    }
}

private extension UIApplication {
    func jhtTopViewController() -> UIViewController? {
        let activeWindow = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return activeWindow?.rootViewController?.jhtTopMost()
    }
}

private extension UIView {
    func jhtNearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    func jhtOwningNavigationController() -> UINavigationController? {
        if let navigation = jhtNearestViewController() as? UINavigationController {
            return navigation
        }
        return jhtNearestViewController()?.navigationController
    }
}

private extension UIViewController {
    func jhtTopMost() -> UIViewController {
        if let presentedViewController {
            return presentedViewController.jhtTopMost()
        }
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.jhtTopMost() ?? navigation
        }
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.jhtTopMost() ?? tab
        }
        return self
    }

    func jhtNavigationControllers() -> [UINavigationController] {
        var result: [UINavigationController] = []
        collectNavigationControllers(into: &result)
        return result
    }

    private func collectNavigationControllers(into result: inout [UINavigationController]) {
        if let navigation = self as? UINavigationController {
            result.append(navigation)
        }
        if let navigationController, !result.contains(where: { $0 === navigationController }) {
            result.append(navigationController)
        }
        for child in children {
            child.collectNavigationControllers(into: &result)
        }
        if let tab = self as? UITabBarController {
            tab.viewControllers?.forEach { $0.collectNavigationControllers(into: &result) }
        }
        presentedViewController?.collectNavigationControllers(into: &result)
    }
}

extension View {
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, action)
        } else {
            onChange(of: value) { newValue in
                action(newValue, newValue)
            }
        }
    }
}

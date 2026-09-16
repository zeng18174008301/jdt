import Foundation
import ImageIO
import SwiftUI
import UIKit

struct StickerGIFDecodedFrame: @unchecked Sendable {
    let image: UIImage
    let delay: TimeInterval
}

enum StickerGIFResourceError: Error, Equatable {
    case invalidTransport, invalidResponse, unauthorized, tooLarge, invalidGIF
}

/// Native-rejected GIFs use the pinned Wuffs decoder, never a format conversion.
/// Calls are made on the shared decode executor; only the bounded display bitmap escapes.
enum StickerGIFFallbackDecoder {
    struct Metadata {
        let width: Int
        let height: Int
        let frameCount: Int
    }

    static func metadata(data: Data) throws -> Metadata {
        var info = WXTGIFInfo()
        let status = data.withUnsafeBytes { bytes in
            WXTGIFInspect(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &info)
        }
        try check(status)
        return Metadata(width: Int(info.width), height: Int(info.height), frameCount: Int(info.frame_count))
    }

    static func frame(data: Data, index: Int, maxPixelSize: Int) throws -> StickerGIFDecodedFrame {
        try Task.checkCancellation()
        guard index >= 0, index <= Int(UInt32.max) else { throw StickerGIFResourceError.invalidGIF }
        var output = WXTGIFFrame()
        let status = data.withUnsafeBytes { bytes in
            WXTGIFDecode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                         UInt32(index), UInt32(min(1024, max(1, maxPixelSize))), &output,
                         { _ in Task<Never, Never>.isCancelled }, nil)
        }
        try check(status)
        guard let pixels = output.bgra else { throw StickerGIFResourceError.invalidGIF }
        let width = Int(output.width), height = Int(output.height)
        guard width > 0, height > 0, width <= 1024, height <= 1024 else {
            WXTGIFFree(pixels)
            throw StickerGIFResourceError.invalidGIF
        }
        let data = Data(bytesNoCopy: pixels, count: width * height * 4,
                        deallocator: .custom { pointer, _ in WXTGIFFree(pointer) })
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                    | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw StickerGIFResourceError.invalidGIF
        }
        let delay = output.delay_seconds.isFinite && output.delay_seconds > 0
            ? max(0.02, min(655.35, output.delay_seconds)) : 0.1
        return StickerGIFDecodedFrame(image: UIImage(cgImage: image), delay: delay)
    }

    private static func check(_ status: Int32) throws {
        switch status {
        case 0: return
        case 2: throw StickerGIFResourceError.tooLarge
        case 3: throw CancellationError()
        default: throw StickerGIFResourceError.invalidGIF
        }
    }
}

enum StickerGIFResourceReader {
    static let maximumBytes = 10 * 1024 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    static func read(_ url: URL) async throws -> Data {
        try await read(url, session: session)
    }

    static func read(_ url: URL, session: URLSession) async throws -> Data {
        try Task.checkCancellation()
        if url.isFileURL {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            try Task.checkCancellation()
            guard data.count <= maximumBytes else { throw StickerGIFResourceError.tooLarge }
            return data
        }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw StickerGIFResourceError.invalidTransport
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url,
              ["https", "http"].contains(finalURL.scheme?.lowercased() ?? ""),
              url.scheme?.lowercased() != "https" || finalURL.scheme?.lowercased() == "https" else {
            throw StickerGIFResourceError.invalidTransport
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw StickerGIFResourceError.unauthorized }
        guard http.statusCode == 200 else { throw StickerGIFResourceError.invalidResponse }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw StickerGIFResourceError.tooLarge }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw StickerGIFResourceError.tooLarge }
            data.append(byte)
        }
        return data
    }
}

/// Serialize native compositing, including previews, so large logical canvases
/// cannot multiply their scratch allocation across simultaneous players.
private actor StickerGIFDecodeExecutor {
    static let shared = StickerGIFDecodeExecutor()

    func decode(data: Data, index: Int, maxPixelSize: Int) throws -> StickerGIFDecodedFrame {
        try Task.checkCancellation()
        return try autoreleasepool {
            let nativeFrame: StickerGIFDecodedFrame? = autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return try? StickerGIFImageDecoder.decodeFrame(at: index, source: source, maxPixelSize: maxPixelSize)
            }
            if let nativeFrame { return nativeFrame }
            // Release rejected native source/scratch before allocating fallback canvases.
            try Task.checkCancellation()
            return try StickerGIFFallbackDecoder.frame(data: data, index: index, maxPixelSize: maxPixelSize)
        }
    }
}

/// Keep compressed bytes only. Each advance releases its entire ImageIO source
/// (including disposal/compositing state), not just the output thumbnail cache.
actor StickerGIFImageDecoder {
    static let maximumPixelSize = 1024
    // Budget three RGBA canvases for native composite/disposal/scratch work.
    // This admits ordinary 4K/16MP canvases while rejecting allocation bombs.
    static let maximumCompositeWorkingBytes = 192 * 1024 * 1024
    static let maximumSourcePixels = maximumCompositeWorkingBytes / (3 * 4)
    static let maximumFrameBytes = maximumPixelSize * maximumPixelSize * 4
    let frameCount: Int
    let maxPixelSize: Int
    private let data: Data

    init(data: Data, maxPixelSize: Int, requiresGIF: Bool = false) throws {
        let header = Array(data.prefix(10))
        if header.count == 10, String(bytes: header.prefix(3), encoding: .ascii) == "GIF" {
            let width = Int(header[6]) | (Int(header[7]) << 8)
            let height = Int(header[8]) | (Int(header[9]) << 8)
            guard width > 0, height > 0, width <= Self.maximumSourcePixels / height else {
                throw StickerGIFResourceError.tooLarge
            }
        }
        guard !data.isEmpty, data.count <= StickerGIFResourceReader.maximumBytes else {
            throw data.isEmpty ? StickerGIFResourceError.invalidGIF : StickerGIFResourceError.tooLarge
        }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           !requiresGIF || CGImageSourceGetType(source) as String? == "com.compuserve.gif",
           CGImageSourceGetStatus(source) == .statusComplete,
           CGImageSourceGetCount(source) > 0, Self.hasBoundedDimensions(at: 0, source: source) {
            frameCount = CGImageSourceGetType(source) as String? == "com.compuserve.gif" ? CGImageSourceGetCount(source) : 1
        } else {
            frameCount = try StickerGIFFallbackDecoder.metadata(data: data).frameCount
        }
        self.data = data
        self.maxPixelSize = min(Self.maximumPixelSize, max(1, maxPixelSize))
    }

    func frame(at index: Int) async throws -> StickerGIFDecodedFrame {
        try Task.checkCancellation()
        guard index >= 0, index < frameCount else {
            throw StickerGIFResourceError.invalidGIF
        }
        return try await StickerGIFDecodeExecutor.shared.decode(data: data, index: index, maxPixelSize: maxPixelSize)
    }

    fileprivate static func decodeFrame(at index: Int, source: CGImageSource, maxPixelSize: Int) throws -> StickerGIFDecodedFrame {
        guard hasBoundedDimensions(at: index, source: source) else {
            throw StickerGIFResourceError.invalidGIF
        }
        defer { CGImageSourceRemoveCacheAtIndex(source, index) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              image.width <= maxPixelSize, image.height <= maxPixelSize,
              image.bytesPerRow <= Self.maximumFrameBytes / max(1, image.height) else {
            throw StickerGIFResourceError.invalidGIF
        }
        // Give the displayed frame explicit small-bitmap ownership rather than
        // relying on undocumented lifetime details of an ImageIO thumbnail.
        guard let bitmap = CGContext(data: nil, width: image.width, height: image.height,
                                     bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StickerGIFResourceError.invalidGIF
        }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let detached = bitmap.makeImage() else { throw StickerGIFResourceError.invalidGIF }
        try Task.checkCancellation()
        return StickerGIFDecodedFrame(image: UIImage(cgImage: detached), delay: Self.frameDelay(at: index, source: source))
    }

    private static func hasBoundedDimensions(at index: Int, source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, height <= maximumSourcePixels else { return false }
        return width <= maximumSourcePixels / height
    }

    private static func frameDelay(at index: Int, source: CGImageSource) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        guard delay.isFinite, delay > 0 else { return 0.1 }
        // GIF delays use a 16-bit centisecond field; preserve every legal long
        // pause. Reject values that cannot safely become a sleep duration.
        guard delay <= 655.35 else { return 0.1 }
        return max(0.02, delay)
    }
}

@MainActor
final class StickerGIFPlaybackLimiter: ObservableObject {
    static let shared = StickerGIFPlaybackLimiter()
    let maxActivePlayers = 4
    @Published private(set) var activePlayers: Set<UUID> = []
    @Published private(set) var visiblePlayers: Set<UUID> = []
    private var eligiblePlayers: [UUID] = []
    static let previewBudgetBytes = 32 * 1024 * 1024
    var hasCapacity: Bool { activePlayers.count < maxActivePlayers }

    func previewPixelLimit(requested: Int) -> Int {
        let pixelsPerPlayer = Self.previewBudgetBytes / (4 * max(1, visiblePlayers.count))
        return min(max(1, requested), StickerGIFImageDecoder.maximumPixelSize, max(1, Int(Double(pixelsPerPlayer).squareRoot())))
    }

    func setVisible(_ playerID: UUID, _ visible: Bool) {
        if visible {
            if !visiblePlayers.contains(playerID) { visiblePlayers.insert(playerID) }
        } else {
            if visiblePlayers.contains(playerID) { visiblePlayers.remove(playerID) }
            release(playerID)
        }
    }

    func requestAnimation(_ playerID: UUID, eligible: Bool, priority: Bool = false) {
        guard eligible else { release(playerID); return }
        if !eligiblePlayers.contains(playerID) {
            if priority { eligiblePlayers.insert(playerID, at: 0) }
            else { eligiblePlayers.append(playerID) }
        }
        reconcile()
    }

    func prioritize(_ playerID: UUID) {
        guard eligiblePlayers.contains(playerID) else { return }
        eligiblePlayers.removeAll { $0 == playerID }
        eligiblePlayers.insert(playerID, at: 0)
        reconcile()
    }

    private func reconcile() {
        let next = Set(eligiblePlayers.prefix(maxActivePlayers))
        if next != activePlayers { activePlayers = next }
    }

    func acquire(_ playerID: UUID) -> Bool {
        requestAnimation(playerID, eligible: true)
        return activePlayers.contains(playerID)
    }

    func release(_ playerID: UUID) {
        eligiblePlayers.removeAll { $0 == playerID }
        reconcile()
    }
}

struct StickerGIFRequestIdentity: Equatable, Sendable {
    let url: URL?
    let cacheKey: String
    let maxPixelSize: Int
    let requiresGIF: Bool
}

private struct StickerGIFPreparedResource: Sendable {
    let decoder: StickerGIFImageDecoder?
    let frameCount: Int
    let firstFrame: StickerGIFDecodedFrame
}

/// Preview work has its own bounded queue, independent of animation ownership.
/// Waiting rows still get their first frame; they never retain compressed sources.
private actor StickerGIFResourcePreparation {
    static let shared = StickerGIFResourcePreparation()
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func prepare(url: URL, dataSource: StickerGIFFrameLoader.DataSource, maxPixelSize: Int, requiresGIF: Bool, retainDecoder: Bool) async throws -> StickerGIFPreparedResource {
        if active < 4 { active += 1 }
        else { await withCheckedContinuation { waiters.append($0) } }
        defer {
            if waiters.isEmpty { active -= 1 }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let data = try await dataSource(url)
        try Task.checkCancellation()
        let decoder = try StickerGIFImageDecoder(data: data, maxPixelSize: maxPixelSize, requiresGIF: requiresGIF)
        let firstFrame = try await decoder.frame(at: 0)
        try Task.checkCancellation()
        let count = await decoder.frameCount
        return StickerGIFPreparedResource(decoder: retainDecoder && count > 1 ? decoder : nil, frameCount: count, firstFrame: firstFrame)
    }
}

@MainActor
final class StickerGIFFrameLoader: ObservableObject {
    typealias DataSource = @Sendable (URL) async throws -> Data
    @Published private(set) var frame: StickerGIFDecodedFrame?
    @Published private(set) var frameCount = 0
    @Published private(set) var failed = false
    @Published private(set) var generation = UUID()
    private(set) var currentFrameIndex = 0
    private(set) var loadedIdentity: StickerGIFRequestIdentity?
    private var decoder: StickerGIFImageDecoder?
    private var firstFrame: StickerGIFDecodedFrame?
    private var resourceURL: URL?
    var retainsDecoder: Bool { decoder != nil }
    private var loadTask: Task<StickerGIFPreparedResource, Error>?
    private var animationTask: Task<StickerGIFPreparedResource, Error>?
    private var animationGeneration = UUID()
    private let dataSource: DataSource

    init(dataSource: @escaping DataSource = { try await StickerGIFResourceReader.read($0) }) {
        self.dataSource = dataSource
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        animationTask?.cancel()
        animationTask = nil
        animationGeneration = UUID()
        generation = UUID()
        decoder = nil
        firstFrame = nil
        resourceURL = nil
        frame = nil
        frameCount = 0
        currentFrameIndex = 0
        loadedIdentity = nil
        failed = false
    }

    func load(
        url: URL?, cacheKey: String, maxPixelSize: Int, requiresGIF: Bool = false,
        recoveryURL: (@MainActor () async -> URL?)? = nil,
        retainDecoder: Bool = true
    ) async {
        stop()
        let requestGeneration = generation
        let identity = StickerGIFRequestIdentity(url: url, cacheKey: cacheKey, maxPixelSize: maxPixelSize, requiresGIF: requiresGIF)
        loadedIdentity = identity
        guard !cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failed = true
            return
        }
        var candidateURL = url
        var recovered = false
        if candidateURL == nil, let recoveryURL {
            recovered = true
            candidateURL = await recoveryURL()
        }
        guard isCurrent(requestGeneration, identity: identity) else { return }
        while let candidate = candidateURL {
            do {
                let dataSource = dataSource
                let task = Task.detached(priority: .utility) {
                    try await StickerGIFResourcePreparation.shared.prepare(url: candidate, dataSource: dataSource, maxPixelSize: maxPixelSize, requiresGIF: requiresGIF, retainDecoder: retainDecoder)
                }
                loadTask = task
                let resource = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                guard isCurrent(requestGeneration, identity: identity) else { return }
                loadTask = nil
                frameCount = resource.frameCount
                decoder = resource.decoder
                frame = resource.firstFrame
                firstFrame = resource.firstFrame
                resourceURL = candidate
                return
            } catch {
                guard isCurrent(requestGeneration, identity: identity) else { return }
                loadTask = nil
                if error as? StickerGIFResourceError == .unauthorized, !recovered, let recoveryURL {
                    recovered = true
                    candidateURL = await recoveryURL()
                    guard isCurrent(requestGeneration, identity: identity) else { return }
                    continue
                }
                failed = true
                return
            }
        }
        if isCurrent(requestGeneration, identity: identity) { failed = true }
    }

    func releaseAnimation() {
        animationTask?.cancel()
        animationTask = nil
        animationGeneration = UUID()
        decoder = nil
        frame = firstFrame
        currentFrameIndex = 0
    }

    func prepareForPlayback(recoveryURL: (@MainActor () async -> URL?)? = nil) async -> Bool {
        guard frameCount > 1, !failed, let identity = loadedIdentity, let url = resourceURL else { return false }
        if decoder != nil { return true }
        let requestGeneration = generation
        let requestAnimationGeneration = animationGeneration
        var candidateURL: URL? = url
        var recovered = false
        while let candidate = candidateURL {
            do {
                let dataSource = dataSource
                let task = Task.detached(priority: .utility) {
                    try await StickerGIFResourcePreparation.shared.prepare(url: candidate, dataSource: dataSource, maxPixelSize: identity.maxPixelSize, requiresGIF: identity.requiresGIF, retainDecoder: true)
                }
                animationTask = task
                let resource = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard isCurrent(requestGeneration, identity: identity), animationGeneration == requestAnimationGeneration else { return false }
                animationTask = nil
                decoder = resource.decoder
                resourceURL = candidate
                return decoder != nil
            } catch {
                guard isCurrent(requestGeneration, identity: identity), animationGeneration == requestAnimationGeneration else { return false }
                animationTask = nil
                if error as? StickerGIFResourceError == .unauthorized, !recovered, let recoveryURL {
                    recovered = true
                    candidateURL = await recoveryURL()
                    guard isCurrent(requestGeneration, identity: identity), animationGeneration == requestAnimationGeneration else { return false }
                    continue
                }
                failed = true
                return false
            }
        }
        failed = true
        return false
    }

    func showFrame(at index: Int) async -> Bool {
        guard let decoder, let identity = loadedIdentity else { return false }
        let requestGeneration = generation
        let requestAnimationGeneration = animationGeneration
        do {
            let nextFrame = try await decoder.frame(at: index)
            guard isCurrent(requestGeneration, identity: identity), animationGeneration == requestAnimationGeneration else { return false }
            currentFrameIndex = index
            frame = nextFrame
            return true
        } catch {
            if isCurrent(requestGeneration, identity: identity), animationGeneration == requestAnimationGeneration { failed = true }
            return false
        }
    }

    private func isCurrent(_ requestGeneration: UUID, identity: StickerGIFRequestIdentity) -> Bool {
        !Task.isCancelled && generation == requestGeneration && loadedIdentity == identity
    }
}

private struct StickerGIFPlaybackViewportKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    var stickerGIFPlaybackViewport: CGRect? {
        get { self[StickerGIFPlaybackViewportKey.self] }
        set { self[StickerGIFPlaybackViewportKey.self] = newValue }
    }
}

enum StickerGIFVisibility {
    static func intersects(frame: CGRect, viewport: CGRect) -> Bool {
        !frame.isEmpty && !viewport.isEmpty && !frame.isNull && !viewport.isNull
            && frame.intersection(viewport).width > 0 && frame.intersection(viewport).height > 0
    }
}

private struct StickerGIFVisiblePreferenceKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct StickerGIFPlayerLoadToken: Equatable {
    let identity: StickerGIFRequestIdentity
    let canLoad: Bool
}

enum StickerGIFPlaybackEligibility {
    static func allowsAnimation(visible: Bool, frameCount: Int, failed: Bool, reduceMotion: Bool, lowPower: Bool) -> Bool {
        visible && frameCount > 1 && !failed && !reduceMotion && !lowPower
    }
}

struct StickerGIFPlayer<Placeholder: View>: View {
    let url: URL?
    let cacheKey: String
    var maxPixelSize = 360
    var requiresGIF = false
    var playbackPriority = false
    var recoveryURL: (@MainActor () async -> URL?)? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.stickerGIFPlaybackViewport) private var viewport
    @StateObject private var loader = StickerGIFFrameLoader()
    @ObservedObject private var limiter = StickerGIFPlaybackLimiter.shared
    @State private var playerID = UUID()
    @State private var isVisible = false
    @State private var isInViewport = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var canLoad: Bool { isVisible && isInViewport && scenePhase == .active }
    private var wantsAnimation: Bool {
        StickerGIFPlaybackEligibility.allowsAnimation(visible: canLoad, frameCount: loader.frameCount, failed: loader.failed, reduceMotion: reduceMotion, lowPower: lowPowerMode)
    }
    private var hasPlaybackSlot: Bool { limiter.activePlayers.contains(playerID) }
    private var shouldAnimate: Bool { wantsAnimation && hasPlaybackSlot }
    private var loadToken: StickerGIFPlayerLoadToken {
        StickerGIFPlayerLoadToken(
            identity: StickerGIFRequestIdentity(url: url, cacheKey: cacheKey, maxPixelSize: limiter.previewPixelLimit(requested: maxPixelSize), requiresGIF: requiresGIF),
            canLoad: canLoad
        )
    }
    private var playbackToken: String { "\(wantsAnimation)|\(hasPlaybackSlot)|\(loader.generation)|\(loader.frameCount)" }

    var body: some View {
        ZStack {
            if let frame = loader.frame {
                Image(uiImage: frame.image).resizable().scaledToFit()
                if wantsAnimation && !hasPlaybackSlot {
                    Button { limiter.prioritize(playerID) } label: {
                        Label("播放", systemImage: "play.circle.fill")
                            .font(.caption).padding(6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放 GIF")
                }
            } else if loader.failed {
                Label(requiresGIF ? "动图暂无法播放" : "图片暂无法显示", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                placeholder()
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: StickerGIFVisiblePreferenceKey.self,
                    value: StickerGIFVisibility.intersects(
                        frame: proxy.frame(in: .global), viewport: viewport ?? UIScreen.main.bounds
                    )
                )
            }
        }
        .onPreferenceChange(StickerGIFVisiblePreferenceKey.self) { visible in
            guard isInViewport != visible else { return }
            isInViewport = visible
            if !visible { releaseResources() }
            else if isVisible && scenePhase == .active { limiter.setVisible(playerID, true) }
        }
        .task(id: loadToken) {
            guard canLoad else { releaseResources(); return }
            limiter.setVisible(playerID, true)
            await loader.load(url: url, cacheKey: cacheKey, maxPixelSize: loadToken.identity.maxPixelSize, requiresGIF: requiresGIF, recoveryURL: recoveryURL, retainDecoder: false)
        }
        .task(id: playbackToken) {
            limiter.requestAnimation(playerID, eligible: wantsAnimation, priority: playbackPriority)
            guard shouldAnimate else { loader.releaseAnimation(); return }
            guard await loader.prepareForPlayback(recoveryURL: recoveryURL), !Task.isCancelled, shouldAnimate else { return }
            while !Task.isCancelled, shouldAnimate, let frame = loader.frame {
                do { try await Task.sleep(nanoseconds: UInt64(frame.delay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, shouldAnimate else { return }
                let nextIndex = (loader.currentFrameIndex + 1) % loader.frameCount
                guard await loader.showFrame(at: nextIndex) else { return }
            }
        }
        .onAppear {
            isVisible = true
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            if isInViewport && scenePhase == .active { limiter.setVisible(playerID, true) }
        }
        .onDisappear {
            isVisible = false
            releaseResources()
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            if phase != .active { releaseResources() }
            else if isVisible && isInViewport { limiter.setVisible(playerID, true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func releaseResources() {
        loader.stop()
        limiter.setVisible(playerID, false)
    }
}

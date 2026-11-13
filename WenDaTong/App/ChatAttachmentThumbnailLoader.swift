import IM4Features
import SwiftUI
import UIKit

enum AttachmentThumbnailCacheIdentity {
    static func generationKey(baseKey: String, generation: UInt64) -> String {
        "generation:\(generation)|\(baseKey)"
    }
}

struct AttachmentThumbnailImage<Placeholder: View, Failure: View>: View {
    @Environment(\.chatMediaScrollActivity) private var mediaScrollActivity
    let url: URL?
    let cacheKey: String
    var contentMode: ContentMode = .fill
    var maxPixelSize: Int = 768
    var scopeGeneration: UInt64 = 0
    var networkRecoveryGeneration: Int = 0
    var recoveryURL: (() async -> URL?)? = nil
    var recoverOnAnyFailure: Bool = false
    var indexedCacheURL: (() async -> URL?)? = nil
    var indexedCacheCommit: ((Data) async -> URL?)? = nil
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure
    @State private var image: UIImage?
    @State private var loadedKey = ""
    @State private var failed = false
    @State private var retryNonce = 0

    private var stableKey: String {
        let key = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty
            ? AttachmentThumbnailDiskCache.cacheKeyFallback(for: url ?? URL(fileURLWithPath: "attachment-thumbnail-recovery-only"))
            : key
    }

    private var generationKey: String {
        AttachmentThumbnailCacheIdentity.generationKey(baseKey: stableKey, generation: scopeGeneration)
    }

    private var displayKey: String { "\(maxPixelSize)|\(generationKey)" }

    private var displayedImage: UIImage? {
        // Keep the image owned by this row when the shared cache evicts it.
        (loadedKey == displayKey ? image : nil)
            ?? AvatarImageCache.shared.peekImage(for: generationKey, maxPixelSize: maxPixelSize)
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed, loadedKey == displayKey {
                Button {
                    failed = false
                    retryNonce += 1
                } label: {
                    failure()
                }
                .buttonStyle(.plain)
            } else {
                placeholder()
            }
        }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_TASK_PRIORITY - 修改开始：缩略图加载降为 utility，避免下拉历史时抢占滚动
        .task(id: "\(displayKey)|\(url?.absoluteString ?? "recovery-only")|\(retryNonce)", priority: .utility) {
            await load()
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_TASK_PRIORITY - 修改结束：缩略图加载降为 utility，避免下拉历史时抢占滚动
        .onChangeCompat(of: networkRecoveryGeneration) { previous, current in
            guard current != previous, failed, loadedKey == displayKey, displayedImage == nil else { return }
            let generationKey = generationKey
            Task {
                guard await MediaVisibleRecoveryGate.shared.shouldRetry(
                    key: generationKey
                ) else {
                    return
                }
                await MainActor.run {
                    guard failed, loadedKey == displayKey, displayedImage == nil else { return }
                    failed = false
                    retryNonce &+= 1
                }
            }
        }
    }

    // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113_BEGIN
    @MainActor
    private func waitForMediaIdle() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let mediaScrollActivity, !mediaScrollActivity.isIdle else { return true }
        return await mediaScrollActivity.waitUntilIdle()
    }
    // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113_END

    @MainActor
    private func load() async {
        guard !Task.isCancelled, loadedKey != displayKey || image == nil else { return }
        let displayKey = displayKey
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_LOAD_SNAPSHOT - 修改开始：先快照加载参数，后台任务不捕获整个 View
        let requestedURL = url
        let requestedMaxPixelSize = maxPixelSize
        let requestedIndexedCacheURL = indexedCacheURL
        let requestedIndexedCacheCommit = indexedCacheCommit
        let requestedRecoveryURL = recoveryURL
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_LOAD_SNAPSHOT - 修改结束：先快照加载参数，后台任务不捕获整个 View
        let stableKey = stableKey
        let generationKey = generationKey
        func applyThumbnailState(image: UIImage?, failed: Bool) {
            guard !Task.isCancelled else { return }
            self.applyThumbnailState(image: image, failed: failed, key: displayKey)
        }
        if let cached = AvatarImageCache.shared.image(for: generationKey, maxPixelSize: requestedMaxPixelSize) {
            applyThumbnailState(image: cached, failed: false)
            return
        }
        guard requestedURL != nil || requestedIndexedCacheURL != nil || requestedRecoveryURL != nil else { return }
        if let mediaScrollActivity, !(await mediaScrollActivity.waitUntilIdle()) { return }
        var hadIndexedURL = false
        if let requestedIndexedCacheURL {
            let gate = AttachmentThumbnailLoadGate.localDecodes
            guard await gate.acquire() else { return }
            // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113_BEGIN
            // The row may have waited for a slot across a new drag.
            guard await waitForMediaIdle() else {
                await gate.release()
                return
            }
            // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113_END
            let indexedURL = Task.isCancelled ? nil : await requestedIndexedCacheURL()
            hadIndexedURL = indexedURL != nil
            let indexedImage: UIImage?
            if let indexedURL, !Task.isCancelled {
                indexedImage = await AttachmentThumbnailDiskCache.localPreparedImage(
                    from: indexedURL, maxPixelSize: requestedMaxPixelSize)
            } else {
                indexedImage = nil
            }
            await gate.release()
            guard !Task.isCancelled else { return }
            if let indexedImage {
                guard await waitForMediaIdle() else { return } // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113
                AvatarImageCache.shared.storePrepared(indexedImage, for: generationKey, maxPixelSize: requestedMaxPixelSize)
                applyThumbnailState(image: indexedImage, failed: false)
                return
            }
        }
        if !hadIndexedURL, mediaScrollActivity == nil {
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_VISIBLE_DEBOUNCE - 修改开始：快速滑过的图片不进入加载队列，减少历史滚动卡顿
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_VISIBLE_DEBOUNCE - 修改结束：快速滑过的图片不进入加载队列，减少历史滚动卡顿
        }
        guard await AttachmentThumbnailLoadGate.shared.acquire() else { return }
        guard !Task.isCancelled else {
            await AttachmentThumbnailLoadGate.shared.release()
            return
        }
        defer {
            Task {
                await AttachmentThumbnailLoadGate.shared.release()
            }
        }
        guard await waitForMediaIdle() else { return } // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113
        if let cached = AvatarImageCache.shared.image(for: generationKey, maxPixelSize: requestedMaxPixelSize) {
            applyThumbnailState(image: cached, failed: false)
            return
        }
        let result: AttachmentThumbnailDownloadResult?
        if let requestedURL {
            result = await AttachmentThumbnailSingleFlight.shared.perform(key: "initial|\(generationKey)") {
                await AttachmentThumbnailDiskCache.downloadImageResult(
                    from: requestedURL,
                    cacheKey: stableKey,
                    maxPixelSize: requestedMaxPixelSize
                )
            }
        } else {
            result = nil
        }
        guard await waitForMediaIdle() else { return } // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113
        if let loaded = result?.image {
            if let data = result?.data, let requestedIndexedCacheCommit {
                _ = await requestedIndexedCacheCommit(data)
            }
            guard await waitForMediaIdle() else { return } // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113
            AvatarImageCache.shared.storePrepared(loaded, for: generationKey, maxPixelSize: requestedMaxPixelSize)
            applyThumbnailState(image: loaded, failed: false)
        } else if (recoverOnAnyFailure || requestedURL == nil || result?.shouldRefreshSignedURL == true),
                  let requestedRecoveryURL,
                  let recoveredURL = await requestedRecoveryURL() {
            guard await waitForMediaIdle() else { return } // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113
            let recoveredResult = await AttachmentThumbnailSingleFlight.shared.perform(key: "recovery|\(generationKey)") {
                await AttachmentThumbnailDiskCache.downloadImageResult(
                    from: recoveredURL,
                    cacheKey: stableKey,
                    maxPixelSize: requestedMaxPixelSize
                )
            }
            guard await waitForMediaIdle() else { return } // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113
            guard let recovered = recoveredResult.image else {
                applyThumbnailState(image: nil, failed: true)
                return
            }
            guard !Task.isCancelled else { return }
            if let data = recoveredResult.data, let requestedIndexedCacheCommit {
                _ = await requestedIndexedCacheCommit(data)
            }
            guard await waitForMediaIdle() else { return } // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113
            AvatarImageCache.shared.storePrepared(recovered, for: generationKey, maxPixelSize: requestedMaxPixelSize)
            applyThumbnailState(image: recovered, failed: false)
        } else {
            guard await waitForMediaIdle() else { return } // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113
            applyThumbnailState(image: nil, failed: true)
        }
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_STATE_NO_ANIMATION - 修改开始：缩略图完成时禁用隐式动画，减少滚动中重绘压力
    @MainActor
    private func applyThumbnailState(image newImage: UIImage?, failed isFailed: Bool, key: String) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            loadedKey = key
            image = newImage
            failed = isFailed
        }
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_STATE_NO_ANIMATION - 修改结束：缩略图完成时禁用隐式动画，减少滚动中重绘压力
}

private actor AttachmentThumbnailSingleFlight {
    static let shared = AttachmentThumbnailSingleFlight()
    private var tasks: [String: Task<AttachmentThumbnailDownloadResult, Never>] = [:]

    func perform(
        key: String,
        operation: @escaping @Sendable () async -> AttachmentThumbnailDownloadResult
    ) async -> AttachmentThumbnailDownloadResult {
        if let task = tasks[key] { return await task.value }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_SINGLEFLIGHT_DETACHED - 修改开始：缩略图下载/解码任务脱离主 actor
        let task = Task.detached(priority: .utility) { await operation() }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_SINGLEFLIGHT_DETACHED - 修改结束：缩略图下载/解码任务脱离主 actor
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        return result
    }
}

// WDT_CHAT_RESOURCE_PERF_20261023_BEGIN
actor AttachmentThumbnailLoadGate {
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_LOAD_CONCURRENCY - 修改开始：降低聊天缩略图并发，避免图片批量加载拖慢历史滚动
    static let shared = AttachmentThumbnailLoadGate(limit: 2)
    static let localDecodes = AttachmentThumbnailLoadGate(limit: 2)
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_LOAD_CONCURRENCY - 修改结束：降低聊天缩略图并发，避免图片批量加载拖慢历史滚动
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if running < limit {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    func release() {
        if !waiters.isEmpty {
            // Transfer the occupied slot; a new arrival must not steal it before the waiter resumes.
            waiters.removeFirst().continuation.resume(returning: true)
        } else {
            running = max(0, running - 1)
        }
    }
}
// WDT_CHAT_RESOURCE_PERF_20261023_END

struct AttachmentThumbnailDownloadResult: @unchecked Sendable {
    let image: UIImage?
    let statusCode: Int?
    let data: Data?

    var shouldRefreshSignedURL: Bool {
        guard let statusCode else { return false }
        return statusCode == 401 || statusCode == 403
    }
}

enum AttachmentThumbnailDiskCache {
    static func image(for cacheKey: String, maxPixelSize: Int? = nil) async -> UIImage? {
        // Persistent bytes are owned by MediaLayeredCacheStore/cache_entry.  This legacy
        // API remains as a fail-closed compatibility shim for existing tests/callers.
        nil
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_BACKGROUND_DECODE_HELPERS - 修改开始：缩略图文件读取和解码统一放到后台
    static func localPreparedImage(from url: URL, maxPixelSize: Int? = nil) async -> UIImage? {
        // WDT_CHAT_RESOURCE_PERF_20261023_BEGIN: indexed cache hits need pixels, not another full source Data.
        await Task.detached(priority: .utility) {
            autoreleasepool {
                if let limit = RemoteImageDecoder.boundedMaxPixelSize(maxPixelSize),
                   let image = RemoteImageDecoder.image(fromFileURL: url, maxPixelSize: limit) {
                    return image.preparingForDisplay() ?? image
                }
                // Preserve the existing format fallback when ImageIO cannot make a thumbnail.
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return RemoteImageDecoder.preparedImage(from: data, maxPixelSize: maxPixelSize)
            }
        }.value
        // WDT_CHAT_RESOURCE_PERF_20261023_END
    }

    private static func localImageResult(from url: URL, maxPixelSize: Int? = nil) async -> AttachmentThumbnailDownloadResult {
        await Task.detached(priority: .utility) {
            // WDT_CHAT_RESOURCE_PERF_20261023_BEGIN: retain original bytes for the existing cache commit contract.
            autoreleasepool {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let image = RemoteImageDecoder.preparedImage(from: data, maxPixelSize: maxPixelSize) else {
                    return AttachmentThumbnailDownloadResult(image: nil, statusCode: nil, data: nil)
                }
                return AttachmentThumbnailDownloadResult(image: image, statusCode: nil, data: data)
            }
            // WDT_CHAT_RESOURCE_PERF_20261023_END
        }.value
    }

    private static func preparedImageResult(
        data: Data,
        statusCode: Int?,
        maxPixelSize: Int? = nil
    ) async -> AttachmentThumbnailDownloadResult {
        await Task.detached(priority: .utility) {
            // WDT_CHAT_RESOURCE_PERF_20261023_BEGIN
            autoreleasepool {
                guard let image = RemoteImageDecoder.preparedImage(from: data, maxPixelSize: maxPixelSize) else {
                    return AttachmentThumbnailDownloadResult(image: nil, statusCode: statusCode, data: nil)
                }
                return AttachmentThumbnailDownloadResult(image: image, statusCode: statusCode, data: data)
            }
            // WDT_CHAT_RESOURCE_PERF_20261023_END
        }.value
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_BACKGROUND_DECODE_HELPERS - 修改结束：缩略图文件读取和解码统一放到后台

    static func downloadImage(
        from url: URL,
        cacheKey: String,
        maxPixelSize: Int? = nil,
        imageTransport: any RemoteImageTransporting = URLSessionRemoteImageTransport()
    ) async -> UIImage? {
        (await downloadImageResult(
            from: url,
            cacheKey: cacheKey,
            maxPixelSize: maxPixelSize,
            imageTransport: imageTransport
        )).image
    }

    static func downloadImageResult(
        from url: URL,
        cacheKey: String,
        maxPixelSize: Int? = nil,
        imageTransport: any RemoteImageTransporting = URLSessionRemoteImageTransport()
    ) async -> AttachmentThumbnailDownloadResult {
        if url.isFileURL {
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_LOCAL_BACKGROUND_DECODE - 修改开始：本地缩略图读取不占用主线程
            return await localImageResult(from: url, maxPixelSize: maxPixelSize)
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_LOCAL_BACKGROUND_DECODE - 修改结束：本地缩略图读取不占用主线程
        }
        do {
            let result = try await imageTransport.data(from: url)
            if let statusCode = result.statusCode, !(200..<300).contains(statusCode) {
                return AttachmentThumbnailDownloadResult(image: nil, statusCode: statusCode, data: nil)
            }
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_NETWORK_BACKGROUND_DECODE - 修改开始：网络缩略图数据返回后后台解码
            return await preparedImageResult(
                data: result.data,
                statusCode: result.statusCode,
                maxPixelSize: maxPixelSize
            )
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_NETWORK_BACKGROUND_DECODE - 修改结束：网络缩略图数据返回后后台解码
        } catch {
            return AttachmentThumbnailDownloadResult(image: nil, statusCode: nil, data: nil)
        }
    }

    static func cacheKeyFallback(for url: URL) -> String {
        "thumbnail-url|\(stableHash(url.absoluteString))"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

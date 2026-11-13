import IM4Features
import SwiftUI
import UIKit
import QuickLook
import AVFoundation

struct FilePreviewView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let file: FileItem
    @State private var previewDocument: LocalPreviewDocument?
    @State private var shareItem: FileShareItem?
    @State private var isPreparingPreview = false
    @State private var isPreparingShare = false
    @State private var previewState: FilePreviewOpenState = .idle

    var body: some View {
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
        state.observeProtectedAccess(.filePreview) { authorized in
            if !authorized {
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END
                BiometricProtectedContentGate(
                    symbol: "faceid",
                    title: "文件预览已受保护",
                    subtitle: "通过 Face ID 验证后才能查看企业文件。"
                ) {
                    _ = await state.authorizeProtectedAccess(.filePreview)
                }
            } else {
                unlockedBody
            }
        }
    }

    private var unlockedBody: some View {
        FilePreviewScreenContent(file: file.featureDisplay, kind: file.visualKind, canPreview: file.canAttemptSystemPreview,
            previewState: previewState, isPreparingShare: isPreparingShare, hero: {
                FilePreviewHeroContent(file: file.featureDisplay, kind: file.visualKind, thumbnailURL: file.thumbnailRemoteURL,
                    isPreparingPreview: isPreparingPreview) { url, placeholder in
                    CachedRemoteImage(urlString: url.absoluteString, contentMode: .fit, maxPixelSize: 640) {
                        placeholder
                    }
                }
            }, progress: {
                FileDownloadProgress(store: state.fileStore, keys: state.fileDownloadKeys(file)) { snapshot in
                    AttachmentDownloadProgressView(snapshot: snapshot) { state.cancelFileDownload(file) }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                }
            }, onClose: { dismiss() }, onOpen: openSystemPreview, onShare: prepareShareForFile)
        .sheet(item: $previewDocument) { document in
            DismissibleQuickLookPreview(url: document.url)
        }
        .sheet(item: $shareItem) { item in
            FileActivityView(activityItems: [item.url])
                .presentationDetentsCompat([.medium, .large])
        }
    }

    private func openSystemPreview() {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        previewState = .loading
        let cacheScope = state.contentCacheScopeKey
        let cacheContext = state.mediaCacheScopeContext
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else {
                await MainActor.run {
                    isPreparingPreview = false
                    previewState = .idle
                }
                return
            }
            if let cacheContext,
               let localURL = await FilesPreviewCacheAdapter.cachedPreviewURL(for: file, state: state, context: cacheContext) {
                await MainActor.run {
                    guard state.contentCacheScopeKey == cacheScope else {
                        isPreparingPreview = false
                        return
                    }
                    isPreparingPreview = false
                    previewState = .cached
                    previewDocument = LocalPreviewDocument(url: localURL)
                }
                return
            }
            await MainActor.run {
                guard state.contentCacheScopeKey == cacheScope else {
                    isPreparingPreview = false
                    return
                }
                openSystemPreviewWithoutPipelineCache(cacheScope: cacheScope, cacheContext: cacheContext)
            }
        }
    }

    private func openSystemPreviewWithoutPipelineCache(
        cacheScope: String,
        cacheContext: IOSMediaCacheScopeContext?
    ) {
        isPreparingPreview = true
        previewState = .loading
        Task {
            do {
                let refreshedFile = try await state.refreshTenantFile(file)
                if let cacheContext,
                   let migrated = await FilesPreviewCacheAdapter.migrateAuthorizedLegacyPreview(
                    for: refreshedFile,
                    state: state,
                    context: cacheContext
                   ) {
                    await MainActor.run {
                        guard state.contentCacheScopeKey == cacheScope else {
                            isPreparingPreview = false
                            return
                        }
                        isPreparingPreview = false
                        previewState = .cached
                        previewDocument = LocalPreviewDocument(url: migrated)
                    }
                    return
                }
                guard refreshedFile.systemPreviewRemoteURL != nil else {
                    await MainActor.run {
                        guard state.contentCacheScopeKey == cacheScope else {
                            isPreparingPreview = false
                            return
                        }
                        isPreparingPreview = false
                        previewState = .idle
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("当前文件暂不支持预览，可下载保存")
                    }
                    return
                }
                let localURL = try await state.prepareTenantFileLocalFile(refreshedFile, preview: true)
                await MainActor.run {
                    guard state.contentCacheScopeKey == cacheScope else {
                        isPreparingPreview = false
                        return
                    }
                    isPreparingPreview = false
                    previewState = .cached
                    previewDocument = LocalPreviewDocument(url: localURL)
                }
            } catch {
                await MainActor.run {
                    guard state.contentCacheScopeKey == cacheScope else {
                        isPreparingPreview = false
                        return
                    }
                    isPreparingPreview = false
                    previewState = .failed
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("系统预览准备失败，请重试或下载保存")
                }
            }
        }
    }

    private func prepareShareForFile() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("正在准备下载文件")
        let cacheScope = state.contentCacheScopeKey
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else {
                await MainActor.run {
                    isPreparingShare = false
                }
                return
            }
            do {
                let localURL = try await TenantFileSharePreparer.prepare(file: file, state: state, scope: cacheScope)
                await MainActor.run {
                    guard state.contentCacheScopeKey == cacheScope else {
                        isPreparingShare = false
                        return
                    }
                    isPreparingShare = false
                    shareItem = FileShareItem(url: localURL)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("文件已准备好，可保存或分享")
                }
            } catch {
                await MainActor.run {
                    isPreparingShare = false
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("文件下载失败，请稍后重试")
                }
            }
        }
    }
}

struct FileThumbnail: View {
    @EnvironmentObject private var state: AppState
    let file: FileItem
    let presentation: FilePresentation
    let size: CGFloat

    var body: some View {
        FileThumbnailContent(size: size, accentHex: file.accentHex, kind: presentation.visualKind,
            thumbnailURL: presentation.thumbnailURL, videoFrameURL: presentation.videoFrameURL,
            image: { thumbnailURL, fileTypeLogo in
            // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
            state.fileStore.observeMediaNetworkRecovery { generation in
                AttachmentThumbnailImage(
                    url: thumbnailURL,
                    cacheKey: "\(state.mediaCacheScopeContext?.scopeHash ?? "invalid-scope")|\(presentation.thumbnailCacheKey)",
                    contentMode: .fill,
                    scopeGeneration: state.mediaCacheScopeContext?.sessionGeneration ?? 0,
                    networkRecoveryGeneration: generation,
                    recoveryURL: refreshedThumbnailURL,
                    indexedCacheURL: {
                        await FilesPreviewCacheAdapter.cachedThumbnailURL(
                            for: file,
                            state: state,
                            context: state.mediaCacheScopeContext
                        )
                    },
                    indexedCacheCommit: { data in
                        await FilesPreviewCacheAdapter.cacheDownloadedThumbnail(
                            data,
                            for: file,
                            state: state,
                            context: state.mediaCacheScopeContext
                        )
                    }
                ) {
                    fileTypeLogo
                } failure: {
                    fileTypeLogo
                }
            }
            // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END
            }, video: { videoFrameURL, fileTypeLogo in
            // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
            state.fileStore.observeMediaNetworkRecovery { generation in
                FileVideoFrameThumbnail(
                    url: videoFrameURL,
                    cacheKey: presentation.thumbnailCacheKey,
                    contentMode: .fill,
                    networkRecoveryGeneration: generation,
                    recoveryURL: refreshedVideoFrameURL,
                    indexedCacheURL: {
                        await FilesPreviewCacheAdapter.cachedThumbnailURL(
                            for: file,
                            state: state,
                            context: state.mediaCacheScopeContext
                        )
                    },
                    indexedCacheCommit: { data in
                        await FilesPreviewCacheAdapter.cacheDownloadedThumbnail(
                            data,
                            for: file,
                            state: state,
                            context: state.mediaCacheScopeContext
                        )
                    }
                ) {
                    fileTypeLogo
                }
            }
            // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END
            })
    }

    @MainActor
    private func refreshedThumbnailURL() async -> URL? {
        guard let refreshed = try? await state.refreshTenantFile(file) else { return nil }
        return FilePresentation(file: refreshed).thumbnailURL
    }

    @MainActor
    private func refreshedVideoFrameURL() async -> URL? {
        guard let refreshed = try? await state.refreshTenantFile(file) else { return nil }
        return FilePresentation(file: refreshed).videoFrameURL
    }
}

private struct FileVideoFrameThumbnail<Placeholder: View>: View {
    let url: URL
    let cacheKey: String
    var contentMode: ContentMode = .fill
    var networkRecoveryGeneration: Int = 0
    var recoveryURL: (() async -> URL?)? = nil
    var indexedCacheURL: (() async -> URL?)? = nil
    var indexedCacheCommit: ((Data) async -> URL?)? = nil
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retryNonce = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: "\(url.absoluteString)|\(cacheKey)|\(retryNonce)") {
            if let indexedCacheURL,
               let cachedURL = await indexedCacheURL(),
               let data = try? Data(contentsOf: cachedURL),
               let cachedImage = RemoteImageDecoder.preparedImage(from: data, maxPixelSize: 480) {
                image = cachedImage
                failed = false
                return
            }
            let loaded = await FileVideoFrameThumbnailCache.shared.image(for: url, cacheKey: cacheKey)
            if let loaded {
                if let data = loaded.jpegData(compressionQuality: 0.86), let indexedCacheCommit {
                    _ = await indexedCacheCommit(data)
                }
                image = loaded
                failed = false
            } else if let recoveryURL,
                      let refreshedURL = await recoveryURL(),
                      let recovered = await FileVideoFrameThumbnailCache.shared.image(
                          for: refreshedURL,
                          cacheKey: cacheKey
                      ) {
                if let data = recovered.jpegData(compressionQuality: 0.86), let indexedCacheCommit {
                    _ = await indexedCacheCommit(data)
                }
                image = recovered
                failed = false
            } else {
                failed = true
            }
        }
        .onChangeCompat(of: networkRecoveryGeneration) { previous, current in
            guard current != previous, failed, image == nil else { return }
            let stableKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                guard await MediaVisibleRecoveryGate.shared.shouldRetry(
                    key: stableKey.isEmpty ? "video-frame|\(url.path)" : stableKey
                ) else {
                    return
                }
                await MainActor.run {
                    guard failed, image == nil else { return }
                    failed = false
                    retryNonce &+= 1
                }
            }
        }
    }
}

@MainActor
private final class FileVideoFrameThumbnailCache {
    static let shared = FileVideoFrameThumbnailCache()
    private var loadingTasks: [String: Task<UIImage?, Never>] = [:]

    func image(for url: URL, cacheKey: String) async -> UIImage? {
        let key = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "file-video-frame|\(url.absoluteString)"
            : cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = AvatarImageCache.shared.image(for: key) {
            return cached
        }
        if let task = loadingTasks[key] {
            return await task.value
        }
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            do {
                let cgImage = try generator.copyCGImage(
                    at: CMTime(seconds: 0.12, preferredTimescale: 600),
                    actualTime: nil
                )
                let image = UIImage(cgImage: cgImage)
                return image.preparingForDisplay() ?? image
            } catch {
                return nil
            }
        }
        loadingTasks[key] = task
        let image = await task.value
        loadingTasks[key] = nil
        if let image {
            AvatarImageCache.shared.store(image, for: key)
        }
        return image
    }
}

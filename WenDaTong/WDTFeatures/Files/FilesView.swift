import Combine
import SwiftUI
import IM4Features
import UIKit
import QuickLook
import AVFoundation

struct FilesView: View {
    @EnvironmentObject private var state: AppState
    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110
    @State private var observedFavorites: FileStore.FavoriteAssetsSnapshot?
    @State private var query = ""
    @State private var type = "全部"
    @State private var selectedFile: FileItem?
    @State private var previewDocument: LocalPreviewDocument?
    @State private var shareItem: FileShareItem?
    @State private var loadingPreview = false
    @State private var downloadingFileID: String?
    @State private var lastRefreshCompletedAt: Date?
    @State private var cachedFileRows: [FavoriteAssetRenderItem] = []
    @State private var hasFilteredFileCache = false
    @State private var previewStatesByFileID: [String: FilePreviewOpenState] = [:]
    @State private var visibleFileLimit = 15
    @State private var canLoadRemotePages = false
    @State private var hasMoreRemoteFiles = false
    @State private var isLoadingMoreFiles = false
    @State private var nextFavoriteAssetsCursor = ""
    @State private var failedFavoriteAssetsCursor: String?
    @State private var failedFavoriteAssetsWasAppend = false
    @State private var pendingUnfavoriteAsset: FavoriteAssetItem?
    @State private var isCancellingFavoriteAsset = false
    @State private var mediaPreviewRefreshInFlight: Set<String> = []
    @State private var mediaPreviewRefreshFailed: Set<String> = []
    @State private var observedMediaNetworkRecoveryGeneration: Int? // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110
    @State private var lastMediaNetworkRecoveryAt: Date?
    @State private var filteredFilesRebuildTask: Task<Void, Never>?
    @State private var firstFilePageRefreshTask: Task<Void, Never>?
    @State private var firstFilePageRefreshGeneration = 0
    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：资料 Tab 自动第一页刷新节流，避免频繁切换重复拉取
    @State private var lastAutomaticFirstFilePageRefreshAt: Date?
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
    @State private var loadMoreFilesTask: Task<Void, Never>?

    private let types = FavoriteAssetCategory.displayOrder.map(\.title)
    private let filePageSize = 15
    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：资料 Tab 自动刷新最小间隔
    private let automaticFirstFilePageRefreshInterval: TimeInterval = 45
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    private var selectedCategory: FavoriteAssetCategory {
        FavoriteAssetCategory(displayTitle: type)
    }

    private var filteredFileRows: [FavoriteAssetRenderItem] {
        hasFilteredFileCache ? cachedFileRows : renderFilteredFiles()
    }

    private var displayedFiles: [FavoriteAssetRenderItem] {
        Array(filteredFileRows.prefix(visibleFileLimit))
    }

    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
    private var favorites: FileStore.FavoriteAssetsSnapshot {
        observedFavorites ?? state.fileStore.favoriteAssetsSnapshot
    }
    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.bootstrapPresentationStore.observeSync(\.isInitialLoading) { isInitialLoading in
            filesContent(isInitialLoading: isInitialLoading)
        }
    }
    // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_END

    @ViewBuilder
    private func filesContent(isInitialLoading: Bool) -> some View { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        let allFiles = filteredFileRows
        let files = displayedFiles
        FilesListContent(query: $query, type: $type, types: types, isRefreshing: favorites.isSyncing && !isLoadingMoreFiles,
            errorMessage: favorites.errorMessage, hasCachedFiles: !favorites.items.isEmpty, lastRefreshedAt: lastRefreshCompletedAt,
            isInitialLoading: isInitialLoading, isEmpty: files.isEmpty, emptySymbol: emptyStateSymbol,
            emptyTitle: emptyStateTitle, emptySubtitle: emptyStateSubtitle, retry: retryFavoriteAssetsPage,
            retrySync: { startFirstFilePageRefresh(showToast: true) }, refresh: {
                cancelFirstFilePageRefresh()
                await refreshFirstFilePage(showToast: true)
            }) {
        LazyVStack(spacing: 10) {
                                    ForEach(files) { item in
                                        FavoriteAssetRow(
                                            // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
                                            downloadProgress: FileDownloadProgress(
                                                store: state.fileStore, keys: state.fileDownloadKeys(item.file)
                                            ) { snapshot in
                                                AttachmentDownloadProgressView(snapshot: snapshot) { state.cancelFileDownload(item.file) }
                                            },
                                            // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END
                                            item: item,
                                            isPreparingDownload: downloadingFileID == item.file.id,
                                            onOpen: {
                                                openFavoriteAssetItem(item)
                                            },
                                            onDownload: {
                                                prepareFileForSharing(item.file)
                                            },
                                            onShare: {
                                                prepareFileForSharing(item.file)
                                            },
                                            onUnfavorite: {
                                                isCancellingFavoriteAsset = false
                                                pendingUnfavoriteAsset = item.asset
                                            }
                                        )
                                        .task(id: item.presentation.previewRefreshTaskID) {
                                            await refreshMediaPreviewIfNeeded(item)
                                        }
                                    }
                                    if shouldShowLoadMoreFooter(totalFilteredCount: allFiles.count) {
                                        FileLoadMoreFooter(
                                            isLoading: isLoadingMoreFiles,
                                            hasLocalMore: visibleFileLimit < allFiles.count,
                                            canLoadRemoteMore: canLoadRemotePages && hasMoreRemoteFiles,
                                            failed: failedFavoriteAssetsWasAppend,
                                            retry: failedFavoriteAssetsWasAppend ? {
                                                loadMoreFilesIfNeeded(forceRetry: true)
                                            } : nil
                                        )
                                        .onAppear {
                                            if failedFavoriteAssetsCursor == nil {
                                                loadMoreFilesIfNeeded()
                                            }
                                        }
                                    }
                                }
        }
        .overlay {
            unfavoriteConfirmationOverlay
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedFile) { file in
            FilePreviewView(file: file)
                .presentationDetentsCompat([.large])
        }
        .sheet(item: $previewDocument) { document in
            DismissibleQuickLookPreview(url: document.url)
        }
        .sheet(item: $shareItem) { item in
            FileActivityView(activityItems: [item.url])
                .presentationDetentsCompat([.medium, .large])
        }
        .onAppear {
            rebuildFilteredFiles()
            resetFilePagingForCachedContent()
            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：切回资料页时短时间内复用缓存，减少主线程刷新压力和网络任务
            startFirstFilePageRefreshIfNeeded()
            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        }
        .onDisappear {
            cancelFileListTasks()
        }
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
        .onReceive(state.fileStore.$favoriteAssetsSnapshot.removeDuplicates()) { snapshot in
            if observedFavorites != snapshot { observedFavorites = snapshot }
        }
        .onChangeCompat(of: favorites.items) { _, _ in
            scheduleFilteredFilesRebuild()
        }
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END
        .onChangeCompat(of: query) { _, _ in
            cancelFilteredFilesRebuild()
            resetFilePagingForCachedContent()
            rebuildFilteredFiles()
        }
        .onChangeCompat(of: type) { _, _ in
            cancelFilteredFilesRebuild()
            resetFilePagingForCachedContent()
            rebuildFilteredFiles()
            startFirstFilePageRefresh(showToast: false)
        }
        // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
        .onReceive(state.fileStore.$mediaNetworkRecoveryGeneration) { current in
            let previous = observedMediaNetworkRecoveryGeneration
            guard previous != current else { return }
            observedMediaNetworkRecoveryGeneration = current
            guard previous != nil else { return }
            let now = Date()
            if let lastMediaNetworkRecoveryAt,
               now.timeIntervalSince(lastMediaNetworkRecoveryAt) < 15 {
                return
            }
            lastMediaNetworkRecoveryAt = now
            mediaPreviewRefreshFailed.removeAll()
            guard !state.isFavoriteAssetsSyncing else { return }
            startFirstFilePageRefresh(showToast: false)
        }
        // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END
    }

    private var emptyStateSymbol: String {
        favorites.items.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory == .all
            ? "bookmark.slash"
            : "line.3.horizontal.decrease.circle"
    }

    private var emptyStateTitle: String {
        if favorites.items.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory == .all {
            return "暂无收藏资料"
        }
        return "没有匹配的资料"
    }

    private var emptyStateSubtitle: String {
        if favorites.items.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory == .all {
            return "在会话中长按图片、视频或文件，点击收藏后会显示在这里。"
        }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "当前分类暂无收藏资料，可以切换分类查看。"
        }
        return "换个关键词，或切换分类后再试。"
    }

    @ViewBuilder
    private var unfavoriteConfirmationOverlay: some View {
        if let item = pendingUnfavoriteAsset {
            FavoriteAssetConfirmationContent(isCancelling: isCancellingFavoriteAsset, isPresented: pendingUnfavoriteAsset != nil,
                onKeep: {
                    guard !isCancellingFavoriteAsset else { return }
                    pendingUnfavoriteAsset = nil
                }, onUnfavorite: {
                    guard !isCancellingFavoriteAsset else { return }
                    isCancellingFavoriteAsset = true
                    Task {
                        await cancelFavoriteAsset(item)
                        await MainActor.run {
                            isCancellingFavoriteAsset = false
                            pendingUnfavoriteAsset = nil
                        }
                    }
                })
        }
    }

    private func renderFilteredFiles() -> [FavoriteAssetRenderItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.favoriteAssets.compactMap { asset in
            let file = asset.file
            let presentation = FilePresentation(file: file)
            let matchesQuery = trimmedQuery.isEmpty
                || file.name.localizedCaseInsensitiveContains(trimmedQuery)
                || file.owner.localizedCaseInsensitiveContains(trimmedQuery)
                || file.source.localizedCaseInsensitiveContains(trimmedQuery)
            let matchesType = selectedCategory.matches(file: file)
            guard matchesQuery && matchesType else { return nil }
            return FavoriteAssetRenderItem(asset: asset, presentation: presentation)
        }
    }

    @MainActor
    private func rebuildFilteredFiles() {
        cachedFileRows = renderFilteredFiles()
        hasFilteredFileCache = true
    }

    @MainActor
    private func scheduleFilteredFilesRebuild() {
        filteredFilesRebuildTask?.cancel()
        filteredFilesRebuildTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            rebuildFilteredFiles()
            filteredFilesRebuildTask = nil
        }
    }

    @MainActor
    private func cancelFilteredFilesRebuild() {
        filteredFilesRebuildTask?.cancel()
        filteredFilesRebuildTask = nil
    }

    @MainActor
    private func resetFilePagingForCachedContent() {
        loadMoreFilesTask?.cancel()
        loadMoreFilesTask = nil
        visibleFileLimit = filePageSize
        canLoadRemotePages = false
        hasMoreRemoteFiles = false
        isLoadingMoreFiles = false
        nextFavoriteAssetsCursor = ""
        failedFavoriteAssetsCursor = nil
        failedFavoriteAssetsWasAppend = false
    }

    private func shouldShowLoadMoreFooter(totalFilteredCount: Int) -> Bool {
        if failedFavoriteAssetsWasAppend { return true }
        if visibleFileLimit < totalFilteredCount {
            return true
        }
        return canLoadRemotePages && hasMoreRemoteFiles
    }

    @MainActor
    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：只节流 Tab 自动进入刷新，不影响手动刷新/分类刷新/网络恢复刷新
    private func startFirstFilePageRefreshIfNeeded() {
        guard !state.isFavoriteAssetsSyncing,
              firstFilePageRefreshTask == nil else {
            return
        }
        let now = Date()
        if let lastAutomaticFirstFilePageRefreshAt,
           now.timeIntervalSince(lastAutomaticFirstFilePageRefreshAt) < automaticFirstFilePageRefreshInterval {
            return
        }
        lastAutomaticFirstFilePageRefreshAt = now
        startFirstFilePageRefresh(showToast: false)
    }
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    @MainActor
    private func startFirstFilePageRefresh(showToast: Bool) {
        firstFilePageRefreshTask?.cancel()
        firstFilePageRefreshGeneration += 1
        let generation = firstFilePageRefreshGeneration
        firstFilePageRefreshTask = Task { @MainActor in
            await refreshFirstFilePage(showToast: showToast)
            guard firstFilePageRefreshGeneration == generation else { return }
            firstFilePageRefreshTask = nil
        }
    }

    @MainActor
    private func cancelFirstFilePageRefresh() {
        firstFilePageRefreshGeneration += 1
        firstFilePageRefreshTask?.cancel()
        firstFilePageRefreshTask = nil
    }

    @MainActor
    private func cancelFileListTasks() {
        cancelFilteredFilesRebuild()
        cancelFirstFilePageRefresh()
        loadMoreFilesTask?.cancel()
        loadMoreFilesTask = nil
        isLoadingMoreFiles = false
    }

    @MainActor
    private func refreshFirstFilePage(showToast: Bool) async {
        loadMoreFilesTask?.cancel()
        loadMoreFilesTask = nil
        visibleFileLimit = filePageSize
        canLoadRemotePages = true
        hasMoreRemoteFiles = true
        isLoadingMoreFiles = false
        nextFavoriteAssetsCursor = ""
        failedFavoriteAssetsCursor = nil
        failedFavoriteAssetsWasAppend = false
        mediaPreviewRefreshFailed.removeAll()
        let result = await state.refreshFavoriteAssetsPage(
            silent: !showToast,
            category: selectedCategory,
            limit: filePageSize,
            cursor: "",
            append: false
        )
        guard !Task.isCancelled else { return }
        cancelFilteredFilesRebuild()
        rebuildFilteredFiles()
        visibleFileLimit = filePageSize
        if result.didSucceed {
            hasMoreRemoteFiles = result.hasMore
            nextFavoriteAssetsCursor = result.nextCursor
            failedFavoriteAssetsCursor = nil
            failedFavoriteAssetsWasAppend = false
            lastRefreshCompletedAt = Date()
            if showToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(filteredFileRows.isEmpty ? "资料列表已刷新，暂无收藏" : "资料列表已刷新")
            }
        } else {
            hasMoreRemoteFiles = true
            failedFavoriteAssetsCursor = ""
            failedFavoriteAssetsWasAppend = false
        }
    }

    @MainActor
    private func loadMoreFilesIfNeeded(forceRetry: Bool = false) {
        let currentFilteredCount = filteredFileRows.count
        if !forceRetry, visibleFileLimit < currentFilteredCount {
            visibleFileLimit = min(visibleFileLimit + filePageSize, currentFilteredCount)
            return
        }
        if !forceRetry, failedFavoriteAssetsCursor != nil {
            return
        }
        guard canLoadRemotePages,
              hasMoreRemoteFiles,
              !isLoadingMoreFiles,
              !state.isFavoriteAssetsSyncing else {
            return
        }
        isLoadingMoreFiles = true
        let cursor = forceRetry
            ? (failedFavoriteAssetsCursor ?? nextFavoriteAssetsCursor)
            : nextFavoriteAssetsCursor
        loadMoreFilesTask?.cancel()
        loadMoreFilesTask = Task { @MainActor in
            let result = await state.refreshFavoriteAssetsPage(
                silent: true,
                category: selectedCategory,
                limit: filePageSize,
                cursor: cursor,
                append: true
            )
            guard !Task.isCancelled else { return }
            isLoadingMoreFiles = false
            cancelFilteredFilesRebuild()
            rebuildFilteredFiles()
            visibleFileLimit = min(visibleFileLimit + filePageSize, max(filteredFileRows.count, filePageSize))
            if result.didSucceed {
                hasMoreRemoteFiles = result.hasMore
                nextFavoriteAssetsCursor = result.nextCursor
                failedFavoriteAssetsCursor = nil
                failedFavoriteAssetsWasAppend = false
                if result.fetchedCount == 0 {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("没有更多资料了")
                }
            } else {
                hasMoreRemoteFiles = true
                failedFavoriteAssetsCursor = cursor
                failedFavoriteAssetsWasAppend = true
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("加载更多资料失败，请稍后重试")
            }
            loadMoreFilesTask = nil
        }
    }

    @MainActor
    private func retryFavoriteAssetsPage() {
        if failedFavoriteAssetsWasAppend {
            loadMoreFilesIfNeeded(forceRetry: true)
        } else {
            startFirstFilePageRefresh(showToast: true)
        }
    }

    @MainActor
    private func refreshMediaPreviewIfNeeded(_ item: FavoriteAssetRenderItem) async {
        guard !item.asset.isUnavailable else { return }
        guard item.presentation.needsRemotePreviewRefresh else { return }
        let lookupID = item.file.remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lookupID.isEmpty,
              !mediaPreviewRefreshInFlight.contains(lookupID),
              !mediaPreviewRefreshFailed.contains(lookupID) else {
            return
        }
        mediaPreviewRefreshInFlight.insert(lookupID)
        defer { mediaPreviewRefreshInFlight.remove(lookupID) }
        do {
            let refreshedFile = try await state.refreshTenantFile(item.file)
            let refreshedPresentation = FilePresentation(file: refreshedFile)
            if refreshedPresentation.needsRemotePreviewRefresh {
                mediaPreviewRefreshFailed.insert(lookupID)
            }
        } catch {
            mediaPreviewRefreshFailed.insert(lookupID)
        }
    }

    private func openFavoriteAssetItem(_ item: FavoriteAssetRenderItem) {
        guard !item.asset.isUnavailable else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("内容已失效/不可预览，可取消收藏")
            return
        }
        openFileListItem(item.file)
    }

    @MainActor
    private func cancelFavoriteAsset(_ item: FavoriteAssetItem) async {
        let success = await state.cancelFavoriteAsset(item)
        guard success else { return }
        cancelFilteredFilesRebuild()
        rebuildFilteredFiles()
    }

    private func openFileListItem(_ file: FileItem) {
        guard !loadingPreview else { return }
        loadingPreview = true
        setPreviewState(.loading, for: file)
        let cacheScope = state.contentCacheScopeKey
        let cacheContext = state.mediaCacheScopeContext
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else {
                await MainActor.run {
                    loadingPreview = false
                    setPreviewState(.idle, for: file)
                }
                return
            }
            if let cacheContext,
               let localURL = await FilesPreviewCacheAdapter.cachedPreviewURL(for: file, state: state, context: cacheContext) {
                await MainActor.run {
                    guard state.contentCacheScopeKey == cacheScope else {
                        loadingPreview = false
                        return
                    }
                    loadingPreview = false
                    setPreviewState(.cached, for: file)
                    previewDocument = LocalPreviewDocument(url: localURL)
                }
                return
            }
            await MainActor.run {
                guard state.contentCacheScopeKey == cacheScope else {
                    loadingPreview = false
                    return
                }
                openFileListItemWithoutPipelineCache(file, cacheScope: cacheScope, cacheContext: cacheContext)
            }
        }
    }

    private func openFileListItemWithoutPipelineCache(
        _ file: FileItem,
        cacheScope: String,
        cacheContext: IOSMediaCacheScopeContext?
    ) {
        if file.visualKind.canUseSystemPreview {
            loadingPreview = true
            setPreviewState(.loading, for: file)
            Task {
                var fallbackFile = file
                do {
                    let refreshedFile = try await state.refreshTenantFile(file)
                    fallbackFile = refreshedFile
                    if let cacheContext,
                       let migrated = await FilesPreviewCacheAdapter.migrateAuthorizedLegacyPreview(
                        for: refreshedFile,
                        state: state,
                        context: cacheContext
                       ) {
                        await MainActor.run {
                            guard state.contentCacheScopeKey == cacheScope else {
                                loadingPreview = false
                                return
                            }
                            loadingPreview = false
                            setPreviewState(.cached, for: refreshedFile)
                            previewDocument = LocalPreviewDocument(url: migrated)
                        }
                        return
                    }
                    guard refreshedFile.systemPreviewRemoteURL != nil else {
                        await MainActor.run {
                            guard state.contentCacheScopeKey == cacheScope else {
                                loadingPreview = false
                                return
                            }
                            loadingPreview = false
                            setPreviewState(.idle, for: file)
                            selectedFile = refreshedFile
                        }
                        return
                    }
                    let localURL = try await state.prepareTenantFileLocalFile(refreshedFile, preview: true)
                    await MainActor.run {
                        guard state.contentCacheScopeKey == cacheScope else {
                            loadingPreview = false
                            return
                        }
                        loadingPreview = false
                        setPreviewState(.cached, for: refreshedFile)
                        previewDocument = LocalPreviewDocument(url: localURL)
                    }
                } catch {
                    await MainActor.run {
                        guard state.contentCacheScopeKey == cacheScope else {
                            loadingPreview = false
                            return
                        }
                        loadingPreview = false
                        setPreviewState(.failed, for: file)
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("系统预览准备失败，可打开详情后重试")
                        selectedFile = fallbackFile
                    }
                }
            }
        } else if file.downloadAvailable || file.previewAvailable {
            loadingPreview = false
            setPreviewState(.idle, for: file)
            selectedFile = file
        } else {
            loadingPreview = false
            setPreviewState(.idle, for: file)
            selectedFile = file
        }
    }

    private func prepareFileForSharing(_ file: FileItem) {
        guard downloadingFileID == nil else { return }
        downloadingFileID = file.id
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("正在准备下载文件")
        let cacheScope = state.contentCacheScopeKey
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else {
                await MainActor.run {
                    downloadingFileID = nil
                }
                return
            }
            do {
                let localURL = try await TenantFileSharePreparer.prepare(file: file, state: state, scope: cacheScope)
                await MainActor.run {
                    guard state.contentCacheScopeKey == cacheScope else {
                        downloadingFileID = nil
                        return
                    }
                    downloadingFileID = nil
                    shareItem = FileShareItem(url: localURL)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("文件已准备好，可保存或分享")
                }
            } catch {
                await MainActor.run {
                    downloadingFileID = nil
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("文件下载失败，请稍后重试")
                }
            }
        }
    }

    private func setPreviewState(_ previewState: FilePreviewOpenState, for file: FileItem) {
        if previewState == .idle {
            previewStatesByFileID.removeValue(forKey: file.id)
        } else {
            previewStatesByFileID[file.id] = previewState
        }
    }

}

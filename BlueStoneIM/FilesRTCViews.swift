import SwiftUI
import UIKit
import QuickLook
import AVFoundation

struct FilesView: View {
    @EnvironmentObject private var state: AppState
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

    var body: some View {
        let allFiles = filteredFileRows
        let files = displayedFiles
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            typeBar

                            FileRefreshHintView(
                                isRefreshing: state.isFavoriteAssetsSyncing && !isLoadingMoreFiles,
                                errorMessage: state.favoriteAssetsSyncErrorMessage,
                                hasCachedFiles: !state.favoriteAssets.isEmpty,
                                lastRefreshedAt: lastRefreshCompletedAt,
                                retry: retryFavoriteAssetsPage
                            )

                            if state.isInitialDataLoading && !state.hasLoadedRemoteSnapshot && state.favoriteAssets.isEmpty && query.isEmpty {
                                RemoteLoadingStateView(
                                    title: "正在加载收藏资料",
                                    subtitle: "正在拉取你收藏的图片、视频和文件。"
                                )
                            } else if let fileSyncError = state.favoriteAssetsSyncErrorMessage, state.favoriteAssets.isEmpty {
                                EmptyStateView(symbol: "wifi.exclamationmark", title: "资料加载失败", subtitle: fileSyncError)
                                PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                                    startFirstFilePageRefresh(showToast: true)
                                }
                            } else if files.isEmpty {
                                EmptyStateView(
                                    symbol: emptyStateSymbol,
                                    title: emptyStateTitle,
                                    subtitle: emptyStateSubtitle
                                )
                            } else {
                                LazyVStack(spacing: 10) {
                                    ForEach(files) { item in
                                        FavoriteAssetRow(
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
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                    } header: {
                        PinnedSearchHeader {
                            SearchField(text: $query, placeholder: "搜索文件、来源、发送人") {
                                startFirstFilePageRefresh(showToast: true)
                            }
                        }
                    }
                }
            }
            .refreshable {
                cancelFirstFilePageRefresh()
                await refreshFirstFilePage(showToast: true)
            }
        }
        .overlay(alignment: .top) {
            PinnedSearchTopMask()
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
        .onChangeCompat(of: state.favoriteAssets) { _, _ in
            scheduleFilteredFilesRebuild()
        }
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
        .onChangeCompat(of: state.mediaNetworkRecoveryGeneration) { previous, current in
            guard current != previous else { return }
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
    }

    private var emptyStateSymbol: String {
        state.favoriteAssets.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory == .all
            ? "bookmark.slash"
            : "line.3.horizontal.decrease.circle"
    }

    private var emptyStateTitle: String {
        if state.favoriteAssets.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory == .all {
            return "暂无收藏资料"
        }
        return "没有匹配的资料"
    }

    private var emptyStateSubtitle: String {
        if state.favoriteAssets.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory == .all {
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
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        guard !isCancellingFavoriteAsset else { return }
                        pendingUnfavoriteAsset = nil
                    }

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("取消收藏这项资料？")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("确认后它会从资料列表移除，不会删除原消息。")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        Button {
                            guard !isCancellingFavoriteAsset else { return }
                            pendingUnfavoriteAsset = nil
                        } label: {
                            Text("保留")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(IMColor.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.9))
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            guard !isCancellingFavoriteAsset else { return }
                            isCancellingFavoriteAsset = true
                            Task {
                                await cancelFavoriteAsset(item)
                                await MainActor.run {
                                    isCancellingFavoriteAsset = false
                                    pendingUnfavoriteAsset = nil
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isCancellingFavoriteAsset {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                                Text("取消收藏")
                                    .font(.system(size: 15, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(IMColor.danger)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: Color.black.opacity(0.18), radius: 24, y: 12)
                )
                .padding(.horizontal, 24)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: pendingUnfavoriteAsset != nil)
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
                state.toast = filteredFileRows.isEmpty ? "资料列表已刷新，暂无收藏" : "资料列表已刷新"
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
                    state.toast = "没有更多资料了"
                }
            } else {
                hasMoreRemoteFiles = true
                failedFavoriteAssetsCursor = cursor
                failedFavoriteAssetsWasAppend = true
                state.toast = "加载更多资料失败，请稍后重试"
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
            state.toast = "内容已失效/不可预览，可取消收藏"
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
                    guard let remoteURL = refreshedFile.systemPreviewRemoteURL else {
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
                    let downloadedURL = try await MediaSignedURLRecovery.perform(
                        initialURL: remoteURL,
                        refreshURL: {
                            let refreshedAgain = try await state.refreshTenantFile(refreshedFile)
                            guard let refreshedURL = refreshedAgain.systemPreviewRemoteURL else {
                                throw IMAPIError.server("当前文件暂不支持预览")
                            }
                            return refreshedURL
                        },
                        operation: { candidateURL in
                            try await SystemPreviewLoader.download(
                                candidateURL,
                                suggestedName: refreshedFile.name,
                                cacheIdentity: refreshedFile.systemPreviewCacheIdentity(scope: cacheScope)
                            )
                        }
                    )
                    let localURL = if let cacheContext {
                        await FilesPreviewCacheAdapter.cacheDownloadedPreview(downloadedURL, for: refreshedFile, state: state, context: cacheContext)
                    } else {
                        downloadedURL
                    }
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
                        state.toast = "系统预览准备失败，可打开详情后重试"
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
        state.toast = "正在准备下载文件"
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
                    state.toast = "文件已准备好，可保存或分享"
                }
            } catch {
                await MainActor.run {
                    downloadingFileID = nil
                    state.toast = "文件下载失败，请稍后重试"
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

    private var typeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(types, id: \.self) { item in
                    Button {
                        type = item
                    } label: {
                        Chip(title: item, isSelected: type == item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct FileRefreshHintView: View {
    let isRefreshing: Bool
    let errorMessage: String?
    let hasCachedFiles: Bool
    let lastRefreshedAt: Date?
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(IMColor.brand)
            } else {
                Image(systemName: errorMessage == nil ? "arrow.down.circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(errorMessage == nil ? IMColor.brand : IMColor.danger)
            }
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(errorMessage == nil ? IMColor.muted : IMColor.danger)
                .lineLimit(2)
            Spacer(minLength: 0)
            if errorMessage?.isEmpty == false, !isRefreshing {
                Button("重试", action: retry)
                    .font(.system(size: 12, weight: .bold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("favorite_assets_retry_button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke((errorMessage == nil ? IMColor.line : IMColor.danger.opacity(0.18)), lineWidth: 1)
                )
        )
    }

    private var statusText: String {
        if isRefreshing {
            return "正在刷新资料列表..."
        }
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if let lastRefreshedAt {
            return "资料列表已刷新 \(Self.timeFormatter.string(from: lastRefreshedAt))"
        }
        return hasCachedFiles ? "下拉刷新资料列表，当前显示上次缓存内容" : "下拉刷新资料列表"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct FileLoadMoreFooter: View {
    let isLoading: Bool
    let hasLocalMore: Bool
    let canLoadRemoteMore: Bool
    let failed: Bool
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(IMColor.brand)
            } else {
                Image(systemName: hasLocalMore || canLoadRemoteMore ? "arrow.down" : "checkmark.circle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(failed ? IMColor.danger : IMColor.muted)
            if let retry, failed, !isLoading {
                Button("重试加载", action: retry)
                    .font(.system(size: 12, weight: .bold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("favorite_assets_page_retry_button")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var title: String {
        if isLoading { return "正在加载更多资料..." }
        if failed { return "加载更多资料失败，已保留当前资料" }
        if hasLocalMore { return "继续下滑显示更多资料" }
        if canLoadRemoteMore { return "继续下滑加载更多资料" }
        return "没有更多资料"
    }
}

private struct FavoriteAssetRenderItem: Identifiable {
    let asset: FavoriteAssetItem
    let presentation: FilePresentation

    var id: String { asset.id }
    var file: FileItem { asset.file }
}

private struct FileRenderItem: Identifiable {
    let file: FileItem
    let presentation: FilePresentation

    var id: String { file.id }
}

private enum FilePreviewOpenState: Equatable {
    case idle
    case cached
    case loading
    case failed

    var isLoading: Bool {
        self == .loading
    }

    var previewActionTitle: String? {
        switch self {
        case .idle:
            return nil
        case .cached:
            return "已缓存"
        case .loading:
            return "准备中"
        case .failed:
            return "重试"
        }
    }

    func pillTitle(defaultTitle: String) -> String {
        switch self {
        case .idle:
            return defaultTitle
        case .cached:
            return "已缓存"
        case .loading:
            return "下载中"
        case .failed:
            return "重试"
        }
    }

    func pillColor(defaultColor: Color) -> Color {
        switch self {
        case .idle:
            return defaultColor
        case .cached:
            return IMColor.success
        case .loading:
            return IMColor.brand
        case .failed:
            return IMColor.danger
        }
    }
}

private struct FilePresentation {
    let visualKind: FileVisualKind
    let thumbnailURL: URL?
    let videoFrameURL: URL?
    let thumbnailCacheKey: String
    let needsRemotePreviewRefresh: Bool
    let previewRefreshTaskID: String

    init(file: FileItem) {
        let visualKind = file.visualKind
        self.visualKind = visualKind
        self.thumbnailURL = file.thumbnailRemoteURL(for: visualKind)
        self.videoFrameURL = file.videoFrameRemoteURL(for: visualKind)
        self.thumbnailCacheKey = file.mediaThumbnailCacheKey(for: visualKind)
        self.needsRemotePreviewRefresh = [.image, .video].contains(visualKind)
            && self.thumbnailURL == nil
            && self.videoFrameURL == nil
            && file.hasRemoteFileID
        self.previewRefreshTaskID = [
            file.remoteLookupID,
            file.cacheKey,
            file.version,
            file.thumbnailURL,
            file.posterURL,
            file.coverURL,
            file.previewURL,
            file.downloadURL
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
    }
}

private struct FavoriteAssetRow: View {
    let item: FavoriteAssetRenderItem
    let isPreparingDownload: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void
    let onUnfavorite: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                FileRow(
                    item: FileRenderItem(file: item.file, presentation: item.presentation),
                    isPreparingDownload: isPreparingDownload,
                    actionsEnabled: !item.asset.isUnavailable,
                    onOpen: onOpen,
                    onDownload: onDownload,
                    onShare: onShare
                )
                if item.asset.isUnavailable {
                    Label("内容已失效/不可预览", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 2)
                }
            }
            Button {
                onUnfavorite()
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: 0xFFB246))
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.94))
                            .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消收藏")
            .padding(.trailing, 10)
        }
    }
}

private struct FileRow: View {
    let item: FileRenderItem
    let isPreparingDownload: Bool
    var actionsEnabled = true
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void

    private var file: FileItem { item.file }
    private var presentation: FilePresentation { item.presentation }
    private var downloadActionsEnabled: Bool {
        actionsEnabled && file.downloadAvailable && !isPreparingDownload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 13) {
                    FileThumbnail(file: file, presentation: presentation, size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.name)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        Text("\(file.type) · \(file.size) · \(file.owner)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                        Text("\(file.source) · \(file.time)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(IMColor.muted)
                    }
                    .padding(.trailing, 38)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                FileRowInlineActionButton(
                    title: isPreparingDownload ? "准备中" : "下载",
                    symbol: isPreparingDownload ? "hourglass" : "arrow.down.circle.fill",
                    enabled: downloadActionsEnabled,
                    action: onDownload
                )
                FileRowInlineActionButton(
                    title: "分享/保存",
                    symbol: "square.and.arrow.up.fill",
                    enabled: downloadActionsEnabled,
                    action: onShare
                )
                Spacer(minLength: 0)
            }
            .padding(.trailing, 38)
        }
        .plainCard(radius: 22)
    }
}

private struct FileRowInlineActionButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(enabled ? IMColor.brand : IMColor.muted.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(enabled ? IMColor.brand.opacity(0.10) : IMColor.line.opacity(0.38))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

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
        Group {
            if !state.isProtectedAccessAuthorized(.filePreview) {
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
        NavigationStackCompat {
            ZStack {
                Color(hex: 0x101828).ignoresSafeArea()
                VStack(spacing: 18) {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(.white.opacity(0.86))
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(.white.opacity(0.14)))
                                .overlay(Circle().stroke(.white.opacity(0.20), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭")
                    }
                    .padding(.horizontal, 20)

                    FilePreviewHero(file: file, isPreparingPreview: isPreparingPreview)
                        .frame(maxHeight: 420)
                        .padding(.horizontal, 18)

                    VStack(spacing: 12) {
                        HStack {
                            Label(file.status, systemImage: "checkmark.shield.fill")
                            Spacer()
                            Text(file.time)
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.80))

                        HStack(spacing: 12) {
                            PreviewAction(
                                symbol: file.visualKind.previewSymbol,
                                title: previewState.previewActionTitle ?? file.visualKind.previewTitle,
                                enabled: file.canAttemptSystemPreview && !previewState.isLoading
                            ) {
                                openSystemPreview()
                            }
                            PreviewAction(
                                symbol: isPreparingShare ? "arrow.down.circle.fill" : "square.and.arrow.down",
                                title: isPreparingShare ? "准备中" : "下载",
                                enabled: file.downloadAvailable && !isPreparingShare
                            ) {
                                prepareShareForFile()
                            }
                            PreviewAction(symbol: "square.and.arrow.up", title: "分享/保存", enabled: file.downloadAvailable && !isPreparingShare) {
                                prepareShareForFile()
                            }
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarNavigationBarDarkCompat()
        }
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
                guard let remoteURL = refreshedFile.systemPreviewRemoteURL else {
                    await MainActor.run {
                        guard state.contentCacheScopeKey == cacheScope else {
                            isPreparingPreview = false
                            return
                        }
                        isPreparingPreview = false
                        previewState = .idle
                        state.toast = "当前文件暂不支持预览，可下载保存"
                    }
                    return
                }
                let downloadedURL = try await MediaSignedURLRecovery.perform(
                    initialURL: remoteURL,
                    refreshURL: {
                        let refreshedAgain = try await state.refreshTenantFile(refreshedFile)
                        guard let refreshedURL = refreshedAgain.systemPreviewRemoteURL else {
                            throw IMAPIError.server("当前文件暂不支持预览")
                        }
                        return refreshedURL
                    },
                    operation: { candidateURL in
                        try await SystemPreviewLoader.download(
                            candidateURL,
                            suggestedName: refreshedFile.name,
                            cacheIdentity: refreshedFile.systemPreviewCacheIdentity(scope: cacheScope)
                        )
                    }
                )
                let localURL = if let cacheContext {
                    await FilesPreviewCacheAdapter.cacheDownloadedPreview(downloadedURL, for: refreshedFile, state: state, context: cacheContext)
                } else {
                    downloadedURL
                }
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
                    state.toast = "系统预览准备失败，请重试或下载保存"
                }
            }
        }
    }

    private func prepareShareForFile() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        state.toast = "正在准备下载文件"
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
                    state.toast = "文件已准备好，可保存或分享"
                }
            } catch {
                await MainActor.run {
                    isPreparingShare = false
                    state.toast = "文件下载失败，请稍后重试"
                }
            }
        }
    }
}

private struct PreviewAction: View {
    let symbol: String
    let title: String
    var danger = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            PreviewActionLabel(symbol: symbol, title: title, danger: danger, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct PreviewActionLabel: View {
    let symbol: String
    let title: String
    var danger = false
    var enabled = true

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(danger ? IMColor.danger : .white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill((danger ? IMColor.danger : IMColor.brand).opacity(enabled ? (danger ? 0.12 : 0.9) : 0.22))
                )
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.84 : 0.42))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FileThumbnail: View {
    @EnvironmentObject private var state: AppState
    let file: FileItem
    let presentation: FilePresentation
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: file.accentHex).opacity(0.12))

            if let thumbnailURL = presentation.thumbnailURL {
                AttachmentThumbnailImage(
                    url: thumbnailURL,
                    cacheKey: "\(state.mediaCacheScopeContext?.scopeHash ?? "invalid-scope")|\(presentation.thumbnailCacheKey)",
                    contentMode: .fill,
                    scopeGeneration: state.mediaCacheScopeContext?.sessionGeneration ?? 0,
                    networkRecoveryGeneration: state.mediaNetworkRecoveryGeneration,
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
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if presentation.visualKind == .video, let videoFrameURL = presentation.videoFrameURL {
                FileVideoFrameThumbnail(
                    url: videoFrameURL,
                    cacheKey: presentation.thumbnailCacheKey,
                    contentMode: .fill,
                    networkRecoveryGeneration: state.mediaNetworkRecoveryGeneration,
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
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                fileTypeLogo
            }

            if presentation.visualKind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.black.opacity(0.48)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.66), lineWidth: 1)
        )
    }

    private var fileTypeLogo: some View {
        VStack(spacing: 4) {
            Image(systemName: presentation.visualKind.symbol)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color(hex: file.accentHex))
            Text(presentation.visualKind.shortLabel)
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(Color(hex: file.accentHex).opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(6)
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

private struct FilePreviewHero: View {
    let file: FileItem
    let isPreparingPreview: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.white)
            .overlay {
                VStack(spacing: 16) {
                    previewArtwork
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                    Text(file.name)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text("\(file.type) · \(file.size)\n\(file.scope)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
    }

    @ViewBuilder
    private var previewArtwork: some View {
        if let thumbnailURL = file.thumbnailRemoteURL {
            ZStack {
                CachedRemoteImage(urlString: thumbnailURL.absoluteString, contentMode: .fit) {
                    iconPreview
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                if file.visualKind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
                }
            }
        } else {
            iconPreview
        }
        if isPreparingPreview {
            ProgressView("正在准备系统预览")
                .font(.system(size: 12, weight: .bold))
                .tint(IMColor.brand)
                .padding(.top, 4)
        }
    }

    private var iconPreview: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(hex: file.accentHex).opacity(0.12))
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: file.visualKind.symbol)
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(Color(hex: file.accentHex))
                    Text(file.visualKind.title)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: file.accentHex))
                }
            )
            .frame(width: 168, height: 168)
    }
}

private struct LocalPreviewDocument: Identifiable {
    let id = UUID()
    let url: URL
}

struct FileShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct FileActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DismissibleQuickLookPreview: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QuickLookPreview(url: url)
                .ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.56)))
                    .overlay(Circle().stroke(.white.opacity(0.26), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
    }
}

enum TenantFileSharePreparer {
    @MainActor
    static func prepare(file: FileItem, state: AppState, scope: String) async throws -> URL {
        let cacheContext = state.mediaCacheScopeContext
        if let cacheContext {
            let metadata = file.mediaResourceMetadata(scope: cacheContext.scopeHash)
            let integrity = MediaFileIntegrityAuthority(
                expectedSizeBytes: file.sizeBytes,
                expectedSHA256: file.checksum
            )
            if let cached = await state.lookupIndexedMediaCache(
                metadata: metadata,
                messageID: file.remoteLookupID,
                resourceKind: .original,
                integrity: integrity,
                context: cacheContext,
                offline: true
            ) {
                return cached
            }
        }
        let resolved = try await state.resolveTenantFileURL(file, preview: false)
        let identity = resolved.file.systemPreviewCacheIdentity(scope: scope).map { "\($0)|share" }
        let downloadedURL = try await MediaSignedURLRecovery.perform(
            initialURL: resolved.url,
            refreshURL: {
                let refreshed = try await state.resolveTenantFileURL(resolved.file, preview: false)
                return refreshed.url
            },
            operation: { candidateURL in
                try await SystemPreviewLoader.download(
                    candidateURL,
                    suggestedName: resolved.file.name,
                    cacheIdentity: identity
                )
            }
        )
        guard let cacheContext else { return downloadedURL }
        let metadata = resolved.file.mediaResourceMetadata(scope: cacheContext.scopeHash)
        let committed = try await state.commitIndexedMediaCache(
            temporaryURL: downloadedURL,
            metadata: metadata,
            resourceKind: .original,
            integrity: MediaFileIntegrityAuthority(
                expectedSizeBytes: resolved.file.sizeBytes,
                expectedSHA256: resolved.file.checksum
            ),
            messageID: resolved.file.remoteLookupID,
            conversationID: "__files__",
            authorityVersion: "0",
            context: cacheContext
        )
        SystemPreviewLoader.discardTransient(downloadedURL)
        return committed
    }
}

enum FilesPreviewCacheAdapter {
    @MainActor
    static func cachedThumbnailURL(
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext?
    ) async -> URL? {
        guard let context else { return nil }
        return await state.lookupIndexedMediaCache(
            metadata: thumbnailMetadata(for: file, scope: context.scopeHash),
            messageID: file.remoteLookupID,
            resourceKind: .thumbnail,
            variant: file.visualKind == .video ? .videoPoster : .thumbnail640,
            integrity: MediaFileIntegrityAuthority(),
            context: context,
            offline: true
        )
    }

    @MainActor
    static func cacheDownloadedThumbnail(
        _ data: Data,
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext?
    ) async -> URL? {
        guard !data.isEmpty, let context else { return nil }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-thumbnail-\(UUID().uuidString.lowercased()).jpg", isDirectory: false)
        do {
            try data.write(to: temporaryURL, options: .atomic)
            let committed = try await state.commitIndexedMediaCache(
                temporaryURL: temporaryURL,
                metadata: thumbnailMetadata(for: file, scope: context.scopeHash),
                resourceKind: .thumbnail,
                variant: file.visualKind == .video ? .videoPoster : .thumbnail640,
                integrity: MediaFileIntegrityAuthority(),
                messageID: file.remoteLookupID,
                conversationID: "__files__",
                authorityVersion: "0",
                context: context
            )
            try? FileManager.default.removeItem(at: temporaryURL)
            return committed
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }
    }

    private static func thumbnailMetadata(for file: FileItem, scope: String) -> MediaResourceMetadata {
        var metadata = file.mediaResourceMetadata(scope: scope)
        metadata.thumbnailMimeType = "image/jpeg"
        metadata.thumbnailExtension = "jpg"
        return metadata
    }

    @MainActor
    static func cachedPreviewURL(
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext
    ) async -> URL? {
        guard context.isValid else { return nil }
        let metadata = file.mediaResourceMetadata(scope: context.scopeHash)
        for resourceKind in [file.mediaPipelinePreviewResourceKind, .original] {
            if let localURL = await state.lookupIndexedMediaCache(
                metadata: metadata,
                messageID: file.remoteLookupID,
                resourceKind: resourceKind,
                integrity: integrity(for: file, resourceKind: resourceKind),
                context: context,
                offline: true
            ) {
                return localURL
            }
        }
        return nil
    }

    @MainActor
    static func cacheDownloadedPreview(
        _ localURL: URL,
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext
    ) async -> URL {
        guard context.isValid,
              FileManager.default.fileExists(atPath: localURL.path) else {
            return localURL
        }

        let metadata = file.mediaResourceMetadata(scope: context.scopeHash)
        let resourceKind = file.mediaPipelinePreviewResourceKind
        let preferredExtension = metadata.preferredExtension(for: resourceKind)
        let temporaryURL = temporaryCopyURL(for: localURL, preferredExtension: preferredExtension)
        let integrity = integrity(for: file, resourceKind: resourceKind)

        do {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try FileManager.default.removeItem(at: temporaryURL)
            }
            try FileManager.default.copyItem(at: localURL, to: temporaryURL)
            let committed = try await state.commitIndexedMediaCache(
                temporaryURL: temporaryURL,
                metadata: metadata,
                resourceKind: resourceKind,
                integrity: integrity,
                messageID: file.remoteLookupID,
                conversationID: "__files__",
                authorityVersion: "0",
                context: context
            )
            try? FileManager.default.removeItem(at: temporaryURL)
            SystemPreviewLoader.discardTransient(localURL)
            return committed
        } catch {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            return localURL
        }
    }

    private static func temporaryCopyURL(for localURL: URL, preferredExtension: String) -> URL {
        var temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-pipeline-preview-\(UUID().uuidString)", isDirectory: false)
        let ext = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localURL.pathExtension
            : preferredExtension
        if !ext.isEmpty {
            temporaryURL.appendPathExtension(ext)
        }
        return temporaryURL
    }

    /// The pre-contract Files cache was already tenant/user scoped, so it is the only legacy
    /// directory eligible for a bounded lazy migration.  Its FNV-derived filename is used
    /// solely to locate old bytes; it never becomes the new cache identity.
    @MainActor
    static func migrateAuthorizedLegacyPreview(
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext
    ) async -> URL? {
        guard !file.remoteLookupID.isEmpty,
              !file.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let oldScope = state.contentCacheScopeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldScope.isEmpty else { return nil }
        let metadata = file.mediaResourceMetadata(scope: context.scopeHash)
        for resourceKind in [file.mediaPipelinePreviewResourceKind, .original] {
            let preferredExtension = metadata.preferredExtension(for: resourceKind)
            let candidate = legacyURL(
                file: file,
                resourceKind: resourceKind,
                scope: oldScope,
                preferredExtension: preferredExtension
            )
            let integrity = integrity(for: file, resourceKind: resourceKind)
            guard (try? integrity.verify(fileAt: candidate)) != nil else { continue }
            do {
                let committed = try await state.commitIndexedMediaCache(
                    temporaryURL: candidate,
                    metadata: metadata,
                    resourceKind: resourceKind,
                    integrity: integrity,
                    messageID: file.remoteLookupID,
                    conversationID: "__files__",
                    authorityVersion: "0",
                    context: context
                )
                if candidate.standardizedFileURL != committed.standardizedFileURL {
                    try? FileManager.default.removeItem(at: candidate)
                }
                return committed
            } catch {
                continue
            }
        }
        return nil
    }

    private static func integrity(
        for file: FileItem,
        resourceKind: MediaResourceKind
    ) -> MediaFileIntegrityAuthority {
        guard resourceKind == .original else { return MediaFileIntegrityAuthority() }
        return MediaFileIntegrityAuthority(
            expectedSizeBytes: file.sizeBytes,
            expectedSHA256: file.checksum
        )
    }

    static func legacyURL(
        file: FileItem,
        resourceKind: MediaResourceKind,
        scope: String,
        preferredExtension: String
    ) -> URL {
        let mimeType = file.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fileID = file.id.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = ["media", resourceKind.rawValue, "scope-\(legacySafeComponent(scope))", legacySafeComponent(fileID)]
        let version = file.version.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty { parts.append("v-\(legacySafeComponent(version))") }
        if let sizeBytes = file.sizeBytes { parts.append("s-\(sizeBytes)") }
        if !mimeType.isEmpty { parts.append("m-\(legacySafeComponent(mimeType))") }
        let base = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("BlueStoneIMMediaPipeline", isDirectory: true)
            .appendingPathComponent(resourceKind.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(parts.joined(separator: "_"), isDirectory: false)
        let ext = legacySafeComponent(preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines))
        return ext.isEmpty ? base : base.appendingPathExtension(ext)
    }

    static func purgeLegacyScope(_ scope: String) {
        let marker = "scope-\(legacySafeComponent(scope))"
        let root = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("BlueStoneIMMediaPipeline", isDirectory: true)
        for kind in MediaResourceKind.allCases {
            let directory = root.appendingPathComponent(kind.cacheDirectoryName, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.lastPathComponent.contains(marker) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func legacySafeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let result = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        if result.isEmpty { return legacyFNV(value) }
        if result.count > 96 { return "\(result.prefix(64))_\(legacyFNV(value))" }
        return result
    }

    private static func legacyFNV(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16, uppercase: false)
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

enum SystemPreviewLoader {
    static func download(_ remoteURL: URL, suggestedName: String, cacheIdentity: String? = nil) async throws -> URL {
        try await SystemPreviewDownloadStore.shared.download(remoteURL, suggestedName: suggestedName, cacheIdentity: cacheIdentity)
    }

    static func discardTransient(_ url: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
            .standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func purgeAllTransientFiles() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
}

protocol SystemPreviewDownloading: Sendable {
    func download(from remoteURL: URL) async throws -> URL
}

struct SystemPreviewDownloadHTTPStatusError: MediaHTTPStatusProvidingError, Equatable {
    let statusCode: Int
    let requestURL: URL?
}

struct URLSessionSystemPreviewDownloader: SystemPreviewDownloading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(from remoteURL: URL) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: remoteURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw SystemPreviewDownloadHTTPStatusError(
                statusCode: httpResponse.statusCode,
                requestURL: remoteURL
            )
        }
        return temporaryURL
    }
}

actor SystemPreviewDownloadStore {
    static let shared = SystemPreviewDownloadStore()

    private let downloader: any SystemPreviewDownloading
    private var inFlightDownloads: [String: Task<URL, Error>] = [:]

    init(downloader: any SystemPreviewDownloading = URLSessionSystemPreviewDownloader()) {
        self.downloader = downloader
    }

    func download(_ remoteURL: URL, suggestedName: String, cacheIdentity: String? = nil) async throws -> URL {
        if remoteURL.isFileURL {
            return remoteURL
        }

        let stableIdentity = cacheIdentity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stableIdentity.isEmpty else {
            return try await downloadToTransientPreview(remoteURL, suggestedName: suggestedName)
        }

        let cacheKey = Self.cacheKey(remoteURL: remoteURL, suggestedName: suggestedName, cacheIdentity: stableIdentity)

        if let task = inFlightDownloads[cacheKey] {
            let sharedURL = try await task.value
            return try Self.materializeConsumerCopy(from: sharedURL)
        }

        let downloader = self.downloader
        let task = Task<URL, Error> {
            let temporaryURL = try await downloader.download(from: remoteURL)
            let destination = Self.destinationURL(remoteURL: remoteURL, suggestedName: suggestedName, cacheIdentity: stableIdentity)
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            return destination
        }

        inFlightDownloads[cacheKey] = task
        do {
            let localURL = try await task.value
            inFlightDownloads[cacheKey] = nil
            return try Self.materializeConsumerCopy(from: localURL)
        } catch {
            inFlightDownloads[cacheKey] = nil
            throw error
        }
    }

    private func downloadToTransientPreview(_ remoteURL: URL, suggestedName: String) async throws -> URL {
        let temporaryURL = try await downloader.download(from: remoteURL)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
        let directory = root.appendingPathComponent("transient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            Self.sanitizedFileName(suggestedName, fallbackExtension: remoteURL.pathExtension),
            isDirectory: false
        )
        try FileManager.default.copyItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func destinationURL(remoteURL: URL, suggestedName: String, cacheIdentity: String) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
        let directory = root
            .appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent(stableHash(cacheIdentity), isDirectory: true)
        let fileName = sanitizedFileName(suggestedName, fallbackExtension: remoteURL.pathExtension)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func materializeConsumerCopy(from sharedURL: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
            .appendingPathComponent("consumer-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        let destination = directory.appendingPathComponent(sharedURL.lastPathComponent, isDirectory: false)
        try FileManager.default.copyItem(at: sharedURL, to: destination)
        return destination
    }

    private static func cacheKey(remoteURL: URL, suggestedName: String, cacheIdentity: String) -> String {
        "\(cacheIdentity)|\(sanitizedFileName(suggestedName, fallbackExtension: remoteURL.pathExtension))"
    }

    private static func stableHash(_ value: String) -> String {
        MediaResourceIdentity.stableHash(value)
    }

    private static func sanitizedFileName(_ rawValue: String, fallbackExtension: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "preview-file" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.contains(".") || fallbackExtension.isEmpty {
            return sanitized.isEmpty ? "preview-file" : sanitized
        }
        return "\(sanitized).\(fallbackExtension)"
    }
}

enum FileVisualKind: Equatable {
    case image
    case video
    case pdf
    case spreadsheet
    case word
    case presentation
    case archive
    case audio
    case text
    case unknown

    var symbol: String {
        switch self {
        case .image: "photo.fill"
        case .video: "play.rectangle.fill"
        case .pdf: "doc.richtext.fill"
        case .spreadsheet: "tablecells.fill"
        case .word: "doc.text.fill"
        case .presentation: "rectangle.on.rectangle.angled"
        case .archive: "archivebox.fill"
        case .audio: "waveform"
        case .text: "text.document.fill"
        case .unknown: "doc.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .image: "IMG"
        case .video: "VID"
        case .pdf: "PDF"
        case .spreadsheet: "XLS"
        case .word: "DOC"
        case .presentation: "PPT"
        case .archive: "ZIP"
        case .audio: "AUD"
        case .text: "TXT"
        case .unknown: "FILE"
        }
    }

    var title: String {
        switch self {
        case .image: "图片"
        case .video: "视频"
        case .pdf: "PDF 文档"
        case .spreadsheet: "表格"
        case .word: "文档"
        case .presentation: "演示文稿"
        case .archive: "压缩包"
        case .audio: "音频"
        case .text: "文本"
        case .unknown: "附件"
        }
    }

    var previewTitle: String {
        switch self {
        case .image: "查看"
        case .video: "播放"
        case .pdf, .spreadsheet, .word, .presentation, .text: "系统预览"
        default: "预览"
        }
    }

    var previewSymbol: String {
        switch self {
        case .video: "play.fill"
        case .pdf, .spreadsheet, .word, .presentation, .text: "doc.viewfinder"
        case .image: "photo.on.rectangle.angled"
        default: "eye.fill"
        }
    }

    var canUseSystemPreview: Bool {
        switch self {
        case .image, .video, .pdf, .spreadsheet, .word, .presentation, .text:
            true
        case .archive, .audio, .unknown:
            false
        }
    }
}

extension FileItem {
    func mediaResourceMetadata(scope: String) -> MediaResourceMetadata {
        let authoritativeFileID = remoteLookupID
        let authoritativeCacheKey = authoritativeFileID.isEmpty ? "" : cacheKey
        return MediaResourceMetadata(
            scope: scope,
            fileID: authoritativeFileID,
            cacheKey: authoritativeCacheKey,
            version: version,
            checksumSHA256: checksum,
            createdAt: time,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            fileName: name,
            fileExtension: fileExtension,
            thumbnailCacheKey: authoritativeCacheKey,
            thumbnailVersion: version,
            previewCacheKey: authoritativeCacheKey,
            previewVersion: version
        )
    }

    var mediaPipelinePreviewResourceKind: MediaResourceKind {
        let hasPreviewURL = !previewURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return inlinePreviewAllowed && hasPreviewURL ? .preview : .original
    }

    var visualKind: FileVisualKind {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMedia = mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPreview = previewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (name as NSString).pathExtension.lowercased()
            : fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = [normalizedMedia, normalizedPreview, normalizedType, ext]

        if candidates.contains(where: { ["图片", "image", "img", "png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains($0) }) {
            return .image
        }
        if candidates.contains(where: { ["视频", "video", "mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains($0) }) {
            return .video
        }
        if candidates.contains("pdf") {
            return .pdf
        }
        if candidates.contains(where: { ["表格", "xlsx", "xls", "csv", "numbers"].contains($0) }) {
            return .spreadsheet
        }
        if candidates.contains(where: { ["文档", "doc", "docx", "pages"].contains($0) }) {
            return .word
        }
        if candidates.contains(where: { ["ppt", "pptx", "key"].contains($0) }) {
            return .presentation
        }
        if candidates.contains(where: { ["zip", "rar", "7z", "tar", "gz"].contains($0) }) {
            return .archive
        }
        if candidates.contains(where: { ["音频", "audio", "mp3", "m4a", "aac", "wav", "flac", "ogg"].contains($0) }) {
            return .audio
        }
        if candidates.contains(where: { ["txt", "md", "json", "xml", "log"].contains($0) }) {
            return .text
        }
        return .unknown
    }

    var thumbnailRemoteURL: URL? {
        thumbnailRemoteURL(for: visualKind)
    }

    func thumbnailRemoteURL(for visualKind: FileVisualKind) -> URL? {
        if let explicit = firstRenderableMediaURL(in: [thumbnailURL, coverURL, posterURL]) {
            return explicit
        }
        switch visualKind {
        case .image:
            return firstRenderableMediaURL(in: [previewURL, downloadURL])
        case .video:
            return nil
        default:
            return nil
        }
    }

    var videoFrameRemoteURL: URL? {
        videoFrameRemoteURL(for: visualKind)
    }

    func videoFrameRemoteURL(for visualKind: FileVisualKind) -> URL? {
        guard visualKind == .video else { return nil }
        return firstRenderableMediaURL(in: [previewURL, downloadURL])
    }

    func mediaThumbnailCacheKey(for visualKind: FileVisualKind) -> String {
        let stableKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableFileID = remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "file-media-preview",
            stableFileID.isEmpty ? stableKey : stableFileID,
            visualKind == .video ? "video-frame" : "thumbnail",
            stableVersion
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    var bestPreviewURL: URL? {
        guard inlinePreviewAllowed else { return nil }
        let candidate = !previewURL.isEmpty ? previewURL : downloadURL
        return URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var systemPreviewRemoteURL: URL? {
        if let previewURL = bestPreviewURL {
            return previewURL
        }
        guard visualKind.canUseSystemPreview else { return nil }
        let candidate = !downloadURL.isEmpty ? downloadURL : previewURL
        return URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var shareURL: URL? {
        let candidate = !downloadURL.isEmpty ? downloadURL : previewURL
        return URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var canAttemptSystemPreview: Bool {
        visualKind.canUseSystemPreview
            && (hasRemoteFileID || systemPreviewRemoteURL != nil)
    }

    func systemPreviewCacheIdentity(scope: String) -> String? {
        let stableKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableFileID = remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableSource = stableFileID.isEmpty ? stableKey : stableFileID
        guard !stableSource.isEmpty else { return nil }
        let versionValue = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksumValue = checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeValue = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            scopeValue.isEmpty ? "scope:missing" : "scope:\(scopeValue)",
            stableFileID.isEmpty ? "cache_key:\(stableSource)" : "file_id:\(stableSource)",
            versionValue.isEmpty ? "" : "version:\(versionValue)",
            checksumValue.isEmpty ? "" : "checksum:\(checksumValue)",
            sizeBytes.map { "size:\($0)" } ?? "",
            mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    private var inlinePreviewAllowed: Bool {
        let normalizedPreviewKind = previewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedPreviewKind == "download" {
            return false
        }
        let normalizedDisposition = contentDisposition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedDisposition.hasPrefix("attachment") {
            return false
        }
        return previewAvailable || !previewURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func firstRenderableMediaURL(in rawValues: [String]) -> URL? {
        for rawValue in rawValues {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !isTenantFileEndpointLike(trimmed),
                  let url = URL(string: trimmed),
                  (url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "")),
                  !isTenantFileEndpointLike(url.path) else {
                continue
            }
            return url
        }
        return nil
    }

    private func isTenantFileEndpointLike(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "/api/tenant/files" || trimmed.hasPrefix("/api/tenant/files/")
    }
}

struct RTCEntryView: View {
    @EnvironmentObject private var state: AppState
    @State private var requestedCallKind: RTCCallActionKind?
    @State private var selectedCallRecord: CallRecord?
    @State private var pendingCallTask: Task<Void, Never>?
    @State private var pendingCallGeneration = 0

    private var isCallSessionBusy: Bool {
        state.isStartingVoiceCall
            || state.isStartingVideoCall
            || state.incomingVoiceCall != nil
            || state.activeVoiceCall != nil
    }

    private var newVoiceCallUnavailableReason: String? {
        isCallSessionBusy ? "请先处理当前通话" : nil
    }

    private var newVideoCallUnavailableReason: String? {
        isCallSessionBusy ? "请先处理当前通话" : nil
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "phone.badge.waveform.fill")
                                .font(.system(size: 28, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 66, height: 66)
                                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing)))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("1对1沟通")
                                    .font(.system(size: 22, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("好友来电通知、接听和最近通话记录")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                            }
                        }
                        HStack(spacing: 12) {
                            Button {
                                guard state.guardCallLicenseForAction(.voice) else { return }
                                requestedCallKind = .voice
                            } label: {
                                Label("语音通话", systemImage: "phone.arrow.up.right.fill")
                                    .font(.callout.weight(.black))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .foregroundStyle(IMColor.brand)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 48)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(IMColor.brand.opacity(0.10))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(newVoiceCallUnavailableReason != nil)
                            .accessibilityIdentifier("rtc_new_voice_call_button")
                            .accessibilityLabel("发起语音通话")
                            .accessibilityHint(newVoiceCallUnavailableReason ?? "选择好友后发起一对一语音通话")

                            Button {
                                guard state.guardCallLicenseForAction(.video) else { return }
                                requestedCallKind = .video
                            } label: {
                                Label(
                                    "视频通话",
                                    systemImage: newVideoCallUnavailableReason == nil ? "video.fill" : "video.slash"
                                )
                                .font(.callout.weight(.black))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .foregroundStyle(newVideoCallUnavailableReason == nil ? IMColor.violet : IMColor.muted)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill((newVideoCallUnavailableReason == nil ? IMColor.violet : IMColor.muted).opacity(0.10))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(newVideoCallUnavailableReason != nil)
                            .accessibilityIdentifier("rtc_new_video_call_button")
                            .accessibilityLabel("发起视频通话")
                            .accessibilityHint(newVideoCallUnavailableReason ?? "选择好友后发起一对一视频通话")
                        }
                    }
                    .glassCard(radius: 28)

                    if let call = state.incomingVoiceCall {
                        RTCIncomingCallCard(call: call)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("最近通话")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        if state.calls.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "phone.badge.clock.fill")
                                    .font(.system(size: 28, weight: .black))
                                    .foregroundStyle(IMColor.brand)
                                    .frame(width: 64, height: 64)
                                    .background(Circle().fill(IMColor.brand.opacity(0.10)))
                                VStack(spacing: 6) {
                                    Text("暂无通话记录")
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                    Text("好友来电、已接和未接通话会在这里展示。")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(IMColor.muted)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .plainCard(radius: 24)
                        } else {
                            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：最近通话改为懒加载行，避免切入沟通 Tab 时一次性渲染全部记录
                            LazyVStack(spacing: 12) {
                                ForEach(state.calls) { call in
                                    Button {
                                        selectedCallRecord = call
                                    } label: {
                                        RTCCallRecordRow(call: call)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("rtc_recent_call_\(call.id)")
                                }
                            }
                            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $requestedCallKind) { requestedKind in
            RTCCallContactPickerSheet(preferredKind: requestedKind) { user, selectedKind in
                requestedCallKind = nil
                startCallAfterSheetDismissal(user, kind: selectedKind)
            }
            .environmentObject(state)
            .presentationDetentsCompat([.medium, .large])
            .presentationDragIndicatorCompat(.visible)
        }
        .sheet(item: $selectedCallRecord) { call in
            let peer = peerUser(for: call)
            RTCCallRecordDetailSheet(
                call: call,
                peer: peer,
                canStartVoiceCall: call.direction != .system && state.canStartVoiceCall(with: peer),
                voiceUnavailableReason: call.direction == .system ? "系统记录不可拨打" : state.voiceCallUnavailableReason(for: peer),
                canStartVideoCall: call.direction != .system && state.videoCallEntryUnavailableReason(for: peer) == nil,
                videoUnavailableReason: call.direction == .system ? "系统记录不可拨打" : state.videoCallUnavailableReason(for: peer),
                onVoiceDial: {
                    guard state.guardCallLicenseForAction(.voice) else { return }
                    selectedCallRecord = nil
                    startVoiceCallAfterSheetDismissal(peer)
                },
                onVideoDial: {
                    guard state.guardCallLicenseForAction(.video) else { return }
                    selectedCallRecord = nil
                    startVideoCallAfterSheetDismissal(peer)
                }
            )
            .presentationDetentsCompat([.medium, .large])
            .presentationDragIndicatorCompat(.visible)
        }
        .onDisappear {
            cancelPendingCallTask()
        }
        .onChangeCompat(of: isCallSessionBusy) { _, isBusy in
            if isBusy {
                cancelPendingCallTask()
            }
        }
    }

    private func startCallAfterSheetDismissal(_ user: IMUser, kind: RTCCallActionKind) {
        scheduleCallAfterSheetDismissal(user, kind: kind)
    }

    private func startVoiceCallAfterSheetDismissal(_ user: IMUser) {
        scheduleCallAfterSheetDismissal(user, kind: .voice)
    }

    private func startVideoCallAfterSheetDismissal(_ user: IMUser) {
        scheduleCallAfterSheetDismissal(user, kind: .video)
    }

    private func scheduleCallAfterSheetDismissal(_ user: IMUser, kind: RTCCallActionKind) {
        let media: RTCCapabilityMedia = kind == .voice ? .voice : .video
        guard state.guardCallLicenseForAction(media) else { return }
        let licenseGeneration = state.callLicenseActionGeneration(for: media)
        pendingCallTask?.cancel()
        pendingCallGeneration += 1
        let generation = pendingCallGeneration
        pendingCallTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 360_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, pendingCallGeneration == generation else { return }
            defer {
                if pendingCallGeneration == generation {
                    pendingCallTask = nil
                }
            }
            guard state.callLicenseActionGeneration(for: media) == licenseGeneration,
                  state.guardCallLicenseForAction(media) else { return }
            if let reason = callUnavailableReason(kind: kind, user: user) {
                state.toast = reason
                return
            }
            switch kind {
            case .voice:
                state.startOutgoingVoiceCall(to: user)
            case .video:
                state.startOutgoingVideoCall(to: user)
            }
        }
    }

    private func cancelPendingCallTask() {
        pendingCallGeneration += 1
        pendingCallTask?.cancel()
        pendingCallTask = nil
    }

    private func callUnavailableReason(kind: RTCCallActionKind, user: IMUser) -> String? {
        switch kind {
        case .voice:
            return newVoiceCallUnavailableReason ?? state.voiceCallUnavailableReason(for: user)
        case .video:
            return newVideoCallUnavailableReason ?? state.videoCallUnavailableReason(for: user)
        }
    }

    private func peerUser(for call: CallRecord) -> IMUser {
        let identifiers = [call.peerID, call.peerUserID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let contact = state.contacts.first(where: { contact in
            let contactIDs = [contact.id, contact.userID, contact.username]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return !Set(contactIDs).isDisjoint(with: identifiers)
        }) {
            return callPeerUser(contact, applying: call)
        }
        if !call.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let contact = state.contacts.first(where: { $0.name == call.title }) {
            return callPeerUser(contact, applying: call)
        }
        let fallbackID = identifiers.first ?? call.title
        return IMUser(
            id: fallbackID.isEmpty ? "unknown_voice_peer" : fallbackID,
            userID: call.peerUserID,
            name: call.title.isEmpty ? "语音联系人" : call.title,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: state.currentEnterprise.name,
            avatarSeed: UInt(bitPattern: fallbackID.hashValue),
            avatarURL: call.peerAvatarURL,
            avatarVersion: call.peerAvatarVersion,
            avatarUpdatedAt: call.peerAvatarUpdatedAt,
            badges: []
        )
    }

    private func callPeerUser(_ user: IMUser, applying call: CallRecord) -> IMUser {
        let recordAvatar = call.peerAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordVersion = call.peerAvatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordUpdatedAt = call.peerAvatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        return IMUser(
            id: user.id,
            userID: user.userID,
            username: user.username,
            name: user.name,
            title: user.title,
            department: user.department,
            departmentPathNames: user.departmentPathNames,
            phone: user.phone,
            phoneVerified: user.phoneVerified,
            realNameVerified: user.realNameVerified,
            realNameStatus: user.realNameStatus,
            email: user.email,
            status: user.status,
            enterprise: user.enterprise,
            avatarSeed: user.avatarSeed,
            avatarURL: recordAvatar.isEmpty ? user.avatarURL : recordAvatar,
            avatarVersion: recordVersion.isEmpty ? user.avatarVersion : recordVersion,
            avatarUpdatedAt: recordUpdatedAt.isEmpty ? user.avatarUpdatedAt : recordUpdatedAt,
            badges: user.badges
        )
    }
}

private enum RTCCallActionKind: String, Identifiable {
    case voice
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voice:
            return "语音通话"
        case .video:
            return "视频通话"
        }
    }

    var systemImage: String {
        switch self {
        case .voice:
            return "phone.fill"
        case .video:
            return "video.fill"
        }
    }

    var unavailableSystemImage: String {
        switch self {
        case .voice:
            return "phone.slash"
        case .video:
            return "video.slash"
        }
    }

    var accentColor: Color {
        switch self {
        case .voice:
            return IMColor.brand
        case .video:
            return IMColor.violet
        }
    }
}

private struct RTCCallRecordRow: View {
    @EnvironmentObject private var state: AppState

    let call: CallRecord

    private var accentColor: Color {
        switch call.direction {
        case .outgoing:
            return IMColor.brand
        case .incoming:
            return IMColor.success
        case .system:
            return IMColor.muted
        }
    }

    private var symbol: String {
        switch call.direction {
        case .outgoing:
            return "phone.arrow.up.right.fill"
        case .incoming:
            return "phone.arrow.down.left.fill"
        case .system:
            return "shield.lefthalf.filled"
        }
    }

    private var directionTitle: String {
        switch call.direction {
        case .outgoing:
            return "我呼出"
        case .incoming:
            return "对方来电"
        case .system:
            return "系统"
        }
    }

    private var statusColor: Color {
        if call.status.contains("拒") || call.status.contains("未") {
            return IMColor.danger
        }
        if call.status.contains("结束") || call.status.contains("已") {
            return IMColor.success
        }
        return IMColor.muted
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                AvatarView(
                    name: call.title,
                    seed: UInt(bitPattern: (call.peerID.isEmpty ? call.title : call.peerID).hashValue),
                    size: 44,
                    imageURL: call.peerAvatarURL,
                    avatarVersion: call.peerAvatarVersion,
                    avatarUpdatedAt: call.peerAvatarUpdatedAt,
                    certification: state.certificationPresentation(
                        forExactUID: call.peerID
                    )
                )
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accentColor))
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(call.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                CertificationPillView(
                    exactUID: call.peerID,
                    compact: true
                )
                HStack(spacing: 7) {
                    Text(directionTitle)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accentColor.opacity(0.10)))
                    Text(call.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(call.time)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                StatusPill(title: call.status, color: statusColor)
            }
        }
        .plainCard(radius: 20)
    }
}

private struct RTCCallRecordDetailSheet: View {
    @EnvironmentObject private var state: AppState

    @Environment(\.dismiss) private var dismiss
    let call: CallRecord
    let peer: IMUser
    let canStartVoiceCall: Bool
    let voiceUnavailableReason: String?
    let canStartVideoCall: Bool
    let videoUnavailableReason: String?
    let onVoiceDial: () -> Void
    let onVideoDial: () -> Void

    private var peerUserIDText: String {
        let value = peer.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? peer.id : value
    }

    private var certificationUID: String {
        call.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var callTypeText: String {
        let type = call.callType.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = type.isEmpty ? "语音通话" : type
        let kind = base.hasPrefix("视频") ? "视频" : "语音"
        switch call.direction {
        case .outgoing:
            return "\(kind)呼出"
        case .incoming:
            return "\(kind)来电"
        case .system:
            return base
        }
    }

    private var startedAtText: String {
        guard let startedAt = call.startedAt else { return "未记录" }
        return Self.dateFormatter.string(from: startedAt)
    }

    private var endedAtText: String {
        if let endedAt = call.endedAt {
            return Self.dateFormatter.string(from: endedAt)
        }
        return isTerminalStatus ? "未记录" : "进行中"
    }

    private var durationText: String {
        let seconds = call.durationSeconds ?? inferredDurationSeconds
        guard let seconds else {
            return isTerminalStatus ? "未记录" : "进行中"
        }
        return Self.durationText(seconds: seconds)
    }

    private var inferredDurationSeconds: TimeInterval? {
        guard let startedAt = call.startedAt, let endedAt = call.endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    private var isTerminalStatus: Bool {
        ["已结束", "已取消", "已拒绝", "已拒接", "未接通", "忙线"].contains(call.status)
            || call.status.contains("结束")
            || call.status.contains("取消")
            || call.status.contains("拒")
            || call.status.contains("未")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(IMColor.line)
                .frame(width: 42, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            HStack(spacing: 12) {
                AvatarView(name: peer.displayName, seed: peer.avatarSeed, size: 54, imageURL: peer.displayAvatarURL, avatarVersion: peer.avatarVersion, avatarUpdatedAt: peer.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: certificationUID))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(peer.displayName)
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        CertificationPillView(
                            exactUID: certificationUID,
                            compact: true
                        )
                    }
                    Text("用户ID \(peerUserIDText)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                StatusPill(title: call.status, color: statusColor)
            }

            VStack(spacing: 0) {
                detailRow(title: "呼叫类型", value: callTypeText)
                detailDivider
                detailRow(title: "开始时间", value: startedAtText)
                detailDivider
                detailRow(title: "结束时间", value: endedAtText)
                detailDivider
                detailRow(title: "总时长", value: durationText)
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(IMColor.line.opacity(0.78), lineWidth: 1))
            )

            VStack(alignment: .leading, spacing: 8) {
                if !canStartVoiceCall, let voiceUnavailableReason {
                    unavailableReason(kind: .voice, text: voiceUnavailableReason)
                }
                if !canStartVideoCall, let videoUnavailableReason {
                    unavailableReason(kind: .video, text: videoUnavailableReason)
                }
            }

            HStack(spacing: 12) {
                redialButton(
                    kind: .voice,
                    isEnabled: canStartVoiceCall,
                    unavailableReason: voiceUnavailableReason,
                    identifier: "rtc_recent_call_detail_voice_button"
                ) {
                    onVoiceDial()
                }
                redialButton(
                    kind: .video,
                    isEnabled: canStartVideoCall,
                    unavailableReason: videoUnavailableReason,
                    identifier: "rtc_recent_call_detail_video_button"
                ) {
                    onVideoDial()
                }
            }
        }
        .padding(18)
        .background(IMColor.page.ignoresSafeArea())
    }

    private var statusColor: Color {
        if call.status.contains("拒") || call.status.contains("未") || call.status.contains("忙") {
            return IMColor.danger
        }
        if call.status.contains("结束") || call.status.contains("已") {
            return IMColor.success
        }
        return IMColor.brand
    }

    private var detailDivider: some View {
        Rectangle()
            .fill(IMColor.line.opacity(0.72))
            .frame(height: 1)
    }

    private func unavailableReason(kind: RTCCallActionKind, text: String) -> some View {
        Label(text, systemImage: kind.unavailableSystemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(IMColor.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(kind.title)不可用：\(text)")
    }

    private func redialButton(
        kind: RTCCallActionKind,
        isEnabled: Bool,
        unavailableReason: String?,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(
                kind.title,
                systemImage: isEnabled ? kind.systemImage : kind.unavailableSystemImage
            )
            .font(.caption.weight(.black))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isEnabled ? kind.accentColor : IMColor.muted.opacity(0.45))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("重新\(kind.title)")
        .accessibilityHint(isEnabled ? "向该好友重新发起\(kind.title)" : (unavailableReason ?? "暂无法发起\(kind.title)"))
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm:ss"
        return formatter
    }()

    private static func durationText(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainSeconds = total % 60
        if hours > 0 {
            return "\(hours)小时\(minutes)分\(remainSeconds)秒"
        }
        if minutes > 0 {
            return "\(minutes)分\(remainSeconds)秒"
        }
        return "\(remainSeconds)秒"
    }
}

private struct RTCCallContactPickerSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let preferredKind: RTCCallActionKind
    let onSelect: (IMUser, RTCCallActionKind) -> Void

    private var currentUserKeys: Set<String> {
        Set([state.currentUser.id, state.currentUser.userID, state.currentUser.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private var allContacts: [IMUser] {
        state.contacts
            .filter { user in
                guard !user.isCancelledUser else { return false }
                return ![user.id, user.userID, user.username]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .contains { currentUserKeys.contains($0) }
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private var contacts: [IMUser] {
        IMUserSearchMatcher.sortedMatches(users: allContacts, query: query)
    }

    var body: some View {
        NavigationStackCompat {
            VStack(spacing: 14) {
                SearchField(text: $query, placeholder: "搜索好友、拼音或用户ID")
                    .accessibilityIdentifier("rtc_call_contact_search_field")
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                Label("本次准备发起\(preferredKind.title)", systemImage: preferredKind.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(preferredKind.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)

                if contacts.isEmpty {
                    Spacer(minLength: 0)
                    VStack(spacing: 10) {
                        Image(systemName: allContacts.isEmpty ? "person.crop.circle.badge.exclamationmark" : "magnifyingglass")
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                        Text(allContacts.isEmpty ? "暂无可呼叫好友" : "没有匹配的好友")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text(allContacts.isEmpty ? "添加好友后即可从这里发起一对一语音或视频通话。" : "可输入姓名、拼音首字母或用户ID继续搜索。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(contacts) { user in
                                HStack(spacing: 12) {
                                    AvatarView(name: user.displayName, seed: user.avatarSeed, size: 44, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(user.displayName)
                                            .font(.system(size: 15, weight: .black))
                                            .foregroundStyle(IMColor.ink)
                                            .lineLimit(1)
                                        CertificationPillView(
                                            exactUID: user.id,
                                            compact: true
                                        )
                                        Text(callContactSubtitle(user))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(IMColor.muted)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    HStack(spacing: 8) {
                                        contactCallAction(kind: .voice, user: user)
                                        contactCallAction(kind: .video, user: user)
                                    }
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.92))
                                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line.opacity(0.80), lineWidth: 1))
                                )
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
            .background(IMColor.page.ignoresSafeArea())
            .navigationTitle("选择好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") {
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .bold))
                }
            }
        }
    }

    private func contactCallAction(kind: RTCCallActionKind, user: IMUser) -> some View {
        let unavailableReason = callUnavailableReason(kind: kind, user: user)
        let isEnabled = unavailableReason == nil
        return Button {
            guard state.guardCallLicenseForAction(kind == .voice ? .voice : .video) else { return }
            dismiss()
            onSelect(user, kind)
        } label: {
            Label(
                kind.title,
                systemImage: isEnabled ? kind.systemImage : kind.unavailableSystemImage
            )
            .font(.caption2.weight(.black))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(.white)
            .frame(width: 82)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isEnabled ? kind.accentColor : IMColor.muted.opacity(0.45))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier("rtc_contact_\(kind.rawValue)_call_\(user.id)")
        .accessibilityLabel("向\(user.displayName)发起\(kind.title)")
        .accessibilityHint(isEnabled ? "发起\(kind.title)" : (unavailableReason ?? "暂无法发起\(kind.title)"))
    }

    private func callUnavailableReason(kind: RTCCallActionKind, user: IMUser) -> String? {
        switch kind {
        case .voice:
            return state.voiceCallUnavailableReason(for: user)
        case .video:
            return state.videoCallEntryUnavailableReason(for: user)
        }
    }

    private func callContactSubtitle(_ user: IMUser) -> String {
        let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let department = user.department.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = user.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return [userID.isEmpty ? user.id : userID, department, title]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct IncomingCallScreen: View {
    @EnvironmentObject private var state: AppState
    let call: IncomingVoiceCall
    private var caller: IMUser { state.displayUserForVoiceCall(call.caller) }
    private var isAnswering: Bool { state.incomingCallAnswerMode != nil }
    private var kindTitle: String { call.isVideo ? "视频来电" : "语音来电" }
    private var kindIcon: String { call.isVideo ? "video.fill" : "phone.fill" }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: call.isVideo
                    ? [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.07, green: 0.08, blue: 0.16)]
                    : [Color(red: 0.08, green: 0.20, blue: 0.29), Color(red: 0.04, green: 0.09, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        Label(kindTitle, systemImage: kindIcon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .accessibilityIdentifier("incoming_call_kind")
                            .padding(.top, 24)

                        Spacer(minLength: 16)
                        AvatarView(
                            name: caller.displayName, seed: caller.avatarSeed, size: 112,
                            imageURL: caller.displayAvatarURL, avatarVersion: caller.avatarVersion,
                            avatarUpdatedAt: caller.avatarUpdatedAt,
                            certification: state.certificationPresentation(forExactUID: caller.id)
                        )
                        VStack(spacing: 12) {
                            Text(caller.displayName)
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("incoming_call_caller")
                            CertificationPillView(exactUID: caller.id, compact: false)
                            if !callerDetails.isEmpty {
                                Text(callerDetails)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.72))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        Text(call.isVideo ? "邀请你进行视频通话" : "邀请你进行语音通话")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 24)

                        // Render metadata only. Media and permission work stays in the
                        // existing explicit answer actions; there is no camera preview.
                        if call.isVideo {
                            Text("接听前不会开启摄像头")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        if let toast = state.toast {
                            Text(toast)
                                .font(.footnote.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .padding(12)
                                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("incoming_call_action_message")
                        }
                        HStack(alignment: .top, spacing: 64) {
                            callButton(title: "拒绝", icon: "phone.down.fill", color: IMColor.danger,
                                       identifier: "incoming_call_reject_button", disabled: false) {
                                guard matchesCurrentCall else { return }
                                state.declineIncomingVoiceCall()
                            }
                            callButton(title: isAnswering ? "正在接听" : "接听",
                                       icon: kindIcon, color: IMColor.success,
                                       identifier: call.isVideo ? "incoming_video_answer_video_button" : "incoming_voice_answer_button",
                                       disabled: isAnswering) {
                                guard matchesCurrentCall else { return }
                                if call.isVideo {
                                    state.acceptIncomingVideoCall(as: "video")
                                } else {
                                    state.acceptIncomingVoiceCall()
                                }
                            }
                        }
                        if call.isVideo {
                            Button {
                                guard matchesCurrentCall else { return }
                                state.acceptIncomingVideoCall(as: "audio")
                            } label: {
                                Label(state.incomingCallAnswerMode == "audio" ? "正在语音接听" : "仅语音接听",
                                      systemImage: "phone.fill")
                                    .font(.body.weight(.semibold))
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(isAnswering)
                            .opacity(isAnswering ? 0.5 : 1)
                            .accessibilityIdentifier("incoming_video_answer_audio_button")
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier(call.isVideo ? "incoming_video_call" : "incoming_voice_call")
    }

    private var matchesCurrentCall: Bool {
        guard let current = state.incomingVoiceCall else { return false }
        return current.id == call.id && current.callID == call.callID && current.isVideo == call.isVideo
    }

    private var callerDetails: String {
        [caller.enterprise, caller.department, caller.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
            .joined(separator: " · ")
    }

    private func callButton(title: String, icon: String, color: Color, identifier: String,
                            disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(color))
                Text(title).font(.body.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct RTCIncomingCallCard: View {
    @EnvironmentObject private var state: AppState
    let call: IncomingVoiceCall
    private var caller: IMUser { state.displayUserForVoiceCall(call.caller) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AvatarView(name: caller.displayName, seed: caller.avatarSeed, size: 54, imageURL: caller.displayAvatarURL, avatarVersion: caller.avatarVersion, avatarUpdatedAt: caller.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: caller.id))
                VStack(alignment: .leading, spacing: 5) {
                    Text("好友正在呼叫")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    HStack(spacing: 6) {
                        Text("\(caller.displayName) · \(call.isVideo ? "视频通话" : "语音通话")")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                            .lineLimit(1)
                        CertificationPillView(
                            exactUID: caller.id,
                            compact: true
                        )
                    }
                }
                Spacer()
                StatusPill(title: "来电中", color: IMColor.success)
            }
            HStack(spacing: 10) {
                Button {
                    state.declineIncomingVoiceCall()
                } label: {
                    Label("拒绝", systemImage: "phone.down.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(IMColor.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.danger.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("incoming_voice_card_reject_button")
                Button {
                    if call.isVideo {
                        state.acceptIncomingVideoCall(as: "video")
                    } else {
                        state.acceptIncomingVoiceCall()
                    }
                } label: {
                    Label("接听", systemImage: call.isVideo ? "video.fill" : "phone.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.success))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(call.isVideo ? "incoming_video_card_answer_button" : "incoming_voice_card_answer_button")
            }
        }
        .plainCard(radius: 24)
    }
}

struct VoiceCallScreen: View {
    @EnvironmentObject private var state: AppState
    let session: VoiceCallSession
    @State private var isShowingKeypad = false

    private var currentSession: VoiceCallSession {
        state.activeVoiceCall ?? session
    }

    var body: some View {
        let call = currentSession
        let peer = state.displayUserForVoiceCall(call.peer)
        ZStack {
            LinearGradient(colors: [Color(hex: 0x101828), Color(hex: 0x1B2559), Color(hex: 0x5D6BFF)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                HStack {
                    StatusPill(title: callStageTitle(call), color: callStageColor(call), filled: true)
                    Spacer()
                    Text("语音通话")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(.top, 22)

                Spacer()

                AvatarView(name: peer.displayName, seed: peer.avatarSeed, size: 104, imageURL: peer.displayAvatarURL, avatarVersion: peer.avatarVersion, avatarUpdatedAt: peer.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: peer.id))
                    .shadow(color: .black.opacity(0.24), radius: 28, y: 16)
                    .accessibilityIdentifier("voice_call_peer_profile_disabled")
                    .accessibilityLabel("通话对象头像")
                    .accessibilityHint("通话期间不能打开用户资料")
                    .accessibilityAddTraits(.isStaticText)
                TimelineView(.periodic(from: Date(), by: 1)) { timeline in
                    VStack(spacing: 8) {
                        HStack(spacing: 7) {
                            Text(peer.displayName)
                                .font(.system(size: 30, weight: .black))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            CertificationPillView(
                                exactUID: peer.id,
                                compact: false
                            )
                        }
                        Text(callRuntimeText(call, now: timeline.date))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.70))
                            .monospacedDigit()
                        HStack(spacing: 8) {
                            VoiceCallStateChip(
                                symbol: call.speakerOn ? "speaker.wave.2.fill" : "speaker.fill",
                                title: call.speakerOn ? "免提已开" : "听筒模式"
                            )
                            VoiceCallStateChip(
                                symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                                title: call.isMuted ? "已静音" : "麦克风开启"
                            )
                        }
                        .padding(.top, 6)
                    }
                }

                Spacer()

                if isShowingKeypad {
                    VoiceCallKeypadPanel {
                        isShowingKeypad = false
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 8) {
                    CallControl(
                        symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                        title: call.isMuted ? "取消静音" : "静音",
                        isActive: call.isMuted
                    ) {
                        state.toggleActiveCallMuted()
                    }
                    .accessibilityIdentifier("voice_call_mute_button")
                    CallControl(
                        symbol: call.speakerOn ? "speaker.wave.2.fill" : "speaker.fill",
                        title: call.speakerOn ? "关闭免提" : "打开免提",
                        isActive: call.speakerOn
                    ) {
                        state.toggleActiveCallSpeaker()
                    }
                    .accessibilityIdentifier("voice_call_speaker_button")
                    CallControl(symbol: "circle.grid.3x3.fill", title: "键盘") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            isShowingKeypad.toggle()
                        }
                    }
                    CallControl(symbol: "phone.down.fill", title: "挂断", danger: true) {
                        state.endActiveVoiceCall()
                    }
                    .accessibilityIdentifier("voice_call_end_button")
                }
                .padding(.bottom, 42)
                .zIndex(2)
            }
            .padding(.horizontal, 18)
        }
        .accessibilityIdentifier("voice_call_screen")
        .interactiveDismissDisabled(true)
    }

    private func callStageTitle(_ call: VoiceCallSession) -> String {
        if call.statusText == "通话中" {
            return "通话中"
        }
        if call.direction == "来电" {
            return "来电中"
        }
        return "等待接听"
    }

    private func callStageColor(_ call: VoiceCallSession) -> Color {
        call.statusText == "通话中" ? IMColor.success : IMColor.brand
    }

    private func callRuntimeText(_ call: VoiceCallSession, now: Date) -> String {
        guard call.statusText == "通话中", let connectedAt = call.connectedAt else {
            return call.statusText
        }
        let total = max(0, Int(now.timeIntervalSince(connectedAt).rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct VoiceCallStateChip: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
            Text(title)
                .font(.system(size: 11, weight: .black))
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.14)))
    }
}

private struct VoiceCallKeypadPanel: View {
    let onClose: () -> Void
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("通话键盘")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起通话键盘")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(key)
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 62, height: 46)
                            .background(Capsule().fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("通话按键 \(key)")
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        )
    }
}

private struct CallControl: View {
    let symbol: String
    let title: String
    var isActive = false
    var danger = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(danger || isActive ? .white : .white.opacity(0.86))
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(controlBackground))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isActive ? .white : .white.opacity(0.78))
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 88)
        .contentShape(Rectangle())
    }

    private var controlBackground: Color {
        if danger { return IMColor.danger }
        if isActive { return .white.opacity(0.30) }
        return .white.opacity(0.16)
    }
}

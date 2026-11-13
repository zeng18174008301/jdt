// WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
import Combine
import Foundation
import IM4Domain
import IM4Data

private typealias AttachmentUploadCheckpoint = IM4Domain.AttachmentUploadCheckpoint<RemoteAvatarFile>

@MainActor
public final class FileStore: ObservableObject {
    private let removeOwnedPendingUpload: @MainActor (PendingAttachmentUpload) -> Void

    public init(removeOwnedPendingUpload: @escaping @MainActor (PendingAttachmentUpload) -> Void) {
        self.removeOwnedPendingUpload = removeOwnedPendingUpload
    }

    // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
    @Published public private(set) var mediaNetworkRecoveryGeneration = 0

    public func noteMediaNetworkRecovery() {
        mediaNetworkRecoveryGeneration &+= 1
    }
    // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
    public struct DownloadKeys: Hashable {
        public let original: String
        public let preview: String

        fileprivate func snapshot(in snapshots: [String: AttachmentDownloadSnapshot]) -> AttachmentDownloadSnapshot? {
            snapshots[original] ?? snapshots[preview]
        }

        public init(
            original: String,
            preview: String
        ) {
            self.original = original
            self.preview = preview
        }
    }

    public struct GroupFilesSnapshot: Equatable {
        public let files: [FileItem]
        public let isSyncing: Bool
        public let syncError: String?
    }
    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
    public struct ChatAttachmentIdentity {
        public let downloads: DownloadKeys
        public let messageID: String
        public let resourceKeys: [String]

        public init(
            downloads: DownloadKeys,
            messageID: String,
            resourceKeys: [String]
        ) {
            self.downloads = downloads
            self.messageID = messageID
            self.resourceKeys = resourceKeys
        }
    }

    public struct ChatAttachmentSnapshot: Equatable {
        public let downloads: [AttachmentDownloadSnapshot?]
        public let uploadProgress: Double?
        public let downloadFailed: Bool
        public let hasPendingUpload: Bool
        public let hasUploadTask: Bool
        public let resources: [LocalAttachmentPreviewResources?]
    }
    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
    public struct FavoriteAssetsSnapshot: Equatable {
        public var items: [FavoriteAssetItem] = []
        public var isSyncing: Bool = false
        public private(set) var errorMessage: String?

        public init(
            items: [FavoriteAssetItem] = [],
            isSyncing: Bool = false,
            errorMessage: String? = nil
        ) {
            self.items = items
            self.isSyncing = isSyncing
            self.errorMessage = errorMessage
        }
    }

    @Published public var favoriteAssetsSnapshot = FavoriteAssetsSnapshot()
    public var favoriteAssetsCollection = FavoriteAssetsCollectionState()

    public func publishFavoriteAssets(isSyncing: Bool, errorMessage: String? = nil) {
        favoriteAssetsSnapshot = FavoriteAssetsSnapshot(
            items: favoriteAssetsCollection.activeItems,
            isSyncing: isSyncing,
            errorMessage: errorMessage
        )
    }
    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END

    @Published private var files: [FileItem] = []
    @Published private var isSyncing = false
    @Published private var syncErrorMessage: String?
    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110_BEGIN
    public struct UploadConfigurationSnapshot: Equatable {
        public fileprivate(set) var config: FileUploadConfig = .defaultValue
        public fileprivate(set) var callLicenseScopeKey: String?

        // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
        public struct CallLicense: Equatable {
            public let scopeKey: String?
            public let voiceEnabled: Bool
            public let voiceKnown: Bool
            public let videoEnabled: Bool
            public let videoKnown: Bool
        }

        public var callLicense: CallLicense {
            CallLicense(
                scopeKey: callLicenseScopeKey,
                voiceEnabled: config.voiceCallEnabled,
                voiceKnown: config.voiceCallLicenseKnown,
                videoEnabled: config.videoCallEnabled,
                videoKnown: config.videoCallLicenseKnown
            )
        }
        // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END
    }

    @Published public private(set) var uploadConfiguration = UploadConfigurationSnapshot()
    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110_END
    @Published private var downloadProgressByID: [String: Double] = [:]
    @Published private var downloadSnapshots: [String: AttachmentDownloadSnapshot] = [:]
    @Published private var downloadFailedIDs: Set<String> = []
    @Published private var groupFiles: [String: [FileItem]] = [:]
    @Published private var groupSyncingIDs: Set<String> = []
    @Published private var groupSyncErrors: [String: String] = [:]

    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110
    @Published private var pendingAttachmentUploads: [String: PendingAttachmentUpload] = [:]
    private var attachmentUploadCheckpoints: [String: AttachmentUploadCheckpoint] = [:]
    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110
    @Published private var attachmentUploadTasks: [String: Task<Void, Never>] = [:]
    private var attachmentDownloadTasks: [String: Task<URL, Error>] = [:]
    private var attachmentDownloadTokens: [String: UUID] = [:]
    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110
    @Published private var localAttachmentResourcesByID: [String: LocalAttachmentPreviewResources] = [:]
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_STATE - 修改开始：附件下载进度刷新节流状态，降低图片加载时聊天列表重绘压力
    private var attachmentDownloadProgressUpdateTimes: [String: Date] = [:]
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_STATE - 修改结束：附件下载进度刷新节流状态，降低图片加载时聊天列表重绘压力

    public func tenantFiles() -> [FileItem] {
        Self.visibleFileItems(files)
    }

    public func replaceTenantFiles(_ fileItems: [FileItem]) {
        files = Self.visibleFileItems(fileItems)
    }

    public func hasTenantFile(id: String) -> Bool {
        Self.visibleFileItems(files).contains { $0.id == id }
    }

    public func hasTenantFiles() -> Bool {
        !Self.visibleFileItems(files).isEmpty
    }

    public func isTenantFilesSyncing() -> Bool {
        isSyncing
    }

    public func tenantFilesSyncError() -> String? {
        syncErrorMessage
    }

    public func beginTenantFilesSync() -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        syncErrorMessage = nil
        return true
    }

    public func finishTenantFilesSync() {
        isSyncing = false
    }

    public func setTenantFilesSyncError(_ message: String?) {
        syncErrorMessage = message
    }

    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110_BEGIN
    public func currentUploadConfig() -> FileUploadConfig {
        uploadConfiguration.config
    }

    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
    public func configurationUpdates<Value: Equatable>(
        for projection: KeyPath<UploadConfigurationSnapshot, Value>
    ) -> AnyPublisher<Value, Never> {
        $uploadConfiguration.map { $0[keyPath: projection] }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END

    public func replaceUploadConfig(_ config: FileUploadConfig) {
        uploadConfiguration.config = config
    }

    public func applyAuthoritativeUploadConfig(_ config: FileUploadConfig, callLicenseScopeKey: String) {
        uploadConfiguration = UploadConfigurationSnapshot(config: config, callLicenseScopeKey: callLicenseScopeKey)
    }

    public func invalidateCallLicenseAuthority() {
        guard uploadConfiguration.callLicenseScopeKey != nil else { return }
        uploadConfiguration.callLicenseScopeKey = nil
    }
    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110_END

    public func files(for groupID: String) -> [FileItem] {
        Self.visibleFileItems(groupFiles[groupID] ?? [])
    }

    public func isGroupSyncing(groupID: String) -> Bool {
        groupSyncingIDs.contains(groupID)
    }

    public func groupSyncError(groupID: String) -> String? {
        groupSyncErrors[groupID]
    }

    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
    public func groupFilesSnapshot(groupID: String) -> GroupFilesSnapshot {
        GroupFilesSnapshot(
            files: files(for: groupID),
            isSyncing: isGroupSyncing(groupID: groupID),
            syncError: groupSyncError(groupID: groupID)
        )
    }

    public func groupFilesUpdates(groupID: String) -> AnyPublisher<GroupFilesSnapshot, Never> {
        Publishers.CombineLatest3($groupFiles, $groupSyncingIDs, $groupSyncErrors)
            .map { files, syncingIDs, errors in
                GroupFilesSnapshot(
                    files: Self.visibleFileItems(files[groupID] ?? []),
                    isSyncing: syncingIDs.contains(groupID),
                    syncError: errors[groupID]
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END

    public func hasGroupFiles(groupID: String) -> Bool {
        groupFiles[groupID] != nil
    }

    public func replaceGroupFiles(_ files: [FileItem], groupID: String) {
        groupFiles[groupID] = Self.visibleFileItems(files)
    }

    public func clearGroupFiles(groupID: String) {
        groupFiles[groupID] = nil
        groupSyncingIDs.remove(groupID)
        groupSyncErrors[groupID] = nil
    }

    public func purgeGroupHistoryFiles(groupID: String, fromSeq: Int64, clearAll: Bool = false) {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty else { return }
        let boundarySeq = max(1, fromSeq)

        func isTargetGroupFile(_ file: FileItem) -> Bool {
            file.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "group"
                && file.channelID.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedGroupID
        }

        func shouldRemove(_ file: FileItem) -> Bool {
            guard isTargetGroupFile(file) else { return false }
            if clearAll { return true }
            return file.channelSeq <= 0 || file.channelSeq < boundarySeq
        }

        files.removeAll(where: shouldRemove)

        for (key, items) in Array(groupFiles) {
            let keyMatches = key.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedGroupID
            let pruned = items.filter { file in
                if shouldRemove(file) { return false }
                if clearAll, keyMatches { return false }
                return true
            }
            if pruned.isEmpty {
                groupFiles[key] = nil
            } else {
                groupFiles[key] = pruned
            }
        }
    }

    public func beginGroupFilesSync(groupID: String) -> Bool {
        guard !groupSyncingIDs.contains(groupID) else { return false }
        groupSyncingIDs.insert(groupID)
        groupSyncErrors[groupID] = nil
        return true
    }

    public func finishGroupFilesSync(groupID: String) {
        groupSyncingIDs.remove(groupID)
    }

    public func setGroupSyncError(_ message: String?, groupID: String) {
        groupSyncErrors[groupID] = message
    }

    public func mergeGroupFiles(_ fileItems: [FileItem]) {
        let grouped = Dictionary(
            grouping: fileItems.filter { $0.channelType == "group" && !$0.channelID.isEmpty }
        ) { $0.channelID }
        for (groupID, items) in grouped {
            groupFiles[groupID] = Self.visibleFileItems(items).sorted { $0.time > $1.time }
        }
    }

    public func upsertTenantFile(_ file: FileItem) {
        guard !file.isVoiceMessageAsset else {
            removeFileListItem(id: file.id)
            return
        }
        if let index = files.firstIndex(where: { $0.id == file.id }) {
            files[index] = file
        } else {
            files.insert(file, at: 0)
        }
        guard file.channelType == "group", !file.channelID.isEmpty else { return }
        var items = groupFiles[file.channelID] ?? []
        if let index = items.firstIndex(where: { $0.id == file.id }) {
            items[index] = file
        } else {
            items.insert(file, at: 0)
        }
        groupFiles[file.channelID] = items
    }

    private static func visibleFileItems(_ fileItems: [FileItem]) -> [FileItem] {
        fileItems.filter { !$0.isVoiceMessageAsset }
    }

    private func removeFileListItem(id: String) {
        files.removeAll { $0.id == id }
        for groupID in Array(groupFiles.keys) {
            groupFiles[groupID]?.removeAll { $0.id == id }
        }
    }

    public func cancelAttachmentDownloadTasks() {
        attachmentDownloadTasks.values.forEach { $0.cancel() }
        attachmentDownloadTasks.removeAll()
        attachmentDownloadTokens.removeAll()
        downloadSnapshots.removeAll()
    }

    public func attachmentDownloadTask(attachmentID: String) -> Task<URL, Error>? {
        attachmentDownloadTasks[attachmentID]
    }

    public func hasAttachmentDownloadTask(attachmentID: String) -> Bool {
        attachmentDownloadTasks[attachmentID] != nil
    }

    public func replaceAttachmentDownloadTask(attachmentID: String, with task: Task<URL, Error>, token: UUID = UUID()) {
        attachmentDownloadTasks[attachmentID]?.cancel()
        attachmentDownloadTasks[attachmentID] = task
        attachmentDownloadTokens[attachmentID] = token
    }

    public func finishAttachmentDownloadTask(attachmentID: String) {
        let token = attachmentDownloadTokens[attachmentID]
        let keys = token.map { value in attachmentDownloadTokens.filter { $0.value == value }.map(\.key) } ?? [attachmentID]
        for key in keys {
            attachmentDownloadTasks[key] = nil
            attachmentDownloadTokens[key] = nil
            if downloadSnapshots[key] != nil { downloadSnapshots[key] = nil }
        }
    }

    // An unknown/stale version resolves to an authoritative version before starting the body GET.
    public func coalesceAttachmentDownload(from source: String, to resolved: String, token: UUID) -> Task<URL, Error>? {
        if let existing = attachmentDownloadTasks[resolved], attachmentDownloadTokens[resolved] != token {
            if downloadSnapshots[source] != nil { beginAttachmentDownloadProgress(attachmentID: resolved) }
            return existing
        }
        guard attachmentDownloadTokens[source] == token else { return nil }
        attachmentDownloadTasks[resolved] = attachmentDownloadTasks[source]
        attachmentDownloadTokens[resolved] = token
        if let snapshot = downloadSnapshots[source] { downloadSnapshots[resolved] = snapshot }
        clearAttachmentDownloadFailed(attachmentID: resolved)
        return nil
    }

    public func cancelAttachmentDownloadTask(attachmentID: String) {
        attachmentDownloadTasks[attachmentID]?.cancel()
        finishAttachmentDownloadTask(attachmentID: attachmentID)
    }

    public func attachmentDownloadProgress(attachmentID: String) -> Double? {
        downloadProgressByID[attachmentID]
    }

    public func isCurrentAttachmentDownload(attachmentID: String, token: UUID) -> Bool {
        attachmentDownloadTokens[attachmentID] == token
    }

    public func attachmentDownloadSnapshot(attachmentID: String) -> AttachmentDownloadSnapshot? {
        downloadSnapshots[attachmentID]
    }

    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
    public func attachmentDownloadSnapshot(keys: DownloadKeys) -> AttachmentDownloadSnapshot? {
        keys.snapshot(in: downloadSnapshots)
    }

    public func attachmentDownloadUpdates(keys: DownloadKeys) -> AnyPublisher<AttachmentDownloadSnapshot?, Never> {
        $downloadSnapshots
            .map { keys.snapshot(in: $0) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
    public func chatAttachmentSnapshot(_ identity: ChatAttachmentIdentity) -> ChatAttachmentSnapshot {
        ChatAttachmentSnapshot(
            downloads: [downloadSnapshots[identity.downloads.original], downloadSnapshots[identity.downloads.preview]],
            uploadProgress: downloadProgressByID[identity.downloads.original] ?? downloadProgressByID[identity.messageID],
            downloadFailed: downloadFailedIDs.contains(identity.downloads.original),
            hasPendingUpload: pendingAttachmentUploads[identity.messageID] != nil,
            hasUploadTask: attachmentUploadTasks[identity.messageID] != nil,
            resources: identity.resourceKeys.map { localAttachmentResourcesByID[$0] }
        )
    }

    public func chatAttachmentUpdates(_ identity: ChatAttachmentIdentity) -> AnyPublisher<ChatAttachmentSnapshot, Never> {
        let original = identity.downloads.original
        let preview = identity.downloads.preview
        let messageID = identity.messageID
        let transfer = Publishers.CombineLatest3(
            $downloadSnapshots.map { [$0[original], $0[preview]] }.removeDuplicates(),
            $downloadProgressByID.map { $0[original] ?? $0[messageID] }.removeDuplicates(),
            $downloadFailedIDs.map { $0.contains(original) }.removeDuplicates()
        )
        let runtime = Publishers.CombineLatest3(
            $pendingAttachmentUploads.map { $0[messageID] != nil }.removeDuplicates(),
            $attachmentUploadTasks.map { $0[messageID] != nil }.removeDuplicates(),
            $localAttachmentResourcesByID
                .map { resources in identity.resourceKeys.map { resources[$0] } }
                .removeDuplicates()
        )
        return transfer.combineLatest(runtime)
            .map { transfer, runtime in
                ChatAttachmentSnapshot(
                    downloads: transfer.0, uploadProgress: transfer.1, downloadFailed: transfer.2,
                    hasPendingUpload: runtime.0, hasUploadTask: runtime.1, resources: runtime.2
                )
            }
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END

    public func beginAttachmentDownloadProgress(attachmentID: String) {
        guard downloadSnapshots[attachmentID] == nil,
              let token = attachmentDownloadTokens[attachmentID] else { return }
        setAttachmentDownloadSnapshot(AttachmentDownloadSnapshot(), attachmentID: attachmentID, token: token)
    }

    public func updateVisibleAttachmentDownloadProgress(_ snapshot: AttachmentDownloadSnapshot, attachmentID: String, token: UUID) {
        guard downloadSnapshots[attachmentID] != nil else { return }
        setAttachmentDownloadSnapshot(snapshot, attachmentID: attachmentID, token: token)
    }

    public func setAttachmentDownloadSnapshot(_ snapshot: AttachmentDownloadSnapshot, attachmentID: String, token: UUID) {
        guard isCurrentAttachmentDownload(attachmentID: attachmentID, token: token),
              !(downloadSnapshots[attachmentID]?.isCommitting == true && !snapshot.isCommitting),
              downloadSnapshots[attachmentID] != snapshot else { return }
        var snapshots = downloadSnapshots
        for (key, owner) in attachmentDownloadTokens where owner == token {
            snapshots[key] = snapshot
        }
        downloadSnapshots = snapshots
    }

    public func setAttachmentDownloadProgress(_ progress: Double, attachmentID: String) {
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_APPLY - 修改开始：下载进度小幅高频变化不立即发布，避免滑动图片消息时卡顿
        let boundedProgress = max(0, min(progress, 1))
        let currentProgress = downloadProgressByID[attachmentID]
        let now = Date()
        guard shouldPublishAttachmentDownloadProgress(
            current: currentProgress,
            next: boundedProgress,
            lastUpdatedAt: attachmentDownloadProgressUpdateTimes[attachmentID],
            now: now
        ) else { return }
        attachmentDownloadProgressUpdateTimes[attachmentID] = now
        downloadProgressByID[attachmentID] = boundedProgress
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_APPLY - 修改结束：下载进度小幅高频变化不立即发布，避免滑动图片消息时卡顿
    }

    public func clearAttachmentDownloadProgress(attachmentID: String) {
        if downloadSnapshots[attachmentID] != nil { downloadSnapshots[attachmentID] = nil }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_CLEAR - 修改开始：清理下载进度时同步清理节流状态，完成/失败/取消仍即时生效
        attachmentDownloadProgressUpdateTimes[attachmentID] = nil
        if downloadProgressByID[attachmentID] != nil { downloadProgressByID[attachmentID] = nil }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_CLEAR - 修改结束：清理下载进度时同步清理节流状态，完成/失败/取消仍即时生效
    }

    public func clearAttachmentDownloadProgress(attachmentIDs: some Sequence<String>) {
        for attachmentID in attachmentIDs {
            clearAttachmentDownloadProgress(attachmentID: attachmentID)
        }
    }

    public func isAttachmentDownloadFailed(attachmentID: String) -> Bool {
        downloadFailedIDs.contains(attachmentID)
    }

    public func markAttachmentDownloadFailed(attachmentID: String) {
        downloadFailedIDs.insert(attachmentID)
        if let token = attachmentDownloadTokens[attachmentID] {
            downloadFailedIDs.formUnion(attachmentDownloadTokens.filter { $0.value == token }.map(\.key))
        }
    }

    public func clearAttachmentDownloadFailed(attachmentID: String) {
        if downloadFailedIDs.contains(attachmentID) { downloadFailedIDs.remove(attachmentID) }
    }

    public func localAttachmentResources(cacheKey: String) -> LocalAttachmentPreviewResources? {
        localAttachmentResourcesByID[normalizedCacheKey(cacheKey)]
    }

    public func cacheLocalAttachmentResources(_ resources: LocalAttachmentPreviewResources, cacheKey: String) {
        let cacheKey = normalizedCacheKey(cacheKey)
        guard !cacheKey.isEmpty else { return }
        localAttachmentResourcesByID[cacheKey] = resources
    }

    public func cacheLocalAttachmentResources(_ resources: LocalAttachmentPreviewResources, cacheKeys: some Sequence<String>) {
        for cacheKey in cacheKeys {
            cacheLocalAttachmentResources(resources, cacheKey: cacheKey)
        }
    }

    public func clearLocalAttachmentResources(cacheKey: String) {
        localAttachmentResourcesByID[normalizedCacheKey(cacheKey)] = nil
    }

    public func clearLocalAttachmentResources() {
        localAttachmentResourcesByID.removeAll()
    }

    public func pendingAttachmentUpload(messageID: String) -> PendingAttachmentUpload? {
        pendingAttachmentUploads[messageID]
    }

    public func rememberPendingAttachmentUpload(_ upload: PendingAttachmentUpload, messageID: String) {
        if let existing = pendingAttachmentUploads[messageID], existing.fileURL != upload.fileURL {
            removeOwnedPendingUpload(existing)
        }
        pendingAttachmentUploads[messageID] = upload
        attachmentUploadCheckpoints[messageID] = nil
    }

    public func attachmentUploadCheckpoint(messageID: String) -> IM4Domain.AttachmentUploadCheckpoint<RemoteAvatarFile>? {
        attachmentUploadCheckpoints[messageID]
    }

    public func recordAttachmentUploadPresign(messageID: String, fileID: String) {
        let normalizedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileID.isEmpty else { return }
        if attachmentUploadCheckpoints[messageID]?.fileID == normalizedFileID {
            return
        }
        attachmentUploadCheckpoints[messageID] = AttachmentUploadCheckpoint(
            fileID: normalizedFileID,
            putCompleted: false,
            completedFile: nil
        )
    }

    public func recordAttachmentUploadPUTCompleted(messageID: String, fileID: String, accelerated: Bool = false) {
        recordAttachmentUploadPresign(messageID: messageID, fileID: fileID)
        attachmentUploadCheckpoints[messageID]?.putCompleted = true
        attachmentUploadCheckpoints[messageID]?.accelerated = accelerated
    }

    public func recordAttachmentUploadStandardFallback(messageID: String, fileID: String) {
        recordAttachmentUploadPUTCompleted(messageID: messageID, fileID: fileID)
        attachmentUploadCheckpoints[messageID]?.standardFallbackUsed = true
    }

    public func recordVideoUploadVerificationSelected(messageID: String) {
        attachmentUploadCheckpoints[messageID]?.videoVerificationSelected = true
    }

    public func recordAttachmentUploadFinalized(messageID: String, file: RemoteAvatarFile) {
        recordAttachmentUploadPresign(messageID: messageID, fileID: file.id)
        attachmentUploadCheckpoints[messageID]?.putCompleted = true
        attachmentUploadCheckpoints[messageID]?.completedFile = file
    }

    public func hasPendingAttachmentUpload(messageID: String) -> Bool {
        pendingAttachmentUploads[messageID] != nil
    }

    public func hasAttachmentUploadRuntimeState(messageID: String) -> Bool {
        pendingAttachmentUploads[messageID] != nil || attachmentUploadTasks[messageID] != nil
    }

    public func hasAttachmentUploadTask(messageID: String) -> Bool {
        attachmentUploadTasks[messageID] != nil
    }

    public func replaceAttachmentUploadTask(messageID: String, with task: Task<Void, Never>) {
        attachmentUploadTasks[messageID]?.cancel()
        attachmentUploadTasks[messageID] = task
    }

    public func finishAttachmentUploadTask(messageID: String) {
        attachmentUploadTasks[messageID] = nil
    }

    public func clearPendingAttachmentUpload(messageID: String, cleanupSource: Bool = true) {
        if cleanupSource {
            if let upload = pendingAttachmentUploads[messageID] { removeOwnedPendingUpload(upload) }
        }
        pendingAttachmentUploads[messageID] = nil
        attachmentUploadCheckpoints[messageID] = nil
    }

    public func finishAttachmentUpload(messageID: String) {
        clearPendingAttachmentUpload(messageID: messageID)
        finishAttachmentUploadTask(messageID: messageID)
    }

    public func cancelAttachmentUpload(messageID: String) {
        attachmentUploadTasks[messageID]?.cancel()
        finishAttachmentUpload(messageID: messageID)
    }

    public func cancelAttachmentUploads() {
        attachmentUploadTasks.values.forEach { $0.cancel() }
        attachmentUploadTasks.removeAll()
        pendingAttachmentUploads.values.forEach { removeOwnedPendingUpload($0) }
        pendingAttachmentUploads.removeAll()
        attachmentUploadCheckpoints.removeAll()
    }

    public func reset() {
        cancelAttachmentUploads()
        cancelAttachmentDownloadTasks()
        clearLocalAttachmentResources()
        downloadProgressByID.removeAll()
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_RESET - 修改开始：重置文件状态时清理进度节流缓存
        attachmentDownloadProgressUpdateTimes.removeAll()
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_RESET - 修改结束：重置文件状态时清理进度节流缓存
        downloadFailedIDs.removeAll()
        uploadConfiguration = UploadConfigurationSnapshot() // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110
        files = []
        isSyncing = false
        syncErrorMessage = nil
        groupFiles = [:]
        groupSyncingIDs = []
        groupSyncErrors = [:]
    }

    private func normalizedCacheKey(_ cacheKey: String) -> String {
        cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_HELPER - 修改开始：附件下载进度发布阈值，保留开始/结束并合并细碎刷新
    private func shouldPublishAttachmentDownloadProgress(
        current: Double?,
        next: Double,
        lastUpdatedAt: Date?,
        now: Date,
        minimumDelta: Double = 0.025,
        minimumInterval: TimeInterval = 0.12
    ) -> Bool {
        guard let current else { return true }
        if next >= 0.995 { return true }
        if abs(next - current) >= minimumDelta { return true }
        guard let lastUpdatedAt else { return true }
        return now.timeIntervalSince(lastUpdatedAt) >= minimumInterval
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_HELPER - 修改结束：附件下载进度发布阈值，保留开始/结束并合并细碎刷新
}

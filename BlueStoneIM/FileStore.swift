import Foundation

@MainActor
final class FileStore: ObservableObject {
    @Published private var files: [FileItem] = []
    @Published private var isSyncing = false
    @Published private var syncErrorMessage: String?
    @Published private var uploadConfig: FileUploadConfig = .defaultValue
    @Published private var downloadProgressByID: [String: Double] = [:]
    @Published private var downloadFailedIDs: Set<String> = []
    @Published private var groupFiles: [String: [FileItem]] = [:]
    @Published private var groupSyncingIDs: Set<String> = []
    @Published private var groupSyncErrors: [String: String] = [:]

    private var pendingAttachmentUploads: [String: PendingAttachmentUpload] = [:]
    private var attachmentUploadCheckpoints: [String: AttachmentUploadCheckpoint] = [:]
    private var attachmentUploadTasks: [String: Task<Void, Never>] = [:]
    private var attachmentDownloadTasks: [String: Task<URL, Error>] = [:]
    private var localAttachmentResourcesByID: [String: LocalAttachmentPreviewResources] = [:]
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_STATE - 修改开始：附件下载进度刷新节流状态，降低图片加载时聊天列表重绘压力
    private var attachmentDownloadProgressUpdateTimes: [String: Date] = [:]
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_STATE - 修改结束：附件下载进度刷新节流状态，降低图片加载时聊天列表重绘压力

    func tenantFiles() -> [FileItem] {
        visibleFileItems(files)
    }

    func replaceTenantFiles(_ fileItems: [FileItem]) {
        files = visibleFileItems(fileItems)
    }

    func hasTenantFile(id: String) -> Bool {
        visibleFileItems(files).contains { $0.id == id }
    }

    func hasTenantFiles() -> Bool {
        !visibleFileItems(files).isEmpty
    }

    func isTenantFilesSyncing() -> Bool {
        isSyncing
    }

    func tenantFilesSyncError() -> String? {
        syncErrorMessage
    }

    func beginTenantFilesSync() -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        syncErrorMessage = nil
        return true
    }

    func finishTenantFilesSync() {
        isSyncing = false
    }

    func setTenantFilesSyncError(_ message: String?) {
        syncErrorMessage = message
    }

    func currentUploadConfig() -> FileUploadConfig {
        uploadConfig
    }

    func replaceUploadConfig(_ config: FileUploadConfig) {
        uploadConfig = config
    }

    func files(for groupID: String) -> [FileItem] {
        visibleFileItems(groupFiles[groupID] ?? [])
    }

    func isGroupSyncing(groupID: String) -> Bool {
        groupSyncingIDs.contains(groupID)
    }

    func groupSyncError(groupID: String) -> String? {
        groupSyncErrors[groupID]
    }

    func hasGroupFiles(groupID: String) -> Bool {
        groupFiles[groupID] != nil
    }

    func replaceGroupFiles(_ files: [FileItem], groupID: String) {
        groupFiles[groupID] = visibleFileItems(files)
    }

    func clearGroupFiles(groupID: String) {
        groupFiles[groupID] = nil
        groupSyncingIDs.remove(groupID)
        groupSyncErrors[groupID] = nil
    }

    func purgeGroupHistoryFiles(groupID: String, fromSeq: Int64, clearAll: Bool = false) {
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

    func beginGroupFilesSync(groupID: String) -> Bool {
        guard !groupSyncingIDs.contains(groupID) else { return false }
        groupSyncingIDs.insert(groupID)
        groupSyncErrors[groupID] = nil
        return true
    }

    func finishGroupFilesSync(groupID: String) {
        groupSyncingIDs.remove(groupID)
    }

    func setGroupSyncError(_ message: String?, groupID: String) {
        groupSyncErrors[groupID] = message
    }

    func mergeGroupFiles(_ fileItems: [FileItem]) {
        let grouped = Dictionary(
            grouping: fileItems.filter { $0.channelType == "group" && !$0.channelID.isEmpty }
        ) { $0.channelID }
        for (groupID, items) in grouped {
            groupFiles[groupID] = visibleFileItems(items).sorted { $0.time > $1.time }
        }
    }

    func upsertTenantFile(_ file: FileItem) {
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

    private func visibleFileItems(_ fileItems: [FileItem]) -> [FileItem] {
        fileItems.filter { !$0.isVoiceMessageAsset }
    }

    private func removeFileListItem(id: String) {
        files.removeAll { $0.id == id }
        for groupID in Array(groupFiles.keys) {
            groupFiles[groupID]?.removeAll { $0.id == id }
        }
    }

    func cancelAttachmentDownloadTasks() {
        attachmentDownloadTasks.values.forEach { $0.cancel() }
        attachmentDownloadTasks.removeAll()
    }

    func attachmentDownloadTask(attachmentID: String) -> Task<URL, Error>? {
        attachmentDownloadTasks[attachmentID]
    }

    func hasAttachmentDownloadTask(attachmentID: String) -> Bool {
        attachmentDownloadTasks[attachmentID] != nil
    }

    func replaceAttachmentDownloadTask(attachmentID: String, with task: Task<URL, Error>) {
        attachmentDownloadTasks[attachmentID]?.cancel()
        attachmentDownloadTasks[attachmentID] = task
    }

    func finishAttachmentDownloadTask(attachmentID: String) {
        attachmentDownloadTasks[attachmentID] = nil
    }

    func cancelAttachmentDownloadTask(attachmentID: String) {
        attachmentDownloadTasks[attachmentID]?.cancel()
        finishAttachmentDownloadTask(attachmentID: attachmentID)
    }

    func attachmentDownloadProgress(attachmentID: String) -> Double? {
        downloadProgressByID[attachmentID]
    }

    func setAttachmentDownloadProgress(_ progress: Double, attachmentID: String) {
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

    func clearAttachmentDownloadProgress(attachmentID: String) {
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_CLEAR - 修改开始：清理下载进度时同步清理节流状态，完成/失败/取消仍即时生效
        attachmentDownloadProgressUpdateTimes[attachmentID] = nil
        downloadProgressByID[attachmentID] = nil
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_CLEAR - 修改结束：清理下载进度时同步清理节流状态，完成/失败/取消仍即时生效
    }

    func clearAttachmentDownloadProgress(attachmentIDs: some Sequence<String>) {
        for attachmentID in attachmentIDs {
            clearAttachmentDownloadProgress(attachmentID: attachmentID)
        }
    }

    func isAttachmentDownloadFailed(attachmentID: String) -> Bool {
        downloadFailedIDs.contains(attachmentID)
    }

    func markAttachmentDownloadFailed(attachmentID: String) {
        downloadFailedIDs.insert(attachmentID)
    }

    func clearAttachmentDownloadFailed(attachmentID: String) {
        downloadFailedIDs.remove(attachmentID)
    }

    func localAttachmentResources(cacheKey: String) -> LocalAttachmentPreviewResources? {
        localAttachmentResourcesByID[normalizedCacheKey(cacheKey)]
    }

    func cacheLocalAttachmentResources(_ resources: LocalAttachmentPreviewResources, cacheKey: String) {
        let cacheKey = normalizedCacheKey(cacheKey)
        guard !cacheKey.isEmpty else { return }
        localAttachmentResourcesByID[cacheKey] = resources
    }

    func cacheLocalAttachmentResources(_ resources: LocalAttachmentPreviewResources, cacheKeys: some Sequence<String>) {
        for cacheKey in cacheKeys {
            cacheLocalAttachmentResources(resources, cacheKey: cacheKey)
        }
    }

    func clearLocalAttachmentResources(cacheKey: String) {
        localAttachmentResourcesByID[normalizedCacheKey(cacheKey)] = nil
    }

    func clearLocalAttachmentResources() {
        localAttachmentResourcesByID.removeAll()
    }

    func pendingAttachmentUpload(messageID: String) -> PendingAttachmentUpload? {
        pendingAttachmentUploads[messageID]
    }

    func rememberPendingAttachmentUpload(_ upload: PendingAttachmentUpload, messageID: String) {
        if let existing = pendingAttachmentUploads[messageID], existing.fileURL != upload.fileURL {
            existing.removeOwnedFile()
        }
        pendingAttachmentUploads[messageID] = upload
        attachmentUploadCheckpoints[messageID] = nil
    }

    func attachmentUploadCheckpoint(messageID: String) -> AttachmentUploadCheckpoint? {
        attachmentUploadCheckpoints[messageID]
    }

    func recordAttachmentUploadPresign(messageID: String, fileID: String) {
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

    func recordAttachmentUploadPUTCompleted(messageID: String, fileID: String) {
        recordAttachmentUploadPresign(messageID: messageID, fileID: fileID)
        attachmentUploadCheckpoints[messageID]?.putCompleted = true
    }

    func recordAttachmentUploadFinalized(messageID: String, file: RemoteAvatarFile) {
        recordAttachmentUploadPresign(messageID: messageID, fileID: file.id)
        attachmentUploadCheckpoints[messageID]?.putCompleted = true
        attachmentUploadCheckpoints[messageID]?.completedFile = file
    }

    func hasPendingAttachmentUpload(messageID: String) -> Bool {
        pendingAttachmentUploads[messageID] != nil
    }

    func hasAttachmentUploadRuntimeState(messageID: String) -> Bool {
        pendingAttachmentUploads[messageID] != nil || attachmentUploadTasks[messageID] != nil
    }

    func hasAttachmentUploadTask(messageID: String) -> Bool {
        attachmentUploadTasks[messageID] != nil
    }

    func replaceAttachmentUploadTask(messageID: String, with task: Task<Void, Never>) {
        attachmentUploadTasks[messageID]?.cancel()
        attachmentUploadTasks[messageID] = task
    }

    func finishAttachmentUploadTask(messageID: String) {
        attachmentUploadTasks[messageID] = nil
    }

    func clearPendingAttachmentUpload(messageID: String, cleanupSource: Bool = true) {
        if cleanupSource {
            pendingAttachmentUploads[messageID]?.removeOwnedFile()
        }
        pendingAttachmentUploads[messageID] = nil
        attachmentUploadCheckpoints[messageID] = nil
    }

    func finishAttachmentUpload(messageID: String) {
        clearPendingAttachmentUpload(messageID: messageID)
        finishAttachmentUploadTask(messageID: messageID)
    }

    func cancelAttachmentUpload(messageID: String) {
        attachmentUploadTasks[messageID]?.cancel()
        finishAttachmentUpload(messageID: messageID)
    }

    func cancelAttachmentUploads() {
        attachmentUploadTasks.values.forEach { $0.cancel() }
        attachmentUploadTasks.removeAll()
        pendingAttachmentUploads.values.forEach { $0.removeOwnedFile() }
        pendingAttachmentUploads.removeAll()
        attachmentUploadCheckpoints.removeAll()
    }

    func reset() {
        cancelAttachmentUploads()
        cancelAttachmentDownloadTasks()
        clearLocalAttachmentResources()
        downloadProgressByID.removeAll()
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_RESET - 修改开始：重置文件状态时清理进度节流缓存
        attachmentDownloadProgressUpdateTimes.removeAll()
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_PROGRESS_THROTTLE_RESET - 修改结束：重置文件状态时清理进度节流缓存
        downloadFailedIDs.removeAll()
        uploadConfig = .defaultValue
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

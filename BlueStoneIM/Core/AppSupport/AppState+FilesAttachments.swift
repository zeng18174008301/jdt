import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

// MARK: - Files and Attachments

extension AppState {
    func files(for groupID: String) -> [FileItem] {
        fileStore.files(for: groupID)
    }

    func isGroupFileSyncing(groupID: String) -> Bool {
        fileStore.isGroupSyncing(groupID: groupID)
    }

    func groupFileSyncError(groupID: String) -> String? {
        fileStore.groupSyncError(groupID: groupID)
    }

    @discardableResult
    func refreshTenantFilesPage(silent: Bool = false, query: String = "", category: String = "", limit: Int = 100, offset: Int = 0, append: Bool = false) async -> Int {
        await refreshTenantFilesSnapshot(
            silent: silent,
            query: query,
            category: category,
            limit: limit,
            offset: offset,
            append: append
        )
    }

    @discardableResult
    func refreshFavoriteAssetsPage(
        silent: Bool = false,
        category: FavoriteAssetCategory = .all,
        limit: Int = 30,
        cursor: String = "",
        append: Bool = false
    ) async -> FavoriteAssetsPageResult {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession, isCurrentRemoteScope(scope) else {
            if !silent {
                toast = "登录会话不可用，请重新登录"
            }
            return .empty
        }
        let request = favoriteAssetsCollection.begin(
            scope: scope,
            category: category,
            cursor: cursor
        )
        favoriteAssets = favoriteAssetsCollection.activeItems
        isFavoriteAssetsSyncing = true
        favoriteAssetsSyncErrorMessage = nil
        defer {
            if favoriteAssetsCollection.isCurrent(request) {
                _ = favoriteAssetsCollection.fail(request: request)
                isFavoriteAssetsSyncing = false
            }
        }
        do {
            let response = try await api.listFavoriteAssets(
                context: context,
                category: category.requestValue,
                limit: limit,
                cursor: cursor
            )
            guard isCurrentRemoteScope(scope),
                  favoriteAssetsCollection.isCurrent(request) else {
                return .empty
            }
            let mapped = response.items
                .map(favoriteAssetItem(from:))
                .filter(isFavoriteAssetVisibleAfterHistoryBoundary)
            guard favoriteAssetsCollection.apply(
                items: mapped,
                append: append,
                request: request
            ) else { return .empty }
            favoriteAssets = favoriteAssetsCollection.activeItems
            isFavoriteAssetsSyncing = false
            favoriteAssetsSyncErrorMessage = nil
            return FavoriteAssetsPageResult(
                fetchedCount: mapped.count,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore,
                didSucceed: true
            )
        } catch {
            guard isCurrentRemoteScope(scope),
                  favoriteAssetsCollection.fail(request: request) else {
                return .empty
            }
            favoriteAssets = favoriteAssetsCollection.activeItems
            isFavoriteAssetsSyncing = false
            logSyncEndpointFailure("/api/im/favorites/list", error: error)
            favoriteAssetsSyncErrorMessage = favoriteAssets.isEmpty
                ? "收藏资料加载失败，请稍后重试"
                : "收藏资料加载失败，当前显示上次缓存"
            if isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "收藏资料加载失败", silent: silent)
            } else if !silent {
                handleRemoteError(error, fallback: "收藏资料加载失败")
            }
            return .empty
        }
    }

    @discardableResult
    func setMessageFavorite(messageID: String, favorited: Bool, showToast: Bool = true) async -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty else { return false }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            if showToast {
                toast = "登录会话不可用，请重新登录"
            }
            return false
        }
        do {
            try await api.favoriteMessage(context: context, messageID: normalizedMessageID, favorited: favorited)
            guard isCurrentRemoteScope(scope) else { return false }
            applyLoadedMessageFavoriteState(messageID: normalizedMessageID, favorited: favorited)
            if !favorited {
                favoriteAssetsCollection.remove(scope: scope) {
                    $0.messageID == normalizedMessageID
                }
                favoriteAssets = favoriteAssetsCollection.activeItems
            }
            if showToast {
                toast = favorited ? "已收藏资料" : "已取消收藏"
            }
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            if shouldShowGroupHistoryLimitedMessage(for: error, messageID: normalizedMessageID) {
                if showToast {
                    toast = groupHistoryLimitedMessage
                }
                return false
            }
            handleRemoteError(error, fallback: favorited ? "收藏失败" : "取消收藏失败")
            return false
        }
    }

    @discardableResult
    func cancelFavoriteAsset(_ item: FavoriteAssetItem) async -> Bool {
        await setMessageFavorite(messageID: item.messageID, favorited: false)
    }

    private func applyLoadedMessageFavoriteState(messageID: String, favorited: Bool) {
        for conversation in conversations {
            conversationStore.setMessageFavorited(messageID: messageID, conversationID: conversation.id, favorited: favorited)
        }
    }

    func syncAttachmentFilesFromConversation(_ conversation: Conversation) {
        let fileItems = attachmentFileItems(from: [conversation])
        guard !fileItems.isEmpty else { return }
        for fileItem in fileItems {
            upsertTenantFile(fileItem)
        }
    }

    func syncAttachmentFilesFromConversations(_ conversations: [Conversation]) {
        let fileItems = attachmentFileItems(from: conversations)
        guard !fileItems.isEmpty else { return }
        for fileItem in fileItems {
            upsertTenantFile(fileItem)
        }
    }

    func refreshFileUploadConfig(silent: Bool = true) {
        let context = apiContext
        guard context.hasIMSession else {
            if !silent {
                toast = "登录会话不可用，请重新登录"
            }
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                _ = try await currentFileUploadConfig(context: context, scope: scope)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if !silent {
                    handleRemoteError(error, fallback: "文件上传配置同步失败")
                }
            }
        }
    }

    func currentFileUploadConfig() async throws -> FileUploadConfig {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        return try await currentFileUploadConfig(context: context, scope: scope)
    }

    func currentFileUploadConfig(context: IMAPIContext, scope: String) async throws -> FileUploadConfig {
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else {
            throw CancellationError()
        }
        return try await fetchScopedFileUploadConfig(context: context, scope: scope).model
    }

    // All existing config consumers share the same authority and its existing
    // capability generations, including requests straddling an A -> B -> A switch.
    func fetchScopedFileUploadConfig(context: IMAPIContext, scope: String) async throws -> RemoteFileUploadConfig {
        let binding = DirectCallContextBinding(context: context)
        let voiceGeneration = callLicenseActionGeneration(for: .voice)
        let videoGeneration = callLicenseActionGeneration(for: .video)
        func isCurrent() -> Bool {
            isCurrentRemoteScope(scope)
                && DirectCallContextBinding(context: apiContext) == binding
                && callLicenseActionGeneration(for: .voice) == voiceGeneration
                && callLicenseActionGeneration(for: .video) == videoGeneration
        }
        guard isCurrent() else { throw CancellationError() }
        do {
            let remote = try await api.fileUploadConfig(context: context)
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
            applyFileUploadConfig(remote.model)
            return remote
        } catch {
            guard isCurrent() else { throw CancellationError() }
            if !(error is CancellationError) {
                authoritativeCallLicenseScopeKey = nil
                if currentDirectCallAttempt(for: .voice) != nil {
                    _ = guardCallLicenseForAction(.voice)
                }
                if let attempt = currentDirectCallAttempt(for: .video) {
                    _ = guardCallLicenseForAction(attempt.mediaMode == "audio" ? .voice : .video)
                } else if videoCallPreview != nil {
                    _ = guardCallLicenseForAction(.video)
                }
                advanceDirectCallCapabilityGeneration(for: .voice, reason: "call_license_unavailable")
                advanceDirectCallCapabilityGeneration(for: .video, reason: "call_license_unavailable")
            }
            throw error
        }
    }

    func handleSplashConfiguration(
        _ configuration: RemoteSplashConfiguration,
        context: IMAPIContext,
        scope: String,
        source: String,
        splashScope: SplashTenantScope,
        intent: SplashPresentationIntent,
        refreshGeneration: Int,
        deadline: Date?
    ) {
        guard isCurrentRemoteScope(scope) else {
            return
        }
        guard splashTenantScope(for: apiContext) == splashScope else {
            return
        }
        guard isCurrentSplashRefresh(
            generation: refreshGeneration,
            scope: splashScope,
            remoteScope: scope
        ) else {
            return
        }
        let tenantID = splashScope.tenantID
        let resolvedImageURL = configuration.imageURL.isEmpty
            ? ""
            : resolveTenantAssetURL(configuration.imageURL, context: context)
        let snapshot = configuration.makeSnapshot(
            tenantID: tenantID,
            resolvedImageURL: resolvedImageURL,
            fetchedAt: Date()
        )
        SplashSnapshotStore.saveSnapshot(snapshot, scope: splashScope)

        if !snapshot.isConfigDisplayable {
            let reason = snapshot.disabledReason.isEmpty ? "config_not_displayable" : snapshot.disabledReason
            SplashSnapshotStore.disableSnapshot(scope: splashScope, reason: reason)
            finishSplashPresentationIntent(
                intent,
                result: .blockedByPolicy(reason),
                trigger: source,
                deadline: deadline
            )
            print("[JHT Splash] snapshot_disabled tenant=\(tenantID) reason=\(reason) source=\(source)")
            return
        }
        guard let candidate = SplashRefreshCandidate(
            generation: refreshGeneration,
            scope: splashScope,
            snapshot: snapshot
        ) else {
            SplashSnapshotStore.disableSnapshot(scope: splashScope, reason: "missing_cache_key")
            finishSplashPresentationIntent(
                intent,
                result: .blockedByPolicy("missing_cache_key"),
                trigger: source,
                deadline: deadline
            )
            print("[JHT Splash] snapshot_disabled tenant=\(tenantID) reason=missing_cache_key source=\(source)")
            return
        }
        prefetchSplashImage(
            snapshot: snapshot,
            candidate: candidate,
            remoteScope: scope,
            source: source,
            intent: intent,
            deadline: deadline
        )
    }

    private func prefetchSplashImage(
        snapshot: SplashConfigSnapshot,
        candidate: SplashRefreshCandidate,
        remoteScope: String,
        source: String,
        intent: SplashPresentationIntent,
        deadline: Date?
    ) {
        Task { [snapshot, candidate, remoteScope, source, intent, deadline] in
            let result = await SplashImageDiskCache.shared.prepareImage(
                from: snapshot.imageURL,
                cacheKey: candidate.cacheKey,
                expectedSHA256: snapshot.sha256,
                expectedSizeBytes: snapshot.sizeBytes,
                expectedMimeType: snapshot.mimeType,
                expectedWidth: snapshot.width,
                expectedHeight: snapshot.height
            )
            guard self.isCurrentSplashRefresh(
                generation: candidate.generation,
                scope: candidate.scope,
                remoteScope: remoteScope
            ),
            candidate.matches(
                currentGeneration: self.splashConfigurationRefreshGeneration.currentToken(),
                currentScope: self.splashTenantScope(for: self.apiContext),
                snapshot: SplashSnapshotStore.snapshot(scope: candidate.scope)
            ) else {
                return
            }
            let error = result.status == .failed
                ? result.validationFailure?.rawValue ?? "download_failed"
                : ""
            guard SplashSnapshotStore.updatePrefetchStatus(
                candidate: candidate,
                status: result.status,
                error: error
            ) else {
                return
            }
            print("[JHT Splash] prefetch_result tenant=\(snapshot.tenantID) status=\(result.status.rawValue) key=\(candidate.cacheKey) source=\(source)")
            if (result.status == .cached || result.status == .downloaded),
               let preparedImage = result.preparedImage {
                self.presentSplashIfAllowed(
                    intent: intent,
                    candidate: candidate,
                    preparedImage: preparedImage,
                    remoteScope: remoteScope,
                    trigger: "splash_prefetch_ready_\(source)",
                    deadline: deadline
                )
            } else {
                self.finishSplashPresentationIntent(
                    intent,
                    result: .blockedByPolicy("prefetch_failed"),
                    trigger: source,
                    deadline: deadline
                )
            }
        }
    }

    func refreshGroupFiles(groupID: String, silent: Bool = false) {
        Task { await refreshGroupFilesSnapshot(groupID: groupID, silent: silent) }
    }

    func openTenantFile(_ file: FileItem, preview: Bool) {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            if preview {
                guard await authorizeProtectedAccess(.filePreview) else { return }
            }
            do {
                let detail = try await api.getTenantFile(context: context, fileID: file.id)
                guard isCurrentRemoteScope(scope) else { return }
                let refreshedFile = fileItem(from: detail, fallback: file)
                upsertTenantFile(refreshedFile)
                let isAvailable = preview ? refreshedFile.previewAvailable : refreshedFile.downloadAvailable
                let urlValue = preview ? refreshedFile.previewURL : refreshedFile.downloadURL
                let resolvedURLValue = resolveTenantAssetURL(urlValue)
                guard isAvailable,
                      let url = URL(string: resolvedURLValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    toast = preview ? "当前文件暂不支持预览" : "当前文件暂不支持下载"
                    return
                }
                UIApplication.shared.open(url) { [weak self] success in
                    guard !success else { return }
                    Task { @MainActor in
                        guard self?.isCurrentRemoteScope(scope) == true else { return }
                        self?.toast = "无法打开文件链接，请稍后重试"
                    }
                }
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if shouldShowGroupHistoryLimitedMessage(for: error, file: file) {
                    toast = groupHistoryLimitedMessage
                    return
                }
                handleRemoteError(error, fallback: preview ? "文件预览失败" : "文件下载失败")
            }
        }
    }

    func refreshTenantFile(_ file: FileItem) async throws -> FileItem {
        let context = apiContext
        guard context.hasIMSession else {
            throw IMAPIError.missingContext("登录会话不可用，请重新登录")
        }
        let fileID = file.remoteLookupID
        guard !fileID.isEmpty else { return file }
        let scope = remoteDataScopeKey(for: context)
        let detail = try await api.getTenantFile(context: context, fileID: fileID)
        guard isCurrentRemoteScope(scope) else {
            throw CancellationError()
        }
        let refreshedFile = fileItem(from: detail, fallback: file)
        upsertTenantFile(refreshedFile)
        return refreshedFile
    }

    func fileItemForSearchResult(fileID: String, fallbackName: String) async -> FileItem? {
        let trimmedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFileID.isEmpty else { return nil }
        if let existing = files.first(where: { file in
            file.id == trimmedFileID || file.remoteFileID == trimmedFileID || file.remoteLookupID == trimmedFileID
        }) {
            do {
                return try await refreshTenantFile(existing)
            } catch {
                handleRemoteError(error, fallback: "文件详情加载失败")
                return existing
            }
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        let fallback = FileItem(
            id: trimmedFileID,
            name: fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名文件" : fallbackName,
            type: "文件",
            size: "未知大小",
            owner: "",
            source: "搜索结果",
            time: "",
            scope: "",
            status: "正在加载",
            accentHex: stableSeed(trimmedFileID),
            remoteFileID: trimmedFileID
        )
        do {
            let detail = try await api.getTenantFile(context: context, fileID: trimmedFileID)
            guard isCurrentRemoteScope(scope) else { return nil }
            let file = fileItem(from: detail, fallback: fallback)
            upsertTenantFile(file)
            return file
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            handleRemoteError(error, fallback: "文件详情加载失败")
            return nil
        }
    }

    func resolveTenantFileURL(_ file: FileItem, preview: Bool) async throws -> (file: FileItem, url: URL) {
        let refreshedFile = try await refreshTenantFile(file)
        let isAvailable = preview ? refreshedFile.previewAvailable : refreshedFile.downloadAvailable
        let urlValue = preview ? refreshedFile.previewURL : refreshedFile.downloadURL
        let resolvedURLValue = resolveTenantAssetURL(urlValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, let url = URL(string: resolvedURLValue) else {
            throw IMAPIError.server(preview ? "当前文件暂不支持预览" : "当前文件暂不支持下载")
        }
        return (refreshedFile, url)
    }

    func resolvedAttachmentPreviewURL(for message: ChatMessage) -> URL? {
        if let localURL = cachedLocalAttachmentURL(for: message, preferPreview: true) {
            return localURL
        }
        let preview = message.attachmentPreviewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachmentPreviewAllowed(
            previewURL: preview,
            previewKind: message.attachmentPreviewKind,
            contentDisposition: message.attachmentContentDisposition,
            backendAvailable: message.attachmentPreviewAvailable
        ) {
            return resolvedAttachmentURL(preview)
        }
        let category = attachmentMediaCategory(for: message)
        let download = message.attachmentDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.attachmentContentDisposition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ["image", "video", "pdf"].contains(category),
           !download.isEmpty {
            return resolvedAttachmentURL(download)
        }
        return nil
    }

    func resolvedAttachmentDownloadURL(for message: ChatMessage) -> URL? {
        if let localURL = cachedLocalAttachmentURL(for: message, preferPreview: false) {
            return localURL
        }
        return resolvedAttachmentURL(message.attachmentDownloadURL.isEmpty ? message.attachmentPreviewURL : message.attachmentDownloadURL)
    }

    func resolvedAttachmentThumbnailURL(for message: ChatMessage) -> URL? {
        if let localThumbnail = cachedLocalAttachmentThumbnailURL(for: message) {
            return localThumbnail
        }
        let explicit = [
            message.attachmentThumbnailURL,
            message.attachmentCoverURL,
            message.attachmentPosterURL
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let explicit, let url = resolvedAttachmentURL(explicit) {
            return url
        }
        let category = attachmentMediaCategory(for: message)
        if category == "image" {
            return resolvedAttachmentPreviewURL(for: message) ?? resolvedAttachmentDownloadURL(for: message)
        }
        if category == "video" {
            return resolvedAttachmentPreviewURL(for: message)
        }
        return nil
    }

    func resolvedAttachmentBestPreviewURL(for message: ChatMessage) -> URL? {
        resolvedAttachmentPreviewURL(for: message)
    }

    func attachmentCanRefreshRemoteFile(_ message: ChatMessage) -> Bool {
        let fileID = tenantFileID(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
        return !fileID.isEmpty
    }

    func attachmentThumbnailCacheKey(for message: ChatMessage) -> String {
        let mediaCategory = attachmentMediaCategory(for: message)
        let fallbackExtension = attachmentFileExtension(for: message, remoteURL: resolvedAttachmentThumbnailURL(for: message), mediaCategory: mediaCategory)
        if let stableIdentity = attachmentStableCacheIdentity(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension) {
            return "thumbnail|\(stableIdentity)"
        }
        let fileID = message.attachmentFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let primaryID = fileID.isEmpty ? message.id : fileID
        let size = message.attachmentSizeBytes.map(String.init) ?? "unknown-size"
        let scopedIdentity = scopedContentCacheIdentity([
            primaryID,
            size,
            mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ])
        return "thumbnail|\(scopedIdentity)"
    }

    func attachmentMediaCategory(for message: ChatMessage) -> String {
        if message.kind == .voice {
            return "voice"
        }
        let explicit = message.attachmentMediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !explicit.isEmpty { return explicit }
        let previewKind = message.attachmentPreviewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["image", "video", "pdf", "audio", "voice", "download"].contains(previewKind), previewKind != "download" {
            return previewKind
        }
        return inferredAttachmentMediaCategory(kind: message.kind, name: message.attachmentName ?? message.text, mimeType: attachmentMimeType(from: message))
    }

    func attachmentTransferProgress(for message: ChatMessage) -> Double? {
        let progressKey = attachmentProgressKey(for: message)
        if isAttachmentUploadInProgress(message) {
            return message.attachmentTransferProgress
                ?? fileStore.attachmentDownloadProgress(attachmentID: progressKey)
                ?? fileStore.attachmentDownloadProgress(attachmentID: message.id)
        }
        guard fileStore.hasAttachmentDownloadTask(attachmentID: progressKey) else { return nil }
        return fileStore.attachmentDownloadProgress(attachmentID: progressKey)
    }

    func isAttachmentUploadInProgress(_ message: ChatMessage) -> Bool {
        if message.status == .sending { return true }
        if fileStore.hasAttachmentUploadRuntimeState(messageID: message.id) { return true }
        let status = message.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["queued", "retrying", "uploading", "processing", "pending", "in_progress"].contains(status)
    }

    func attachmentProgressKey(for message: ChatMessage) -> String {
        let fileID = message.attachmentFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fileID.isEmpty ? message.id : fileID
    }

    private func resolvedAttachmentURL(_ rawValue: String) -> URL? {
        guard !isTenantFileAPIEndpoint(rawValue) else { return nil }
        let resolved = resolveTenantAssetURL(rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return nil }
        guard !isTenantFileAPIEndpoint(resolved) else { return nil }
        return URL(string: resolved)
    }

    func isTenantFileAPIEndpoint(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "/api/tenant/files" || trimmed.hasPrefix("/api/tenant/files/") {
            return true
        }
        guard let url = URL(string: trimmed) else { return false }
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path == "/api/tenant/files" || path.hasPrefix("/api/tenant/files/")
    }

    func attachmentDownloadFailed(_ message: ChatMessage) -> Bool {
        fileStore.isAttachmentDownloadFailed(attachmentID: attachmentProgressKey(for: message))
    }

    func isMessageAttachmentDownloaded(_ message: ChatMessage, preferPreview: Bool = false) -> Bool {
        cachedLocalAttachmentURL(for: message, preferPreview: preferPreview) != nil
    }

    func cancelAttachmentDownload(_ message: ChatMessage) {
        let attachmentID = attachmentProgressKey(for: message)
        fileStore.cancelAttachmentDownloadTask(attachmentID: attachmentID)
        fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
        toast = "已取消下载"
    }

    func isVoiceMessagePlaying(_ message: ChatMessage) -> Bool {
        playingVoiceMessageID == message.id
    }

    func voicePlaybackState(for message: ChatMessage) -> VoiceMessagePlaybackState? {
        guard voiceMessagePlaybackState?.messageID == message.id else { return nil }
        return voiceMessagePlaybackState
    }

    func toggleVoiceMessagePlayback(_ message: ChatMessage, conversationID: String) {
        guard message.kind == .voice else { return }
        if voiceMessagePlayerMessageID == message.id, let player = voiceMessagePlayer {
            guard let durationMS = voicePlayerDurationMS(player) else {
                clearVoiceMessagePlayback()
                toast = "语音播放失败，请重试"
                return
            }
            if player.isPlaying {
                player.pause()
                playingVoiceMessageID = nil
                voiceMessagePlaybackTimer?.invalidate()
                voiceMessagePlaybackTimer = nil
                updateVoiceMessagePlaybackState(
                    messageID: message.id,
                    elapsedMS: Int((player.currentTime * 1_000).rounded()),
                    durationMS: durationMS,
                    isPlaying: false
                )
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            } else {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    guard player.play() else {
                        throw IMAPIError.server("语音播放启动失败")
                    }
                    playingVoiceMessageID = message.id
                    updateVoiceMessagePlaybackState(
                        messageID: message.id,
                        elapsedMS: Int((player.currentTime * 1_000).rounded()),
                        durationMS: durationMS,
                        isPlaying: true
                    )
                    startVoiceMessagePlaybackProgressTimer(
                        messageID: message.id,
                        generation: voiceMessagePlaybackGeneration
                    )
                } catch {
                    clearVoiceMessagePlayback()
                    toast = "语音播放失败，请重试"
                }
            }
            return
        }
        if voiceMessagePlayerMessageID == message.id {
            stopVoiceMessagePlayback()
            return
        }
        stopVoiceMessagePlayback()
        let requestID = message.id
        voiceMessagePlaybackGeneration &+= 1
        let generation = voiceMessagePlaybackGeneration
        voiceMessagePlayerMessageID = requestID
        playingVoiceMessageID = nil
        updateVoiceMessagePlaybackState(
            messageID: requestID,
            elapsedMS: 0,
            durationMS: estimatedVoiceMessageDurationMS(message),
            isPlaying: false
        )
        Task { [weak self] in
            do {
                guard let self else { return }
                let localURL = try await self.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                guard self.voiceMessagePlayerMessageID == requestID,
                      self.voiceMessagePlaybackGeneration == generation else { return }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(contentsOf: localURL)
                guard player.prepareToPlay(),
                      let durationMS = self.voicePlayerDurationMS(player) else {
                    throw IMAPIError.server("语音解码失败")
                }
                let delegate = VoiceMessageAudioPlayerDelegate()
                delegate.didFinish = { [weak self] finishedPlayerID, succeeded in
                    guard let self,
                          self.voiceMessagePlaybackGeneration == generation,
                          let activePlayer = self.voiceMessagePlayer,
                          ObjectIdentifier(activePlayer) == finishedPlayerID,
                          let actualDurationMS = self.voicePlayerDurationMS(activePlayer) else {
                        return
                    }
                    self.updateVoiceMessagePlaybackState(
                        messageID: requestID,
                        elapsedMS: actualDurationMS,
                        durationMS: actualDurationMS,
                        isPlaying: false
                    )
                    self.clearVoiceMessagePlayback(
                        expectedGeneration: generation,
                        preservePlaybackState: succeeded
                    )
                    if !succeeded {
                        self.toast = "语音播放失败，请重试"
                    }
                }
                delegate.didFailToDecode = { [weak self] failedPlayerID in
                    guard let self,
                          self.voiceMessagePlaybackGeneration == generation,
                          let activePlayer = self.voiceMessagePlayer,
                          ObjectIdentifier(activePlayer) == failedPlayerID else {
                        return
                    }
                    self.clearVoiceMessagePlayback(expectedGeneration: generation)
                    self.toast = "语音播放失败，请重试"
                }
                player.delegate = delegate
                self.voiceMessagePlayerDelegate = delegate
                self.voiceMessagePlayer = player
                guard player.play() else {
                    throw IMAPIError.server("语音播放启动失败")
                }
                self.playingVoiceMessageID = requestID
                self.updateVoiceMessagePlaybackState(
                    messageID: requestID,
                    elapsedMS: 0,
                    durationMS: durationMS,
                    isPlaying: true
                )
                self.startVoiceMessagePlaybackProgressTimer(messageID: requestID, generation: generation)
            } catch is CancellationError {
                if self?.voiceMessagePlayerMessageID == requestID,
                   self?.voiceMessagePlaybackGeneration == generation {
                    self?.clearVoiceMessagePlayback(expectedGeneration: generation)
                }
            } catch {
                if self?.voiceMessagePlayerMessageID == requestID,
                   self?.voiceMessagePlaybackGeneration == generation {
                    self?.clearVoiceMessagePlayback(expectedGeneration: generation)
                    self?.toast = "语音播放失败，请重试"
                }
            }
        }
    }

    func stopVoiceMessagePlayback(ifPlaying messageID: String? = nil) {
        if let messageID, voiceMessagePlayerMessageID != messageID { return }
        stopVoiceMessagePlayback()
    }

    func stopVoiceMessagePlayback() {
        clearVoiceMessagePlayback()
    }

    private func clearVoiceMessagePlayback(
        expectedGeneration: UInt64? = nil,
        preservePlaybackState: Bool = false
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.clearVoiceMessagePlayback(
                    expectedGeneration: expectedGeneration,
                    preservePlaybackState: preservePlaybackState
                )
            }
            return
        }
        if let expectedGeneration,
           voiceMessagePlaybackGeneration != expectedGeneration {
            return
        }
        voiceMessagePlaybackGeneration &+= 1
        voiceMessagePlaybackTimer?.invalidate()
        voiceMessagePlaybackTimer = nil
        voiceMessagePlayer?.stop()
        voiceMessagePlayer = nil
        voiceMessagePlayerDelegate = nil
        voiceMessagePlayerMessageID = nil
        playingVoiceMessageID = nil
        if !preservePlaybackState {
            voiceMessagePlaybackState = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startVoiceMessagePlaybackProgressTimer(messageID: String, generation: UInt64) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startVoiceMessagePlaybackProgressTimer(messageID: messageID, generation: generation)
            }
            return
        }
        voiceMessagePlaybackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVoiceMessagePlaybackProgress(messageID: messageID, generation: generation)
            }
        }
        voiceMessagePlaybackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshVoiceMessagePlaybackProgress(messageID: String, generation: UInt64) {
        guard voiceMessagePlaybackGeneration == generation,
              voiceMessagePlayerMessageID == messageID,
              let player = voiceMessagePlayer else {
            clearVoiceMessagePlayback(expectedGeneration: generation)
            return
        }
        guard let durationMS = voicePlayerDurationMS(player) else {
            clearVoiceMessagePlayback(expectedGeneration: generation)
            toast = "语音播放失败，请重试"
            return
        }
        let elapsedMS = min(durationMS, max(0, Int((player.currentTime * 1_000).rounded())))
        updateVoiceMessagePlaybackState(
            messageID: messageID,
            elapsedMS: elapsedMS,
            durationMS: durationMS,
            isPlaying: player.isPlaying
        )
        guard !player.isPlaying else { return }
        voiceMessagePlaybackTimer?.invalidate()
        voiceMessagePlaybackTimer = nil
        if elapsedMS >= durationMS {
            clearVoiceMessagePlayback(expectedGeneration: generation, preservePlaybackState: true)
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func updateVoiceMessagePlaybackState(
        messageID: String,
        elapsedMS: Int,
        durationMS: Int,
        isPlaying: Bool
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateVoiceMessagePlaybackState(
                    messageID: messageID,
                    elapsedMS: elapsedMS,
                    durationMS: durationMS,
                    isPlaying: isPlaying
                )
            }
            return
        }
        voiceMessagePlaybackState = VoiceMessagePlaybackState(
            messageID: messageID,
            elapsedMS: elapsedMS,
            durationMS: max(1, VoiceMessagePayload.normalizedDurationMS(durationMS)),
            isPlaying: isPlaying
        )
    }

    private func estimatedVoiceMessageDurationMS(_ message: ChatMessage) -> Int {
        if let seconds = message.attachmentDurationSeconds, seconds > 0 {
            return VoiceMessagePayload.normalizedDurationMS(Int((seconds * 1_000).rounded()))
        }
        return VoiceMessagePayload.minDurationMS
    }

    private func voicePlayerDurationMS(_ player: AVAudioPlayer) -> Int? {
        VoiceMessagePayload.decodedDurationMS(player.duration)
    }

    func prepareMessageAttachmentLocalFile(_ message: ChatMessage, conversationID: String, preferPreview: Bool = false) async throws -> URL {
        let context = apiContext
        guard context.hasIMSession else {
            throw IMAPIError.missingContext("登录会话不可用，请重新登录")
        }
        let scope = remoteDataScopeKey(for: context)
        let attachmentID = attachmentProgressKey(for: message)
        if let task = fileStore.attachmentDownloadTask(attachmentID: attachmentID) {
            return try await task.value
        }
        if let cacheContext = mediaCacheScopeContext,
           let localURL = await cachedUnifiedAttachmentURL(
            for: message,
            preferPreview: preferPreview,
            context: cacheContext,
            offline: true
           ) {
            return localURL
        }

        fileStore.clearAttachmentDownloadFailed(attachmentID: attachmentID)
        fileStore.setAttachmentDownloadProgress(0.02, attachmentID: attachmentID)

        do {
            let targetMessage = try await refreshedAttachmentMessage(message, in: conversationID, context: context, scope: scope)
            guard let cacheContext = mediaCacheScopeContext,
                  cacheContext.sessionGeneration == localMessageSessionGeneration else {
                throw LocalMessageDatabaseError.staleSession
            }
            let cachedURL = await cachedUnifiedAttachmentURL(
                for: targetMessage,
                preferPreview: preferPreview,
                context: cacheContext,
                offline: false
            )
            let authorizedLegacyURL: URL?
            if cachedURL == nil {
                authorizedLegacyURL = await migrateAuthorizedLegacyAttachmentIfPossible(
                    targetMessage,
                    preferPreview: preferPreview,
                    conversationID: conversationID,
                    context: cacheContext
                )
            } else {
                authorizedLegacyURL = nil
            }
            if let localURL = cachedURL ?? authorizedLegacyURL {
                guard isCurrentRemoteScope(scope) else {
                    fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
                    throw CancellationError()
                }
                fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
                return localURL
            }
            let url = attachmentRemoteURL(for: targetMessage, preferPreview: preferPreview)
            guard let url else {
                fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
                throw AttachmentDownloadError.missingURL
            }

            let suggestedName = targetMessage.attachmentName ?? message.attachmentName ?? message.text
            let mediaCategory = attachmentMediaCategory(for: targetMessage)
            let fallbackExtension = attachmentFileExtension(for: targetMessage, remoteURL: url, mediaCategory: mediaCategory)
            let cacheKey = attachmentPersistentCacheKey(for: targetMessage, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension)
            let task = Task<URL, Error> { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                let temporaryURL = try await MediaSignedURLRecovery.perform(
                    initialURL: url,
                    refreshURL: {
                        let refreshedMessage = try await self.refreshedAttachmentMessage(
                            targetMessage,
                            in: conversationID,
                            context: context,
                            scope: scope
                        )
                        guard let refreshedURL = self.attachmentRemoteURL(
                            for: refreshedMessage,
                            preferPreview: preferPreview
                        ) else {
                            throw AttachmentDownloadError.missingURL
                        }
                        return refreshedURL
                    },
                    operation: { remoteURL in
                        // JHT_MOD_BEGIN ATTACHMENT_DOWNLOAD_NON_MAIN_PERF_20260912 - 修改开始：下载请求体离开 MainActor 执行，主线程只接收进度状态更新
                        let sessionFactory = self.attachmentDownloadSessionFactory
                        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
                            Task { @MainActor [weak self] in
                                self?.fileStore.setAttachmentDownloadProgress(fraction, attachmentID: attachmentID)
                            }
                        }
                        return try await AttachmentDownloadExecutor.temporaryFile(
                            remoteURL: remoteURL,
                            suggestedName: suggestedName,
                            cacheKey: cacheKey,
                            fallbackExtension: fallbackExtension,
                            expectedSizeBytes: targetMessage.attachmentSizeBytes ?? message.attachmentSizeBytes,
                            sessionFactory: sessionFactory,
                            progress: progress
                        )
                        // JHT_MOD_END ATTACHMENT_DOWNLOAD_NON_MAIN_PERF_20260912 - 修改结束
                    }
                )
                return try await self.commitUnifiedAttachment(
                    temporaryURL,
                    message: targetMessage,
                    preferPreview: preferPreview,
                    conversationID: conversationID,
                    context: cacheContext
                )
            }
            fileStore.replaceAttachmentDownloadTask(attachmentID: attachmentID, with: task)
            let localURL = try await task.value
            guard isCurrentRemoteScope(scope) else {
                fileStore.finishAttachmentDownloadTask(attachmentID: attachmentID)
                fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
                throw CancellationError()
            }
            // JHT_MOD_BEGIN ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：下载完成后的图片尺寸/视频缩略图生成移出 MainActor
            let resources = await AttachmentPreviewResourceBuilder.downloadedPreviewResourcesOffMain(
                messageID: targetMessage.id,
                localURL: localURL,
                mediaCategory: mediaCategory
            )
            if let resources {
                cacheLocalAttachmentResources(
                    resources,
                    messageID: targetMessage.id,
                    fileID: targetMessage.attachmentFileID,
                    cacheIdentity: attachmentStableCacheIdentity(for: targetMessage, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension)
                )
            }
            // JHT_MOD_END ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束
            fileStore.finishAttachmentDownloadTask(attachmentID: attachmentID)
            fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
            return localURL
        } catch is CancellationError {
            fileStore.finishAttachmentDownloadTask(attachmentID: attachmentID)
            fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
            throw CancellationError()
        } catch {
            fileStore.finishAttachmentDownloadTask(attachmentID: attachmentID)
            fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
            fileStore.markAttachmentDownloadFailed(attachmentID: attachmentID)
            throw error
        }
    }

    private func cachedUnifiedAttachmentURL(
        for message: ChatMessage,
        preferPreview: Bool,
        context: IOSMediaCacheScopeContext,
        offline: Bool
    ) async -> URL? {
        let metadata = unifiedAttachmentMetadata(for: message, context: context)
        let resourceKind: MediaResourceKind = preferPreview ? .preview : .original
        return await lookupIndexedMediaCache(
            metadata: metadata,
            messageID: message.id,
            resourceKind: resourceKind,
            integrity: unifiedAttachmentIntegrity(for: message, resourceKind: resourceKind),
            context: context,
            offline: offline
        )
    }

    func cachedUnifiedAttachmentThumbnailURL(
        for message: ChatMessage,
        offline: Bool = true
    ) async -> URL? {
        guard let context = mediaCacheScopeContext else { return nil }
        let variant: MediaCacheVariant = attachmentMediaCategory(for: message) == "video"
            ? .videoPoster
            : .thumbnail640
        return await lookupIndexedMediaCache(
            metadata: unifiedAttachmentMetadata(for: message, context: context),
            messageID: message.id,
            resourceKind: .thumbnail,
            variant: variant,
            integrity: MediaFileIntegrityAuthority(),
            context: context,
            offline: offline
        )
    }

    func cacheUnifiedAttachmentThumbnail(
        _ data: Data,
        for message: ChatMessage,
        conversationID: String
    ) async -> URL? {
        guard !data.isEmpty, let context = mediaCacheScopeContext else { return nil }
        let variant: MediaCacheVariant = attachmentMediaCategory(for: message) == "video"
            ? .videoPoster
            : .thumbnail640
        // JHT_MOD_BEGIN ATTACHMENT_THUMBNAIL_CACHE_IO_PERF_20260912 - 修改开始：缩略图临时文件写入/清理由后台 support helper 执行
        var temporaryURL: URL?
        do {
            let stagedURL = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(data)
            temporaryURL = stagedURL
            let committed = try await commitIndexedMediaCache(
                temporaryURL: stagedURL,
                metadata: unifiedAttachmentMetadata(for: message, context: context),
                resourceKind: .thumbnail,
                variant: variant,
                integrity: MediaFileIntegrityAuthority(),
                messageID: message.id,
                conversationID: conversationID,
                authorityVersion: "0",
                context: context
            )
            await AttachmentTemporaryFileWriter.removeTemporaryFileOffMain(stagedURL)
            return committed
        } catch {
            if let temporaryURL {
                await AttachmentTemporaryFileWriter.removeTemporaryFileOffMain(temporaryURL)
            }
            return nil
        }
        // JHT_MOD_END ATTACHMENT_THUMBNAIL_CACHE_IO_PERF_20260912 - 修改结束
    }

    private func migrateAuthorizedLegacyAttachmentIfPossible(
        _ message: ChatMessage,
        preferPreview: Bool,
        conversationID: String,
        context: IOSMediaCacheScopeContext
    ) async -> URL? {
        guard !preferPreview,
              context.sessionGeneration == localMessageSessionGeneration,
              !tenantFileID(for: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !message.attachmentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let integrity = unifiedAttachmentIntegrity(for: message, resourceKind: .original)
        guard integrity.hasChecksum else { return nil }
        let mediaCategory = attachmentMediaCategory(for: message)
        let fallbackExtension = attachmentFileExtension(for: message, remoteURL: nil, mediaCategory: mediaCategory)
        let cacheKey = attachmentPersistentCacheKey(
            for: message,
            mediaCategory: mediaCategory,
            fallbackExtension: fallbackExtension
        )
        let suggestedName = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredLegacyURL = try? AttachmentDownloadCachePolicy.destinationURL(
            remoteURL: nil,
            suggestedName: suggestedName,
            cacheKey: cacheKey,
            fallbackExtension: fallbackExtension
        )
        var candidates = preferredLegacyURL.map { [$0] } ?? []
        candidates.append(contentsOf: AttachmentDownloadCachePolicy.legacyCandidateURLs().filter {
            $0.standardizedFileURL != preferredLegacyURL?.standardizedFileURL
        })
        // JHT_MOD_BEGIN ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改开始：legacy 候选文件完整性校验离开 MainActor
        guard let legacyURL = await AttachmentTemporaryFileWriter.firstVerifiedFileOffMain(
            in: candidates,
            integrity: integrity
        ) else {
            return nil
        }
        // JHT_MOD_END ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改结束
        do {
            let committed = try await commitUnifiedAttachment(
                legacyURL,
                message: message,
                preferPreview: false,
                conversationID: conversationID,
                context: context
            )
            if legacyURL.standardizedFileURL != committed.standardizedFileURL {
                // JHT_MOD_BEGIN ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改开始：legacy 文件清理离开 MainActor
                await AttachmentTemporaryFileWriter.removeTemporaryFileOffMain(legacyURL)
                // JHT_MOD_END ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改结束
            }
            return committed
        } catch {
            return nil
        }
    }

    private func commitUnifiedAttachment(
        _ temporaryURL: URL,
        message: ChatMessage,
        preferPreview: Bool,
        conversationID: String,
        context: IOSMediaCacheScopeContext
    ) async throws -> URL {
        let metadata = unifiedAttachmentMetadata(for: message, context: context)
        let resourceKind: MediaResourceKind = preferPreview ? .preview : .original
        let integrity = unifiedAttachmentIntegrity(for: message, resourceKind: resourceKind)
        guard metadata.identity(for: resourceKind).persistentCacheIdentity != nil else {
            // JHT_MOD_BEGIN ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改开始：无缓存 identity 分支的文件校验离开 MainActor
            _ = try await AttachmentTemporaryFileWriter.verifyFileOffMain(temporaryURL, integrity: integrity)
            // JHT_MOD_END ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改结束
            guard context.sessionGeneration == localMessageSessionGeneration else {
                // JHT_MOD_BEGIN ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改开始：下载 staging 目录清理离开 MainActor
                await AttachmentTemporaryFileWriter.removeDownloadStagingDirectoryIfNeededOffMain(for: temporaryURL)
                // JHT_MOD_END ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改结束
                throw LocalMessageDatabaseError.staleSession
            }
            return temporaryURL
        }
        let committedURL = try await commitIndexedMediaCache(
            temporaryURL: temporaryURL,
            metadata: metadata,
            resourceKind: resourceKind,
            integrity: integrity,
            messageID: message.id,
            conversationID: conversationID,
            authorityVersion: "0",
            context: context
        )
        // JHT_MOD_BEGIN ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改开始：下载 staging 目录清理离开 MainActor
        await AttachmentTemporaryFileWriter.removeDownloadStagingDirectoryIfNeededOffMain(for: temporaryURL)
        // JHT_MOD_END ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改结束
        return committedURL
    }

    private func unifiedAttachmentMetadata(
        for message: ChatMessage,
        context: IOSMediaCacheScopeContext
    ) -> MediaResourceMetadata {
        let mediaCategory = attachmentMediaCategory(for: message)
        let remoteURL = attachmentRemoteURL(for: message, preferPreview: false)
        let fileExtension = attachmentFileExtension(for: message, remoteURL: remoteURL, mediaCategory: mediaCategory)
        let resource = attachmentResourceComponents(for: message)
        return MediaResourceMetadata(
            scope: context.scopeHash,
            fileID: resource.fileID,
            attachmentID: resource.attachmentID,
            mediaID: resource.mediaID,
            cacheKey: message.attachmentCacheKey,
            version: message.attachmentVersion,
            checksumSHA256: message.attachmentChecksum,
            createdAt: message.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            mimeType: attachmentMimeType(from: message),
            sizeBytes: message.attachmentSizeBytes,
            fileName: message.attachmentName ?? message.text,
            fileExtension: fileExtension,
            previewCacheKey: message.attachmentCacheKey,
            previewVersion: message.attachmentVersion,
            previewMimeType: attachmentMimeType(from: message),
            previewExtension: fileExtension
        )
    }

    private func unifiedAttachmentIntegrity(
        for message: ChatMessage,
        resourceKind: MediaResourceKind
    ) -> MediaFileIntegrityAuthority {
        // The backend checksum/size describe the original object. Transformed previews do not
        // currently expose an independent digest, so they are only checked for non-empty bytes.
        guard resourceKind == .original else { return MediaFileIntegrityAuthority() }
        return MediaFileIntegrityAuthority(
            expectedSizeBytes: message.attachmentSizeBytes,
            expectedSHA256: message.attachmentChecksum
        )
    }

    func openMessageAttachment(_ message: ChatMessage, conversationID: String, preferPreview: Bool = false) {
        let attachmentID = attachmentProgressKey(for: message)
        let scope = contentCacheScopeKey
        Task {
            guard await authorizeProtectedAccess(.filePreview) else { return }
            do {
                let localURL = try await prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: preferPreview)
                guard scope.isEmpty || isCurrentRemoteScope(scope) else { return }
                UIApplication.shared.open(localURL) { [weak self] success in
                    Task { @MainActor in
                        guard scope.isEmpty || self?.isCurrentRemoteScope(scope) == true else { return }
                        self?.fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
                        if !success {
                            self?.toast = "无法打开文件，请稍后重试"
                        }
                    }
                }
            } catch {
                guard scope.isEmpty || isCurrentRemoteScope(scope) else { return }
                fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
                handleRemoteError(error, fallback: "下载失败，请重试")
            }
        }
    }

    private enum AttachmentDownloadError: Error, LocalizedError {
        case missingURL

        var errorDescription: String? {
            switch self {
            case .missingURL:
                return "文件下载地址暂不可用"
            }
        }
    }

    private func attachmentRemoteURL(for message: ChatMessage, preferPreview: Bool) -> URL? {
        preferPreview
            ? (resolvedAttachmentPreviewURL(for: message) ?? resolvedAttachmentDownloadURL(for: message))
            : (resolvedAttachmentDownloadURL(for: message) ?? resolvedAttachmentPreviewURL(for: message))
    }

    func refreshedGIFAttachmentOriginalURL(_ message: ChatMessage, conversationID: String) async -> URL? {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let generation = localMessageSessionGeneration
        let fileID = tenantFileID(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.isCurrentRemoteScope(scope)
                && generation == self.localMessageSessionGeneration
                && context.accountID == self.apiContext.accountID
                && context.appID == self.apiContext.appID
                && context.deviceID == self.apiContext.deviceID
                && context.sessionEpoch == self.apiContext.sessionEpoch
                && self.conversationStore.conversation(id: conversationID)?.messages.contains(where: {
                    $0.id == message.id && self.tenantFileID(for: $0) == fileID
                        && $0.status != .recalled && !$0.isDeletedLocally
                }) == true
        }
        let validMetadata = { (detail: RemoteUserFileDetail) in
            return detail.file.id == fileID && detail.file.sizeBytes > 0
                && detail.file.sizeBytes <= GIFAttachmentUploadPolicy.maximumBytes
                && detail.file.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "uploaded"
                && (detail.downloadAvailable || detail.previewAvailable)
                && GIFAttachmentUploadPolicy.isGIFCandidate(
                    mimeType: detail.file.mimeType, name: detail.file.fileName, fileExtension: detail.file.fileExtension
                )
        }
        func originalURL(download: String, downloadAllowed: Bool, preview: String, previewAllowed: Bool, thumbnail: String) -> URL? {
            for raw in [downloadAllowed ? download : "", previewAllowed ? preview : ""] where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard raw != thumbnail, let url = resolvedAttachmentURL(raw),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
                return url
            }
            return nil
        }
        guard context.hasIMSession, !fileID.isEmpty, isCurrent() else { return nil }
        do {
            let refreshed = try await refreshedAttachmentMessage(
                message, in: conversationID, context: context, scope: scope,
                additionalValidation: { isCurrent() && validMetadata($0) }
            )
            guard isCurrent() else { return nil }
            if let url = originalURL(download: refreshed.attachmentDownloadURL, downloadAllowed: refreshed.attachmentDownloadAvailable, preview: refreshed.attachmentPreviewURL, previewAllowed: refreshed.attachmentPreviewAvailable, thumbnail: refreshed.attachmentThumbnailURL) {
                return url
            }
            guard refreshed.attachmentDownloadAvailable, let client = api as? IMAPIClient else { return nil }
            let signed = try await client.presignTenantFileDownload(context: context, fileID: fileID)
            guard isCurrent(), validMetadata(signed) else { return nil }
            return originalURL(download: signed.downloadURL, downloadAllowed: signed.downloadAvailable, preview: signed.previewURL, previewAllowed: signed.previewAvailable, thumbnail: signed.file.thumbnailURL)
        } catch {
            // Recovery is optional UI work; no credential-bearing error or URL toast.
            return nil
        }
    }

    private func refreshedAttachmentMessage(_ message: ChatMessage, in conversationID: String, context: IMAPIContext, scope: String, additionalValidation: ((RemoteUserFileDetail) -> Bool)? = nil) async throws -> ChatMessage {
        var targetMessage = message
        let fileID = tenantFileID(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileID.isEmpty {
            let detail = try await api.getTenantFile(context: context, fileID: fileID)
            guard !Task.isCancelled, isCurrentRemoteScope(scope), additionalValidation?(detail) ?? true else {
                throw CancellationError()
            }
            targetMessage.attachmentName = detail.file.fileName
            targetMessage.attachmentMeta = attachmentMeta(kind: message.kind, mimeType: detail.file.mimeType, sizeBytes: detail.file.sizeBytes)
            targetMessage.attachmentSizeBytes = detail.file.sizeBytes
            targetMessage.attachmentMimeType = detail.file.mimeType
            targetMessage.attachmentCacheKey = detail.file.cacheKey
            targetMessage.attachmentVersion = detail.file.version
            targetMessage.attachmentChecksum = detail.file.checksum
            targetMessage.attachmentPreviewAvailable = detail.previewAvailable
            targetMessage.attachmentDownloadAvailable = detail.downloadAvailable
            targetMessage.attachmentPreviewURL = detail.previewURL
            targetMessage.attachmentDownloadURL = detail.downloadURL
            targetMessage.attachmentMediaCategory = detail.file.mediaCategory
            targetMessage.attachmentExtension = detail.file.fileExtension
            targetMessage.attachmentThumbnailURL = detail.file.thumbnailURL
            targetMessage.attachmentPosterURL = detail.file.posterURL
            targetMessage.attachmentCoverURL = detail.file.coverURL
            targetMessage.attachmentPreviewKind = detail.file.previewKind
            targetMessage.attachmentContentDisposition = detail.contentDisposition
            targetMessage.attachmentWidth = detail.file.width
            targetMessage.attachmentHeight = detail.file.height
            targetMessage.attachmentDurationSeconds = detail.file.durationSeconds
            targetMessage.attachmentUploadStatus = detail.file.status
            updateMessageAttachment(targetMessage, in: conversationID)
        }
        return targetMessage
    }

    @discardableResult
    func refreshTenantFilesSnapshot(silent: Bool, query: String = "", category: String = "", limit: Int = 100, offset: Int = 0, append: Bool = false) async -> Int {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        return await refreshTenantFilesSnapshot(
            context: context,
            scope: scope,
            silent: silent,
            query: query,
            category: category,
            limit: limit,
            offset: offset,
            append: append
        )
    }

    @discardableResult
    func refreshTenantFilesSnapshot(context: IMAPIContext, scope: String, silent: Bool, query: String = "", category: String = "", limit: Int = 100, offset: Int = 0, append: Bool = false) async -> Int {
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else { return 0 }
        guard await beginTenantFilesSyncForRefresh(scope: scope, silent: silent) else {
            print("[JHT Perf] files_sync_skip reason=in_flight scope=\(Self.sessionScopeLogToken(scope))")
            return 0
        }
        defer { fileStore.finishTenantFilesSync() }
        do {
            let remoteFiles = try await api.listTenantFiles(
                context: context,
                query: query,
                category: category,
                limit: limit,
                offset: offset
            )
            guard isCurrentRemoteScope(scope) else { return 0 }
            let mapped = remoteFiles
                .map(fileItem(from:))
                .filter(isFileItemVisibleInFileLists)
            let mappedFileIDs = Set(mapped.map(\.id))
            let groupFileItems = await refreshKnownGroupFileItemsForFileList(
                context: context,
                scope: scope,
                query: query,
                category: category,
                excludingFileIDs: mappedFileIDs
            )
            let remoteBackedFileIDs = mappedFileIDs.union(groupFileItems.map(\.id))
            await backfillRecentAttachmentMessagesForFileList(
                context: context,
                scope: scope
            )
            let remoteBackedFiles = mapped + groupFileItems
            let localAttachmentFiles = attachmentFileItems(from: conversations)
                .filter { localFile in
                    isFileItemVisibleInFileLists(localFile)
                        && !remoteBackedFileIDs.contains(localFile.id)
                        && !remoteBackedFiles.contains { remoteFile in fileItemsReferToSameAttachment(remoteFile, localFile) }
                        && fileItem(localFile, matchesQuery: query, category: category)
                }
            if append {
                for file in mapped {
                    upsertTenantFile(file)
                }
                for file in groupFileItems where !fileStore.hasTenantFile(id: file.id) {
                    upsertTenantFile(file)
                }
                for file in localAttachmentFiles where !fileStore.hasTenantFile(id: file.id) {
                    upsertTenantFile(file)
                }
                mergeGroupFiles(files)
            } else {
                fileStore.replaceTenantFiles(mapped)
                for file in groupFileItems {
                    upsertTenantFile(file)
                }
                for file in localAttachmentFiles {
                    upsertTenantFile(file)
                }
                mergeGroupFiles(mapped)
            }
            return remoteFiles.count
        } catch {
            logSyncEndpointFailure("/api/tenant/files", error: error)
            fileStore.setTenantFilesSyncError(fileStore.hasTenantFiles()
                ? "文件同步失败，当前显示上次缓存"
                : "文件同步失败，请稍后重试")
            print("[JHT Perf] files_sync_fallback cached_count=\(files.count) scope=\(Self.sessionScopeLogToken(scope))")
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "文件同步失败",
                    silent: silent
                )
            } else if !silent {
                handleRemoteError(error, fallback: "文件同步失败")
            }
            return 0
        }
    }

    private func beginTenantFilesSyncForRefresh(scope: String, silent: Bool) async -> Bool {
        if fileStore.beginTenantFilesSync() {
            return true
        }
        guard !silent else { return false }
        guard await waitForTenantFilesSyncToFinish(scope: scope) else { return false }
        return fileStore.beginTenantFilesSync()
    }

    private func waitForTenantFilesSyncToFinish(scope: String) async -> Bool {
        let maxAttempts = 60
        for _ in 0..<maxAttempts {
            guard isCurrentRemoteScope(scope) else { return false }
            if !fileStore.isTenantFilesSyncing() {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !fileStore.isTenantFilesSyncing()
    }

    func refreshGroupFilesSnapshot(groupID: String, silent: Bool) async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        await refreshGroupFilesSnapshot(context: context, scope: scope, groupID: groupID, silent: silent)
    }

    func refreshGroupFilesSnapshot(context: IMAPIContext, scope: String, groupID: String, silent: Bool) async {
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        guard fileStore.beginGroupFilesSync(groupID: groupID) else { return }
        defer { fileStore.finishGroupFilesSync(groupID: groupID) }
        do {
            let files = try await api.listGroupFiles(context: context, groupID: groupID)
            guard isCurrentRemoteScope(scope) else { return }
            let mapped = files
                .map { fileItem(from: $0, groupID: groupID) }
                .filter(isFileItemVisibleInFileLists)
            fileStore.replaceGroupFiles(mapped, groupID: groupID)
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            logSyncEndpointFailure("/api/tenant/groups/{id}/files", error: error)
            fileStore.setGroupSyncError("群文件同步失败，请稍后重试", groupID: groupID)
            if isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "群文件同步失败", silent: silent)
            } else if !silent {
                handleRemoteError(error, fallback: "群文件同步失败")
            }
        }
    }

    // JHT_MOD_BEGIN APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改开始：统一媒体缓存职责从根 AppState.swift 拆入文件/附件扩展
    var contentCacheScopeKey: String {
        guard apiContext.hasIMSession else { return "" }
        return remoteDataScopeKey(for: apiContext)
    }

    var mediaCacheScopeContext: IOSMediaCacheScopeContext? {
        guard apiContext.hasIMSession,
              let scope = try? LocalMessageScope(context: apiContext),
              let paths = try? MessageDatabasePaths(scope: scope) else { return nil }
        return IOSMediaCacheScopeContext(
            scopeHash: scope.scopeHash,
            sessionGeneration: localMessageSessionGeneration,
            rootDirectory: paths.mediaScopeDirectory
        )
    }

    nonisolated static func mediaOfflinePolicy(
        for policy: RemoteTenantClientPolicy?
    ) -> IOSMediaOfflinePolicy {
        guard let policy,
              policy.mediaOfflinePolicyPresent else { return .bounded }
        switch policy.mediaOfflinePolicy {
        case "deny", "high_sensitivity", "high-sensitivity":
            return .deny
        default:
            return .bounded
        }
    }

    private var effectiveMediaOfflinePolicy: IOSMediaOfflinePolicy {
        Self.mediaOfflinePolicy(for: resolvedTenantClientPolicy)
    }

    func lookupIndexedMediaCache(
        metadata: MediaResourceMetadata,
        messageID: String,
        resourceKind: MediaResourceKind,
        variant: MediaCacheVariant? = nil,
        integrity: MediaFileIntegrityAuthority,
        context: IOSMediaCacheScopeContext,
        offline: Bool,
        offlinePolicy: IOSMediaOfflinePolicy? = nil
    ) async -> URL? {
        let resolvedOfflinePolicy = offlinePolicy ?? effectiveMediaOfflinePolicy
        guard !(offline && resolvedOfflinePolicy == .deny) else { return nil }
        let identity = metadata.identity(for: resourceKind, variant: variant)
        guard context.sessionGeneration == localMessageSessionGeneration,
              context.scopeHash == identity.scope,
              let cacheIdentity = identity.persistentCacheIdentity,
              let ticket = try? await currentMediaCacheTicket(context: context),
              let indexed = try? await messagePersistence.mediaCacheLookup(
                ticket: ticket,
                cacheIdentity: cacheIdentity,
                messageID: messageID,
                offline: offline
              ) else { return nil }
        guard context.sessionGeneration == localMessageSessionGeneration,
              await IOSMediaCacheStoreRegistry.shared.accepts(context),
              let indexedURL = mediaCacheURL(
                relativePath: indexed.entry.relativePath,
                context: context
              ),
              indexedURL.standardizedFileURL == identity.cacheFileURL(
                in: context.rootDirectory,
                preferredExtension: metadata.preferredExtension(for: resourceKind)
              ).standardizedFileURL,
              let store = try? await IOSMediaCacheStoreRegistry.shared.store(for: context) else {
            return nil
        }
        // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：缓存文件存在性校验放到后台，避免消息滚动时阻塞 MainActor
        let existedBeforeVerification = await MediaCacheFileIO.fileExistsOffMain(indexedURL)
        // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
        let indexedIntegrity = MediaFileIntegrityAuthority(
            expectedSizeBytes: indexed.entry.verifiedSizeBytes ?? integrity.expectedSizeBytes,
            expectedSHA256: indexed.entry.verifiedChecksumSHA256 ?? integrity.expectedSHA256
        )
        let result = await store.verifiedLookup(
            identity: identity,
            preferredExtension: metadata.preferredExtension(for: resourceKind),
            integrity: indexedIntegrity,
            sessionGeneration: context.sessionGeneration
        )
        guard context.sessionGeneration == localMessageSessionGeneration,
              await IOSMediaCacheStoreRegistry.shared.accepts(context),
              case let .downloaded(localURL) = result.state else {
            try? await messagePersistence.markMediaCacheState(
                ticket: ticket,
                cacheIdentity: cacheIdentity,
                state: existedBeforeVerification ? .corrupt : .evicted
            )
            return nil
        }
        if !offline {
            let authorizedAt = Date()
            try? await messagePersistence.renewMediaCacheAuthority(
                ticket: ticket,
                cacheIdentity: cacheIdentity,
                messageID: messageID,
                authorizedAt: authorizedAt,
                offlineAccessUntil: resolvedOfflinePolicy == .bounded
                    ? authorizedAt.addingTimeInterval(resolvedOfflinePolicy.ttl)
                    : nil
            )
        }
        try? await messagePersistence.touchMediaCache(
            ticket: ticket,
            cacheIdentity: cacheIdentity
        )
        guard context.sessionGeneration == localMessageSessionGeneration else { return nil }
        return localURL
    }

    func commitIndexedMediaCache(
        temporaryURL: URL,
        metadata: MediaResourceMetadata,
        resourceKind: MediaResourceKind,
        variant: MediaCacheVariant? = nil,
        integrity: MediaFileIntegrityAuthority,
        messageID: String,
        conversationID: String,
        authorityVersion: String = "0",
        offlinePolicy: IOSMediaOfflinePolicy? = nil,
        protectionReason: String = "",
        context: IOSMediaCacheScopeContext
    ) async throws -> URL {
        let resolvedOfflinePolicy = offlinePolicy ?? effectiveMediaOfflinePolicy
        let identity = metadata.identity(for: resourceKind, variant: variant)
        do {
            try MediaCacheCanonicalIdentity.validateRequired(messageID, field: "message_id")
        } catch {
            throw LocalMessageDatabaseError.identityConflict
        }
        guard let normalizedAuthorityVersion = canonicalMediaAuthorityVersion(authorityVersion) else {
            throw LocalMessageDatabaseError.identityConflict
        }
        guard context.sessionGeneration == localMessageSessionGeneration,
              context.scopeHash == identity.scope,
              let cacheIdentity = identity.persistentCacheIdentity else {
            throw LocalMessageDatabaseError.staleSession
        }
        // Rebind the SQLite writer generation before advancing the file-store
        // generation so an old ticket cannot commit authority rows in between.
        let ticket = try await currentMediaCacheTicket(context: context)
        guard context.sessionGeneration == localMessageSessionGeneration,
              let store = try? await IOSMediaCacheStoreRegistry.shared.store(for: context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let preferredExtension = metadata.preferredExtension(for: resourceKind)
        guard context.sessionGeneration == localMessageSessionGeneration,
              await IOSMediaCacheStoreRegistry.shared.accepts(context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let entry = try await store.saveVerifiedDownloadedFile(
            from: temporaryURL,
            identity: identity,
            preferredExtension: preferredExtension,
            integrity: integrity,
            sessionGeneration: context.sessionGeneration
        )
        guard context.sessionGeneration == localMessageSessionGeneration,
              await IOSMediaCacheStoreRegistry.shared.accepts(context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        guard context.sessionGeneration == localMessageSessionGeneration,
              let relativePath = mediaCacheRelativePath(for: entry.localURL, context: context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let now = Date()
        let attachmentID = identity.primaryStableID
        let authority = IOSMediaCacheAuthorityRecord(
            scopeHash: context.scopeHash,
            messageID: messageID,
            attachmentID: attachmentID,
            identity: identity,
            mimeType: metadata.mimeType.isEmpty ? "application/octet-stream" : metadata.mimeType,
            sizeBytes: entry.sizeBytes,
            checksumSHA256: integrity.hasChecksum ? integrity.expectedSHA256 : nil,
            state: .active,
            authorityVersion: normalizedAuthorityVersion,
            lastAuthorizedAt: now,
            offlineAccessUntil: resolvedOfflinePolicy == .bounded
                ? now.addingTimeInterval(resolvedOfflinePolicy.ttl)
                : nil,
            createdAt: nil,
            updatedAt: now
        )
        let indexedEntry = IOSMediaCacheEntryRecord(
            scopeHash: context.scopeHash,
            cacheIdentity: cacheIdentity,
            attachmentID: attachmentID,
            variant: identity.variant,
            relativePath: relativePath,
            localState: .verifiedCached,
            sizeBytes: entry.sizeBytes,
            verifiedSizeBytes: entry.sizeBytes,
            verifiedChecksumSHA256: try MediaFileIntegrityAuthority.sha256Hex(fileAt: entry.localURL),
            pinnedByUser: false,
            protectionReason: protectionReason,
            createdAt: now,
            lastAccessedAt: now
        )
        do {
            let accepted = try await messagePersistence.upsertMediaCache(
                ticket: ticket,
                authority: authority,
                entry: indexedEntry,
                conversationID: conversationID
            )
            guard accepted else {
                throw LocalMessageDatabaseError.authorityRejected
            }
        } catch {
            throw error
        }
        guard context.sessionGeneration == localMessageSessionGeneration else {
            throw LocalMessageDatabaseError.staleSession
        }
        try? await pruneIndexedMediaCacheIfNeeded(ticket: ticket, context: context)
        return entry.localURL
    }

    private func canonicalMediaAuthorityVersion(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty,
              rawValue.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }) else {
            return nil
        }
        let trimmed = rawValue.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private func currentMediaCacheTicket(
        context: IOSMediaCacheScopeContext
    ) async throws -> LocalMessageSessionTicket {
        if let localMessageTicket,
           localMessageTicket.scopeHash == context.scopeHash,
           localMessageTicket.sessionGeneration == context.sessionGeneration {
            return localMessageTicket
        }
        let ticket = try await messagePersistence.ensureTicket(
            context: apiContext,
            sessionGeneration: context.sessionGeneration
        )
        guard context.sessionGeneration == localMessageSessionGeneration,
              ticket.scopeHash == context.scopeHash else {
            throw LocalMessageDatabaseError.staleSession
        }
        localMessageTicket = ticket
        return ticket
    }

    private func mediaCacheRelativePath(
        for url: URL,
        context: IOSMediaCacheScopeContext
    ) -> String? {
        let root = context.rootDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return nil }
        let relative = String(candidate.dropFirst(root.count + 1))
        guard !relative.isEmpty, !relative.contains(".."), !relative.hasPrefix("/") else { return nil }
        return relative
    }

    func mediaCacheURL(
        relativePath: String,
        context: IOSMediaCacheScopeContext
    ) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("..") else { return nil }
        let resolved = context.rootDirectory
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard resolved.path.hasPrefix(context.rootDirectory.standardizedFileURL.path + "/") else { return nil }
        return resolved
    }

    private func pruneIndexedMediaCacheIfNeeded(
        ticket: LocalMessageSessionTicket,
        context: IOSMediaCacheScopeContext,
        softQuotaBytes: Int64 = MediaCachePolicy.thumbnailDiskCapacityBytes
            + MediaCachePolicy.previewDiskCapacityBytes
            + MediaCachePolicy.originalDiskCapacityBytes
    ) async throws {
        for (kind, quota) in [
            (MediaResourceKind.thumbnail, MediaCachePolicy.thumbnailDiskCapacityBytes),
            (.preview, MediaCachePolicy.previewDiskCapacityBytes),
            (.original, MediaCachePolicy.originalDiskCapacityBytes)
        ] {
            let tierStats = try await messagePersistence.mediaCacheStatistics(
                ticket: ticket,
                resourceKind: kind
            )
            guard tierStats.totalBytes > quota * 12 / 10 else { continue }
            let candidates = try await messagePersistence.mediaCachePruneCandidates(
                ticket: ticket,
                bytesToFree: tierStats.totalBytes - quota * 11 / 10,
                resourceKind: kind
            )
            try await removeMediaCacheCandidates(candidates, ticket: ticket, context: context)
        }
        let stats = try await messagePersistence.mediaCacheStatistics(ticket: ticket)
        guard stats.totalBytes > softQuotaBytes * 12 / 10 else { return }
        let candidates = try await messagePersistence.mediaCachePruneCandidates(
            ticket: ticket,
            bytesToFree: stats.totalBytes - softQuotaBytes * 11 / 10
        )
        try await removeMediaCacheCandidates(candidates, ticket: ticket, context: context)
    }

    private func removeMediaCacheCandidates(
        _ candidates: [IOSMediaCachePruneCandidate],
        ticket: LocalMessageSessionTicket,
        context: IOSMediaCacheScopeContext
    ) async throws {
        guard context.sessionGeneration == localMessageSessionGeneration,
              await IOSMediaCacheStoreRegistry.shared.accepts(context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        var removedIdentities: [String] = []
        for candidate in candidates {
            guard context.sessionGeneration == localMessageSessionGeneration else {
                throw LocalMessageDatabaseError.staleSession
            }
            guard let url = mediaCacheURL(relativePath: candidate.relativePath, context: context) else { continue }
            // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：媒体缓存删除放到后台，保留原有成功后移除索引的语义
            let removal = await MediaCacheFileIO.removeFileIfExistsOffMain(url)
            guard removal.didComplete else {
                continue
            }
            removedIdentities.append(candidate.cacheIdentity)
            // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
        }
        try await messagePersistence.removeMediaCacheEntries(
            ticket: ticket,
            cacheIdentities: removedIdentities
        )
    }

    func invalidateIndexedMediaCache(
        messageID: String,
        state: MediaCacheAuthorityState,
        authorityVersion: String,
        context: IOSMediaCacheScopeContext
    ) {
        guard let normalizedVersion = canonicalMediaAuthorityVersion(authorityVersion) else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  context.sessionGeneration == self.localMessageSessionGeneration,
                  let ticket = try? await self.currentMediaCacheTicket(context: context),
                  let candidates = try? await self.messagePersistence.invalidateMediaCache(
                    ticket: ticket,
                    messageID: messageID,
                    state: state,
                    authorityVersion: normalizedVersion
                  ),
                  context.sessionGeneration == self.localMessageSessionGeneration else { return }
            for candidate in candidates {
                guard let url = self.mediaCacheURL(
                    relativePath: candidate.relativePath,
                    context: context
                ) else { continue }
                // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：失效缓存文件删除放到后台执行
                await MediaCacheFileIO.removeFileIgnoringErrorsOffMain(url)
                // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
            }
        }
    }

    func invalidateIndexedMediaCache(
        for message: ChatMessage,
        state: MediaCacheAuthorityState
    ) {
        guard let context = mediaCacheScopeContext else { return }
        invalidateIndexedMediaCache(
            messageID: message.id,
            state: state,
            authorityVersion: String(max(message.editRevision, 0)),
            context: context
        )
    }

    func invalidateIndexedMediaCacheIfRemoteTombstone(_ remote: RemoteMessage) {
        let normalizedStatus = remote.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let state: MediaCacheAuthorityState
        if isAdminDeletedRemoteMessage(remote) {
            state = .deleted
        } else if ["recalled", "revoked"].contains(normalizedStatus) {
            state = .recalled
        } else {
            return
        }
        guard let context = mediaCacheScopeContext else { return }
        let payloadVersion = attachmentPayloadString(
            remote.payload,
            ["authority_version", "event_version", "tombstone_version"]
        )
        let authorityVersion = canonicalMediaAuthorityVersion(payloadVersion)
            ?? String(max(remote.editRevision, 0))
        invalidateIndexedMediaCache(
            messageID: remote.messageID,
            state: state,
            authorityVersion: authorityVersion,
            context: context
        )
    }

    func clearCurrentIndexedMediaCache() async -> AppCacheCleanupResult {
        guard let context = mediaCacheScopeContext,
              let ticket = try? await currentMediaCacheTicket(context: context),
              let stats = try? await messagePersistence.mediaCacheStatistics(ticket: ticket),
              stats.totalBytes > 0,
              let candidates = try? await messagePersistence.mediaCachePruneCandidates(
                ticket: ticket,
                bytesToFree: stats.totalBytes
              ),
              context.sessionGeneration == localMessageSessionGeneration else {
            return AppCacheCleanupResult(bytesRemoved: 0, failures: [])
        }
        var removedBytes: Int64 = 0
        var removedIdentities: [String] = []
        var failures: [String] = []
        for candidate in candidates {
            guard context.sessionGeneration == localMessageSessionGeneration else {
                failures.append("统一媒体缓存（会话已切换）")
                break
            }
            guard let url = mediaCacheURL(relativePath: candidate.relativePath, context: context) else {
                failures.append("统一媒体缓存（路径）")
                continue
            }
            // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：清理统一媒体缓存的磁盘删除放到后台
            let removal = await MediaCacheFileIO.removeFileIfExistsOffMain(url)
            guard removal.didComplete else {
                failures.append("统一媒体缓存")
                continue
            }
            if removal.fileExisted {
                removedBytes += max(candidate.sizeBytes, 0)
            }
            removedIdentities.append(candidate.cacheIdentity)
            // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
        }
        do {
            try await messagePersistence.removeMediaCacheEntries(
                ticket: ticket,
                cacheIdentities: removedIdentities
            )
        } catch {
            failures.append("统一媒体缓存（索引）")
        }
        return AppCacheCleanupResult(bytesRemoved: removedBytes, failures: failures)
    }

    func deletePersistedConversationAndMedia(
        ticket: LocalMessageSessionTicket,
        conversationID: String,
        context: IOSMediaCacheScopeContext?
    ) async {
        if let candidates = try? await messagePersistence.removeMediaCacheReferences(
            ticket: ticket,
            conversationID: conversationID
        ), let context,
           context.sessionGeneration == localMessageSessionGeneration {
            for candidate in candidates {
                guard let url = mediaCacheURL(relativePath: candidate.relativePath, context: context) else { continue }
                // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：删除会话关联媒体文件放到后台执行
                await MediaCacheFileIO.removeFileIgnoringErrorsOffMain(url)
                // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
            }
        }
        try? await messagePersistence.deleteConversation(
            ticket: ticket,
            conversationID: conversationID
        )
    }
    // JHT_MOD_END APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改结束


}

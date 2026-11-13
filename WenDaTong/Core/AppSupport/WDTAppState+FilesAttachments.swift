import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            }
            return .empty
        }
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
        let request = fileStore.favoriteAssetsCollection.begin(
            scope: scope,
            category: category,
            cursor: cursor
        )
        fileStore.publishFavoriteAssets(isSyncing: true)
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        let authority = context.authSessionFence
        let pageOwner = ScopedListRequestOwner(ownsRequest: { [weak self] in
            guard let self else { return false }
            return authority.epoch == self.apiContext.sessionEpoch && self.isCurrentRemoteScope(scope)
                && self.fileStore.favoriteAssetsCollection.isCurrent(request)
        }, ownsAuthority: { [weak self] in
            self?.apiContext.isSameAuthAuthority(as: authority) == true
        })
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
        defer {
            if fileStore.favoriteAssetsCollection.isCurrent(request) {
                _ = fileStore.favoriteAssetsCollection.fail(request: request)
                fileStore.favoriteAssetsSnapshot.isSyncing = false
            }
        }
        do {
            // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
            let response = try await ScopedListRequestOwner.$current.withValue(pageOwner) {
                try await api.listFavoriteAssets(
                    context: context,
                    category: category.requestValue,
                    limit: limit,
                    cursor: cursor
                )
            }
            guard !Task.isCancelled, pageOwner.ownsRequest() else { return .empty }
            // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
            let mapped = response.items
                .map(favoriteAssetItem(from:))
                .filter(isFavoriteAssetVisibleAfterHistoryBoundary)
            guard fileStore.favoriteAssetsCollection.apply(
                items: mapped,
                append: append,
                request: request
            ) else { return .empty }
            fileStore.publishFavoriteAssets(isSyncing: false)
            return FavoriteAssetsPageResult(
                fetchedCount: mapped.count,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore,
                didSucceed: true
            )
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        } catch is CancellationError {
            return .empty
        } catch {
            guard !Task.isCancelled, pageOwner.ownsRequest() else { return .empty }
            if isUnauthorizedError(error) || DeviceRevocationDetector.matches(error: error)
                || securityBlockedInfo(from: error) != nil || workspaceAccessCode(from: error) != nil {
                guard pageOwner.ownsAuthority() else { return .empty }
            }
            guard fileStore.favoriteAssetsCollection.fail(request: request) else { return .empty }
            // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
            logSyncEndpointFailure("/api/im/favorites/list", error: error)
            fileStore.publishFavoriteAssets(
                isSyncing: false,
                errorMessage: fileStore.favoriteAssetsCollection.activeItems.isEmpty
                    ? "收藏资料加载失败，请稍后重试"
                    : "收藏资料加载失败，当前显示上次缓存"
            )
            if isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "收藏资料加载失败", silent: silent)
            } else if !silent {
                handleRemoteError(error, fallback: "收藏资料加载失败")
            }
            return .empty
        }
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END
    }

    @discardableResult
    func setMessageFavorite(messageID: String, favorited: Bool, showToast: Bool = true) async -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty else { return false }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            if showToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            }
            return false
        }
        do {
            try await api.favoriteMessage(context: context, messageID: normalizedMessageID, favorited: favorited)
            guard isCurrentRemoteScope(scope) else { return false }
            applyLoadedMessageFavoriteState(messageID: normalizedMessageID, favorited: favorited)
            if !favorited {
                // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
                fileStore.favoriteAssetsCollection.remove(scope: scope) {
                    $0.messageID == normalizedMessageID
                }
                fileStore.favoriteAssetsSnapshot.items = fileStore.favoriteAssetsCollection.activeItems
                // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END
            }
            if showToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(favorited ? "已收藏资料" : "已取消收藏")
            }
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            if shouldShowGroupHistoryLimitedMessage(for: error, messageID: normalizedMessageID) {
                if showToast {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
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

    func syncAttachmentFilesFromConversation(_ conversation: ConversationMessageSnapshot) {
        let fileItems = attachmentFileItems(from: [conversation])
        guard !fileItems.isEmpty else { return }
        for fileItem in fileItems {
            upsertTenantFile(fileItem)
        }
    }

    func syncAttachmentFilesFromConversations(_ conversations: [ConversationMessageSnapshot]) {
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                fileStore.invalidateCallLicenseAuthority() // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(preview ? "当前文件暂不支持预览" : "当前文件暂不支持下载")
                    return
                }
                UIApplication.shared.open(url) { [weak self] success in
                    guard !success else { return }
                    Task { @MainActor in
                        guard self?.isCurrentRemoteScope(scope) == true else { return }
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self?.setToast("无法打开文件链接，请稍后重试")
                    }
                }
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if shouldShowGroupHistoryLimitedMessage(for: error, file: file) {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
                    return
                }
                handleRemoteError(error, fallback: preview ? "文件预览失败" : "文件下载失败")
            }
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

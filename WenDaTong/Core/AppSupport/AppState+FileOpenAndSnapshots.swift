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

extension AppState {
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
                            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self?.setToast("无法打开文件，请稍后重试")
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

    enum AttachmentDownloadError: Error, LocalizedError {
        case missingURL

        var errorDescription: String? {
            switch self {
            case .missingURL:
                return "文件下载地址暂不可用"
            }
        }
    }

    func attachmentRemoteURL(for message: ChatMessage, preferPreview: Bool) -> URL? {
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
                && self.conversationStore.conversationMessageSnapshot(id: conversationID)?.messages.contains(where: {
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

    func refreshedAttachmentMessage(_ message: ChatMessage, in conversationID: String, context: IMAPIContext, scope: String, additionalValidation: ((RemoteUserFileDetail) -> Bool)? = nil, requireSignedDownload: Bool = false, forChatThumbnail: Bool = false,
        prefetchedDetail: RemoteUserFileDetail? = nil) async throws -> ChatMessage { // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
        var targetMessage = message
        let fileID = tenantFileID(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileID.isEmpty {
            // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_BEGIN
            let detail: RemoteUserFileDetail
            if let prefetchedDetail, prefetchedDetail.file.id == fileID {
                detail = prefetchedDetail
            } else {
                detail = try await api.getTenantFile(context: context, fileID: fileID)
            }
            // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_END
            var signedDownloadURL: String?
            guard !Task.isCancelled, isCurrentRemoteScope(scope), additionalValidation?(detail) ?? true else {
                throw CancellationError()
            }
            if detail.downloadAvailable,
               requireSignedDownload || resolvedAttachmentURL(detail.downloadURL) == nil,
               let client = api as? IMAPIClient {
                signedDownloadURL = try await client.presignTenantFileDownloadURL(context: context, fileID: fileID)
                guard let signedDownloadURL, resolvedAttachmentURL(signedDownloadURL) != nil else {
                    throw AttachmentDownloadError.missingURL
                }
            }
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
            targetMessage.attachmentDownloadURL = signedDownloadURL ?? detail.downloadURL
            targetMessage.attachmentMediaCategory = detail.file.mediaCategory
            targetMessage.attachmentExtension = detail.file.fileExtension
            targetMessage.attachmentThumbnailURL = detail.file.thumbnailURL
            targetMessage.attachmentPosterURL = detail.file.posterURL
            targetMessage.attachmentCoverURL = detail.file.coverURL
            targetMessage.attachmentPreviewKind = detail.file.previewKind
            targetMessage.attachmentContentDisposition = detail.contentDisposition
            if !forChatThumbnail {
                targetMessage.attachmentWidth = detail.file.width
                targetMessage.attachmentHeight = detail.file.height
            }
            targetMessage.attachmentDurationSeconds = detail.file.durationSeconds
            targetMessage.attachmentUploadStatus = detail.file.status
            if conversationStore.updateMessageAttachment(targetMessage, conversationID: conversationID) != nil {
                if forChatThumbnail {
                    scheduleConversationSnapshotCacheWrite(conversationID: conversationID, scope: scope)
                } else {
                    await persistConversationSnapshotImmediately(conversationID: conversationID, scope: scope, source: .localMutation)
                }
            }
            guard !Task.isCancelled, isCurrentRemoteScope(scope) else { throw CancellationError() }
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
            let localAttachmentFiles = attachmentFileItems(from: conversationStore.conversationMessageSnapshots())
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

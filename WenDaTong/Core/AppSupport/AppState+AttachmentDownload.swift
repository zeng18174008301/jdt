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
    // WDT_APP_CONTRACT_20261021_10: one registry for chat, files, previews and shares before any await.
    func withSharedAttachmentDownload(attachmentID: String, showsProgress: Bool = true,
        operation: @escaping @MainActor (UUID) async throws -> URL) async throws -> URL {
        if let task = fileStore.attachmentDownloadTask(attachmentID: attachmentID) {
            if showsProgress { fileStore.beginAttachmentDownloadProgress(attachmentID: attachmentID) }
            return try await task.value
        }
        let token = UUID()
        let task = Task<URL, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                if self.fileStore.isCurrentAttachmentDownload(attachmentID: attachmentID, token: token) {
                    self.fileStore.finishAttachmentDownloadTask(attachmentID: attachmentID)
                    self.fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
                }
            }
            do {
                try Task.checkCancellation()
                return try await operation(token)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if !(error is CancellationError), !Task.isCancelled,
                   self.fileStore.isCurrentAttachmentDownload(attachmentID: attachmentID, token: token),
                   self.fileStore.attachmentDownloadSnapshot(attachmentID: attachmentID) != nil {
                    self.fileStore.markAttachmentDownloadFailed(attachmentID: attachmentID)
                }
                throw error
            }
        }
        fileStore.replaceAttachmentDownloadTask(attachmentID: attachmentID, with: task, token: token)
        fileStore.clearAttachmentDownloadFailed(attachmentID: attachmentID)
        if showsProgress { fileStore.beginAttachmentDownloadProgress(attachmentID: attachmentID) }
        return try await task.value
    }

    func fileDownloadKey(_ file: FileItem, preview: Bool) -> String {
        attachmentDownloadKey(fileID: file.remoteLookupID.isEmpty ? file.id : file.remoteLookupID,
            version: file.version, preferPreview: preview && file.mediaPipelinePreviewResourceKind == .preview)
    }

    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
    func fileDownloadKeys(_ file: FileItem) -> FileStore.DownloadKeys {
        FileStore.DownloadKeys(
            original: fileDownloadKey(file, preview: false),
            preview: fileDownloadKey(file, preview: true)
        )
    }
    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END

    func cancelFileDownload(_ file: FileItem) {
        for preview in [false, true] {
            let key = fileDownloadKey(file, preview: preview)
            fileStore.cancelAttachmentDownloadTask(attachmentID: key)
            fileStore.clearAttachmentDownloadProgress(attachmentID: key)
        }
    }

    func prepareTenantFileLocalFile(_ file: FileItem, preview: Bool = false) async throws -> URL {
        let scope = contentCacheScopeKey
        let key = fileDownloadKey(file, preview: preview)
        return try await withSharedAttachmentDownload(attachmentID: key) { token in
            guard self.contentCacheScopeKey == scope else {
                throw CancellationError()
            }
            let context = self.mediaCacheScopeContext
            let kind: MediaResourceKind = preview ? file.mediaPipelinePreviewResourceKind : .original
            let integrity = kind == .original
                ? MediaFileIntegrityAuthority(expectedSizeBytes: file.sizeBytes, expectedSHA256: file.checksum)
                : MediaFileIntegrityAuthority()
            if let context, let cached = await self.lookupIndexedMediaCache(metadata: file.mediaResourceMetadata(scope: context.scopeHash), messageID: file.remoteLookupID,
                resourceKind: kind, integrity: integrity, context: context, offline: true) {
                try Task.checkCancellation()
                guard self.contentCacheScopeKey == scope else { throw CancellationError() }
                return cached
            }
            let refreshed = try await self.refreshTenantFile(file)
            try Task.checkCancellation()
            guard self.contentCacheScopeKey == scope else { throw CancellationError() }
            let resolvedKey = self.fileDownloadKey(refreshed, preview: preview)
            if let joined = self.fileStore.coalesceAttachmentDownload(from: key, to: resolvedKey, token: token) {
                return try await joined.value
            }
            let url = preview ? refreshed.systemPreviewRemoteURL
                : (refreshed.downloadAvailable ? self.resolvedAttachmentURL(refreshed.downloadURL) : nil)
            guard let url else { throw AttachmentDownloadError.missingURL }
            let resolvedKind: MediaResourceKind = preview ? refreshed.mediaPipelinePreviewResourceKind : .original
            let resolvedIntegrity = resolvedKind == .original
                ? MediaFileIntegrityAuthority(expectedSizeBytes: refreshed.sizeBytes, expectedSHA256: refreshed.checksum)
                : MediaFileIntegrityAuthority()
            if let context, let cached = await self.lookupIndexedMediaCache(
                metadata: refreshed.mediaResourceMetadata(scope: context.scopeHash), messageID: refreshed.remoteLookupID,
                resourceKind: resolvedKind, integrity: resolvedIntegrity, context: context, offline: false) {
                try Task.checkCancellation()
                guard self.contentCacheScopeKey == scope else { throw CancellationError() }
                return cached
            }
            let bytes: @Sendable (AttachmentDownloadSnapshot) -> Void = { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.fileStore.setAttachmentDownloadSnapshot(snapshot, attachmentID: key, token: token)
                }
            }
            let temporary = try await MediaSignedURLRecovery.perform(initialURL: url, refreshURL: {
                let fresh = try await self.refreshTenantFile(refreshed)
                guard self.contentCacheScopeKey == scope else { throw CancellationError() }
                let candidate = preview ? fresh.systemPreviewRemoteURL
                    : (fresh.downloadAvailable ? self.resolvedAttachmentURL(fresh.downloadURL) : nil)
                guard let candidate else { throw AttachmentDownloadError.missingURL }
                return candidate
            }, operation: { candidate in
                try await AttachmentDownloadExecutor.temporaryFile(remoteURL: candidate,
                    suggestedName: refreshed.name, cacheKey: key, fallbackExtension: refreshed.fileExtension,
                    expectedSizeBytes: resolvedKind == .original ? refreshed.sizeBytes : nil,
                    sessionFactory: self.attachmentDownloadSessionFactory,
                    byteProgress: bytes, progress: { _ in })
            })
            var didCommit = false
            defer {
                if didCommit, temporary.standardizedFileURL != url.standardizedFileURL {
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
            try Task.checkCancellation()
            guard self.contentCacheScopeKey == scope else { throw CancellationError() }
            var snapshot = self.fileStore.attachmentDownloadSnapshot(attachmentID: key) ?? AttachmentDownloadSnapshot()
            snapshot.isCommitting = true
            self.fileStore.setAttachmentDownloadSnapshot(snapshot, attachmentID: key, token: token)
            // Preserve public-media access when a cache scope is unavailable; it is not an auth gate.
            guard let context else {
                _ = try await AttachmentTemporaryFileWriter.verifyFileOffMain(temporary, integrity: resolvedIntegrity)
                try Task.checkCancellation()
                guard self.contentCacheScopeKey == scope else { throw CancellationError() }
                return temporary
            }
            let committed = try await self.commitIndexedMediaCache(temporaryURL: temporary,
                metadata: refreshed.mediaResourceMetadata(scope: context.scopeHash), resourceKind: resolvedKind,
                integrity: resolvedIntegrity, messageID: refreshed.remoteLookupID,
                conversationID: "__files__", authorityVersion: "0", context: context)
            didCommit = true
            try Task.checkCancellation()
            guard self.contentCacheScopeKey == scope else { throw CancellationError() }
            return committed
        }
    }

    func downloadMessageAttachmentLocalFile(_ message: ChatMessage, conversationID: String,
        preferPreview: Bool, attachmentID: String, token: UUID, forChatThumbnail: Bool,
        prefetchedDetail: RemoteUserFileDetail? = nil) async throws -> URL { // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
        try Task.checkCancellation()
        let context = apiContext
        guard context.hasIMSession else {
            throw IMAPIError.missingContext("登录会话不可用，请重新登录")
        }
        let scope = remoteDataScopeKey(for: context)
        if let cacheContext = mediaCacheScopeContext,
           let localURL = await cachedUnifiedAttachmentURL(
            for: message,
            preferPreview: preferPreview,
            context: cacheContext,
            offline: true
           ) {
            try Task.checkCancellation()
            guard isCurrentRemoteScope(scope) else { throw CancellationError() }
            return localURL
        }

        let targetMessage = try await refreshedAttachmentMessage(message, in: conversationID, context: context, scope: scope,
            forChatThumbnail: forChatThumbnail, prefetchedDetail: prefetchedDetail) // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
        try Task.checkCancellation()
        let resolvedKey = attachmentProgressKey(for: targetMessage, preferPreview: preferPreview)
        if let joined = fileStore.coalesceAttachmentDownload(from: attachmentID, to: resolvedKey, token: token) {
            return try await joined.value
        }
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
                throw CancellationError()
            }
            return localURL
        }
        let url = attachmentRemoteURL(for: targetMessage, preferPreview: preferPreview)
        guard let url else {
            throw AttachmentDownloadError.missingURL
        }

        let suggestedName = targetMessage.attachmentName ?? message.attachmentName ?? message.text
        let mediaCategory = attachmentMediaCategory(for: targetMessage)
        let fallbackExtension = attachmentFileExtension(for: targetMessage, remoteURL: url, mediaCategory: mediaCategory)
        let cacheKey = attachmentPersistentCacheKey(for: targetMessage, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension)
        try Task.checkCancellation()
        let temporaryURL = try await MediaSignedURLRecovery.perform(
            initialURL: url,
            refreshURL: {
                let refreshedMessage = try await self.refreshedAttachmentMessage(
                    targetMessage,
                    in: conversationID,
                    context: context,
                    scope: scope,
                    requireSignedDownload: true,
                    forChatThumbnail: forChatThumbnail
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
                let byteProgress: @Sendable (AttachmentDownloadSnapshot) -> Void = { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.fileStore.updateVisibleAttachmentDownloadProgress(snapshot, attachmentID: attachmentID, token: token)
                    }
                }
                return try await AttachmentDownloadExecutor.temporaryFile(
                    remoteURL: remoteURL,
                    suggestedName: suggestedName,
                    cacheKey: cacheKey,
                    fallbackExtension: fallbackExtension,
                    expectedSizeBytes: preferPreview ? nil : targetMessage.attachmentSizeBytes ?? message.attachmentSizeBytes,
                    sessionFactory: sessionFactory,
                    byteProgress: byteProgress,
                    progress: { _ in }
                )
                // JHT_MOD_END ATTACHMENT_DOWNLOAD_NON_MAIN_PERF_20260912 - 修改结束
            }
        )
        try Task.checkCancellation()
        var snapshot = fileStore.attachmentDownloadSnapshot(attachmentID: attachmentID) ?? AttachmentDownloadSnapshot()
        snapshot.isCommitting = true
        fileStore.updateVisibleAttachmentDownloadProgress(snapshot, attachmentID: attachmentID, token: token)
        let localURL = try await self.commitUnifiedAttachment(
            temporaryURL,
            message: targetMessage,
            preferPreview: preferPreview,
            conversationID: conversationID,
            context: cacheContext
        )
        try Task.checkCancellation()
        guard isCurrentRemoteScope(scope) else {
            throw CancellationError()
        }
        if forChatThumbnail { return localURL }
        // JHT_MOD_BEGIN ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：下载完成后的图片尺寸/视频缩略图生成移出 MainActor
        let resources = await AttachmentPreviewResourceBuilder.downloadedPreviewResourcesOffMain(
            messageID: targetMessage.id,
            localURL: localURL,
            mediaCategory: mediaCategory
        )
        try Task.checkCancellation()
        guard isCurrentRemoteScope(scope) else { throw CancellationError() }
        if let resources {
            cacheLocalAttachmentResources(
                resources,
                messageID: targetMessage.id,
                fileID: targetMessage.attachmentFileID,
                cacheIdentity: attachmentStableCacheIdentity(for: targetMessage, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension)
            )
        }
        // JHT_MOD_END ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束
        return localURL
    }

    // WDT_CHAT_MEDIA_CACHE_REUSE_20261102: cache-only lookup for a recycled chat cell, before loading UI/network work.
    func cachedMessageAttachmentLocalFile(_ message: ChatMessage, conversationID: String) async -> URL? {
        let message = currentAttachmentCacheMessage(message, conversationID: conversationID)
        guard !message.isDeletedLocally, message.status != .recalled,
              let context = mediaCacheScopeContext else { return nil }
        let url = await cachedUnifiedAttachmentURL(for: message, preferPreview: false, context: context, offline: true)
        guard !Task.isCancelled, context == mediaCacheScopeContext else { return nil }
        return url
    }

    func cachedUnifiedAttachmentURL(
        for message: ChatMessage,
        preferPreview: Bool,
        context: IOSMediaCacheScopeContext,
        offline: Bool
    ) async -> URL? {
        let metadata = unifiedAttachmentMetadata(for: message, context: context)
        // WDT_CHAT_MEDIA_CACHE_REUSE_20261102: opening a downloaded image/movie need not fetch a second preview copy.
        if preferPreview, ["image", "video"].contains(attachmentMediaCategory(for: message)),
           let original = await lookupIndexedMediaCache(
            metadata: metadata, messageID: message.id, resourceKind: .original,
            integrity: unifiedAttachmentIntegrity(for: message, resourceKind: .original),
            context: context, offline: offline
           ) {
            return original
        }
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
        conversationID: String? = nil,
        offline: Bool = true
    ) async -> URL? {
        let message = currentAttachmentCacheMessage(message, conversationID: conversationID)
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
        let message = currentAttachmentCacheMessage(message, conversationID: conversationID)
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

    func currentAttachmentCacheMessage(_ message: ChatMessage, conversationID: String?) -> ChatMessage {
        guard let conversationID,
              let current = conversationStore.conversationMessageSnapshot(id: conversationID)?.messages.first(where: { $0.id == message.id }),
              tenantFileID(for: current) == tenantFileID(for: message) else { return message }
        return current
    }

    func unifiedAttachmentMetadata(
        for message: ChatMessage,
        context: IOSMediaCacheScopeContext
    ) -> MediaResourceMetadata {
        let mediaCategory = attachmentMediaCategory(for: message)
        let remoteURL = attachmentRemoteURL(for: message, preferPreview: false)
        let fileExtension = attachmentFileExtension(for: message, remoteURL: remoteURL, mediaCategory: mediaCategory)
        let resource = attachmentResourceComponents(for: message)
        var metadata = MediaResourceMetadata(
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
        // Derived bytes need the original's stable content identity even when version is absent.
        if metadata.version.isEmpty,
           let (kind, value) = metadata.identity(for: .original).contentVersionKindAndValue {
            let derivedVersion = "source:\(kind.rawValue):\(value)"
            metadata.thumbnailVersion = derivedVersion
            metadata.previewVersion = derivedVersion
        }
        if mediaCategory == "video" {
            metadata.thumbnailMimeType = "image/jpeg"
            metadata.thumbnailExtension = "jpg"
        }
        return metadata
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

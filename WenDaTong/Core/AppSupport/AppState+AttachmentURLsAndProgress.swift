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

    // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
    func fileItemForSearchResult(
        fileID: String,
        fallbackName: String,
        ownsSelection: @MainActor () -> Bool
    ) async -> FileItem? {
        let id = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = apiContext
        let session = chatBubbleSessionIdentity
        guard !id.isEmpty, context.hasIMSession, !Task.isCancelled, ownsSelection() else { return nil }
        let scope = remoteDataScopeKey(for: context)
        func isCurrent() -> Bool {
            !Task.isCancelled && chatBubbleSessionIdentity == session && isCurrentRemoteScope(scope)
                && apiContext.tenantAPIBaseURL == context.tenantAPIBaseURL && ownsSelection()
        }
        let fallback = files.first { $0.id == id || $0.remoteFileID == id || $0.remoteLookupID == id }
            ?? FileItem(
                id: id,
                name: fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名文件" : fallbackName,
                type: "文件", size: "未知大小", owner: "", source: "搜索结果", time: "", scope: "",
                status: "正在加载", accentHex: stableSeed(id), remoteFileID: id
            )
        do {
            let detail = try await api.getTenantFile(context: context, fileID: id)
            guard isCurrent() else { return nil }
            let status = detail.file.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard detail.file.id == id, !["deleted", "disabled", "expired"].contains(status) else {
                setToast("文件已失效或暂不可查看")
                return nil
            }
            let file = fileItem(from: detail, fallback: fallback)
            upsertTenantFile(file)
            return file
        } catch {
            guard isCurrent(), !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return nil }
            handleRemoteError(error, fallback: "文件详情加载失败")
            return nil
        }
    }
    // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END

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

    // Android chat posters are derived from the original, not remote image URLs.
    func resolvedAttachmentBubbleThumbnailURL(for message: ChatMessage) -> URL? {
        if attachmentMediaCategory(for: message) == "video" {
            return cachedLocalAttachmentThumbnailURL(for: message)
        }
        return resolvedAttachmentThumbnailURL(for: message)
    }

    // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_BEGIN
    func chatImageThumbnailURL(for message: ChatMessage) -> URL? {
        guard !message.isDeletedLocally, message.status != .recalled,
              let thumbnail = resolvedAttachmentURL(message.attachmentThumbnailURL, allowPosterEndpoint: true),
              ["http", "https"].contains(thumbnail.scheme?.lowercased() ?? "") else { return nil }
        // File detail can report an original URL in the thumbnail field.
        if let original = resolvedAttachmentURL(message.attachmentDownloadURL, allowPosterEndpoint: true),
           original.scheme?.lowercased() == thumbnail.scheme?.lowercased(),
           original.host?.lowercased() == thumbnail.host?.lowercased(),
           original.port == thumbnail.port, original.path == thumbnail.path {
            return nil
        }
        return thumbnail
    }
    // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_END

    func resolvedAttachmentThumbnailURL(for message: ChatMessage) -> URL? {
        // Prefer a derived local poster; a movie URL must never be decoded as an image.
        let category = attachmentMediaCategory(for: message)
        if let localThumbnail = cachedLocalAttachmentThumbnailURL(for: message) {
            return localThumbnail
        }
        let explicit = [
            message.attachmentThumbnailURL,
            message.attachmentCoverURL,
            message.attachmentPosterURL
        ]
            .compactMap { resolvedAttachmentURL($0, allowPosterEndpoint: category == "image" || category == "video") }
            .first
        if let explicit { return explicit }
        if category == "image" {
            return resolvedAttachmentPreviewURL(for: message) ?? resolvedAttachmentDownloadURL(for: message)
        }
        if category == "video" {
            return cachedLocalAttachmentThumbnailURL(for: message)
        }
        return nil
    }

    func loadServerVideoPoster(_ message: ChatMessage, conversationID: String,
        pause: @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        update: @MainActor (IOSVideoPosterPresentation) -> Void) async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let generation = localMessageSessionGeneration
        let parent = tenantFileID(for: message)
        let sourceChecksum = message.attachmentChecksum
        func isCurrent() -> Bool {
            guard !Task.isCancelled, isCurrentRemoteScope(scope), localMessageSessionGeneration == generation,
                  let current = conversationStore.conversationMessageSnapshot(id: conversationID)?.messages.first(where: { $0.id == message.id }) else { return false }
            return !current.isDeletedLocally && current.status != .recalled && tenantFileID(for: current) == parent
                && current.attachmentChecksum == sourceChecksum && current.attachmentVersion == message.attachmentVersion
        }
        guard isCurrent(), let client = api as? IMAPIClient, !parent.isEmpty,
              let cacheContext = mediaCacheScopeContext else { return }
        if let status = await IOSServerVideoPosterReceiptStore.shared.load(root: cacheContext.rootDirectory,
            parentID: parent, checksum: sourceChecksum, sourceVersion: message.attachmentVersion), isCurrent() {
            let integrity = MediaFileIntegrityAuthority(expectedSizeBytes: status.size, expectedSHA256: status.posterChecksum ?? "")
            if let hit = await lookupIndexedMediaCache(metadata: status.metadata(scope: cacheContext.scopeHash),
                messageID: message.id, resourceKind: .thumbnail, variant: .videoPoster, integrity: integrity,
                context: cacheContext, offline: true), isCurrent() {
                update(.ready(hit))
                return
            }
        }
        // WDT_CHAT_MEDIA_CACHE_REUSE_20261102: also reuse covers derived from an already downloaded movie.
        if let hit = await cachedUnifiedAttachmentThumbnailURL(for: message, conversationID: conversationID), isCurrent() {
            update(.ready(hit))
            return
        }
        let budgetKey = "\(cacheContext.scopeHash)|\(parent)"
        func localFallback(_ checksum: String) async {
            guard isCurrent() else { return }
            var source = message
            source.attachmentChecksum = checksum
            // Cache-only: preparing a cover must never download the movie.
            guard let original = await cachedUnifiedAttachmentURL(for: source, preferPreview: false,
                    context: cacheContext, offline: false), isCurrent(),
                  let resources = await AttachmentPreviewResourceBuilder.downloadedPreviewResourcesOffMain(
                    messageID: source.id, localURL: original, mediaCategory: "video"),
                  let poster = resources.thumbnailURL, isCurrent() else {
                if isCurrent() { update(.missing) }
                return
            }
            let cachedPoster = try? await commitIndexedMediaCache(temporaryURL: poster,
                metadata: unifiedAttachmentMetadata(for: message, context: cacheContext),
                resourceKind: .thumbnail, variant: .videoPoster, integrity: MediaFileIntegrityAuthority(),
                messageID: message.id, conversationID: conversationID, context: cacheContext)
            guard isCurrent() else { return }
            update(.ready(cachedPoster ?? poster))
        }
        var refreshedNotReady = false
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        for attempt in 0..<5 {
            guard isCurrent() else { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { update(.pending); return }
            guard await IOSServerVideoPosterBudget.shared.reserve(budgetKey) else { update(.limited); return }
            do {
                let status: IOSServerVideoPosterStatus
                do {
                    status = try await client.serverVideoPosterStatus(context: context, fileID: parent, timeout: min(15, max(0.1, deadline - ProcessInfo.processInfo.systemUptime)))
                } catch IMAPIError.httpStatus(404, _) {
                    // Compatibility with servers without the poster-status contract.
                    let detail = try await client.getTenantFile(context: context, fileID: parent)
                    guard isCurrent(), detail.file.id == parent, detail.downloadAvailable,
                          detail.file.status.lowercased() == "uploaded",
                          !detail.file.checksum.isEmpty,
                          MediaFileIntegrityAuthority.normalizedSHA256(detail.file.checksum.lowercased()) == detail.file.checksum.lowercased(),
                          sourceChecksum.isEmpty || sourceChecksum.lowercased() == detail.file.checksum.lowercased() else {
                        if isCurrent() { update(.unavailable) }; return
                    }
                    await localFallback(detail.file.checksum)
                    return
                }
                guard isCurrent() else { return }
                try status.validate(parentID: parent, expectedChecksum: sourceChecksum)
                switch status.state {
                case .ready:
                    let metadata = status.metadata(scope: cacheContext.scopeHash)
                    let integrity = MediaFileIntegrityAuthority(expectedSizeBytes: status.size, expectedSHA256: status.posterChecksum ?? "")
                    if let hit = await lookupIndexedMediaCache(metadata: metadata, messageID: message.id,
                        resourceKind: .thumbnail, variant: .videoPoster, integrity: integrity,
                        context: cacheContext, offline: false) {
                        await IOSServerVideoPosterReceiptStore.shared.save(status, root: cacheContext.rootDirectory,
                            sourceVersion: message.attachmentVersion)
                        guard isCurrent() else { return }; update(.ready(hit)); return
                    }
                    let bytes: Data
                    do { bytes = try await client.serverVideoPosterBytes(context: context, status: status, timeout: min(15, max(0.1, deadline - ProcessInfo.processInfo.systemUptime))) }
                    catch IOSServerVideoPosterError.http(404, let code, _) where code == "poster_not_ready" && !refreshedNotReady && attempt < 4 {
                        refreshedNotReady = true
                        update(.pending)
                        continue
                    }
                    guard isCurrent() else { return }
                    let staged = try await AttachmentTemporaryFileWriter.writeThumbnailDataOffMain(bytes)
                    do {
                        let url = try await commitIndexedMediaCache(temporaryURL: staged, metadata: metadata,
                            resourceKind: .thumbnail, variant: .videoPoster, integrity: integrity,
                            messageID: message.id, conversationID: conversationID, context: cacheContext)
                        await AttachmentTemporaryFileWriter.removeTemporaryFileOffMain(staged)
                        await IOSServerVideoPosterReceiptStore.shared.save(status, root: cacheContext.rootDirectory,
                            sourceVersion: message.attachmentVersion)
                        guard isCurrent() else { return }; update(.ready(url)); return
                    } catch {
                        await AttachmentTemporaryFileWriter.removeTemporaryFileOffMain(staged)
                        throw error
                    }
                case .pending:
                    update(.pending)
                    if attempt < 4 {
                        let remaining = max(0, min(12, deadline - ProcessInfo.processInfo.systemUptime))
                        try await pause(UInt64(remaining * 1_000_000_000))
                    }
                case .none, .skipped:
                    await localFallback(status.checksum)
                    return
                case .failed:
                    update(.failed); return
                }
            } catch {
                guard isCurrent() else { return }
                if case IMAPIError.httpStatus(429, _) = error {
                    await IOSServerVideoPosterBudget.shared.deferRetry(budgetKey, seconds: 12)
                    update(.limited)
                } else if case IOSServerVideoPosterError.http(429, _, let seconds) = error {
                    await IOSServerVideoPosterBudget.shared.deferRetry(budgetKey, seconds: seconds ?? 12)
                    update(.limited)
                } else { update(.failed) }
                return
            }
        }
    }

    // WDT_CHAT_FIX3_VIDEO_COVER_20261023_BEGIN
    func refreshedAttachmentThumbnailURL(_ message: ChatMessage, conversationID: String, forceLocalPoster: Bool = true) async -> URL? {
        guard attachmentMediaCategory(for: message) == "video" else {
            return try? await prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: true)
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession, attachmentCanRefreshRemoteFile(message) else { return nil }
        do {
            let refreshed: ChatMessage
            if forceLocalPoster {
                // prepareMessageAttachmentLocalFile validates the detail once and shares the download.
                refreshed = message
            } else {
                refreshed = try await refreshedAttachmentMessage(message, in: conversationID, context: context, scope: scope)
            }
            guard !Task.isCancelled, isCurrentRemoteScope(scope) else { return nil }
            if !forceLocalPoster, let poster = resolvedAttachmentThumbnailURL(for: refreshed),
               poster != resolvedAttachmentThumbnailURL(for: message) {
                return poster
            }
            // Legacy callers also use cache-only fallback; never fetch a movie for a poster.
            guard let cacheContext = mediaCacheScopeContext,
                  let localURL = await cachedUnifiedAttachmentURL(for: refreshed, preferPreview: false,
                    context: cacheContext, offline: true), isCurrentRemoteScope(scope), !Task.isCancelled else { return nil }
            let resources = await AttachmentPreviewResourceBuilder.downloadedPreviewResourcesOffMain(
                messageID: refreshed.id, localURL: localURL, mediaCategory: "video")
            guard isCurrentRemoteScope(scope), !Task.isCancelled else { return nil }
            return resources?.thumbnailURL
        } catch {
            return nil
        }
    }
    // WDT_CHAT_FIX3_VIDEO_COVER_20261023_END

    func resolvedAttachmentBestPreviewURL(for message: ChatMessage) -> URL? {
        resolvedAttachmentPreviewURL(for: message)
    }

    func attachmentCanRefreshRemoteFile(_ message: ChatMessage) -> Bool {
        let fileID = tenantFileID(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
        return !fileID.isEmpty
    }

    func chatAttachmentImageCacheKey(for message: ChatMessage, videoPoster: Bool) -> String {
        let resource = attachmentResourceComponents(for: message)
        let stableID = [resource.fileID, resource.attachmentID, resource.mediaID, message.attachmentCacheKey]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? message.id
        return scopedContentCacheIdentity([
            videoPoster ? "chat-server-poster" : "chat-original",
            stableID, message.attachmentChecksum.lowercased(), message.attachmentVersion
        ])
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
        return fileStore.attachmentDownloadSnapshot(attachmentID: progressKey)?.fraction
    }

    func isAttachmentUploadInProgress(_ message: ChatMessage) -> Bool {
        if message.status == .sending { return true }
        if fileStore.hasAttachmentUploadRuntimeState(messageID: message.id) { return true }
        let status = message.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["queued", "retrying", "uploading", "processing", "pending", "in_progress"].contains(status)
    }

    func attachmentProgressKey(for message: ChatMessage, preferPreview: Bool = false) -> String {
        let fileID = message.attachmentFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return attachmentDownloadKey(fileID: fileID.isEmpty ? message.id : fileID,
            version: message.attachmentVersion, preferPreview: preferPreview)
    }

    func attachmentDownloadKey(fileID: String, version: String, preferPreview: Bool) -> String {
        let resource = preferPreview ? "preview" : "original"
        return [contentCacheScopeKey, fileID, version, resource]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    func attachmentDownloadSnapshot(for message: ChatMessage) -> AttachmentDownloadSnapshot? {
        fileStore.attachmentDownloadSnapshot(attachmentID: attachmentProgressKey(for: message))
            ?? fileStore.attachmentDownloadSnapshot(attachmentID: attachmentProgressKey(for: message, preferPreview: true))
    }

    func resolvedAttachmentURL(_ rawValue: String, allowPosterEndpoint: Bool = false) -> URL? {
        let resolved = resolveTenantAssetURL(rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty, let url = URL(string: resolved) else { return nil }
        if isTenantFileAPIEndpoint(resolved) {
            let parts = url.path.split(separator: "/")
            // Image fields can point at poster/thumbnail/cover or other media routes.
            // Only known JSON endpoints are excluded, rather than the whole files prefix.
            let isJSONEndpoint = parts.count <= 4 || (parts.count == 5 && parts.last == "presign-download")
            guard allowPosterEndpoint, !isJSONEndpoint else { return nil }
        }
        return url
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
        for preview in [false, true] {
            let attachmentID = attachmentProgressKey(for: message, preferPreview: preview)
            fileStore.cancelAttachmentDownloadTask(attachmentID: attachmentID)
            fileStore.clearAttachmentDownloadProgress(attachmentID: attachmentID)
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已取消下载")
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

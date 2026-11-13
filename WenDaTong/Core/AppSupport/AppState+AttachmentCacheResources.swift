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
    func attachmentSystemPreviewCacheIdentity(for message: ChatMessage) -> String? {
        let mediaCategory = attachmentMediaCategory(for: message)
        let fallbackExtension = attachmentFileExtension(for: message, remoteURL: resolvedAttachmentBestPreviewURL(for: message), mediaCategory: mediaCategory)
        return attachmentPersistentCacheKey(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension)
    }

    func attachmentMimeType(from message: ChatMessage) -> String {
        message.resolvedAttachmentMimeType
    }

    func uploadedFileMetadata(
        from message: ChatMessage,
        fileIDOverride: String? = nil
    ) -> RemoteAvatarFile? {
        let fileID = (fileIDOverride ?? tenantFileID(for: message))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else { return nil }
        let mediaCategory = attachmentMediaCategory(for: message)
        let fileName = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteAvatarFile(
            id: fileID,
            fileName: fileName.isEmpty ? "attachment" : fileName,
            mimeType: attachmentMimeType(from: message),
            sizeBytes: Int(message.attachmentSizeBytes ?? 0),
            status: "uploaded",
            uploadStatus: "uploaded",
            previewAvailable: message.attachmentPreviewAvailable,
            downloadAvailable: message.attachmentDownloadAvailable || !message.attachmentDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            previewURL: retainedRemoteAttachmentURL(message.attachmentPreviewURL),
            downloadURL: retainedRemoteAttachmentURL(message.attachmentDownloadURL),
            downloadEndpoint: "/api/tenant/files/\(fileID)/presign-download",
            detailEndpoint: "/api/tenant/files/\(fileID)",
            cacheKey: message.attachmentCacheKey,
            version: message.attachmentVersion,
            checksum: message.attachmentChecksum,
            mediaCategory: mediaCategory,
            fileExtension: message.attachmentExtension,
            thumbnailURL: retainedRemoteAttachmentURL(message.attachmentThumbnailURL),
            posterURL: retainedRemoteAttachmentURL(message.attachmentPosterURL),
            coverURL: retainedRemoteAttachmentURL(message.attachmentCoverURL),
            previewKind: message.attachmentPreviewKind.isEmpty ? previewKind(forMediaCategory: mediaCategory) : message.attachmentPreviewKind,
            contentDisposition: message.attachmentContentDisposition,
            width: message.attachmentWidth,
            height: message.attachmentHeight,
            durationSeconds: message.attachmentDurationSeconds
        )
    }

    // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：AppState 只保留附件预览状态编排，具体文件/图片处理交给 support builder
    func localAttachmentPreviewResources(messageID: String, name: String, mimeType: String, data: Data, mediaCategory: String) -> LocalAttachmentPreviewResources? {
        _ = mimeType
        return AttachmentPreviewResourceBuilder.dataPreviewResources(
            messageID: messageID,
            name: name,
            data: data,
            mediaCategory: mediaCategory
        )
    }

    func applyLocalAttachmentPreviewResources(_ localPreview: LocalAttachmentPreviewResources, to message: inout ChatMessage) {
        if let previewURL = localPreview.previewURL {
            message.attachmentPreviewURL = previewURL.absoluteString
            message.attachmentPreviewAvailable = true
        }
        if let downloadURL = localPreview.downloadURL {
            message.attachmentDownloadURL = downloadURL.absoluteString
            message.attachmentDownloadAvailable = true
        }
        if let thumbnailURL = localPreview.thumbnailURL {
            message.attachmentThumbnailURL = thumbnailURL.absoluteString
        }
        message.attachmentWidth = localPreview.width
        message.attachmentHeight = localPreview.height
    }

    func scheduleOutgoingAttachmentPreviewPreparation(
        messageID: String,
        conversationID: String,
        name: String,
        data: Data?,
        fileURL: URL?,
        mediaCategory: String
    ) {
        let generation = localMessageSessionGeneration
        Task(priority: .utility) { [weak self] in
            let resources = await AttachmentPreviewResourceBuilder.outgoingPreviewResourcesOffMain(
                messageID: messageID,
                name: name,
                data: data,
                fileURL: fileURL,
                mediaCategory: mediaCategory
            )
            guard let resources,
                  let self,
                  self.localMessageSessionGeneration == generation,
                  var message = self.conversationStore.conversationMessageSnapshot(id: conversationID)?
                    .messages
                    .first(where: { $0.id == messageID }) else { return }
            self.cacheLocalAttachmentResources(resources, messageID: messageID)
            self.applyLocalAttachmentPreviewResources(resources, to: &message)
            self.updateMessageAttachment(message, in: conversationID)
            self.chatBackSendDiagnostic(
                "app_send_attachment_preview_applied",
                conversationID: conversationID,
                messageID: messageID,
                extra: "media=\(mediaCategory)"
            )
        }
    }
    // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束

    func cacheLocalAttachmentResources(_ resources: LocalAttachmentPreviewResources, messageID: String, fileID: String? = nil, cacheIdentity: String? = nil) {
        let keys = [cacheIdentity ?? "", messageID, fileID ?? ""]
            .compactMap(scopedContentCacheKey)
        guard !keys.isEmpty else { return }
        fileStore.cacheLocalAttachmentResources(resources, cacheKeys: keys)
    }

    private func cacheStableLocalAttachmentResources(
        _ resources: LocalAttachmentPreviewResources,
        for message: ChatMessage,
        mediaCategory: String,
        fallbackExtension: String
    ) {
        cacheLocalAttachmentResources(resources, messageID: message.id, fileID: message.attachmentFileID)
        if let cacheIdentity = attachmentStableCacheIdentity(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension) {
            cacheLocalAttachmentResources(
                resources,
                messageID: message.id,
                fileID: message.attachmentFileID,
                cacheIdentity: cacheIdentity
            )
        }
    }

    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
    func attachmentResourceCacheKeys(for message: ChatMessage) -> [String] {
        let mediaCategory = attachmentMediaCategory(for: message)
        let fallbackExtension = attachmentFileExtension(for: message, remoteURL: nil, mediaCategory: mediaCategory)
        let cacheIdentity = attachmentStableCacheIdentity(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension)
        return [cacheIdentity ?? "", message.attachmentFileID ?? "", message.id].compactMap(scopedContentCacheKey)
    }

    func cachedLocalAttachmentResources(for message: ChatMessage) -> LocalAttachmentPreviewResources? {
        for key in attachmentResourceCacheKeys(for: message) {
            if let resources = fileStore.localAttachmentResources(cacheKey: key), resources.hasUsableLocalFile {
                return resources
            }
        }
        // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END
        let previewURL = URL(string: message.attachmentPreviewURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let downloadURL = URL(string: message.attachmentDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let thumbnailURL = URL(string: message.attachmentThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let resources = LocalAttachmentPreviewResources(
            previewURL: previewURL?.usableLocalFileURL,
            downloadURL: downloadURL?.usableLocalFileURL,
            thumbnailURL: thumbnailURL?.usableLocalFileURL,
            width: message.attachmentWidth,
            height: message.attachmentHeight
        )
        return resources.hasUsableLocalFile ? resources : nil
    }

    func cachedLocalAttachmentURL(for message: ChatMessage, preferPreview: Bool) -> URL? {
        guard let resources = cachedLocalAttachmentResources(for: message) else { return nil }
        let preferred = preferPreview
            ? [resources.previewURL, resources.downloadURL]
            : [resources.downloadURL, resources.previewURL]
        return preferred.compactMap { $0?.usableLocalFileURL }.first
    }

    func cachedLocalAttachmentThumbnailURL(for message: ChatMessage) -> URL? {
        guard let resources = cachedLocalAttachmentResources(for: message) else { return nil }
        // WDT_CHAT_FIX3_VIDEO_COVER_20261023: only a real local poster is a valid video thumbnail fallback.
        if attachmentMediaCategory(for: message) == "video" {
            return resources.thumbnailURL?.usableLocalFileURL
        }
        return [resources.thumbnailURL, resources.previewURL, resources.downloadURL]
            .compactMap { $0?.usableLocalFileURL }
            .first
    }

    // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：本地文件预览生成委托给 support builder
    func localAttachmentPreviewResources(for message: ChatMessage, localURL: URL, mediaCategory: String) -> LocalAttachmentPreviewResources? {
        AttachmentPreviewResourceBuilder.localFilePreviewResources(
            messageID: message.id,
            localURL: localURL,
            mediaCategory: mediaCategory
        )
    }
    // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束

    func attachmentPersistentCacheKey(for message: ChatMessage, mediaCategory: String, fallbackExtension: String) -> String {
        if let stableIdentity = attachmentStableCacheIdentity(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension) {
            return stableIdentity
        }
        let primaryID = (message.attachmentFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            ? message.id
            : (message.attachmentFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? message.id)
        let size = message.attachmentSizeBytes.map(String.init) ?? "unknown-size"
        let updated = message.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return scopedContentCacheIdentity([
            primaryID,
            size,
            mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            updated
        ])
    }

    func attachmentStableCacheIdentity(for message: ChatMessage, mediaCategory: String, fallbackExtension: String) -> String? {
        let resource = attachmentResourceComponents(for: message)
        let cacheKey = message.attachmentCacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceComponent: String
        if !resource.fileID.isEmpty {
            resourceComponent = "file_id:\(resource.fileID)"
        } else if !resource.attachmentID.isEmpty {
            resourceComponent = "attachment_id:\(resource.attachmentID)"
        } else if !resource.mediaID.isEmpty {
            resourceComponent = "media_id:\(resource.mediaID)"
        } else if !cacheKey.isEmpty {
            resourceComponent = "cache_key:\(cacheKey)"
        } else {
            return nil
        }
        let version = message.attachmentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = message.attachmentChecksum.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = message.attachmentSizeBytes.map(String.init) ?? ""
        return scopedContentCacheIdentity([
            resourceComponent,
            version.isEmpty ? "" : "version:\(version)",
            checksum.isEmpty ? "" : "checksum:\(checksum)",
            size.isEmpty ? "" : "size:\(size)",
            mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ])
    }

    func scopedContentCacheIdentity(_ parts: [String]) -> String {
        let payload = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ([currentContentCacheScopePrefix()] + payload).joined(separator: "|")
    }

    func scopedContentCacheKey(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let currentScopePrefix = currentContentCacheScopePrefix()
        if trimmed.hasPrefix("scope:") {
            guard trimmed == currentScopePrefix || trimmed.hasPrefix("\(currentScopePrefix)|") else {
                return nil
            }
            return trimmed
        }
        return scopedContentCacheIdentity([trimmed])
    }

    private func currentContentCacheScopePrefix() -> String {
        let scope = contentCacheScopeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return scope.isEmpty ? "scope:missing" : "scope:\(scope)"
    }

    func attachmentFileExtension(for message: ChatMessage, remoteURL: URL?, mediaCategory: String) -> String {
        let explicit = message.attachmentExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nameExtension = ((message.attachmentName ?? message.text) as NSString).pathExtension.lowercased()
        let remoteExtension = remoteURL?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let value = [explicit, nameExtension, remoteExtension].first(where: { !$0.isEmpty }) {
            return sanitizedAttachmentFileExtension(value)
        }

        let mimeType = attachmentMimeType(from: message)
        if mimeType.contains("mp4") { return "mp4" }
        if mimeType.contains("quicktime") { return "mov" }
        if mimeType.contains("webm") { return "webm" }
        if mimeType.contains("x-matroska") { return "mkv" }
        if mimeType.contains("jpeg") { return "jpg" }
        if mimeType.contains("png") { return "png" }
        if mimeType.contains("gif") { return "gif" }
        if mimeType.contains("heic") { return "heic" }
        if mimeType.contains("pdf") { return "pdf" }

        switch mediaCategory {
        case "video": return "mp4"
        case "image": return "jpg"
        case "pdf": return "pdf"
        default: return ""
        }
    }

    private func sanitizedAttachmentFileExtension(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitized = String(rawValue.lowercased().unicodeScalars.filter { allowed.contains($0) })
        return String(sanitized.prefix(8))
    }

    func previewKind(forMediaCategory category: String) -> String {
        switch category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "image": return "image"
        case "video": return "video"
        case "pdf": return "pdf"
        case "voice": return "voice"
        case "audio": return "audio"
        default: return "download"
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

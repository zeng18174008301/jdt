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
import IM4Stores // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112

extension AppState {
    struct StickerUploadFileDescriptor {
        let fileName: String
        let mimeType: String
        let fileExtension: String
    }

    private struct PreparedStickerUploadFile {
        let data: Data
        let fileName: String
        let mimeType: String
        let fileExtension: String
    }

    // WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110: resolved sticker file values live in Domain/StickerMessageModels.swift.

    func performStickerImageUpload(
        uploadID: String,
        data: Data,
        fileName: String,
        mimeType: String,
        fileExtension: String,
        conversation: ConversationMessageSnapshot,
        context: IMAPIContext,
        binding: StickerStore.Binding
    ) async {
        guard isCurrentStickerLibrary(binding) else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        stickerStore.updateLocalUpload(id: uploadID, phase: .compressing, binding: binding)
        do {
            let preparedFile = prepareStickerUploadFile(
                data: data,
                fileName: fileName,
                mimeType: mimeType,
                fileExtension: fileExtension
            )
            let remoteConfig = try await fetchScopedFileUploadConfig(context: context, scope: remoteDataScopeKey(for: context)) // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
            guard isCurrentStickerLibrary(binding) else {
                return
            }
            let config = remoteConfig.model
            guard preparedFile.data.count <= config.maxBytes else {
                stickerStore.failLocalUpload(id: uploadID, binding: binding)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(config.overLimitMessage)
                return
            }
            let channelID = remoteChannelID(for: conversation)
            stickerStore.updateLocalUpload(id: uploadID, phase: .uploading, progress: 0.08, binding: binding)
            let presign = try await api.presignFileUpload(
                context: context,
                conversation: conversation,
                channelID: channelID,
                clientMessageID: "",
                purpose: "user_sticker",
                fileName: preparedFile.fileName,
                mimeType: preparedFile.mimeType,
                sizeBytes: preparedFile.data.count
            )
            guard isCurrentStickerLibrary(binding) else {
                return
            }
            stickerStore.updateLocalUpload(id: uploadID, phase: .uploading, progress: 0.18, binding: binding)
            // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_STICKER_UPLOAD_GUARD - 修改开始：贴纸仍要求上传描述，避免聊天附件兼容影响贴纸业务
            guard let upload = presign.upload else {
                throw IMAPIError.server("sticker_upload_descriptor_missing")
            }
            try await api.uploadFileBinary(upload: upload, data: preparedFile.data, mimeType: preparedFile.mimeType) { [weak self] fraction in
                let progress = 0.18 + max(0, min(fraction, 1)) * 0.58
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentStickerLibrary(binding) else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
                    self.stickerStore.updateLocalUpload(id: uploadID, phase: .uploading, progress: progress, binding: binding)
                }
            }
            // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_STICKER_UPLOAD_GUARD - 修改结束
            guard isCurrentStickerLibrary(binding) else {
                return
            }
            stickerStore.updateLocalUpload(id: uploadID, phase: .processing, binding: binding)
            let uploadedFile = try await api.markFileUploaded(context: context, fileID: presign.file.id)
            let completedFile = uploadedFile.merged(with: presign.file)
            guard isCurrentStickerLibrary(binding) else {
                return
            }
            let commit = try await api.commitUserSticker(context: context, fileID: completedFile.id, name: preparedFile.fileName)
            guard isCurrentStickerLibrary(binding) else {
                return
            }
            // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
            let committedItem = await hydrateStickerLibraryItem(StickerLibraryItem(commitResult: commit),
                context: context, manifest: stickerLibraryHydration(binding: binding))
            guard isCurrentStickerLibrary(binding) else { return }
            // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
            stickerStore.replaceLocalUpload(id: uploadID, with: committedItem, binding: binding)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("表情已提交处理，完成后可发送")
            await refreshUserStickerManifest(force: true, silent: true)
            scheduleStickerManifestPollIfNeeded(runtime: binding)
        } catch {
            guard isCurrentStickerLibrary(binding) else {
                return
            }
            stickerStore.failLocalUpload(id: uploadID, binding: binding)
            handleRemoteError(error, fallback: "表情上传失败")
        }
    }

    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    func deleteUserSticker(_ item: StickerLibraryItem, binding: StickerStore.Binding) async {
        guard isCurrentStickerLibrary(binding) else { return }
        if item.isLocalUploadPlaceholder {
            stickerStore.removeLocalUpload(id: item.id, binding: binding)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已移除表情")
            return
        }
        let id = item.id.isEmpty ? item.stickerID : item.id
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let context = apiContext
        stickerStore.beginDeleting(id: id)
        do {
            _ = try await api.deleteUserSticker(context: context, id: id)
            guard isCurrentStickerLibrary(binding) else { return }
            stickerStore.removeMySticker(id: id, binding: binding)
            stickerStore.finishDeleting(id: id)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已删除表情")
            await refreshUserStickerManifest(force: true, silent: true)
        } catch {
            guard isCurrentStickerLibrary(binding) else { return }
            stickerStore.finishDeleting(id: id)
            handleRemoteError(error, fallback: "删除表情失败")
        }
    }

    func moveUserSticker(_ item: StickerLibraryItem, direction: Int, binding: StickerStore.Binding) async {
        guard !item.isLocalUploadPlaceholder, isCurrentStickerLibrary(binding) else { return }
        let context = apiContext
        guard let ids = stickerStore.moveUserSticker(id: item.id, direction: direction, binding: binding) else { return }
        stickerStore.beginSorting(ids: ids)
        do {
            let remoteItems = try await api.orderUserStickers(context: context, ids: ids)
            guard isCurrentStickerLibrary(binding) else { return }
            if !remoteItems.isEmpty {
                let items = await hydrateStickerLibraryItems(remoteItems.map(StickerLibraryItem.init(remote:)),
                    context: context, manifest: stickerLibraryHydration(binding: binding))
                guard isCurrentStickerLibrary(binding) else { return }
                stickerStore.replaceMyStickers(items, binding: binding)
            }
            stickerStore.finishSorting(ids: ids)
        } catch {
            guard isCurrentStickerLibrary(binding) else { return }
            stickerStore.finishSorting(ids: ids)
            await refreshUserStickerManifest(force: true, silent: true)
            guard isCurrentStickerLibrary(binding) else { return }
            handleRemoteError(error, fallback: "表情排序失败")
        }
    }

    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END

    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN
    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
    func hydrateStickerLibraryItems(
        _ items: [StickerLibraryItem], context: IMAPIContext,
        manifest: StickerManifestHydration? = nil
    ) async -> [StickerLibraryItem] {
        var fileCache: [String: StickerResolvedFileAsset] = [:]
        var hydrated: [StickerLibraryItem] = []
        hydrated.reserveCapacity(items.count)
        for item in items {
            guard manifest?.isCurrent() != false else { return [] }
            hydrated.append(await hydrateStickerLibraryItem(item, context: context, fileCache: &fileCache, manifest: manifest))
        }
        return hydrated
    }
    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END

    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    private func stickerLibraryHydration(binding: StickerStore.Binding) -> StickerManifestHydration {
        StickerManifestHydration(operation: nil, isCurrent: {
            !Task.isCancelled && self.isCurrentStickerLibrary(binding)
        })
    }

    private func hydrateStickerLibraryItem(_ item: StickerLibraryItem, context: IMAPIContext,
        manifest: StickerManifestHydration) async -> StickerLibraryItem {
        var fileCache: [String: StickerResolvedFileAsset] = [:]
        return await hydrateStickerLibraryItem(item, context: context, fileCache: &fileCache, manifest: manifest)
    }
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END

    private func hydrateStickerLibraryItem(
        _ item: StickerLibraryItem,
        context: IMAPIContext,
        fileCache: inout [String: StickerResolvedFileAsset],
        manifest: StickerManifestHydration? = nil // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
    ) async -> StickerLibraryItem {
        var nextThumbnailURL = stickerRenderableURL(item.thumbnailURL)
        if nextThumbnailURL.isEmpty {
            let thumbnailFileID = tenantFileID(from: item.thumbnailURL) ?? item.fileID
            nextThumbnailURL = await signedStickerFileURL(fileID: thumbnailFileID, preferThumbnail: true, context: context, fileCache: &fileCache, manifest: manifest) // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
        }

        let nextVariants = await hydrateStickerVariants(item.variants, context: context, fileCache: &fileCache, manifest: manifest) // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
        return StickerLibraryItem(
            id: item.id,
            stickerID: item.stickerID,
            fileID: item.fileID,
            packID: item.packID,
            source: item.source,
            status: item.status,
            processingStatus: item.processingStatus,
            sort: item.sort,
            mimeType: item.mimeType,
            sizeBytes: item.sizeBytes,
            width: item.width,
            height: item.height,
            durationMS: item.durationMS,
            frameCount: item.frameCount,
            cacheKey: item.cacheKey,
            version: item.version,
            thumbnailURL: nextThumbnailURL.isEmpty ? item.thumbnailURL : nextThumbnailURL,
            variants: nextVariants,
            errorCode: item.errorCode,
            errorReason: item.errorReason,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            displayName: item.displayName,
            packName: item.packName,
            uploadPhase: item.uploadPhase,
            uploadProgress: item.uploadProgress
        )
    }

    func stickerLibraryFileIDs(for item: StickerLibraryItem) -> [String] {
        var ordered: [String] = []
        func append(_ raw: String?) {
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty, !ordered.contains(value) else { return }
            ordered.append(value)
        }
        append(tenantFileID(from: item.thumbnailURL))
        append(item.fileID)
        for variant in item.variants {
            append(tenantFileID(from: variant.thumbnailURL))
            append(tenantFileID(from: variant.assetURL))
            append(variant.fileID)
        }
        return ordered
    }

    private func hydrateStickerVariants(
        _ variants: [StickerAssetVariant],
        context: IMAPIContext,
        fileCache: inout [String: StickerResolvedFileAsset],
        manifest: StickerManifestHydration? // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
    ) async -> [StickerAssetVariant] {
        var hydrated: [StickerAssetVariant] = []
        hydrated.reserveCapacity(variants.count)
        for variant in variants {
            var assetURL = stickerRenderableURL(variant.assetURL)
            if assetURL.isEmpty {
                let assetFileID = tenantFileID(from: variant.assetURL) ?? variant.fileID
                assetURL = await signedStickerFileURL(fileID: assetFileID, preferThumbnail: false, context: context, fileCache: &fileCache, manifest: manifest) // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
            }

            var thumbnailURL = stickerRenderableURL(variant.thumbnailURL)
            if thumbnailURL.isEmpty {
                let thumbnailFileID = tenantFileID(from: variant.thumbnailURL) ?? variant.fileID
                thumbnailURL = await signedStickerFileURL(fileID: thumbnailFileID, preferThumbnail: true, context: context, fileCache: &fileCache, manifest: manifest) // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
            }

            hydrated.append(StickerAssetVariant(
                kind: variant.kind,
                fileID: variant.fileID,
                mimeType: variant.mimeType,
                assetURL: assetURL.isEmpty ? variant.assetURL : assetURL,
                sizeBytes: variant.sizeBytes,
                width: variant.width,
                height: variant.height,
                durationMS: variant.durationMS,
                frameCount: variant.frameCount,
                thumbnailURL: thumbnailURL.isEmpty ? variant.thumbnailURL : thumbnailURL,
                cacheKey: variant.cacheKey
            ))
        }
        return hydrated
    }

    private func signedStickerFileURL(
        fileID: String,
        preferThumbnail: Bool,
        context: IMAPIContext,
        fileCache: inout [String: StickerResolvedFileAsset],
        manifest: StickerManifestHydration? // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
    ) async -> String {
        let normalizedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard manifest?.isCurrent() != false, !normalizedFileID.isEmpty, context.hasIMSession else { return "" } // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
        let file: StickerResolvedFileAsset
        if let cached = fileCache[normalizedFileID] {
            file = cached
        } else {
            do {
                let detail = try await api.getTenantFile(context: context, fileID: normalizedFileID)
                guard manifest?.isCurrent() != false else { return "" } // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
                var resolvedFile = StickerResolvedFileAsset(
                    fileID: detail.file.id.isEmpty ? normalizedFileID : detail.file.id,
                    fileName: detail.file.fileName,
                    mimeType: detail.file.mimeType,
                    sizeBytes: detail.file.sizeBytes,
                    cacheKey: detail.file.cacheKey,
                    version: detail.file.version,
                    checksum: detail.file.checksum,
                    thumbnailURL: detail.file.thumbnailURL,
                    previewURL: detail.previewURL,
                    downloadURL: detail.downloadURL
                )
                resolvedFile = await hydrateLocalStickerResolvedFileAsset(resolvedFile, context: context, manifest: manifest)
                guard manifest?.isCurrent() != false else { return "" } // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
                file = resolvedFile
                fileCache[normalizedFileID] = resolvedFile
                if !resolvedFile.fileID.isEmpty, resolvedFile.fileID != normalizedFileID {
                    fileCache[resolvedFile.fileID] = resolvedFile
                }
            } catch {
                return ""
            }
        }
        let candidates = preferThumbnail
            ? [file.localThumbnailURL, file.localPreviewURL, file.localDownloadURL, file.thumbnailURL, file.previewURL, file.downloadURL]
            : [file.localDownloadURL, file.localPreviewURL, file.localThumbnailURL, file.downloadURL, file.previewURL, file.thumbnailURL]
        return candidates
            .map(stickerRenderableURL)
            .first { !$0.isEmpty } ?? ""
    }

    func stickerRenderableURL(_ rawValue: String) -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        return resolvedStickerAssetURLString(raw)
    }

    func tenantFileID(from rawValue: String) -> String? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let path: String
        if let url = URL(string: raw), url.scheme != nil {
            path = url.path
        } else {
            path = raw
        }
        let parts = path
            .split(separator: "/")
            .map(String.init)
        guard let filesIndex = parts.firstIndex(of: "files"),
              parts.indices.contains(filesIndex + 1) else {
            return nil
        }
        let fileID = parts[filesIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return fileID.isEmpty ? nil : fileID
    }

    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN
    func scheduleStickerManifestPollIfNeeded(runtime: StickerStore.Binding) { // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        let binding = stickerManifestBinding(context: apiContext, runtime: runtime)
        guard isCurrentStickerManifestBinding(binding),
              stickerStore.myStickers.contains(where: { $0.isProcessing }) else { return }
        stickerManifestPollTask?.cancel()
        stickerManifestPollTask = Task { [weak self] in
            defer {
                if let self, !Task.isCancelled, self.isCurrentStickerManifestBinding(binding) {
                    self.stickerManifestPollTask = nil
                }
            }
            for attempt in 0..<12 {
                let delayNs = UInt64(min(12, 2 + attempt)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled, let self, self.isCurrentStickerManifestBinding(binding),
                      self.stickerStore.myStickers.contains(where: { $0.isProcessing }) else { return }
                await self.refreshUserStickerManifest(force: true, silent: true, schedulePoll: false)
            }
        }
    }
    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END

    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END

    private func prepareStickerUploadFile(
        data: Data,
        fileName: String,
        mimeType: String,
        fileExtension: String
    ) -> PreparedStickerUploadFile {
        let normalizedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let original = PreparedStickerUploadFile(
            data: data,
            fileName: fileName,
            mimeType: mimeType,
            fileExtension: normalizedExtension
        )
        guard normalizedExtension != "gif",
              let image = UIImage(data: data),
              image.size.width > 0,
              image.size.height > 0 else {
            return original
        }

        let maxLongSide: CGFloat = 512
        let longSide = max(image.size.width, image.size.height)
        let scale = longSide > 0 ? min(1, maxLongSide / longSide) : 1
        let targetSize = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        let hasAlpha = stickerImageHasAlpha(image)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        if hasAlpha, let pngData = resized.pngData(), pngData.count < data.count {
            return PreparedStickerUploadFile(
                data: pngData,
                fileName: normalizedStickerFileName(fileName, preferredExtension: "png"),
                mimeType: "image/png",
                fileExtension: "png"
            )
        }

        let jpegCandidates: [CGFloat] = [0.82, 0.74, 0.66, 0.58]
        let jpegData = jpegCandidates
            .compactMap { quality in resized.jpegData(compressionQuality: quality) }
            .first { $0.count < data.count } ?? resized.jpegData(compressionQuality: 0.58)
        guard let jpegData, jpegData.count < data.count else {
            return original
        }
        return PreparedStickerUploadFile(
            data: jpegData,
            fileName: normalizedStickerFileName(fileName, preferredExtension: "jpg"),
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )
    }

    private func stickerImageHasAlpha(_ image: UIImage) -> Bool {
        guard let alphaInfo = image.cgImage?.alphaInfo else { return false }
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    func stickerUploadFileDescriptor(data: Data, name: String) -> StickerUploadFileDescriptor? {
        guard let fileExtension = supportedStickerUploadExtension(data: data, name: name) else { return nil }
        return StickerUploadFileDescriptor(
            fileName: normalizedStickerFileName(name, preferredExtension: fileExtension),
            mimeType: stickerUploadMimeType(fileExtension: fileExtension),
            fileExtension: fileExtension
        )
    }

    private func supportedStickerUploadExtension(data: Data, name: String) -> String? {
        let declaredExtension = (name.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .pathExtension
            .lowercased()
        if ["gif", "png", "jpg", "jpeg"].contains(declaredExtension) {
            return declaredExtension
        }
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 6,
           bytes[0] == 0x47,
           bytes[1] == 0x49,
           bytes[2] == 0x46,
           bytes[3] == 0x38,
           (bytes[4] == 0x37 || bytes[4] == 0x39),
           bytes[5] == 0x61 {
            return "gif"
        }
        if bytes.count >= 8,
           bytes[0] == 0x89,
           bytes[1] == 0x50,
           bytes[2] == 0x4E,
           bytes[3] == 0x47,
           bytes[4] == 0x0D,
           bytes[5] == 0x0A,
           bytes[6] == 0x1A,
           bytes[7] == 0x0A {
            return "png"
        }
        if bytes.count >= 3,
           bytes[0] == 0xFF,
           bytes[1] == 0xD8,
           bytes[2] == 0xFF {
            return "jpg"
        }
        return nil
    }

    private func stickerUploadMimeType(fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        default:
            return "image/gif"
        }
    }

    private func normalizedStickerFileName(_ raw: String, preferredExtension: String = "gif") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackExtension = ["gif", "png", "jpg", "jpeg"].contains(preferredExtension.lowercased())
            ? preferredExtension.lowercased()
            : "gif"
        if trimmed.isEmpty { return "我的表情.\(fallbackExtension)" }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        if ["gif", "png", "jpg", "jpeg"].contains(ext) { return trimmed }
        let base = (trimmed as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base.isEmpty ? "我的表情" : base).\(fallbackExtension)"
    }

    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    func stickerRuntimeScope(for context: IMAPIContext) -> LocalMessageScope? {
        guard context.hasIMSession, !context.appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? LocalMessageScope(context: context)
    }

    func activateStickerLibrary() -> StickerStore.Binding? {
        let context = apiContext
        guard let scope = stickerRuntimeScope(for: context) else {
            if stickerStore.activeBinding != nil { stickerStore.resetRuntime() }
            return nil
        }
        return stickerStore.activate(scope: scope, legacyKey: stickerLibraryScopeKey(for: context))
    }

    func isCurrentStickerLibrary(_ binding: StickerStore.Binding) -> Bool {
        stickerStore.activeBinding == binding && stickerRuntimeScope(for: apiContext) == binding.scope
    }
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END

    func stickerLibraryScopeKey(for context: IMAPIContext) -> String {
        [
            context.tenantID ?? "",
            context.imUID ?? "",
            context.accountID ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    func isCurrentStickerScope(_ scope: String) -> Bool {
        apiContext.hasIMSession && stickerLibraryScopeKey(for: apiContext) == scope
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

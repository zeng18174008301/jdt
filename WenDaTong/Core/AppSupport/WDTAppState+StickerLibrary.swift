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

// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_BEGIN
// MARK: - Sticker Library

extension AppState {
    // WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110
    func reconcileStickerMessageAssetAuthority(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
        guard oldContext.hasIMSession != newContext.hasIMSession
            || oldContext.authSessionFence != newContext.authSessionFence
            || stickerRuntimeScope(for: oldContext) != stickerRuntimeScope(for: newContext) else { return }
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
        reconcileStickerManifestAuthority(from: oldContext, to: newContext) // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
        stickerMessageAssetStore.reset()
        resolvingStickerMessageFileAssetKeys.removeAll()
        failedStickerMessageFileAssetKeys.removeAll()
    }

    func stickerMessageAssetPresentation(
        for message: ChatMessage,
        snapshot: StickerMessageAssetStore.Snapshot
    ) -> StickerMessageAssetStore.Presentation {
        StickerMessageAssetStore.Presentation(
            thumbnailURL: resolvedStickerThumbnailURL(for: message.stickerSnapshot, files: snapshot.files),
            animationURL: resolvedStickerAnimationURL(for: message.stickerSnapshot, files: snapshot.files),
            requestKey: [
                stickerLibraryScopeKey(for: apiContext), snapshot.generation.uuidString,
                message.stickerSnapshot?.cacheIdentity ?? message.id
            ].joined(separator: "|")
        )
    }

    private func isCurrentStickerMessageAssetRequest(context: IMAPIContext, generation: UUID) -> Bool {
        generation == stickerMessageAssetStore.snapshot.generation
            && apiContext.isSameAuthAuthority(as: context.authSessionFence)
            && isCurrentStickerScope(stickerLibraryScopeKey(for: context))
    }
    // WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110

    func prepareStickerExpressionPanel(force: Bool = false) async {
        guard !Task.isCancelled else { return } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        let context = apiContext
        // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
        guard let runtime = activateStickerLibrary() else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        if stickerStore.isManifestRefreshing {
            await refreshUserStickerManifest(force: force, silent: true)
            return
        }
        let binding = stickerManifestBinding(context: context, runtime: runtime) // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        let operation = beginStickerManifestOperation()
        await hydrateCachedStickerManifestIfNeeded(context: context, binding: binding, operation: operation)
        guard !Task.isCancelled, ownsStickerManifest(operation, binding: binding) else { return }
        await refreshUserStickerManifest(force: force, silent: true, continuing: operation)
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
        // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END
    }

    func refreshStickerExpressionPanel() {
        Task {
            await prepareStickerExpressionPanel(force: true)
        }
    }

    func officialStickers(packID: String) -> [StickerLibraryItem] {
        stickerStore.officialStickers(packID: packID)
    }

    func stickerThumbnailURL(for item: StickerLibraryItem) -> String {
        let raw = [
            item.thumbnailURL,
            item.variants.first(where: { !$0.thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.thumbnailURL ?? "",
            item.variants.first(where: { !$0.assetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.assetURL ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        guard !raw.isEmpty else { return "" }
        return resolvedStickerAssetURLString(raw)
    }

    func resolvedStickerAssetURLString(_ rawValue: String) -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isTenantFileAPIEndpoint(raw) else { return "" }
        let resolved = resolveTenantAssetURL(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty, !isTenantFileAPIEndpoint(resolved) else { return "" }
        return resolved
    }

    func resolvedStickerThumbnailURL(for snapshot: StickerMessageSnapshot?) -> URL? {
        resolvedStickerThumbnailURL(for: snapshot, files: stickerMessageFileAssets)
    }

    func resolvedStickerThumbnailURL(for snapshot: StickerMessageSnapshot?, files: [String: StickerResolvedFileAsset]) -> URL? {
        guard let snapshot else { return nil }
        let cached = stickerMessageFileURL(for: snapshot, preferThumbnail: true, files: files)
        if !cached.isEmpty {
            return URL(string: cached)
        }
        let raw = [
            snapshot.thumbnailURL,
            snapshot.variants.first(where: { !$0.thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.thumbnailURL ?? "",
            snapshot.variants.first(where: { !$0.assetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.assetURL ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let resolved = resolvedStickerAssetURLString(raw)
        if !resolved.isEmpty {
            return URL(string: resolved)
        }
        return nil
    }

    func resolvedStickerAnimationURL(for snapshot: StickerMessageSnapshot?) -> URL? {
        resolvedStickerAnimationURL(for: snapshot, files: stickerMessageFileAssets)
    }

    func resolvedStickerAnimationURL(for snapshot: StickerMessageSnapshot?, files: [String: StickerResolvedFileAsset]) -> URL? {
        guard let snapshot else { return nil }
        let cached = stickerMessageFileURL(for: snapshot, preferThumbnail: false, files: files)
        if !cached.isEmpty {
            return URL(string: cached)
        }
        let preferredVariant = preferredStickerVariant(for: snapshot)
        let raw = [
            preferredVariant?.assetURL ?? "",
            preferredVariant?.thumbnailURL ?? "",
            snapshot.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image/gif" ? snapshot.thumbnailURL : ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let resolved = resolvedStickerAssetURLString(raw)
        if !resolved.isEmpty {
            return URL(string: resolved)
        }
        return resolvedStickerThumbnailURL(for: snapshot, files: files)
    }

    func resolveStickerMessageAssetsIfNeeded(for snapshot: StickerMessageSnapshot?) {
        guard let snapshot else { return }
        let context = apiContext
        guard context.hasIMSession else { return }
        let generation = stickerMessageAssetStore.snapshot.generation
        let fileIDs = stickerMessageFileIDs(for: snapshot)
        guard !fileIDs.isEmpty else { return }
        for fileID in fileIDs {
            let cacheKey = stickerMessageFileAssetCacheKey(fileID: fileID, context: context)
            guard !stickerMessageFileAssets.keys.contains(cacheKey),
                  !resolvingStickerMessageFileAssetKeys.contains(cacheKey),
                  !failedStickerMessageFileAssetKeys.contains(cacheKey) else {
                continue
            }
            resolvingStickerMessageFileAssetKeys.insert(cacheKey)
            Task { [weak self] in
                await self?.resolveStickerMessageFileAsset(fileID: fileID, cacheKey: cacheKey, context: context, generation: generation)
            }
        }
    }

    func stickerAnimationCacheKey(for message: ChatMessage) -> String {
        let snapshot = message.stickerSnapshot
        let preferredVariant = snapshot.flatMap(preferredStickerVariant(for:))
        let identity = [
            snapshot?.fileID ?? "",
            preferredVariant?.cacheKey ?? "",
            preferredVariant?.kind ?? "",
            snapshot?.stickerID ?? "",
            message.id
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
        return "sticker-gif|\(identity.isEmpty ? message.id : identity)"
    }

    private func preferredStickerVariant(for snapshot: StickerMessageSnapshot) -> StickerMessageVariantSnapshot? {
        snapshot.variants.first { variant in
            let kind = variant.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let mime = variant.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return mime == "image/gif" || ["gif", "original", "source", "full", "animated"].contains(kind)
        } ?? snapshot.variants.first
    }

    private func stickerMessageFileURL(for snapshot: StickerMessageSnapshot, preferThumbnail: Bool, files: [String: StickerResolvedFileAsset]) -> String {
        let context = apiContext
        guard context.hasIMSession else { return "" }
        let fileIDs = preferThumbnail
            ? stickerMessageFileIDs(for: snapshot)
            : stickerMessageAnimationFileIDs(for: snapshot)
        for fileID in fileIDs {
            let cacheKey = stickerMessageFileAssetCacheKey(fileID: fileID, context: context)
            guard let file = files[cacheKey] else { continue }
            let candidates = preferThumbnail
                ? [file.localThumbnailURL, file.localPreviewURL, file.localDownloadURL, file.thumbnailURL, file.previewURL, file.downloadURL]
                : [file.localDownloadURL, file.localPreviewURL, file.localThumbnailURL, file.downloadURL, file.previewURL, file.thumbnailURL]
            if let url = candidates
                .map(stickerRenderableURL)
                .first(where: { !$0.isEmpty }) {
                return url
            }
        }
        return ""
    }

    private func stickerMessageFileIDs(for snapshot: StickerMessageSnapshot) -> [String] {
        var ordered: [String] = []
        func append(_ raw: String?) {
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty, !ordered.contains(value) else { return }
            ordered.append(value)
        }
        append(tenantFileID(from: snapshot.thumbnailURL))
        append(snapshot.fileID)
        for variant in snapshot.variants {
            append(tenantFileID(from: variant.thumbnailURL))
            append(tenantFileID(from: variant.assetURL))
            append(variant.fileID)
        }
        return ordered
    }

    private func stickerMessageAnimationFileIDs(for snapshot: StickerMessageSnapshot) -> [String] {
        var ordered: [String] = []
        func append(_ raw: String?) {
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty, !ordered.contains(value) else { return }
            ordered.append(value)
        }
        if let preferredVariant = preferredStickerVariant(for: snapshot) {
            append(tenantFileID(from: preferredVariant.assetURL))
            append(preferredVariant.fileID)
            append(tenantFileID(from: preferredVariant.thumbnailURL))
        }
        append(tenantFileID(from: snapshot.thumbnailURL))
        append(snapshot.fileID)
        for variant in snapshot.variants {
            append(tenantFileID(from: variant.assetURL))
            append(variant.fileID)
            append(tenantFileID(from: variant.thumbnailURL))
        }
        return ordered
    }

    private func stickerMessageFileAssetCacheKey(fileID: String, context: IMAPIContext) -> String {
        [
            context.tenantID ?? "",
            context.imUID ?? "",
            context.accountID ?? "",
            fileID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    private func resolveStickerMessageFileAsset(fileID: String, cacheKey: String, context: IMAPIContext, generation: UUID) async {
        defer {
            if generation == stickerMessageAssetStore.snapshot.generation {
                resolvingStickerMessageFileAssetKeys.remove(cacheKey)
            }
        }
        guard isCurrentStickerMessageAssetRequest(context: context, generation: generation) else { return }
        do {
            let detail = try await api.getTenantFile(context: context, fileID: fileID, coalescingScope: generation.uuidString)
            guard isCurrentStickerMessageAssetRequest(context: context, generation: generation) else { return }
            var asset = StickerResolvedFileAsset(
                fileID: detail.file.id.isEmpty ? fileID : detail.file.id,
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
            stickerMessageAssetStore.upsert(asset, for: cacheKey)
            failedStickerMessageFileAssetKeys.remove(cacheKey)
            asset = await hydrateLocalStickerResolvedFileAsset(asset, context: context)
            guard isCurrentStickerMessageAssetRequest(context: context, generation: generation) else { return }
            stickerMessageAssetStore.upsert(asset, for: cacheKey)
        } catch {
            guard isCurrentStickerMessageAssetRequest(context: context, generation: generation) else { return }
            failedStickerMessageFileAssetKeys.insert(cacheKey)
        }
    }

    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
    func hydrateLocalStickerResolvedFileAsset(
        _ asset: StickerResolvedFileAsset, context: IMAPIContext, manifest: StickerManifestHydration? = nil
    ) async -> StickerResolvedFileAsset {
        let generation = stickerMessageAssetStore.snapshot.generation
        @MainActor func isCurrent() -> Bool {
            if let manifest { return manifest.isCurrent() }
            return isCurrentStickerMessageAssetRequest(context: context, generation: generation)
        }
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
        var next = asset
        var downloadedByURL: [String: String] = [:]

        func localURL(for rawURL: String, role: String) async -> String {
            guard isCurrent() else { return "" } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
            let resolved = stickerDownloadableURLString(rawURL)
            guard !resolved.isEmpty else { return "" }
            if let cached = downloadedByURL[resolved] {
                return cached
            }
            let local = await downloadStickerMessageAssetToLocalFile(
                resolvedURLString: resolved,
                asset: asset,
                role: role,
                context: context,
                manifest: manifest,
                isCurrent: isCurrent
            )
            guard isCurrent() else { return "" } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
            if !local.isEmpty {
                downloadedByURL[resolved] = local
            }
            return local
        }

        if let raw = firstStickerDownloadableURL(in: [next.thumbnailURL, next.previewURL, next.downloadURL]) {
            next.localThumbnailURL = await localURL(for: raw, role: "thumbnail")
        }
        if let raw = firstStickerDownloadableURL(in: [next.previewURL, next.downloadURL, next.thumbnailURL]) {
            next.localPreviewURL = await localURL(for: raw, role: "preview")
        }
        if let raw = firstStickerDownloadableURL(in: [next.downloadURL, next.previewURL, next.thumbnailURL]) {
            next.localDownloadURL = await localURL(for: raw, role: "download")
        }
        return next
    }

    private func firstStickerDownloadableURL(in rawValues: [String]) -> String? {
        rawValues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !stickerDownloadableURLString($0).isEmpty }
    }

    private func stickerDownloadableURLString(_ rawValue: String) -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              !isTenantFileAPIEndpoint(raw) else {
            return ""
        }
        let resolved = resolveTenantAssetURL(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty,
              !isTenantFileAPIEndpoint(resolved) else {
            return ""
        }
        return resolved
    }

    private func downloadStickerMessageAssetToLocalFile(
        resolvedURLString: String,
        asset: StickerResolvedFileAsset,
        role: String,
        context: IMAPIContext,
        manifest: StickerManifestHydration?, // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        isCurrent: @MainActor () -> Bool
    ) async -> String {
        guard isCurrent(), let remoteURL = URL(string: resolvedURLString) else { return "" } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        if let local = remoteURL.usableLocalFileURL {
            return local.absoluteString
        }
        let fallbackExtension = stickerAssetFallbackExtension(asset: asset, remoteURL: remoteURL, role: role)
        let suggestedName = stickerAssetSuggestedFileName(asset: asset, role: role, fallbackExtension: fallbackExtension)
        let cacheKey = stickerAssetLocalCacheKey(asset: asset, role: role)
        let resourceKind: MediaResourceKind = role == "download" ? .original : (role == "preview" ? .preview : .thumbnail)
        let variant: MediaCacheVariant = role == "download" ? .original : (role == "preview" ? .preview1600 : .thumbnail640)
        let mediaContext = mediaCacheScopeContext
        let metadata = MediaResourceMetadata(
            scope: mediaContext?.scopeHash ?? "",
            fileID: asset.fileID,
            cacheKey: cacheKey,
            version: asset.version,
            checksumSHA256: asset.checksum,
            mimeType: asset.mimeType,
            sizeBytes: asset.sizeBytes,
            fileName: suggestedName,
            fileExtension: fallbackExtension,
            thumbnailCacheKey: cacheKey,
            thumbnailVersion: asset.version,
            thumbnailMimeType: asset.mimeType,
            thumbnailExtension: fallbackExtension,
            previewCacheKey: cacheKey,
            previewVersion: asset.version,
            previewMimeType: asset.mimeType,
            previewExtension: fallbackExtension
        )
        let integrity = resourceKind == .original
            ? MediaFileIntegrityAuthority(expectedSizeBytes: asset.sizeBytes, expectedSHA256: asset.checksum)
            : MediaFileIntegrityAuthority()
        if let mediaContext,
           let cached = await lookupIndexedMediaCache(
            metadata: metadata,
            messageID: "sticker:\(asset.fileID)",
            resourceKind: resourceKind,
            variant: variant,
            integrity: integrity,
            context: mediaContext,
            offline: false,
            stickerManifest: manifest
           ) {
            return isCurrent() ? cached.absoluteString : "" // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        }
        guard isCurrent() else { return "" } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        do {
            var request = URLRequest(url: remoteURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("JianHuiTong-iOS/1.0", forHTTPHeaderField: "User-Agent")
            let downloadContext = manifest?.operation == nil ? context : apiContext // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
            if shouldAuthorizeStickerAssetRequest(remoteURL, context: downloadContext),
               let token = downloadContext.imToken?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
            let (location, response) = try await stickerAssetDownload(request)
            defer {
                if manifest != nil { try? FileManager.default.removeItem(at: location) }
            }
            guard isCurrent() else { return "" }
            // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return ""
            }
            if let mediaContext,
               metadata.identity(for: resourceKind, variant: variant).persistentCacheIdentity != nil {
                let committed = try await commitIndexedMediaCache(
                    temporaryURL: location,
                    metadata: metadata,
                    resourceKind: resourceKind,
                    variant: variant,
                    integrity: integrity,
                    messageID: "sticker:\(asset.fileID)",
                    conversationID: "__stickers__",
                    authorityVersion: "0",
                    context: mediaContext,
                    stickerManifest: manifest // WDT_IOS1_STICKER_MANIFEST_R2_20261111
                )
                return committed.absoluteString
            }
            let destination = try AttachmentDownloadCachePolicy.stagingURL(
                suggestedName: suggestedName,
                fallbackExtension: fallbackExtension
            )
            try FileManager.default.copyItem(at: location, to: destination)
            guard AttachmentDownloadCachePolicy.canReuseCachedDownload(at: destination, expectedSizeBytes: nil) else {
                return ""
            }
            return destination.absoluteString
        } catch {
            return ""
        }
    }

    private func shouldAuthorizeStickerAssetRequest(_ url: URL, context: IMAPIContext) -> Bool {
        guard context.hasIMSession else { return false }
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path == "/api/tenant/files" || path.hasPrefix("/api/tenant/files/")
    }

    private func stickerAssetLocalCacheKey(asset: StickerResolvedFileAsset, role: String) -> String {
        scopedContentCacheIdentity([
            "sticker-message",
            role,
            asset.fileID,
            asset.cacheKey,
            asset.version,
            asset.checksum,
            asset.sizeBytes > 0 ? String(asset.sizeBytes) : ""
        ])
    }

    private func stickerAssetSuggestedFileName(asset: StickerResolvedFileAsset, role: String, fallbackExtension: String) -> String {
        let name = asset.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        let id = asset.fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = id.isEmpty ? "sticker-\(role)" : "sticker-\(id)"
        return fallbackExtension.isEmpty ? base : "\(base).\(fallbackExtension)"
    }

    private func stickerAssetFallbackExtension(asset: StickerResolvedFileAsset, remoteURL: URL, role: String) -> String {
        let remoteExtension = remoteURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !remoteExtension.isEmpty {
            return remoteExtension
        }
        let mime = asset.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mime.contains("webp") { return "webp" }
        if mime.contains("gif") { return "gif" }
        if mime.contains("png") { return "png" }
        if mime.contains("jpeg") || mime.contains("jpg") { return "jpg" }
        return role == "thumbnail" ? "png" : "gif"
    }

}

// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_END

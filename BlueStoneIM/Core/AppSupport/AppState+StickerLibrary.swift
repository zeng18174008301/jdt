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

// MARK: - Sticker Library

extension AppState {
    func prepareStickerExpressionPanel(force: Bool = false) async {
        let context = apiContext
        let scope = stickerLibraryScopeKey(for: context)
        stickerStore.activate(scope: scope)
        await hydrateCachedStickerManifestIfNeeded(context: context, scope: scope)
        await refreshUserStickerManifest(force: force, silent: true)
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
        guard let snapshot else { return nil }
        let cached = stickerMessageFileURL(for: snapshot, preferThumbnail: true)
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
        guard let snapshot else { return nil }
        let cached = stickerMessageFileURL(for: snapshot, preferThumbnail: false)
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
        return resolvedStickerThumbnailURL(for: snapshot)
    }

    func resolveStickerMessageAssetsIfNeeded(for snapshot: StickerMessageSnapshot?) {
        guard let snapshot else { return }
        let context = apiContext
        guard context.hasIMSession else { return }
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
                await self?.resolveStickerMessageFileAsset(fileID: fileID, cacheKey: cacheKey, context: context)
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

    private func stickerMessageFileURL(for snapshot: StickerMessageSnapshot, preferThumbnail: Bool) -> String {
        let context = apiContext
        guard context.hasIMSession else { return "" }
        let fileIDs = preferThumbnail
            ? stickerMessageFileIDs(for: snapshot)
            : stickerMessageAnimationFileIDs(for: snapshot)
        for fileID in fileIDs {
            let cacheKey = stickerMessageFileAssetCacheKey(fileID: fileID, context: context)
            guard let file = stickerMessageFileAssets[cacheKey] else { continue }
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

    private func resolveStickerMessageFileAsset(fileID: String, cacheKey: String, context: IMAPIContext) async {
        defer {
            resolvingStickerMessageFileAssetKeys.remove(cacheKey)
        }
        do {
            let detail = try await api.getTenantFile(context: context, fileID: fileID)
            guard isCurrentStickerScope(stickerLibraryScopeKey(for: context)) else { return }
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
            stickerMessageFileAssets[cacheKey] = asset
            failedStickerMessageFileAssetKeys.remove(cacheKey)
            objectWillChange.send()
            asset = await hydrateLocalStickerResolvedFileAsset(asset, context: context)
            guard isCurrentStickerScope(stickerLibraryScopeKey(for: context)) else { return }
            stickerMessageFileAssets[cacheKey] = asset
            objectWillChange.send()
        } catch {
            failedStickerMessageFileAssetKeys.insert(cacheKey)
        }
    }

    private func hydrateLocalStickerResolvedFileAsset(_ asset: StickerResolvedFileAsset, context: IMAPIContext) async -> StickerResolvedFileAsset {
        var next = asset
        var downloadedByURL: [String: String] = [:]

        func localURL(for rawURL: String, role: String) async -> String {
            let resolved = stickerDownloadableURLString(rawURL)
            guard !resolved.isEmpty else { return "" }
            if let cached = downloadedByURL[resolved] {
                return cached
            }
            let local = await downloadStickerMessageAssetToLocalFile(
                resolvedURLString: resolved,
                asset: asset,
                role: role,
                context: context
            )
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
        context: IMAPIContext
    ) async -> String {
        guard let remoteURL = URL(string: resolvedURLString) else { return "" }
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
            offline: false
           ) {
            return cached.absoluteString
        }
        do {
            var request = URLRequest(url: remoteURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("JianHuiTong-iOS/1.0", forHTTPHeaderField: "User-Agent")
            if shouldAuthorizeStickerAssetRequest(remoteURL, context: context),
               let token = context.imToken?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (location, response) = try await URLSession.shared.download(for: request)
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
                    context: mediaContext
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

    private func stickerMessageSnapshot(for item: StickerLibraryItem) -> StickerMessageSnapshot {
        let variants = item.variants.map { variant in
            StickerMessageVariantSnapshot(
                kind: variant.kind,
                fileID: variant.fileID,
                mimeType: variant.mimeType,
                assetURL: variant.assetURL,
                sizeBytes: variant.sizeBytes,
                width: variant.width,
                height: variant.height,
                durationMS: variant.durationMS,
                frameCount: variant.frameCount,
                thumbnailURL: variant.thumbnailURL,
                cacheKey: variant.cacheKey
            )
        }
        let fileID = item.fileID.isEmpty
            ? variants.first(where: { !$0.fileID.isEmpty })?.fileID ?? ""
            : item.fileID
        let stickerID = item.stickerID.isEmpty ? item.id : item.stickerID
        return StickerMessageSnapshot(
            stickerID: stickerID,
            packID: item.packID,
            fileID: fileID,
            mimeType: item.mimeType.isEmpty ? "image/gif" : item.mimeType,
            width: item.width,
            height: item.height,
            durationMS: item.durationMS,
            frameCount: item.frameCount,
            thumbnailURL: item.thumbnailURL,
            variants: variants
        )
    }

    func isDeletingSticker(_ item: StickerLibraryItem) -> Bool {
        stickerStore.deletingIDs.contains(item.id) || stickerStore.deletingIDs.contains(item.stickerID)
    }

    func isSortingSticker(_ item: StickerLibraryItem) -> Bool {
        stickerStore.sortingIDs.contains(item.id)
    }

    func loadOfficialStickerPack(_ packID: String) async {
        guard !packID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !stickerStore.officialStickers(packID: packID).isEmpty { return }
        await refreshOfficialStickerPack(packID)
    }

    func uploadStickerGIF(data: Data, name: String, conversationID: String) {
        uploadStickerImage(data: data, name: name, conversationID: conversationID)
    }

    func uploadStickerImage(data: Data, name: String, conversationID: String) {
        guard !data.isEmpty else {
            toast = "表情数据读取失败，请重新选择"
            return
        }
        guard let uploadFile = stickerUploadFileDescriptor(data: data, name: name) else {
            toast = "仅支持上传 GIF/JPG/PNG 表情"
            return
        }
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.kind != .system else {
            toast = "当前会话不支持添加表情"
            return
        }
        let context = apiContext
        let scope = stickerLibraryScopeKey(for: context)
        stickerStore.activate(scope: scope)
        guard context.hasIMSession, !scope.isEmpty else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let uploadID = StickerLibraryItem.makeLocalUploadID()
        stickerStore.beginLocalUpload(
            id: uploadID,
            name: uploadFile.fileName,
            mimeType: uploadFile.mimeType,
            sizeBytes: data.count,
            data: data,
            conversationID: conversationID,
            scope: scope
        )
        Task {
            await performStickerImageUpload(
                uploadID: uploadID,
                data: data,
                fileName: uploadFile.fileName,
                mimeType: uploadFile.mimeType,
                fileExtension: uploadFile.fileExtension,
                conversation: conversation,
                context: context,
                scope: scope
            )
        }
    }

    func deleteSticker(_ item: StickerLibraryItem) {
        Task {
            await deleteUserSticker(item)
        }
    }

    func retryStickerUpload(_ item: StickerLibraryItem) {
        guard item.isLocalUploadPlaceholder else { return }
        let scope = stickerLibraryScopeKey(for: apiContext)
        guard let draft = stickerStore.localUploadDraft(id: item.id) else {
            stickerStore.failLocalUpload(id: item.id, scope: scope)
            toast = "请重新选择文件上传"
            return
        }
        guard let uploadFile = stickerUploadFileDescriptor(data: draft.data, name: draft.name) else {
            stickerStore.failLocalUpload(id: item.id, scope: scope)
            toast = "仅支持上传 GIF/JPG/PNG 表情"
            return
        }
        guard let conversation = conversations.first(where: { $0.id == draft.conversationID }),
              conversation.kind != .system else {
            stickerStore.failLocalUpload(id: item.id, scope: scope)
            toast = "当前会话不支持添加表情"
            return
        }
        let context = apiContext
        guard context.hasIMSession, !scope.isEmpty else {
            stickerStore.failLocalUpload(id: item.id, scope: scope)
            toast = "登录会话不可用，请重新登录"
            return
        }
        stickerStore.updateLocalUpload(id: item.id, phase: .uploading, progress: 0.02, scope: scope)
        Task {
            await performStickerImageUpload(
                uploadID: item.id,
                data: draft.data,
                fileName: uploadFile.fileName,
                mimeType: uploadFile.mimeType,
                fileExtension: uploadFile.fileExtension,
                conversation: conversation,
                context: context,
                scope: scope
            )
        }
    }

    func moveSticker(_ item: StickerLibraryItem, direction: Int) {
        Task {
            await moveUserSticker(item, direction: direction)
        }
    }

    @discardableResult
    func sendSticker(
        _ item: StickerLibraryItem,
        conversationID: String,
        quote: String? = nil,
        replyContext: MessageReplyContext? = nil,
        onPolicyRejected: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard item.isActive else {
            toast = item.isFailed ? "表情处理失败，暂不能发送" : "表情处理中，完成后才能发送"
            return false
        }
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        let conversation = conversations[cIndex]
        if isSystemReadOnlyConversation(conversation) {
            toast = "系统通知仅支持阅读"
            return false
        }
        if let message = directSendBlockedMessage(for: conversation) {
            toast = message
            return false
        }
        if let message = localSendPolicyBlockedMessage(for: conversation) {
            toast = message
            return false
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let snapshot = stickerMessageSnapshot(for: item)
        guard !snapshot.stickerID.isEmpty, !snapshot.fileID.isEmpty else {
            toast = "表情资源缺少文件信息，暂不能发送"
            return false
        }
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_sticker")
        var message = ChatMessage(
            id: "local_\(UUID().uuidString)",
            senderId: localOutgoingMessageSenderID(),
            senderName: localOutgoingMessageSenderName(conversationID: conversationID),
            text: snapshot.fallbackText,
            time: "刚刚",
            isOutgoing: true,
            status: .sending,
            kind: .text,
            contentType: "sticker",
            reactions: [],
            readBy: [],
            unreadBy: conversations[cIndex].participants.prefix(3).map { ReadReceipt(id: "pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
            quote: quote,
            attachmentName: nil,
            attachmentMeta: nil
        )
        message.createdAt = Date()
        message.replyContext = replyContext
        message.stickerSnapshot = snapshot
        guard let appendedConversation = conversationStore.appendLocalOutgoingMessage(
            message,
            to: conversationID,
            preview: snapshot.fallbackText
        ) else { return false }
        let channelID = remoteChannelID(for: appendedConversation)
        Task {
            var durableTicket: LocalMessageSessionTicket?
            do {
                durableTicket = try await enqueueDurableOutgoing(
                    messageID: message.id,
                    conversationID: conversationID,
                    operationKind: "send_sticker",
                    context: context,
                    scope: scope
                )
                let remote = try await api.sendSticker(
                    context: context,
                    conversation: appendedConversation,
                    channelID: channelID,
                    sticker: snapshot,
                    quote: quote,
                    replyContext: replyContext,
                    clientMessageID: message.id
                )
                guard isCurrentRemoteScope(scope) else { return }
                removeMessage(messageID: message.id, in: conversationID)
                applyRemoteMessages(
                    [remote],
                    channelID: remote.channelID.isEmpty ? channelID : remote.channelID,
                    channelType: remote.channelType.isEmpty ? apiChannelType(for: appendedConversation.kind) : remote.channelType
                )
                if let durableTicket {
                    await confirmDurableOutgoing(
                        ticket: durableTicket,
                        clientMessageID: message.id,
                        remote: remote,
                        conversationID: conversationID,
                        scope: scope
                    )
                }
                syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if isNotFriendsError(error) {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .failedPermanent)
                    markMessageFailed(messageID: message.id, in: conversationID)
                    handleNotFriends(for: appendedConversation, context: directFriendRequestContext(from: error, fallback: appendedConversation))
                } else if isSendPolicyForbidden(error) {
                    let groupAllMuted = isGroupAllMutedError(error)
                    if isGroupMemberMutedError(error) {
                        markGroupMutedForConversation(appendedConversation)
                    }
                    await refreshGroupPolicyAfterSendFailure(appendedConversation, scope: scope)
                    guard isCurrentRemoteScope(scope) else { return }
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .cancelled)
                    handleRemoteError(error, fallback: "表情发送失败")
                    removeMessage(messageID: message.id, in: conversationID)
                    if groupAllMuted {
                        onPolicyRejected?()
                    }
                } else {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .retryWait)
                    markMessageFailed(messageID: message.id, in: conversationID)
                    handleRemoteError(error, fallback: "表情发送失败")
                }
            }
        }
        return true
    }

    private func refreshUserStickerManifest(force: Bool = false, silent: Bool = false, schedulePoll: Bool = true) async {
        let context = apiContext
        let scope = stickerLibraryScopeKey(for: context)
        stickerStore.activate(scope: scope)
        guard context.hasIMSession, !scope.isEmpty else {
            if !silent {
                toast = "登录会话不可用，请重新登录"
            }
            return
        }
        if stickerStore.isManifestRefreshing && !force { return }
        stickerStore.setManifestRefreshing(true)
        do {
            let remoteItems = try await api.listUserStickers(context: context, limit: 200)
            guard isCurrentStickerScope(scope) else { return }
            let items = await hydrateStickerLibraryItems(remoteItems.map(StickerLibraryItem.init(remote:)), context: context)
            stickerStore.replaceMyStickers(items, scope: scope)
            stickerStore.setManifestRefreshing(false)
            if schedulePoll {
                scheduleStickerManifestPollIfNeeded(scope: scope)
            }
        } catch {
            guard isCurrentStickerScope(scope) else { return }
            let message = userFacingError(error)
            stickerStore.setManifestError(message)
            if !silent {
                handleRemoteError(error, fallback: "表情库同步失败")
            }
        }
    }

    private func refreshOfficialStickerPacksIfNeeded(force: Bool = false) async {
        guard force || stickerStore.officialPacks.isEmpty else { return }
        let context = apiContext
        let scope = stickerLibraryScopeKey(for: context)
        guard context.hasIMSession, !scope.isEmpty else { return }
        do {
            let packs = try await api.listStickerPacks(context: context)
            guard isCurrentStickerScope(scope) else { return }
            let mapped = packs
                .map(StickerPackItem.init(remote:))
                .filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "offline" }
            stickerStore.replaceOfficialPacks(mapped)
            if let first = mapped.first {
                await refreshOfficialStickerPack(first.id)
            }
        } catch {
            guard isCurrentStickerScope(scope) else { return }
            stickerStore.setOfficialError(userFacingError(error))
        }
    }

    private func refreshOfficialStickerPack(_ packID: String) async {
        let context = apiContext
        let scope = stickerLibraryScopeKey(for: context)
        guard context.hasIMSession, !scope.isEmpty else { return }
        do {
            let packName = stickerStore.officialPacks.first(where: { $0.id == packID })?.name ?? ""
            let remoteStickers = try await api.listStickerPackStickers(context: context, packID: packID)
            guard isCurrentStickerScope(scope) else { return }
            let stickers = remoteStickers
                .map { StickerLibraryItem(remote: $0, packName: packName) }
                .filter { $0.isActive || $0.normalizedStatus == "online" }
            stickerStore.replaceOfficialStickers(stickers, packID: packID)
        } catch {
            guard isCurrentStickerScope(scope) else { return }
            stickerStore.setOfficialError(userFacingError(error))
        }
    }

    private func hydrateCachedStickerManifestIfNeeded(context: IMAPIContext, scope: String) async {
        guard context.hasIMSession,
              isCurrentStickerScope(scope),
              !stickerStore.myStickers.isEmpty else {
            return
        }
        let itemsNeedingHydration = stickerStore.myStickers.filter { item in
            stickerThumbnailURL(for: item).isEmpty && stickerLibraryFileIDs(for: item).isEmpty == false
        }
        guard !itemsNeedingHydration.isEmpty else { return }
        let hydrated = await hydrateStickerLibraryItems(stickerStore.myStickers, context: context)
        guard isCurrentStickerScope(scope) else { return }
        stickerStore.replaceMyStickers(hydrated, scope: scope)
    }

    private struct StickerUploadFileDescriptor {
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

    struct StickerResolvedFileAsset {
        let fileID: String
        let fileName: String
        let mimeType: String
        let sizeBytes: Int64
        let cacheKey: String
        let version: String
        let checksum: String
        let thumbnailURL: String
        let previewURL: String
        let downloadURL: String
        var localThumbnailURL: String = ""
        var localPreviewURL: String = ""
        var localDownloadURL: String = ""
    }

    private func performStickerImageUpload(
        uploadID: String,
        data: Data,
        fileName: String,
        mimeType: String,
        fileExtension: String,
        conversation: Conversation,
        context: IMAPIContext,
        scope: String
    ) async {
        guard isCurrentStickerScope(scope) else { return }
        stickerStore.updateLocalUpload(id: uploadID, phase: .compressing, scope: scope)
        do {
            let preparedFile = prepareStickerUploadFile(
                data: data,
                fileName: fileName,
                mimeType: mimeType,
                fileExtension: fileExtension
            )
            let remoteConfig = try await fetchScopedFileUploadConfig(context: context, scope: scope)
            guard isCurrentStickerScope(scope) else {
                return
            }
            let config = remoteConfig.model
            guard preparedFile.data.count <= config.maxBytes else {
                stickerStore.failLocalUpload(id: uploadID, scope: scope)
                toast = config.overLimitMessage
                return
            }
            let channelID = remoteChannelID(for: conversation)
            stickerStore.updateLocalUpload(id: uploadID, phase: .uploading, progress: 0.08, scope: scope)
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
            guard isCurrentStickerScope(scope) else {
                return
            }
            stickerStore.updateLocalUpload(id: uploadID, phase: .uploading, progress: 0.18, scope: scope)
            // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_STICKER_UPLOAD_GUARD - 修改开始：贴纸仍要求上传描述，避免聊天附件兼容影响贴纸业务
            guard let upload = presign.upload else {
                throw IMAPIError.server("sticker_upload_descriptor_missing")
            }
            try await api.uploadFileBinary(upload: upload, data: preparedFile.data, mimeType: preparedFile.mimeType) { [weak self] fraction in
                let progress = 0.18 + max(0, min(fraction, 1)) * 0.58
                Task { @MainActor [weak self] in
                    self?.stickerStore.updateLocalUpload(id: uploadID, phase: .uploading, progress: progress, scope: scope)
                }
            }
            // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_STICKER_UPLOAD_GUARD - 修改结束
            guard isCurrentStickerScope(scope) else {
                return
            }
            stickerStore.updateLocalUpload(id: uploadID, phase: .processing, scope: scope)
            let uploadedFile = try await api.markFileUploaded(context: context, fileID: presign.file.id)
            let completedFile = uploadedFile.merged(with: presign.file)
            guard isCurrentStickerScope(scope) else {
                return
            }
            let commit = try await api.commitUserSticker(context: context, fileID: completedFile.id, name: preparedFile.fileName)
            guard isCurrentStickerScope(scope) else {
                return
            }
            let committedItem = await hydrateStickerLibraryItem(StickerLibraryItem(commitResult: commit), context: context)
            stickerStore.replaceLocalUpload(id: uploadID, with: committedItem, scope: scope)
            toast = "表情已提交处理，完成后可发送"
            await refreshUserStickerManifest(force: true, silent: true)
            scheduleStickerManifestPollIfNeeded(scope: scope)
        } catch {
            guard isCurrentStickerScope(scope) else {
                return
            }
            stickerStore.failLocalUpload(id: uploadID, scope: scope)
            handleRemoteError(error, fallback: "表情上传失败")
        }
    }

    private func deleteUserSticker(_ item: StickerLibraryItem) async {
        if item.isLocalUploadPlaceholder {
            stickerStore.removeLocalUpload(id: item.id, scope: stickerLibraryScopeKey(for: apiContext))
            toast = "已移除表情"
            return
        }
        let id = item.id.isEmpty ? item.stickerID : item.id
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let context = apiContext
        let scope = stickerLibraryScopeKey(for: context)
        guard context.hasIMSession, !scope.isEmpty else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        stickerStore.beginDeleting(id: id)
        do {
            _ = try await api.deleteUserSticker(context: context, id: id)
            guard isCurrentStickerScope(scope) else { return }
            stickerStore.removeMySticker(id: id, scope: scope)
            stickerStore.finishDeleting(id: id)
            toast = "已删除表情"
            await refreshUserStickerManifest(force: true, silent: true)
        } catch {
            guard isCurrentStickerScope(scope) else { return }
            stickerStore.finishDeleting(id: id)
            handleRemoteError(error, fallback: "删除表情失败")
        }
    }

    private func moveUserSticker(_ item: StickerLibraryItem, direction: Int) async {
        guard !item.isLocalUploadPlaceholder else { return }
        let context = apiContext
        let scope = stickerLibraryScopeKey(for: context)
        guard context.hasIMSession, !scope.isEmpty else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        guard let ids = stickerStore.moveUserSticker(id: item.id, direction: direction, scope: scope) else { return }
        stickerStore.beginSorting(ids: ids)
        do {
            let remoteItems = try await api.orderUserStickers(context: context, ids: ids)
            guard isCurrentStickerScope(scope) else { return }
            if !remoteItems.isEmpty {
                let items = await hydrateStickerLibraryItems(remoteItems.map(StickerLibraryItem.init(remote:)), context: context)
                stickerStore.replaceMyStickers(items, scope: scope)
            }
            stickerStore.finishSorting(ids: ids)
        } catch {
            guard isCurrentStickerScope(scope) else { return }
            stickerStore.finishSorting(ids: ids)
            await refreshUserStickerManifest(force: true, silent: true)
            handleRemoteError(error, fallback: "表情排序失败")
        }
    }

    private func hydrateStickerLibraryItems(_ items: [StickerLibraryItem], context: IMAPIContext) async -> [StickerLibraryItem] {
        var fileCache: [String: StickerResolvedFileAsset] = [:]
        var hydrated: [StickerLibraryItem] = []
        hydrated.reserveCapacity(items.count)
        for item in items {
            hydrated.append(await hydrateStickerLibraryItem(item, context: context, fileCache: &fileCache))
        }
        return hydrated
    }

    private func hydrateStickerLibraryItem(_ item: StickerLibraryItem, context: IMAPIContext) async -> StickerLibraryItem {
        var fileCache: [String: StickerResolvedFileAsset] = [:]
        return await hydrateStickerLibraryItem(item, context: context, fileCache: &fileCache)
    }

    private func hydrateStickerLibraryItem(
        _ item: StickerLibraryItem,
        context: IMAPIContext,
        fileCache: inout [String: StickerResolvedFileAsset]
    ) async -> StickerLibraryItem {
        var nextThumbnailURL = stickerRenderableURL(item.thumbnailURL)
        if nextThumbnailURL.isEmpty {
            let thumbnailFileID = tenantFileID(from: item.thumbnailURL) ?? item.fileID
            nextThumbnailURL = await signedStickerFileURL(fileID: thumbnailFileID, preferThumbnail: true, context: context, fileCache: &fileCache)
        }

        let nextVariants = await hydrateStickerVariants(item.variants, context: context, fileCache: &fileCache)
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

    private func stickerLibraryFileIDs(for item: StickerLibraryItem) -> [String] {
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
        fileCache: inout [String: StickerResolvedFileAsset]
    ) async -> [StickerAssetVariant] {
        var hydrated: [StickerAssetVariant] = []
        hydrated.reserveCapacity(variants.count)
        for variant in variants {
            var assetURL = stickerRenderableURL(variant.assetURL)
            if assetURL.isEmpty {
                let assetFileID = tenantFileID(from: variant.assetURL) ?? variant.fileID
                assetURL = await signedStickerFileURL(fileID: assetFileID, preferThumbnail: false, context: context, fileCache: &fileCache)
            }

            var thumbnailURL = stickerRenderableURL(variant.thumbnailURL)
            if thumbnailURL.isEmpty {
                let thumbnailFileID = tenantFileID(from: variant.thumbnailURL) ?? variant.fileID
                thumbnailURL = await signedStickerFileURL(fileID: thumbnailFileID, preferThumbnail: true, context: context, fileCache: &fileCache)
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
        fileCache: inout [String: StickerResolvedFileAsset]
    ) async -> String {
        let normalizedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileID.isEmpty, context.hasIMSession else { return "" }
        let file: StickerResolvedFileAsset
        if let cached = fileCache[normalizedFileID] {
            file = cached
        } else {
            do {
                let detail = try await api.getTenantFile(context: context, fileID: normalizedFileID)
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
                resolvedFile = await hydrateLocalStickerResolvedFileAsset(resolvedFile, context: context)
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

    private func stickerRenderableURL(_ rawValue: String) -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        return resolvedStickerAssetURLString(raw)
    }

    private func tenantFileID(from rawValue: String) -> String? {
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

    private func scheduleStickerManifestPollIfNeeded(scope: String) {
        guard isCurrentStickerScope(scope),
              stickerStore.myStickers.contains(where: { $0.isProcessing }) else {
            return
        }
        stickerManifestPollTask?.cancel()
        stickerManifestPollTask = Task { [weak self] in
            for attempt in 0..<12 {
                guard !Task.isCancelled else { return }
                let delayNs = UInt64(min(12, 2 + attempt)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled else { return }
                await self?.refreshUserStickerManifest(force: true, silent: true, schedulePoll: false)
                guard let self,
                      self.isCurrentStickerScope(scope),
                      self.stickerStore.myStickers.contains(where: { $0.isProcessing }) else {
                    return
                }
            }
        }
    }

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

    private func stickerUploadFileDescriptor(data: Data, name: String) -> StickerUploadFileDescriptor? {
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

    private func stickerLibraryScopeKey(for context: IMAPIContext) -> String {
        [
            context.tenantID ?? "",
            context.imUID ?? "",
            context.accountID ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    private func isCurrentStickerScope(_ scope: String) -> Bool {
        apiContext.hasIMSession && stickerLibraryScopeKey(for: apiContext) == scope
    }
}

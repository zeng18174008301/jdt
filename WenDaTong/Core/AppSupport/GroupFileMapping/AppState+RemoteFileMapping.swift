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
    func fileItem(from remote: RemoteGroupFile, groupID: String) -> FileItem {
        var item = fileItem(from: remote, fallbackSource: group(id: groupID)?.name ?? conversationTitleForGroupFileList(groupID: groupID))
        if item.channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.channelID = groupID
        }
        if item.channelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.channelType = "group"
        }
        return item
    }

    func fileItem(from remote: RemoteGroupFile) -> FileItem {
        let knownConversationTitle = conversationStore.conversationMessageSnapshots().first { conversation in
            conversation.id == remote.channelID || remoteChannelID(for: conversation) == remote.channelID
        }?.title
        return fileItem(from: remote, fallbackSource: remote.sourceName.isEmpty ? knownConversationTitle ?? remote.channelID : remote.sourceName)
    }

    func favoriteAssetItem(from remote: RemoteFavoriteAssetItem) -> FavoriteAssetItem {
        let file = fileItem(fromFavoriteAsset: remote)
        let messageID = remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        return FavoriteAssetItem(
            messageID: messageID.isEmpty ? favoriteAssetFallbackMessageID(remote) : messageID,
            tenantID: remote.tenantID,
            channelID: remote.channelID,
            channelType: remote.channelType,
            channelSeq: remote.channelSeq,
            fromUID: remote.resolvedSenderID,
            contentType: remote.contentType,
            status: remote.status,
            createdAt: remote.createdAt,
            favoritedAt: remote.favoritedAt,
            favoriteVersion: remote.favoriteVersion,
            category: favoriteAssetCategory(from: remote, file: file),
            displayText: remote.displayText,
            cursor: remote.cursor,
            file: file,
            isUnavailable: favoriteAssetIsUnavailable(remote)
        )
    }

    func fileItem(fromFavoriteAsset remote: RemoteFavoriteAssetItem) -> FileItem {
        let payload = remote.payload
        let category = favoriteAssetCategory(from: remote)
        let unavailable = favoriteAssetIsUnavailable(remote)
        let fileID = attachmentPayloadString(
            payload,
            ["file_id", "remote_file_id", "attachment_id", "media_id", "asset_file_id", "id"]
        )
        let fallbackMessageID = favoriteAssetFallbackMessageID(remote)
        let itemID = fileID.isEmpty ? "favorite-asset|\(fallbackMessageID)" : fileID
        let displayText = remote.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadName = attachmentPayloadString(
            payload,
            ["file_name", "filename", "name", "attachment_name", "title", "display_name"]
        )
        let name = [payloadName, displayText].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? (unavailable ? "内容已失效" : "未命名资料")
        let mimeType = attachmentPayloadString(payload, ["mime_type", "mime", "content_type"])
        let extensionValue = attachmentPayloadString(payload, ["extension", "file_extension", "ext"])
        let mediaCategory = favoriteAssetMediaCategory(remote: remote, fallback: category)
        let previewURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["preview_url", "preview", "url"]))
        let downloadURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["download_url", "download_public", "file_url", "url", "asset_url"]))
        let thumbnailURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["thumbnail_url", "thumb_url", "preview_thumbnail_url", "thumbnail_preview_url"]))
        let posterURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["poster_url", "video_poster_url"]))
        let coverURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["cover_url", "video_cover_url"]))
        let previewKind = attachmentPayloadString(payload, ["preview_kind"])
        let contentDisposition = attachmentPayloadString(payload, ["content_disposition"])
        let previewAvailable = unavailable ? false : attachmentPreviewAllowed(
            previewURL: previewURL,
            previewKind: previewKind,
            contentDisposition: contentDisposition,
            backendAvailable: attachmentPayloadBool(payload, ["preview_available"])
        )
        let downloadAvailable = unavailable ? false : (attachmentPayloadBool(payload, ["download_available"]) ?? (!downloadURL.isEmpty || !fileID.isEmpty))
        let senderDisplayName = attachmentPayloadString(
            payload,
            ["sender_display_name", "sender_name", "from_name", "nickname", "display_name"]
        )
        let senderID = remote.resolvedSenderID
        let source = favoriteAssetSourceText(remote)
        let status: String
        if unavailable {
            status = "内容已失效/不可预览"
        } else if previewAvailable && downloadAvailable {
            status = "可预览 / 可下载"
        } else if downloadAvailable {
            status = "可下载"
        } else if previewAvailable {
            status = "可预览"
        } else {
            status = "仅元数据"
        }
        return FileItem(
            id: itemID,
            name: name,
            type: fileTypeLabel(name: name, mimeType: mimeType, category: mediaCategory, fallback: extensionValue),
            size: byteSize(attachmentPayloadInt64(payload, ["size_bytes", "size", "file_size"]) ?? 0),
            sizeBytes: attachmentPayloadInt64(payload, ["size_bytes", "size", "file_size"]),
            owner: senderDisplayName.isEmpty ? (senderID.isEmpty ? "未知发送人" : senderID) : senderDisplayName,
            source: source,
            time: displayTime(remote.favoritedAt ?? remote.createdAt),
            scope: "个人收藏",
            status: status,
            accentHex: stableSeed(itemID),
            remoteFileID: fileID,
            previewURL: previewURL,
            downloadURL: downloadURL,
            previewAvailable: previewAvailable,
            downloadAvailable: downloadAvailable,
            channelID: remote.channelID,
            channelType: remote.channelType,
            channelSeq: remote.channelSeq,
            mediaCategory: mediaCategory,
            contentType: remote.contentType,
            kind: attachmentPayloadString(payload, ["kind", "type"]),
            mimeType: mimeType,
            cacheKey: attachmentPayloadString(payload, ["cache_key", "cacheKey", "version"]),
            version: attachmentPayloadString(payload, ["version", "file_version", "cache_version"]),
            checksum: attachmentPayloadString(payload, ["checksum"]),
            fileExtension: extensionValue,
            thumbnailURL: thumbnailURL,
            posterURL: posterURL,
            coverURL: coverURL,
            previewKind: previewKind,
            contentDisposition: contentDisposition,
            width: attachmentPayloadInt64(payload, ["width"]).map(Int.init),
            height: attachmentPayloadInt64(payload, ["height"]).map(Int.init),
            durationSeconds: attachmentDuration(from: payload)
        )
    }

    private func favoriteAssetFallbackMessageID(_ remote: RemoteFavoriteAssetItem) -> String {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：收藏 fallback ID 纯逻辑从 AppState 拆出
        FileItemProjectionHelper.favoriteAssetFallbackMessageID(remote)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func favoriteAssetCategory(from remote: RemoteFavoriteAssetItem, file: FileItem? = nil) -> FavoriteAssetCategory {
        let explicit = FavoriteAssetCategory(serverValue: remote.category)
        if explicit != .all {
            return explicit
        }
        if let file {
            for category in FavoriteAssetCategory.displayOrder where category != .all && category.matches(file: file) {
                return category
            }
        }
        return FavoriteAssetCategory(serverValue: favoriteAssetMediaCategory(remote: remote, fallback: .all))
    }

    private func favoriteAssetMediaCategory(remote: RemoteFavoriteAssetItem, fallback: FavoriteAssetCategory) -> String {
        let payload = remote.payload
        let category = attachmentPayloadString(payload, ["media_category", "category", "kind", "preview_kind"])
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：收藏媒体分类纯逻辑从 AppState 拆出
        return FileItemProjectionHelper.favoriteAssetMediaCategory(
            payloadCategory: category,
            contentType: remote.contentType,
            fallback: fallback
        )
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func favoriteAssetSourceText(_ remote: RemoteFavoriteAssetItem) -> String {
        if let conversation = conversationStore.conversationMessageSnapshots().first(where: { conversation in
            conversation.id == remote.channelID || remoteChannelID(for: conversation) == remote.channelID
        }) {
            return conversation.title
        }
        switch remote.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "group":
            return remote.channelID.isEmpty ? "群聊" : "群聊 \(remote.channelID)"
        case "direct", "p2p":
            return "私聊"
        default:
            return remote.channelID.isEmpty ? "收藏资料" : remote.channelID
        }
    }

    private func favoriteAssetIsUnavailable(_ remote: RemoteFavoriteAssetItem) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：收藏失效状态纯判断从 AppState 拆出
        FileItemProjectionHelper.favoriteAssetIsUnavailable(remote)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    func fileItem(from detail: RemoteUserFileDetail, fallback: FileItem) -> FileItem {
        let object = detail.file
        let remote = RemoteGroupFile(
            fileID: object.id,
            name: object.fileName,
            type: fallback.type,
            mimeType: object.mimeType,
            category: "",
            size: object.sizeBytes,
            uploaderUID: object.uploaderUID,
            uploaderName: fallback.owner,
            channelID: fallback.channelID,
            channelType: fallback.channelType,
            channelSeq: fallback.channelSeq,
            groupID: fallback.channelType == "group" ? fallback.channelID : "",
            sourceName: fallback.source,
            createdAt: object.createdAt,
            previewAvailable: detail.previewAvailable,
            downloadAvailable: detail.downloadAvailable,
            previewURL: detail.previewURL,
            downloadURL: detail.downloadURL,
            status: object.status,
            cacheKey: object.cacheKey,
            version: object.version,
            checksum: object.checksum,
            mediaCategory: object.mediaCategory,
            contentType: object.contentType,
            kind: object.kind,
            fileExtension: object.fileExtension,
            thumbnailURL: object.thumbnailURL,
            posterURL: object.posterURL,
            coverURL: object.coverURL,
            previewKind: object.previewKind,
            contentDisposition: detail.contentDisposition,
            width: object.width,
            height: object.height,
            durationSeconds: object.durationSeconds
        )
        return fileItem(from: remote, fallbackSource: fallback.source)
    }

    func fileItem(from remote: RemoteGroupFile, fallbackSource: String) -> FileItem {
        let type = fileTypeLabel(name: remote.name, mimeType: remote.mimeType, category: remote.mediaCategory.isEmpty ? remote.category : remote.mediaCategory, fallback: remote.type)
        let previewURL = resolvedTenantFileAssetURL(remote.previewURL)
        let downloadURL = resolvedTenantFileAssetURL(remote.downloadURL)
        let thumbnailURL = resolvedTenantFileAssetURL(remote.thumbnailURL)
        let posterURL = resolvedTenantFileAssetURL(remote.posterURL)
        let coverURL = resolvedTenantFileAssetURL(remote.coverURL)
        let previewAvailable = attachmentPreviewAllowed(
            previewURL: previewURL,
            previewKind: remote.previewKind,
            contentDisposition: remote.contentDisposition,
            backendAvailable: remote.previewAvailable
        )
        let status: String
        if !remote.status.isEmpty, remote.status.lowercased() != "uploaded" {
            status = remote.status
        } else if remote.downloadAvailable && previewAvailable {
            status = "可预览 / 可下载"
        } else if remote.downloadAvailable {
            status = "可下载"
        } else if previewAvailable {
            status = "可预览"
        } else {
            status = "仅元数据"
        }
        return FileItem(
            id: remote.fileID.isEmpty ? remote.name : remote.fileID,
            name: remote.name.isEmpty ? "未命名文件" : remote.name,
            type: type,
            size: byteSize(remote.size),
            sizeBytes: remote.size,
            owner: remote.uploaderName.isEmpty ? remote.uploaderUID : remote.uploaderName,
            source: remote.sourceName.isEmpty ? fallbackSource : remote.sourceName,
            time: displayTime(remote.createdAt),
            scope: remote.channelScopeText,
            status: status,
            accentHex: stableSeed(remote.fileID),
            remoteFileID: remote.fileID,
            previewURL: previewURL,
            downloadURL: downloadURL,
            previewAvailable: previewAvailable,
            downloadAvailable: remote.downloadAvailable,
            channelID: remote.channelID,
            channelType: remote.channelType,
            channelSeq: remote.channelSeq,
            mediaCategory: remote.mediaCategory.isEmpty ? remote.category : remote.mediaCategory,
            contentType: remote.contentType,
            kind: remote.kind.isEmpty ? remote.type : remote.kind,
            mimeType: remote.mimeType,
            cacheKey: remote.cacheKey,
            version: remote.version,
            checksum: remote.checksum,
            fileExtension: remote.fileExtension,
            thumbnailURL: thumbnailURL,
            posterURL: posterURL,
            coverURL: coverURL,
            previewKind: remote.previewKind,
            contentDisposition: remote.contentDisposition,
            width: remote.width,
            height: remote.height,
            durationSeconds: remote.durationSeconds
        )
    }

    func refreshKnownGroupFileItemsForFileList(
        context: IMAPIContext,
        scope: String,
        query: String,
        category: String,
        excludingFileIDs: Set<String>
    ) async -> [FileItem] {
        let groupIDs = knownGroupIDsForFileList()
        guard !groupIDs.isEmpty else { return [] }
        var seen = excludingFileIDs
        var collected: [FileItem] = []
        for groupID in groupIDs.prefix(30) {
            guard isCurrentRemoteScope(scope) else { return collected }
            do {
                let remoteFiles = try await api.listGroupFiles(context: context, groupID: groupID)
                let mapped = remoteFiles
                    .map { fileItem(from: $0, groupID: groupID) }
                    .filter(isFileItemVisibleInFileLists)
                fileStore.replaceGroupFiles(mapped, groupID: groupID)
                for item in mapped where seen.insert(item.id).inserted && fileItem(item, matchesQuery: query, category: category) {
                    collected.append(item)
                }
            } catch {
                logSyncEndpointFailure("/api/tenant/groups/{id}/files", error: error)
            }
        }
        return collected
    }

    private func knownGroupIDsForFileList() -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        func append(_ rawValue: String) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            ids.append(value)
        }
        for conversation in conversationStore.conversationMessageSnapshots() where conversation.kind == .group {
            append(remoteChannelID(for: conversation))
        }
        for group in groups {
            append(group.id)
        }
        return ids
    }

    func backfillRecentAttachmentMessagesForFileList(
        context: IMAPIContext,
        scope: String
    ) async {
        let targets = fileListMessageBackfillTargets(
            conversationLimit: fileListMessageBackfillConversationLimit,
            windowLimit: fileListMessageBackfillWindowLimit
        )
        guard !targets.isEmpty else { return }
        for target in targets {
            guard isCurrentRemoteScope(scope) else { return }
            let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: target.channelID, channelType: target.channelType)
            do {
                let page = try await api.syncMessages(
                    context: context,
                    channelID: target.channelID,
                    channelType: target.channelType,
                    afterSeq: target.afterSeq,
                    beforeSeq: nil,
                    limit: fileListMessageBackfillWindowLimit
                )
                guard isCurrentRemoteScope(scope),
                      isCurrentGroupHistoryBoundaryResponse(context: context, channelID: target.channelID, channelType: target.channelType, generation: boundaryGeneration) else { return }
                let syncBoundary = historyBoundary(from: page, channelType: target.channelType)
                let relevantMessages = page.items.filter { remote in
                    isRemoteMessageVisibleAfterHistoryBoundary(remote, boundary: syncBoundary)
                        && isAttachmentMessageKind(remoteMessageKind(from: remote))
                        && !isVoiceMessageAssetForFileList(remote)
                }
                guard !relevantMessages.isEmpty else {
                    if let syncBoundary {
                        applyHistoryVisibilityBoundaryForGroup(
                            channelID: target.channelID,
                            boundary: syncBoundary
                        )
                    }
                    continue
                }
                applyRemoteMessages(
                    relevantMessages,
                    channelID: target.channelID,
                    channelType: target.channelType,
                    windowRetention: .latestTail(limit: fileListMessageBackfillWindowLimit),
                    historyBoundary: syncBoundary
                )
            } catch {
                logSyncEndpointFailure("/api/im/sync", error: error)
            }
        }
    }

    private func fileListMessageBackfillTargets(
        conversationLimit: Int,
        windowLimit: Int
    ) -> [(channelID: String, channelType: String, afterSeq: Int64)] {
        var seen = Set<String>()
        var targets: [(channelID: String, channelType: String, afterSeq: Int64)] = []
        let boundedLimit = max(1, conversationLimit)
        let boundedWindow = Int64(max(1, windowLimit))
        for conversation in conversationStore.conversationMessageSnapshots() {
            guard conversation.kind != .system else { continue }
            let channelID = remoteChannelID(for: conversation)
            let channelType = apiChannelType(for: conversation.kind)
            let key = "\(channelType)|\(channelID)"
            guard !channelID.isEmpty, seen.insert(key).inserted else { continue }
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：附件补扫目标计算避免生成序号临时数组
            let localLatestSeq = ConversationSequenceInspector.maximumChannelSeq(in: conversation.messages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
            let latestKnownSeq = max(conversation.lastMsgSeq, localLatestSeq)
            let shouldBackfill = latestKnownSeq > localLatestSeq
                || fileListMessageSummaryLooksLikeAttachment(conversation.lastMessage)
                || fileListMessageSummaryLooksLikeAttachment(conversation.subtitle)
            guard shouldBackfill else { continue }
            targets.append((
                channelID: channelID,
                channelType: channelType,
                afterSeq: max(0, latestKnownSeq - boundedWindow)
            ))
            if targets.count >= boundedLimit {
                break
            }
        }
        return targets
    }

    private func fileListMessageSummaryLooksLikeAttachment(_ rawValue: String) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：附件摘要识别复用静态后缀集合
        FileItemProjectionHelper.fileListMessageSummaryLooksLikeAttachment(rawValue)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func isVoiceMessageAssetForFileList(_ remote: RemoteMessage) -> Bool {
        let payload = remote.payload
        return VoiceFileListPolicy.isVoiceMessageAsset(
            contentType: remote.contentType,
            mediaCategory: attachmentPayloadString(payload, ["media_category", "category"]),
            kind: attachmentPayloadString(payload, ["kind", "type"]),
            previewKind: attachmentPayloadString(payload, ["preview_kind"]),
            type: attachmentPayloadString(payload, ["type"]),
            name: attachmentPayloadString(payload, ["file_name", "filename", "name"]),
            mimeType: attachmentPayloadString(payload, ["mime_type", "mime"]),
            fileExtension: attachmentPayloadString(payload, ["extension", "file_extension", "ext"])
        )
    }

    func fileItemsReferToSameAttachment(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：文件去重纯判断从 AppState 拆出
        FileItemProjectionHelper.fileItemsReferToSameAttachment(lhs, rhs)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func conversationTitleForGroupFileList(groupID: String) -> String {
        conversationStore.conversationMessageSnapshots().first { conversation in
            conversation.kind == .group && (conversation.id == groupID || remoteChannelID(for: conversation) == groupID)
        }?.title ?? groupID
    }

    func attachmentFileItems(from conversations: [ConversationMessageSnapshot]) -> [FileItem] {
        var seen = Set<String>()
        var items: [FileItem] = []
        for conversation in conversations {
            for message in conversation.messages.reversed() {
                guard let item = fileItem(fromAttachmentMessage: message, conversation: conversation),
                      seen.insert(item.id).inserted else {
                    continue
                }
                items.append(item)
            }
        }
        return items
    }

    func fileItem(fromAttachmentMessage message: ChatMessage, conversation: ConversationMessageSnapshot) -> FileItem? {
        guard isAttachmentMessageKind(message.kind),
              message.status != .sending,
              message.status != .failed,
              message.status != .recalled,
              !message.isDeletedLocally else {
            return nil
        }
        let remoteFileID = (message.attachmentFileID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackID = attachmentFallbackFileID(for: message, conversation: conversation)
        let fileID = remoteFileID.isEmpty ? fallbackID : remoteFileID
        guard !fileID.isEmpty else { return nil }
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.isEmpty ? "未命名文件" : name
        let mediaCategory = attachmentMediaCategory(for: message)
        let mimeType = attachmentMimeType(from: message)
        guard !VoiceFileListPolicy.isVoiceMessageAsset(
            contentType: message.contentType,
            mediaCategory: mediaCategory,
            kind: message.kind.rawValue,
            previewKind: message.attachmentPreviewKind,
            type: message.attachmentExtension,
            name: resolvedName,
            mimeType: mimeType,
            fileExtension: message.attachmentExtension
        ) else {
            return nil
        }
        let previewURL = resolvedTenantFileAssetURL(message.attachmentPreviewURL)
        let downloadURL = resolvedTenantFileAssetURL(message.attachmentDownloadURL)
        let thumbnailURL = resolvedTenantFileAssetURL(message.attachmentThumbnailURL)
        let posterURL = resolvedTenantFileAssetURL(message.attachmentPosterURL)
        let coverURL = resolvedTenantFileAssetURL(message.attachmentCoverURL)
        let previewAvailable = attachmentPreviewAllowed(
            previewURL: previewURL,
            previewKind: message.attachmentPreviewKind,
            contentDisposition: message.attachmentContentDisposition,
            backendAvailable: message.attachmentPreviewAvailable
        )
        let downloadAvailable = !downloadURL.isEmpty || !remoteFileID.isEmpty
        let status: String
        if previewAvailable && downloadAvailable {
            status = "可预览 / 可下载"
        } else if downloadAvailable {
            status = "可下载"
        } else if previewAvailable {
            status = "可预览"
        } else {
            status = "待同步"
        }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        return FileItem(
            id: fileID,
            name: resolvedName,
            type: fileTypeLabel(name: resolvedName, mimeType: mimeType, category: mediaCategory, fallback: message.attachmentExtension),
            size: byteSize(message.attachmentSizeBytes ?? 0),
            sizeBytes: message.attachmentSizeBytes,
            owner: remarkPreferredDisplayName(
                identifiers: [message.senderId],
                candidates: [message.senderName],
                fallback: message.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? message.senderId : message.senderName
            ),
            source: conversation.title,
            time: message.createdAt.map(displayTime) ?? message.time,
            scope: conversation.kind == .group ? "群文件" : (conversation.kind == .direct ? "私聊文件" : "会话文件"),
            status: status,
            accentHex: stableSeed(fileID),
            remoteFileID: remoteFileID,
            previewURL: previewURL,
            downloadURL: downloadURL,
            previewAvailable: previewAvailable,
            downloadAvailable: downloadAvailable,
            channelID: channelID,
            channelType: channelType,
            channelSeq: message.channelSeq,
            mediaCategory: mediaCategory,
            contentType: message.contentType,
            kind: message.kind.rawValue,
            mimeType: mimeType,
            cacheKey: message.attachmentCacheKey,
            version: message.attachmentVersion,
            checksum: message.attachmentChecksum,
            fileExtension: message.attachmentExtension,
            thumbnailURL: thumbnailURL,
            posterURL: posterURL,
            coverURL: coverURL,
            previewKind: message.attachmentPreviewKind,
            contentDisposition: message.attachmentContentDisposition,
            width: message.attachmentWidth,
            height: message.attachmentHeight,
            durationSeconds: message.attachmentDurationSeconds
        )
    }

    private func attachmentFallbackFileID(for message: ChatMessage, conversation: ConversationMessageSnapshot) -> String {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：本地附件 fallback ID 纯逻辑从 AppState 拆出
        FileItemProjectionHelper.attachmentFallbackFileID(for: message, conversation: conversation)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    func fileItem(_ fileItem: FileItem, matchesQuery query: String, category: String) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：文件列表过滤纯逻辑从 AppState 拆出并复用静态分类集合
        FileItemProjectionHelper.fileItem(fileItem, matchesQuery: query, category: category)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    func mergeGroupFiles(_ fileItems: [FileItem]) {
        fileStore.mergeGroupFiles(fileItems.filter(isFileItemVisibleInFileLists))
    }

    func upsertTenantFile(_ file: FileItem) {
        guard isFileItemVisibleInFileLists(file) else { return }
        fileStore.upsertTenantFile(file)
    }

    private func fileTypeLabel(name: String, mimeType: String, category: String, fallback: String) -> String {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：文件类型展示纯逻辑从 AppState 拆出
        FileItemProjectionHelper.fileTypeLabel(
            name: name,
            mimeType: mimeType,
            category: category,
            fallback: fallback
        )
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func statusText(_ status: String) -> String {
        switch status.lowercased() {
        case "online":
            return "在线"
        case "offline":
            return "离线"
        case "hidden", "unknown", "normal", "active", "enabled":
            return ""
        case "busy":
            return "忙碌"
        default:
            return status.isEmpty ? "" : status
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

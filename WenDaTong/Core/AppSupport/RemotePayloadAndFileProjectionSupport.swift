import IM4Domain
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

// JHT_MOD_BEGIN APPSTATE_PRESENTATION_HELPER_SPLIT_20260913 - 修改开始：展示层纯工具从 AppState 拆出，保持原算法
enum AppStatePresentationHelper {
    static func messageKind(from contentType: String) -> MessageKind {
        switch contentType.lowercased() {
        case "rtc_call_record": return .rtcCallRecord
        case "image": return .image
        case "file", "attachment": return .file
        case "voice", "audio": return .voice
        case "video": return .video
        case "location": return .location
        case "contact_card": return .contactCard
        case "system": return .system
        default: return .text
        }
    }

    static func stableSeed(_ value: String) -> UInt {
        let palette: [UInt] = [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7, 0xFFB246, 0xFF6E91, 0x50D2FF]
        let sum = value.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[abs(sum) % palette.count]
    }
}
// JHT_MOD_END APPSTATE_PRESENTATION_HELPER_SPLIT_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改开始：JSON payload 基础读取从 AppState 拆出，保持原解析规则
enum RemotePayloadReader {
    static func string(_ payload: [String: JSONValue], _ keys: [String], fallback: String = "") -> String {
        for key in keys {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return fallback
    }

    static func attachmentObjects(_ payload: [String: JSONValue]) -> [[String: JSONValue]] {
        var objects = [payload]
        for key in [
            "file", "attachment", "attachments", "media", "sticker", "resource", "original", "thumbnail",
            "metadata", "file_metadata", "attachment_metadata", "sticker_metadata"
        ] {
            guard let value = payload[key] else { continue }
            if case .object(let object) = value {
                objects.append(object)
            } else if case .array(let values) = value {
                for item in values {
                    if case .object(let object) = item {
                        objects.append(object)
                    }
                }
            }
        }
        return objects
    }

    static func attachmentString(_ payload: [String: JSONValue], _ keys: [String], fallback: String = "") -> String {
        for object in attachmentObjects(payload) {
            let value = string(object, keys)
            if !value.isEmpty {
                return value
            }
        }
        return fallback
    }

    static func encodedAttachmentResourceID(from payload: [String: JSONValue]) -> String? {
        let fileID = attachmentString(payload, ["file_id"])
        if !fileID.isEmpty { return fileID }
        let attachmentID = attachmentString(payload, ["attachment_id"])
        if !attachmentID.isEmpty { return "attachment_id:\(attachmentID)" }
        let mediaID = attachmentString(payload, ["media_id"])
        if !mediaID.isEmpty { return "media_id:\(mediaID)" }
        return nil
    }

    static func attachmentBool(_ payload: [String: JSONValue], _ keys: [String]) -> Bool? {
        for object in attachmentObjects(payload) {
            if let value = bool(object, keys) {
                return value
            }
        }
        return nil
    }

    static func attachmentInt64(_ payload: [String: JSONValue], _ keys: [String]) -> Int64? {
        for object in attachmentObjects(payload) {
            if let value = int64(object, keys) {
                return value
            }
        }
        return nil
    }

    static func attachmentDouble(_ payload: [String: JSONValue], _ keys: [String]) -> Double? {
        for object in attachmentObjects(payload) {
            if let value = double(object, keys) {
                return value
            }
        }
        return nil
    }

    static func attachmentIntArray(_ payload: [String: JSONValue], _ keys: [String]) -> [Int] {
        for object in attachmentObjects(payload) {
            let values = intArray(object, keys)
            if !values.isEmpty {
                return values
            }
        }
        return []
    }

    static func bool(_ payload: [String: JSONValue], _ keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key]?.boolValue {
                return value
            }
        }
        return nil
    }

    // WDT_IOS1_SAFE_NUMERIC_20261023_BEGIN
    static func int64(_ payload: [String: JSONValue], _ keys: [String]) -> Int64? {
        for key in keys {
            guard let value = payload[key] else { continue }
            switch value {
            case .int(let intValue):
                return Int64(intValue)
            case .double(let doubleValue):
                if let parsed = Int64(exactly: doubleValue.rounded(.towardZero)) { return parsed }
            case .string(let stringValue):
                if let parsed = Int64(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            default:
                continue
            }
        }
        return nil
    }

    static func double(_ payload: [String: JSONValue], _ keys: [String]) -> Double? {
        for key in keys {
            guard let value = payload[key] else { continue }
            switch value {
            case .int(let intValue):
                return Double(intValue)
            case .double(let doubleValue):
                if doubleValue.isFinite { return doubleValue }
            case .string(let stringValue):
                if let parsed = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite {
                    return parsed
                }
            default:
                continue
            }
        }
        return nil
    }

    static func intArray(_ payload: [String: JSONValue], _ keys: [String]) -> [Int] {
        for key in keys {
            guard let value = payload[key] else { continue }
            guard case .array(let values) = value else { continue }
            let parsed = values.compactMap { item -> Int? in
                switch item {
                case .int(let intValue):
                    return intValue
                case .double(let doubleValue):
                    return Int(exactly: doubleValue.rounded())
                case .string(let stringValue):
                    return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                default:
                    return nil
                }
            }
            if !parsed.isEmpty {
                return parsed
            }
        }
        return []
    }

    // WDT_IOS1_SAFE_NUMERIC_20261023_END

    static func stringArray(_ payload: [String: JSONValue], _ keys: [String]) -> [String] {
        for key in keys {
            guard let value = payload[key] else { continue }
            let values: [String]
            if case .array(let array) = value {
                values = array.compactMap {
                    $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if let stringValue = value.stringValue {
                values = stringValue
                    .split { ["、", ",", "，", ";", "；"].contains(String($0)) }
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                values = []
            }
            let filtered = values.filter { !$0.isEmpty }
            if !filtered.isEmpty {
                return Array(NSOrderedSet(array: filtered).compactMap { $0 as? String })
            }
        }
        return []
    }

    static func attachmentDuration(from payload: [String: JSONValue]) -> Double? {
        if let seconds = attachmentDouble(payload, ["duration_seconds", "duration"]) {
            return seconds
        }
        if let milliseconds = attachmentDouble(payload, ["duration_ms"]) {
            return milliseconds / 1000.0
        }
        return nil
    }

    static func attachmentWaveform(from payload: [String: JSONValue]) -> [Int] {
        VoiceMessagePayload.normalizedWaveform(attachmentIntArray(payload, ["waveform", "waveform_samples", "peaks"]))
    }
}
// JHT_MOD_END APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：文件/收藏列表纯判断从 AppState 拆出，并复用静态分类集合
enum FileItemProjectionHelper {
    private static let attachmentSummaryKeywords = ["文件", "图片", "视频"]
    private static let attachmentSummaryExtensions = [
        ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".txt", ".md",
        ".csv", ".zip", ".rar", ".7z", ".png", ".jpg", ".jpeg", ".gif", ".webp",
        ".mp4", ".mov", ".webm", ".mp3", ".m4a", ".wav"
    ]

    private static let favoriteUnavailableStatuses: Set<String> = [
        "deleted", "delete", "removed", "recalled", "recall", "revoked",
        "expired", "invalid", "unavailable", "disabled", "failed"
    ]
    private static let favoriteMediaContentTypes: Set<String> = [
        "image", "video", "audio", "voice", "pdf", "archive"
    ]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz"]
    private static let documentExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "txt", "md"]

    static func attachmentPreviewAllowed(
        previewURL: String,
        previewKind: String,
        contentDisposition: String,
        backendAvailable: Bool?
    ) -> Bool {
        let trimmedPreviewURL = previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPreviewURL.isEmpty else { return false }
        let normalizedPreviewKind = previewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedPreviewKind == "download" {
            return false
        }
        let normalizedDisposition = contentDisposition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedDisposition.hasPrefix("attachment") {
            return false
        }
        if let backendAvailable {
            return backendAvailable
        }
        return true
    }

    static func favoriteAssetFallbackMessageID(_ remote: RemoteFavoriteAssetItem) -> String {
        [
            remote.messageID,
            remote.cursor,
            remote.channelID,
            remote.channelSeq > 0 ? String(remote.channelSeq) : ""
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    static func favoriteAssetMediaCategory(
        payloadCategory: String,
        contentType: String,
        fallback: FavoriteAssetCategory
    ) -> String {
        if !payloadCategory.isEmpty {
            let category = FavoriteAssetCategory(serverValue: payloadCategory)
            return category.requestValue == "all" ? payloadCategory : category.requestValue
        }
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if favoriteMediaContentTypes.contains(normalizedContentType) {
            return normalizedContentType == "voice" ? "audio" : normalizedContentType
        }
        return fallback == .all ? "" : fallback.requestValue
    }

    static func favoriteAssetIsUnavailable(_ remote: RemoteFavoriteAssetItem) -> Bool {
        let status = remote.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !status.isEmpty else { return false }
        return favoriteUnavailableStatuses.contains(status)
            || status.contains("deleted")
            || status.contains("recalled")
            || status.contains("expired")
    }

    static func fileListMessageSummaryLooksLikeAttachment(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        if attachmentSummaryKeywords.contains(where: { value.contains($0) }) {
            return true
        }
        return attachmentSummaryExtensions.contains { value.contains($0) }
    }

    static func fileItemsReferToSameAttachment(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        let lhsRemoteID = lhs.remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsRemoteID = rhs.remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lhsRemoteID.isEmpty, !rhsRemoteID.isEmpty {
            return lhsRemoteID == rhsRemoteID
        }
        let lhsChannelID = lhs.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsChannelID = rhs.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhsChannelID.isEmpty,
              lhsChannelID == rhsChannelID,
              lhs.channelType == rhs.channelType else {
            return false
        }
        let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhsName.isEmpty, lhsName == rhsName else { return false }
        if let lhsSize = lhs.sizeBytes, let rhsSize = rhs.sizeBytes, lhsSize > 0, rhsSize > 0 {
            return lhsSize == rhsSize
        }
        return true
    }

    static func attachmentFallbackFileID(for message: ChatMessage, conversation: ConversationMessageSnapshot) -> String {
        let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !messageID.isEmpty {
            return "local-attachment|\(conversation.id)|\(messageID)"
        }
        if message.channelSeq > 0 {
            return "local-attachment|\(conversation.id)|seq-\(message.channelSeq)"
        }
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        return "local-attachment|\(conversation.id)|\(name)|\(message.time)"
    }

    static func fileItem(_ fileItem: FileItem, matchesQuery query: String, category: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryMatches = trimmedQuery.isEmpty
            || fileItem.name.localizedCaseInsensitiveContains(trimmedQuery)
            || fileItem.owner.localizedCaseInsensitiveContains(trimmedQuery)
            || fileItem.source.localizedCaseInsensitiveContains(trimmedQuery)
        guard queryMatches else { return false }
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCategory.isEmpty else { return true }
        let mediaCategory = fileItem.mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mimeType = fileItem.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = fileItem.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = (fileItem.fileExtension.isEmpty ? (fileItem.name as NSString).pathExtension : fileItem.fileExtension)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedCategory {
        case "image":
            return mediaCategory == "image" || mimeType.hasPrefix("image/") || imageExtensions.contains(ext)
        case "video":
            return mediaCategory == "video" || mimeType.hasPrefix("video/") || videoExtensions.contains(ext)
        case "audio":
            return mediaCategory == "audio" || mimeType.hasPrefix("audio/") || audioExtensions.contains(ext)
        case "archive":
            return mediaCategory == "archive" || archiveExtensions.contains(ext)
        case "pdf":
            return mediaCategory == "pdf" || mimeType.contains("pdf") || type == "pdf" || ext == "pdf"
        case "document":
            return mediaCategory == "document"
                || mimeType.contains("spreadsheet")
                || mimeType.contains("excel")
                || mimeType.contains("word")
                || mimeType.contains("document")
                || documentExtensions.contains(ext)
        default:
            return true
        }
    }

    static func fileTypeLabel(name: String, mimeType: String, category: String, fallback: String) -> String {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedCategory {
        case "image": return "图片"
        case "video": return "视频"
        case "pdf": return "PDF"
        case "audio": return "音频"
        case "spreadsheet": return "表格"
        case "document": break
        case "archive": return "压缩包"
        default: break
        }
        let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedMime.hasPrefix("image/") { return "图片" }
        if normalizedMime.hasPrefix("video/") { return "视频" }
        if normalizedMime.hasPrefix("audio/") { return "音频" }
        if normalizedMime.contains("pdf") { return "PDF" }
        if normalizedMime.contains("spreadsheet") || normalizedMime.contains("excel") { return "表格" }
        if normalizedMime.contains("word") || normalizedMime.contains("document") { return "文档" }
        let ext = (name as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return fallback.isEmpty ? "文件" : fallback.uppercased()
    }
}
// JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束 // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

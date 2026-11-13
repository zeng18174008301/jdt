import SwiftUI
import IM4Features
import UIKit
import QuickLook
import AVFoundation

// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
typealias FileVisualKind = IM4Features.FileVisualKind
// WDT_IOS1_FEATURES_FILES_UI_20261111_END

extension FileItem {
    func mediaResourceMetadata(scope: String) -> MediaResourceMetadata {
        let authoritativeFileID = remoteLookupID
        let authoritativeCacheKey = authoritativeFileID.isEmpty ? "" : cacheKey
        return MediaResourceMetadata(
            scope: scope,
            fileID: authoritativeFileID,
            cacheKey: authoritativeCacheKey,
            version: version,
            checksumSHA256: checksum,
            createdAt: time,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            fileName: name,
            fileExtension: fileExtension,
            thumbnailCacheKey: authoritativeCacheKey,
            thumbnailVersion: version,
            previewCacheKey: authoritativeCacheKey,
            previewVersion: version
        )
    }

    var mediaPipelinePreviewResourceKind: MediaResourceKind {
        let hasPreviewURL = !previewURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return inlinePreviewAllowed && hasPreviewURL ? .preview : .original
    }

    var visualKind: FileVisualKind {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMedia = mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPreview = previewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (name as NSString).pathExtension.lowercased()
            : fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = [normalizedMedia, normalizedPreview, normalizedType, ext]

        if candidates.contains(where: { ["图片", "image", "img", "png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains($0) }) {
            return .image
        }
        if candidates.contains(where: { ["视频", "video", "mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains($0) }) {
            return .video
        }
        if candidates.contains("pdf") {
            return .pdf
        }
        if candidates.contains(where: { ["表格", "xlsx", "xls", "csv", "numbers"].contains($0) }) {
            return .spreadsheet
        }
        if candidates.contains(where: { ["文档", "doc", "docx", "pages"].contains($0) }) {
            return .word
        }
        if candidates.contains(where: { ["ppt", "pptx", "key"].contains($0) }) {
            return .presentation
        }
        if candidates.contains(where: { ["zip", "rar", "7z", "tar", "gz"].contains($0) }) {
            return .archive
        }
        if candidates.contains(where: { ["音频", "audio", "mp3", "m4a", "aac", "wav", "flac", "ogg"].contains($0) }) {
            return .audio
        }
        if candidates.contains(where: { ["txt", "md", "json", "xml", "log"].contains($0) }) {
            return .text
        }
        return .unknown
    }

    var thumbnailRemoteURL: URL? {
        thumbnailRemoteURL(for: visualKind)
    }

    func thumbnailRemoteURL(for visualKind: FileVisualKind) -> URL? {
        if let explicit = firstRenderableMediaURL(in: [thumbnailURL, coverURL, posterURL], imageResource: true) {
            return explicit
        }
        switch visualKind {
        case .image:
            return firstRenderableMediaURL(in: [previewURL, downloadURL])
        case .video:
            return nil
        default:
            return nil
        }
    }

    var videoFrameRemoteURL: URL? {
        videoFrameRemoteURL(for: visualKind)
    }

    func videoFrameRemoteURL(for visualKind: FileVisualKind) -> URL? {
        guard visualKind == .video else { return nil }
        return firstRenderableMediaURL(in: [previewURL, downloadURL])
    }

    func mediaThumbnailCacheKey(for visualKind: FileVisualKind) -> String {
        let stableKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableFileID = remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "file-media-preview",
            stableFileID.isEmpty ? stableKey : stableFileID,
            visualKind == .video ? "video-frame" : "thumbnail",
            stableVersion
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    var bestPreviewURL: URL? {
        guard inlinePreviewAllowed else { return nil }
        let candidate = !previewURL.isEmpty ? previewURL : downloadURL
        return URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var systemPreviewRemoteURL: URL? {
        if let previewURL = bestPreviewURL {
            return previewURL
        }
        guard visualKind.canUseSystemPreview else { return nil }
        let candidate = !downloadURL.isEmpty ? downloadURL : previewURL
        return URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var shareURL: URL? {
        let candidate = !downloadURL.isEmpty ? downloadURL : previewURL
        return URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var canAttemptSystemPreview: Bool {
        visualKind.canUseSystemPreview
            && (hasRemoteFileID || systemPreviewRemoteURL != nil)
    }

    func systemPreviewCacheIdentity(scope: String) -> String? {
        let stableKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableFileID = remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableSource = stableFileID.isEmpty ? stableKey : stableFileID
        guard !stableSource.isEmpty else { return nil }
        let versionValue = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksumValue = checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeValue = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            scopeValue.isEmpty ? "scope:missing" : "scope:\(scopeValue)",
            stableFileID.isEmpty ? "cache_key:\(stableSource)" : "file_id:\(stableSource)",
            versionValue.isEmpty ? "" : "version:\(versionValue)",
            checksumValue.isEmpty ? "" : "checksum:\(checksumValue)",
            sizeBytes.map { "size:\($0)" } ?? "",
            mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    private var inlinePreviewAllowed: Bool {
        let normalizedPreviewKind = previewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedPreviewKind == "download" {
            return false
        }
        let normalizedDisposition = contentDisposition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedDisposition.hasPrefix("attachment") {
            return false
        }
        return previewAvailable || !previewURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func firstRenderableMediaURL(in rawValues: [String], imageResource: Bool = false) -> URL? {
        for rawValue in rawValues {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !isTenantFileEndpointLike(trimmed, imageResource: imageResource),
                  let url = URL(string: trimmed),
                  (url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "")),
                  !isTenantFileEndpointLike(url.path, imageResource: imageResource) else {
                continue
            }
            return url
        }
        return nil
    }

    private func isTenantFileEndpointLike(_ rawValue: String, imageResource: Bool = false) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URL(string: trimmed)?.path ?? trimmed
        guard path == "/api/tenant/files" || path.hasPrefix("/api/tenant/files/") else { return false }
        guard imageResource else { return true }
        let parts = path.split(separator: "/")
        return parts.count <= 4 || (parts.count == 5 && parts.last == "presign-download")
    }
}

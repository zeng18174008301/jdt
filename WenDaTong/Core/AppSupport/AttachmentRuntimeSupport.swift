// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
import Combine
import Foundation
import IM4Data // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111
import IM4Domain // WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
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

typealias PendingAttachmentUpload = IM4Domain.PendingAttachmentUpload

extension IM4Domain.PendingAttachmentUpload {
    init(
        kind: MessageKind,
        name: String,
        mimeType: String,
        sizeBytes: Int64,
        data: Data? = nil,
        fileURL: URL? = nil,
        removeFileWhenFinished: Bool = false,
        conversationID: String,
        quote: String?,
        replyContext: MessageReplyContext?,
        voiceDurationMS: Int? = nil,
        voiceWaveform: [Int] = [],
        onPolicyRejected: (@MainActor () -> Void)? = nil
    ) {
        self.init(
            kind: kind, name: name, mimeType: mimeType, sizeBytes: sizeBytes,
            data: data, fileURL: fileURL, removeFileWhenFinished: removeFileWhenFinished,
            conversationID: conversationID, quote: quote, replyContext: replyContext,
            voiceDurationMS: voiceDurationMS,
            normalizedVoiceWaveform: VoiceMessagePayload.normalizedWaveform(voiceWaveform),
            onPolicyRejected: onPolicyRejected
        )
    }

    func removeOwnedFile() {
        guard removeFileWhenFinished else { return }
        PendingAttachmentFileStore.removeManagedFile(at: fileURL)
    }
}

enum AttachmentUploadPhase: String, Equatable {
    case config
    case presign
    case put
    case finalize
    case send

    var failedStatus: String {
        "failed_\(rawValue)"
    }

    static func failurePhase(from status: String) -> AttachmentUploadPhase? {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("failed_") else { return nil }
        return AttachmentUploadPhase(rawValue: String(normalized.dropFirst("failed_".count)))
    }
}

typealias AttachmentUploadCheckpoint = IM4Domain.AttachmentUploadCheckpoint<RemoteAvatarFile>

extension AttachmentUploadFailure {
    init(error: Error) {
        if error is LocalMessageDatabaseError { self.init(code: .localPersistence); return }
        if error is CocoaError { self.init(code: .localFile); return }
        if error is EncodingError { self.init(code: .requestEncoding); return }
        if error is DecodingError { self.init(code: .decode); return }
        if error is CancellationError { self.init(code: .cancelled); return }
        if let error = error as? URLError {
            let code: Code
            switch error.code {
            case .timedOut: code = .timeout
            case .cannotFindHost, .dnsLookupFailed: code = .dns
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: code = .offline
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .clientCertificateRequired: code = .tls
            case .cancelled: code = .cancelled
            default: code = .transport
            }
            self.init(code: code)
            return
        }
        guard let error = error as? IMAPIError else { self.init(code: .unknown); return }
        switch error {
        case .missingContext: self.init(code: .missingContext)
        case .badURL: self.init(code: .route)
        case .httpStatus(let status, _): self.init(code: .http, httpStatus: status)
        case .businessForbidden(let code, _, _), .conflict(let code, _),
             .loginSecurity(let code, _, _), .rateLimited(let code, _, _, _):
            self.init(code: .policy, serverCode: code)
        case .unauthorized: self.init(code: .policy, serverCode: "unauthorized")
        case .forbidden: self.init(code: .policy, serverCode: "forbidden")
        case .forcedAuthRequired: self.init(code: .policy)
        case .securityBlocked: self.init(code: .policy, serverCode: "security_blocked")
        case .emptyResponse: self.init(code: .invalidResponse)
        case .server: self.init(code: .unknown)
        }
    }
}

@MainActor
final class VoiceMessageAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var didFinish: (@MainActor (ObjectIdentifier, Bool) -> Void)?
    var didFailToDecode: (@MainActor (ObjectIdentifier) -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.didFinish?(playerID, flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.didFailToDecode?(playerID)
        }
    }
}

// JHT_MOD_BEGIN ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：本地附件预览结果允许后台计算后安全回传主线程
// WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110
typealias LocalAttachmentPreviewResources = IM4Domain.LocalAttachmentPreviewResources

extension IM4Domain.LocalAttachmentPreviewResources {
    var hasUsableLocalFile: Bool {
        [previewURL, downloadURL, thumbnailURL]
            .contains { $0?.usableLocalFileURL != nil }
    }
}

// JHT_MOD_BEGIN ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：附件本地预览生成从 AppState/MainActor 抽到 support helper
enum AttachmentPreviewResourceBuilder {
    // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：发送入口先生成轻量本地资源，重的尺寸/缩略图后台补齐
    static func lightweightLocalFileResources(
        localURL: URL,
        mediaCategory: String
    ) -> LocalAttachmentPreviewResources? {
        guard localURL.usableLocalFileURL != nil else { return nil }
        switch mediaCategory {
        case "image":
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: localURL,
                width: nil,
                height: nil
            )
        case "video", "pdf":
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        default:
            return LocalAttachmentPreviewResources(
                previewURL: nil,
                downloadURL: localURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        }
    }

    static func outgoingPreviewResourcesOffMain(
        messageID: String,
        name: String,
        data: Data?,
        fileURL: URL?,
        mediaCategory: String
    ) async -> LocalAttachmentPreviewResources? {
        await Task.detached(priority: .utility) {
            if let fileURL {
                return localFilePreviewResources(
                    messageID: messageID,
                    localURL: fileURL,
                    mediaCategory: mediaCategory
                )
            }
            guard let data else { return nil }
            return dataPreviewResources(
                messageID: messageID,
                name: name,
                data: data,
                mediaCategory: mediaCategory
            )
        }.value
    }

    static func dataPreviewResources(
        messageID: String,
        name: String,
        data: Data,
        mediaCategory: String
    ) -> LocalAttachmentPreviewResources? {
        guard let attachmentURL = writeTemporaryAttachmentData(data, messageID: messageID, name: name) else { return nil }
        switch mediaCategory {
        case "image":
            let image = UIImage(data: data)
            return LocalAttachmentPreviewResources(
                previewURL: attachmentURL,
                downloadURL: attachmentURL,
                thumbnailURL: attachmentURL,
                width: image.map { Int($0.size.width) },
                height: image.map { Int($0.size.height) }
            )
        case "video":
            let thumbnail = videoThumbnailURL(for: attachmentURL, messageID: messageID)
            let size = thumbnail.flatMap { UIImage(contentsOfFile: $0.path)?.size }
            return LocalAttachmentPreviewResources(
                previewURL: attachmentURL,
                downloadURL: attachmentURL,
                thumbnailURL: thumbnail,
                width: size.map { Int($0.width) },
                height: size.map { Int($0.height) }
            )
        case "pdf":
            return LocalAttachmentPreviewResources(
                previewURL: attachmentURL,
                downloadURL: attachmentURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        default:
            return LocalAttachmentPreviewResources(
                previewURL: nil,
                downloadURL: attachmentURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        }
    }

    static func localFilePreviewResources(
        messageID: String,
        localURL: URL,
        mediaCategory: String
    ) -> LocalAttachmentPreviewResources? {
        downloadedPreviewResources(
            messageID: messageID,
            localURL: localURL,
            mediaCategory: mediaCategory
        )
    }
    // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束

    static func downloadedPreviewResourcesOffMain(
        messageID: String,
        localURL: URL,
        mediaCategory: String
    ) async -> LocalAttachmentPreviewResources? {
        await Task.detached(priority: .utility) {
            downloadedPreviewResources(
                messageID: messageID,
                localURL: localURL,
                mediaCategory: mediaCategory
            )
        }.value
    }

    private static func downloadedPreviewResources(
        messageID: String,
        localURL: URL,
        mediaCategory: String
    ) -> LocalAttachmentPreviewResources? {
        guard localURL.usableLocalFileURL != nil else { return nil }
        switch mediaCategory {
        case "image":
            let imageSize = RemoteImageDecoder.pixelSize(fromFileURL: localURL)
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: localURL,
                width: imageSize.map { Int($0.width) },
                height: imageSize.map { Int($0.height) }
            )
        case "video":
            let thumbnail = videoThumbnailURL(for: localURL, messageID: messageID)
            let size = thumbnail.flatMap { UIImage(contentsOfFile: $0.path)?.size }
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: thumbnail,
                width: size.map { Int($0.width) },
                height: size.map { Int($0.height) }
            )
        case "pdf":
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        default:
            return LocalAttachmentPreviewResources(
                previewURL: nil,
                downloadURL: localURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        }
    }

    private static func videoThumbnailURL(for videoURL: URL, messageID: String) -> URL? {
        do {
            let asset = AVAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            let cgImage = try [0.5, 1.0, 0.0].lazy.compactMap { seconds in
                try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            }.first ?? generator.copyCGImage(at: .zero, actualTime: nil)
            let image = UIImage(cgImage: cgImage)
            guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
            let url = videoURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(messageID)_thumbnail.jpg", isDirectory: false)
            try IM4Data.MediaBlobFileIO.writeReplacingData(data, at: url)
            return url
        } catch {
            return nil
        }
    }

    // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：发送本地 data 的临时文件写入从 AppState 拆到 support helper
    private static func writeTemporaryAttachmentData(_ data: Data, messageID: String, name: String) -> URL? {
        do {
            let fileName = "\(messageID)_\(sanitizedAttachmentFileName(name))"
            return try IM4Data.MediaBlobFileIO.writePendingAttachmentData(data, fileName: fileName)
        } catch { return nil }
    }

    private static func sanitizedAttachmentFileName(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "attachment" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment" : sanitized
    }
    // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束
}
// JHT_MOD_END ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN ATTACHMENT_THUMBNAIL_CACHE_IO_PERF_20260912 - 修改开始：缩略图缓存临时文件 IO 从 AppState/MainActor 抽离
enum AttachmentTemporaryFileWriter {
    static func writeThumbnailDataOffMain(_ data: Data) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try IM4Data.MediaBlobFileIO.writeTemporaryThumbnailData(data)
        }.value
    }

    static func removeTemporaryFileOffMain(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? IM4Data.MediaBlobFileIO.removeItem(at: url)
        }.value
    }

    // JHT_MOD_BEGIN ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改开始：附件完整性校验和下载 staging 清理放到后台执行
    static func verifyFileOffMain(_ url: URL, integrity: MediaFileIntegrityAuthority) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            try integrity.verify(fileAt: url)
        }.value
    }

    static func firstVerifiedFileOffMain(
        in candidates: [URL],
        integrity: MediaFileIntegrityAuthority
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            candidates.first { (try? integrity.verify(fileAt: $0)) != nil }
        }.value
    }

    static func removeDownloadStagingDirectoryIfNeededOffMain(for url: URL) async {
        guard isDownloadStagingURL(url) else { return }
        await Task.detached(priority: .utility) {
            try? IM4Data.MediaBlobFileIO.removeItem(at: url.deletingLastPathComponent())
        }.value
    }

    private static func isDownloadStagingURL(_ url: URL) -> Bool {
        url.path.contains("/BlueStoneIMAttachmentDownloadStaging/")
    }
    // JHT_MOD_END ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改结束
}
// JHT_MOD_END ATTACHMENT_THUMBNAIL_CACHE_IO_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：统一媒体缓存文件 IO 从 AppState/MainActor 抽离
typealias MediaCacheFileRemovalOutcome = IM4Data.MediaBlobFileRemovalOutcome

enum MediaCacheFileIO {
    static func fileExistsOffMain(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            IM4Data.MediaBlobFileIO.fileExists(at: url)
        }.value
    }

    static func removeFileIfExistsOffMain(_ url: URL) async -> MediaCacheFileRemovalOutcome {
        await Task.detached(priority: .utility) {
            IM4Data.MediaBlobFileIO.removeFileIfExists(at: url)
        }.value
    }

    static func removeFileIgnoringErrorsOffMain(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? IM4Data.MediaBlobFileIO.removeItem(at: url)
        }.value
    }
}
// JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END

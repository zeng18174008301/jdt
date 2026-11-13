import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ChatView {
    func handleAttachmentTap(_ message: ChatMessage) {
        if message.status == .sending || (message.status == .failed && screenActions.media.canRetryAttachmentUpload(message)) {
            selectedAttachmentMessage = message
            return
        }

        let mediaCategory = screenActions.media.attachmentMediaCategory(for: message)
        switch mediaCategory {
        case "image":
            prepareMediaPreview(message, mediaCategory: "image")
        case "video":
            prepareMediaPreview(message, mediaCategory: "video")
        case "pdf":
            prepareDocumentPreview(message)
        default:
            prepareFileShare(message)
        }
    }

    private func prepareMediaPreview(_ message: ChatMessage, mediaCategory: String) {
        let entry = secondaryEntry()
        Task {
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
            guard await screenActions.authority.authorizeFilePreview() else { return }
            do {
                let localURL = try await screenActions.media.prepareMessageAttachmentLocalFile(
                    message, conversationID: conversationID,
                    preferPreview: mediaCategory != "image" && !AttachmentGIFPresentation.isGIF(message) // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
                )
                let item = AttachmentMediaPreviewItem(message: currentMessageSnapshot(for: message), localURL: localURL)
                await MainActor.run {
                    switch mediaCategory {
                    case "video":
                        previewVideoAttachment = item
                    default:
                        previewImageAttachment = item
                    }
                }
            } catch is CancellationError {
                // User cancelled; no toast needed.
            } catch {
                await MainActor.run {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("下载失败，请重试")
                }
            }
        }
    }

    private func prepareDocumentPreview(_ message: ChatMessage) {
        let entry = secondaryEntry()
        Task {
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
            guard await screenActions.authority.authorizeFilePreview() else { return }
            do {
                let localURL = try await screenActions.media.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: true)
                await MainActor.run {
                    attachmentPreviewDocument = AttachmentLocalPreviewDocument(url: localURL)
                }
            } catch is CancellationError {
                // User cancelled; no toast needed.
            } catch {
                await MainActor.run {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("下载失败，请重试")
                }
            }
        }
    }

    private func prepareFileShare(_ message: ChatMessage) {
        let entry = secondaryEntry()
        Task {
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
            guard await screenActions.authority.authorizeFilePreview() else { return }
            do {
                let localURL = try await screenActions.media.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                await MainActor.run {
                    attachmentShareItem = AttachmentShareItem(url: localURL)
                }
            } catch is CancellationError {
                // User cancelled; no toast needed.
            } catch {
                await MainActor.run {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("下载失败，请重试")
                }
            }
        }
    }

    func canSaveAttachmentFromActionMenu(_ message: ChatMessage) -> Bool {
        AttachmentSaveCapabilityPolicy.canSave(
            kind: message.kind,
            mediaCategory: screenActions.media.attachmentMediaCategory(for: message),
            status: message.status,
            isDeletedLocally: message.isDeletedLocally,
            hasResolvableAsset: screenActions.media.resolvedAttachmentDownloadURL(for: message) != nil
            || screenActions.media.resolvedAttachmentBestPreviewURL(for: message) != nil
                || screenActions.media.attachmentCanRefreshRemoteFile(message)
        )
    }

    func canFavoriteAssetFromActionMenu(_ message: ChatMessage) -> Bool {
        guard !message.isRTCCallRecordMessage,
              message.status != .sending,
              message.status != .failed,
              message.status != .recalled,
              !message.isDeletedLocally,
              !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !message.id.hasPrefix("local_") else {
            return false
        }
        if message.kind == .image || message.kind == .video || message.kind == .voice {
            return true
        }
        guard message.kind == .file else { return false }
        let mediaCategory = screenActions.media.attachmentMediaCategory(for: message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["image", "video", "audio", "voice", "pdf", "document", "spreadsheet", "archive"].contains(mediaCategory) {
            return true
        }
        return !(message.attachmentFileID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveAttachmentFromActionMenu(_ message: ChatMessage) {
        let mediaCategory = screenActions.media.attachmentMediaCategory(for: message)
        let entry = secondaryEntry()
        Task {
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
            do {
                let localURL = try await screenActions.media.prepareMessageAttachmentLocalFile(
                    message,
                    conversationID: conversationID,
                    preferPreview: !AttachmentGIFPresentation.isGIF(message) && (mediaCategory == "image" || mediaCategory == "video")
                )
                switch mediaCategory {
                case "image":
                    await saveImageAttachment(localURL, originalGIF: AttachmentGIFPresentation.isGIF(message))
                case "video":
                    await saveVideoAttachment(localURL)
                default:
                    await MainActor.run {
                        attachmentShareItem = AttachmentShareItem(url: localURL)
                    }
                }
            } catch is CancellationError {
                // User cancelled; no toast needed.
            } catch {
                await MainActor.run {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("文件下载失败，无法保存，请重试")
                }
            }
        }
    }

    private func saveImageAttachment(_ localURL: URL, originalGIF: Bool = false) async {
        if originalGIF {
            let result = await AttachmentPhotoLibrarySaver.saveOriginalImage(at: localURL)
            switch result {
            case .success: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("图片已保存到相册")
            case .denied: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("没有相册保存权限，请在系统设置中开启")
            case .failed, .unknownFailure: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("图片保存失败，请重试")
            }
            return
        }
        guard let image = UIImage(contentsOfFile: localURL.path) else {
            await MainActor.run {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("图片文件不存在，请重新下载后保存")
            }
            return
        }
        let result = await AttachmentPhotoLibrarySaver.saveImage(image)
        await MainActor.run {
            switch result {
            case .success:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("图片已保存到相册")
            case .denied:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("没有相册保存权限，请在系统设置中开启")
            case .failed(let message):
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("图片保存失败：\(message)")
            case .unknownFailure:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("图片保存失败，请重试")
            }
        }
    }

    private func saveVideoAttachment(_ localURL: URL) async {
        guard localURL.isFileURL, FileManager.default.fileExists(atPath: localURL.path) else {
            await MainActor.run {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("视频文件不存在，请重新下载后保存")
            }
            return
        }
        let result = await AttachmentPhotoLibrarySaver.saveVideo(at: localURL)
        await MainActor.run {
            switch result {
            case .success:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("视频已保存到相册")
            case .denied:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("没有相册保存权限，请在系统设置中开启")
            case .failed(let message):
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("视频保存失败：\(message)")
            case .unknownFailure:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("视频保存失败，请重试")
            }
        }
    }

}

struct PendingAttachmentSelection: Identifiable {
    let id = UUID()
    let kind: MessageKind
    let name: String
    let mimeType: String
    let sizeBytes: Int64?
    let data: Data?
    let fileURL: URL?
    let ownsFileURL: Bool
    let previewImage: UIImage?

    init(
        kind: MessageKind,
        name: String,
        mimeType: String,
        sizeBytes: Int64?,
        data: Data? = nil,
        fileURL: URL? = nil,
        ownsFileURL: Bool = false,
        previewImage: UIImage?
    ) {
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.fileURL = fileURL
        self.ownsFileURL = ownsFileURL
        self.previewImage = previewImage
    }

    var asBatch: PendingAttachmentSelectionBatch {
        PendingAttachmentSelectionBatch(selections: [self])
    }

    static func photoLibrarySelection(item: PhotoLibraryPickedItem) -> PendingAttachmentSelection? {
        guard item.data?.isEmpty == false || item.fileURL != nil else { return nil }
        let contentType = preferredContentType(from: item.contentTypes)
        let isVideo = contentType.map(isVideoContentType) ?? false
        let fileExtension = sanitizedExtension(
            contentType?.preferredFilenameExtension,
            fallback: isVideo ? "mov" : "jpg"
        )
        let mimeType = contentType?.preferredMIMEType ?? (isVideo ? "video/quicktime" : "image/jpeg")
        let previewImage: UIImage?
        if isVideo {
            // Like Android, show the video icon immediately in the send sheet.
            // Chat covers continue through the normal attachment preview path.
            previewImage = nil
        } else if let fileURL = item.fileURL {
            previewImage = RemoteImageDecoder.image(fromFileURL: fileURL, maxPixelSize: 320)
        } else if let data = item.data {
            previewImage = RemoteImageDecoder.image(from: data, maxPixelSize: 320) // WDT_IOS1_IMAGE_BUDGET_20261023
        } else {
            previewImage = nil
        }
        return PendingAttachmentSelection(
            kind: isVideo ? .file : .image,
            name: isVideo ? "视频消息.\(fileExtension)" : "图片消息.\(fileExtension)",
            mimeType: mimeType,
            sizeBytes: item.sizeBytes,
            data: item.data,
            fileURL: item.fileURL,
            ownsFileURL: item.fileURL != nil,
            previewImage: previewImage
        )
    }

    var effectiveSizeBytes: Int64 {
        sizeBytes
            ?? data.map { Int64($0.count) }
            ?? fileURL.flatMap { PendingAttachmentFileStore.fileSize(at: $0) }
            ?? 0
    }

    func removeOwnedFile() {
        guard ownsFileURL else { return }
        PendingAttachmentFileStore.removeManagedFile(at: fileURL)
    }

    var mediaCategory: String {
        let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if kind == .image || normalizedMime.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains(ext) {
            return "image"
        }
        if normalizedMime.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains(ext) {
            return "video"
        }
        if normalizedMime.contains("pdf") || ext == "pdf" {
            return "pdf"
        }
        return "file"
    }

    private static func preferredContentType(from contentTypes: [UTType]) -> UTType? {
        contentTypes.first(where: isVideoContentType)
            ?? contentTypes.first(where: { $0.conforms(to: .image) })
            ?? contentTypes.first
    }

    private static func isVideoContentType(_ contentType: UTType) -> Bool {
        contentType.conforms(to: .movie) || (contentType.preferredMIMEType?.hasPrefix("video/") ?? false)
    }

    private static func sanitizedExtension(_ rawValue: String?, fallback: String) -> String {
        let value = (rawValue ?? fallback)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let allowed = CharacterSet.alphanumerics
        let sanitized = String(value.unicodeScalars.filter { allowed.contains($0) })
        return sanitized.isEmpty ? fallback : sanitized
    }

}

struct PendingAttachmentSelectionBatch: Identifiable {
    let id = UUID()
    let selections: [PendingAttachmentSelection]

    var isMultiple: Bool {
        selections.count > 1
    }

    var photoCount: Int {
        selections.filter { $0.mediaCategory == "image" }.count
    }

    var videoCount: Int {
        selections.filter { $0.mediaCategory == "video" }.count
    }

    var totalSizeBytes: Int64 {
        selections.reduce(Int64(0)) { $0 + $1.effectiveSizeBytes }
    }

    func removeOwnedFiles() {
        selections.forEach { $0.removeOwnedFile() }
    }
}


struct AttachmentSendConfirmationSheet: View {
    @EnvironmentObject private var state: AppState
    let batch: PendingAttachmentSelectionBatch
    let onCancel: () -> Void
    let onSend: () -> Void
    var body: some View {
        state.observeChatSecondaryEntry { entry in
            state.fileStore.observeUploadConfiguration(\.config) { config in
                AttachmentSendConfirmationContent(batch: input, config: config,
                    onCancel: { if entry.isCurrent(state) { onCancel() } },
                    onSend: {
                        guard entry.isCurrent(state) else { return }
                        let currentConfig = state.fileUploadConfig
                        guard !batch.selections.contains(where: { !currentConfig.allowsUpload(sizeBytes: $0.effectiveSizeBytes) }) else {
                            state.setToast(currentConfig.overLimitMessage)
                            return
                        }
                        onSend()
                    })
            }
        }
    }
    private var input: ChatAttachmentConfirmationInput {
        ChatAttachmentConfirmationInput(id: batch.id, totalSizeBytes: batch.totalSizeBytes,
            selections: batch.selections.map { item in
                ChatAttachmentSelectionInput(id: item.id, name: item.name, mediaCategory: item.mediaCategory,
                    mimeType: item.mimeType, effectiveSizeBytes: item.effectiveSizeBytes,
                    previewImage: item.previewImage)
            })
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

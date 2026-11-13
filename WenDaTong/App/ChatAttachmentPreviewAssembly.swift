import IM4Features
import SwiftUI
import UIKit

struct AttachmentImagePreviewSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let conversationID: String
    let localURL: URL?
    private var imageURL: URL? {
        if AttachmentGIFPresentation.isGIF(message) {
            return AttachmentGIFPresentation.originalURL(
                localURL: localURL,
                downloadURL: state.resolvedAttachmentDownloadURL(for: message),
                previewURL: state.resolvedAttachmentPreviewURL(for: message),
                downloadAllowed: message.attachmentDownloadAvailable,
                previewAllowed: message.attachmentPreviewAvailable
            )
        }
        return localURL ?? state.resolvedAttachmentBestPreviewURL(for: message)
    }
    var body: some View {
        ChatAttachmentSessionView(store: state.tenantInteractionStore,
            sessionSource: state.chatBubbleSessionIdentitySource, initialIdentity: state.chatBubbleSessionIdentity) { binding in
            state.observeChatAttachment(message) { assembledContent(binding: binding) }
        }
    }
    private func assembledContent(binding: ChatBubbleSessionBinding) -> some View {
        let origin = binding.generation
        let identity = binding.sessionIdentity
        let url = imageURL
        let input = AttachmentImagePreviewInput(title: mediaAttachmentDisplayName(message.attachmentName ?? "图片"),
            hasImage: url != nil || AttachmentGIFPresentation.isGIF(message))
        let actions = AttachmentImagePreviewActions(
            save: { if isCurrent(binding, origin, identity) { saveImage(binding, origin, identity) } },
            dismiss: {
                // WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_BEGIN
                guard isCurrent(binding, origin, identity) else { return false }
                dismiss()
                return true
                // WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_END
            })
#if DEBUG
        ChatAttachmentDetailDiagnostics.image?(AttachmentImagePreviewProbe(input: input, actions: actions, identity: identity, imageURL: url))
#endif
        return AttachmentImagePreviewContent(input: input, actions: actions) { imageContent(url: url) }
    }
    @ViewBuilder
    private func imageContent(url: URL?) -> some View {
        if AttachmentGIFPresentation.isGIF(message) {
            AttachmentGIFImage(message: message, conversationID: conversationID, localURL: localURL, maxPixelSize: 1024) {
                ProgressView().tint(.white)
            }
        } else if let imageURL = url {
            CachedRemoteImage(urlString: imageURL.absoluteString, contentMode: .fit) { ProgressView().tint(.white) }
        }
    }
    private func saveImage(_ binding: ChatBubbleSessionBinding, _ origin: UUID, _ identity: ChatBubbleSessionIdentity) {
        guard let imageURL else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片暂无可保存链接")
            return
        }
        Task {
            let entryIsCurrent = isCurrent(binding, origin, identity)
#if DEBUG
            ChatAttachmentDetailDiagnostics.taskEntry?("image-save", entryIsCurrent)
#endif
            guard entryIsCurrent else { return }
            if AttachmentGIFPresentation.isGIF(message) {
                do {
                    let original = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                    guard binding.generation == origin else { return }
                    let result = await AttachmentPhotoLibrarySaver.saveOriginalImage(at: original)
                    guard binding.generation == origin else { return }
                    switch result {
                    case .success: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片已保存到相册")
                    case .denied: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("没有相册保存权限，请在系统设置中开启")
                    case .failed, .unknownFailure: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片保存失败，请重试")
                    }
                } catch {
                    guard binding.generation == origin else { return }
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片下载失败，请重试")
                }
                return
            }
            let image: UIImage?
            if imageURL.isFileURL {
                image = UIImage(contentsOfFile: imageURL.path)
            } else {
                image = await AvatarImageCache.shared.remoteImage(for: imageURL.absoluteString)
            }
            guard binding.generation == origin else { return }
            guard let image else {
                await MainActor.run {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(imageURL.isFileURL ? "图片文件不存在，请重新下载后保存" : "图片下载失败，请重试")
                }
                return
            }
            let result = await AttachmentPhotoLibrarySaver.saveImage(image)
            await MainActor.run {
                guard binding.generation == origin else { return }
                switch result {
                case .success:
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片已保存到相册")
                case .denied:
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("没有相册保存权限，请在系统设置中开启")
                case .failed(let message):
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片保存失败：\(message)")
                case .unknownFailure:
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片保存失败，请重试")
                }
            }
        }
    }
    private func isCurrent(_ binding: ChatBubbleSessionBinding, _ origin: UUID, _ identity: ChatBubbleSessionIdentity) -> Bool {
        binding.generation == origin && state.chatBubbleSessionIdentity == identity
    }
}

struct AttachmentVideoPreviewSheet: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let localURL: URL?
    var body: some View {
        ChatAttachmentSessionView(store: state.tenantInteractionStore,
            sessionSource: state.chatBubbleSessionIdentitySource, initialIdentity: state.chatBubbleSessionIdentity) { _ in
            state.observeChatAttachment(message) {
                AttachmentVideoPreviewContent(videoURL: localURL ?? state.resolvedAttachmentBestPreviewURL(for: message))
            }
        }
    }
}

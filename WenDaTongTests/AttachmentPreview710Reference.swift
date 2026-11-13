import IM4Features
import SwiftUI
import UIKit
import AVKit
@testable import WenDaTong

struct LegacyAttachmentImagePreviewSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let conversationID: String
    let localURL: URL?
    @State private var scale: CGFloat = 1
    @State private var dismissalOffset: CGSize = .zero
    @State private var dismissalCoordinator = AttachmentImagePreviewDismissalCoordinator()
    @GestureState private var gestureScale: CGFloat = 1

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

    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.observeChatAttachment(message) { attachmentContent }
    }
    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END

    private var attachmentContent: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if imageURL != nil || AttachmentGIFPresentation.isGIF(message) {
                    Group {
                        if AttachmentGIFPresentation.isGIF(message) {
                            AttachmentGIFImage(message: message, conversationID: conversationID, localURL: localURL, maxPixelSize: 1024) {
                                ProgressView().tint(.white)
                            }
                        } else if let imageURL {
                            CachedRemoteImage(urlString: imageURL.absoluteString, contentMode: .fit) {
                                ProgressView().tint(.white)
                            }
                        }
                    }
                    .scaleEffect(effectiveScale)
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                scale = max(1, min(scale * value, 5))
                            }
                    )
                    .padding(.horizontal, 12)
                } else {
                    unavailableView("图片暂无可用预览链接")
                }
            }
            .overlay(alignment: .top) {
                legacyMediaTopControls(title: mediaAttachmentDisplayName(message.attachmentName ?? "图片")) {
                    requestDismissal(.closeButton)
                } onSave: {
                    saveImage()
                }
                .accessibilityIdentifier("attachment_image_preview_controls")
            }
            .contentShape(Rectangle())
            .offset(dismissalOffset)
            .opacity(AttachmentImagePreviewDismissalPolicy.dismissalOpacity(offset: dismissalOffset, viewportSize: proxy.size))
            .simultaneousGesture(dismissalGesture(in: proxy.size))
        }
        .background(Color.black.ignoresSafeArea())
        .accessibilityAction(.escape) {
            requestDismissal(.accessibilityEscape)
        }
        .accessibilityAction(named: Text("关闭图片预览")) {
            requestDismissal(.accessibilityEscape)
        }
    }

    private var effectiveScale: CGFloat {
        max(1, min(scale * gestureScale, 5))
    }

    private func dismissalGesture(in viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                dismissalOffset = AttachmentImagePreviewDismissalPolicy.interactiveOffset(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    viewportSize: viewportSize,
                    scale: effectiveScale
                )
            }
            .onEnded { value in
                let trigger = AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    viewportSize: viewportSize,
                    scale: effectiveScale
                )
                if let trigger {
                    requestDismissal(trigger)
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dismissalOffset = .zero
                    }
                }
            }
    }

    private func requestDismissal(_ trigger: AttachmentImagePreviewDismissalTrigger) {
        guard dismissalCoordinator.request(trigger) else { return }
        dismiss()
    }

    private func unavailableView(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 34, weight: .bold))
            Text(text)
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.86))
    }

    private func saveImage() {
        guard let imageURL else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片暂无可保存链接")
            return
        }
        Task {
            if AttachmentGIFPresentation.isGIF(message) {
                do {
                    let original = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                    let result = await AttachmentPhotoLibrarySaver.saveOriginalImage(at: original)
                    switch result {
                    case .success: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片已保存到相册")
                    case .denied: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("没有相册保存权限，请在系统设置中开启")
                    case .failed, .unknownFailure: /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("图片保存失败，请重试")
                    }
                } catch {
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
            guard let image else {
                await MainActor.run {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(imageURL.isFileURL ? "图片文件不存在，请重新下载后保存" : "图片下载失败，请重试")
                }
                return
            }
            let result = await AttachmentPhotoLibrarySaver.saveImage(image)
            await MainActor.run {
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
}

struct LegacyAttachmentVideoPreviewSheet: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let localURL: URL?

    private var videoURL: URL? {
        localURL ?? state.resolvedAttachmentBestPreviewURL(for: message)
    }

    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.observeChatAttachment(message) { attachmentContent }
    }
    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END

    private var attachmentContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let videoURL {
                LegacyAttachmentInlineVideoPlayer(url: videoURL)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash.fill")
                        .font(.system(size: 36, weight: .black))
                    Text("视频暂无可播放链接")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.86))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
    }
}

private struct LegacyAttachmentInlineVideoPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.player = AVPlayer(url: url)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            controller.player?.pause()
            controller.player = AVPlayer(url: url)
        }
        controller.showsPlaybackControls = true
        controller.player?.play()
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: url)
    }

    final class Coordinator {
        var currentURL: URL

        init(currentURL: URL) {
            self.currentURL = currentURL
        }
    }
}

@MainActor
private func legacyMediaTopControls(title: String, onClose: @escaping () -> Void, onSave: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
        legacyMediaOverlayIconButton(symbol: "xmark", label: "关闭图片预览", action: onClose)
            .accessibilityIdentifier("attachment_image_preview_close_button")
            .keyboardShortcut(.cancelAction)

        Text(title)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        legacyMediaOverlayIconButton(symbol: "square.and.arrow.down", label: "保存", action: onSave)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
    .safeAreaPaddingTopCompat(8)
    .background(
        LinearGradient(
            colors: [.black.opacity(0.74), .black.opacity(0.36), .black.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("媒体查看操作栏")
}

@MainActor
private func legacyMediaOverlayIconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(.black.opacity(0.46)))
            .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
}

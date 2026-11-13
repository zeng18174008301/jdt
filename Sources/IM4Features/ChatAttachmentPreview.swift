// WDT_IOS1_FEATURES_ATTACHMENT_APPROVED305_PHYSICAL_20261111_BEGIN
import SwiftUI
import UIKit
import AVFoundation
import AVKit
import IM4DesignSystem



public struct AttachmentImagePreviewInput {
    public init(title: String, hasImage: Bool) {
        self.title = title
        self.hasImage = hasImage
    }
    let title: String
    let hasImage: Bool
}
public struct AttachmentImagePreviewActions {
    public init(save: @escaping () -> Void, dismiss: @escaping () -> Bool) {
        self.save = save
        self.dismiss = dismiss
    }
    let save: () -> Void
    let dismiss: () -> Bool // WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110: true means App admitted the close.
}
public struct AttachmentImagePreviewContent<ImageContent: View>: View {
    public init(input: AttachmentImagePreviewInput, actions: AttachmentImagePreviewActions, @ViewBuilder imageContent: @escaping () -> ImageContent) {
        self.input = input
        self.actions = actions
        self.imageContent = imageContent
    }
    let input: AttachmentImagePreviewInput
    let actions: AttachmentImagePreviewActions
    @ViewBuilder let imageContent: () -> ImageContent
    @State private var scale: CGFloat = 1
    @State private var dismissalOffset: CGSize = .zero
    @State private var dismissalCoordinator = AttachmentImagePreviewDismissalCoordinator()
    @GestureState private var gestureScale: CGFloat = 1

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if input.hasImage {
                    imageContent()
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
                mediaTopControls(title: input.title) {
                    requestDismissal(.closeButton)
                } onSave: {
                    actions.save()
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

    // WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111_BEGIN
    private func dismissalGesture(in viewportSize: CGSize) -> some Gesture {
        let changed: (CGPoint, CGSize) -> Void = { startLocation, translation in
            dismissalOffset = AttachmentImagePreviewDismissalPolicy.interactiveOffset(
                startLocation: startLocation,
                translation: translation,
                viewportSize: viewportSize,
                scale: effectiveScale
            )
        }
        let ended: (CGPoint, CGSize, CGSize) -> Void = { startLocation, translation, predictedEndTranslation in
            let trigger = AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                startLocation: startLocation,
                translation: translation,
                predictedEndTranslation: predictedEndTranslation,
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
#if DEBUG
        // Observe the actual installed State and the same callers used below.
        AttachmentImagePreviewDragDiagnostics.capture?(AttachmentImagePreviewDragProbe(
            viewportSize: viewportSize, offset: dismissalOffset, scale: effectiveScale,
            acceptedTrigger: dismissalCoordinator.acceptedTrigger, changed: changed, ended: ended))
#endif
        return DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in changed(value.startLocation, value.translation) }
            .onEnded { value in ended(value.startLocation, value.translation, value.predictedEndTranslation) }
    }
    // WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111_END

    private func requestDismissal(_ trigger: AttachmentImagePreviewDismissalTrigger) {
        guard dismissalCoordinator.request(trigger) else { return }
        // Keep the lock before dispatch for reentrancy; only rejection releases it.
        // WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_BEGIN
        if !actions.dismiss() {
            // WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111_BEGIN
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                dismissalCoordinator.reject(trigger)
                dismissalOffset = .zero
            }
            // WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111_END
        }
        // WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_END
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

}

public struct AttachmentVideoPreviewContent: View {
    public init(videoURL: URL?) {
        self.videoURL = videoURL
    }
    let videoURL: URL?
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let videoURL {
                AttachmentInlineVideoPlayer(url: videoURL)
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

private struct AttachmentInlineVideoPlayer: UIViewControllerRepresentable {
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
private func mediaTopControls(title: String, onClose: @escaping () -> Void, onSave: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
        mediaOverlayIconButton(symbol: "xmark", label: "关闭图片预览", action: onClose)
            .accessibilityIdentifier("attachment_image_preview_close_button")
            .keyboardShortcut(.cancelAction)

        Text(title)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        mediaOverlayIconButton(symbol: "square.and.arrow.down", label: "保存", action: onSave)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
    .im4SafeAreaPaddingTopCompat(8)
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
private func mediaOverlayIconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
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

#if DEBUG
// WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111_BEGIN
// Internal passive observation only; no public API, replacement authority or State setter.
struct AttachmentImagePreviewDragProbe {
    let viewportSize: CGSize
    let offset: CGSize
    let scale: CGFloat
    let acceptedTrigger: AttachmentImagePreviewDismissalTrigger?
    let changed: (CGPoint, CGSize) -> Void
    let ended: (CGPoint, CGSize, CGSize) -> Void
}
@MainActor enum AttachmentImagePreviewDragDiagnostics {
    static var capture: ((AttachmentImagePreviewDragProbe) -> Void)?
}
// WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111_END
#endif

// WDT_IOS1_FEATURES_ATTACHMENT_APPROVED305_PHYSICAL_20261111_END

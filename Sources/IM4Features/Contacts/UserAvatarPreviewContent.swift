// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4DesignSystem

public enum UserAvatarPreviewLoadPhase {
    case loading
    case loaded(UIImage)
    case failed
}

public struct UserAvatarPreviewContent: View {
    let displayName: String
    let loadPhase: UserAvatarPreviewLoadPhase
    let onRetry: () -> Void
    let onDismiss: () -> Void
    @State private var dismissalOffset: CGSize = .zero
    @State private var dismissalCoordinator = AttachmentImagePreviewDismissalCoordinator()

    public init(displayName: String, loadPhase: UserAvatarPreviewLoadPhase,
                onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.displayName = displayName
        self.loadPhase = loadPhase
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Button {
                    requestDismissal(.closeButton)
                } label: {
                    Color.black.opacity(0.96).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("点击遮罩关闭头像预览")

                previewContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 64)
            }
            .overlay(alignment: .topTrailing) {
                IconButton(symbol: "xmark", tint: .white) {
                    requestDismissal(.closeButton)
                }
                .accessibilityLabel("关闭头像预览")
                .accessibilityIdentifier("other_user_avatar_preview_close_button")
                .im4SafeAreaPaddingTopCompat(8)
                .padding(.trailing, 16)
            }
            .contentShape(Rectangle())
            .offset(dismissalOffset)
            .opacity(
                AttachmentImagePreviewDismissalPolicy.dismissalOpacity(
                    offset: dismissalOffset,
                    viewportSize: proxy.size
                )
            )
            .simultaneousGesture(dismissalGesture(in: proxy.size))
        }
        .background(Color.black.ignoresSafeArea())
        .accessibilityAction(.escape) {
            requestDismissal(.accessibilityEscape)
        }
        .accessibilityAction(named: Text("关闭头像预览")) {
            requestDismissal(.accessibilityEscape)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch loadPhase {
        case .loading:
            ProgressView()
                .tint(.white)
                .accessibilityLabel("正在加载头像大图")
        case .loaded(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("\(displayName)的头像大图")
                .allowsHitTesting(false)
        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 36, weight: .bold))
                Text("头像加载失败")
                    .font(.system(size: 15, weight: .bold))
                Button("重试") {
                    onRetry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("other_user_avatar_preview_retry_button")
            }
            .foregroundStyle(.white.opacity(0.92))
        }
    }

    private func dismissalGesture(in viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                dismissalOffset = AttachmentImagePreviewDismissalPolicy.interactiveOffset(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    viewportSize: viewportSize,
                    scale: 1
                )
            }
            .onEnded { value in
                let trigger = AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    viewportSize: viewportSize,
                    scale: 1
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
        onDismiss()
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

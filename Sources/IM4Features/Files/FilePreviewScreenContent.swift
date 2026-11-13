// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct FilePreviewScreenContent<Hero: View, Progress: View>: View {
    let file: FileDisplayInput
    let kind: FileVisualKind
    let canPreview: Bool
    let previewState: FilePreviewOpenState
    let isPreparingShare: Bool
    let hero: () -> Hero
    let progress: () -> Progress
    let onClose: () -> Void
    let onOpen: () -> Void
    let onShare: () -> Void

    public init(file: FileDisplayInput, kind: FileVisualKind, canPreview: Bool, previewState: FilePreviewOpenState,
                isPreparingShare: Bool, @ViewBuilder hero: @escaping () -> Hero,
                @ViewBuilder progress: @escaping () -> Progress, onClose: @escaping () -> Void,
                onOpen: @escaping () -> Void, onShare: @escaping () -> Void) {
        self.file = file
        self.kind = kind
        self.canPreview = canPreview
        self.previewState = previewState
        self.isPreparingShare = isPreparingShare
        self.hero = hero
        self.progress = progress
        self.onClose = onClose
        self.onOpen = onOpen
        self.onShare = onShare
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                Color(im4Hex: 0x101828).ignoresSafeArea()
                VStack(spacing: 18) {
                    HStack {
                        Spacer()
                        Button {
                            onClose()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(.white.opacity(0.86))
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(.white.opacity(0.14)))
                                .overlay(Circle().stroke(.white.opacity(0.20), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭")
                    }
                    .padding(.horizontal, 20)

                    hero()
                        .frame(maxHeight: 420)
                        .padding(.horizontal, 18)

                    progress()

                    VStack(spacing: 12) {
                        HStack {
                            Label(file.status, systemImage: "checkmark.shield.fill")
                            Spacer()
                            Text(file.time)
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.80))

                        HStack(spacing: 12) {
                            PreviewAction(
                                symbol: kind.previewSymbol,
                                title: previewState.previewActionTitle ?? kind.previewTitle,
                                enabled: canPreview && !previewState.isLoading
                            ) {
                                onOpen()
                            }
                            PreviewAction(
                                symbol: isPreparingShare ? "arrow.down.circle.fill" : "square.and.arrow.down",
                                title: isPreparingShare ? "准备中" : "下载",
                                enabled: file.downloadAvailable && !isPreparingShare
                            ) {
                                onShare()
                            }
                            PreviewAction(symbol: "square.and.arrow.up", title: "分享/保存", enabled: file.downloadAvailable && !isPreparingShare) {
                                onShare()
                            }
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .im4ToolbarNavigationBarDarkCompat()
        }
    }
}

private struct PreviewAction: View {
    let symbol: String
    let title: String
    var danger = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            PreviewActionLabel(symbol: symbol, title: title, danger: danger, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct PreviewActionLabel: View {
    let symbol: String
    let title: String
    var danger = false
    var enabled = true

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(danger ? IMColor.danger : .white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill((danger ? IMColor.danger : IMColor.brand).opacity(enabled ? (danger ? 0.12 : 0.9) : 0.22))
                )
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.84 : 0.42))
        }
        .frame(maxWidth: .infinity)
    }
}

public struct FilePreviewHeroContent<Thumbnail: View>: View {
    let file: FileDisplayInput
    let isPreparingPreview: Bool

    let kind: FileVisualKind
    let thumbnailURL: URL?
    let thumbnail: (URL, FilePreviewIcon) -> Thumbnail

    public init(file: FileDisplayInput, kind: FileVisualKind, thumbnailURL: URL?, isPreparingPreview: Bool,
                @ViewBuilder thumbnail: @escaping (URL, FilePreviewIcon) -> Thumbnail) {
        self.file = file
        self.kind = kind
        self.thumbnailURL = thumbnailURL
        self.isPreparingPreview = isPreparingPreview
        self.thumbnail = thumbnail
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.white)
            .overlay {
                VStack(spacing: 16) {
                    previewArtwork
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                    Text(file.name)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text("\(file.type) · \(file.size)\n\(file.scope)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
    }

    @ViewBuilder
    private var previewArtwork: some View {
        if let thumbnailURL {
            ZStack {
                thumbnail(thumbnailURL, iconPreview)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                if kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
                }
            }
        } else {
            iconPreview
        }
        if isPreparingPreview {
            ProgressView("正在准备系统预览")
                .font(.system(size: 12, weight: .bold))
                .tint(IMColor.brand)
                .padding(.top, 4)
        }
    }

    private var iconPreview: FilePreviewIcon { FilePreviewIcon(accentHex: file.accentHex, kind: kind) }
}

public struct FilePreviewIcon: View {
    let accentHex: UInt
    let kind: FileVisualKind

    public var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(im4Hex: accentHex).opacity(0.12))
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(Color(im4Hex: accentHex))
                    Text(kind.title)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(im4Hex: accentHex))
                }
            )
            .frame(width: 168, height: 168)
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END

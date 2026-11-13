// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct FavoriteAssetRowContent<Progress: View, Thumbnail: View>: View {
    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110
    let downloadProgress: Progress
    let file: FileDisplayInput
    let isUnavailable: Bool
    let thumbnail: () -> Thumbnail
    let isPreparingDownload: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void
    let onUnfavorite: () -> Void

    public init(downloadProgress: Progress, file: FileDisplayInput, isUnavailable: Bool, isPreparingDownload: Bool,
                @ViewBuilder thumbnail: @escaping () -> Thumbnail, onOpen: @escaping () -> Void,
                onDownload: @escaping () -> Void, onShare: @escaping () -> Void, onUnfavorite: @escaping () -> Void) {
        self.downloadProgress = downloadProgress; self.file = file; self.isUnavailable = isUnavailable
        self.isPreparingDownload = isPreparingDownload; self.thumbnail = thumbnail
        self.onOpen = onOpen; self.onDownload = onDownload; self.onShare = onShare; self.onUnfavorite = onUnfavorite
    }
    public var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                FileRow(
                    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110
                    downloadProgress: downloadProgress,
                    file: file, thumbnail: thumbnail,
                    isPreparingDownload: isPreparingDownload,
                    actionsEnabled: !isUnavailable,
                    onOpen: onOpen,
                    onDownload: onDownload,
                    onShare: onShare
                )
                if isUnavailable {
                    Label("内容已失效/不可预览", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 2)
                }
            }
            Button {
                onUnfavorite()
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(im4Hex: 0xFFB246))
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.94))
                            .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消收藏")
            .padding(.trailing, 10)
        }
    }
}

private struct FileRow<Progress: View, Thumbnail: View>: View {
    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110
    let downloadProgress: Progress
    let file: FileDisplayInput
    let thumbnail: () -> Thumbnail
    let isPreparingDownload: Bool
    var actionsEnabled = true
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void

    private var downloadActionsEnabled: Bool {
        actionsEnabled && file.downloadAvailable && !isPreparingDownload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 13) {
                    thumbnail()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.name)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        Text("\(file.type) · \(file.size) · \(file.owner)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                        Text("\(file.source) · \(file.time)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(IMColor.muted)
                    }
                    .padding(.trailing, 38)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                FileRowInlineActionButton(
                    title: isPreparingDownload ? "准备中" : "下载",
                    symbol: isPreparingDownload ? "hourglass" : "arrow.down.circle.fill",
                    enabled: downloadActionsEnabled,
                    action: onDownload
                )
                FileRowInlineActionButton(
                    title: "分享/保存",
                    symbol: "square.and.arrow.up.fill",
                    enabled: downloadActionsEnabled,
                    action: onShare
                )
                Spacer(minLength: 0)
            }
            .padding(.trailing, 38)
            // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110
            downloadProgress
        }
        .im4PlainCard(radius: 22)
    }
}

private struct FileRowInlineActionButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(enabled ? IMColor.brand : IMColor.muted.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(enabled ? IMColor.brand.opacity(0.10) : IMColor.line.opacity(0.38))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END

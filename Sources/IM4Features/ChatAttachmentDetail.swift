// WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110_BEGIN
import Combine // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110
import SwiftUI
import UIKit
import QuickLook
import IM4Domain
import IM4DesignSystem

// WDT_APP_CONTRACT_20261021_10: shared byte/indeterminate progress, including the final commit phase.
public struct AttachmentDownloadProgressView: View {
    // WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113_BEGIN
    public init(snapshot: AttachmentDownloadSnapshot, compact: Bool = false, onCancel: @escaping () -> Void) {
        self.snapshot = snapshot
        self.compact = compact
        self.onCancel = onCancel
    }
    let snapshot: AttachmentDownloadSnapshot
    private let compact: Bool
    let onCancel: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if compact {
                    ProgressView(value: snapshot.fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: snapshot.fraction)
                }
            }
            .tint(IMColor.brand)
            HStack(spacing: 8) {
                Text(snapshot.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(compact ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("取消", action: onCancel)
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
            }
        }
    }
    // WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113_END
}

public struct AttachmentDetailInput {
    public init(messageID: String, fileName: String, metadata: String, mediaCategory: String, mediaSymbol: String, detailTitle: String, previewTitle: String, previewSymbol: String, previewAvailable: Bool, downloadAvailable: Bool, isPreparingPreview: Bool, isPreparingShare: Bool, isUploading: Bool, progress: Double?, download: AttachmentDownloadSnapshot?, uploadFailure: String?, canRetryUpload: Bool, canCancelUpload: Bool, hasForward: Bool, forwardDisabledReason: String?) {
        self.messageID = messageID
        self.fileName = fileName
        self.metadata = metadata
        self.mediaCategory = mediaCategory
        self.mediaSymbol = mediaSymbol
        self.detailTitle = detailTitle
        self.previewTitle = previewTitle
        self.previewSymbol = previewSymbol
        self.previewAvailable = previewAvailable
        self.downloadAvailable = downloadAvailable
        self.isPreparingPreview = isPreparingPreview
        self.isPreparingShare = isPreparingShare
        self.isUploading = isUploading
        self.progress = progress
        self.download = download
        self.uploadFailure = uploadFailure
        self.canRetryUpload = canRetryUpload
        self.canCancelUpload = canCancelUpload
        self.hasForward = hasForward
        self.forwardDisabledReason = forwardDisabledReason
    }
    let messageID: String
    let fileName: String
    let metadata: String
    let mediaCategory: String
    let mediaSymbol: String
    let detailTitle: String
    let previewTitle: String
    let previewSymbol: String
    let previewAvailable: Bool
    let downloadAvailable: Bool
    let isPreparingPreview: Bool
    let isPreparingShare: Bool
    let isUploading: Bool
    let progress: Double?
    let download: AttachmentDownloadSnapshot?
    let uploadFailure: String?
    let canRetryUpload: Bool
    let canCancelUpload: Bool
    let hasForward: Bool
    let forwardDisabledReason: String?
}

public struct AttachmentDetailActions {
    public init(openPreview: @escaping () -> Void, share: @escaping () -> Void, forward: @escaping () -> Void, retryUpload: @escaping () -> Void, cancelUpload: @escaping () -> Void, cancelDownload: @escaping () -> Void) {
        self.openPreview = openPreview
        self.share = share
        self.forward = forward
        self.retryUpload = retryUpload
        self.cancelUpload = cancelUpload
        self.cancelDownload = cancelDownload
    }
    let openPreview: () -> Void
    let share: () -> Void
    let forward: () -> Void
    let retryUpload: () -> Void
    let cancelUpload: () -> Void
    let cancelDownload: () -> Void
}

public struct AttachmentDetailContent<Thumbnail: View>: View {
    public init(input: AttachmentDetailInput, actions: AttachmentDetailActions, @ViewBuilder thumbnail: @escaping () -> Thumbnail) {
        self.input = input
        self.actions = actions
        self.thumbnail = thumbnail
    }
    let input: AttachmentDetailInput
    let actions: AttachmentDetailActions
    @ViewBuilder let thumbnail: () -> Thumbnail

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(
                            symbol: input.mediaSymbol,
                            title: input.detailTitle,
                            subtitle: "使用后端返回的预览 / 下载链接，不在客户端拼接存储地址。",
                            showsCloseButton: true
                        )

                        fileSummary
                        if let snapshot = input.download, !input.isUploading {
                            AttachmentDownloadProgressView(snapshot: snapshot) { actions.cancelDownload() }
                                .im4PlainCard(radius: 22)
                        } else if let progress = input.progress {
                            progressCard(progress)
                        }
                        if let failureMessage = input.uploadFailure {
                            Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(IMColor.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(IMColor.danger.opacity(0.08))
                                )
                        }
                        actionGrid // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var fileSummary: some View {
        HStack(spacing: 14) {
            ZStack {
                if input.mediaCategory == "image" || input.mediaCategory == "video" {
                    thumbnail()

                    if input.mediaCategory == "video" {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.black.opacity(0.42)))
                    }
                } else {
                    summaryIcon
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(["image", "video"].contains(input.mediaCategory) ? chatMediaAttachmentDisplayName(input.fileName) : input.fileName)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(2)
                Text(input.metadata)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .im4PlainCard(radius: 24)
    }

    private var summaryIcon: some View {
        Image(systemName: input.mediaSymbol)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(IMColor.brand)
            .frame(width: 58, height: 58)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand.opacity(0.12)))
    }

    private func progressCard(_ progress: Double) -> some View {
        // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_DETAIL_REAL_PROGRESS_TEXT - 修改开始：详情页只展示真实传输百分比，不再称为阶段进度
        let boundedProgress = max(0, min(progress, 1))
        let percentText = "\(Int(boundedProgress * 100))%"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(input.isUploading ? "上传中" : "下载中")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                Text(percentText)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted)
            }
            ProgressView(value: boundedProgress)
                .tint(IMColor.brand)
        }
        .im4PlainCard(radius: 22)
        // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_DETAIL_REAL_PROGRESS_TEXT - 修改结束
    }

    private var actionGrid: some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            attachmentActionTile(input.previewTitle, symbol: input.previewSymbol, enabled: input.previewAvailable && !input.isPreparingPreview) {
                actions.openPreview()
            }
            attachmentActionTile("分享", symbol: "square.and.arrow.up.fill", enabled: input.downloadAvailable && !input.isPreparingShare) {
                actions.share()
            }
            if input.hasForward {
                if let batchForwardDisabledReason = input.forwardDisabledReason { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                    attachmentActionTile(
                        "转发",
                        symbol: "arrowshape.turn.up.right.fill",
                        enabled: false,
                        accessibilityLabel: batchForwardDisabledReason
                    ) {}
                } else {
                    attachmentActionTile("转发", symbol: "arrowshape.turn.up.right.fill", enabled: true) {
                        actions.forward()
                    }
                }
            }
            if input.canRetryUpload {
                attachmentActionTile("重试上传", symbol: "arrow.clockwise.circle.fill", enabled: true) {
                    actions.retryUpload()
                }
            }
            if input.canCancelUpload {
                attachmentActionTile("取消发送", symbol: "xmark.circle.fill", tint: IMColor.danger, enabled: true) {
                    actions.cancelUpload()
                }
            }
        }
    }
}



public struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    public init(url: URL) {
        self.url = url
    }
    let url: URL

    public func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    public final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

@MainActor
private func attachmentActionButton(_ title: String, symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Capsule().fill(.white.opacity(0.16)))
    }
    .buttonStyle(.plain)
}

@MainActor
private func attachmentActionTile(
    _ title: String,
    symbol: String,
    tint: Color = IMColor.brand,
    enabled: Bool,
    accessibilityLabel: String? = nil,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(enabled ? tint : IMColor.muted)
                .frame(width: 44, height: 44)
                .background(Circle().fill((enabled ? tint : IMColor.muted).opacity(0.12)))
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(enabled ? IMColor.ink : IMColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.76)))
    }
    .disabled(!enabled)
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel ?? title)
    .accessibilityValue(enabled ? "" : "不可用")
}

public struct AttachmentDetailSummaryIcon: View {
    public init(symbol: String) {
        self.symbol = symbol
    }
    let symbol: String
    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(IMColor.brand)
            .frame(width: 58, height: 58)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand.opacity(0.12)))
    }
}

func chatMediaAttachmentDisplayName(_ fileName: String) -> String {
    let name = fileName as NSString
    return name.pathExtension.isEmpty ? fileName : name.deletingPathExtension
}

// WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110_END

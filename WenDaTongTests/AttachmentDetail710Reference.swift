import SwiftUI
import UIKit
@testable import WenDaTong

struct LegacyAttachmentDetailSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let conversationID: String
    var onForward: ((ChatMessage) -> Void)? = nil
    @State private var previewDocument: AttachmentLocalPreviewDocument?
    @State private var previewVideoAttachment: AttachmentMediaPreviewItem?
    @State private var shareItem: AttachmentShareItem?
    @State private var isPreparingPreview = false
    @State private var isPreparingShare = false

    private var progress: Double? {
        state.attachmentTransferProgress(for: message)
    }

    private var fileName: String {
        message.attachmentName ?? message.text
    }

    private var sizeText: String {
        if let size = message.attachmentSizeBytes, size > 0 {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return "大小待同步"
    }

    private var mediaCategory: String {
        state.attachmentMediaCategory(for: message)
    }

    private var mediaSymbol: String {
        switch mediaCategory {
        case "image": return "photo.fill.on.rectangle.fill"
        case "video": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        case "audio": return "waveform"
        case "archive": return "archivebox.fill"
        default: return "doc.fill"
        }
    }

    private var detailTitle: String {
        switch mediaCategory {
        case "image": return "图片详情"
        case "video": return "视频详情"
        case "pdf": return "PDF 详情"
        default: return "文件详情"
        }
    }

    private var previewTitle: String {
        switch mediaCategory {
        case "image": return "查看原图"
        case "video": return "播放视频"
        case "pdf": return "阅读 PDF"
        default: return "系统预览"
        }
    }

    private var previewSymbol: String {
        switch mediaCategory {
        case "image": return "photo.fill"
        case "video": return "play.circle.fill"
        case "pdf": return "doc.text.magnifyingglass"
        default: return "eye.fill"
        }
    }

    private var previewURL: URL? {
        state.resolvedAttachmentBestPreviewURL(for: message)
    }

    private var previewAvailable: Bool {
        if state.attachmentCanRefreshRemoteFile(message) {
            return true
        }
        if mediaCategory == "video" {
            return previewURL != nil || state.resolvedAttachmentDownloadURL(for: message) != nil
        }
        return previewURL != nil
    }

    private var downloadAvailable: Bool {
        state.resolvedAttachmentDownloadURL(for: message) != nil || state.attachmentCanRefreshRemoteFile(message)
    }

    private var canRetryUpload: Bool {
        state.canRetryAttachmentUpload(message)
    }

    private var canCancelUpload: Bool {
        state.isAttachmentUploadInProgress(message) || canRetryUpload
    }

    private func batchForwardDisabledReason(policy: MessageActionsPolicy) -> String? { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        switch state.batchForwardEligibility(
            for: message,
            in: conversationID,
            policy: policy
        ) {
        case .selectable:
            return nil
        case .disabled(let reason):
            return reason
        }
    }

    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
    var body: some View {
        // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
        state.observeChatAttachment(message) {
            state.tenantInteractionStore.observe(\.currentActions) { policy in
                attachmentContent(policy: policy)
            }
        }
        // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END
    }
    // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END

    private func attachmentContent(policy: MessageActionsPolicy) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(
                            symbol: mediaSymbol,
                            title: detailTitle,
                            subtitle: "使用后端返回的预览 / 下载链接，不在客户端拼接存储地址。",
                            showsCloseButton: true
                        )

                        fileSummary
                        if let snapshot = state.attachmentDownloadSnapshot(for: message), !state.isAttachmentUploadInProgress(message) {
                            AttachmentDownloadProgressView(snapshot: snapshot) { state.cancelAttachmentDownload(message) }
                                .plainCard(radius: 22)
                        } else if let progress {
                            progressCard(progress)
                        }
                        if let failureMessage = state.attachmentUploadFailureMessage(for: message) {
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
                        actionGrid(policy: policy) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicatorCompat(.visible)
        .sheet(item: $previewDocument) { document in
            AttachmentQuickLookPreview(url: document.url)
        }
        .fullScreenCover(item: $previewVideoAttachment) { item in
            AttachmentVideoPreviewSheet(message: item.message, localURL: item.localURL)
        }
        .sheet(item: $shareItem) { item in
            AttachmentActivityView(activityItems: [item.url]) { completed, error in
                if let error {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("保存/分享失败：\(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重试"))")
                } else if completed {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("保存/分享已完成")
                }
            }
                .presentationDetentsCompat([.medium, .large])
        }
    }

    private var fileSummary: some View {
        HStack(spacing: 14) {
            ZStack {
                if mediaCategory == "image" || mediaCategory == "video" {
                    // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
                    state.fileStore.observeMediaNetworkRecovery { generation in
                        AttachmentThumbnailImage(
                            // WDT_CHAT_FIX3_VIDEO_COVER_20261023
                            url: state.resolvedAttachmentThumbnailURL(for: message) ?? (mediaCategory == "video" ? nil : previewURL),
                            cacheKey: state.attachmentThumbnailCacheKey(for: message),
                            contentMode: .fill,
                            scopeGeneration: state.mediaCacheScopeContext?.sessionGeneration ?? 0,
                            networkRecoveryGeneration: generation,
                            recoveryURL: {
                                await state.refreshedAttachmentThumbnailURL(message, conversationID: conversationID)
                            },
                            indexedCacheURL: {
                                await state.cachedUnifiedAttachmentThumbnailURL(for: message)
                            },
                            indexedCacheCommit: { data in
                                await state.cacheUnifiedAttachmentThumbnail(
                                    data,
                                    for: message,
                                    conversationID: conversationID
                                )
                            }
                        ) {
                            summaryIcon
                        } failure: {
                            summaryIcon
                        }
                    }
                    // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END
                    if mediaCategory == "video" {
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
                Text(["image", "video"].contains(mediaCategory) ? mediaAttachmentDisplayName(fileName) : fileName)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(2)
                Text([message.attachmentMeta, sizeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .plainCard(radius: 24)
    }

    private var summaryIcon: some View {
        Image(systemName: mediaSymbol)
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
                Text(state.isAttachmentUploadInProgress(message) ? "上传中" : "下载中")
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
        .plainCard(radius: 22)
        // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_DETAIL_REAL_PROGRESS_TEXT - 修改结束
    }

    private func actionGrid(policy: MessageActionsPolicy) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            attachmentActionTile(previewTitle, symbol: previewSymbol, enabled: previewAvailable && !isPreparingPreview) {
                openPreview()
            }
            attachmentActionTile("分享", symbol: "square.and.arrow.up.fill", enabled: downloadAvailable && !isPreparingShare) {
                prepareShare()
            }
            if let onForward {
                if let batchForwardDisabledReason = batchForwardDisabledReason(policy: policy) { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                    attachmentActionTile(
                        "转发",
                        symbol: "arrowshape.turn.up.right.fill",
                        enabled: false,
                        accessibilityLabel: batchForwardDisabledReason
                    ) {}
                } else {
                    attachmentActionTile("转发", symbol: "arrowshape.turn.up.right.fill", enabled: true) {
                        onForward(message)
                    }
                }
            }
            if canRetryUpload {
                attachmentActionTile("重试上传", symbol: "arrow.clockwise.circle.fill", enabled: true) {
                    state.retryAttachmentUpload(messageID: message.id, in: conversationID)
                }
            }
            if canCancelUpload {
                attachmentActionTile("取消发送", symbol: "xmark.circle.fill", tint: IMColor.danger, enabled: true) {
                    state.cancelAttachmentUpload(messageID: message.id, in: conversationID)
                    dismiss()
                }
            }
        }
    }

    private func openPreview() {
        if mediaCategory == "image" {
            state.openMessageAttachment(message, conversationID: conversationID, preferPreview: true)
            return
        }
        if mediaCategory == "video" {
            isPreparingPreview = true
            Task {
                guard await state.authorizeProtectedAccess(.filePreview) else {
                    await MainActor.run {
                        isPreparingPreview = false
                    }
                    return
                }
                do {
                    let localURL = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: true)
                    await MainActor.run {
                        isPreparingPreview = false
                        previewVideoAttachment = AttachmentMediaPreviewItem(message: message, localURL: localURL)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        isPreparingPreview = false
                    }
                } catch {
                    await MainActor.run {
                        isPreparingPreview = false
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("视频下载失败，无法播放，请重试")
                    }
                }
            }
            return
        }
        guard let previewURL else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("当前附件暂无可预览链接")
            return
        }
        isPreparingPreview = true
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else {
                await MainActor.run {
                    isPreparingPreview = false
                }
                return
            }
            do {
                let localURL = try await LegacyAttachmentSystemPreviewLoader.download(
                    previewURL,
                    suggestedName: fileName,
                    cacheIdentity: state.attachmentSystemPreviewCacheIdentity(for: message)
                )
                await MainActor.run {
                    isPreparingPreview = false
                    previewDocument = AttachmentLocalPreviewDocument(url: localURL)
                }
            } catch {
                await MainActor.run {
                    isPreparingPreview = false
                    state.openMessageAttachment(message, conversationID: conversationID, preferPreview: true)
                }
            }
        }
    }

    private func prepareShare() {
        isPreparingShare = true
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else {
                await MainActor.run {
                    isPreparingShare = false
                }
                return
            }
            do {
                let localURL = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                await MainActor.run {
                    isPreparingShare = false
                    shareItem = AttachmentShareItem(url: localURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    isPreparingShare = false
                }
            } catch {
                await MainActor.run {
                    isPreparingShare = false
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("下载失败，请重试")
                }
            }
        }
    }
}

private enum LegacyAttachmentSystemPreviewLoader {
    static func download(_ remoteURL: URL, suggestedName: String, cacheIdentity: String? = nil) async throws -> URL {
        try await SystemPreviewLoader.download(remoteURL, suggestedName: suggestedName, cacheIdentity: cacheIdentity)
    }
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

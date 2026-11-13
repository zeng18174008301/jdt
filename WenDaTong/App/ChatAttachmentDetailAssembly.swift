// WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_BEGIN
import IM4Domain
// WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_END
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_BEGIN
struct AttachmentDetailSheet: View {
    @Environment(\.attachmentDetailSource) private var sourceFactory
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let conversationID: String
    var onForward: ((ChatMessage) -> Void)? = nil
    @State private var previewDocument: AttachmentLocalPreviewDocument?
    @State private var previewVideoAttachment: AttachmentMediaPreviewItem?
    @State private var shareItem: AttachmentShareItem?
    @State private var isPreparingPreview = false
    @State private var isPreparingShare = false

    private var fileName: String {
        message.attachmentName ?? message.text
    }

    private var sizeText: String {
        if let size = message.attachmentSizeBytes, size > 0 {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return "大小待同步"
    }

    private func mediaSymbol(for mediaCategory: String) -> String {
        switch mediaCategory {
        case "image": return "photo.fill.on.rectangle.fill"
        case "video": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        case "audio": return "waveform"
        case "archive": return "archivebox.fill"
        default: return "doc.fill"
        }
    }

    private func detailTitle(for mediaCategory: String) -> String {
        switch mediaCategory {
        case "image": return "图片详情"
        case "video": return "视频详情"
        case "pdf": return "PDF 详情"
        default: return "文件详情"
        }
    }

    private func previewTitle(for mediaCategory: String) -> String {
        switch mediaCategory {
        case "image": return "查看原图"
        case "video": return "播放视频"
        case "pdf": return "阅读 PDF"
        default: return "系统预览"
        }
    }

    private func previewSymbol(for mediaCategory: String) -> String {
        switch mediaCategory {
        case "image": return "photo.fill"
        case "video": return "play.circle.fill"
        case "pdf": return "doc.text.magnifyingglass"
        default: return "eye.fill"
        }
    }

    var body: some View {
        guard let sourceFactory else { preconditionFailure("App must inject attachment detail actions") }
        let source = sourceFactory(message, conversationID)
        return ChatAttachmentSessionView(store: source.tenant,
            sessionSource: source.sessions, initialIdentity: source.currentIdentity()) { binding in
            source.files.observeChatAttachment(identity: source.transferIdentity()) {
                source.tenant.observe(\.currentActions) { policy in
                    assembledContent(source, binding: binding, policy: policy)
                }
            }
        }
    }

    private func assembledContent(_ source: AttachmentDetailSource, binding: ChatBubbleSessionBinding, policy: MessageActionsPolicy) -> some View {
        let origin = binding.generation
        let identity = binding.sessionIdentity
        let preview = source.preview()
        let transfer = source.transfer()
        let mediaSymbol = mediaSymbol(for: preview.category)
        let input = AttachmentDetailInput(messageID: message.id, fileName: fileName,
            metadata: [message.attachmentMeta, sizeText].compactMap { $0 }.joined(separator: " · "),
            mediaCategory: preview.category, mediaSymbol: mediaSymbol, detailTitle: detailTitle(for: preview.category),
            previewTitle: previewTitle(for: preview.category), previewSymbol: previewSymbol(for: preview.category),
            previewAvailable: preview.isAvailable, downloadAvailable: preview.canDownload,
            isPreparingPreview: isPreparingPreview, isPreparingShare: isPreparingShare,
            isUploading: transfer.isUploading, progress: transfer.progress, download: transfer.download,
            uploadFailure: transfer.uploadFailure, canRetryUpload: transfer.canRetry,
            canCancelUpload: transfer.isUploading || transfer.canRetry, hasForward: onForward != nil,
            forwardDisabledReason: onForward == nil ? nil : source.forwardDisabledReason(policy))
        let actions = AttachmentDetailActions(
            openPreview: { if isCurrent(source, binding, origin, identity) { openPreview(source, binding, origin, identity) } },
            share: { if isCurrent(source, binding, origin, identity) { prepareShare(source, binding, origin, identity) } },
            forward: { if isCurrent(source, binding, origin, identity) { onForward?(message) } },
            retryUpload: { if isCurrent(source, binding, origin, identity) { source.retryUpload() } },
            cancelUpload: { if isCurrent(source, binding, origin, identity) { source.cancelUpload(); dismiss() } },
            cancelDownload: { if isCurrent(source, binding, origin, identity) { source.cancelDownload() } })
#if DEBUG
        ChatAttachmentDetailDiagnostics.detail?(AttachmentDetailProbe(input: input, actions: actions, identity: identity, preparedShareURL: shareItem?.url, bindingGeneration: origin))
#endif
        return AttachmentDetailContent(input: input, actions: actions) { summaryThumbnail(source, binding, origin, symbol: mediaSymbol) }
        .presentationDragIndicatorCompat(.visible)
        .sheet(item: $previewDocument) { document in
            AttachmentQuickLookPreview(url: document.url)
        }
        .fullScreenCover(item: $previewVideoAttachment) { item in
            AttachmentVideoPreviewSheet(message: item.message, localURL: item.localURL)
        }
        .sheet(item: $shareItem) { item in
            AttachmentActivityView(activityItems: [item.url]) { completed, error in
                guard binding.generation == origin else { return }
                if let error {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ source.toast("保存/分享失败：\(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重试"))")
                } else if completed {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ source.toast("保存/分享已完成")
                }
            }
                .presentationDetentsCompat([.medium, .large])
        }
    }

    private func summaryThumbnail(_ source: AttachmentDetailSource, _ binding: ChatBubbleSessionBinding,
                                  _ origin: UUID, symbol: String) -> some View {
        source.files.observeMediaNetworkRecovery { generation in
            let thumbnail = source.thumbnail()
            AttachmentThumbnailImage(
                url: thumbnail.url, cacheKey: thumbnail.cacheKey, contentMode: .fill,
                scopeGeneration: thumbnail.scopeGeneration, networkRecoveryGeneration: generation,
                recoveryURL: {
                    guard binding.generation == origin else { return nil }
                    let url = await source.recoverThumbnail()
                    return binding.generation == origin ? url : nil
                },
                indexedCacheURL: {
                    guard binding.generation == origin else { return nil }
                    let url = await source.cachedThumbnail()
                    return binding.generation == origin ? url : nil
                },
                indexedCacheCommit: { data in
                    guard binding.generation == origin else { return nil }
                    let url = await source.cacheThumbnail(data)
                    return binding.generation == origin ? url : nil
                }
            ) {
                AttachmentDetailSummaryIcon(symbol: symbol)
            } failure: {
                AttachmentDetailSummaryIcon(symbol: symbol)
            }
        }
    }

    private func openPreview(_ source: AttachmentDetailSource, _ binding: ChatBubbleSessionBinding, _ origin: UUID, _ identity: ChatBubbleSessionIdentity) {
        let preview = source.preview()
        if preview.category == "image" {
            source.openPreview()
            return
        }
        if preview.category == "video" {
            isPreparingPreview = true
            Task {
                let entryIsCurrent = isCurrent(source, binding, origin, identity)
#if DEBUG
                ChatAttachmentDetailDiagnostics.taskEntry?("detail-video-preview", entryIsCurrent)
#endif
                guard entryIsCurrent else { isPreparingPreview = false; return }
                guard await source.authorizePreview() else {
                    await MainActor.run {
                        isPreparingPreview = false
                    }
                    return
                }
                guard binding.generation == origin else { isPreparingPreview = false; return }
                do {
                    let localURL = try await source.prepareLocalFile(true)
                    await MainActor.run {
                        isPreparingPreview = false
                        guard binding.generation == origin else { return }
                        previewVideoAttachment = AttachmentMediaPreviewItem(message: message, localURL: localURL)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        isPreparingPreview = false
                    }
                } catch {
                    await MainActor.run {
                        isPreparingPreview = false
                        guard binding.generation == origin else { return }
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ source.toast("视频下载失败，无法播放，请重试")
                    }
                }
            }
            return
        }
        guard let previewURL = preview.url else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ source.toast("当前附件暂无可预览链接")
            return
        }
        isPreparingPreview = true
        Task {
                let entryIsCurrent = isCurrent(source, binding, origin, identity)
#if DEBUG
                ChatAttachmentDetailDiagnostics.taskEntry?("detail-system-preview", entryIsCurrent)
#endif
                guard entryIsCurrent else { isPreparingPreview = false; return }
            guard await source.authorizePreview() else {
                await MainActor.run {
                    isPreparingPreview = false
                }
                return
            }
            guard binding.generation == origin else { isPreparingPreview = false; return }
            do {
                let localURL = try await source.downloadDocument(previewURL, fileName)
                await MainActor.run {
                    isPreparingPreview = false
                    guard binding.generation == origin else { return }
                        previewDocument = AttachmentLocalPreviewDocument(url: localURL)
                }
            } catch {
                await MainActor.run {
                    isPreparingPreview = false
                    guard binding.generation == origin else { return }
                    source.openPreview()
                }
            }
        }
    }

    private func prepareShare(_ source: AttachmentDetailSource, _ binding: ChatBubbleSessionBinding, _ origin: UUID, _ identity: ChatBubbleSessionIdentity) {
        isPreparingShare = true
        Task {
            let entryIsCurrent = isCurrent(source, binding, origin, identity)
#if DEBUG
            ChatAttachmentDetailDiagnostics.taskEntry?("detail-share", entryIsCurrent)
#endif
            guard entryIsCurrent else { isPreparingShare = false; return }
            guard await source.authorizePreview() else {
                await MainActor.run {
                    isPreparingShare = false
                }
                return
            }
            guard binding.generation == origin else { isPreparingShare = false; return }
            do {
                let localURL = try await source.prepareLocalFile(false)
                await MainActor.run {
                    isPreparingShare = false
                    guard binding.generation == origin else { return }
                        shareItem = AttachmentShareItem(url: localURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    isPreparingShare = false
                }
            } catch {
                await MainActor.run {
                    isPreparingShare = false
                    guard binding.generation == origin else { return }
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ source.toast("下载失败，请重试")
                }
            }
        }
    }

    private func isCurrent(_ source: AttachmentDetailSource, _ binding: ChatBubbleSessionBinding, _ origin: UUID, _ identity: ChatBubbleSessionIdentity) -> Bool {
        binding.generation == origin && source.currentIdentity() == identity
    }
}
// WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_END

#if DEBUG
struct AttachmentDetailProbe {
    let input: AttachmentDetailInput
    let actions: AttachmentDetailActions
    let identity: ChatBubbleSessionIdentity
    let preparedShareURL: URL?
    let bindingGeneration: UUID
}
struct AttachmentImagePreviewProbe {
    let input: AttachmentImagePreviewInput
    let actions: AttachmentImagePreviewActions
    let identity: ChatBubbleSessionIdentity
    let imageURL: URL?
}
@MainActor enum ChatAttachmentDetailDiagnostics {
    static var taskEntry: ((String, Bool) -> Void)?
    static var detail: ((AttachmentDetailProbe) -> Void)?
    static var image: ((AttachmentImagePreviewProbe) -> Void)?
}
#endif

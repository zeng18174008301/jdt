import IM4Features
// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_BEGIN
// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN
import SwiftUI
import UIKit

struct FileBubbleContent: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let outgoing: Bool
    var conversationID = ""

    var body: some View {
        ChatAttachmentSessionView(store: state.tenantInteractionStore,
            sessionSource: state.chatBubbleSessionIdentitySource, initialIdentity: state.chatBubbleSessionIdentity) { binding in
            state.observeChatAttachment(message) { assembledContent(binding: binding) }
        }
    }

    private func assembledContent(binding: ChatBubbleSessionBinding) -> some View {
        let origin = binding.generation
        let mediaCategory = state.attachmentMediaCategory(for: message)
        let layout = FileMessageLayout(message: message, mediaCategory: mediaCategory)
        let upload = state.isAttachmentUploadInProgress(message)
        let presentation = FileMessagePresentation(
            mediaCategory: mediaCategory,
            progress: mediaCategory != "video" || upload ? state.attachmentTransferProgress(for: message) : nil,
            isUploadTransfer: upload,
            attachmentDownloaded: layout.isMediaMessage ? false : state.isMessageAttachmentDownloaded(message, preferPreview: false),
            download: state.attachmentDownloadSnapshot(for: message), // WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113
            canRetryUpload: message.status == .failed ? state.canRetryAttachmentUpload(message) : false,
            downloadFailed: state.attachmentDownloadFailed(message)
        )
        let boundCancelDownload: () -> Void = { binding.performIfCurrent(origin) { state.cancelAttachmentDownload(message) } }
        let boundCancelTransfer: () -> Void = {
                binding.performIfCurrent(origin) {
                    if state.isAttachmentUploadInProgress(message) || state.canRetryAttachmentUpload(message) {
                        state.cancelAttachmentUpload(messageID: message.id, in: conversationID)
                    } else { state.cancelAttachmentDownload(message) }
                }
            }
        let boundCancelUpload: () -> Void = { binding.performIfCurrent(origin) { state.cancelAttachmentUpload(messageID: message.id, in: conversationID) } }
        let content = FileMessageContent(message: message, outgoing: outgoing, presentation: presentation,
            onCancelDownload: boundCancelDownload,
            onCancelTransfer: boundCancelTransfer,
            onCancelUpload: boundCancelUpload,
            gifContent: {
                AttachmentGIFImage(message: message, conversationID: conversationID) {
                    FileAttachmentPlaceholder(symbol: layout.mediaSymbol, title: "GIF", status: "点按查看原图", usesOutgoingFill: outgoing && !layout.isBorderlessGIF)
                }
            },
            posterContent: { ServerVideoPosterThumbnail(message: message, conversationID: conversationID) },
            originalContent: { AttachmentOriginalThumbnail(message: message, conversationID: conversationID) },
            fallbackContent: { fallbackThumbnail(layout: layout, binding: binding, origin: origin) }
        )
#if DEBUG
        ChatAttachmentAssemblyDiagnostics.file?(ChatFileAttachmentProbe(messageID: message.id, presentation: presentation,
            layout: layout, onCancelDownload: boundCancelDownload, onCancelTransfer: boundCancelTransfer,
            onCancelUpload: boundCancelUpload))
#endif
        return content
    }

    @ViewBuilder
    private func fallbackThumbnail(layout: FileMessageLayout, binding: ChatBubbleSessionBinding, origin: UUID) -> some View {
        let thumbnailURL = state.resolvedAttachmentBubbleThumbnailURL(for: message)
        if thumbnailURL != nil || state.attachmentCanRefreshRemoteFile(message) {
            // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
            state.fileStore.observeMediaNetworkRecovery { generation in
                AttachmentThumbnailImage(
                    url: thumbnailURL,
                    cacheKey: state.attachmentThumbnailCacheKey(for: message),
                    contentMode: .fill,
                    maxPixelSize: Int(max(layout.mediaFrameSize.width, layout.mediaFrameSize.height) * UIScreen.main.scale * 1.5),
                    scopeGeneration: state.mediaCacheScopeContext?.sessionGeneration ?? 0,
                    networkRecoveryGeneration: generation,
                    recoveryURL: {
                        guard binding.generation == origin, !conversationID.isEmpty else { return nil }
                        let url = await state.refreshedAttachmentThumbnailURL(message, conversationID: conversationID)
                        return binding.generation == origin ? url : nil
                    },
                    recoverOnAnyFailure: layout.mediaCategory == "video",
                    indexedCacheURL: {
                        guard binding.generation == origin else { return nil }
                        let url = await state.cachedUnifiedAttachmentThumbnailURL(for: message, conversationID: conversationID)
                        return binding.generation == origin ? url : nil
                    },
                    indexedCacheCommit: { data in
                        guard binding.generation == origin else { return nil }
                        let url = await state.cacheUnifiedAttachmentThumbnail(data, for: message, conversationID: conversationID)
                        return binding.generation == origin ? url : nil
                    },
                    placeholder: {
                        FileAttachmentPlaceholder(symbol: layout.mediaSymbol, title: layout.mediaTitle, status: "缩略图加载中", usesOutgoingFill: outgoing && !layout.isBorderlessGIF)
                    },
                    failure: {
                        FileAttachmentPlaceholder(symbol: layout.mediaSymbol, title: layout.mediaTitle, status: "缩略图加载失败，点按重试", usesOutgoingFill: outgoing && !layout.isBorderlessGIF)
                    }
                )
            }
            // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END
        } else {
            FileAttachmentPlaceholder(
                symbol: layout.mediaSymbol,
                title: layout.mediaTitle,
                status: layout.mediaCategory == "video" ? "暂无视频封面" : "暂无图片预览",
                usesOutgoingFill: outgoing && !layout.isBorderlessGIF
            )
        }
    }
}

// Observe the existing scope/login binding; this is not a new retirement authority or F4 identity source.
struct ChatAttachmentSessionView<Content: View>: View {
    @Environment(\.chatBubbleSessionBinding) private var inheritedBinding
    let store: TenantInteractionPresentationStore
    let sessionSource: ChatBubbleSessionIdentitySource
    let initialIdentity: ChatBubbleSessionIdentity
    let content: (ChatBubbleSessionBinding) -> Content

    var body: some View {
        if let inheritedBinding {
            ObservedAttachmentScope(binding: inheritedBinding, content: content)
        } else {
            ChatBubbleSessionObservation(store: store, sessionSource: sessionSource, initialIdentity: initialIdentity) { binding in
                content(binding)
            }
        }
    }
}

private struct ObservedAttachmentScope<Content: View>: View {
    @ObservedObject var binding: ChatBubbleSessionBinding
    let content: (ChatBubbleSessionBinding) -> Content
    var body: some View { content(binding) }
}

#if DEBUG
struct ChatFileAttachmentProbe {
    let messageID: String
    let presentation: FileMessagePresentation
    let layout: FileMessageLayout
    let onCancelDownload: () -> Void
    let onCancelTransfer: () -> Void
    let onCancelUpload: () -> Void
}
@MainActor enum ChatAttachmentAssemblyDiagnostics {
    static var file: ((ChatFileAttachmentProbe) -> Void)?
    static var original: ((ChatOriginalThumbnailProbe) -> Void)?
    static var originalLookup: ((String, URL?) -> Void)?
    static var poster: ((ChatPosterThumbnailProbe) -> Void)?
}
#endif
// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END
// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_END

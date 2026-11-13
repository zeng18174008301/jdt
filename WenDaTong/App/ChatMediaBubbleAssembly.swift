import IM4Features
// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
import SwiftUI
import UIKit

struct StickerMessageView: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    private var snapshot: StickerMessageSnapshot? { message.stickerSnapshot }
    var body: some View {
        let store = state.stickerMessageAssetStore
        let project = { (snapshot: StickerMessageAssetStore.Snapshot) in
            state.stickerMessageAssetPresentation(for: message, snapshot: snapshot)
        }
        return PublisherSnapshotView(initialValue: project(store.snapshot), updates: store.updates(project)) { assets in
            let presentation = StickerMessagePresentation(
                thumbnailURL: assets.thumbnailURL, animationURL: assets.animationURL,
                requestKey: assets.requestKey, animationCacheKey: state.stickerAnimationCacheKey(for: message)
            )
#if DEBUG
            let _ = ChatMediaAssemblyDiagnostics.sticker?(message.id, presentation)
#endif
            StickerMessageContent(message: message, presentation: presentation) {
                state.resolveStickerMessageAssetsIfNeeded(for: snapshot)
            }
        }
    }
}

struct AttachmentGIFImage<Placeholder: View>: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let conversationID: String
    var localURL: URL? = nil
    var maxPixelSize = 768
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        // WDT_IOS1_CHAT_GIF_RENDER_PRESENTATION_20261111_BEGIN
        let playable = AttachmentGIFPresentation.canPlay(message)
        let scope = playable ? state.mediaCacheScopeContext : nil
        let canPlay = playable && scope != nil
        let downloadURL = canPlay ? state.resolvedAttachmentDownloadURL(for: message) : nil
        let previewURL = canPlay ? state.resolvedAttachmentPreviewURL(for: message) : nil
        let presentation = AttachmentGIFPresentation.renderPresentation(
            canPlay: canPlay,
            localURL: localURL,
            downloadURL: downloadURL,
            previewURL: previewURL,
            downloadAllowed: message.attachmentDownloadAvailable || message.status == .sending,
            previewAllowed: message.attachmentPreviewAvailable,
            cacheKey: "\(scope?.scopeHash ?? "invalid-scope")|\(scope?.sessionGeneration ?? 0)|original-gif|\(message.id)|\(message.attachmentVersion)|\(message.attachmentChecksum)"
        )
        // WDT_IOS1_CHAT_GIF_RENDER_PRESENTATION_20261111_END
#if DEBUG
        let _ = ChatMediaAssemblyDiagnostics.gif?(message.id, presentation)
#endif
        return AttachmentGIFContent(presentation: presentation, maxPixelSize: maxPixelSize,
            recoveryURL: { await state.refreshedGIFAttachmentOriginalURL(message, conversationID: conversationID) },
            placeholder: placeholder)
    }
}

private struct ChatBubbleSessionBindingKey: EnvironmentKey {
    static let defaultValue: ChatBubbleSessionBinding? = nil
}
extension EnvironmentValues {
    var chatBubbleSessionBinding: ChatBubbleSessionBinding? {
        get { self[ChatBubbleSessionBindingKey.self] }
        set { self[ChatBubbleSessionBindingKey.self] = newValue }
    }
}

struct VoiceBubbleContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.chatBubbleSessionBinding) private var inheritedBinding
    let message: ChatMessage
    let outgoing: Bool
    var conversationID = ""

    var body: some View {
        if let inheritedBinding { observedContent(binding: inheritedBinding) }
        else {
            // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN
            ChatBubbleSessionObservation(store: state.tenantInteractionStore,
                sessionSource: state.chatBubbleSessionIdentitySource, initialIdentity: state.chatBubbleSessionIdentity) { binding in
                observedContent(binding: binding)
            }
            // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END
        }
    }

    private func observedContent(binding: ChatBubbleSessionBinding) -> some View {
        let store = state.voiceMessagePlaybackStore
        return state.observeChatAttachment(message) {
            PublisherSnapshotView(initialValue: store.snapshot(for: message.id), updates: store.updates(for: message.id)) { playback in
                assembledContent(playback: playback, binding: binding)
            }.id(message.id)
        }
    }

    private func assembledContent(playback: VoiceMessagePlaybackStore.Snapshot, binding: ChatBubbleSessionBinding) -> some View {
        let generation = binding.generation
        let presentation = VoiceMessagePresentation(
            isPlaying: playback.isPlaying, playbackState: playback.state,
            progress: state.attachmentTransferProgress(for: message),
            isUploadTransfer: state.isAttachmentUploadInProgress(message),
            download: state.attachmentDownloadSnapshot(for: message),
            canRetryUpload: state.canRetryAttachmentUpload(message),
            downloadFailed: state.attachmentDownloadFailed(message)
        )
        let boundToggle: () -> Void = { binding.performIfCurrent(generation) { state.toggleVoiceMessagePlayback(message, conversationID: conversationID) } }
        let boundCancelDownload: () -> Void = { binding.performIfCurrent(generation) { state.cancelAttachmentDownload(message) } }
        let boundCancelTransfer: () -> Void = {
                binding.performIfCurrent(generation) {
                    if state.isAttachmentUploadInProgress(message) { state.cancelAttachmentUpload(messageID: message.id, in: conversationID) }
                    else { state.cancelAttachmentDownload(message) }
                }
            }
        let boundRetry: () -> Void = { binding.performIfCurrent(generation) { state.retryAttachmentUpload(messageID: message.id, in: conversationID) } }
        let boundDisappear: () -> Void = { binding.performIfCurrent(generation) { state.stopVoiceMessagePlayback(ifPlaying: message.id) } }
        let content = VoiceMessageContent(message: message, outgoing: outgoing, conversationID: conversationID,
            presentation: presentation,
            onToggle: boundToggle,
            onCancelDownload: boundCancelDownload,
            onCancelTransfer: boundCancelTransfer,
            onRetry: boundRetry,
            onDisappear: boundDisappear
        )
#if DEBUG
        ChatMediaAssemblyDiagnostics.voice?(ChatVoiceAssemblyProbe(messageID: message.id, presentation: presentation,
            onToggle: boundToggle, onCancelDownload: boundCancelDownload,
            onCancelTransfer: boundCancelTransfer, onRetry: boundRetry, onDisappear: boundDisappear))
#endif
        return content
    }
}

extension ChatBubbleSessionBinding {
    // Only the existing login/scope binding invalidates a retained UI command. Runtime methods keep authorization ownership.
    func performIfCurrent(_ origin: UUID, _ action: () -> Void) {
        guard generation == origin else { return }
        action()
    }
}

#if DEBUG
struct ChatVoiceAssemblyProbe {
    let messageID: String
    let presentation: VoiceMessagePresentation
    let onToggle: () -> Void
    let onCancelDownload: () -> Void
    let onCancelTransfer: () -> Void
    let onRetry: () -> Void
    let onDisappear: () -> Void
}
@MainActor enum ChatMediaAssemblyDiagnostics {
    static var voice: ((ChatVoiceAssemblyProbe) -> Void)?
    static var sticker: ((String, StickerMessagePresentation) -> Void)?
    static var gif: ((String, AttachmentGIFRenderPresentation) -> Void)?
}
#endif
// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END

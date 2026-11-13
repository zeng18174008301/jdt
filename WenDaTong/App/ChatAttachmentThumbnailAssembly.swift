import IM4Features
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_BEGIN
// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN
struct ServerVideoPosterThumbnail: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.chatMediaScrollActivity) private var mediaScrollActivity
    let message: ChatMessage
    let conversationID: String
    @State private var presentation: IOSVideoPosterPresentation = .pending
    @State private var displayedResource = ""
    @State private var completedBinding: String?

    private func posterURL(for presentation: IOSVideoPosterPresentation) -> URL? {
        guard case .ready(let url) = presentation else { return nil }
        return url
    }

    // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
    var body: some View {
        ChatAttachmentSessionView(store: state.tenantInteractionStore,
            sessionSource: state.chatBubbleSessionIdentitySource, initialIdentity: state.chatBubbleSessionIdentity) { binding in
            state.fileStore.observeMediaNetworkRecovery { generation in
                posterContent(networkRecoveryGeneration: generation)
            }
        }
    }

    private func posterContent(networkRecoveryGeneration: Int) -> some View {
        let scope = state.mediaCacheScopeContext
        let generation = scope?.sessionGeneration ?? 0
        let resource = "\(scope?.scopeHash ?? "")|\(generation)|\(message.id)|\(message.attachmentFileID ?? "")|\(message.attachmentChecksum)|\(message.attachmentVersion)"
        let requestBinding = "\(resource)|\(networkRecoveryGeneration)"
        let currentPresentation = displayedResource == resource ? presentation : .pending
        let isResolvingPoster = currentPresentation == .pending && completedBinding != requestBinding
        // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END
        let visible = !message.isDeletedLocally && message.status != .recalled && currentPresentation != .unavailable
        let localURL = posterURL(for: currentPresentation)
        let cacheKey = visible ? state.chatAttachmentImageCacheKey(for: message, videoPoster: true) : ""
#if DEBUG
        let _ = ChatAttachmentAssemblyDiagnostics.poster?(ChatPosterThumbnailProbe(messageID: message.id,
            resource: resource, requestBinding: requestBinding, scopeGeneration: generation,
            visible: visible, presentation: currentPresentation))
#endif
        return ServerVideoPosterContent(visible: visible, localURL: localURL, cacheKey: cacheKey,
            scopeGeneration: generation, isResolvingPoster: isResolvingPoster)
        .task(id: requestBinding, priority: .utility) {
            if let mediaScrollActivity, !(await mediaScrollActivity.waitUntilIdle()) { return }
            await state.loadServerVideoPoster(message, conversationID: conversationID) { result in
                guard !Task.isCancelled else { return }
                if displayedResource != resource {
                    displayedResource = resource
                    presentation = result
                    return
                }
                guard presentation != result else { return }
                switch presentation {
                case .ready, .unavailable:
                    switch result {
                    case .pending, .missing, .failed, .limited: return
                    case .ready, .unavailable: break
                    }
                default: break
                }
                presentation = result
            }
            guard !Task.isCancelled else { return }
            // Terminal results already hide the spinner. Record completion only
            // when the loader exited without a terminal result.
            if displayedResource != resource || presentation == .pending {
                completedBinding = requestBinding
            }
        }
    }
}


struct AttachmentOriginalThumbnail: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let conversationID: String

    var body: some View {
        Group {
            if !message.isDeletedLocally, message.status != .recalled {
                ChatAttachmentSessionView(store: state.tenantInteractionStore,
            sessionSource: state.chatBubbleSessionIdentitySource, initialIdentity: state.chatBubbleSessionIdentity) { binding in
                    state.fileStore.observeMediaNetworkRecovery { generation in
                        originalContent(networkRecoveryGeneration: generation, binding: binding)
                    }
                }
            }
        }
    }

    private func originalContent(networkRecoveryGeneration: Int, binding: ChatBubbleSessionBinding) -> some View {
        let origin = binding.generation
        let scope = state.mediaCacheScopeContext?.sessionGeneration ?? 0
        // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_BEGIN
        let thumbnailURL = state.chatImageThumbnailURL(for: message)
        let originalCacheKey = state.chatAttachmentImageCacheKey(for: message, videoPoster: false)
        let cacheKey = thumbnailURL == nil ? originalCacheKey : "thumbnail|\(originalCacheKey)"
        // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_END
        let recovery: () async -> URL? = {
            guard binding.generation == origin else { return nil }
            // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_BEGIN
            let url = await state.prepareChatImageBubbleFile(message, conversationID: conversationID,
                attemptedThumbnail: thumbnailURL)
            return binding.generation == origin ? url : nil
            // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_END
        }
        let lookup: () async -> URL? = {
            guard binding.generation == origin else { return nil }
            // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_BEGIN
            let thumbnail = await state.cachedUnifiedAttachmentThumbnailURL(for: message, conversationID: conversationID)
            let url: URL?
            if let thumbnail {
                url = thumbnail
            } else {
                url = await state.cachedMessageAttachmentLocalFile(message, conversationID: conversationID)
            }
            // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_END
#if DEBUG
            ChatAttachmentAssemblyDiagnostics.originalLookup?(message.id, url)
#endif
            return binding.generation == origin ? url : nil
        }
#if DEBUG
        ChatAttachmentAssemblyDiagnostics.original?(ChatOriginalThumbnailProbe(messageID: message.id,
            cacheKey: cacheKey, scopeGeneration: scope, networkRecoveryGeneration: networkRecoveryGeneration,
            recoveryURL: recovery, indexedCacheURL: lookup))
#endif
        return AttachmentOriginalContent(visible: true, thumbnailURL: thumbnailURL, cacheKey: cacheKey, scopeGeneration: scope, // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
            networkRecoveryGeneration: networkRecoveryGeneration, recoveryURL: recovery, indexedCacheURL: lookup)
    }
}

// WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_BEGIN
extension AppState {
    func prepareChatImageBubbleFile(_ message: ChatMessage, conversationID: String,
        attemptedThumbnail: URL?,
        downloadThumbnail: (URL) async -> Data? = { url in
            await AttachmentThumbnailDiskCache.downloadImageResult(
                from: url, cacheKey: "", maxPixelSize: 768
            ).data
        }
    ) async -> URL? {
        let context = apiContext
        let scope = contentCacheScopeKey
        let generation = localMessageSessionGeneration
        func isCurrent() -> Bool {
            let current = currentAttachmentCacheMessage(message, conversationID: conversationID)
            return !Task.isCancelled && contentCacheScopeKey == scope
                && localMessageSessionGeneration == generation
                && !current.isDeletedLocally && current.status != .recalled
                && current.attachmentVersion == message.attachmentVersion
                && current.attachmentChecksum == message.attachmentChecksum
        }
        let fileID = tenantFileID(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCurrent() else { return nil }
        var detail: RemoteUserFileDetail?
        if context.hasIMSession, !fileID.isEmpty {
            guard let fetched = try? await api.getTenantFile(context: context, fileID: fileID),
                  isCurrent() else { return nil }
            detail = fetched
            guard fetched.file.id == fileID else { return nil }
            let status = fetched.file.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !["deleted", "disabled", "expired"].contains(status) else { return nil }
            var candidate = message
            candidate.attachmentThumbnailURL = fetched.file.thumbnailURL
            candidate.attachmentDownloadURL = fetched.downloadURL.isEmpty ? message.attachmentDownloadURL : fetched.downloadURL
            if let url = chatImageThumbnailURL(for: candidate), url != attemptedThumbnail,
               (message.attachmentVersion.isEmpty || fetched.file.version == message.attachmentVersion),
               (message.attachmentChecksum.isEmpty || fetched.file.checksum == message.attachmentChecksum),
               let bytes = await downloadThumbnail(url), isCurrent(),
               let cached = await cacheUnifiedAttachmentThumbnail(bytes, for: message, conversationID: conversationID),
               isCurrent() {
                return cached
            }
        }
        guard isCurrent() else { return nil }
        return try? await prepareMessageAttachmentLocalFile(message, conversationID: conversationID,
            forChatThumbnail: true, prefetchedDetail: detail)
    }
}
// WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_END

#if DEBUG
struct ChatOriginalThumbnailProbe {
    let messageID: String
    let cacheKey: String
    let scopeGeneration: UInt64
    let networkRecoveryGeneration: Int
    let recoveryURL: () async -> URL?
    let indexedCacheURL: () async -> URL?
}
struct ChatPosterThumbnailProbe {
    let messageID: String
    let resource: String
    let requestBinding: String
    let scopeGeneration: UInt64
    let visible: Bool
    let presentation: IOSVideoPosterPresentation
}
#endif
// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END
// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_END

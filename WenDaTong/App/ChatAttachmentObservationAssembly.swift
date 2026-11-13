import SwiftUI
import Combine
// WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_BEGIN
import IM4Domain
import IM4Stores
// WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_END

// WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
// WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
extension FileStore {
    @MainActor
    func observeUploadConfiguration<Value: Equatable, Content: View>(
        _ projection: KeyPath<UploadConfigurationSnapshot, Value>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(
            initialValue: uploadConfiguration[keyPath: projection],
            updates: configurationUpdates(for: projection),
            content: content
        )
    }
}
// WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_BEGIN
extension FileStore {
    @MainActor
    func observeMediaNetworkRecovery<Content: View>(
        @ViewBuilder content: @escaping (Int) -> Content
    ) -> some View {
        PublisherSnapshotView(
            initialValue: mediaNetworkRecoveryGeneration,
            updates: $mediaNetworkRecoveryGeneration.eraseToAnyPublisher(),
            content: content
        )
    }
}
// WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110_END

extension AppState {
    func chatAttachmentIdentity(for message: ChatMessage) -> FileStore.ChatAttachmentIdentity? {
        guard [.image, .video, .voice, .file].contains(message.kind) else { return nil }
        return FileStore.ChatAttachmentIdentity(
            downloads: FileStore.DownloadKeys(
                original: attachmentProgressKey(for: message),
                preview: attachmentProgressKey(for: message, preferPreview: true)
            ),
            messageID: message.id,
            resourceKeys: attachmentResourceCacheKeys(for: message)
        )
    }

    // WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_BEGIN
    func observeChatAttachment<Content: View>(
        _ message: ChatMessage, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        fileStore.observeChatAttachment(identity: chatAttachmentIdentity(for: message), content: content)
    }
}

extension FileStore {
    @MainActor @ViewBuilder
    func observeChatAttachment<Content: View>(
        identity: ChatAttachmentIdentity?, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if let identity {
            PublisherSnapshotView(initialValue: chatAttachmentSnapshot(identity),
                                  updates: chatAttachmentUpdates(identity)) { _ in content() }
        } else {
            content()
        }
    }
}
    // WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_END
// WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END

// WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_BEGIN
@MainActor
struct AttachmentDetailSource {
    struct Preview {
        let category: String
        let url: URL?
        let downloadURL: URL?
        let canRefresh: Bool

        var isAvailable: Bool { canRefresh || url != nil || (category == "video" && downloadURL != nil) }
        var canDownload: Bool { downloadURL != nil || canRefresh }
    }

    struct Transfer {
        let isUploading: Bool
        let progress: Double?
        let download: AttachmentDownloadSnapshot?
        let uploadFailure: String?
        let canRetry: Bool
    }

    struct Thumbnail {
        let url: URL?
        let cacheKey: String
        let scopeGeneration: UInt64
    }

    let tenant: TenantInteractionPresentationStore
    let files: FileStore
    let sessions: ChatBubbleSessionIdentitySource
    let currentIdentity: () -> ChatBubbleSessionIdentity
    let transferIdentity: () -> FileStore.ChatAttachmentIdentity?
    let preview: () -> Preview
    let transfer: () -> Transfer
    let forwardDisabledReason: (MessageActionsPolicy) -> String?
    let thumbnail: () -> Thumbnail
    let recoverThumbnail: () async -> URL?
    let cachedThumbnail: () async -> URL?
    let cacheThumbnail: (Data) async -> URL?
    let authorizePreview: () async -> Bool
    let openPreview: () -> Void
    let prepareLocalFile: (Bool) async throws -> URL
    let downloadDocument: (URL, String) async throws -> URL
    let retryUpload: () -> Void
    let cancelUpload: () -> Void
    let cancelDownload: () -> Void
    let toast: (String?) -> Void

    static func bind(_ app: AppState, message: ChatMessage, conversationID: String) -> Self {
        Self(
            tenant: app.tenantInteractionStore, files: app.fileStore, sessions: app.chatBubbleSessionIdentitySource,
            currentIdentity: { app.chatBubbleSessionIdentity },
            transferIdentity: { app.chatAttachmentIdentity(for: message) },
            preview: {
                Preview(category: app.attachmentMediaCategory(for: message),
                    url: app.resolvedAttachmentBestPreviewURL(for: message),
                    downloadURL: app.resolvedAttachmentDownloadURL(for: message),
                    canRefresh: app.attachmentCanRefreshRemoteFile(message))
            },
            transfer: {
                Transfer(isUploading: app.isAttachmentUploadInProgress(message),
                    progress: app.attachmentTransferProgress(for: message),
                    download: app.attachmentDownloadSnapshot(for: message),
                    uploadFailure: app.attachmentUploadFailureMessage(for: message),
                    canRetry: app.canRetryAttachmentUpload(message))
            },
            forwardDisabledReason: { policy in
                switch app.batchForwardEligibility(for: message, in: conversationID, policy: policy) {
                case .selectable: return nil
                case .disabled(let reason): return reason
                }
            },
            thumbnail: {
                let url = app.resolvedAttachmentThumbnailURL(for: message)
                    ?? (app.attachmentMediaCategory(for: message) == "video" ? nil : app.resolvedAttachmentBestPreviewURL(for: message))
                return Thumbnail(url: url, cacheKey: app.attachmentThumbnailCacheKey(for: message),
                                 scopeGeneration: app.mediaCacheScopeContext?.sessionGeneration ?? 0)
            },
            recoverThumbnail: { await app.refreshedAttachmentThumbnailURL(message, conversationID: conversationID) },
            cachedThumbnail: { await app.cachedUnifiedAttachmentThumbnailURL(for: message) },
            cacheThumbnail: { await app.cacheUnifiedAttachmentThumbnail($0, for: message, conversationID: conversationID) },
            authorizePreview: { await app.authorizeProtectedAccess(.filePreview) },
            openPreview: { app.openMessageAttachment(message, conversationID: conversationID, preferPreview: true) },
            prepareLocalFile: { try await app.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: $0) },
            downloadDocument: { url, fileName in
                try await SystemPreviewLoader.download(url, suggestedName: fileName,
                    cacheIdentity: app.attachmentSystemPreviewCacheIdentity(for: message))
            },
            retryUpload: { app.retryAttachmentUpload(messageID: message.id, in: conversationID) },
            cancelUpload: { app.cancelAttachmentUpload(messageID: message.id, in: conversationID) },
            cancelDownload: { app.cancelAttachmentDownload(message) },
            toast: app.setToast
        )
    }
}

private struct AttachmentDetailSourceKey: EnvironmentKey {
    static let defaultValue: (@MainActor (ChatMessage, String) -> AttachmentDetailSource)? = nil
}

extension EnvironmentValues {
    var attachmentDetailSource: (@MainActor (ChatMessage, String) -> AttachmentDetailSource)? {
        get { self[AttachmentDetailSourceKey.self] }
        set { self[AttachmentDetailSourceKey.self] = newValue }
    }
}
// WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_END

import SwiftUI
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
import IM4Domain
import IM4Features
import IM4Stores
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_BEGIN
extension ChatView {
    @ViewBuilder
    var chatComposerArea: some View {
        if !isReadOnlySystemConversation {
            if isBatchForwardSelectionActive {
                BatchForwardSelectionBar(
                    selectedCount: batchForwardSelectedSourceCount,
                    onCancel: {
                        screenActions.forwarding.cancelBatchForward()
                    },
                    onForward: {
                        screenActions.forwarding.refreshBatchForwardContext(
                            conversationID: conversationID
                        )
                        showBatchForwardTargets = true
                    }
                )
            } else {
                // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
                screenStores.tenantInteraction.observe(\.chat) { _ in
                GroupSnapshotView(store: screenStores.contacts, selectors: screenActions.authority.groupObservationSelectors(conversationID: conversationID)) {
                screenStores.files.observeUploadConfiguration(\.callLicense) { _ in
                    ChatComposer(
                    conversationID: conversationID,
                    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
                    input: composerState.binding(\.input, conversationID: conversationID, scope: chatComposerScope),
                    replyQuote: composerState.binding(\.replyQuote, conversationID: conversationID, scope: chatComposerScope),
                    replyContext: composerState.binding(\.replyContext, conversationID: conversationID, scope: chatComposerScope),
                    showTools: composerState.binding(\.showTools, conversationID: conversationID, scope: chatComposerScope),
                    showEmoji: composerState.binding(\.showEmoji, conversationID: conversationID, scope: chatComposerScope),
                    mentionAllSelected: composerState.binding(\.mentionAll, conversationID: conversationID, scope: chatComposerScope),
                    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
                    mentionGroupID: conversation.kind == .group ? currentGroup.id : "",
                    mentionMembers: conversation.kind == .group ? (currentGroup.members.isEmpty ? conversation.participants : currentGroup.members) : [],
                    mentionMembersLoading: conversation.kind == .group && currentGroup.members.isEmpty,
                    canMentionAll: conversation.kind == .group && currentGroup.canCurrentUserManage,
                    isDisabled: composerIsDisabled,
                    showsDisabledNotice: disabledBannerDecision.showsComposerDisabledNotice,
                    disabledTitle: composerDisabledTitle,
                    disabledReason: composerDisabledReason,
                    friendActionTitle: screenActions.people.conversationFriendRequestActionTitle(conversationID),
                    isApplyingFriend: screenStores.conversations.applyingFriendConversationIDs().contains(conversationID),
                    allowsVoiceCall: conversation.kind == .direct,
                    allowsVideoCall: isVideoCallEntryVisible,
                    voiceCallAccessibilityHint: voiceCallAccessibilityHint,
                    videoCallAccessibilityHint: videoCallAccessibilityHint,
                    startVoiceCall: startVoiceCallFromConversation,
                    startVideoCall: startVideoCallFromConversation,
                    applyFriend: {
                        Task {
                            await screenActions.people.applyFriendFromDisabledConversation(conversationID)
                        }
                    },

                    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_CALL - 修改开始：ChatView 传入输入框聚焦滚动回调
                    onBeginEditing: {
                        scrollToLatestMessageForComposerFocus()
                    },
                    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_CALL - 修改结束：ChatView 传入输入框聚焦滚动回调
                    // WDT_CHAT_KEYBOARD_INSET_20261021: no message, read-state or scroll side effects.
                    onEditingChanged: { isEditing in
                        presentation.receiveComposerEditingEvent(isEditing)
                    },
                    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CALL - 修改开始：ChatView 传入 composer 操作滚动回调
                    onRequestLatestScroll: {
                        scrollToLatestMessageForComposerFocus()
                    },
                    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CALL - 修改结束：ChatView 传入 composer 操作滚动回调
                    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110
                    sharedComposerState: composerState,
                    sharedComposerScope: chatComposerScope,
                    send: { draft, mentionAll, mentionedUsers in
                        sendComposerDraft(draft, mentionAll: mentionAll, mentionedUsers: mentionedUsers)
                    }
                    )
                    .id(chatComposerScope + [conversationID]) // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110: a new scope/conversation gets its own UIKit editor lifetime.
                }
                }
                }
                // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END
            }
        }
    }

}
// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_END

// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
@MainActor
struct ChatComposerServices {
    let authentication: AuthenticationPresentationStore
    let enterprise: EnterpriseMembershipPresentationStore
    let currentUser: CurrentUserPresentationStore
    let sessions: ChatBubbleSessionIdentitySource
    let currentIdentity: () -> ChatBubbleSessionIdentity
    let globalMutedMessage: String
    let contacts: ContactStore
    let remarkPreferredDisplayName: (IMUser) -> String
    let contactCandidate: (IMUser) -> ChatContactCardCandidate
    let shareContactCard: (IMUser, String, String?) -> Void
    let searchMentions: (String, String) async -> [IMUser]
    let toast: (String?) -> Void
    let stopVoicePlayback: () -> Void
    let stickers: ChatComposerStickerActions
    let catalog: ChatComposerCatalogActions
    let media: ChatComposerMediaActions

    @ViewBuilder
    func observeAccount<Content: View>(
        @ViewBuilder content: @escaping (Bool, String, CurrentUserPresentationStore.Identity, ChatBubbleSessionIdentity) -> Content
    ) -> some View {
        authentication.observeAuthentication { authenticated in
            enterprise.observe(\.current.id) { enterpriseID in
                currentUser.observe(CurrentUserPresentationStore.identity) { identity in
                    PublisherSnapshotView(initialValue: currentIdentity(), updates: sessions.updates) { session in
                        content(authenticated, enterpriseID, identity, session)
                    }
                }
            }
        }
    }

    static func bind(_ app: AppState) -> Self {
        Self(
            authentication: app.authenticationPresentationStore, enterprise: app.enterpriseMembershipStore,
            currentUser: app.currentUserPresentationStore, sessions: app.chatBubbleSessionIdentitySource,
            currentIdentity: { app.chatBubbleSessionIdentity }, globalMutedMessage: AppState.globalMutedMessage,
            contacts: app.contactStore, remarkPreferredDisplayName: { app.remarkPreferredDisplayName(for: $0) },
            contactCandidate: { user in
                ChatContactCardCandidate(user: user, displayName: app.remarkPreferredDisplayName(for: user),
                    certification: app.certificationPillSource.reference(forExactUID: user.id)?.chatFeatureReference)
            },
            shareContactCard: app.shareContactCard, searchMentions: app.searchGroupMentionMembers,
            toast: app.setToast, stopVoicePlayback: { app.stopVoiceMessagePlayback() },
            stickers: .bind(app), catalog: .bind(app), media: .bind(app)
        )
    }
}

@MainActor
struct ChatComposerStickerActions {
    let store: StickerStore
    let prepare: () async -> Void
    let refresh: () -> Void
    let thumbnailURL: (StickerLibraryItem) -> String
    let retry: (StickerLibraryItem) -> Void
    let delete: (StickerLibraryItem) -> Void
    let move: (StickerLibraryItem, Int) -> Void
    let upload: (Data, String, String) -> Void
    let send: (StickerLibraryItem, String, String?, MessageReplyContext?, @escaping @MainActor () -> Void) -> Bool

    static func bind(_ app: AppState) -> Self {
        Self(store: app.stickerStore, prepare: { await app.prepareStickerExpressionPanel() },
             refresh: app.refreshStickerExpressionPanel, thumbnailURL: app.stickerThumbnailURL,
             retry: app.retryStickerUpload, delete: app.deleteSticker, move: app.moveSticker,
             upload: app.uploadStickerImage,
             send: { item, conversation, quote, reply, onRejected in
                app.sendSticker(item, conversationID: conversation, quote: quote, replyContext: reply,
                                onPolicyRejected: onRejected)
             })
    }
}

@MainActor
struct ChatComposerCatalogActions {
    let taskKey: (Bool, String, CurrentUserPresentationStore.Identity) -> String
    let currentContext: () -> EmojiPickerRuntimeContext?
    let reset: () -> Void
    let begin: (EmojiPickerRuntimeContext) -> EmojiPickerCatalogLoadDecision
    let recordSuccess: (EmojiCatalog, EmojiPickerRuntimeContext) -> Bool
    let recordFailure: (EmojiPickerRuntimeContext) -> Bool
    let cancelAttempt: (EmojiPickerRuntimeContext) -> Void

    static func bind(_ app: AppState) -> Self {
        Self(
            taskKey: { emojiPickerRuntimeTaskKey(state: app, isOpen: $0, enterpriseID: $1, identity: $2) },
            currentContext: { currentEmojiPickerRuntimeContext(state: app) },
            reset: { app.emojiPickerCatalogRuntime.reset() },
            begin: { app.emojiPickerCatalogRuntime.begin(scope: $0.scope, baseURL: $0.catalogBaseURL) },
            recordSuccess: { app.emojiPickerCatalogRuntime.recordSuccess($0, scope: $1.scope, baseURL: $1.catalogBaseURL) },
            recordFailure: { app.emojiPickerCatalogRuntime.recordFailure(scope: $0.scope, baseURL: $0.catalogBaseURL) },
            cancelAttempt: { app.emojiPickerCatalogRuntime.cancelAttempt(scope: $0.scope, baseURL: $0.catalogBaseURL) }
        )
    }
}

@MainActor
struct ChatComposerMediaActions {
    let sendAttachment: (PendingAttachmentSelection, String, String?, MessageReplyContext?, Bool,
                         @escaping @MainActor () -> Void, @escaping (String) -> Void) -> Bool
    let startQueuedAttachments: ([String], String) -> Void
    let sendVoice: (VoiceMessageRecording, String, String?, MessageReplyContext?, @escaping @MainActor () -> Void) -> Bool

    static func bind(_ app: AppState) -> Self {
        Self(
            sendAttachment: { selection, conversation, quote, reply, automaticallyStart, onRejected, onQueued in
                app.sendAttachment(kind: selection.kind, name: selection.name, mimeType: selection.mimeType,
                    sizeBytes: selection.sizeBytes, data: selection.data, fileURL: selection.fileURL,
                    removeFileWhenFinished: selection.ownsFileURL, conversationID: conversation, quote: quote,
                    replyContext: reply, onPolicyRejected: onRejected,
                    automaticallyStartUpload: automaticallyStart, onQueued: onQueued)
            },
            startQueuedAttachments: app.startQueuedAttachmentUploadsInOrder,
            sendVoice: { recording, conversation, quote, reply, onRejected in
                app.sendVoiceMessage(data: recording.data, name: recording.name, mimeType: recording.mimeType,
                    sizeBytes: recording.sizeBytes, durationMS: recording.durationMS, waveform: recording.waveform,
                    conversationID: conversation, quote: quote, replyContext: reply, onPolicyRejected: onRejected)
            }
        )
    }
}

private struct ChatComposerServicesKey: EnvironmentKey {
    static let defaultValue: ChatComposerServices? = nil
}

extension EnvironmentValues {
    var chatComposerServices: ChatComposerServices? {
        get { self[ChatComposerServicesKey.self] }
        set { self[ChatComposerServicesKey.self] = newValue }
    }
}
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

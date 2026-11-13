import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

// Only the existing F4 binding/identity is sampled here. No new authority or epoch.
@MainActor struct ChatSecondaryEntry {
    let binding: ChatBubbleSessionBinding
    let generation: UUID
    let identity: ChatBubbleSessionIdentity
    init(_ state: AppState, binding: ChatBubbleSessionBinding? = nil) {
        self.init(policy: state.tenantInteractionStore, sessionSource: state.chatBubbleSessionIdentitySource,
                  identity: state.chatBubbleSessionIdentity, binding: binding)
    }

    init(policy: TenantInteractionPresentationStore, sessionSource: ChatBubbleSessionIdentitySource,
         identity: ChatBubbleSessionIdentity, binding: ChatBubbleSessionBinding? = nil) {
        let original = binding ?? ChatBubbleSessionBinding(
            store: policy, sessionSource: sessionSource, initialIdentity: identity
        )
        self.binding = original
        generation = original.generation
        self.identity = identity
    }

    func isCurrent(_ state: AppState) -> Bool {
        isCurrent(identity: state.chatBubbleSessionIdentity)
    }

    func isCurrent(identity: ChatBubbleSessionIdentity) -> Bool {
        binding.generation == generation && self.identity == identity
    }
}
extension AppState {
    func observeChatSecondaryEntry<Content: View>(@ViewBuilder content: @escaping (ChatSecondaryEntry) -> Content) -> some View {
        ChatAttachmentSessionView(store: tenantInteractionStore,
            sessionSource: chatBubbleSessionIdentitySource, initialIdentity: chatBubbleSessionIdentity) { binding in
            content(ChatSecondaryEntry(self, binding: binding))
        }
    }
}

extension ChatView {
    func secondaryEntry(binding: ChatBubbleSessionBinding? = nil) -> ChatSecondaryEntry {
        ChatSecondaryEntry(policy: screenStores.tenantInteraction, sessionSource: screenStores.sessionIdentity,
                           identity: screenActions.authority.chatBubbleSessionIdentity(), binding: binding)
    }

    func observeSecondaryEntry<Content: View>(
        @ViewBuilder content: @escaping (ChatSecondaryEntry) -> Content
    ) -> some View {
        ChatAttachmentSessionView(store: screenStores.tenantInteraction,
            sessionSource: screenStores.sessionIdentity, initialIdentity: screenActions.authority.chatBubbleSessionIdentity()) { binding in
            content(secondaryEntry(binding: binding))
        }
    }

    @ViewBuilder
    func observeSelectedAttachment<Content: View>(
        _ message: ChatMessage, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if let identity = screenActions.media.attachmentIdentity(for: message) {
            let store = screenStores.files
            PublisherSnapshotView(initialValue: store.chatAttachmentSnapshot(identity),
                                  updates: store.chatAttachmentUpdates(identity)) { _ in
                content()
            }
        } else {
            content()
        }
    }

    func mention(_ user: IMUser) {
        guard conversation.kind == .group else { return }
	        let displayName = mentionVisibleDisplayName(for: user)
        let mentionText = "@\(displayName) "
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            input = mentionText
        } else if !input.contains(mentionText) {
            input += input.hasSuffix(" ") ? mentionText : " \(mentionText)"
        }
        rememberExternalMention(user, displayText: displayName)
        showTools = false
        showEmoji = false
    }

    private func rememberExternalMention(_ user: IMUser, displayText: String? = nil) {
        let mention = MentionIdentity(
            imUID: user.id,
            userID: user.userID,
            username: user.username,
            displayText: displayText ?? mentionVisibleDisplayName(for: user)
        )
        guard !mention.id.isEmpty else { return }
        pendingMentionUsers.removeAll { $0.id == mention.id || $0.mentionToken == mention.mentionToken }
        pendingMentionUsers.append(mention)
    }

    func mergedMentionUsers(from composerMentions: [MentionIdentity], externalMentions: [MentionIdentity], in draft: String) -> [MentionIdentity] {
        var seen = Set<String>()
        return (composerMentions + externalMentions).filter { mention in
            guard draft.contains(mention.mentionToken), !mention.id.isEmpty else { return false }
            return seen.insert(mention.id).inserted
        }
    }

    func startReply(to message: ChatMessage) {
        let context = replyContext(for: message)
        replyContext = context
        replyQuote = context.quoteText
        guard conversation.kind == .group,
              let replyTarget = replyMentionTarget(for: message) else { return }
        mention(replyTarget)
    }

    func replyContext(for message: ChatMessage) -> MessageReplyContext {
        let senderName = replySenderSnapshotName(for: message)
        return MessageReplyContext(
            messageID: message.id,
            senderID: message.senderId,
            senderName: senderName,
            summary: replySummaryText(for: message),
            contentType: message.contentType.isEmpty ? message.kind.rawValue : message.contentType,
            channelSeq: message.channelSeq,
            isUnavailable: message.status == .recalled || message.isDeletedLocally,
            thumbnailURL: message.isStickerMessage ? message.stickerSnapshot?.thumbnailURL ?? "" : ""
        )
    }

    private func replyMentionTarget(for message: ChatMessage) -> IMUser? {
        guard message.kind != .system, !isMessageAuthoredByCurrentUser(message) else { return nil }
        let resolver = MessageSenderResolver(
            currentUser: screenStores.currentUser.user,
            enterpriseName: chatEnterpriseName, // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            conversation: conversation,
            contacts: screenStores.contacts.contacts,
            group: currentGroup,
            exactGroupSelf: screenActions.people.myGroupMemberProjection(groupID: currentGroup.id),
            contactRemarks: screenStores.contacts.remarks
        )
        return resolver.senderUser(for: message)
    }

    private func replyQuoteText(for message: ChatMessage) -> String {
        let senderName = replySenderDisplayName(for: message)
        let summary = replySummaryText(for: message)
        return senderName.isEmpty ? summary : "\(senderName)：\(summary)"
    }

    private func replySenderDisplayName(for message: ChatMessage) -> String {
        let resolver = MessageSenderResolver(
            currentUser: screenStores.currentUser.user,
            enterpriseName: chatEnterpriseName, // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            conversation: conversation,
            contacts: screenStores.contacts.contacts,
            group: conversation.kind == .group ? currentGroup : nil,
            exactGroupSelf: conversation.kind == .group
                ? screenActions.people.myGroupMemberProjection(groupID: currentGroup.id)
                : nil,
            contactRemarks: screenStores.contacts.remarks
        )
        let senderUser = resolver.senderUser(for: message)
        return resolver.displaySenderName(for: message, resolvedUser: senderUser)
    }

    private func replySenderSnapshotName(for message: ChatMessage) -> String {
        guard message.kind != .system else { return "系统" }
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedName.isEmpty, !isIdentifierLikeSenderName(storedName, senderID: message.senderId) {
            return storedName
        }
        return message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replySummaryText(for message: ChatMessage) -> String {
        switch message.kind {
        case .rtcCallRecord:
            return message.rtcCallRecord?.presentation(viewerIsCaller: message.isOutgoing).conversationPreview
                ?? "[通话记录]"
        case .image:
            return "[图片]"
        case .file:
            let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
            switch screenActions.media.attachmentMediaCategory(for: message) {
            case "video":
                return "[视频]"
            default:
                return name.isEmpty ? "[文件]" : "[文件] \(name)"
            }
        case .voice:
            return "[语音]"
        case .video:
            return "[视频]"
        case .location:
            return "[位置]"
        case .contactCard:
            let name = (message.attachmentName ?? message.text)
                .replacingOccurrences(of: "个人名片：", with: "")
                .replacingOccurrences(of: "推荐名片：", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "[名片]" : "[名片] \(name)"
        case .system:
            return "回复了一条消息"
        case .text:
            if message.isStickerMessage {
                return message.stickerSnapshot?.fallbackText ?? StickerMessageSnapshot.fallbackText
            }
            let text = message.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "回复了一条消息" : text
        }
    }


}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

extension ChatView {
    @ViewBuilder
    var assembledMessageActionOverlay: some View {
        observeSecondaryEntry { entry in
        Group {
            if !isReadOnlySystemConversation, let actionMessage {
                // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_BEGIN
                observeSelectedAttachment(actionMessage) {
                    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
                    screenStores.files.observeUploadConfiguration(\.config) { config in
                        // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
                        screenStores.tenantInteraction.observe(\.chat) { interaction in
                            MessageActionOverlay(
                                message: actionMessage,
                                conversationID: conversationID,
                                canShowReadActions: isMessageAuthoredByCurrentUser(actionMessage),
                                readActionTitle: config.readReceiptsEnabled ? "已读列表" : "送达详情",
                                canForward: batchForwardDisabledReason(for: actionMessage, policy: interaction.actions) == nil,
                                forwardDisabledReason: batchForwardDisabledReason(for: actionMessage, policy: interaction.actions),
                                canSaveAttachment: canSaveAttachmentFromActionMenu(actionMessage),
                                canFavoriteAsset: canFavoriteAssetFromActionMenu(actionMessage),
                                canReportMessage: messageReportActionIsAvailable(
                                    message: actionMessage,
                                    isCurrentUserSender: isMessageAuthoredByCurrentUser(actionMessage)
                                ),
                                canAdminDeleteForAll: screenActions.messages.canAdminDeleteMessage(actionMessage, in: conversationID),
                                editDisabledReason: screenActions.messages.messageEditUnavailableReason(actionMessage, policy: interaction.actions),
                                recallDisabledReason: screenActions.messages.messageRecallUnavailableReason(actionMessage, policy: interaction.actions),
                                onDismiss: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                                        self.actionMessage = nil
                                    }
                                },
                                onReact: { emoji in
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    screenActions.messages.addReaction(emoji, to: actionMessage.id, in: conversationID)
                                    self.actionMessage = nil
                                },
                                onMoreReactions: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    reactionMessage = actionMessage
                                    self.actionMessage = nil
                                },
                                onReply: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    startReply(to: actionMessage)
                                    self.actionMessage = nil
                                },
                                onCopy: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    screenActions.messages.copyMessage(actionMessage)
                                    self.actionMessage = nil
                                },
                                onRead: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    guard isMessageAuthoredByCurrentUser(actionMessage) else {
                                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("只能查看自己发送消息的已读状态")
                                        self.actionMessage = nil
                                        return
                                    }
                                    // WDT_RECEIPT_DETAIL_SCOPE_20261023: reactions and reader identities have separate permissions.
                                    screenActions.messages.prepareReadReceiptPanel(messageID: actionMessage.id, in: conversationID)
                                    receiptMessage = actionMessage
                                    self.actionMessage = nil
                                },
                                onEdit: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    editMessage = actionMessage
                                    self.actionMessage = nil
                                },
                                onPin: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    screenActions.messages.toggleMessagePinned(messageID: actionMessage.id, in: conversationID)
                                    self.actionMessage = nil
                                },
                                onFavorite: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    screenActions.messages.toggleMessageFavorite(messageID: actionMessage.id, in: conversationID)
                                    self.actionMessage = nil
                                },
                                onForward: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    beginBatchForward(with: actionMessage)
                                    self.actionMessage = nil
                                },
                                onSaveAttachment: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    saveAttachmentFromActionMenu(actionMessage)
                                    self.actionMessage = nil
                                },
                                onReport: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    reportMessage = actionMessage
                                    self.actionMessage = nil
                                },
                                onDelete: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    self.actionMessage = nil
                                    if actionMessage.status == .failed {
                                        failedDeleteCandidate = actionMessage
                                    } else {
                                        Task { guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }; await screenActions.messages.deleteOwnMessage(messageID: actionMessage.id, in: conversationID, as: .sent) }
                                    }
                                },
                                onAdminDeleteForAll: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    adminDeleteCandidate = actionMessage
                                    self.actionMessage = nil
                                },
                                onRecall: {
                                    guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                                    screenActions.messages.recallMessage(messageID: actionMessage.id, in: conversationID)
                                    self.actionMessage = nil
                                }
                            )
                            .environment(\.chatShowsMessageProcessingNotices, interaction.showsProcessingNotices).environment(\.chatRenderingShowsMessageProcessingNotices, interaction.showsProcessingNotices)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            .zIndex(20)
                        }
                        // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END
                    }
                    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END
                }
                // WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110_END
            }
        }
        }
    }
    @ViewBuilder
    var assembledSenderActionOverlay: some View {
        observeSecondaryEntry { entry in
        Group {
            if !isReadOnlySystemConversation, let user = selectedSenderActionUser {
                UserQuickActionOverlay(
                    user: user,
                    showsMentionAction: conversation.kind == .group,
                    onDismiss: {
                        guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            selectedSenderActionUser = nil
                        }
                    },
                    onMention: {
                        guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                        guard conversation.kind == .group else {
                            selectedSenderActionUser = nil
                            return
                        }
                        mention(user)
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            selectedSenderActionUser = nil
                        }
                    },
                    onDetail: {
                        guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            selectedSenderActionUser = nil
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                            selectedUserProfile = user
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(30)
            }
        }
        }
    }

}

struct ChatMessageActionPreview: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.chatShowsMessageProcessingNotices) private var showsNotices
    let message: ChatMessage
    let conversationID: String
    var body: some View {
        ContactDirectoryPresentationView(store: state.contactStore) {
            state.conversationStore.observeConversationPresentation(id: conversationID) { conversation in
                assembledPreview(conversation: conversation)
            }
        }
    }
    private func assembledPreview(conversation: ConversationMessageSnapshot?) -> some View {
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = state.remarkPreferredDisplayName(identifiers: [message.senderId], candidates: [storedName],
            fallback: storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName)
        let reply = resolvedVisibleReplyPresentation(for: message,
            conversation: conversation ?? state.conversation(id: conversationID), state: state, showsProcessingNotices: showsNotices)
        let quote = reply.map { AnyView(ReplyQuoteBlock(quote: $0.quote, context: $0.context, outgoing: message.isOutgoing,
            compact: true, hasTransparentBackground: !message.isStickerMessage && AttachmentGIFPresentation.usesBorderlessContainer(message))) }
        return MessageActionPreviewContent(message: message, conversationID: conversationID,
            displaySenderName: name, certification: state.certificationPillSource.reference(forExactUID: message.senderId)?.chatFeatureReference,
            replyContent: quote, richContent: richContent)
    }
    private var richContent: AnyView {
        if message.isStickerMessage { return AnyView(StickerMessageView(message: message)) }
        else if message.kind == .file || message.kind == .image || message.kind == .video {
            return AnyView(FileBubbleContent(message: message, outgoing: message.isOutgoing, conversationID: conversationID))
        } else if message.kind == .contactCard {
            return AnyView(ContactCardBubbleContent(message: message, outgoing: message.isOutgoing) { _ in })
        } else { return AnyView(EmptyView()) }
    }
}

struct UserQuickActionOverlay: View {
    @EnvironmentObject private var state: AppState
    let user: IMUser
    var showsMentionAction = true
    let onDismiss: () -> Void
    let onMention: () -> Void
    let onDetail: () -> Void
    var body: some View {
        ContactDirectoryPresentationView(store: state.contactStore) {
            state.observeDepartmentSummary(for: user) { department in
                UserQuickActionContent(displayName: state.remarkPreferredDisplayName(for: user),
                    certification: state.certificationPillSource.reference(forExactUID: user.id)?.chatFeatureReference, department: department,
                    user: user, showsMentionAction: showsMentionAction,
                    onDismiss: onDismiss, onMention: onMention, onDetail: onDetail)
            }
        }
    }
}

extension ChatView {
    func observeSecondaryMessageEntry<Content: View>(_ message: ChatMessage,
        @ViewBuilder content: @escaping (ChatMessageEntryActions) -> Content) -> some View {
        observeSecondaryEntry { entry in
            content(ChatMessageEntryActions(toggleSelection: {
                guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                screenActions.forwarding.toggleBatchForwardSource(messageID: message.id, conversationID: conversationID)
            }, longPress: {
                guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                    dismissChatKeyboardFromTranscript(trigger: .longPress)
                    guard !isReadOnlySystemConversation else { return }
                    if isBatchForwardSelectionActive {
                        screenActions.forwarding.toggleBatchForwardSource(messageID: message.id, conversationID: conversationID)
                        return
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        screenActions.messages.refreshAppInteractionPolicy(force: true)
                        actionMessage = message
                    }
            }, read: {
                guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                    guard !isBatchForwardSelectionActive else { return }
                    guard !isReadOnlySystemConversation else { return }
                    guard isMessageAuthoredByCurrentUser(message) else {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("只能查看自己发送消息的已读状态")
                        return
                    }
                    // WDT_RECEIPT_DETAIL_SCOPE_20261023
                    screenActions.messages.prepareReadReceiptPanel(messageID: message.id, in: conversationID)
                    receiptMessage = message
            }, attachment: { message in
                guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                    if isBatchForwardSelectionActive {
                        screenActions.forwarding.toggleBatchForwardSource(messageID: message.id, conversationID: conversationID)
                        return
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    handleAttachmentTap(message)
            }))
        }
    }
}

struct MessageActionOverlay: View {
    let message: ChatMessage
    let conversationID: String
    let canShowReadActions: Bool
    let readActionTitle: String
    let canForward: Bool
    let forwardDisabledReason: String?
    let canSaveAttachment: Bool
    let canFavoriteAsset: Bool
    let canReportMessage: Bool
    let canAdminDeleteForAll: Bool
    let editDisabledReason: String?
    let recallDisabledReason: String?
    let onDismiss: () -> Void
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onRead: () -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onFavorite: () -> Void
    let onForward: () -> Void
    let onSaveAttachment: () -> Void
    let onReport: () -> Void
    let onDelete: () -> Void
    let onAdminDeleteForAll: () -> Void
    let onRecall: () -> Void

    var body: some View {
#if DEBUG
        let _ = ChatSecondarySurfaceDiagnostics.menu?(self)
#endif
        MessageActionOverlayContent(
            message: message,
            conversationID: conversationID,
            preview: AnyView(ChatMessageActionPreview(message: message, conversationID: conversationID)),
            canShowReadActions: canShowReadActions,
            readActionTitle: readActionTitle,
            canForward: canForward,
            forwardDisabledReason: forwardDisabledReason,
            canSaveAttachment: canSaveAttachment,
            canFavoriteAsset: canFavoriteAsset,
            canReportMessage: canReportMessage,
            canAdminDeleteForAll: canAdminDeleteForAll,
            editDisabledReason: editDisabledReason,
            recallDisabledReason: recallDisabledReason,
            descriptors: messageActionMenuDescriptors(message: message, canShowReadActions: canShowReadActions,
                readActionTitle: readActionTitle, canForward: canForward, forwardDisabledReason: forwardDisabledReason,
                canSaveAttachment: canSaveAttachment, canFavoriteAsset: canFavoriteAsset, canReportMessage: canReportMessage,
                canAdminDeleteForAll: canAdminDeleteForAll, editDisabledReason: editDisabledReason, recallDisabledReason: recallDisabledReason),
            onDismiss: onDismiss,
            onReact: onReact,
            onMoreReactions: onMoreReactions,
            onReply: onReply,
            onCopy: onCopy,
            onRead: onRead,
            onEdit: onEdit,
            onPin: onPin,
            onFavorite: onFavorite,
            onForward: onForward,
            onSaveAttachment: onSaveAttachment,
            onReport: onReport,
            onDelete: onDelete,
            onAdminDeleteForAll: onAdminDeleteForAll,
            onRecall: onRecall
        )
    }
}

#if DEBUG
@MainActor enum ChatSecondarySurfaceDiagnostics {
    static var menu: ((MessageActionOverlay) -> Void)?
}
#endif

func messageActionMenuDescriptors(message: ChatMessage, canShowReadActions: Bool, readActionTitle: String,
    canForward: Bool, forwardDisabledReason: String? = nil, canSaveAttachment: Bool, canFavoriteAsset: Bool,
    canReportMessage: Bool, canAdminDeleteForAll: Bool, editDisabledReason: String? = nil,
    recallDisabledReason: String?) -> [MessageActionMenuDescriptor] {
    chatMessageActionMenuDescriptors(message: message, canShowReadActions: canShowReadActions,
        readActionTitle: readActionTitle, canForward: canForward, forwardDisabledReason: forwardDisabledReason,
        canSaveAttachment: canSaveAttachment, canFavoriteAsset: canFavoriteAsset, canReportMessage: canReportMessage,
        canAdminDeleteForAll: canAdminDeleteForAll, editDisabledReason: editDisabledReason,
        recallDisabledReason: recallDisabledReason,
        ownDeletionTitle: OwnMessageDeletion.available(for: message, isCurrentSender: canShowReadActions).map {
            $0 == .failed ? "删除失败消息" : "删除该消息"
        })
}

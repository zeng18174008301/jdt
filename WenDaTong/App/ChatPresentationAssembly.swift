import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

extension ChatView {
    func chatMediaPresentation<Content: View>(_ content: Content) -> some View {
        content
        .sheet(item: $messagePresentation.reactionMessage /* WDT_IOS1_CHAT_STATE_20261023 */) { message in
            ReactionPickerView(message: message, conversationID: conversationID)
                .presentationDetentsCompat([.height(360)])
                .presentationDragIndicatorCompat(.visible)
                .presentationCornerRadiusCompat(30)
        }
        .sheet(item: $messagePresentation.receiptMessage /* WDT_IOS1_CHAT_STATE_20261023 */) { message in
            // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
            screenStores.files.observeUploadConfiguration(\.config.readReceiptsEnabled) { enabled in
                // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_BEGIN
                screenStores.conversations.observeConversationPresentation(id: conversationID) { snapshot in
                    let current = snapshot ?? conversation
                    ReadReceiptSheet(
                        message: current.messages.first(where: { $0.id == message.id }) ?? message,
                        conversation: current,
                        readReceiptsEnabled: enabled
                    )
                }
                // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_END
            }
            .presentationDetentsCompat([.medium, .large])
            // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END
        }
        .fullScreenCover(item: $previewImageAttachment) { item in
            AttachmentImagePreviewSheet(message: currentMessageSnapshot(for: item.message), conversationID: conversationID, localURL: item.localURL)
        }
        .fullScreenCover(item: $previewVideoAttachment) { item in
            AttachmentVideoPreviewSheet(message: currentMessageSnapshot(for: item.message), localURL: item.localURL)
        }
        .sheet(item: $attachmentShareItem) { item in
            AttachmentActivityView(activityItems: [item.url]) { completed, error in
                if let error {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("保存/分享失败：\(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重试"))")
                } else if completed {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("保存/分享已完成")
                }
            }
                .presentationDetentsCompat([.medium, .large])
        }
        .sheet(item: $attachmentPreviewDocument) { document in
            AttachmentQuickLookPreview(url: document.url)
                .ignoresSafeArea()
        }
        .sheet(item: $messagePresentation.selectedAttachmentMessage /* WDT_IOS1_CHAT_STATE_20261023 */) { message in
            AttachmentDetailSheet(
                message: conversation.messages.first(where: { $0.id == message.id }) ?? message,
                conversationID: conversationID,
                onForward: { message in
                    beginBatchForward(with: message)
                    selectedAttachmentMessage = nil
                }
            )
                .presentationDetentsCompat([.medium, .large])
        }
    }

    func chatMessagePresentation<Content: View>(_ content: Content) -> some View {
        content
        .sheet(item: $selectedUserProfile, onDismiss: {
            openPendingProfileConversationIfNeeded()
        }) { user in
            requiredContactsRouting(contactsFeatureRouting).makeUserProfile(user: user, onOpenConversation: { conversationID in
                pendingProfileConversationID = conversationID
                selectedUserProfile = nil
            }, sourceGroupID: conversation.kind == .group ? screenActions.history.remoteChannelID(for: conversation) : nil)
                .presentationDetentsCompat([.large])
        }
        .sheet(item: $messagePresentation.editMessage /* WDT_IOS1_CHAT_STATE_20261023 */) { message in
            MessageEditSheet(
                message: message,
                conversationID: conversationID,
                onAuthoritativeSuccess: { success in
                    guard editMessage?.id == success.messageID,
                          screenActions.messages.messageEditCurrentConversationID() == conversationID,
                          let currentConversation = screenStores.conversations.conversationMessageSnapshot(id: conversationID),
                          let currentMessage = currentConversation.messages.first(where: { $0.id == success.messageID }),
                          messageEditAuthoritativeSuccessIsCurrent(
                            success,
                            currentScope: screenActions.history.activeConversationHistoryScope(),
                            currentConversationID: screenActions.messages.messageEditCurrentConversationID() ?? "",
                            currentMessage: currentMessage
                          ) else { return false }
                    setScrollTarget(bottomAnchorID, source: .jumpToLatest, anchor: .bottom)
                    return true
                }
            )
                .presentationDetentsCompat([.medium])
        }
        .sheet(item: $messagePresentation.reportMessage /* WDT_IOS1_CHAT_STATE_20261023 */) { message in
            MessageReportSheet(message: message, conversationID: conversationID)
                .presentationDetentsCompat([.large])
        }
        .sheet(isPresented: $presentation.showBatchForwardTargets) {
            ForwardMessageTargetSheet(
                sourceConversationID: conversationID
            )
                .presentationDetentsCompat([.large])
        }
        .sheet(isPresented: $presentation.showPinnedMessages, onDismiss: {
            performPendingPinnedJumpIfNeeded()
        }) {
            PinnedMessagesSheet(
                conversationID: conversationID, // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110
                onSelect: { message in
                    pendingPinnedJumpMessage = message
                    showPinnedMessages = false
                },
                onUnpin: { message in
                    screenActions.messages.toggleMessagePinned(messageID: message.id, in: conversationID)
                }
            )
            .presentationDetentsCompat([.medium])
        }
    }

}
// WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_END // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

extension ChatView {
    var secondaryPinnedDetailAction: () -> Void {
        let entry = secondaryEntry()
        return {
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                        showDetail = false
                        if conversation.kind == .group {
                            screenActions.history.refreshPinnedMessages(for: conversationID, silent: false)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            showPinnedMessages = true
                        }

        }
    }
    // The sheet was already admitted: retain the original close ACK, including its original token.
    var secondaryAnnouncementCloseAction: () -> Void {
        {
                    if let announcementID = openedGroupAnnouncementID {
                        screenActions.people.markGroupAnnouncementRead(groupID: currentGroup.id, announcementID: announcementID)
                    }

        }
    }
    var secondaryDeletionActions: ChatDeletionActions {
        let entry = secondaryEntry()
        return ChatDeletionActions(adminDelete: { message in
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
            screenActions.messages.adminDeleteMessageForAll(messageID: message.id, in: conversationID)
        }, failedDelete: { message in
            guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
            Task {
                guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }
                await screenActions.messages.deleteOwnMessage(messageID: message.id, in: conversationID, as: .failed)
            }
        })
    }
}

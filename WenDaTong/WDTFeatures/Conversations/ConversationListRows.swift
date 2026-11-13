// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4Features

typealias ConversationTypeBadge = IM4Features.ConversationTypeBadge

extension CertificationPresentation {
    var conversationFeatureInput: ConversationCertificationInput {
        ConversationCertificationInput(visibleLabel: visibleLabel, accessibilityLabel: accessibilityLabel,
            styleToken: styleToken, revision: revision, generation: generation)
    }
}

struct ConversationInteractiveRow: View, Equatable {
    let rowModel: ConversationRowInput
    let directCertificationPresentation: CertificationPresentation?
    let mentionTarget: String
    let unreadMention: MentionPreview?
    let systemNoticeAvatarURL: String
    var onTap: () -> Void
    var onLongPress: () -> Void
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rowModel == rhs.rowModel && lhs.mentionTarget == rhs.mentionTarget
            && lhs.unreadMention == rhs.unreadMention && lhs.systemNoticeAvatarURL == rhs.systemNoticeAvatarURL
    }
    var body: some View {
        ConversationInteractiveRowContent(rowModel: rowModel, mentionTarget: mentionTarget,
            unreadMention: unreadMention,
            systemNoticeAvatarURL: systemNoticeAvatarURL, avatar: { avatar }, certification: {
                CertificationPillView(exactUID: rowModel.rowPresentation.directCertificationUID, compact: true,
                    presentation: directCertificationPresentation)
            }, onTap: onTap, onLongPress: onLongPress)
    }
    @ViewBuilder private var avatar: some View {
        let p = rowModel.rowPresentation
        if rowModel.kind == .system {
            SystemNoticeLogoAvatar(size: 56)
        } else if rowModel.kind == .group {
            GroupAvatarView(name: rowModel.displayTitle, seed: rowModel.accentHex, size: 56, imageURL: p.avatarURL,
                avatarVersion: p.avatarVersion, avatarUpdatedAt: p.avatarUpdatedAt, imageCacheKey: p.avatarImageCacheKey)
        } else {
            AvatarView(name: rowModel.displayTitle, seed: rowModel.accentHex, size: 56, imageURL: p.avatarURL,
                avatarVersion: p.avatarVersion, avatarUpdatedAt: p.avatarUpdatedAt, certification: directCertificationPresentation)
        }
    }
}

private struct SystemConversationAvatar: View {
    let size: CGFloat
    var imageURL: String = ""

    var body: some View {
        SystemNoticeLogoAvatar(size: size)
    }
}

struct ConversationActionSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let conversationID: String

    private var conversation: ConversationMessageSnapshot {
        state.conversation(id: conversationID)
    }

    private var unreadBadgeColor: Color {
        conversation.isMuted ? IMColor.muted.opacity(0.62) : IMColor.danger
    }

    private var directPeer: IMUser? {
        guard conversation.kind == .direct else { return nil }
        return state.directConversationProfilePeer(for: conversation)
    }

    private var directCertificationUID: String {
        guard conversation.kind == .direct else { return "" }
        return state.directConversationCertificationUID(for: conversation) ?? directPeer?.id ?? ""
    }

    private var avatarURL: String {
        conversation.kind == .direct ? directPeer?.displayAvatarURL ?? "" : conversation.avatarURL
    }

    private var avatarVersion: String {
        conversation.kind == .direct ? directPeer?.avatarVersion ?? "" : conversation.avatarVersion
    }

    private var avatarUpdatedAt: String {
        conversation.kind == .direct ? directPeer?.avatarUpdatedAt ?? "" : conversation.avatarUpdatedAt
    }

    private var displayTitle: String {
        if conversation.kind == .direct, let participant = directPeer {
            return state.remarkPreferredDisplayName(for: participant)
        }
        return conversation.title
    }

    @ViewBuilder
    private var avatar: some View {
        if conversation.kind == .system {
            SystemConversationAvatar(size: 46, imageURL: state.systemNoticeAvatarURL)
        } else if conversation.kind == .group {
            GroupAvatarView(name: displayTitle, seed: conversation.accentHex, size: 46, imageURL: avatarURL, avatarVersion: avatarVersion, avatarUpdatedAt: avatarUpdatedAt, imageCacheKey: state.groupAvatarCacheKey(for: conversation))
        } else {
            AvatarView(name: displayTitle, seed: conversation.accentHex, size: 46, imageURL: avatarURL, avatarVersion: avatarVersion, avatarUpdatedAt: avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: directCertificationUID)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        }
    }

    // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_BEGIN
    var body: some View {
        // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
        state.conversationStore.observeConversationPresentation(id: conversationID) { _ in
            conversationContent
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END

    @ViewBuilder
    private var conversationContent: some View {
        if conversation.kind == .direct {
            ContactDirectoryPresentationView(store: state.contactStore) { actionContent }
        } else {
            actionContent
        }
    }
    // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_END

    private var actionContent: some View {
        ConversationActionSheetContent(displayTitle: displayTitle, isDirect: conversation.kind == .direct,
            isPinned: conversation.isPinned, isMuted: conversation.isMuted, avatar: { avatar }, certification: {
                CertificationPillView(exactUID: directCertificationUID, compact: true)
            }, summary: {
                state.tenantInteractionStore.observe(\.showsProcessingNotices) { showsNotices in
                    ConversationActionSummaryContent(text: state.visibleConversationLastMessage(conversation, showsProcessingNotices: showsNotices))
                }
            }, onClose: { dismiss() }, onTogglePinned: { state.togglePinned(conversationID) },
            onToggleMuted: { state.toggleMuted(conversationID) }, onDelete: { state.deleteConversation(conversationID) })
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

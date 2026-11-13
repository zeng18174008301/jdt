import IM4Features
import SwiftUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import UIKit

struct ConversationTopCard: View {
    @EnvironmentObject private var state: AppState
    let enterprise: Enterprise
    var openEnterprise: () -> Void
    var openConversation: (String) -> Void

    var body: some View {
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
        state.appPolicyPresentationStore.observe(\.workspaceSwitchDisabled) { _ in
            EnterpriseHeaderCard(
                enterprise: enterprise,
                isSwitchingEnabled: state.canOpenEnterpriseSwitcher(for: enterprise),
                action: openEnterprise
            ) {
                QuickAddMenu(openConversation: openConversation)
            }
        }
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
    }
}

// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
typealias QuickAddFlow = IM4Features.QuickAddFlow
typealias QuickAddPresentationState = IM4Features.QuickAddPresentationState
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

private struct QuickAddMenu: View {
    @EnvironmentObject private var state: AppState
    var openConversation: (String) -> Void
    @State private var presentation = QuickAddPresentationState()

    var body: some View {
        QuickAddMenuButton(onOpen: { presentation.presentActions() })
        .sheet(isPresented: $presentation.isPresented, onDismiss: {
            presentation.dismiss()
        }) {
            // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
            state.tenantClientPolicyStore.observe(\.allowsMemberGroupCreation) { enabled in
                // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
                state.enterpriseMembershipStore.observe(\.current.role) { role in
                    sheetHost(canCreateGroup: AppState.canCreateGroupChat(role: role, enabled: enabled))
                }
                // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
            }
            // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        }
    }

    private func sheetHost(canCreateGroup: Bool) -> some View {
        QuickAddSheetHost(
            flow: $presentation.flow,
            canCreateGroup: canCreateGroup, // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            select: { presentation.select($0) },
            close: { presentation.dismiss() },
            openConversation: { conversationID in
                presentation.dismiss()
                openConversation(conversationID)
            }
        )
        .environmentObject(state)
    }
}

private struct QuickAddSheetHost: View {
    @Binding var flow: QuickAddFlow
    let canCreateGroup: Bool
    let select: (QuickAddFlow) -> Void
    let close: () -> Void
    let openConversation: (String) -> Void

    @ViewBuilder
    var body: some View {
        switch flow {
        case .actions:
            QuickAddActionSheet(
                canCreateGroup: canCreateGroup,
                onClose: close,
                onDirectChat: { select(.directChat) },
                onFindUser: { select(.findUser) },
                onCreateGroup: { select(.createGroup) }
            )
            .presentationDetentsCompat([.height(canCreateGroup ? 320 : 260)])
            .presentationDragIndicatorCompat(.hidden)
            .presentationCornerRadiusCompat(30)
            .presentationBackgroundUltraThinMaterialCompat()
        case .directChat:
            StartDirectChatSheet(openConversation: openConversation)
                .presentationDetentsCompat([.medium, .large])
                .presentationCornerRadiusCompat(30)
        case .createGroup:
            CreateGroupSheet(openConversation: openConversation)
                .presentationDetentsCompat([.large])
                .presentationCornerRadiusCompat(30)
        case .findUser:
            FindUserSheet()
                .presentationDetentsCompat([.large])
                .presentationCornerRadiusCompat(30)
        }
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct CreateGroupSheet: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var query = ""
    @State private var selectedIDs: Set<String> = []
    @State private var isSubmitting = false
    var openConversation: (String) -> Void

    private var candidates: [IMUser] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = state.contacts
            .filter { $0.id != renderedCurrentUser.id }
            .sorted {
                state.remarkPreferredDisplayName(for: $0)
                    .localizedCaseInsensitiveCompare(state.remarkPreferredDisplayName(for: $1)) == .orderedAscending
            }
        guard !keyword.isEmpty else { return source }
        return source.filter { user in
            IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: keyword
            )
        }
    }

    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_BEGIN
    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.identity)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        ContactDirectoryPresentationView(store: state.contactStore) { directoryContent }
    }
    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_END

    private var directoryContent: some View {
        let choices = candidates
        return CreateGroupContent(query: $query, isEmpty: choices.isEmpty, groupName: $groupName, selectedCount: selectedIDs.count,
            isSubmitting: isSubmitting, onSubmit: submit, onClose: { dismiss() }) {
            ForEach(choices) { user in
                selectableUserRow(user)
            }
        }
    }

    private func selectableUserRow(_ user: IMUser) -> some View {
        let displayName = state.remarkPreferredDisplayName(for: user)
        return CreateGroupMemberContent(userID: user.id, displayName: displayName, isSelected: selectedIDs.contains(user.id),
            visibleUserID: user.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? user.id : user.userID,
            onCopy: state.copyUserID,
            onSelect: {
                if selectedIDs.contains(user.id) {
                    selectedIDs.remove(user.id)
                } else {
                    selectedIDs.insert(user.id)
                }
            }, avatar: {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.avatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }, certification: { CertificationPillView(exactUID: user.id, compact: true) })
        .certificationAccessibilityLabel(
            "选择成员 \(displayName)",
            reference: state.certificationPillSource.reference(forExactUID: user.id)
        ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let conversationID = await state.createGroup(name: groupName, memberIDs: Array(selectedIDs))
            isSubmitting = false
            if let conversationID {
                dismiss()
                openConversation(conversationID)
            }
        }
    }


}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private struct StartDirectChatSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var openConversation: (String) -> Void

    private var contacts: [IMUser] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = state.contacts.sorted {
            state.remarkPreferredDisplayName(for: $0)
                .localizedCaseInsensitiveCompare(state.remarkPreferredDisplayName(for: $1)) == .orderedAscending
        }
        guard !keyword.isEmpty else { return source }
        return source.filter { user in
            IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: keyword
            )
        }
    }

    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_BEGIN
    var body: some View {
        ContactDirectoryPresentationView(store: state.contactStore) {
            // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
            state.conversationStore.observeConversationCollection({
                $0.filter { $0.kind == .direct }.map(\.withoutMessages)
            }) { conversations in
                directoryContent(conversations: conversations.map { ConversationMessageSnapshot(conversation: $0, messages: []) })
            }
            // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_END

    private func directoryContent(conversations: [ConversationMessageSnapshot]) -> some View { // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110
        let choices = contacts
        return StartDirectChatContent(query: $query, isEmpty: choices.isEmpty, onClose: { dismiss() }) {
            ForEach(choices) { user in
                directContactRow(user, conversations: conversations)
            }
        }
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
    private func directContactRow(_ user: IMUser, conversations: [ConversationMessageSnapshot]) -> some View {
        let existingConversationID = state.directConversationID(for: user, in: conversations)
        // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END
        let displayName = state.remarkPreferredDisplayName(for: user)
        return DirectChatContactContent(userID: user.id, displayName: displayName, hasConversation: existingConversationID != nil,
            onSelect: {
                guard let conversationID = state.openOrCreateDirectConversationID(for: user, activateChatsTab: false) else { return }
                dismiss()
                openConversation(conversationID)
            }, avatar: {
                AvatarView(
                                    name: displayName,
                                    seed: user.avatarSeed,
                                    size: 48,
                                    imageURL: user.avatarURL,
                                    avatarVersion: user.avatarVersion,
                                    avatarUpdatedAt: user.avatarUpdatedAt,
                                    certificationReference: state.certificationPillSource.reference( // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                                        forExactUID: user.id
                                    )
                                )
            }, certification: { CertificationPillView(exactUID: user.id, compact: true) })
        .certificationAccessibilityLabel(
            "发起单聊 \(displayName)",
            reference: state.certificationPillSource.reference(forExactUID: user.id)
        ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
    }


} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

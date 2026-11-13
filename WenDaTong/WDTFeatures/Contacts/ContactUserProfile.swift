import IM4Features
import SwiftUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

struct UserProfileView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let user: IMUser
    var onOpenConversation: ((String) -> Void)? = nil
    var sourceGroupID: String? = nil
    @State private var sourceScope = ""
    @State private var showRemarkEditor = false
    @State private var showCardShareSheet = false
    @State private var showBlockConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isApplyingFriend = false
    @State private var friendRequestSent = false
    @State private var showAvatarPreview = false

    private typealias ProfileActionMode = IM4Features.ContactProfileActionMode

    private var liveUser: IMUser {
        state.liveProfileUser(for: user)
    }

    private var displayName: String {
        state.userProfileDisplayName(for: liveUser)
    }

    private var visiblePhone: String? {
        let phone = liveUser.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else { return nil }
        return phone
    }

    private var isSelfProfile: Bool {
        state.isCurrentUserProfile(liveUser)
    }

    private var isCancelledProfile: Bool {
        state.isCancelledProfile(liveUser)
    }

    private var previewAvatarSource: String? {
        OtherUserAvatarPreviewPolicy.source(
            for: liveUser,
            isSelf: isSelfProfile,
            isCancelled: isCancelledProfile
        )
    }

    private var isFriendProfile: Bool {
        state.canStartDirectConversation(with: liveUser)
    }

    private var isBlockedProfile: Bool {
        state.isBlockedProfile(liveUser)
    }

    private var profileUserID: String {
        let value = liveUser.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? liveUser.id : value
    }

    private var hasPendingFriendRequest: Bool {
        friendRequestSent || state.hasPendingOutgoingFriendRequest(with: liveUser)
    }

    private var profileActionMode: ProfileActionMode {
        if isSelfProfile { return .selfProfile }
        if isCancelledProfile { return .cancelled }
        if isBlockedProfile { return .blocked }
        if isFriendProfile { return .friend }
        if hasPendingFriendRequest { return .pendingFriendRequest }
        return .nonFriend
    }

    private var addFriendButtonTitle: String {
        if hasPendingFriendRequest { return FriendAddPresentation.waitingTitle }
        if isApplyingFriend { return "发送中" }
        return FriendAddPresentation.actionTitle
    }

    private var addFriendButtonDisabled: Bool {
        hasPendingFriendRequest || isApplyingFriend
    }

    private var sourceGroupAllowsFriendApply: Bool {
        guard let sourceGroupID else { return true }
        return sourceScope == state.contentCacheScopeKey
            && state.group(id: sourceGroupID)?.memberFriendApplyEnabled == true
    }

    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_BEGIN
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_BEGIN
    var body: some View {
        // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
        ContactDirectoryPresentationView(store: state.contactStore) {
            state.tenantInteractionStore.observe(\.currentRules) { rules in
                // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
                state.tenantClientPolicyStore.observe(\.allowsMemberFriendRequests) { enabled in
                    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
                    state.enterpriseMembershipStore.observe(\.current.role) { role in
                        directoryContent(rules: rules, enterpriseRole: role, canInitiateFriendRequests: AppState.canInitiateFriendRequest(role: role, enabled: enabled))
                    }
                    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
                }
                // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
            }
        }
        // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END
    }
    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_END

    @ViewBuilder
    private func directoryContent(rules: TenantInteractionPolicy, enterpriseRole: String, canInitiateFriendRequests: Bool) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        if let sourceGroupID {
            GroupSnapshotView(store: state.contactStore, groupID: sourceGroupID) { relationshipContent(rules: rules, enterpriseRole: enterpriseRole, canInitiateFriendRequests: canInitiateFriendRequests) } // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        } else {
            relationshipContent(rules: rules, enterpriseRole: enterpriseRole, canInitiateFriendRequests: canInitiateFriendRequests) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END

    private func relationshipContent(rules: TenantInteractionPolicy, enterpriseRole: String, canInitiateFriendRequests: Bool) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        let identities = Set(state.userIdentityCandidates(for: liveUser))
        let store = state.contactStore
        return PublisherSnapshotView(
            initialValue: store.hasPendingOutgoingFriendRequest(identities: identities),
            updates: store.pendingOutgoingFriendRequestUpdates(identities: identities)
        ) { _ in
            // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
            PublisherSnapshotView(
                initialValue: store.blacklistIDs(matching: identities),
                updates: store.blacklistIDUpdates(matching: identities)
            ) { _ in
                profileContent(rules: rules, enterpriseRole: enterpriseRole, canInitiateFriendRequests: canInitiateFriendRequests) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
            }
            // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_END

    private func profileContent(rules: TenantInteractionPolicy, enterpriseRole: String, canInitiateFriendRequests: Bool) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        ContactProfileContent(actionMode: profileActionMode,
            canBlock: TenantInteractionPolicy.permitsOrdinaryAction(role: enterpriseRole, enabled: rules.allowMemberBlacklist),
            canDelete: TenantInteractionPolicy.permitsOrdinaryAction(role: enterpriseRole, enabled: rules.allowMemberFriendDelete),
            showsAddFriend: sourceGroupAllowsFriendApply && (canInitiateFriendRequests || hasPendingFriendRequest),
            showsFriendRequestsDisabled: sourceGroupID == nil, addFriendButtonTitle: addFriendButtonTitle,
            addFriendButtonDisabled: addFriendButtonDisabled, summary: { profileSummaryCard },
            onStartChat: startProfileConversation, onCall: { state.startOutgoingVoiceCall(to: liveUser) },
            onRemark: { showRemarkEditor = true }, onShare: { showCardShareSheet = true },
            onBlock: { showBlockConfirm = true }, onDelete: { showDeleteConfirm = true }, onAddFriend: requestFriend)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        .fullScreenCover(isPresented: $showAvatarPreview) {
            if let previewAvatarSource {
                UserAvatarPreviewSheet(
                    user: liveUser,
                    displayName: displayName,
                    source: previewAvatarSource
                )
            }
        }
        .sheet(isPresented: $showRemarkEditor) {
            ContactRemarkEditSheet(user: liveUser)
                .presentationDetentsCompat([.height(310)])
        }
        .sheet(isPresented: $showCardShareSheet) {
            ContactCardShareSheet(user: liveUser)
                .presentationDetentsCompat([.medium, .large])
        }
        .alert("拉黑 \(displayName)？", isPresented: $showBlockConfirm) {
            Button("取消", role: .cancel) {}
            Button("拉黑", role: .destructive) {
                state.blockContact(liveUser)
            }
        } message: {
            Text("拉黑后该用户会从通讯录和单聊入口移除，并进入黑名单。")
        }
        .alert("删除好友 \(displayName)？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除好友", role: .destructive) {
                state.deleteContact(liveUser)
                dismiss()
            }
        } message: {
            Text("删除后会从通讯录和单聊入口移除该好友。")
        }
        .onAppear {
            state.refreshAppInteractionPolicy(force: true)
            if sourceScope.isEmpty { sourceScope = state.contentCacheScopeKey }
            if let sourceGroupID, sourceScope == state.contentCacheScopeKey {
                state.loadGroupDetailIfNeeded(groupID: sourceGroupID, force: true, includeSecondaryData: false)
            }
        }
    }

    private func startProfileConversation() {
        guard let conversationID = state.openOrCreateDirectConversationID(for: liveUser, activateChatsTab: false) else { return }
        if let onOpenConversation {
            onOpenConversation(conversationID)
        } else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("已进入与 \(displayName) 的会话")
            dismiss()
        }
    }

    private func requestFriend() {
        guard !addFriendButtonDisabled else { return }
        Task {
            isApplyingFriend = true
            let sent = await state.applyFriend(to: liveUser, source: sourceGroupID == nil ? "profile" : "group", sourceGroupID: sourceGroupID)
            isApplyingFriend = false
            if sent {
                friendRequestSent = true
            }
        }
    }

    private var profileSummaryCard: some View {
        ContactProfileSummaryContent(displayName: displayName, enterprise: liveUser.enterprise, profileUserID: profileUserID,
            remark: state.contactRemark(for: liveUser), visiblePhone: visiblePhone, isCancelledProfile: isCancelledProfile,
            isBlockedProfile: isBlockedProfile, showsAvatarPreview: previewAvatarSource != nil, avatar: { profileAvatarImage },
            certification: { CertificationPillView(exactUID: liveUser.id, maximumLineCount: nil) },
            department: {
                state.observeDepartmentSummary(for: liveUser, fullPath: true) { department in
                    if let department { ProfileInfoRowContent(title: "部门", value: department) }
                }
            }, onClose: { dismiss() }, onShowAvatarPreview: {
                guard !showAvatarPreview else { return }
                showAvatarPreview = true
            }, onCopy: state.copyUserID)
    }

    private var profileAvatarImage: some View {
        AvatarView(
            name: displayName,
            seed: liveUser.avatarSeed,
            size: 72,
            imageURL: liveUser.displayAvatarURL,
            avatarVersion: liveUser.avatarVersion,
            avatarUpdatedAt: liveUser.avatarUpdatedAt,
            certificationReference: state.certificationPillSource.reference(forExactUID: liveUser.id) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        )
    }
}

private typealias ProfileInlineActionButton = IM4Features.ProfileInlineActionButton

private struct ContactRemarkEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let user: IMUser
    @State private var draftRemark = ""
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    private var remarkCount: Int {
        FriendRemarkInputPolicy.unicodeCodePointCount(draftRemark)
    }

    private var validationMessage: String? {
        FriendRemarkInputPolicy.validationMessage(for: draftRemark)
    }

    private func save(_ remark: String) {
        guard !isSaving else { return }
        if let validationMessage = FriendRemarkInputPolicy.validationMessage(for: remark) {
            saveErrorMessage = validationMessage
            return
        }
        isSaving = true
        saveErrorMessage = nil
        state.setContactRemark(remark, for: user) { result in
            isSaving = false
            switch result {
            case .success:
                dismiss()
            case .failure(let failure):
                saveErrorMessage = failure.message
            }
        }
    }

    var body: some View {
        ContactRemarkEditContent(draftRemark: $draftRemark, remarkCount: remarkCount,
            maximumLength: FriendRemarkInputPolicy.maxUnicodeCodePoints, validationMessage: validationMessage,
            saveErrorMessage: saveErrorMessage, isSaving: isSaving, onSave: save)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            let currentRemark = state.contactRemark(for: user)
            draftRemark = currentRemark == "未设置" ? "" : currentRemark
        }
        .onChangeCompat(of: draftRemark) { _, _ in
            saveErrorMessage = nil
        }
    }
}

private struct ContactCardShareSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let user: IMUser

    private var displayName: String {
        state.remarkPreferredDisplayName(for: user)
    }

    private func displayName(for conversation: ConversationMessageSnapshot) -> String {
        guard conversation.kind == .direct,
              let peer = state.directConversationCallPeer(for: conversation) else {
            return conversation.title
        }
        return state.remarkPreferredDisplayName(for: peer)
    }

    private func shareTargetTag(for kind: ConversationKind) -> (title: String, color: Color)? {
        switch kind {
        case .group:
            return ("群聊", IMColor.brand)
        case .system:
            return ("系统", IMColor.cyan)
        case .direct:
            return nil
        }
    }

    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_BEGIN
    var body: some View {
        ContactDirectoryPresentationView(store: state.contactStore) {
            // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
            state.conversationStore.observeConversationCollection({ $0.filter { $0.kind != .system } }) { conversations in
                directoryContent(shareTargets: conversations.map { ConversationMessageSnapshot(conversation: $0, messages: []) })
            }
            // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_END

    private func directoryContent(shareTargets: [ConversationMessageSnapshot]) -> some View { // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110
        ContactCardShareContent(displayName: displayName, avatar: {
            AvatarView(name: displayName, seed: user.avatarSeed, size: 54, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        }, certification: { CertificationPillView(exactUID: user.id, compact: true) }) {
            ForEach(shareTargets) { conversation in
                let targetDisplayName = displayName(for: conversation)
                ContactCardShareTargetContent(name: targetDisplayName, tag: shareTargetTag(for: conversation.kind),
                    onSelect: {
                        state.shareContactCard(user, to: conversation.id)
                        dismiss()
                    }, avatar: {
                        if conversation.kind == .group {
                            GroupAvatarView(name: targetDisplayName, seed: conversation.accentHex, size: 42, imageURL: conversation.avatarURL, avatarVersion: conversation.avatarVersion, avatarUpdatedAt: conversation.avatarUpdatedAt, imageCacheKey: state.groupAvatarCacheKey(for: conversation))
                        } else {
                            AvatarView(name: targetDisplayName, seed: conversation.accentHex, size: 42, certificationReference: state.certificationPillSource.reference(forExactUID: conversation.participants.first?.id ?? "")) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                        }
                    }, certification: {
                        if conversation.kind == .direct {
                            CertificationPillView(
                                exactUID: conversation.participants.first?.id ?? "",
                                compact: true
                            )
                        }
                    }
                )
            }
        }
    }
}

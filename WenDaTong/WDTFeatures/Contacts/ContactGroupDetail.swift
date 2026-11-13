import IM4Features
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
import Combine // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110 // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct GroupDetailView: View {
    @Environment(\.contactsFeatureRouting) private var contactsFeatureRouting
    @Environment(\.chatFeatureRouting) private var chatFeatureRouting
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    let group: GroupInfo
    var onSearchHistory: (() -> Void)? = nil
    var onPinnedMessages: (() -> Void)? = nil
    @State private var activeSheet: GroupDetailSheet?
    @State private var previewMember: IMUser?
    @State private var previewConversationRoute: ContactsConversationRoute?
    @State private var pendingPreviewConversationID: String?
    @State private var forcedAuthPromptDeferralToken: UUID?
    @State private var showLeaveDetail = false
    @State private var showDissolveDetail = false
    @State private var dissolvePreview: RemoteGroupDissolvePreview?
    @State private var dissolvePreviewScopeKey: String?
    @State private var dissolvePreviewError: String?
    @State private var isDissolvePreviewLoading = false
    @State private var isLifecycleActionRunning = false
    @State private var lifecycleInlineMessage: String?
    @State private var lifecycleActionScopeKey = ""
    @State private var lifecycleActionActorID = ""
    @State private var lifecycleActionGroupID = ""

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var canManage: Bool {
        state.canManageGroup(currentGroup)
    }

    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
    private var isNotificationMuted: Bool {
        GroupNotificationMuteProjection.isMuted(group: currentGroup, conversation: nil)
    }
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END

    private var isCurrentUserOwner: Bool {
        currentGroup.isCurrentUserOwner || state.isGroupOwner(renderedCurrentUser, in: currentGroup)
    }

    private func lifecycleActionContextIsCurrent(groupID: String, requiresOwner: Bool) -> Bool {
        guard !lifecycleActionScopeKey.isEmpty,
              lifecycleActionGroupID == groupID,
              state.contentCacheScopeKey == lifecycleActionScopeKey,
              state.currentUser.id == lifecycleActionActorID,
              let refreshedGroup = state.group(id: groupID) else {
            return false
        }
        let isOwner = refreshedGroup.isCurrentUserOwner
            || state.isGroupOwner(state.currentUser, in: refreshedGroup)
        return requiresOwner ? isOwner : !isOwner
    }

    private func captureLifecycleActionContext(groupID: String) {
        lifecycleActionScopeKey = state.contentCacheScopeKey
        lifecycleActionActorID = state.currentUser.id
        lifecycleActionGroupID = groupID
    }

    private func clearLifecycleActionContext() {
        lifecycleActionScopeKey = ""
        lifecycleActionActorID = ""
        lifecycleActionGroupID = ""
        dissolvePreviewScopeKey = nil
    }

    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
    private struct Pins: Equatable {
        let isPinned: Bool
        let messageCount: Int

        init(conversation: ConversationMessageSnapshot?) {
            isPinned = conversation?.isPinned ?? false
            messageCount = conversation?.messages.filter { $0.isPinned && $0.status != .recalled }.count ?? 0
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END

    private var roleTitle: String? {
        switch currentGroup.presentedRole {
        case "owner": return "群主"
        case "admin": return "管理员"
        case "member": return "成员"
        default: return nil
        }
    }

    private var roleColor: Color {
        roleTitle == "成员" ? IMColor.muted : IMColor.success
    }

    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
    private var observedMyGroupNicknameRow: some View {
        let store = state.contactStore.groupSelfProfiles
        let key = state.groupMemberProfileCacheKey(groupID: currentGroup.id)
        return PublisherSnapshotView(
            initialValue: store.snapshot(for: key).nickname,
            updates: store.updates(for: key, \.nickname)
        ) { nickname in
            GroupDetailMenuRow(
                symbol: "person.text.rectangle.fill",
                title: "我的群昵称",
                subtitle: nickname.isEmpty ? "未设置，显示全局昵称" : nickname
            ) {
                activeSheet = .myNickname
            }
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.identity)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        GroupSnapshotView(store: state.contactStore, groupID: group.id) {
            // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
            let store = state.conversationStore
            let id = currentGroup.id
            PublisherSnapshotView(
                initialValue: Pins(conversation: store.conversationMessagePresentation(id: id)),
                updates: store.conversationMessageUpdates(id: id)
                    .map(Pins.init(conversation:))
                    .removeDuplicates()
                    .eraseToAnyPublisher()
            ) { pins in
                // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
                state.tenantInteractionStore.observe(\.currentRules.allowMemberGroupLeave) { allowed in
                    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
                    state.tenantClientPolicyStore.observe(\.showsGroupMemberCount) { visible in
                        // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
                        state.enterpriseMembershipStore.observe(\.current.role) { role in
                            groupContent(pins: pins, memberLeaveAllowed: allowed, showsGroupCount: visible, enterpriseRole: role)
                        }
                        // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
                    }
                    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
                }
                // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END
            }
            // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    private func groupSummary(showsGroupCount: Bool) -> some View {
        let memberSummary = [
            state.visibleGroupMemberCount(currentGroup.memberCount, showsCount: showsGroupCount).map { "\($0) 人" },
            currentGroup.owner.isEmpty ? nil : "群主 \(currentGroup.owner)"
        ].compactMap { $0 }.joined(separator: " · ")
        return GroupDetailSummaryContent(name: currentGroup.name, memberSummary: memberSummary, roleTitle: roleTitle,
            roleColor: roleColor, canManage: canManage, notice: currentGroup.notice, description: currentGroup.groupDescription,
            avatar: {
                GroupAvatarView(name: currentGroup.name, seed: 0x5D6BFF, size: 56, imageURL: currentGroup.avatarURL,
                    avatarVersion: currentGroup.avatarVersion, avatarUpdatedAt: currentGroup.avatarUpdatedAt,
                    imageCacheKey: state.groupAvatarCacheKey(groupID: currentGroup.id, avatarURL: currentGroup.avatarURL,
                        avatarVersion: currentGroup.avatarVersion, avatarUpdatedAt: currentGroup.avatarUpdatedAt))
            }, onEdit: { activeSheet = .profile })
    }

    private func handleGroupDetailAction(_ action: GroupDetailMenuAction) {
        switch action {
        case .announcement:
            activeSheet = .announcement
        case .files:
            activeSheet = .files
        case .pinnedMessages:
            onPinnedMessages?()
        case .togglePinned:
            state.togglePinned(currentGroup.id)
        case .muteAll:
            activeSheet = .muteAll
        case .muteList:
            activeSheet = .muteList
        case .mute:
            activeSheet = .mute
        case .memberFriendApply:
            activeSheet = .memberFriendApply
        case .historyVisibility:
            activeSheet = .historyVisibility
        case .joinApproval:
            if forcedAuthPromptDeferralToken == nil {
                forcedAuthPromptDeferralToken = state.beginForcedAppPolicyAuthPromptDeferral()
            }
            activeSheet = .joinApproval
        case .dissolve:
            guard !isLifecycleActionRunning else { return }
            captureLifecycleActionContext(groupID: currentGroup.id)
            lifecycleInlineMessage = nil
            dissolvePreview = nil
            dissolvePreviewScopeKey = nil
            dissolvePreviewError = nil
            showDissolveDetail = true
        case .leave:
            guard !isLifecycleActionRunning else { return }
            captureLifecycleActionContext(groupID: currentGroup.id)
            lifecycleInlineMessage = nil
            showLeaveDetail = true
        }
    }

    @ViewBuilder
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
    private func groupContent(pins: Pins, memberLeaveAllowed: Bool?, showsGroupCount: Bool, enterpriseRole: String) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        let isConversationPinned = pins.isPinned
        let pinnedMessageCount = pins.messageCount
        // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END
        NavigationStackCompat {
            GroupDetailScreenContent(summary: groupSummary(showsGroupCount: showsGroupCount),
                members: {
                    GroupDetailMemberGrid(group: currentGroup, onMember: { previewMember = $0 }) {
                        activeSheet = .members
                    }
                }, menu: GroupDetailMenuContent(canManage: canManage,
                    canLeave: TenantInteractionPolicy.permitsOrdinaryAction(role: enterpriseRole, enabled: memberLeaveAllowed),
                    isCurrentUserOwner: isCurrentUserOwner, isConversationPinned: isConversationPinned,
                    pinnedMessageCount: pinnedMessageCount, allMuteStatus: currentGroup.allMuteStatusText(),
                    muteListStatus: currentGroup.muteListStatusText, isNotificationMuted: isNotificationMuted,
                    inviteConfirmRequired: currentGroup.inviteConfirmRequired,
                    memberFriendApplyEnabled: currentGroup.memberFriendApplyEnabled,
                    historyVisibilityStatus: currentGroup.historyVisibilityStatusText,
                    nickname: { observedMyGroupNicknameRow }, onAction: handleGroupDetailAction),
                onClose: { dismiss() })
	                .navigationTitle("")
	                .navigationBarTitleDisplayMode(.inline)
	                .navigationDestinationCompat(item: $activeSheet) { sheet in
	                    switch sheet {
	                    case .members:
	                        GroupMemberManagementView(groupID: currentGroup.id)
	                    case .announcement:
	                        GroupAnnouncementSheet(group: currentGroup)
	                    case .files:
	                        GroupFilesSheet(group: currentGroup)
	                    case .profile:
	                        GroupProfileEditSheet(group: currentGroup)
	                    case .myNickname:
	                        GroupNicknameEditSheet(groupID: currentGroup.id)
		                    case .muteAll:
		                        GroupMuteAllSheet(group: currentGroup)
		                    case .mute:
	                        GroupMuteSheet(group: currentGroup)
	                    case .muteList:
	                        GroupMuteListSheet(group: currentGroup)
		                    case .joinApproval:
		                        GroupJoinApprovalSheet(group: currentGroup)
		                            .onDisappear {
		                                endForcedAuthPromptDeferralIfNeeded()
		                            }
	                    case .historyVisibility:
	                        GroupHistoryVisibilitySheet(group: currentGroup)
                        case .memberFriendApply:
                            GroupMemberFriendApplySheet(groupID: currentGroup.id)
		                    }
		                }
	                .onChangeCompat(of: activeSheet) { _, sheet in
	                    if sheet == nil {
	                        endForcedAuthPromptDeferralIfNeeded()
	                    }
	                }
	                .navigationDestinationCompat(isPresented: $showLeaveDetail) {
	                    GroupLeaveDetailSheet(
	                        group: currentGroup,
	                        isSubmitting: isLifecycleActionRunning,
	                        isScopeValid: lifecycleActionContextIsCurrent(
                            groupID: currentGroup.id,
                            requiresOwner: false
                        ),
                        actionErrorMessage: lifecycleInlineMessage
                    ) {
                        showLeaveDetail = false
                        lifecycleInlineMessage = nil
                        clearLifecycleActionContext()
	                    } onConfirm: {
	                        performLeaveGroup()
	                    }
	                    .interactiveDismissDisabled(isLifecycleActionRunning)
	                }
	                .navigationDestinationCompat(isPresented: $showDissolveDetail) {
	                    GroupDissolveConfirmSheet(
	                        group: currentGroup,
	                        preview: dissolvePreview,
	                        isSubmitting: isLifecycleActionRunning && !isDissolvePreviewLoading,
                        isPreviewLoading: isDissolvePreviewLoading,
                        isScopeValid: lifecycleActionContextIsCurrent(
                            groupID: currentGroup.id,
                            requiresOwner: true
                        ),
                        isPreviewScopeValid: !lifecycleActionScopeKey.isEmpty
                            && dissolvePreviewScopeKey == lifecycleActionScopeKey,
                        previewErrorMessage: dissolvePreviewError,
                        actionErrorMessage: lifecycleInlineMessage,
                        onRetryPreview: {
                            beginDissolvePreview()
                        }
                    ) {
                        showDissolveDetail = false
                        dissolvePreview = nil
                        dissolvePreviewError = nil
                        lifecycleInlineMessage = nil
                        clearLifecycleActionContext()
	                    } onConfirm: {
	                        performDissolveGroup()
	                    }
	                    .interactiveDismissDisabled(isLifecycleActionRunning)
	                    .onAppear {
	                        guard dissolvePreview == nil,
                              dissolvePreviewError == nil,
                              !isDissolvePreviewLoading else { return }
                        beginDissolvePreview()
                    }
	                }
                    .sheet(item: $previewMember, onDismiss: {
                        if let id = pendingPreviewConversationID {
                            pendingPreviewConversationID = nil
                            previewConversationRoute = ContactsConversationRoute(id: id)
                        }
                    }) { user in
                        NavigationStackCompat {
                            requiredContactsRouting(contactsFeatureRouting).makeUserProfile(user: user, onOpenConversation: { id in
                                pendingPreviewConversationID = id
                                previewMember = nil
                            }, sourceGroupID: currentGroup.id)
                        }
                    }
                    .navigationDestinationCompat(item: $previewConversationRoute) { route in
                        requiredChatRouting(chatFeatureRouting).makeChat(route.conversationID)
                    }
                    .task(id: state.contentCacheScopeKey + "|" + group.id) {
                        state.refreshAppInteractionPolicy(force: true)
                        await state.refreshGroupBundle(groupID: group.id, silent: true, includeSecondaryData: false)
                    }
                    .onChangeCompat(of: showsGroupCount) { _, _ in // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
                        state.loadGroupDetailIfNeeded(groupID: group.id, force: true, includeSecondaryData: false)
                    }
						    }
					}

    private func beginDissolvePreview() {
        guard !isLifecycleActionRunning else { return }
        let groupID = currentGroup.id
        guard lifecycleActionContextIsCurrent(groupID: groupID, requiresOwner: true) else {
            dissolvePreview = nil
            dissolvePreviewScopeKey = nil
            dissolvePreviewError = "群聊状态、账号或你的群角色已变化，请返回后重试"
            return
        }
        let expectedScopeKey = lifecycleActionScopeKey
        let expectedActorID = lifecycleActionActorID
        isLifecycleActionRunning = true
        isDissolvePreviewLoading = true
        dissolvePreview = nil
        dissolvePreviewScopeKey = nil
        dissolvePreviewError = nil
        lifecycleInlineMessage = nil
        Task {
            let preview = await state.previewDissolveGroup(groupID: groupID)
            isLifecycleActionRunning = false
            isDissolvePreviewLoading = false
            guard showDissolveDetail else { return }
            guard lifecycleActionScopeKey == expectedScopeKey,
                  lifecycleActionActorID == expectedActorID,
                  lifecycleActionContextIsCurrent(groupID: groupID, requiresOwner: true) else {
                dissolvePreview = nil
                dissolvePreviewScopeKey = nil
                dissolvePreviewError = "群聊状态、账号或你的群角色已变化，请返回后重试"
                return
            }
            if let preview, preview.groupID == groupID {
                dissolvePreview = preview
                dissolvePreviewScopeKey = expectedScopeKey
            } else {
                dissolvePreviewScopeKey = nil
                dissolvePreviewError = state.toast ?? "解散预览失败，请稍后重试"
            }
        }
    }

    private func performLeaveGroup() {
        guard !isLifecycleActionRunning else { return }
        let groupID = currentGroup.id
        guard lifecycleActionContextIsCurrent(groupID: groupID, requiresOwner: false) else {
            lifecycleInlineMessage = "群聊状态、账号或你的群角色已变化，请返回后重试"
            return
        }
        isLifecycleActionRunning = true
        lifecycleInlineMessage = nil
        Task {
            let ok = await state.leaveGroup(groupID: groupID)
            isLifecycleActionRunning = false
            if ok {
                dismiss()
            } else {
                lifecycleInlineMessage = state.toast ?? "退出群聊失败，请稍后重试"
            }
	        }
	    }

	    private func endForcedAuthPromptDeferralIfNeeded() {
	        guard let token = forcedAuthPromptDeferralToken else { return }
	        forcedAuthPromptDeferralToken = nil
	        state.endForcedAppPolicyAuthPromptDeferral(token)
	    }

	    private func performDissolveGroup() {
	        guard !isLifecycleActionRunning else { return }
	        let groupID = currentGroup.id
        guard lifecycleActionContextIsCurrent(groupID: groupID, requiresOwner: true),
              dissolvePreview?.groupID == groupID,
              dissolvePreviewScopeKey == lifecycleActionScopeKey else {
            lifecycleInlineMessage = "群聊状态、账号或你的群角色已变化，请重新读取影响范围"
            return
        }
        isLifecycleActionRunning = true
        lifecycleInlineMessage = nil
        Task {
            let ok = await state.dissolveGroup(groupID: groupID)
            isLifecycleActionRunning = false
            if ok {
                showDissolveDetail = false
                dismiss()
            } else {
                lifecycleInlineMessage = state.toast ?? "解散该群失败，请稍后重试"
            }
        }
    }

	private enum GroupDetailSheet: String, Identifiable, Hashable {
    case members
    case announcement
    case files
    case profile
    case myNickname
    case muteAll
    case mute
    case muteList
    case joinApproval
    case historyVisibility
    case memberFriendApply

    var id: String { rawValue }
}

}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END

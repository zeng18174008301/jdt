import IM4Features
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
import SwiftUI
import UIKit

enum GroupMemberInviteAffordancePolicy {
    static func isVisible(canManage: Bool, inviteConfirmRequired: Bool, isMember: Bool = false) -> Bool {
        canManage || isMember
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct GroupMemberManagementView: View {
    @Environment(\.contactsFeatureRouting) private var contactsFeatureRouting
    @Environment(\.chatFeatureRouting) private var chatFeatureRouting
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    let groupID: String
    @EnvironmentObject private var state: AppState
    @State private var selectedMember: IMUser?
    @State private var pendingProfileMember: IMUser?
    @State private var profileMember: IMUser?
    @State private var selectedConversationRoute: ContactsConversationRoute?
    @State private var pendingProfileConversationID: String?
    @State private var showInvitePicker = false
    @State private var memberFilter = ""

    private var group: GroupInfo {
        state.group(id: groupID) ?? GroupInfo(id: groupID, name: "群成员", notice: "", owner: "", members: [], admins: [], muted: false, allMuted: false)
    }

    private var canManage: Bool {
        state.canManageGroup(group)
    }

    private var canInviteMembers: Bool {
        GroupMemberInviteAffordancePolicy.isVisible(
            canManage: canManage,
            inviteConfirmRequired: group.inviteConfirmRequired,
            isMember: state.group(id: groupID)?.presentedRole.map { ["owner", "admin", "member"].contains($0) } == true
        )
    }

    private func ownerUser(groupSelf: IMUser?) -> IMUser? { // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
        guard let owner = ownerIdentityUser else { return nil }
        let selfKeys = ownerStableKeys(for: renderedCurrentUser)
        guard !ownerStableKeys(for: owner).isDisjoint(with: selfKeys) else { return owner }
        let projection = groupSelf
            ?? (group.members + group.admins).first { member in
                !ownerStableKeys(for: member).isDisjoint(with: selfKeys)
            }
        guard let projection else { return owner }
        return owner.withName(GroupMemberDisplayNameResolver.projectedName(for: projection))
    }

    private var ownerIdentityUser: IMUser? {
        let ownerID = group.ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ownerID.isEmpty {
            if ownerIDMatches(renderedCurrentUser, ownerID: ownerID) {
                return renderedCurrentUser
            }
            return ownerCandidateUsers.first { ownerIDMatches($0, ownerID: ownerID) }
        }

        let ownerName = group.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ownerName.isEmpty else { return nil }
        let nameMatches = ownerCandidateUsers.filter { user in
            user.name.trimmingCharacters(in: .whitespacesAndNewlines) == ownerName
        }
        return nameMatches.count == 1 ? nameMatches.first : nil
    }

    private var ownerCandidateUsers: [IMUser] {
        var seen = Set<String>()
        return ([renderedCurrentUser] + group.members + group.admins).filter { user in
            let key = ownerStableKey(for: user)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private func ownerIDMatches(_ user: IMUser, ownerID: String) -> Bool {
        ownerStableKeys(for: user).contains(ownerID)
    }

    private func ownerStableKeys(for user: IMUser) -> Set<String> {
        Set([user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private func ownerStableKey(for user: IMUser) -> String {
        for key in [user.id, user.userID, user.username] {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private var adminUsers: [IMUser] {
        group.admins.filter { user in
            !state.isGroupOwner(user, in: group)
        }
    }

    private var filteredAdminUsers: [IMUser] {
        filteredUsers(adminUsers, role: .admin)
    }

    private var memberUsers: [IMUser] {
        group.members.filter { user in
            !state.isGroupOwner(user, in: group) && !state.isGroupAdmin(user, in: group)
        }
    }

    private var filteredMemberUsers: [IMUser] {
        filteredUsers(memberUsers, role: .member)
    }

    private var hasActiveFilter: Bool {
        !IMUserSearchMatcher.normalized(memberFilter).isEmpty
    }

    private func matchesFilter(_ user: IMUser, role: GroupMemberRole) -> Bool {
        IMUserSearchMatcher.matches(
            user: user.withName(GroupMemberDisplayNameResolver.projectedName(for: user)),
            role: role.title,
            query: memberFilter
        )
    }

    private func filteredUsers(_ users: [IMUser], role: GroupMemberRole) -> [IMUser] {
        let query = memberFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return users }
        return users
            .compactMap { user -> (user: IMUser, score: Int, name: String)? in
                let name = GroupMemberDisplayNameResolver.projectedName(for: user)
                guard let score = IMUserSearchMatcher.matchScore(
                    user: user.withName(name),
                    role: role.title,
                    query: query
                ) else { return nil }
                return (user, score, name)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(\.user)
    }

    private func loadMoreMembersIfNeeded(appearing user: IMUser, in users: [IMUser]) {
        guard !hasActiveFilter, group.membersPartial else { return }
        let userKeys = ownerStableKeys(for: user)
        let preloadWindow = users.suffix(8)
        guard preloadWindow.contains(where: { candidate in
            let candidateKeys = ownerStableKeys(for: candidate)
            return !candidateKeys.isDisjoint(with: userKeys)
        }) else { return }
        state.loadNextGroupMembersPageIfNeeded(groupID: group.id)
    }

    private func openPendingProfileConversationIfNeeded() {
        guard let conversationID = pendingProfileConversationID else { return }
        pendingProfileConversationID = nil
        DispatchQueue.main.async {
            selectedConversationRoute = ContactsConversationRoute(id: conversationID)
        }
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.display)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        GroupSnapshotView(store: state.contactStore, groupID: groupID) {
            // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
            let store = state.contactStore.groupSelfProfiles
            let key = state.groupMemberProfileCacheKey(groupID: group.id)
            PublisherSnapshotView(initialValue: store.snapshot(for: key).member, updates: store.updates(for: key, \.member)) { member in
                // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
                state.tenantClientPolicyStore.observe(\.showsGroupMemberCount) { visible in
                    groupContent(owner: ownerUser(groupSelf: member), showsGroupCount: visible)
                        .environment(\.tenantShowsGroupMemberCount, visible)
                }
                // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
            }
            // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private func groupContent(owner: IMUser?, showsGroupCount: Bool) -> some View {
        // WDT_APP_CONTRACT_20261021_13: reuse one filter/sort result in row appearance callbacks.
        let ownerSnapshot = owner.flatMap { matchesFilter($0, role: .owner) ? $0 : nil } // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
        let adminSnapshot = filteredAdminUsers
        let memberSnapshot = filteredMemberUsers
        NavigationStackCompat {
            GroupMemberManagementContent(memberFilter: $memberFilter, canManage: canManage, canInviteMembers: canInviteMembers,
                hasActiveFilter: hasActiveFilter, hasOwner: ownerSnapshot != nil,
                hasAdmins: !adminSnapshot.isEmpty, hasMembers: !memberSnapshot.isEmpty,
                stats: { GroupMemberStatsCard(group: group, ownerName: owner?.name ?? group.owner) },
                owner: {
                    if let user = ownerSnapshot {
                        GroupMemberRoleRow(user: user, role: .owner) { selectedMember = user }
                            .onAppear { loadMoreMembersIfNeeded(appearing: user, in: ownerCandidateUsers) }
                    }
                }, admins: {
                    ForEach(adminSnapshot) { user in
                        GroupMemberRoleRow(user: user, role: .admin) { selectedMember = user }
                            .onAppear { loadMoreMembersIfNeeded(appearing: user, in: adminSnapshot) }
                    }
                }, members: {
                    ForEach(memberSnapshot) { user in
                        GroupMemberRoleRow(user: user, role: .member) { selectedMember = user }
                            .onAppear { loadMoreMembersIfNeeded(appearing: user, in: memberSnapshot) }
                    }
                }, onInvite: { showInvitePicker = true })
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedMember, onDismiss: {
                guard let pendingProfileMember else { return }
                self.pendingProfileMember = nil
                DispatchQueue.main.async {
                    profileMember = pendingProfileMember
                }
            }) { user in
                GroupMemberActionSheet(groupID: group.id, user: user) { profileUser in
                    pendingProfileMember = profileUser
                    selectedMember = nil
                }
                    .presentationDetentsCompat([.height(520), .medium])
                    .presentationDragIndicatorCompat(.hidden)
                    .presentationCornerRadiusCompat(34)
                    .presentationBackgroundClearCompat()
            }
                .sheet(item: $profileMember, onDismiss: {
                    openPendingProfileConversationIfNeeded()
                }) { user in
                    NavigationStackCompat {
                        requiredContactsRouting(contactsFeatureRouting).makeUserProfile(user: user, onOpenConversation: { conversationID in
                            pendingProfileConversationID = conversationID
                            profileMember = nil
                        }, sourceGroupID: groupID)
                    }
                .presentationDetentsCompat([.large])
                .presentationDragIndicatorCompat(.visible)
            }
            // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_MEMBER_DESTINATION - 修改开始：群成员页聊天页目标读取 route conversationID
            .navigationDestinationCompat(item: $selectedConversationRoute) { route in
                requiredChatRouting(chatFeatureRouting).makeChat(route.conversationID)
            }
            // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_MEMBER_DESTINATION - 修改结束
            .sheet(isPresented: $showInvitePicker) {
                GroupInviteMembersSheet(group: group)
                    .presentationDetentsCompat([.medium, .large])
            }
            .task(id: state.contentCacheScopeKey + "|" + groupID) {
                state.refreshAppInteractionPolicy(force: true)
                await state.refreshGroupBundle(groupID: groupID, silent: true)
            }
            .onChangeCompat(of: showsGroupCount) { _, _ in // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
                state.loadGroupDetailIfNeeded(groupID: groupID, force: true)
            }
        }
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private typealias GroupMemberRole = IM4Features.GroupMemberRole

private struct GroupMemberRoleRow: View {
    @EnvironmentObject private var state: AppState

    let user: IMUser
    let role: GroupMemberRole
    let action: () -> Void

    private var userIDText: String {
        let value = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? user.id : value
    }

    private var displayName: String {
        GroupMemberDisplayNameResolver.projectedName(for: user)
    }

    var body: some View {
        GroupMemberRoleContent(displayName: displayName, userIDText: userIDText, role: role, action: action,
            avatar: {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 50, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }, certification: { CertificationPillView(exactUID: user.id, compact: true) }, onCopy: state.copyUserID)
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
private struct GroupMemberActionSheet: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    let groupID: String
    let user: IMUser
    let onViewProfile: (IMUser) -> Void
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var group: GroupInfo {
        state.group(id: groupID) ?? GroupInfo(id: groupID, name: "群成员", notice: "", owner: "", members: [], admins: [], muted: false, allMuted: false)
    }

    private var role: GroupMemberRole {
        if state.isGroupOwner(user, in: group) {
            return .owner
        }
        if state.isGroupAdmin(user, in: group) {
            return .admin
        }
        return .member
    }

    private var userIDText: String {
        let value = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? user.id : value
    }

    private var displayName: String {
        GroupMemberDisplayNameResolver.projectedName(for: user)
    }

    private var isCurrentUserOwner: Bool {
        group.isCurrentUserOwner || state.isGroupOwner(renderedCurrentUser, in: group)
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.identity)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        GroupSnapshotView(store: state.contactStore, groupID: groupID) {
            // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_BEGIN
            let key = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            PublisherSnapshotView(
                initialValue: state.groupModerationStore.isTransferringOwner(groupID: key),
                updates: state.groupModerationStore.ownerTransferPublisher(for: key)
            ) { isTransferring in
                groupContent(isTransferring: isTransferring)
            }
            // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private func groupContent(isTransferring: Bool) -> some View { // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110
        GroupMemberActionContent(
            groupName: group.name, userID: user.id, userIDText: userIDText, displayName: displayName,
            role: role, isCurrentUserOwner: isCurrentUserOwner, canManage: state.canManageGroup(group),
            isTransferring: isTransferring,
            avatar: {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 54, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }, certification: { CertificationPillView(exactUID: user.id, compact: true) },
            onCopyUserID: state.copyUserID,
            onClose: { dismiss() },
            onViewProfile: { onViewProfile(user) },
            onTransfer: {
                Task {
                    if await state.transferGroupOwner(groupID: groupID, targetUID: user.id) {
                        dismiss()
                    }
                }
            },
            onSetAdmin: { isAdmin in
                state.setGroupMemberAdmin(groupID: groupID, userID: user.id, isAdmin: isAdmin)
                dismiss()
            },
            onRemove: {
                state.removeGroupMember(groupID: groupID, userID: user.id)
                dismiss()
            }
        )
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private struct GroupInviteMembersSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo
    @State private var query = ""
    @State private var selectedIDs: Set<String> = []
    @State private var isSubmitting = false

    private var candidateUsers: [IMUser] {
        let existingIDs = Set(group.members.map(\.id))
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.inviteCandidates(for: group).filter { user in
            !existingIDs.contains(user.id) &&
            !user.isCancelledUser &&
            (trimmedQuery.isEmpty || IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: trimmedQuery
            ))
        }
    }

    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    var body: some View {
        let store = state.contactStore
        PublisherSnapshotView(initialValue: store.groups, updates: store.groupDirectoryUpdates) { _ in
            // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_BEGIN
            ContactDirectoryPresentationView(store: store) { groupDependentContent }
            // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END

    @ViewBuilder
    private var groupDependentContent: some View {
        let candidates = candidateUsers
        GroupInviteMembersContent(query: $query, canManage: state.canManageGroup(group),
            isEmpty: candidates.isEmpty, selectedCount: selectedIDs.count,
            isSubmitting: isSubmitting, onSubmit: submit) {
            ForEach(candidates) { user in
                let displayName = state.remarkPreferredDisplayName(for: user)
                GroupMemberSelectionRowContent(
                    displayName: displayName,
                    displayID: user.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? user.id : user.userID,
                    isSelected: selectedIDs.contains(user.id),
                    avatar: {
                        AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                    }, certification: { CertificationPillView(exactUID: user.id, compact: true) },
                    onCopyUserID: state.copyUserID,
                    onSelect: {
                        if selectedIDs.contains(user.id) {
                            selectedIDs.remove(user.id)
                        } else {
                            selectedIDs.insert(user.id)
                        }
                    }
                )
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let ok = await state.inviteGroupMembers(groupID: group.id, memberIDs: Array(selectedIDs))
            isSubmitting = false
            if ok {
                dismiss()
            }
        }
    }
}
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END

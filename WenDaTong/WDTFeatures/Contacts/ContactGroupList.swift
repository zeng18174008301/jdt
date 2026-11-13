import IM4Features
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
import Combine // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110 // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct GroupListView: View {
    @Environment(\.chatFeatureRouting) private var chatFeatureRouting
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState
    // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_GROUP_ROUTE_STATE - 修改开始：群列表聊天跳转改为稳定 item route
    @State private var selectedConversationRoute: ContactsConversationRoute?
    // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_GROUP_ROUTE_STATE - 修改结束
    @State private var showCreateGroupSheet = false
    @State private var cachedGroupSections: GroupListRenderSections = .empty
    @State private var hasGroupListCache = false
    @State private var groupDirectoryRefreshTask: Task<Void, Never>?

    private var groupSections: GroupListRenderSections {
        hasGroupListCache ? cachedGroupSections : buildGroupSections()
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
    nonisolated private static func groupConversationMetadata(in conversations: [ConversationMessageSnapshot]) -> [ConversationMessageSnapshot] {
        conversations.compactMap { conversation in
            guard conversation.kind == .group else { return nil }
            var metadata = conversation
            metadata.messages = []
            return metadata
        }
    }

    private func projectedGroups(from groups: [GroupInfo]? = nil, conversations: [ConversationMessageSnapshot]? = nil) -> [GroupInfo] {
        ContactStore.projectedGroupDirectory(
            authoritativeGroups: groups ?? state.contactStore.groups,
            conversations: conversations ?? Self.groupConversationMetadata(in: state.conversationStore.conversationMessageSnapshots())
        )
    }
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.display)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        state.tenantClientPolicyStore.observe(\.groupDirectory) { policy in
            // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
            state.enterpriseMembershipStore.observe(\.current.role) { role in
                groupListContent(canCreateGroup: AppState.canCreateGroupChat(role: role, enabled: policy.allowsMemberCreation))
                    .environment(\.tenantShowsGroupMemberCount, policy.showsMemberCount)
            }
            // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
        }
    }

    private func groupListContent(canCreateGroup: Bool) -> some View {
        GroupListContent(canCreateGroup: canCreateGroup, onCreateGroup: { showCreateGroupSheet = true },
            managed: { groupRows(groupSections.managed) }, joined: { groupRows(groupSections.joined) })
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_GROUP_DESTINATION - 修改开始：群列表聊天页目标由 route 直接携带
        .navigationDestinationCompat(item: $selectedConversationRoute) { route in
            requiredChatRouting(chatFeatureRouting).makeChat(route.conversationID)
        }
        // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_GROUP_DESTINATION - 修改结束
        .onAppear {
            rebuildGroupListCache()
            projectedGroups().forEach { group in
                state.loadGroupDetailIfNeeded(groupID: group.id)
            }
            startGroupDirectoryRefresh()
        }
        .refreshable {
            _ = await state.refreshGroupDirectory(silent: false)
        }
        .onDisappear {
            groupDirectoryRefreshTask?.cancel()
            groupDirectoryRefreshTask = nil
        }
        // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.$groups) { groups in
            rebuildGroupListCache(from: groups)
        }
        // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END
        // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
        .onReceive(state.conversationStore.memoryUpdates.map { _ in Self.groupConversationMetadata(in: state.conversationStore.conversationMessageSnapshots()) }.removeDuplicates()) { metadata in // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            rebuildGroupListCache(conversations: metadata)
        }
        // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END
        .onChangeCompat(of: CurrentUserPresentationStore.identity(renderedCurrentUser)) { _, _ in
            rebuildGroupListCache()
        }
        .onChangeCompat(of: renderedCurrentUser.name) { _, _ in
            rebuildGroupListCache()
        }
        .sheet(isPresented: $showCreateGroupSheet) {
            CreateGroupSheet { conversationID in
                showCreateGroupSheet = false
                // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_CREATE_GROUP_ROUTE - 修改开始：创建群后使用同一稳定聊天 route
                selectedConversationRoute = ContactsConversationRoute(id: conversationID)
                // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_CREATE_GROUP_ROUTE - 修改结束
            }
            .environmentObject(state)
            .presentationDetentsCompat([.large])
            .presentationCornerRadiusCompat(30)
        }
        .toolbarTabBarHiddenCompat()
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
    private func groupRows(_ items: [GroupListRenderItem]) -> some View {
        ForEach(items) { item in
            GroupListButton(groupID: item.group.id, groupName: item.group.name, onSelect: {
                selectedConversationRoute = ContactsConversationRoute(id: conversationID(for: item))
            }) {
                GroupListRow(group: item.group, conversation: item.conversation)
            }
        }
    }

    private func buildGroupSections(
        from groups: [GroupInfo]? = nil,
        conversations: [ConversationMessageSnapshot]? = nil
    ) -> GroupListRenderSections {
        let metadata = conversations ?? Self.groupConversationMetadata(in: state.conversationStore.conversationMessageSnapshots())
        var managed: [GroupListRenderItem] = []
        var joined: [GroupListRenderItem] = []
        for group in projectedGroups(from: groups, conversations: metadata) {
            let item = GroupListRenderItem(group: group, conversation: conversation(for: group, in: metadata))
            // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END
            if state.canManageGroup(group) {
                managed.append(item)
            } else {
                joined.append(item)
            }
        }
        return GroupListRenderSections(managed: managed, joined: joined)
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
    private func rebuildGroupListCache(from groups: [GroupInfo]? = nil, conversations: [ConversationMessageSnapshot]? = nil) {
        let sections = buildGroupSections(from: groups, conversations: conversations)
        if cachedGroupSections != sections { cachedGroupSections = sections }
        if !hasGroupListCache { hasGroupListCache = true }
    }
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END

    private func startGroupDirectoryRefresh() {
        groupDirectoryRefreshTask?.cancel()
        groupDirectoryRefreshTask = Task { @MainActor in
            guard await state.refreshGroupDirectory(), !Task.isCancelled else { return }
            state.groups.forEach { group in
                state.loadGroupDetailIfNeeded(groupID: group.id)
            }
        }
    }

    private func conversation(for group: GroupInfo, in conversations: [ConversationMessageSnapshot]) -> ConversationMessageSnapshot? {
        conversations.first { conversation in
            conversation.kind == .group && (conversation.id == group.id || conversation.title == group.name)
        }
    }

    private func conversationID(for item: GroupListRenderItem) -> String {
        item.conversation?.id ?? item.group.id
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private typealias GroupCreateEntryRow = IM4Features.GroupCreateEntryRow

private struct GroupListRenderItem: Identifiable, Hashable {
    let group: GroupInfo
    let conversation: ConversationMessageSnapshot?

    var id: String { group.id }
}

private struct GroupListRenderSections: Hashable {
    static let empty = GroupListRenderSections(managed: [], joined: [])

    let managed: [GroupListRenderItem]
    let joined: [GroupListRenderItem]
}

private struct GroupListRow: View {
    @Environment(\.tenantShowsGroupMemberCount) private var showsGroupCount // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
    let group: GroupInfo
    let conversation: ConversationMessageSnapshot?
    @EnvironmentObject private var state: AppState

    private var isNotificationMuted: Bool {
        GroupNotificationMuteProjection.isMuted(group: group, conversation: conversation)
    }

    var body: some View {
        let subtitle = [
            state.visibleGroupMemberCount(group.memberCount, showsCount: showsGroupCount).map { "\($0) 人" },
            group.owner.isEmpty ? nil : "群主 \(group.owner)"
        ].compactMap { $0 }.joined(separator: " · ")
        GroupListRowContent(name: group.name, subtitle: subtitle, isNotificationMuted: isNotificationMuted,
            unread: conversation?.unread) {
            GroupAvatarView(name: group.name, seed: conversation?.accentHex ?? 0x5D6BFF, size: 46, imageURL: group.avatarURL, avatarVersion: group.avatarVersion, avatarUpdatedAt: group.avatarUpdatedAt, imageCacheKey: state.groupAvatarCacheKey(groupID: group.id, avatarURL: group.avatarURL, avatarVersion: group.avatarVersion, avatarUpdatedAt: group.avatarUpdatedAt))
        }
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END

import IM4Features
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
extension OrganizationDirectoryStore {
    @MainActor
    func observe<Value: Equatable, Content: View>(
        _ project: @escaping (Snapshot) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(initialValue: project(snapshot), updates: updates(project), content: content)
    }
}

extension AppState {
    @MainActor
    func observeDepartmentAvailability<Content: View>(
        @ViewBuilder content: @escaping (Bool) -> Content
    ) -> some View {
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
        appPolicyPresentationStore.observe(\.departmentEnabled) { policyEnabled in
            self.organizationDirectoryStore.observe(
                { $0.departmentEnabled(appPolicyEnabled: policyEnabled) },
                content: content
            )
        }
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
    }

    @MainActor
    func observeDepartmentSummary<Content: View>(
        for user: IMUser,
        fullPath: Bool = false,
        @ViewBuilder content: @escaping (String?) -> Content
    ) -> some View {
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
        appPolicyPresentationStore.observe(\.departmentEnabled) { _ in
            self.organizationDirectoryStore.observe(
                { self.departmentSummary(for: user, fullPath: fullPath, directory: $0) },
                content: content
            )
        }
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
    }
}
// WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END

struct OrganizationDirectoryView: View {
    @EnvironmentObject private var state: AppState
    let onShowMembers: (RemoteDepartmentNode) -> Void

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    private struct Header: Equatable {
        let tree: RemoteOrganizationTree?
        let isSyncing: Bool
        let errorMessage: String?
    }

    var body: some View {
        state.organizationDirectoryStore.observe({
            Header(tree: $0.tree, isSyncing: $0.isSyncing, errorMessage: $0.errorMessage)
        }) { header in
            directoryContent(header)
        }
    }

    private func directoryContent(_ header: Header) -> some View {
        OrganizationDirectoryContent(isSyncing: header.isSyncing, hasTree: header.tree != nil,
            hasNodes: header.tree.map { $0.root != nil || !$0.items.isEmpty } ?? false, errorMessage: header.errorMessage,
            nodes: {
                if let root = header.tree?.root {
                    OrganizationDepartmentNodeView(node: root, level: 0, onShowMembers: onShowMembers)
                } else if let tree = header.tree {
                    ForEach(tree.items) { node in
                        OrganizationDepartmentNodeView(node: node, level: 0, onShowMembers: onShowMembers)
                    }
                }
            }, onRetry: { state.retryContactsSync() })
    }
}

private struct OrganizationDepartmentNodeView: View {
    @EnvironmentObject private var state: AppState
    let node: RemoteDepartmentNode
    let level: Int
    let onShowMembers: (RemoteDepartmentNode) -> Void
    let initiallyExpanded: Bool

    init(
        node: RemoteDepartmentNode,
        level: Int,
        initiallyExpanded: Bool = true,
        onShowMembers: @escaping (RemoteDepartmentNode) -> Void
    ) {
        self.node = node
        self.level = level
        self.onShowMembers = onShowMembers
        self.initiallyExpanded = initiallyExpanded
    }

    private var displayName: String {
        let trimmed = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "公司" : trimmed
    }

    private var hasChildren: Bool {
        !node.children.isEmpty
    }

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    var body: some View {
        let id = state.normalizedOrganizationDepartmentID(node.departmentID)
        state.organizationDirectoryStore.observe({ node.memberCount > 0 ? node.memberCount : $0.members(for: id).count }) { count in
            nodeContent(memberCount: count)
        }
    }

    private func nodeContent(memberCount: Int) -> some View {
        OrganizationDepartmentContent(departmentID: node.departmentID, displayName: displayName,
            hasChildren: hasChildren, isVirtual: node.isVirtual, level: level, memberCount: memberCount,
            initiallyExpanded: initiallyExpanded, onShowMembers: { onShowMembers(node) }) {
            ForEach(node.children) { child in
                OrganizationDepartmentNodeView(node: child, level: level + 1, onShowMembers: onShowMembers)
            }
        }
    }
}

struct OrganizationDepartmentMembersView: View {
    @Environment(\.contactsFeatureRouting) private var contactsFeatureRouting
    @Environment(\.chatFeatureRouting) private var chatFeatureRouting
    @EnvironmentObject private var state: AppState
    let department: RemoteDepartmentNode
    @State private var selectedUser: IMUser?
    // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_ORG_ROUTE_STATE - 修改开始：组织成员页聊天跳转改为稳定 item route
    @State private var selectedConversationRoute: ContactsConversationRoute?
    // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_ORG_ROUTE_STATE - 修改结束

    private var displayName: String {
        let trimmed = department.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "公司" : trimmed
    }

    private var pathText: String {
        let names = department.departmentPathNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return displayName }
        return names.joined(separator: " / ")
    }

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    private struct MembersPresentation: Equatable {
        let members: [IMUser]
        let isSyncing: Bool
        let showDepartmentSummary: Bool
    }

    var body: some View {
        let id = state.normalizedOrganizationDepartmentID(department.departmentID)
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
        state.appPolicyPresentationStore.observe(\.departmentEnabled) { policyEnabled in
            state.organizationDirectoryStore.observe({
                let members = $0.members(for: id)
                return MembersPresentation(
                    members: members,
                    isSyncing: $0.isSyncing && members.isEmpty,
                    showDepartmentSummary: $0.departmentEnabled(appPolicyEnabled: policyEnabled)
                )
            }) { presentation in
                membersContent(presentation)
            }
        }
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
    }

    private func membersContent(_ presentation: MembersPresentation) -> some View {
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
        OrganizationMembersScreenContent(header: header(displayCount: department.memberCount > 0 ? department.memberCount : presentation.members.count),
            memberList: memberList(presentation))
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestinationCompat(item: $selectedUser) { user in
            requiredContactsRouting(contactsFeatureRouting).makeUserProfile(user: user, onOpenConversation: { conversationID in
                // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_ORG_PROFILE_ROUTE - 修改开始：避免 Bool+Optional 跳转生成空聊天页
                selectedConversationRoute = ContactsConversationRoute(id: conversationID)
                // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_ORG_PROFILE_ROUTE - 修改结束
            })
        }
        // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_ORG_DESTINATION - 修改开始：聊天页目标由 route 直接携带
        .navigationDestinationCompat(item: $selectedConversationRoute) { route in
            requiredChatRouting(chatFeatureRouting).makeChat(route.conversationID)
        }
        // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_ORG_DESTINATION - 修改结束
        .toolbarTabBarHiddenCompat()
    }

    private func header(displayCount: Int) -> some View {
        OrganizationMembersHeaderContent(displayName: displayName, pathText: pathText,
            isVirtual: department.isVirtual, displayCount: displayCount)
    }
    private func memberList(_ presentation: MembersPresentation) -> some View {
        OrganizationMembersListContent(isEmpty: presentation.members.isEmpty, isSyncing: presentation.isSyncing) {
            ForEach(presentation.members) { user in
                let row = contactDirectoryRowPresentation(for: user, state: state,
                    includeDepartmentSummary: presentation.showDepartmentSummary, accessibilityPrefix: "成员")
                OrganizationMemberButtonContent(userID: user.id, accessibilityLabel: row.accessibilityLabel,
                    onSelect: { selectedUser = user }) {
                    ContactDirectoryRow(row: row)
                }
                if presentation.members.last?.id != user.id {
                    Divider().padding(.leading, 62).opacity(0.72)
                }
            }
        }
    }
}
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END

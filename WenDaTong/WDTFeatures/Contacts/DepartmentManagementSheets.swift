import IM4Features
import Combine // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_BEGIN
private extension OrganizationDirectoryStore {
    @MainActor
    func observeManagementProgress<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        PublisherSnapshotView(
            initialValue: isManagementSaving,
            updates: $isManagementSaving.eraseToAnyPublisher()
        ) { _ in content() }
    }
}
// WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_END

struct DepartmentManagementSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedDepartmentID = "company"
    @State private var departmentNameDraft = ""
    @State private var childDepartmentName = ""
    @State private var showingDeleteConfirmation = false
    @State private var showingMemberInvite = false

    private var departmentNodes: [RemoteDepartmentNode] {
        var nodes: [RemoteDepartmentNode] = []
        func append(_ node: RemoteDepartmentNode) {
            nodes.append(node)
            node.children.forEach(append)
        }
        if let root = state.organizationTree?.root {
            append(root)
        } else {
            state.organizationTree?.items.forEach(append)
        }
        return nodes
    }

    private var departmentTreeRevision: String {
        departmentNodes
            .map { "\($0.departmentID):\($0.parentDepartmentID):\($0.name):\($0.memberCount)" }
            .joined(separator: "|")
    }

    private var selectedDepartment: RemoteDepartmentNode? {
        let normalized = normalizedDepartmentID(selectedDepartmentID)
        return departmentNodes.first { normalizedDepartmentID($0.departmentID) == normalized }
    }

    private var selectedMembers: [IMUser] {
        state.organizationMembers(for: selectedDepartmentID)
    }

    private var isCompanySelected: Bool {
        normalizedDepartmentID(selectedDepartmentID) == "company" || selectedDepartment?.isVirtual == true
    }

    // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_BEGIN
    var body: some View {
        // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_BEGIN
        state.organizationDirectoryStore.observeManagementProgress {
            ContactDirectoryPresentationView(store: state.contactStore) {
                // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
                let id = normalizedDepartmentID(selectedDepartmentID)
                state.organizationDirectoryStore.observe(\.tree) { _ in
                    state.organizationDirectoryStore.observe({ $0.members(for: id) }) { _ in directoryContent }
                }
                // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
            }
        }
        // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_END
    }
    // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_END

    private var directoryContent: some View {
        DepartmentManagementContent(showDeleteConfirmation: $showingDeleteConfirmation, onDelete: {
            Task {
                let deletedID = selectedDepartmentID
                selectedDepartmentID = "company"
                _ = await state.deleteOrganizationDepartment(departmentID: deletedID)
            }
        }, departmentChooser: { departmentChooser }, selectedDepartmentPanel: { selectedDepartmentPanel },
            memberPanel: { memberPanel })
        .onAppear {
            ensureSelectedDepartmentExists()
            syncDepartmentDraft()
        }
        .onChangeCompat(of: selectedDepartmentID) { _, _ in
            syncDepartmentDraft()
        }
        .onChangeCompat(of: departmentTreeRevision) { _, _ in
            ensureSelectedDepartmentExists()
            syncDepartmentDraft()
        }
        .sheet(isPresented: $showingMemberInvite) {
            DepartmentMemberInviteSheet(
                departmentID: selectedDepartmentID,
                departmentName: displayDepartmentName(selectedDepartment),
                currentMemberIDs: Set(selectedMembers.map { $0.id })
            )
            .environmentObject(state)
            .presentationDetentsCompat([.large])
            .presentationDragIndicatorCompat(.visible)
        }

    }

    private var departmentChooser: some View {
        let nodes = departmentNodes
        return DepartmentManagementChooserContent(isEmpty: nodes.isEmpty) {
            ForEach(nodes) { node in
                departmentChoiceButton(node)
            }
        }
    }

    private var selectedDepartmentPanel: some View {
        DepartmentManagementEditorContent(
            departmentNameDraft: $departmentNameDraft, childDepartmentName: $childDepartmentName,
            name: displayDepartmentName(selectedDepartment), memberCount: selectedMembers.count,
            isCompanySelected: isCompanySelected, isSaving: state.isOrganizationManagementSaving,
            onSave: {
                Task {
                    _ = await state.updateOrganizationDepartment(departmentID: selectedDepartmentID, parentDepartmentID: nil, name: departmentNameDraft)
                }
            }, onCreate: {
                Task {
                    if await state.createOrganizationDepartment(parentDepartmentID: selectedDepartmentID, name: childDepartmentName) {
                        childDepartmentName = ""
                    }
                }
            }, onDelete: { showingDeleteConfirmation = true }
        )
    }

    private var memberPanel: some View {
        let members = selectedMembers
        return DepartmentManagementMembersContent(memberCount: members.count, isCompanySelected: isCompanySelected,
            isSaving: state.isOrganizationManagementSaving, onInvite: {
                guard !state.isOrganizationManagementSaving else { return }
                showingMemberInvite = true
            }) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, user in
                memberRow(user)
                if index < members.count - 1 {
                    Divider().padding(.leading, 58).opacity(0.7)
                }
            }
        }
    }

    private func departmentChoiceButton(_ node: RemoteDepartmentNode) -> some View {
        let normalizedID = normalizedDepartmentID(node.departmentID)
        let selected = normalizedDepartmentID(selectedDepartmentID) == normalizedID
        return DepartmentManagementChoiceContent(name: displayDepartmentName(node), isVirtual: node.isVirtual,
            depth: node.depth, selected: selected, onSelect: { selectedDepartmentID = normalizedID })
    }

    private func memberRow(_ user: IMUser) -> some View {
        let displayName = state.remarkPreferredDisplayName(for: user)
        return DepartmentManagementMemberRowContent(
            displayName: displayName, subtitle: user.title.isEmpty ? user.id : user.title,
            canRemove: !isCompanySelected, isSaving: state.isOrganizationManagementSaving,
            onRemove: {
                Task {
                    _ = await state.removeOrganizationMember(departmentID: selectedDepartmentID, userID: user.id)
                }
            }, avatar: {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 42, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }, certification: { CertificationPillView(exactUID: user.id, compact: true) }
        )
    }

    private func ensureSelectedDepartmentExists() {
        guard !departmentNodes.isEmpty else {
            selectedDepartmentID = "company"
            return
        }
        let normalized = normalizedDepartmentID(selectedDepartmentID)
        if !departmentNodes.contains(where: { normalizedDepartmentID($0.departmentID) == normalized }) {
            selectedDepartmentID = normalizedDepartmentID(departmentNodes.first?.departmentID ?? "company")
        }
    }

    private func syncDepartmentDraft() {
        departmentNameDraft = isCompanySelected ? "" : displayDepartmentName(selectedDepartment)
    }

    private func displayDepartmentName(_ node: RemoteDepartmentNode?) -> String {
        let name = node?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "公司" : name
    }

    private func normalizedDepartmentID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "__company__" || trimmed == "__root__" {
            return "company"
        }
        return trimmed
    }
}

private struct DepartmentMemberInviteSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let departmentID: String
    let departmentName: String
    let currentMemberIDs: Set<String>
    @State private var query = ""
    @State private var selectedUserID = ""
    @State private var isSubmitting = false

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetDepartmentName: String {
        let trimmed = departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "当前部门" : trimmed
    }

    private var candidateUsers: [IMUser] {
        let users = state.organizationManagementCandidateUsers.filter { user in
            normalizedQuery.isEmpty || IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: normalizedQuery
            )
        }
        return users.sorted {
            state.remarkPreferredDisplayName(for: $0)
                .localizedCaseInsensitiveCompare(state.remarkPreferredDisplayName(for: $1)) == .orderedAscending
        }
    }

    private var selectedUser: IMUser? {
        state.organizationManagementCandidateUsers.first { $0.id == selectedUserID }
    }

    private var selectedUserAlreadyInTarget: Bool {
        guard !selectedUserID.isEmpty else { return false }
        return currentMemberIDs.contains(selectedUserID)
    }

    private var confirmDisabled: Bool {
        selectedUserID.isEmpty || selectedUserAlreadyInTarget || isSubmitting || state.isOrganizationManagementSaving
    }

    // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_BEGIN
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    private struct DirectoryInput: Equatable {
        let memberIndex: [String: IMUser]
        let departmentEnabled: Bool
    }

    var body: some View {
        // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_BEGIN
        state.organizationDirectoryStore.observeManagementProgress {
            ContactDirectoryPresentationView(store: state.contactStore) {
                // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
                state.appPolicyPresentationStore.observe(\.departmentEnabled) { policyEnabled in
                    state.organizationDirectoryStore.observe({
                        DirectoryInput(memberIndex: $0.memberIndex, departmentEnabled: $0.departmentEnabled(appPolicyEnabled: policyEnabled))
                    }) { _ in directoryContent }
                }
                // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
            }
        }
        // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_END
    }
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_END

    private var directoryContent: some View {
        let candidates = candidateUsers
        return DepartmentMemberInviteContent(
            query: $query, targetDepartmentName: targetDepartmentName, isEmpty: candidates.isEmpty,
            confirmButtonTitle: confirmButtonTitle, confirmDisabled: confirmDisabled, onSubmit: submit
        ) {
            ForEach(candidates) { user in
                inviteCandidateRow(user)
            }
        }
        .onChangeCompat(of: query) { _, _ in
            if let selectedUser, !candidateUsers.contains(where: { $0.id == selectedUser.id }) {
                selectedUserID = ""
            }
        }
    }

    private var confirmButtonTitle: String {
        if isSubmitting || state.isOrganizationManagementSaving {
            return "变更中..."
        }
        if selectedUserAlreadyInTarget {
            return "已在当前部门"
        }
        return selectedUserID.isEmpty ? "选择成员后确认" : "确认变更到当前部门"
    }

    private func inviteCandidateRow(_ user: IMUser) -> some View {
        let selected = selectedUserID == user.id
        let alreadyInTarget = currentMemberIDs.contains(user.id)
        let displayName = state.remarkPreferredDisplayName(for: user)
        return DepartmentMemberInviteRowContent(
            userID: user.id, displayName: displayName,
            displayID: user.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? user.id : user.userID,
            departmentName: userDepartmentText(user), selected: selected, alreadyInTarget: alreadyInTarget,
            onCopyUserID: state.copyUserID, onSelect: {
                guard !alreadyInTarget else { return }
                selectedUserID = selected ? "" : user.id
            }, avatar: {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }, certification: { CertificationPillView(exactUID: user.id, compact: true) }
        )
        .certificationAccessibilityLabel(
            "邀请候选人 \(displayName)，当前部门 \(userDepartmentText(user))",
            reference: state.certificationPillSource.reference(forExactUID: user.id)
        ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
    }

    private func userDepartmentText(_ user: IMUser) -> String {
        state.departmentSummary(for: user, fullPath: true) ?? "公司"
    }

    private func submit() {
        guard !confirmDisabled else { return }
        let userID = selectedUserID
        isSubmitting = true
        Task {
            let ok = await state.addOrganizationMember(departmentID: departmentID, userID: userID)
            await MainActor.run {
                isSubmitting = false
                if ok {
                    dismiss()
                }
            }
        }
    }
}

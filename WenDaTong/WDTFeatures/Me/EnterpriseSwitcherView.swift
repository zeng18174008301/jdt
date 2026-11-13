import IM4Features
import Combine // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct EnterpriseSwitcherDismissalFence {
    private var baselineRevision: UInt64?
    private var consumed = false

    mutating func captureBaseline(_ revision: UInt64) {
        guard baselineRevision == nil else { return }
        baselineRevision = revision
    }

    mutating func consume(successRevision: UInt64) -> Bool {
        guard !consumed,
              let baselineRevision,
              successRevision > baselineRevision else {
            return false
        }
        consumed = true
        return true
    }
}

struct EnterpriseSwitcherView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hasSubmittedSearch = false
    @State private var dismissalFence = EnterpriseSwitcherDismissalFence()

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isShowingSearchResults: Bool {
        hasSubmittedSearch && !trimmedQuery.isEmpty
    }

    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
    private var joinedEnterpriseIDs: Set<String> {
        Set(state.enterprises.filter { $0.isWorkspaceJoined }.map(\.id))
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110_BEGIN
    var body: some View {
        let store = state.loginWorkspacePresentationStore
        PublisherSnapshotView(
            initialValue: store.switchCompletionRevision,
            updates: store.$switchCompletionRevision.eraseToAnyPublisher()
        ) { revision in
            // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
            state.enterpriseMembershipStore.observe(\.selection) { selection in
                chooserContent(completionRevision: revision, selection: selection)
            }
            // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110_END

    private func chooserContent(completionRevision: UInt64, selection: EnterpriseMembershipPresentationStore.Selection) -> some View { // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110
        EnterpriseSwitcherContent(query: $query, onClose: { dismiss() }, onSearch: {
            hasSubmittedSearch = !trimmedQuery.isEmpty
            state.searchEnterprises(query: query)
            }, onQueryChange: enterpriseQueryChanged, defaultWorkspace: {
                state.loginWorkspacePresentationStore.observe(\.defaultWorkspaceID) { defaultID in
                    defaultWorkspaceCard(defaultID: defaultID, memberships: selection.memberships)
                }
            }, directoryResults: { observedDirectoryResults(selection: selection) })
        .onAppear {
            dismissalFence.captureBaseline(state.loginWorkspacePresentationStore.switchCompletionRevision) // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110
        }
        .onChangeCompat(of: completionRevision) { _, revision in // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110
            guard dismissalFence.consume(successRevision: revision) else { return }
            dismiss()
        }
        .task {
            await state.refreshCurrentAppPolicyForAuthUI(force: true)
        }
    }

    private func enterpriseQueryChanged(_ newValue: String) {
        let normalized = AuthInputFilter.entryCode().apply(to: newValue)
        if newValue != normalized, newValue.count <= 11 || newValue.rangeOfCharacter(from: .letters) != nil || newValue.rangeOfCharacter(from: .decimalDigits) != nil {
            query = normalized
            return
        }
        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasSubmittedSearch = false
            state.clearEnterpriseSearch()
        } else {
            hasSubmittedSearch = false
            state.clearEnterpriseSearch()
        }
    }

    // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110_BEGIN
    @ViewBuilder
    private func defaultWorkspaceCard(defaultID: String, memberships: [Enterprise]) -> some View {
        let normalizedID = defaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedID.isEmpty {
            let defaultWorkspace = memberships.first { $0.id == normalizedID } // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            let defaultWorkspaceName = defaultWorkspace?.name ?? "已设置的默认企业"
            if !defaultWorkspaceName.isEmpty {
                EnterpriseDefaultWorkspaceContent(name: defaultWorkspaceName,
                    displayCode: defaultWorkspace?.displayCode, onClear: { state.clearDefaultWorkspacePreference() }) {
                    if let defaultWorkspace {
                        EnterpriseLogoView(
                            enterprise: defaultWorkspace,
                            size: 34,
                            cornerRadius: 12,
                            cacheKey: state.enterpriseLogoCacheKey(for: defaultWorkspace)
                        )
                    } else {
                        EnterpriseDefaultWorkspaceFallbackIcon()
                    }
                }
            }
        }
    }
    // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_BEGIN
    private func observedDirectoryResults(selection: EnterpriseMembershipPresentationStore.Selection) -> some View {
        let store = state.enterpriseDirectoryStore
        return PublisherSnapshotView(
            initialValue: store.snapshot,
            updates: store.$snapshot.eraseToAnyPublisher()
        ) { directory in
            directoryResults(directory, selection: selection)
        }
    }

    @ViewBuilder
    private func directoryResults(_ directory: EnterpriseDirectoryStore.Snapshot, selection: EnterpriseMembershipPresentationStore.Selection) -> some View {
        let renderJoinedEnterpriseIDs = Set(selection.memberships.filter { $0.isWorkspaceJoined }.map(\.id)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        EnterpriseSwitcherDirectoryListContent(showingSearchResults: isShowingSearchResults, isSearching: directory.isSearching) {
            ForEach(isShowingSearchResults ? directory.results : selection.memberships) { enterprise in
                let isJoining = directory.isJoining(state.enterpriseJoinKey(enterprise))
                EnterpriseSwitcherDirectoryRowContent(id: enterprise.id, name: enterprise.name,
                    isJoining: isJoining, onSelect: {
                    guard !isJoining else {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("正在提交申请，请稍候")
                        return
                    }
                    if !enterprise.isWorkspaceEnterable, !enterprise.workspaceDisabledDescription.isEmpty {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(enterprise.workspaceDisabledDescription)
                    } else if enterprise.isWorkspaceJoinPending {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("入企申请等待审批中")
                    } else if enterprise.isWorkspaceJoinRejected {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("入企申请已被拒绝，请联系企业管理员")
                    } else if enterprise.isWorkspaceJoinApproved || self.joinedEnterpriseIDs.contains(enterprise.id) { // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                        state.switchEnterprise(enterprise)
                    } else {
                        state.joinEnterprise(enterprise)
                    }
                }) {
                    EnterpriseMiniCard(
                        enterprise: enterprise,
                        selected: enterprise.id == selection.currentID, // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                        trailingText: isJoining ? "提交中" : enterpriseWorkspaceStateText(enterprise, joined: renderJoinedEnterpriseIDs.contains(enterprise.id))
                    )
                }
            }
        }

        if isShowingSearchResults && !directory.isSearching && directory.results.isEmpty {
            EnterpriseSwitcherDirectoryEmptyContent(message: directory.message)
        }

        if isShowingSearchResults && directory.results.count > 1 {
            EnterpriseSwitcherDirectoryPickHint()
        } else if isShowingSearchResults, let enterprise = directory.results.first {
            let joined = enterprise.isWorkspaceJoinApproved || renderJoinedEnterpriseIDs.contains(enterprise.id)
            let pending = enterprise.isWorkspaceJoinPending
            let rejected = enterprise.isWorkspaceJoinRejected
            let isJoining = directory.isJoining(state.enterpriseJoinKey(enterprise))
            let unavailableReason = enterprise.workspaceDisabledDescription
            let switchUnavailable = joined && !enterprise.canSwitch
            let unavailable = (!enterprise.isWorkspaceEnterable && !unavailableReason.isEmpty) || switchUnavailable
            EnterpriseSwitcherDirectoryActionContent(
                name: enterprise.name, unavailableReason: unavailableReason, unavailable: unavailable,
                isJoining: isJoining, pending: pending, rejected: rejected, joined: joined,
                approved: enterprise.isWorkspaceJoinApproved,
                canUseDirectory: state.canUseEnterpriseDirectory,
                membershipAlreadyJoined: renderJoinedEnterpriseIDs.contains(enterprise.id)
            ) {
                if joined {
                    state.switchEnterprise(enterprise)
                } else {
                    state.joinEnterprise(enterprise)
                }
            }
        } else {
            EnterpriseSwitcherDirectorySearchHint(queryIsEmpty: trimmedQuery.isEmpty)
        }
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_END

    private func enterpriseWorkspaceStateText(_ enterprise: Enterprise, joined: Bool) -> String {
        let unavailableReason = enterprise.workspaceDisabledDescription
        if !enterprise.isWorkspaceEnterable, !unavailableReason.isEmpty {
            return unavailableReason
        }
        if enterprise.isWorkspaceJoinPending {
            return "等待审批"
        }
        if enterprise.isWorkspaceJoinRejected {
            return "已拒绝"
        }
        if enterprise.isWorkspaceJoinApproved {
            return "已通过"
        }
        if joined {
            return enterprise.isWorkspaceEnterable && enterprise.canSwitch ? "已加入" : "不可进入"
        }
        return enterprise.approvalRequired ? "需审批" : "可加入"
    }
}

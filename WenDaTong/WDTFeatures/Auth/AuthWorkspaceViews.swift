import IM4Features
import Security
import SwiftUI
import UIKit
import WebKit

struct AuthPage<Content: View>: View {
    let title: String
    let subtitle: String
    var showsBack = true
    /// 递增该值可让页面滚动到底部。用于“请先勾选协议”这类提示:
    /// 协议勾选区在长表单底部,提示出现时自动滚到底露出勾选区。
    var scrollToBottomTrigger = 0
    @ViewBuilder let content: Content
    @EnvironmentObject private var state: AppState

    var body: some View {
        AuthPageContent(showsBack: showsBack, scrollToBottomTrigger: scrollToBottomTrigger,
            onBack: { state.setAuthScreen(.welcome) }) {
            content
        }
    }
}

struct LoginWorkspaceSelectionView: View {
    @EnvironmentObject private var state: AppState
    @State private var makeDefaultWorkspace = false

    private func sortedEnterprises(in memberships: [Enterprise]) -> [Enterprise] {
        memberships.sorted { lhs, rhs in // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            if lhs.isWorkspaceEnterable != rhs.isWorkspaceEnterable {
                return lhs.isWorkspaceEnterable && !rhs.isWorkspaceEnterable
            }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.loginWorkspacePresentationStore.observe({ $0 }) { presentation in
            // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_BEGIN
            state.authenticationPresentationStore.observeLoading { isLoading in
                // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_BEGIN
                state.authenticationPresentationStore.observeAuthentication { authenticated in
                    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
                    state.enterpriseMembershipStore.observe(\.selection) { selection in
                        selectionContent(presentation, isLoading: isLoading, authenticated: authenticated, membership: selection)
                    }
                    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
                }
                // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_END
            } // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110_END

    private func selectionContent(_ presentation: LoginWorkspacePresentationStore.Snapshot, isLoading: Bool, authenticated: Bool, membership: EnterpriseMembershipPresentationStore.Selection) -> some View { // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        let sortedEnterprises = sortedEnterprises(in: membership.memberships) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        return AuthPage(title: "选择企业", subtitle: "请选择本次要进入的企业。", showsBack: false) {
            AuthWorkspaceSelectionContent(makeDefaultWorkspace: $makeDefaultWorkspace,
                message: presentation.message, isLoading: isLoading, rows: sortedEnterprises.map { enterprise in
                    AuthWorkspaceRowInput(id: enterprise.id, canEnter: enterprise.isWorkspaceEnterable && enterprise.canSwitch,
                        accessibilityLabel: accessibilityLabel(for: enterprise))
                }, row: { id in
                    if let enterprise = sortedEnterprises.first(where: { $0.id == id }) {
                        EnterpriseMiniCard(enterprise: enterprise,
                            selected: enterprise.id == membership.currentID && authenticated,
                            trailingText: trailingText(for: enterprise, defaultWorkspaceID: presentation.defaultWorkspaceID),
                            logoCacheKey: state.enterpriseLogoCacheKey(for: enterprise))
                    }
                }, onSelect: { id, makeDefault in
                    guard let enterprise = sortedEnterprises.first(where: { $0.id == id }) else { return }
                    state.selectLoginWorkspace(enterprise, makeDefault: makeDefault)
                }, onCancel: { state.cancelLoginWorkspaceSelection() })
            .task(id: state.workspaceSelectionLogoPrefetchSignature(for: sortedEnterprises)) {
                await state.prefetchWorkspaceSelectionLogos(sortedEnterprises)
            }
        }
    }

    private func trailingText(for enterprise: Enterprise, defaultWorkspaceID: String) -> String { // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        if enterprise.isWorkspaceJoinPending {
            return "等待审批"
        }
        if enterprise.isWorkspaceJoinRejected {
            return "已拒绝"
        }
        if enterprise.isWorkspaceJoinApproved {
            return enterprise.canSwitch && enterprise.isWorkspaceEnterable ? "已通过" : "不可进入"
        }
        if !enterprise.isWorkspaceEnterable || !enterprise.canSwitch {
            return enterprise.workspaceDisabledDescription.isEmpty ? "不可进入" : "受限"
        }
        return enterprise.id == defaultWorkspaceID ? "默认" : "进入" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
    }

    private func accessibilityLabel(for enterprise: Enterprise) -> String {
        let reason = enterprise.workspaceDisabledDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if enterprise.isWorkspaceJoinPending {
            return "\(enterprise.name)，等待审批"
        }
        if enterprise.isWorkspaceJoinRejected {
            return "\(enterprise.name)，已拒绝"
        }
        if !reason.isEmpty {
            return "\(enterprise.name)，\(reason)"
        }
        return "\(enterprise.name)，可进入"
    }
}

struct EnterpriseMiniCard: View {
    let enterprise: Enterprise
    var selected = false
    var trailingText: String?
    var logoCacheKey: String = ""

    private var canEnterWorkspace: Bool {
        enterprise.isWorkspaceEnterable && enterprise.canSwitch
    }

    private var unavailableText: String {
        guard !canEnterWorkspace else { return "" }
        let reason = enterprise.workspaceDisabledDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "暂不可进入" : reason
    }

    var body: some View {
        AuthEnterpriseMiniCardContent(name: enterprise.name, displayCode: enterprise.displayCode,
            selected: selected, trailingText: trailingText, canEnterWorkspace: canEnterWorkspace,
            unavailableText: unavailableText, inviteLine: enterprise.searchInviteDisplayLine) {
            EnterpriseLogoView(enterprise: enterprise, size: 52, cornerRadius: 18, cacheKey: logoCacheKey)
        }
    }
}

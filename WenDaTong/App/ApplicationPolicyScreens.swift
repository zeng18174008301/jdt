import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox
import CryptoKit

private struct LegacyGlobalPolicyScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: GlobalPolicyScreenshotScenario

    private var peer: IMUser {
        IMUser(
            id: "im-global-policy-target",
            userID: "user-global-policy-target",
            username: "USERNAME_PLACEHOLDER",
            name: scenario == .friendOn ? "可申请同事" : "受控同事",
            title: "跨部门成员",
            department: "策略组",
            departmentPathNames: ["策略组"],
            phone: "",
            email: "",
            status: scenario == .friendOn ? "在线" : "",
            lastLoginAt: scenario == .friendOn ? "今天 08:52" : "",
            enterprise: state.currentEnterprise.name,
            avatarSeed: scenario == .friendOn ? 0x14B8A6 : 0x64748B,
            badges: ["非好友"]
        )
    }

    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    var body: some View {
        let store = state.contactStore
        PublisherSnapshotView(initialValue: store.groups, updates: store.groupDirectoryUpdates) { _ in
            // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
            state.tenantClientPolicyStore.observe(\.groupDirectory) { policy in
                // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
                state.enterpriseMembershipStore.observe(\.current.role) { role in
                    groupDependentContent(role: role, allowsMemberCreation: policy.allowsMemberCreation)
                }
                // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
            }
            // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END

    @ViewBuilder
    private func groupDependentContent(role: String, allowsMemberCreation: Bool) -> some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                content(role: role, allowsMemberCreation: allowsMemberCreation)
            }
            .navigationTitle("全局策略")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func content(role: String, allowsMemberCreation: Bool) -> some View {
        switch scenario {
        case .memberOff, .memberOn, .adminOff:
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    policyHeader
                    groupPermissionSummary(role: role, allowsMemberCreation: allowsMemberCreation)
                    GroupListView()
                        .environmentObject(state)
                        .frame(minHeight: 430)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
        case .friendOff, .friendOn:
            UserProfileView(user: peer)
                .environmentObject(state)
        case .presence:
            policyHeader
                .padding(.horizontal, 16)
                .padding(.top, 18)
        }
    }

    private var policyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iOS Global Policy Smoke")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text("场景：\(scenario.rawValue) · \(state.currentEnterprise.name)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Text(
                state.visibleGroupMemberCount(state.groups.first?.effectiveMemberCount ?? 0)
                    .map { "群人数：\($0) 人" }
                    ?? "群人数：已隐藏"
            )
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.brand)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainCard(radius: 22)
        .accessibilityIdentifier("global_policy_smoke_header")
    }

    private func groupPermissionSummary(role: String, allowsMemberCreation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            policyLine(title: "当前角色", value: role)
            policyLine(title: "建群入口", value: AppState.canCreateGroupChat(role: role, enabled: allowsMemberCreation) ? "显示" : "隐藏")
            state.organizationDirectoryStore.observe({ state.canManageOrganizationDepartments(in: $0, role: role) }) { canManage in // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
                policyLine(title: "组织管理", value: canManage ? "可管理" : "未开放")
            }
            Text(AppState.canCreateGroupChat(role: role, enabled: allowsMemberCreation) ? "成员/管理员策略允许提交建群。" : "管理员已关闭成员建群，已打开 sheet 时提交也会被 AppState 拦截。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainCard(radius: 22)
        .accessibilityIdentifier("global_policy_group_summary")
    }

    private func policyLine(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.ink)
        }
    }
}

private struct LegacyIOSRiskTelemetryWindowSceneInstaller: UIViewRepresentable {
    let onWindowSceneChanged: @MainActor (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> SceneProbeView {
        SceneProbeView(onWindowSceneChanged: onWindowSceneChanged)
    }

    func updateUIView(_ uiView: SceneProbeView, context: Context) {
        uiView.onWindowSceneChanged = onWindowSceneChanged
        uiView.publishWindowScene()
    }

    @MainActor
    final class SceneProbeView: UIView {
        var onWindowSceneChanged: @MainActor (UIWindowScene?) -> Void

        init(onWindowSceneChanged: @escaping @MainActor (UIWindowScene?) -> Void) {
            self.onWindowSceneChanged = onWindowSceneChanged
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishWindowScene()
        }

        func publishWindowScene() {
            onWindowSceneChanged(window?.windowScene)
        }
    }
}

struct GlobalPolicyScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: GlobalPolicyScreenshotScenario

    private var peer: IMUser {
        IMUser(
            id: "im-global-policy-target",
            userID: "user-global-policy-target",
            username: "USERNAME_PLACEHOLDER",
            name: scenario == .friendOn ? "可申请同事" : "受控同事",
            title: "跨部门成员",
            department: "策略组",
            departmentPathNames: ["策略组"],
            phone: "",
            email: "",
            status: scenario == .friendOn ? "在线" : "",
            lastLoginAt: scenario == .friendOn ? "今天 08:52" : "",
            enterprise: state.currentEnterprise.name,
            avatarSeed: scenario == .friendOn ? 0x14B8A6 : 0x64748B,
            badges: ["非好友"]
        )
    }

    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    var body: some View {
        let store = state.contactStore
        PublisherSnapshotView(initialValue: store.groups, updates: store.groupDirectoryUpdates) { _ in
            // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
            state.tenantClientPolicyStore.observe(\.groupDirectory) { policy in
                // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
                state.enterpriseMembershipStore.observe(\.current.role) { role in
                    groupDependentContent(role: role, allowsMemberCreation: policy.allowsMemberCreation)
                }
                // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
            }
            // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END

    @ViewBuilder
    private func groupDependentContent(role: String, allowsMemberCreation: Bool) -> some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                content(role: role, allowsMemberCreation: allowsMemberCreation)
            }
            .navigationTitle("全局策略")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func content(role: String, allowsMemberCreation: Bool) -> some View {
        switch scenario {
        case .memberOff, .memberOn, .adminOff:
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    policyHeader
                    groupPermissionSummary(role: role, allowsMemberCreation: allowsMemberCreation)
                    GroupListView()
                        .environmentObject(state)
                        .frame(minHeight: 430)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
        case .friendOff, .friendOn:
            UserProfileView(user: peer)
                .environmentObject(state)
        case .presence:
            policyHeader
                .padding(.horizontal, 16)
                .padding(.top, 18)
        }
    }

    private var policyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iOS Global Policy Smoke")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text("场景：\(scenario.rawValue) · \(state.currentEnterprise.name)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Text(
                state.visibleGroupMemberCount(state.groups.first?.effectiveMemberCount ?? 0)
                    .map { "群人数：\($0) 人" }
                    ?? "群人数：已隐藏"
            )
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.brand)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainCard(radius: 22)
        .accessibilityIdentifier("global_policy_smoke_header")
    }

    private func groupPermissionSummary(role: String, allowsMemberCreation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            policyLine(title: "当前角色", value: role)
            policyLine(title: "建群入口", value: AppState.canCreateGroupChat(role: role, enabled: allowsMemberCreation) ? "显示" : "隐藏")
            state.organizationDirectoryStore.observe({ state.canManageOrganizationDepartments(in: $0, role: role) }) { canManage in // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
                policyLine(title: "组织管理", value: canManage ? "可管理" : "未开放")
            }
            Text(AppState.canCreateGroupChat(role: role, enabled: allowsMemberCreation) ? "成员/管理员策略允许提交建群。" : "管理员已关闭成员建群，已打开 sheet 时提交也会被 AppState 拦截。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainCard(radius: 22)
        .accessibilityIdentifier("global_policy_group_summary")
    }

    private func policyLine(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.ink)
        }
    }
}

struct IOSRiskTelemetryWindowSceneInstaller: UIViewRepresentable {
    let onWindowSceneChanged: @MainActor (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> SceneProbeView {
        SceneProbeView(onWindowSceneChanged: onWindowSceneChanged)
    }

    func updateUIView(_ uiView: SceneProbeView, context: Context) {
        uiView.onWindowSceneChanged = onWindowSceneChanged
        uiView.publishWindowScene()
    }

    @MainActor
    final class SceneProbeView: UIView {
        var onWindowSceneChanged: @MainActor (UIWindowScene?) -> Void

        init(onWindowSceneChanged: @escaping @MainActor (UIWindowScene?) -> Void) {
            self.onWindowSceneChanged = onWindowSceneChanged
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishWindowScene()
        }

        func publishWindowScene() {
            onWindowSceneChanged(window?.windowScene)
        }
    }
}

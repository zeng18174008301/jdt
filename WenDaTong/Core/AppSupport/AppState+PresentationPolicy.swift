import Combine // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
import Foundation
import SwiftUI // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
import UIKit

// WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
@MainActor
final class TenantClientPolicyPresentationStore {
    struct GroupDirectoryPolicy: Equatable {
        let showsMemberCount: Bool
        let allowsMemberCreation: Bool
    }

    struct Snapshot: Equatable {
        var activeScope = ""
        var policyScope = ""
        var policy: RemoteTenantClientPolicy?
        var groupCountResolution: GroupMemberCountPolicyResolutionState =
            .unresolved(scope: "", minimumGeneration: 0)

        var resolvedPolicy: RemoteTenantClientPolicy? {
            activeScope == policyScope ? policy : nil
        }

        var showsGroupMemberCount: Bool {
            groupCountResolution.permitsVisibleTotal(currentScope: activeScope, policy: resolvedPolicy)
        }

        var allowsMemberGroupCreation: Bool { resolvedPolicy?.allowMemberGroupCreation == true }
        var allowsMemberFriendRequests: Bool { resolvedPolicy?.clientFriendRequests == true }
        var groupDirectory: GroupDirectoryPolicy {
            GroupDirectoryPolicy(showsMemberCount: showsGroupMemberCount, allowsMemberCreation: allowsMemberGroupCreation)
        }
    }

    @Published var snapshot = Snapshot()

    func setActiveScope(_ scope: String) {
        if snapshot.activeScope != scope { snapshot.activeScope = scope }
    }

    func updates<Value: Equatable>(_ project: @escaping (Snapshot) -> Value) -> AnyPublisher<Value, Never> {
        $snapshot.map(project).removeDuplicates().eraseToAnyPublisher()
    }

    func observe<Value: Equatable, Content: View>(
        _ project: @escaping (Snapshot) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(initialValue: project(snapshot), updates: updates(project), content: content)
    }
}

private struct TenantShowsGroupMemberCountKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var tenantShowsGroupMemberCount: Bool? {
        get { self[TenantShowsGroupMemberCountKey.self] }
        set { self[TenantShowsGroupMemberCountKey.self] = newValue }
    }
}
// WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END

extension AppState {
    // MARK: - Bootstrap and Common State

    var canUseEnterpriseDirectory: Bool {
        apiContext.hasIMSession
    }

    var hasActiveIMSession: Bool {
        apiContext.hasIMSession
    }

    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
    var visibleForcedAppPolicyAuthPrompt: AppPolicyForcedAuthRequirement? {
        guard isAuthenticated, apiContext.hasIMSession else { return nil }
        return forcedAppPolicyAuthStore.snapshot.presentation.prompt
    }

    var visibleForcedAppPolicyAuthDestination: AppPolicyForcedAuthRequirement? {
        guard isAuthenticated, apiContext.hasIMSession else { return nil }
        return forcedAppPolicyAuthStore.snapshot.presentation.destination
    }

    func updateVisibleForcedAppPolicyAuthPrompt(_ requirement: AppPolicyForcedAuthRequirement?) {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        if let requirement {
            presentForcedAppPolicyAuthPrompt(requirement)
        } else {
            forcedAppPolicyAuthStore.setPrompt(nil)
        }
    }

    @discardableResult
    func beginForcedAppPolicyAuthPromptDeferral() -> UUID {
        forcedAppPolicyAuthStore.beginPromptDeferral()
    }

    func endForcedAppPolicyAuthPromptDeferral(_ token: UUID) {
        forcedAppPolicyAuthStore.endPromptDeferral(token)
    }

    func updateVisibleForcedAppPolicyAuthDestination(_ requirement: AppPolicyForcedAuthRequirement?) {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        forcedAppPolicyAuthStore.setDestination(requirement)
    }
    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END

    var isRegistrationTenantCodeRequired: Bool { appPolicyPresentationStore.snapshot.authentication.requiresRegistrationCode } // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110

    var isRegistrationEnabledForAuthUI: Bool { appPolicyPresentationStore.snapshot.authentication.registrationEnabled } // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110

    var isEnterpriseCodeFirstForAuthUI: Bool { appPolicyPresentationStore.snapshot.authentication.enterpriseCodeFirst } // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110

    var hasUsablePreAuthEnterpriseContext: Bool {
        preAuthEnterpriseContext?.matchesIdentity(
            appID: apiContext.appID,
            deviceID: apiContext.deviceID
        ) == true
    }

    func enterpriseContextLogoURL(_ context: PreAuthEnterpriseContext) -> String { // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110
        let rawValue = context.tenantLogoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return "" }
        if let absolute = URL(string: rawValue), absolute.scheme != nil {
            return rawValue
        }
        guard let route = Self.freshRuntimeEndpoint(context.runtimeRoutes, service: .tenantAPI),
              let base = URL(string: route),
              let resolved = URL(string: rawValue, relativeTo: base)?.absoluteURL else {
            return ""
        }
        return resolved.absoluteString
    }

    var isPhoneAuthEnabledForAuthUI: Bool { appPolicyPresentationStore.snapshot.authentication.phoneAuthEnabled } // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110

    func normalizeAuthScreenForCurrentAppPolicy() {
        if hasResolvedCurrentAppPolicyForAuthUI, !isPhoneAuthEnabledForAuthUI {
            clearRememberedPhoneLoginCredentialsForCurrentPolicy()
        }
        let phoneNormalized = PhoneAuthPresentationPolicy.normalizedScreen(
            authScreen,
            phoneAuthEnabled: isPhoneAuthEnabledForAuthUI
        )
        let normalized: AuthScreen
        if isAuthenticated || apiContext.hasIMSession {
            normalized = phoneNormalized
        } else {
            normalized = EnterpriseCodeAuthPresentationPolicy.normalizedScreen(
                phoneNormalized,
                enterpriseCodeFirst: isEnterpriseCodeFirstForAuthUI,
                registrationEnabled: isRegistrationEnabledForAuthUI,
                hasUsableContext: hasUsablePreAuthEnterpriseContext
            )
        }
        if authScreen != normalized {
            setAuthScreen(normalized) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        }
    }

    func normalizeAuthScreenForPhoneAuthPolicy() {
        normalizeAuthScreenForCurrentAppPolicy()
    }

    func applyCurrentAppAuthRouting(
        _ policy: RemoteAppCurrentPolicy,
        allowPreferredAutoResolve _: Bool
    ) {
        if !policy.enterpriseCodeFirst {
            invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        }
        normalizeAuthScreenForCurrentAppPolicy()
        // Enterprise-code-first is an explicit trust boundary. Never acquire or
        // resolve the server's preferred code on behalf of the user.
    }

    var registrationTenantCodeRequirementText: String {
        if isEnterpriseCodeFirstForAuthUI {
            return "当前企业由已验证的企业码上下文绑定，无需再次填写。"
        }
        if isRegistrationTenantCodeRequired {
            return "注册时必须填写企业编码或邀请码"
        }
        if currentAppPolicy == nil {
            return "正在读取应用策略；提交前会自动校验。"
        }
//        return "输入企业编码或邀请码加入已有企业；留空将进入演示企业，立即体验完整功能"
        return "输入企业编码或邀请码加入已有企业；未填写时将进入示例企业，可使用主要功能"
    }

    var isRegistrationTenantCodeRequirementEmphasized: Bool {
        isRegistrationTenantCodeRequired || currentAppPolicy != nil
    }

    var isWorkspaceSwitchDisabledByPolicy: Bool {
        currentAppPolicy?.allowWorkspaceSwitch == false
    }

    func canOpenEnterpriseSwitcher(for enterprise: Enterprise) -> Bool {
        !isWorkspaceSwitchDisabledByPolicy
            && enterprise.canSwitch
            && enterprise.isWorkspaceEnterable
    }

    func enterpriseSwitchDisabledMessage(for enterprise: Enterprise) -> String {
        if isWorkspaceSwitchDisabledByPolicy {
            return "管理员已关闭企业切换"
        }
        let reason = enterprise.workspaceDisabledDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enterprise.canSwitch {
            return reason.isEmpty ? "该企业暂不可切换，请联系管理员确认成员状态" : reason
        }
        if !enterprise.isWorkspaceEnterable {
            return reason.isEmpty ? "该企业暂不可进入，请联系管理员确认状态" : reason
        }
        return ""
    }

    var enterpriseDirectoryStatusText: String {
        canUseEnterpriseDirectory ? "企业列表来自服务端企业工作区。" : "请先登录后再搜索、加入或切换企业。"
    }

    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110: the directory snapshot supplies per-enterprise progress.

    var canCreateGroupChat: Bool {
        Self.canCreateGroupChat(role: currentEnterprise.role, policy: resolvedTenantClientPolicy)
    }

    nonisolated static func enterpriseRoleCanCreateGroup(_ rawRole: String) -> Bool {
        privilegedRoleCanManageOrganization(rawRole)
    }

    nonisolated static func privilegedRoleCanManageOrganization(_ rawRole: String) -> Bool {
        let normalized = rawRole
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let compact = normalized.replacingOccurrences(of: "_", with: "")
        let creatableRoles: Set<String> = [
            "internal", "staff", "employee", "admin", "administrator", "manager",
            "super_admin", "superadmin",
            "owner", "creator",
            "tenant_owner", "tenant_admin", "tenant_manager", "tenant_staff",
            "merchant_owner", "merchant_admin", "merchant_manager", "merchant_staff",
            "internal_admin", "internal_staff",
            "platform_admin", "platform_internal",
            "workspace_owner", "workspace_admin",
            "enterprise_owner", "enterprise_admin",
            "company_owner", "company_admin",
            "管理员", "内部人员", "超级管理员", "企业管理员", "商户管理员", "负责人", "所有者"
        ]
        return creatableRoles.contains(normalized) || creatableRoles.contains(compact)
    }

    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
    nonisolated static func canCreateGroupChat(role: String, policy: RemoteTenantClientPolicy?) -> Bool {
        canCreateGroupChat(role: role, enabled: policy?.allowMemberGroupCreation == true)
    }

    nonisolated static func canCreateGroupChat(role: String, enabled: Bool) -> Bool {
        if privilegedRoleCanManageOrganization(role) {
            return true
        }
        return enabled
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    var canManageOrganizationDepartments: Bool {
        canManageOrganizationDepartments(in: organizationDirectoryStore.snapshot)
    }

    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
    func canManageOrganizationDepartments(in directory: OrganizationDirectoryStore.Snapshot) -> Bool {
        canManageOrganizationDepartments(in: directory, role: currentEnterprise.role)
    }

    func canManageOrganizationDepartments(in directory: OrganizationDirectoryStore.Snapshot, role: String) -> Bool {
        guard directory.departmentEnabled(appPolicyEnabled: currentAppPolicy?.departmentEnabled == true) else { return false }
        return directory.tree?.canManage == true
            || directory.tree?.canManageDepartment == true
            || Self.privilegedRoleCanManageOrganization(role)
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END

    nonisolated static func friendApplyResolution(
        outcome: String,
        relationStatus: String,
        status: String,
        directlyEstablished: Bool
    ) -> FriendApplyResolution {
        if directlyEstablished {
            return .established
        }
        let establishedValues: Set<String> = [
            "friend",
            "accepted",
            "established",
            "friendship_established",
            "already_friend"
        ]
        let normalizedValues = [outcome, relationStatus, status].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if normalizedValues.contains(where: establishedValues.contains) {
            return .established
        }
        let terminalValues: Set<String> = [
            "suppressed",
            "application_suppressed",
            "rejected",
            "application_rejected",
            "cancelled",
            "canceled",
            "application_cancelled",
            "expired",
            "application_expired"
        ]
        return normalizedValues.contains(where: terminalValues.contains) ? .terminal : .pending
    }

    nonisolated static func friendApplyResolution(_ result: RemoteFriendApplyResult) -> FriendApplyResolution {
        friendApplyResolution(
            outcome: result.outcome,
            relationStatus: result.relationStatus,
            status: result.status,
            directlyEstablished: result.directlyEstablished
        )
    }

    nonisolated static func isFriendRelationChangedConflictCode(_ code: String) -> Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "friend_relation_changed"
    }

    nonisolated static func isFriendRelationRealtimeEvent(event: String, kind: String) -> Bool {
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedKind == "friend_application"
            || normalizedKind == "friend_request"
            || normalizedKind == "friend_relation"
            || normalizedKind == "friend"
            || normalizedEvent == "friend_application.created"
            || normalizedEvent == "friend_application.reviewed"
            || normalizedEvent == "friend_application.rejected"
            || normalizedEvent == "friend_application.approved"
            || normalizedEvent == "friend_application.updated"
            || normalizedEvent == "friend_application.suppressed"
            || normalizedEvent == "friend_application.cancelled"
            || normalizedEvent == "friend_relation.established"
            || normalizedEvent == "friend_application_created"
            || normalizedEvent == "friend_application_reviewed"
            || normalizedEvent == "friend_application_rejected"
            || normalizedEvent == "friend_application_suppressed"
            || normalizedEvent == "friend_application_cancelled"
            || normalizedEvent == "friend_relation_established"
            || normalizedEvent == "friend.request.created"
            || normalizedEvent == "friend_request.created"
    }

    nonisolated static func isSuppressedFriendApplication(status: String, outcome: String) -> Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedOutcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedStatus == "suppressed" || normalizedOutcome == "application_suppressed"
    }

    // JHT_MOD_BEGIN APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改开始：媒体缓存扩展需要读取原有租户策略解析结果
    var resolvedTenantClientPolicy: RemoteTenantClientPolicy? {
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
        let snapshot = tenantClientPolicyStore.snapshot
        guard snapshot.policyScope == remoteDataScopeKey(for: apiContext) else { return nil }
        return snapshot.policy
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
    }
    // JHT_MOD_END APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改结束

    var tenantDeviceLimitPresentationText: String {
        tenantDeviceMultiplicityPolicyState.presentationText
    }

    var shouldShowGroupMemberCount: Bool {
        tenantClientPolicyStore.snapshot.groupCountResolution.permitsVisibleTotal( // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
            currentScope: remoteDataScopeKey(for: apiContext),
            policy: resolvedTenantClientPolicy
        )
    }

    func visibleGroupMemberCount(_ candidates: Int?..., showsCount: Bool? = nil) -> Int? { // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
        guard showsCount ?? shouldShowGroupMemberCount else { return nil } // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
        return candidates.compactMap { $0 }.max().flatMap { $0 > 0 ? $0 : nil }
    }

    var canCurrentUserInitiateFriendRequest: Bool {
        Self.canInitiateFriendRequest(
            role: currentEnterprise.role,
            policy: resolvedTenantClientPolicy
        )
    }

    nonisolated static func canInitiateFriendRequest(
        role rawRole: String,
        policy: RemoteTenantClientPolicy?
    ) -> Bool {
        canInitiateFriendRequest(role: rawRole, enabled: policy?.clientFriendRequests == true) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
    }

    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
    nonisolated static func canInitiateFriendRequest(role rawRole: String, enabled: Bool) -> Bool {
        let normalizedRole = rawRole
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedRole {
        case "internal", "staff", "内部用户", "admin", "管理员", "super_admin", "system", "service":
            return true
        default:
            return enabled
        }
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END

    nonisolated static func canInitiateFriendRequestFromSearch(pairCanApply: Bool) -> Bool {
        pairCanApply
    }

    var shouldShowLastLoginTime: Bool {
        resolvedTenantClientPolicy?.showLastLoginTime == true
    }

    func visibleLastLoginText(for user: IMUser) -> String? {
        Self.lastLoginPresentationText(rawValue: user.lastLoginAt, policy: resolvedTenantClientPolicy)
    }

    nonisolated static func lastLoginPresentationText(
        rawValue: String,
        policy: RemoteTenantClientPolicy?
    ) -> String? {
        nil
    }

    func resolvedLastLoginText(_ rawValue: String?) -> String {
        Self.lastLoginPresentationText(rawValue: rawValue ?? "", policy: resolvedTenantClientPolicy) ?? ""
    }

    var organizationManagementCandidateUsers: [IMUser] {
        var byID: [String: IMUser] = [:]
        func insert(_ user: IMUser) {
            let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            byID[id] = user
        }
        insert(currentUser)
        contacts.forEach(insert)
        organizationDirectoryStore.snapshot.memberIndex.values.forEach(insert) // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var systemNoticeAvatarURL: String {
        resolveTenantAssetURL("/avatars/system-notice-logo-96.png")
    }

    func copyUserID(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("暂无可复制ID")
            return
        }
        UIPasteboard.general.string = normalized
        syncIOSRiskTelemetrySession()
        iosRiskTelemetry.recordClipboardCopy(
            characterCount: normalized.count,
            resourceType: "user",
            resourceID: normalized
        )
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已复制用户ID")
    }

    var shouldPollActiveConversation: Bool {
        !isRealtimeConnected
    }

    func isConversationMessageSyncInFlight(_ conversationID: String) -> Bool {
        conversationPollingPlan(for: conversationID).isMessageSyncInFlight
    }

    func shouldPollConversation(_ conversationID: String) -> Bool {
        conversationPollingPlan(for: conversationID).shouldPoll
    }

    private func conversationPollingPlan(for conversationID: String) -> ConversationStore.ConversationPollingPlan {
        conversationStore.conversationPollingPlan(
            conversationID: conversationID,
            shouldPollActiveConversation: shouldPollActiveConversation,
            historyKeyForConversation: { conversationHistoryStateKey(for: $0) }
        )
    }

    var activeConversationHistoryScope: String {
        activeConversationScopedStateKeyContext(for: "").scope
    }

    func rememberedConversationBottomSeq(for conversationID: String) -> Int64 {
        conversationStore.rememberedConversationBottomSeq(stateKey: conversationBottomStateKey(conversationID))
    }

    func rememberConversationBottomSeq(_ seq: Int64, for conversationID: String) {
        conversationStore.rememberConversationBottomSeq(seq, stateKey: conversationBottomStateKey(conversationID))
    }

    private func conversationBottomStateKey(_ conversationID: String) -> String {
        activeConversationScopedStateKeyContext(for: conversationID).stateKey
    }

    func activeConversationScopedStateKeyContext(for conversationID: String) -> ConversationStore.ActiveConversationScopedStateKeyContext {
        conversationStore.activeConversationScopedStateKeyContext(
            tenantID: apiContext.tenantID,
            imUID: apiContext.imUID,
            conversationID: conversationID
        )
    }

}

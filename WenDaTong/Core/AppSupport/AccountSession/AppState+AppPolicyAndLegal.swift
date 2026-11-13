import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

// WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
@MainActor
final class AppPolicyPresentationStore {
    struct Authentication: Equatable {
        let hasPolicy: Bool
        let hasResolved: Bool
        let enterpriseCodeFirst: Bool
        let requiresRegistrationCode: Bool
        let registrationEnabled: Bool
        let phoneAuthEnabled: Bool
    }

    struct SupportContact: Equatable {
        let email: String
        let configured: Bool
        let failed: Bool
    }

    struct Snapshot: Equatable {
        var currentAppPolicy: RemoteAppCurrentPolicy?
        var currentAppPolicyErrorMessage: String?
        var hasResolvedCurrentAppPolicyForAuthUI = false
        var isPhoneAuthDisabledByServer = false

        var authentication: Authentication {
            let enterpriseCodeFirst = currentAppPolicy?.enterpriseCodeFirst == true
            return Authentication(
                hasPolicy: currentAppPolicy != nil,
                hasResolved: hasResolvedCurrentAppPolicyForAuthUI,
                enterpriseCodeFirst: enterpriseCodeFirst,
                requiresRegistrationCode: enterpriseCodeFirst || currentAppPolicy?.allowDefaultTenantJoin == false,
                registrationEnabled: hasResolvedCurrentAppPolicyForAuthUI && currentAppPolicy?.registrationEnabled == true,
                phoneAuthEnabled: PhoneAuthPresentationPolicy.isEnabled(
                    policyValue: currentAppPolicy?.phoneAuthEnabled,
                    hasResolvedPolicy: hasResolvedCurrentAppPolicyForAuthUI,
                    disabledByServer: isPhoneAuthDisabledByServer
                )
            )
        }

        var supportContact: SupportContact {
            SupportContact(
                email: currentAppPolicy?.supportContactEmail ?? "",
                configured: currentAppPolicy?.supportContactConfigured == true,
                failed: currentAppPolicyErrorMessage != nil
            )
        }

        var departmentEnabled: Bool { currentAppPolicy?.departmentEnabled == true }
        var workspaceSwitchDisabled: Bool { currentAppPolicy?.allowWorkspaceSwitch == false }
    }

    @Published var snapshot = Snapshot()

    func installResolvedPolicy(_ policy: RemoteAppCurrentPolicy) {
        var next = snapshot
        next.currentAppPolicy = policy
        next.hasResolvedCurrentAppPolicyForAuthUI = true
        next.isPhoneAuthDisabledByServer = !policy.phoneAuthEnabled
        snapshot = next
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
// WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END

extension AppState {
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110: callers receive their own content and error together.
    func legalDocumentRequestContext() -> IMAPIContext? {
        let activeTenantID = apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !activeTenantID.isEmpty {
            return apiContext
        }
        guard let enterpriseContext = usablePreAuthEnterpriseContext(),
              let validatedRoutes = enterpriseContext.runtimeRoutes.validated(
                appID: enterpriseContext.appID,
                tenantID: enterpriseContext.tenantID
              ),
              let tenantEndpoint = validatedRoutes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first,
              let tenantBaseURL = IMAPIClient.normalizedTenantAPIBaseURL(tenantEndpoint) else {
            return nil
        }
        return IMAPIContext(
            platformToken: nil,
            accountID: nil,
            tenantID: enterpriseContext.tenantID,
            imUID: nil,
            imToken: nil,
            tenantAPIBaseURL: tenantBaseURL.absoluteString,
            imAPIBaseURL: nil,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: enterpriseContext.appID,
            deviceID: enterpriseContext.deviceID
        )
    }
    // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

    func legalDocumentFailureMessage(_ error: Error) -> String {
        let code = appPolicyErrorCode(from: error)
        switch code {
        case "legal_doc_app_id_required", "app_id_required", "missing_app_id":
            return "当前应用配置缺失，请联系管理员"
        case "legal_doc_manifest_not_synced", "legal_doc_manifest_not_found":
            return "协议内容暂未同步，请在平台后台发布并同步后重试"
        case "legal_doc_platform_unavailable", "legal_doc_sign_failed":
            return "协议内容暂不可用，请稍后再试"
        case "rate_limited", "too_many_requests":
            return "协议内容请求过于频繁，请稍后再试"
        default:
            if code.contains("legal_doc_manifest_not_synced") || code.contains("legal_doc_manifest_not_found") {
                return "协议内容暂未同步，请在平台后台发布并同步后重试"
            }
            return "协议内容暂不可用，请稍后再试"
        }
    }

    @discardableResult
    func refreshCurrentAppPolicyAndDepartmentRuntime(reason: String, force: Bool = true) async -> Bool {
        let previousPolicyDepartmentEnabled = currentAppPolicy?.departmentEnabled == true
        let previousEffectiveDepartmentEnabled = isDepartmentFeatureEnabled
        let refreshed = await refreshCurrentAppPolicyForAuthUI(force: force)
        let nextPolicyDepartmentEnabled = currentAppPolicy?.departmentEnabled == true
        let nextEffectiveDepartmentEnabled = isDepartmentFeatureEnabled
        let departmentPolicyChanged = previousPolicyDepartmentEnabled != nextPolicyDepartmentEnabled
            || previousEffectiveDepartmentEnabled != nextEffectiveDepartmentEnabled
        let organizationManagementGrantMissing = nextEffectiveDepartmentEnabled
            && canCreateGroupChat
            && organizationTree?.canManage != true
            && organizationTree?.canManageDepartment != true
        let shouldRefreshDepartmentRuntime = departmentPolicyChanged
            || (nextEffectiveDepartmentEnabled && (organizationTree == nil || organizationSyncErrorMessage != nil || organizationManagementGrantMissing))
        guard refreshed, shouldRefreshDepartmentRuntime else { return refreshed }
        guard isAuthenticated, apiContext.hasIMSession else { return refreshed }

        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return refreshed }
        _ = await refreshStoredAuthSessionIfNeeded(
            reason: "department_policy_\(reason)",
            silent: true,
            context: context,
            scope: scope
        )

        let refreshedContext = apiContext
        let refreshedScope = remoteDataScopeKey(for: refreshedContext)
        guard refreshedContext.hasIMSession, isCurrentRemoteScope(refreshedScope) else { return refreshed }
        guard let devicePolicyAuthority = beginTenantDevicePolicyRequest(context: refreshedContext) else {
            return refreshed
        }
        let profileAuthorityRequest = beginCurrentProfileRead(context: refreshedContext)
        if let tenantContext = try? await api.tenantContext(context: refreshedContext) {
            guard isCurrentRemoteScope(refreshedScope) else { return refreshed }
            if isCurrentTenantDevicePolicyRequest(devicePolicyAuthority) {
                applyTenantContext(
                    tenantContext,
                    devicePolicyAuthority: devicePolicyAuthority,
                    profileAuthorityRequest: profileAuthorityRequest
                )
            }
        } else {
            markGroupMemberCountPolicyUnresolved(scope: refreshedScope)
            markTenantDevicePolicyUnavailable(authority: devicePolicyAuthority)
        }
        await refreshOrganizationDirectoryForCurrentSnapshot()
        return refreshed
    }

    func loadCurrentAppPolicy(force: Bool = false) async throws -> RemoteAppCurrentPolicy {
        try await loadCurrentAppPolicy(force: force, contactOwner: nil)
    }

    // WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112
    private func loadCurrentAppPolicy(force: Bool = false, contactOwner: ContactHTTPRequestOwner?) async throws -> RemoteAppCurrentPolicy {
        try contactOwner?.check(requiresExactAuthority: true)
        let appID = IMAPIContext.normalizedIOSAppID(apiContext.appID)
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            forceDisableAccessDiagnosticsOverlay()
            throw IMAPIError.missingContext("app_id")
        }
        if appID != apiContext.appID {
            disableAccessDiagnosticsOverlay()
            apiContext.appID = appID
            apiContext.save(sessionStore: protectedSessionStore)
        }
        if !force,
           let policy = currentAppPolicy,
           cachedAppPolicyMatchesCurrentAppID(policy, appID: appID),
           let expiresAt = currentAppPolicyExpiresAt,
           expiresAt > Date() {
            appPolicyPresentationStore.snapshot.hasResolvedCurrentAppPolicyForAuthUI = true // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            appPolicyPresentationStore.snapshot.isPhoneAuthDisabledByServer = !policy.phoneAuthEnabled // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            normalizeAuthScreenForPhoneAuthPolicy()
            applyAccessDiagnosticsPolicy(policy, source: "cache")
            return policy
        }
        beginAccessDiagnosticsPolicyFetch(appID: appID)
        var lastError: Error?
        for candidate in IMAPIContext.iosAppIDCandidates(preferred: appID) {
            do {
                let policy: RemoteAppCurrentPolicy
                if let contactOwner, let client = api as? IMAPIClient {
                    policy = try await client.currentAppPolicy(appID: candidate, forceRefresh: force, contactOwner: contactOwner)
                } else {
                    policy = try await api.currentAppPolicy(appID: candidate, forceRefresh: force)
                }
                try contactOwner?.check(requiresExactAuthority: true)
                guard policy.isUsable else {
                    forceDisableAccessDiagnosticsOverlay()
                    // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112
                    IMAppPolicyLastGoodStore.clear(appID: candidate, defaults: appPolicyLastGoodDefaults)
                    appPolicyPresentationStore.snapshot.currentAppPolicy = nil // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                    currentAppPolicyExpiresAt = nil
                    throw IMAPIError.businessForbidden(
                        code: policy.status.localizedCaseInsensitiveContains("disabled") ? "app_disabled" : "app_inactive",
                        message: currentAppPolicyBlockedMessage(policy),
                        error: nil
                    )
                }
                let normalizedPolicyAppID = IMAPIContext.normalizedIOSAppID(policy.appID)
                if !normalizedPolicyAppID.isEmpty, normalizedPolicyAppID != apiContext.appID {
                    apiContext.appID = normalizedPolicyAppID
                    apiContext.save(sessionStore: protectedSessionStore)
                }
                appPolicyPresentationStore.installResolvedPolicy(policy) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                applyCurrentAppAuthRouting(policy, allowPreferredAutoResolve: true)
                // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_BEGIN
                IMAppPolicyLastGoodStore.save(policy, appID: normalizedPolicyAppID.isEmpty ? candidate : normalizedPolicyAppID,
                    defaults: appPolicyLastGoodDefaults)
                // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_END
                applyAccessDiagnosticsPolicy(policy, source: "live")
                if !policy.departmentEnabled {
                    clearOrganizationDirectory(disabled: true)
                }
                appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = nil // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                currentAppPolicyExpiresAt = Date().addingTimeInterval(TimeInterval(max(0, policy.cacheTTLSeconds)))
                return policy
            } catch {
                try contactOwner?.check(requiresExactAuthority: true)
                lastError = error
                if DisasterRecoveryFallbackClassifier.isAppPolicyFailClosedError(error) {
                    forceDisableAccessDiagnosticsOverlay()
                    // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112
                    IMAppPolicyLastGoodStore.clear(appID: candidate, defaults: appPolicyLastGoodDefaults)
                    appPolicyPresentationStore.snapshot.currentAppPolicy = nil // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                    currentAppPolicyExpiresAt = nil
                    throw error
                }
                if DisasterRecoveryFallbackClassifier.shouldFallbackFromPlatformFailure(error),
                   let fallback = loadLastGoodAppPolicy(appID: appID) {
                    return fallback
                }
                guard shouldTryNextCurrentAppPolicyCandidate(after: error) else {
                    disableAccessDiagnosticsOverlay()
                    throw error
                }
            }
        }
        disableAccessDiagnosticsOverlay()
        throw lastError ?? IMAPIError.missingContext("app_id")
    }

    private func cachedAppPolicyMatchesCurrentAppID(_ policy: RemoteAppCurrentPolicy, appID: String) -> Bool {
        let policyAppID = IMAPIContext.normalizedIOSAppID(policy.appID)
        let currentAppID = IMAPIContext.normalizedIOSAppID(appID)
        return !policyAppID.isEmpty && policyAppID == currentAppID
    }

    private func shouldTryNextCurrentAppPolicyCandidate(after error: Error) -> Bool {
        if DisasterRecoveryFallbackClassifier.isAppPolicyFailClosedError(error)
            || DisasterRecoveryFallbackClassifier.shouldFallbackFromPlatformFailure(error) {
            return false
        }
        let code = appPolicyErrorCode(from: error)
        return [
            "legacy_app_id_mismatch"
        ].contains(code) || code.contains("app_not_found")
    }

    private func loadLastGoodAppPolicy(appID: String) -> RemoteAppCurrentPolicy? {
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112
        guard let entry = IMAppPolicyLastGoodStore.usable(appID: appID, defaults: appPolicyLastGoodDefaults) else { return nil }
        appPolicyPresentationStore.installResolvedPolicy(entry.policy) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        applyCurrentAppAuthRouting(entry.policy, allowPreferredAutoResolve: false)
        appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = nil // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        applyAccessDiagnosticsPolicy(entry.policy, source: "last-good")
        let normalizedPolicyAppID = IMAPIContext.normalizedIOSAppID(entry.policy.appID)
        if !normalizedPolicyAppID.isEmpty, normalizedPolicyAppID != apiContext.appID {
            apiContext.appID = normalizedPolicyAppID
            apiContext.save(sessionStore: protectedSessionStore)
        }
        if !entry.policy.departmentEnabled {
            clearOrganizationDirectory(disabled: true)
        }
        print("[JHT DR] app_policy_last_good app_id=\(IMAPIContext.normalizedIOSAppID(appID)) online_fresh=\(entry.isOnlineFresh)")
        return entry.policy
    }

    func configureForcedAppPolicyRequestGate() {
        guard let client = api as? IMAPIClient else { return }
        client.forcedAuthRequestGate = { [weak self] descriptor in
            try await self?.enforceForcedAppPolicyRequestGate(descriptor)
        }
    }

    private func enforceForcedAppPolicyRequestGate(_ descriptor: IMAPIRequestDescriptor) async throws {
        guard shouldApplyForcedAppPolicyGate(to: descriptor) else { return }
        let contactOwner = ContactHTTPRequestOwner.current
        try contactOwner?.check(requiresExactAuthority: true)
        guard let requirement = try await pendingForcedAppPolicyRequirementForRequestGate(contactOwner: contactOwner) else { return }
        try contactOwner?.check(requiresExactAuthority: true)
        presentForcedAppPolicyAuthPrompt(requirement)
        throw IMAPIError.forcedAuthRequired(requirement)
    }

    private func shouldApplyForcedAppPolicyGate(to descriptor: IMAPIRequestDescriptor) -> Bool {
        guard descriptor.hasBearerToken else { return false }
        let dynamicTenantBase = IMAPIClient.normalizedTenantAPIBaseURL(apiContext.tenantAPIBaseURL)
        let dynamicIMBase = IMAPIClient.normalizedIMAPIBaseURL(apiContext.imAPIBaseURL)
        guard isSameAPIBase(descriptor.base, api.tenantBase)
            || isSameAPIBase(descriptor.base, api.imBase)
            || dynamicTenantBase.map({ isSameAPIBase(descriptor.base, $0) }) == true
            || dynamicIMBase.map({ isSameAPIBase(descriptor.base, $0) }) == true else {
            return false
        }
        return !isForcedAppPolicyAuthAllowedRequest(descriptor)
    }

    private func isForcedAppPolicyAuthAllowedRequest(_ descriptor: IMAPIRequestDescriptor) -> Bool {
        let path = normalizedAPIPath(descriptor.path)
        let method = descriptor.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allowedExactPaths: Set<String> = [
            "/api/tenant/me/verification-status",
            "/api/tenant/me/phone/captcha",
            "/api/tenant/me/phone/verify",
            "/api/tenant/me/real-name/submit"
        ]
        if allowedExactPaths.contains(path) {
            return true
        }
        if method == "GET", path == "/api/tenant/me/profile" {
            return true
        }
        return path.hasPrefix("/api/tenant/captcha/")
    }

    private func normalizedAPIPath(_ rawPath: String) -> String {
        let pathWithoutQuery = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        let trimmed = pathWithoutQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed.lowercased() : "/\(trimmed.lowercased())"
    }

    private func isSameAPIBase(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.normalizedAPIBaseKey == rhs.normalizedAPIBaseKey
    }

    private func pendingForcedAppPolicyRequirementForRequestGate(
        contactOwner: ContactHTTPRequestOwner?
    ) async throws -> AppPolicyForcedAuthRequirement? {
        guard isAuthenticated, apiContext.hasIMSession else { return nil }
        let scope = remoteDataScopeKey(for: apiContext)
        let policy: RemoteAppCurrentPolicy
        do {
            policy = try await loadCurrentAppPolicy(contactOwner: contactOwner)
        } catch {
            try contactOwner?.check(requiresExactAuthority: true)
            appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = currentAppPolicyFailureMessage(error) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            return nil
        }
        try contactOwner?.check(requiresExactAuthority: true)
        guard policy.requireRealName || policy.requirePhoneVerification else { return nil }
        if verificationRequirementAuthorityScopeKey != scope, isAuthenticated, apiContext.hasIMSession {
            await refreshVerificationStatus(contactOwner: contactOwner)
            try contactOwner?.check(requiresExactAuthority: true)
        }
        guard verificationRequirementAuthorityScopeKey == scope else {
            return policy.requirePhoneVerification ? .phone : .realName
        }
        return AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: currentUser)
    }

    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
    func presentForcedAppPolicyAuthPrompt(_ requirement: AppPolicyForcedAuthRequirement) {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        guard forcedAppPolicyAuthDestination == nil,
              forcedAppPolicyAuthStore.snapshot.pendingDestination == nil,
              forcedAppPolicyAuthPrompt != requirement else { return }
        forcedAppPolicyAuthStore.setPrompt(requirement)
    }
    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END

    func ensureCurrentAppPolicyForAuth() async -> RemoteAppCurrentPolicy? {
        do {
            let policy = try await loadCurrentAppPolicy()
            guard policy.isUsable else {
                let message = currentAppPolicyBlockedMessage(policy)
                appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = message // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
                return nil
            }
            return policy
        } catch {
            let message = currentAppPolicyFailureMessage(error)
            appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = message // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return nil
        }
    }

    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
    func openForcedAppPolicyAuthDestination(_ requirement: AppPolicyForcedAuthRequirement) {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        guard forcedAppPolicyAuthStore.beginDestinationTransition(requirement) else { return }
        scheduleForcedAppPolicyAuthDestinationTransition(requirement)
    }

    private func scheduleForcedAppPolicyAuthDestinationTransition(
        _ requirement: AppPolicyForcedAuthRequirement
    ) {
        forcedAppPolicyAuthDestinationTransitionTask?.cancel()
        let scope = remoteDataScopeKey(for: apiContext)
        forcedAppPolicyAuthDestinationTransitionTask = Task { @MainActor [weak self] in
            do {
                // UIKit's alert dismissal is animated. Starting a full-screen cover in the
                // same transition reproduces NSInternalInconsistencyException on iOS 26.
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.isAuthenticated,
                  self.apiContext.hasIMSession,
                  self.isCurrentRemoteScope(scope),
                  self.forcedAppPolicyAuthStore.completeDestinationTransition(requirement) else {
                self.forcedAppPolicyAuthStore.cancelDestinationTransition()
                self.forcedAppPolicyAuthDestinationTransitionTask = nil
                return
            }
            self.forcedAppPolicyAuthDestinationTransitionTask = nil
        }
    }

    func cancelForcedAppPolicyAuthDestinationTransition() {
        forcedAppPolicyAuthDestinationTransitionTask?.cancel()
        forcedAppPolicyAuthDestinationTransitionTask = nil
        forcedAppPolicyAuthStore.cancelDestinationTransition()
    }

    func forcedAppPolicyAuthDestinationDidDismiss() {
        forcedAppPolicyAuthStore.setDestination(nil)
        Task { [weak self] in
            await self?.evaluateForcedAppPolicyAuthIfNeeded(
                forceRefreshVerification: true,
                reason: "forced_auth_flow_dismissed"
            )
        }
    }

    func evaluateForcedAppPolicyAuthIfNeeded(
        forceRefreshVerification: Bool = false,
        reason: String = ""
    ) async {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        if forcedAppPolicyAuthScopeKey != scope {
            forcedAppPolicyAuthScopeKey = scope
            cancelForcedAppPolicyAuthDestinationTransition()
            forcedAppPolicyAuthStore.clearPresentation()
        }

        let policy: RemoteAppCurrentPolicy
        do {
            policy = try await loadCurrentAppPolicy()
        } catch {
            appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = currentAppPolicyFailureMessage(error) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            return
        }
        guard isAuthenticated, isCurrentRemoteScope(scope) else { return }
        guard policy.requireRealName || policy.requirePhoneVerification else { return }

        if forceRefreshVerification || verificationRequirementAuthorityScopeKey != scope {
            await refreshVerificationStatus()
        }
        guard isAuthenticated, isCurrentRemoteScope(scope) else { return }
        guard forcedAppPolicyAuthPrompt == nil, forcedAppPolicyAuthDestination == nil else { return }

        let requirement = verificationRequirementAuthorityScopeKey == scope
            ? AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: currentUser)
            : (policy.requirePhoneVerification ? .phone : .realName)
        if let requirement {
            presentForcedAppPolicyAuthPrompt(requirement)
        }
    }

    func resetForcedAppPolicyAuthState() {
        forcedAppPolicyAuthDestinationTransitionTask?.cancel()
        forcedAppPolicyAuthDestinationTransitionTask = nil
        forcedAppPolicyAuthStore.reset()
        forcedAppPolicyAuthScopeKey = ""
        verificationRequirementAuthorityScopeKey = ""
    }
    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END

    private func currentAppPolicyBlockedMessage(_ policy: RemoteAppCurrentPolicy) -> String {
        let status = policy.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.localizedCaseInsensitiveContains("disabled") || status.localizedCaseInsensitiveContains("停用") {
            return "当前应用已停用，请联系管理员"
        }
        return "当前应用暂不可用，请联系管理员"
    }

    func currentAppPolicyFailureMessage(_ error: Error) -> String {
        let code = appPolicyErrorCode(from: error)
        switch code {
        case "app_id_required", "missing_app_id":
            return "当前应用配置缺失，请联系管理员"
        case "app_not_found", "unknown_app_id", "invalid_app_id":
            return "当前应用未开通，请联系管理员"
        case "app_disabled", "app_inactive":
            return "当前应用已停用，请联系管理员"
        case "rate_limited", "too_many_requests":
            return "应用策略请求过于频繁，请稍后再试"
        default:
            return "应用策略校验失败，请稍后重试或联系管理员"
        }
    }

    @discardableResult
    func handlePhoneAuthDisabledError(_ error: Error) -> Bool {
        guard PhoneAuthPresentationPolicy.userMessage(for: appPolicyErrorCode(from: error)) != nil else {
            return false
        }
        disablePhoneAuthForCurrentApp()
        return true
    }

    func disablePhoneAuthForCurrentApp() {
        appPolicyPresentationStore.snapshot.isPhoneAuthDisabledByServer = true // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        appPolicyPresentationStore.snapshot.hasResolvedCurrentAppPolicyForAuthUI = true // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        if let policy = currentAppPolicy, policy.phoneAuthEnabled {
            let disabledPolicy = policy.settingPhoneAuthEnabled(false)
            appPolicyPresentationStore.snapshot.currentAppPolicy = disabledPolicy // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            let appID = IMAPIContext.normalizedIOSAppID(
                disabledPolicy.appID.isEmpty ? apiContext.appID : disabledPolicy.appID
            )
            // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112
            IMAppPolicyLastGoodStore.save(disabledPolicy, appID: appID, defaults: appPolicyLastGoodDefaults)
            currentAppPolicyExpiresAt = Date().addingTimeInterval(TimeInterval(max(0, disabledPolicy.cacheTTLSeconds)))
        }
        normalizeAuthScreenForPhoneAuthPolicy()
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(PhoneAuthPresentationPolicy.disabledMessage)
    }

    func appPolicyErrorCode(from error: Error) -> String {
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .missingContext(let value):
                return value
            case .businessForbidden(let code, _, _),
                 .conflict(let code, _),
                 .loginSecurity(let code, _, _),
                 .rateLimited(let code, _, _, _):
                return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            case .forbidden(let message),
                 .httpStatus(_, let message),
                 .server(let message),
                 .unauthorized(let message):
                return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            default:
                break
            }
        }
        return String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

}

private extension URL {
    var normalizedAPIBaseKey: String {
        let scheme = (self.scheme ?? "").lowercased()
        let host = (self.host ?? "").lowercased()
        let port = self.port.map { ":\($0)" } ?? ""
        let normalizedPath = self.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if normalizedPath.isEmpty {
            return "\(scheme)://\(host)\(port)"
        }
        return "\(scheme)://\(host)\(port)/\(normalizedPath)"
    }
}

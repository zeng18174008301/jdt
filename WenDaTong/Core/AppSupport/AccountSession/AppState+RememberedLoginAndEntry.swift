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

// WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110_BEGIN
@MainActor
final class RememberLoginPresentationStore {
    @Published var isEnabled = false

    func observe<Content: View>(@ViewBuilder content: @escaping (Bool) -> Content) -> some View {
        PublisherSnapshotView(initialValue: isEnabled, updates: $isEnabled.eraseToAnyPublisher(), content: content)
    }
}
// WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_BEGIN
@MainActor
final class AuthenticationPresentationStore {
    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_BEGIN
    @Published fileprivate(set) var authenticated = false

    func setInitialAuthentication(_ authenticated: Bool) {
        self.authenticated = authenticated
    }

    var authenticationUpdates: AnyPublisher<Bool, Never> {
        $authenticated.removeDuplicates().eraseToAnyPublisher()
    }

    func observeAuthentication<Content: View>(@ViewBuilder content: @escaping (Bool) -> Content) -> some View {
        PublisherSnapshotView(initialValue: authenticated, updates: authenticationUpdates, content: content)
    }
    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_BEGIN
    @Published fileprivate(set) var screen: AuthScreen = .welcome

    // AppState initialization restores a route with stored-property initialization semantics.
    func setInitialScreen(_ screen: AuthScreen) {
        self.screen = screen
    }

    var screenUpdates: AnyPublisher<AuthScreen, Never> {
        $screen.removeDuplicates().eraseToAnyPublisher()
    }

    func observeScreen<Content: View>(@ViewBuilder content: @escaping (AuthScreen) -> Content) -> some View {
        PublisherSnapshotView(initialValue: screen, updates: screenUpdates, content: content)
    }
    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_END
    @Published var isLoading = false

    var loadingUpdates: AnyPublisher<Bool, Never> {
        $isLoading.removeDuplicates().eraseToAnyPublisher()
    }

    func observeLoading<Content: View>(@ViewBuilder content: @escaping (Bool) -> Content) -> some View {
        PublisherSnapshotView(initialValue: isLoading, updates: loadingUpdates, content: content)
    }
}
// WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_END

extension AppState {
    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_BEGIN
    func setAuthenticated(_ authenticated: Bool) {
        authenticationPresentationStore.authenticated = authenticated
        if isAuthenticated {
            abandonRegistrationConfirmationForAuthenticatedSession()
        }
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncAccessDiagnosticsActivationScope()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncIOSRiskTelemetrySession()
        if !isAuthenticated {
            cancelSessionReauthentication()
            postLoginWorkbenchAdmission.reset()
            emojiPickerCatalogRuntime.reset()
            stopRTCMediaStateHeartbeat(reason: "logout")
            resetRTCDeviceCapabilityReportState()
        } else {
            scheduleRTCDeviceCapabilitiesReportIfNeeded()
        }
    }
    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_BEGIN
    func setAuthScreen(_ screen: AuthScreen) {
        let oldValue = authScreen
        authenticationPresentationStore.screen = screen
        normalizeAuthScreenForCurrentAppPolicy()
        if (oldValue == .accountRegister || oldValue == .phoneRegister),
           authScreen != .accountRegister, authScreen != .phoneRegister {
            cancelRegistrationSessionRecovery()
        }
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：挑战页被路由切走时废弃临时凭据并围栏迟到响应
        if oldValue == .tenantCodeChallenge,
           authScreen != .tenantCodeChallenge,
           loginTenantCodeChallengeStore.hasChallenge { // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110
            retireLoginTenantCodeChallenge(invalidateGeneration: true)
        }
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        if oldValue != authScreen {
            AccessDiagnostics.shared.resetLogoTapSequence(entry: .loggedOutLoginLogo)
        }
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }
    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_END

    private var rememberedLoginCredentialScope: RememberedLoginCredentialScope {
        RememberedLoginCredentialScope(context: apiContext)
    }

    func rememberedLoginCredentialsForAuthUI() -> RememberedLoginCredentials? {
        guard rememberLoginCredentialsEnabledForAuthUI else { return nil }
        return rememberedLoginCredentialStore.load(
            scope: rememberedLoginCredentialScope
        )
    }

    func reloadRememberedLoginCredentialsForCurrentScope() {
        let scope = rememberedLoginCredentialScope
        let enabled = rememberedLoginPreferenceStore.value(scope: scope) ?? true
        rememberLoginPresentationStore.isEnabled = enabled // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110
        if enabled {
            _ = rememberedLoginCredentialStore.load(scope: scope)
        } else {
            // An explicit opt-out wins over any stale protected credential.
            pendingRememberedLoginAttempt = nil
            rememberedLoginCredentialStore.clear(scope: scope)
        }
    }

    func setRememberLoginCredentialsEnabled(_ enabled: Bool) {
        let scope = rememberedLoginCredentialScope
        rememberedLoginPreferenceStore.set(enabled, scope: scope)
        rememberLoginPresentationStore.isEnabled = enabled // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110
        if !enabled {
            clearRememberedLoginCredentials()
        }
    }

    func clearRememberedLoginCredentials() {
        pendingRememberedLoginAttempt = nil
        rememberedLoginCredentialStore.clear(scope: rememberedLoginCredentialScope)
    }

    func clearRememberedPhoneLoginCredentialsForCurrentPolicy() {
        if pendingRememberedLoginAttempt?.credentials.mode == .phone {
            pendingRememberedLoginAttempt = nil
        }
        let scope = rememberedLoginCredentialScope
        guard rememberedLoginCredentialStore.load(scope: scope)?.mode == .phone else { return }
        clearRememberedLoginCredentials()
    }

    func beginRememberedLoginAttempt(
        generation: Int,
        mode: LoginMode,
        identifier: String,
        password: String
    ) {
        guard rememberLoginCredentialsEnabledForAuthUI else {
            pendingRememberedLoginAttempt = nil
            return
        }
        pendingRememberedLoginAttempt = PendingRememberedLoginAttempt(
            generation: generation,
            scope: rememberedLoginCredentialScope,
            credentials: RememberedLoginCredentials(
                mode: mode,
                identifier: identifier,
                password: password
            )
        )
    }

    func discardRememberedLoginAttempt(generation: Int) {
        guard pendingRememberedLoginAttempt?.generation == generation else { return }
        pendingRememberedLoginAttempt = nil
    }

    func commitRememberedLoginAttemptIfAuthoritative(
        generation: Int,
        loginData: RemoteTenantLoginData
    ) -> RememberedLoginCommitOutcome {
        guard authFlowGeneration.isCurrent(generation),
              let pending = pendingRememberedLoginAttempt,
              pending.generation == generation,
              pending.scope == rememberedLoginCredentialScope,
              rememberLoginCredentialsEnabledForAuthUI else {
            discardRememberedLoginAttempt(generation: generation)
            return .authorityGuardRejected
        }
        let hasPlatformAuthority = loginData.platformToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let accountID = [
            loginData.accountID,
            loginData.account?.id,
            loginData.userID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        guard let session = loginData.authSession,
              session.isUsable,
              hasPlatformAuthority,
              !accountID.isEmpty,
              IMAPIContext.normalizedIOSAppID(session.appID) == pending.scope.appID,
              session.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) == pending.scope.deviceID else {
            discardRememberedLoginAttempt(generation: generation)
            return .authorityGuardRejected
        }
        let saved = rememberedLoginCredentialStore.save(
            pending.credentials,
            scope: pending.scope
        )
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        let immediateReadMatched = saved
            && rememberedLoginCredentialStore.load(scope: pending.scope) == pending.credentials
#else
        let immediateReadMatched = saved
#endif
        pendingRememberedLoginAttempt = nil
        return RememberedLoginCommitOutcome.classify(
            authorityAccepted: true,
            protectedStoreWriteSucceeded: saved,
            immediateReadMatched: immediateReadMatched
        )
    }

    func startLoginFlow(
        identifier: String? = nil,
        password: String? = nil,
        credentialMode: LoginMode? = nil
    ) {
        guard !isAuthLoading else { return }
        let loginID = (identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let loginPassword = (password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loginID.isEmpty, !loginPassword.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入账号和密码")
            return
        }

        cancelRegistrationSessionRecovery()
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：新的登录输入会废弃上一轮临时企业码挑战
        retireLoginTenantCodeChallenge(invalidateGeneration: false)
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        // Login has detached registration before any asynchronous work.
        authenticationPresentationStore.isLoading = true // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        let generation = authFlowGeneration.issueToken()
        let resolvedCredentialMode = credentialMode
            ?? (isValidMainlandPhone(normalizedMainlandPhone(loginID)) ? .phone : .account)
        beginRememberedLoginAttempt(
            generation: generation,
            mode: resolvedCredentialMode,
            identifier: loginID,
            password: loginPassword
        )
        workspaceSwitchGeneration.invalidate()
        Task {
            // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：为 409 tenant_code_required 捕获本次登录的上下文边界
            var attemptedPolicy: RemoteAppCurrentPolicy?
            var attemptedEnterpriseContext: PreAuthEnterpriseContext?
            var attemptedLoginContext: IMAPIContext?
            // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
            defer {
                discardRememberedLoginAttempt(generation: generation)
                authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            }
            do {
                guard let policy = await ensureCurrentAppPolicyForAuth() else { return }
                // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始
                attemptedPolicy = policy
                // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
                if isValidMainlandPhone(normalizedMainlandPhone(loginID)), !policy.phoneAuthEnabled {
                    disablePhoneAuthForCurrentApp()
                    return
                }
                let enterpriseContext = requirePreAuthEnterpriseContextIfConfigured()
                // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始
                attemptedEnterpriseContext = enterpriseContext
                // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
                if policy.enterpriseCodeFirst, enterpriseContext == nil { return }
                let loginContext = apiContext
                // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始
                attemptedLoginContext = loginContext
                // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                PostLoginSuccessConsumptionDiagnostics.begin(generation: generation)
#endif
                let data = try await loginWithOptionalSlideCaptcha(
                    username: loginID,
                    password: loginPassword,
                    context: loginContext,
                    enterpriseContext: enterpriseContext
                )
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                PostLoginSuccessConsumptionDiagnostics.advance(.responseDecoded, generation: generation)
#endif
                guard authFlowGeneration.isCurrent(generation) else { return }
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                PostLoginSuccessConsumptionDiagnostics.advance(.generationCurrent, generation: generation)
#endif
                if let enterpriseContext,
                   !tenantLoginData(data, matches: enterpriseContext) {
                    throw IMAPIError.businessForbidden(
                        code: "enterprise_context_invalid",
                        message: "企业登录路由校验失败，请重新输入企业码",
                        error: nil
                    )
                }
                let rememberCommitOutcome = commitRememberedLoginAttemptIfAuthoritative(
                    generation: generation,
                    loginData: data
                )
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                RememberedLoginCommitDiagnostics.record(rememberCommitOutcome)
#endif
                await completeTenantLogin(
                    data,
                    syncedMessage: "已登录并同步企业数据",
                    fallbackMessage: "登录成功，聊天数据正在同步",
                    allowDefaultAutoEnter: true,
                    loginIdentifierFallback: loginID,
                    enterpriseContext: enterpriseContext,
                    loginGeneration: generation
                )
            } catch {
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                PostLoginSuccessConsumptionDiagnostics.advance(.caughtAfterRequest, generation: generation)
#endif
                guard authFlowGeneration.isCurrent(generation) else { return }
                // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：仅普通登录的 409 tenant_code_required 进入临时企业码确认，不走旧租户回退
                if attemptedPolicy?.enterpriseCodeFirst == false,
                   attemptedEnterpriseContext == nil,
                   let attemptedLoginContext,
                   isTenantCodeRequiredLoginChallenge(error) {
                    presentLoginTenantCodeChallenge(
                        generation: generation,
                        credentialMode: resolvedCredentialMode,
                        identifier: loginID,
                        password: loginPassword,
                        context: attemptedLoginContext
                    )
                    return
                }
                // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
                setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
                stopInboxRefreshLoop()
                resetAuthenticatedRemoteData(showLoading: false)
                disableAccessDiagnosticsOverlay()
                apiContext.clearSession(sessionStore: protectedSessionStore)
                if isRegistrationEntryCodeRateLimitError(error) {
                    invalidatePreAuthEnterpriseContext(normalizeScreen: false)
                    setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                    let message = enterpriseContextFailureMessage(error)
                    preAuthEnterpriseContextStore.setError(message) // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
                } else if isEnterpriseContextAuthorityError(error) {
                    invalidatePreAuthEnterpriseContext(normalizeScreen: false)
                    setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                    let message = enterpriseContextFailureMessage(error)
                    preAuthEnterpriseContextStore.setError(message) // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
                } else if !handlePhoneAuthDisabledError(error) {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(loginFailureMessage(error))
                }
            }
        }
    }

    func completeTenantLogin(
        _ data: RemoteTenantLoginData,
        syncedMessage: String,
        fallbackMessage: String,
        allowDefaultAutoEnter: Bool = false,
        loginIdentifierFallback: String? = nil,
        enterpriseContext: PreAuthEnterpriseContext? = nil,
        loginGeneration: Int
    ) async {
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.completeEntered, generation: loginGeneration)
#endif
        guard applyTenantLoginData(data, loginIdentifierFallback: loginIdentifierFallback) else {
            setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            stopInboxRefreshLoop()
            stopRTCCallRefreshLoop()
            disconnectRealtime(shouldReconnect: false)
            apiContext.clearSession(sessionStore: protectedSessionStore)
            resetAuthenticatedRemoteData(showLoading: false)
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态未能安全保存，请重试")
            return
        }
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.tenantDataApplied, generation: loginGeneration)
#endif
        if enterpriseContext != nil, !apiContext.hasIMSession {
            invalidatePreAuthEnterpriseContext(normalizeScreen: false)
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
            PostLoginSuccessConsumptionDiagnostics.advance(.enterpriseIMSessionRejected, generation: loginGeneration)
#endif
            setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(data.pendingApprovalCount > 0 || !data.pendingEntryTenantID.isEmpty
                ? "入企申请等待审批中，审核通过后请重新登录。"
                : "企业登录会话暂不可用，请稍后重试") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
            return
        }
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.workspaceResolutionEntered, generation: loginGeneration)
#endif
        loginWorkspacePresentationStore.snapshot.defaultWorkspaceID = normalizedDefaultWorkspaceID(from: data) // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        applyLoginWorkspaceState(from: data)
        if await attemptDirectWorkspaceEnterFromLoginSession(
            from: data,
            syncedMessage: syncedMessage,
            fallbackMessage: fallbackMessage,
            loginGeneration: loginGeneration
        ) {
            return
        }

        let appScopedDirectory = await loadAppScopedTenantDirectoryForLogin()
        if let appScopedDirectory {
            let visibleAppScopedMemberships = appScopedDirectory.preferredMemberships.filter { $0.isVisibleInAppScope(currentAppID) }
            if !visibleAppScopedMemberships.isEmpty {
                applyTenantMemberships(visibleAppScopedMemberships)
                if !data.requiresWorkspaceSelection,
                   data.canDirectEnter,
                   await attemptSingleWorkspaceAutoEnterFromDirectory(
                    visibleAppScopedMemberships,
                    syncedMessage: syncedMessage,
                    fallbackMessage: fallbackMessage,
                    loginGeneration: loginGeneration
                   ) {
                    return
                }
            } else {
                setEnterprises([]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                setCurrentEnterprise(Enterprise(id: "pending_workspace_selection", name: "请选择企业", code: "", role: "", status: "待选择", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            }
            let message = loginWorkspaceSelectionMessage(from: data, directory: appScopedDirectory)
                ?? (visibleAppScopedMemberships.isEmpty
                ? "当前账号在此 App 下暂无可进入企业，请联系管理员确认企业归属。"
                : "请选择本次要进入的企业。勾选后下次登录会按企业状态自动进入。")
            prepareLoginWorkspaceSelectionFromCurrentDirectory(message: message, loginGeneration: loginGeneration)
            if !visibleAppScopedMemberships.isEmpty, isWorkspaceSwitchDisabledByPolicy {
                loginWorkspacePresentationStore.snapshot.message = "管理员已关闭企业切换；系统会优先自动进入最近可用企业。当前未获取到可直接进入的企业会话，请联系管理员确认企业成员状态。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("未获取到可直接进入的企业会话")
            }
            return
        }

        if allowDefaultAutoEnter,
           await attemptDefaultWorkspaceAutoEnter(
            from: data,
            syncedMessage: syncedMessage,
            fallbackMessage: fallbackMessage,
            loginGeneration: loginGeneration
           ) {
            return
        }
        prepareLoginWorkspaceSelection(from: data, loginGeneration: loginGeneration)
        if isWorkspaceSwitchDisabledByPolicy {
            loginWorkspacePresentationStore.snapshot.message = "管理员已关闭企业切换；系统会优先自动进入最近可用企业。当前未获取到可直接进入的企业会话，请联系管理员确认企业成员状态。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("未获取到可直接进入的企业会话")
        }
    }

    private func loadAppScopedTenantDirectoryForLogin() async -> RemoteTenantDirectoryResult? {
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Capture at the original owner/installed-auth phase before its request suspends.
        let requestAuthority = apiContext.authSessionFence
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END

        let platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !platformToken.isEmpty else { return nil }
        do {
            return try await api.myTenantDirectory(platformToken: platformToken, appID: currentAppID, requestAuthority: requestAuthority)
        } catch {
            return nil
        }
    }

    func loginWorkspaceSelectionMessage(from data: RemoteTenantLoginData, directory: RemoteTenantDirectoryResult? = nil) -> String? {
        let status = [
            loginEntryStatus(from: data),
            directory?.entryStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        ].first { !$0.isEmpty } ?? ""
        switch status {
        case "pending_approval":
            return "入企申请等待审批中，审核通过后再进入企业。"
        case "preparing":
            return "企业数据正在准备中，请稍后再进入。"
        case "ready":
            return "企业数据已准备好，请选择企业继续进入。"
        case "failed":
            return "企业数据准备失败，请联系管理员或稍后重试。"
        case "revoked":
            return "默认企业已失效，请选择其他可进入企业。"
        default:
            break
        }
        let pendingCount = data.pendingApprovalCount + (directory?.pendingApprovalCount ?? 0)
        if pendingCount > 0 {
            return "有入企申请等待审批，审核通过后可进入企业。"
        }
        let defaultWorkspaceID = normalizedDefaultWorkspaceID(from: data)
        if let defaultWorkspaceMessage = defaultWorkspaceEntryFailureMessage(from: data, defaultWorkspaceID: defaultWorkspaceID) {
            return "\(defaultWorkspaceMessage)请选择本次要进入的企业。"
        }
        return nil
    }

    func prepareLoginWorkspaceSelection(from data: RemoteTenantLoginData, loginGeneration: Int) {
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        recordAccessDiagnosticsMerchantResolving(name: "待选择")
        apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        if data.workspaces.isEmpty {
            setEnterprises([]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            setCurrentEnterprise(Enterprise(id: "pending_workspace_selection", name: "请选择企业", code: "", role: "", status: "待选择", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.workspaceSelectionTerminal, generation: loginGeneration)
#endif
        loginWorkspacePresentationStore.snapshot.message = loginWorkspaceSelectionMessage(from: data) // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            ?? "请选择本次要进入的企业。勾选后下次登录会按企业状态自动进入。"
    }

    private func loginEntryStatus(from data: RemoteTenantLoginData) -> String {
        data.entryStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func normalizedDefaultWorkspaceID(from data: RemoteTenantLoginData) -> String {
        [
            data.defaultWorkspaceID,
            data.defaultWorkspace?.id ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
    }

    private func defaultWorkspaceEntryFailureMessage(from data: RemoteTenantLoginData, defaultWorkspaceID: String) -> String? {
        if data.defaultWorkspaceUnavailable, !isDefaultWorkspaceUnsetReason(data.defaultWorkspaceReason) {
            return defaultWorkspaceReasonMessage(data.defaultWorkspaceReason)
        }
        let trimmedDefaultID = defaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDefaultID.isEmpty else { return nil }
        guard let defaultEnterprise = defaultWorkspaceEnterprise(from: data, defaultWorkspaceID: trimmedDefaultID) else {
            return data.workspaces.isEmpty ? nil : defaultWorkspaceReasonMessage("default_workspace_not_found")
        }
        if defaultEnterprise.isWorkspaceJoinPending {
            return "默认企业需商户后台审核，当前为待审核状态。"
        }
        if defaultEnterprise.isWorkspaceJoinRejected {
            return "默认企业入企申请已被拒绝。"
        }
        guard defaultEnterprise.isWorkspaceEnterable else {
            let reason = defaultEnterprise.workspaceDisabledDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? defaultWorkspaceReasonMessage("default_workspace_unavailable") : "\(reason)，默认企业暂不可进入。"
        }
        if !defaultEnterprise.canSwitch,
           !canEnterDefaultWorkspaceFromLoginSession(data, enterprise: defaultEnterprise) {
            return "管理员已关闭企业切换；默认企业需要服务端下发直入会话后才能进入。"
        }
        return nil
    }

    private func isDefaultWorkspaceUnsetReason(_ rawReason: String) -> Bool {
        let normalized = rawReason
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        return [
            "defaultnotset",
            "defaultworkspacenotset",
            "defaultcompanynotset",
            "defaulttenantnotset",
            "notset"
        ].contains(normalized)
    }

    @discardableResult
    private func attemptDirectWorkspaceEnterFromLoginSession(
        from data: RemoteTenantLoginData,
        syncedMessage: String,
        fallbackMessage: String,
        loginGeneration: Int
    ) async -> Bool {
        guard data.canDirectEnter,
              !data.requiresWorkspaceSelection,
              data.session != nil,
              apiContext.hasIMSession else {
            return false
        }
        let targetWorkspaceID = [
            data.autoEnteredWorkspaceID,
            data.tenant?.tenantID ?? "",
            apiContext.tenantID ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        if !targetWorkspaceID.isEmpty,
           let targetEnterprise = enterprises.first(where: { $0.id == targetWorkspaceID }),
           (!targetEnterprise.isWorkspaceEnterable || targetEnterprise.isWorkspaceJoinPending || targetEnterprise.isWorkspaceJoinRejected) {
            return false
        }
        let generation = authFlowGeneration.currentToken()
        disconnectRealtime(shouldReconnect: false)
        resetAuthenticatedRemoteData(showLoading: true)
        enterIM(showToast: false)
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.authenticatedMainTerminal, generation: loginGeneration)
#endif
        let enteredContext = apiContext
        let enteredScope = remoteDataScopeKey(for: enteredContext)
        _ = await applyCachedRemoteSnapshotIfAvailable(context: enteredContext)
        guard authFlowGeneration.isCurrent(generation),
              isCurrentRemoteScope(enteredScope) else { return true }
        startPostLoginRemoteSnapshotRefresh(
            generation: generation,
            context: enteredContext,
            immediateToast: fallbackMessage,
            syncedToast: currentEnterprise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? syncedMessage : "已进入 \(currentEnterprise.name)",
            fallbackToast: fallbackMessage
        )
        return true
    }

}

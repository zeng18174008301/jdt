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

// WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_BEGIN
@MainActor
final class LoginTenantCodeChallengeStore {
    struct Snapshot: Equatable {
        var identifier = ""
        var isSubmitting = false
        var errorMessage: String?
    }

    @Published private(set) var snapshot = Snapshot()
    fileprivate var challenge: LoginTenantCodeChallenge?

    var hasChallenge: Bool { challenge != nil }

    fileprivate func install(_ challenge: LoginTenantCodeChallenge, isSubmitting: Bool = false) {
        self.challenge = challenge
        snapshot = Snapshot(identifier: challenge.identifier, isSubmitting: isSubmitting)
    }

    fileprivate func clear() {
        challenge = nil
        if snapshot != Snapshot() { snapshot = Snapshot() }
    }

    fileprivate func setError(_ message: String?) {
        if snapshot.errorMessage != message {
            snapshot.errorMessage = message
        }
    }

    fileprivate func finishSubmission(generation: Int) {
        guard challenge?.generation == generation, snapshot.isSubmitting else { return }
        snapshot.isSubmitting = false
    }

    func observe<Content: View>(@ViewBuilder content: @escaping (Snapshot) -> Content) -> some View {
        PublisherSnapshotView(initialValue: snapshot, updates: $snapshot.eraseToAnyPublisher(), content: content)
    }
}
// WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_BEGIN
@MainActor
final class PreAuthEnterpriseContextStore {
    struct Form: Equatable {
        var isResolving = false
        var errorMessage: String?
    }

    struct Branding: Equatable {
        let name: String
        let logoURL: String
        let logoCacheKey: String
    }

    @Published private(set) var form = Form()
    @Published private(set) var branding: Branding?
    fileprivate private(set) var context: PreAuthEnterpriseContext?

    fileprivate func reset(isResolving: Bool = false) {
        context = nil
        if branding != nil { branding = nil }
        let next = Form(isResolving: isResolving)
        if form != next { form = next }
    }

    fileprivate func install(_ context: PreAuthEnterpriseContext, logoURL: String) {
        self.context = context
        branding = Branding(name: context.tenantName, logoURL: logoURL, logoCacheKey: context.tenantLogoCacheKey)
        setError(nil)
    }

    fileprivate func finishResolution() {
        if form.isResolving { form.isResolving = false }
    }

    func setError(_ message: String?) {
        if form.errorMessage != message { form.errorMessage = message }
    }

    func observeForm<Content: View>(@ViewBuilder content: @escaping (Form) -> Content) -> some View {
        PublisherSnapshotView(initialValue: form, updates: $form.eraseToAnyPublisher(), content: content)
    }

    func observeBranding<Content: View>(@ViewBuilder content: @escaping (Branding?) -> Content) -> some View {
        PublisherSnapshotView(initialValue: branding, updates: $branding.eraseToAnyPublisher(), content: content)
    }
}
// WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_END

extension AppState {
    var preAuthEnterpriseContext: PreAuthEnterpriseContext? { preAuthEnterpriseContextStore.context } // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110

    func normalizedRegistrationTenantCode(_ value: String?) -> String {
        guard let value else { return "" }
        return RegistrationFlowPolicy.normalizedEntryCode(value)?.normalizedValue ?? ""
    }

    func normalizedEnterpriseContextCode(_ value: String) -> String? {
        RegistrationFlowPolicy.normalizedEntryCode(value)?.normalizedValue
    }

    // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：复用企业码上下文解析，避免临时挑战复制另一套校验逻辑
    private func resolvedPreAuthEnterpriseContext(
        enterpriseCode normalizedCode: String,
        appID requestAppID: String,
        deviceID requestDeviceID: String
    ) async throws -> PreAuthEnterpriseContext {
        let result = try await api.resolveEnterpriseContext(
            tenantCode: normalizedCode,
            appID: requestAppID,
            deviceID: requestDeviceID
        )
        return try preAuthEnterpriseContext(
            from: result,
            submittedCode: normalizedCode,
            appID: requestAppID,
            deviceID: requestDeviceID
        )
    }

    private func preAuthEnterpriseContext(
        from result: RemoteEnterpriseContextResult,
        submittedCode normalizedCode: String,
        appID rawRequestAppID: String,
        deviceID rawRequestDeviceID: String
    ) throws -> PreAuthEnterpriseContext {
        let requestAppID = IMAPIContext.normalizedIOSAppID(rawRequestAppID)
        let requestDeviceID = rawRequestDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenantID = result.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenantName = result.tenant?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let presentationTenantID = result.tenant?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canonicalTenantEntry = RegistrationFlowPolicy.normalizedEntryCode(result.tenantCode)
        let presentationTenantEntry = RegistrationFlowPolicy.normalizedEntryCode(result.tenant?.tenantCode ?? "")
        let authority = RegistrationFlowPolicy.entryAuthority(
            entryType: result.entryType,
            scheme: result.scheme,
            canonical: result.canonical,
            submittedEntryCode: normalizedCode,
            allowsServerDefinedInvite: true // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        )
        let token = result.contextToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let routes = result.runtimeConfig.runtimeRouteSnapshot
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(result.expiresAt))
        guard result.appID == requestAppID,
              !tenantID.isEmpty,
              let canonicalTenantEntry,
              canonicalTenantEntry.kind == .enterprise,
              let presentationTenantEntry,
              presentationTenantEntry == canonicalTenantEntry,
              let authority,
              presentationTenantID == tenantID,
              !token.isEmpty,
              expiresAt > Date(),
              result.routeRevision > 0,
              result.routeRevision == routes.revision,
              result.runtimeConfig.routeStatus == "ready",
              routes.validated(appID: requestAppID, tenantID: tenantID) != nil else {
            throw IMAPIError.businessForbidden(
                code: "enterprise_context_invalid",
                message: "企业码验证已失效，请重新输入",
                error: nil
            )
        }
        let context = PreAuthEnterpriseContext(
            appID: requestAppID,
            deviceID: requestDeviceID,
            tenantID: tenantID,
            tenantCode: canonicalTenantEntry.normalizedValue,
            entryCode: authority.canonicalCode,
            entryType: authority.entryType,
            entryScheme: authority.scheme,
            tenantName: tenantName,
            tenantLogoURL: result.tenant?.logoURL ?? "",
            tenantLogoCacheKey: result.tenant?.logoCacheKey ?? "",
            contextToken: token,
            expiresAt: expiresAt,
            routeRevision: result.routeRevision,
            runtimeRoutes: routes
        )
        guard context.matchesIdentity(appID: requestAppID, deviceID: requestDeviceID) else {
            throw IMAPIError.businessForbidden(
                code: "enterprise_context_invalid",
                message: "企业码验证已失效，请重新输入",
                error: nil
            )
        }
        return context
    }
    // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束

    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_BEGIN
    @discardableResult
    func resolveEnterpriseContext(enterpriseCode: String, automatic _: Bool = false) async -> Bool {
        guard !isAuthenticated, !apiContext.hasIMSession,
              currentAppPolicy?.enterpriseCodeFirst == true else {
            return false
        }
        let store = preAuthEnterpriseContextStore
        let normalizedCode = RegistrationFlowPolicy.submittedEntryCode(enterpriseCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        guard !normalizedCode.isEmpty else {
            let message = RegistrationFlowPolicy.entryCodePrompt
            store.setError(message)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return false
        }
        cancelRegistrationSessionRecovery()
        let requestAppID = apiContext.appID
        let requestDeviceID = apiContext.deviceID
        let generation = enterpriseContextGeneration.issueToken()
        store.reset(isResolving: true)
        defer {
            if enterpriseContextGeneration.isCurrent(generation) {
                store.finishResolution()
            }
        }
        do {
            let context = try await resolvedPreAuthEnterpriseContext(
                enterpriseCode: normalizedCode,
                appID: requestAppID,
                deviceID: requestDeviceID
            )
            guard enterpriseContextGeneration.isCurrent(generation),
                  !isAuthenticated,
                  currentAppPolicy?.enterpriseCodeFirst == true,
                  apiContext.appID == requestAppID,
                  apiContext.deviceID == requestDeviceID else {
                return false
            }
            store.install(context, logoURL: enterpriseContextLogoURL(context))
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return true
        } catch {
            guard enterpriseContextGeneration.isCurrent(generation) else { return false }
            let message = enterpriseContextFailureMessage(error)
            store.setError(message)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return false
        }
    }

    func clearPreAuthEnterpriseContext() {
        invalidatePreAuthEnterpriseContext(normalizeScreen: true)
    }

    func invalidatePreAuthEnterpriseContext(normalizeScreen: Bool = true) {
        enterpriseContextGeneration.invalidate()
        preAuthEnterpriseContextStore.reset()
        lastPreferredEnterpriseCodeAttempt = ""
        if normalizeScreen {
            normalizeAuthScreenForCurrentAppPolicy()
        }
    }

    func usablePreAuthEnterpriseContext() -> PreAuthEnterpriseContext? {
        guard let context = preAuthEnterpriseContext,
              context.matchesIdentity(appID: apiContext.appID, deviceID: apiContext.deviceID) else {
            return nil
        }
        return context
    }

    func requirePreAuthEnterpriseContextIfConfigured() -> PreAuthEnterpriseContext? {
        guard currentAppPolicy?.enterpriseCodeFirst == true else { return nil }
        if let context = usablePreAuthEnterpriseContext() {
            return context
        }
        invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let message = "企业码验证已失效，请重新输入"
        preAuthEnterpriseContextStore.setError(message)
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
        return nil
    }
    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_END

    // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：普通登录 409 tenant_code_required 的一次性企业码续登
    func isTenantCodeRequiredLoginChallenge(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError,
              case let .conflict(code, _) = apiError else { return false }
        return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tenant_code_required"
    }

    func isAuthDependencyUnavailableError(_ error: Error) -> Bool {
        let code = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
        return code == "auth_dependency_unavailable" || code.contains("auth_dependency_unavailable")
    }

    // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_BEGIN
    func presentLoginTenantCodeChallenge(
        generation: Int,
        credentialMode: LoginMode,
        identifier: String,
        password: String,
        context: IMAPIContext
    ) {
        loginTenantCodeChallengeStore.install(LoginTenantCodeChallenge(
            generation: generation,
            credentialMode: credentialMode,
            identifier: identifier,
            password: password,
            context: context
        ))
        setAuthScreen(.tenantCodeChallenge) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入企业码，以确认要登录的企业")
    }

    func clearLoginTenantCodeChallenge() {
        loginTenantCodeChallengeStore.clear()
    }

    func retireLoginTenantCodeChallenge(invalidateGeneration: Bool) {
        if invalidateGeneration {
            authFlowGeneration.invalidate()
            cancelSlideCaptcha()
        }
        clearLoginTenantCodeChallenge()
    }

    func cancelLoginTenantCodeChallenge() {
        let fallbackScreen: AuthScreen
        if loginTenantCodeChallengeStore.challenge?.credentialMode == .phone, isPhoneAuthEnabledForAuthUI {
            fallbackScreen = .phoneLogin
        } else {
            fallbackScreen = .accountLogin
        }
        retireLoginTenantCodeChallenge(invalidateGeneration: true)
        authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        setAuthScreen(fallbackScreen) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
    }

    func loginTenantCodeChallengeInputDidChange() {
        loginTenantCodeChallengeStore.setError(nil)
    }

    func submitLoginTenantCodeChallenge(enterpriseCode: String) {
        let store = loginTenantCodeChallengeStore
        guard !store.snapshot.isSubmitting,
              let currentChallenge = store.challenge,
              authScreen == .tenantCodeChallenge else { return }
        guard let normalizedCode = normalizedEnterpriseContextCode(enterpriseCode) else {
            let message = RegistrationFlowPolicy.entryCodePrompt
            store.setError(message)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return
        }
        let generation = authFlowGeneration.issueToken()
        let challenge = LoginTenantCodeChallenge(
            generation: generation,
            credentialMode: currentChallenge.credentialMode,
            identifier: currentChallenge.identifier,
            password: currentChallenge.password,
            context: currentChallenge.context
        )
        store.install(challenge, isSubmitting: true)
        authenticationPresentationStore.isLoading = true // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        workspaceSwitchGeneration.invalidate()
        Task {
            defer {
                discardRememberedLoginAttempt(generation: generation)
                if authFlowGeneration.isCurrent(generation) {
                    authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                    store.finishSubmission(generation: generation)
                }
            }
            do {
                let enterpriseContext = try await resolvedPreAuthEnterpriseContext(
                    enterpriseCode: normalizedCode,
                    appID: challenge.context.appID,
                    deviceID: challenge.context.deviceID
                )
                guard authFlowGeneration.isCurrent(generation),
                      store.challenge?.isCurrent(
                        generation: generation,
                        appID: challenge.context.appID,
                        deviceID: challenge.context.deviceID
                      ) == true,
                      !isAuthenticated,
                      !apiContext.hasIMSession,
                      IMAPIContext.normalizedIOSAppID(apiContext.appID) == challenge.appID,
                      apiContext.deviceID == challenge.deviceID else { return }
                beginRememberedLoginAttempt(
                    generation: generation,
                    mode: challenge.credentialMode,
                    identifier: challenge.identifier,
                    password: challenge.password
                )
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                PostLoginSuccessConsumptionDiagnostics.begin(generation: generation)
#endif
                let data = try await loginWithOptionalSlideCaptcha(
                    username: challenge.identifier,
                    password: challenge.password,
                    context: challenge.context,
                    enterpriseContext: enterpriseContext
                )
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                PostLoginSuccessConsumptionDiagnostics.advance(.responseDecoded, generation: generation)
#endif
                guard authFlowGeneration.isCurrent(generation),
                      store.challenge?.isCurrent(
                        generation: generation,
                        appID: challenge.context.appID,
                        deviceID: challenge.context.deviceID
                      ) == true else { return }
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                PostLoginSuccessConsumptionDiagnostics.advance(.generationCurrent, generation: generation)
#endif
                guard tenantLoginData(data, matches: enterpriseContext) else {
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
                clearLoginTenantCodeChallenge()
                await completeTenantLogin(
                    data,
                    syncedMessage: "已登录并同步企业数据",
                    fallbackMessage: "登录成功，聊天数据正在同步",
                    allowDefaultAutoEnter: true,
                    loginIdentifierFallback: challenge.identifier,
                    enterpriseContext: enterpriseContext,
                    loginGeneration: generation
                )
            } catch {
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                PostLoginSuccessConsumptionDiagnostics.advance(.caughtAfterRequest, generation: generation)
#endif
                guard authFlowGeneration.isCurrent(generation),
                      store.challenge?.isCurrent(
                        generation: generation,
                        appID: challenge.context.appID,
                        deviceID: challenge.context.deviceID
                      ) == true else { return }
                if handlePhoneAuthDisabledError(error) {
                    clearLoginTenantCodeChallenge()
                    return
                }
                let message = loginTenantCodeChallengeFailureMessage(error)
                store.setError(message)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
                setAuthScreen(.tenantCodeChallenge) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            }
        }
    }
    // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_END

    private func loginTenantCodeChallengeFailureMessage(_ error: Error) -> String {
        if isAuthDependencyUnavailableError(error) {
            return "登录服务暂不可用，请稍后重试"
        }
        if isTenantCodeRequiredLoginChallenge(error)
            || isEnterpriseContextAuthorityError(error)
            || isRegistrationEntryCodeRateLimitError(error) {
            return enterpriseContextFailureMessage(error)
        }
        return loginFailureMessage(error)
    }
    // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束

    func enterpriseContextFailureMessage(_ error: Error) -> String {
        let code = appPolicyErrorCode(from: error)
        if code == "enterprise_context_expired" {
            return "企业码验证已失效，请重新输入"
        }
        let retryAfterSeconds: Int?
        let lockedUntil: Date?
        if case let IMAPIError.rateLimited(_, _, retryAfter, rawLockedUntil) = error {
            retryAfterSeconds = retryAfter
            lockedUntil = rawLockedUntil.flatMap(enterpriseContextLockedUntilDate)
        } else {
            retryAfterSeconds = nil
            lockedUntil = nil
        }
        if let presentation = RegistrationFlowPolicy.entryCodeRateLimitPresentation(
            errorCode: code,
            retryAfterSeconds: retryAfterSeconds,
            retryAvailableAt: lockedUntil
        ) {
            return presentation.message
        }
        return "企业码无效或暂不可用，请检查后重试"
    }

    private func enterpriseContextLockedUntilDate(_ rawValue: String) -> Date? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: normalized) ?? ISO8601DateFormatter().date(from: normalized)
    }

    func isEnterpriseContextAuthorityError(_ error: Error) -> Bool {
        ["enterprise_context_invalid", "enterprise_context_expired", "enterprise_context_required"]
            .contains(appPolicyErrorCode(from: error))
    }

    func isRegistrationEntryCodeRateLimitError(_ error: Error) -> Bool {
        ["enterprise_context_rate_limited", "registration_tenant_code_probe_rate_limited"]
            .contains(appPolicyErrorCode(from: error))
    }


}

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

// MARK: - AppState MainActor Partition
//
// Remote registration and snapshot sync stay on AppState/MainActor because they
// coordinate authentication/session fences, remoteSyncEngine state, published
// loading and failure flags, child stores, cached snapshot hydration, and
// SwiftUI-observed conversations. Heavy snapshot projection and local message
// cache builders remain delegated to background helpers; this file keeps the
// AppState state boundary explicit.

// MARK: - Remote Registration and Snapshot Sync

extension AppState {
    func registerRemotely(phone: String, account: String, password: String, enterpriseCode: String?, captchaCode: String) async {
        guard !Task.isCancelled else { return }
        #if DEBUG
        if licenseQuotaScreenshotScenario == .registration {
            toast = IMAPIClient.licenseQuotaUserMessage(for: "registered_user_quota_exceeded")
            return
        }
        #endif
        let trimmedPhone = normalizedMainlandPhone(phone)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCaptchaCode = captchaCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty, (!trimmedPhone.isEmpty || !trimmedAccount.isEmpty) else {
            toast = "请输入注册账号和密码"
            return
        }
        if !trimmedPhone.isEmpty {
            guard isValidMainlandPhone(trimmedPhone) else {
                toast = "请输入正确的手机号"
                return
            }
        }
        if !trimmedAccount.isEmpty, !isValidAccountUsername(trimmedAccount) {
            // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册账号格式提示按文档统一
            toast = "账号须为5–10位英文字母或数字。"
            // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
            return
        }
        registrationRecoveryEntryCode = preAuthEnterpriseContext?.entryCode ?? normalizedRegistrationTenantCode(enterpriseCode)
        isAuthLoading = true
        let generation = authFlowGeneration.issueToken()
        workspaceSwitchGeneration.invalidate()
        let registrationFailureScreen: AuthScreen = trimmedAccount.isEmpty ? .phoneRegister : .accountRegister
        defer {
            if authFlowGeneration.isCurrent(generation) {
                isAuthLoading = false
            }
        }

        let normalizedEnterpriseCode = normalizedRegistrationTenantCode(enterpriseCode)
        var submittedAttempt: PendingRegistrationAttempt?
        do {
            guard let policy = await ensureCurrentAppPolicyForAuth() else { return }
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            guard policy.registrationEnabled else {
                authScreen = .accountLogin
                toast = EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage
                return
            }
            if !trimmedPhone.isEmpty, (!policy.phoneAuthEnabled || isPhoneAuthDisabledByServer) {
                disablePhoneAuthForCurrentApp()
                return
            }
            let enterpriseContext = requirePreAuthEnterpriseContextIfConfigured()
            if policy.enterpriseCodeFirst, enterpriseContext == nil { return }
            if !policy.enterpriseCodeFirst,
               enterpriseCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
               !isValidRegistrationTenantCode(enterpriseCode) {
                toast = "请输入企业编码或邀请码"
                return
            }
            let authoritativeEnterpriseCode = enterpriseContext?.entryCode ?? normalizedEnterpriseCode
            if !policy.allowDefaultTenantJoin, authoritativeEnterpriseCode.isEmpty {
                toast = "请输入企业编码或邀请码"
                return
            }
            let requestEnterpriseCode = authoritativeEnterpriseCode.isEmpty ? nil : authoritativeEnterpriseCode
            let registrationContext = apiContext
            let registrationCaptchaRequired = !trimmedPhone.isEmpty
                ? try await captchaRequired(scene: "register", channel: "sms", appID: registrationContext.appID, tenantCode: requestEnterpriseCode ?? "", fallbackToCurrentTenant: false)
                : false
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            if !trimmedPhone.isEmpty && registrationCaptchaRequired {
                guard trimmedCaptchaCode.count == 6, trimmedCaptchaCode.allSatisfy(\.isNumber) else {
                    toast = "请输入 6 位验证码"
                    return
                }
            }
            let requestCaptchaCode = trimmedPhone.isEmpty || !registrationCaptchaRequired
                ? nil
                : trimmedCaptchaCode
            let requestID = UUID().uuidString.lowercased()
            let attempt = PendingRegistrationAttempt(
                requestID: requestID,
                appID: IMAPIContext.normalizedIOSAppID(registrationContext.appID),
                deviceID: registrationContext.deviceID,
                failureScreen: trimmedAccount.isEmpty ? .phoneRegister : .accountRegister,
                startedAt: registrationNow()
            )
            registrationRecoveryReceipt = PendingRegistrationReceipt(
                requestID: attempt.requestID, appID: attempt.appID, deviceID: attempt.deviceID,
                failureScreen: trimmedAccount.isEmpty ? "phone" : "account", startedAt: attempt.startedAt
            )
            guard let secret = RegistrationSessionRecovery.generateSecret(),
                  saveRegistrationRecovery(RegistrationSessionRecovery(
                    requestID: attempt.requestID, appID: attempt.appID, deviceID: attempt.deviceID,
                    entryCode: authoritativeEnterpriseCode, startedAt: attempt.startedAt, secret: secret,
                    tenantID: enterpriseContext?.tenantID
                  )) else {
                toast = "无法安全保存注册凭据，请重试"
                return
            }
            submittedAttempt = attempt
            guard pendingRegistrationReceiptStore.save(PendingRegistrationReceipt(
                requestID: attempt.requestID,
                appID: attempt.appID,
                deviceID: attempt.deviceID,
                failureScreen: attempt.failureScreen == .phoneRegister ? "phone" : "account",
                startedAt: attempt.startedAt
            )) else {
                clearRegistrationRecovery()
                registrationResolutionState = .failed
                toast = "注册暂时无法安全提交，请稍后重试"
                return
            }
            registrationResolutionState = nil
            registrationConfirmationTimedOut = false
            let data = try await api.registerWithRequestID(
                username: trimmedAccount,
                phone: trimmedPhone,
                password: trimmedPassword,
                tenantCode: requestEnterpriseCode,
                captchaCode: requestCaptchaCode,
                enterpriseContextToken: enterpriseContext?.contextToken,
                appID: registrationContext.appID,
                deviceID: registrationContext.deviceID,
                requestID: attempt.requestID,
                registrationSessionSecret: secret
            )
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            let responseEntryAuthority: RegistrationEntryAuthority?
            if data.hasTypedEntryAuthority {
                let submittedEntryCode = requestEnterpriseCode ?? data.entryCanonical
                guard let authority = RegistrationFlowPolicy.entryAuthority(
                        entryType: data.entryType,
                        scheme: data.entryScheme,
                        canonical: data.entryCanonical,
                        submittedEntryCode: submittedEntryCode
                      ) else {
                    throw RegistrationOutcomeUncertainError()
                }
                responseEntryAuthority = authority
            } else {
                responseEntryAuthority = nil
            }
            if let enterpriseContext,
               !registrationData(data, matches: enterpriseContext) {
                throw RegistrationOutcomeUncertainError()
            }
            if registrationResponseShouldFailClosedForAppIDIsolation(data, requestedEnterpriseCode: requestEnterpriseCode) {
                throw RegistrationOutcomeUncertainError()
            }
            if data.requiresRegistrationWorkspaceJoinRetry {
                guard try await resumeRegistrationWorkspaceJoin(
                    from: data,
                    entryCode: responseEntryAuthority?.canonicalCode ?? requestEnterpriseCode,
                    generation: generation
                ) else {
                    throw RegistrationOutcomeUncertainError()
                }
                guard isAuthenticated else {
                    beginRegistrationConfirmation(attempt: attempt, generation: generation)
                    return
                }
                if enterpriseContext != nil {
                    invalidatePreAuthEnterpriseContext(normalizeScreen: false)
                }
                finishRegistrationSuccess(attempt: attempt)
                return
            }
            if data.registrationSession == nil,
               !data.hasPendingWorkspaceApplication,
               let tenantID = data.tenant?.id.trimmingCharacters(in: .whitespacesAndNewlines),
               !tenantID.isEmpty {
                guard await completeRegistrationSession(
                    data, registrationContext: registrationContext,
                    attempt: attempt, authGeneration: generation
                ) else { throw RegistrationOutcomeUncertainError() }
                return
            }
            let completion = registrationCompletionDecision(data, enterpriseContext: enterpriseContext)
            switch completion {
            case .installSessionAndEnter:
                guard await completeRegistrationSession(
                    data, registrationContext: registrationContext,
                    attempt: attempt, authGeneration: generation
                ) else {
                    throw RegistrationOutcomeUncertainError()
                }
            case .awaitWorkspaceApproval, .rejectIncompleteSession:
                beginRegistrationConfirmation(attempt: attempt, generation: generation)
            }
        } catch _ as CancellationError {
            return
        } catch {
            guard authFlowGeneration.isCurrent(generation) else { return }
            guard let attempt = submittedAttempt else {
                if !handlePhoneAuthDisabledError(error) {
                    toast = registrationFailureMessage(error, enterpriseCode: normalizedEnterpriseCode)
                }
                return
            }
            if registrationFailureIsExplicit4xx(error) {
                finishRegistrationFailure(
                    error,
                    enterpriseCode: normalizedEnterpriseCode,
                    failureScreen: registrationFailureScreen,
                    attempt: attempt
                )
            } else {
                beginRegistrationConfirmation(attempt: attempt, generation: generation)
                // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：指定 503 code 保留原确认流程，仅替换用户文案
                if let pendingMessage = registrationPendingConfirmationMessage(error) {
                    toast = pendingMessage
                }
                // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
            }
        }
    }

    private func registrationFailureIsExplicit4xx(_ error: Error) -> Bool {
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册 503 回执/状态异常不是普通失败，继续确认原请求
        if registrationPendingConfirmationMessage(error) != nil {
            return false
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .httpStatus(let statusCode, _):
            return (400..<500).contains(statusCode)
        case .unauthorized, .forbidden, .businessForbidden, .conflict,
             .securityBlocked, .loginSecurity, .rateLimited:
            return true
        case .missingContext, .badURL, .forcedAuthRequired, .server, .emptyResponse:
            return false
        }
    }

    private func resetRegistrationNonSuccessState(failureScreen: AuthScreen) {
        isAuthenticated = false
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        disableAccessDiagnosticsOverlay()
        apiContext.clearSession(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        activeTab = .chats
        loginWorkspaceSelectionMessage = nil
        authScreen = failureScreen
    }

    private func finishRegistrationFailure(
        _ error: Error,
        enterpriseCode: String,
        failureScreen: AuthScreen,
        attempt: PendingRegistrationAttempt
    ) {
        cancelRegistrationConfirmationPolling()
        clearRegistrationRecovery()
        pendingRegistrationReceiptStore.clear()
        registrationResolutionState = .failed
        registrationConfirmationTimedOut = false
        resetRegistrationNonSuccessState(failureScreen: failureScreen)
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册错误文案优先按后端 error.code 精确映射，不再通过 message 关键词猜重名
        if let mappedMessage = registrationBackendCodeFailureMessage(error) {
            toast = mappedMessage
        } else if licenseQuotaUserMessage(from: error) != nil
                    || isRegistrationEntryCodeRateLimitError(error) {
            toast = registrationFailureMessage(error, enterpriseCode: enterpriseCode)
        } else if let inviteMessage = memberInviteCodeErrorMessage(error) {
            toast = "注册失败：\(inviteMessage)"
        } else {
            toast = "注册未通过，请检查填写内容；仍无法完成请联系管理员。"
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        recordRegistrationResolution(.failed, attempt: attempt)
    }

    private func beginRegistrationConfirmation(
        attempt: PendingRegistrationAttempt,
        generation: Int
    ) {
        guard authFlowGeneration.isCurrent(generation) else { return }
        _ = pendingRegistrationReceiptStore.save(PendingRegistrationReceipt(
            requestID: attempt.requestID,
            appID: attempt.appID,
            deviceID: attempt.deviceID,
            failureScreen: attempt.failureScreen == .phoneRegister ? "phone" : "account",
            startedAt: attempt.startedAt
        ))
        resetRegistrationNonSuccessState(
            failureScreen: attempt.failureScreen
        )
        registrationResolutionState = .pending
        registrationConfirmationTimedOut = false
        toast = RegistrationConfirmationPolicy.pendingMessage
        recordRegistrationResolution(.pending, attempt: attempt)
        startRegistrationConfirmationPolling(attempt: attempt)
    }

    private func finishRegistrationSuccess(attempt: PendingRegistrationAttempt) {
        cancelRegistrationConfirmationPolling()
        clearRegistrationRecovery()
        pendingRegistrationReceiptStore.clear()
        registrationResolutionState = .success
        registrationConfirmationTimedOut = false
        recordRegistrationResolution(.success, attempt: attempt)
    }

    func restorePendingRegistrationReceiptIfNeeded() {
        // Historical pending/failed requests neither resume polling nor change the
        // registration form. Keep already committed platform session recovery only.
        guard !apiContext.hasIMSession,
              let receipt = pendingRegistrationReceiptStore.load(),
              receipt.resolutionState != .failed, !receipt.sessionRecoveryCancelled,
              receipt.hasBoundScope, let appID = receipt.appID, let deviceID = receipt.deviceID,
              IMAPIContext.normalizedIOSAppID(apiContext.appID) == appID,
              apiContext.deviceID == deviceID else { return }
        let attempt = PendingRegistrationAttempt(requestID: receipt.requestID,
            appID: appID, deviceID: deviceID, failureScreen: receipt.authScreen, startedAt: receipt.startedAt)
        guard let recovery = loadRegistrationRecovery(attempt: attempt),
              committedRegistrationPlatformContext(recovery) != nil else { return }
        registrationResolutionState = .pending
        startRegistrationPlatformEntryRecovery(attempt: attempt)
    }

    private func startRegistrationConfirmationPolling(attempt: PendingRegistrationAttempt) {
        cancelRegistrationConfirmationPolling()
        let generation = registrationConfirmationGeneration
        let authGeneration = authFlowGeneration.currentToken()
        registrationConfirmationTask = Task { @MainActor [weak self] in
            await self?.pollRegistrationConfirmation(
                attempt: attempt,
                generation: generation,
                authGeneration: authGeneration
            )
        }
    }

    private func pollRegistrationConfirmation(
        attempt: PendingRegistrationAttempt,
        generation: UInt64,
        authGeneration: Int
    ) async {
#if DEBUG
        var finishedConfirmationHandling = false
#endif
        defer {
#if DEBUG
            // Terminal handlers cancel their own task as normal cleanup.
            if Task.isCancelled, !finishedConfirmationHandling {
                recordRegistrationDiagnostic(.confirmationCancelled, elapsedSeconds: registrationNow() - attempt.startedAt)
            }
#endif
            if registrationConfirmationGeneration == generation {
                registrationConfirmationTask = nil
            }
        }
        let deadline = attempt.startedAt + RegistrationConfirmationPolicy.totalConfirmationSeconds
        for delay in RegistrationConfirmationPolicy.sleepDelaysSeconds() {
            guard registrationConfirmationIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) else { return }
            let remaining = deadline - registrationNow()
            guard remaining > 0 else {
                finishRegistrationConfirmationTimeout(attempt: attempt)
                return
            }
            do {
                try await registrationSleep(min(delay, remaining))
            } catch {
                return
            }
            guard registrationConfirmationIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) else { return }
            guard registrationNow() < deadline else {
                finishRegistrationConfirmationTimeout(attempt: attempt)
                return
            }
            do {
                let status: RemoteRegistrationStatus
                if let recovery = loadRegistrationRecovery(attempt: attempt),
                   committedRegistrationPlatformContext(recovery) != nil {
                    status = .success
                } else {
                    status = try await api.registrationStatus(
                        appID: attempt.appID, deviceID: attempt.deviceID, requestID: attempt.requestID
                    )
                }
                guard registrationConfirmationIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) else { return }
                guard registrationNow() < deadline else {
                    finishRegistrationConfirmationTimeout(attempt: attempt)
                    return
                }
                switch status {
                case .success:
#if DEBUG
                    finishedConfirmationHandling = true
#endif
                    if await finishRegistrationConfirmedSuccess(attempt: attempt, generation: generation, authGeneration: authGeneration) {
                        return
                    }
                case .failed:
#if DEBUG
                    finishedConfirmationHandling = true
#endif
                    finishRegistrationConfirmedFailure(attempt: attempt)
                    return
                case .pending:
                    break
                }
            } catch is CancellationError {
                return
            } catch {
                // Status lookup can itself be temporarily unavailable. Stay
                // fail-closed in PENDING and retry without resubmitting registration.
            }
            guard registrationConfirmationIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) else { return }
            if registrationNow() >= deadline {
                finishRegistrationConfirmationTimeout(attempt: attempt)
                return
            }
        }
        finishRegistrationConfirmationTimeout(attempt: attempt)
    }

    private func registrationConfirmationIsCurrent(
        attempt: PendingRegistrationAttempt, generation: UInt64, authGeneration: Int
    ) -> Bool {
        guard registrationConfirmationGeneration == generation,
              authFlowGeneration.isCurrent(authGeneration),
              registrationResolutionState == .pending, !isAuthenticated, !apiContext.hasIMSession,
              IMAPIContext.normalizedIOSAppID(apiContext.appID) == attempt.appID,
              apiContext.deviceID == attempt.deviceID,
              let receipt = pendingRegistrationReceiptStore.load() else { return false }
        return receipt.requestID == attempt.requestID && receipt.appID == attempt.appID
            && receipt.deviceID == attempt.deviceID && receipt.startedAt == attempt.startedAt
    }

    private func loadRegistrationRecovery(attempt: PendingRegistrationAttempt) -> RegistrationSessionRecovery? {
        guard let value = registrationSessionStore.string(forKey: RegistrationSessionRecovery.storageKey),
              let bytes = value.data(using: .utf8),
              let recovery = try? JSONDecoder().decode(RegistrationSessionRecovery.self, from: bytes),
              let receipt = pendingRegistrationReceiptStore.load(),
              receipt.requestID == attempt.requestID,
              recovery.matchesScope(receipt),
              recovery.matches(receipt, now: registrationNow())
                || committedRegistrationPlatformContext(recovery) != nil else { return nil }
        registrationRecoveryReceipt = receipt
        registrationRecoveryEntryCode = recovery.entryCode
        return recovery
    }

    private func committedRegistrationPlatformContext(_ recovery: RegistrationSessionRecovery) -> IMAPIContext? {
        guard let sessionID = recovery.platformSessionID, let tenantID = recovery.tenantID,
              !tenantID.isEmpty, recovery.appID == IMAPIContext.normalizedIOSAppID(apiContext.appID),
              recovery.deviceID == apiContext.deviceID else { return nil }
        return apiContext.registrationPlatformContext(sessionID: sessionID, tenantID: tenantID, sessionStore: protectedSessionStore)
    }

    private func startRegistrationPlatformEntryRecovery(attempt: PendingRegistrationAttempt) {
        cancelRegistrationConfirmationPolling()
        let generation = registrationConfirmationGeneration
        let authGeneration = authFlowGeneration.currentToken()
        registrationConfirmationTimedOut = false
        registrationConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.registrationConfirmationGeneration == generation { self.registrationConfirmationTask = nil }
            }
            if !(await self.finishRegistrationConfirmedSuccess(attempt: attempt, generation: generation, authGeneration: authGeneration)),
               self.registrationRecoveryIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) {
                self.finishRegistrationConfirmationTimeout(attempt: attempt)
            }
        }
    }

    private func saveRegistrationRecovery(_ recovery: RegistrationSessionRecovery) -> Bool {
        guard let bytes = try? JSONEncoder().encode(recovery),
              let value = String(data: bytes, encoding: .utf8),
              registrationSessionStore.setString(value, forKey: RegistrationSessionRecovery.storageKey) else { return false }
        let saved = registrationSessionStore.string(forKey: RegistrationSessionRecovery.storageKey) == value
        if saved { registrationRecoveryEntryCode = recovery.entryCode }
        return saved
    }

    func registrationFormDidChange() {
        guard registrationSubmissionTask != nil || registrationResolutionState == .pending else { return }
        cancelRegistrationSessionRecovery()
    }

    func cancelRegistrationSessionRecovery(changedEntryCode: String? = nil) {
        if let changedEntryCode {
            var originalCode = registrationRecoveryEntryCode
            if originalCode == nil,
               let value = registrationSessionStore.string(forKey: RegistrationSessionRecovery.storageKey),
               let bytes = value.data(using: .utf8),
               let recovery = try? JSONDecoder().decode(RegistrationSessionRecovery.self, from: bytes) {
                originalCode = recovery.entryCode
            }
            if let originalCode, normalizedRegistrationTenantCode(changedEntryCode) == originalCode { return }
        }
        // Cancel the request and fence even transports that deliver a late response.
        registrationSubmissionTask?.cancel()
        registrationSubmissionTask = nil
        registrationSubmissionID = nil
        cancelRegistrationConfirmationPolling()
        authFlowGeneration.invalidate()
        isAuthLoading = false
        if let receipt = registrationRecoveryReceipt ?? pendingRegistrationReceiptStore.load(), receipt.hasBoundScope,
           let appID = receipt.appID, let deviceID = receipt.deviceID {
            _ = pendingRegistrationReceiptStore.save(PendingRegistrationReceipt(
                requestID: receipt.requestID, appID: appID, deviceID: deviceID,
                failureScreen: receipt.failureScreen, startedAt: receipt.startedAt,
                resolutionState: receipt.resolutionState, sessionRecoveryCancelled: true
            ))
        }
        clearRegistrationRecovery()
        registrationResolutionState = nil
        registrationConfirmationTimedOut = false
    }

    func clearRegistrationRecovery() {
        registrationSessionStore.deleteString(forKey: RegistrationSessionRecovery.storageKey)
        registrationRecoveryReceipt = nil
        registrationRecoveryEntryCode = nil
    }

    private func registrationRecoveryIsCurrent(
        attempt: PendingRegistrationAttempt, generation: UInt64, authGeneration: Int
    ) -> Bool {
        guard !Task.isCancelled, registrationConfirmationGeneration == generation,
              authFlowGeneration.isCurrent(authGeneration), !isAuthenticated,
              IMAPIContext.normalizedIOSAppID(apiContext.appID) == attempt.appID,
              apiContext.deviceID == attempt.deviceID,
              let receipt = pendingRegistrationReceiptStore.load() else { return false }
        return !receipt.sessionRecoveryCancelled && receipt.requestID == attempt.requestID && receipt.appID == attempt.appID
            && receipt.deviceID == attempt.deviceID && receipt.startedAt == attempt.startedAt
    }

    // Returns false only for a retryable exchange/entry failure. SUCCESS alone
    // never supplies authentication: the original protected proof does.
    private func finishRegistrationConfirmedSuccess(
        attempt: PendingRegistrationAttempt, generation: UInt64, authGeneration: Int
    ) async -> Bool {
        guard registrationRecoveryIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) else { return true }
        guard var recovery = loadRegistrationRecovery(attempt: attempt) else {
            clearRegistrationRecovery()
            finishRegistrationAwaitingManualLogin(message: "注册已确认，安全凭据不可用，请使用原账号登录")
            finishRegistrationSuccess(attempt: attempt)
            return true
        }
        var enteringTenant = false
        var exchangingSession = false
        do {
            if let committed = committedRegistrationPlatformContext(recovery) {
                apiContext = committed
            } else {
                exchangingSession = true
                let result = try await api.registrationSession(
                    appID: attempt.appID, deviceID: attempt.deviceID,
                    requestID: attempt.requestID, secret: recovery.secret
                )
                guard registrationRecoveryIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) else { return true }
                guard result.matches(recovery),
                      registrationNow() - attempt.startedAt < RegistrationConfirmationPolicy.publicConfirmationSeconds else {
                    throw IMAPIError.unauthorized("registration_session_unauthorized")
                }
                recovery.tenantID = result.tenantID
                recovery.platformSessionID = result.auth.authSession?.sessionID
                // Persist the association first. A crash before platform commit
                // then safely repeats the same idempotent exchange.
                guard saveRegistrationRecovery(recovery),
                      applyAuthData(result.auth, registrationTenantID: result.tenantID) else {
                    resetRegistrationNonSuccessState(failureScreen: attempt.failureScreen)
                    throw IMAPIError.server("protected_session_persistence_failed")
                }
            }
            exchangingSession = false
            enteringTenant = true
            guard let tenantID = recovery.tenantID, !tenantID.isEmpty else {
                throw IMAPIError.unauthorized("registration_session_unauthorized")
            }
            try await switchPlatformTenant(tenantID: tenantID, allowLegacyFallback: false, isCurrent: { [weak self] in
                self?.registrationRecoveryIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) == true
            })
            guard registrationRecoveryIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) else { return true }
            guard apiContext.tenantID == tenantID, apiContext.hasIMSession else {
                throw IMAPIError.server("protected_session_persistence_failed")
            }
            invalidatePreAuthEnterpriseContext(normalizeScreen: false)
            guard enterIM(showToast: false) != .rejectedMissingSession else { return false }
            toast = "注册成功，已自动登录"
            finishRegistrationSuccess(attempt: attempt)
            return true
        } catch {
            guard registrationRecoveryIsCurrent(attempt: attempt, generation: generation, authGeneration: authGeneration) else { return true }
            // Read the latest commit after await: entry may have rotated the
            // platform credential or persisted an uncertain refresh request ID.
            // Never write back the pre-entry snapshot or clear platform authority.
            if enteringTenant {
                if let latest = committedRegistrationPlatformContext(recovery) {
                    apiContext = latest
                    _ = latest.save(sessionStore: protectedSessionStore)
                } else {
                    apiContext.discardRegistrationIMState()
                }
            }
            let code = appPolicyErrorCode(from: error)
            let rejectedExchange: Bool
            if exchangingSession, let apiError = error as? IMAPIError {
                switch apiError {
                case .unauthorized, .httpStatus(401, _): rejectedExchange = true
                default: rejectedExchange = false
                }
            } else { rejectedExchange = false }
            if rejectedExchange || code.contains("registration_session_unauthorized") {
                clearRegistrationRecovery()
                finishRegistrationAwaitingManualLogin(message: "注册已确认，安全会话不可恢复，请使用原账号登录")
                finishRegistrationSuccess(attempt: attempt)
                return true
            }
            if code == "registration_session_failed" {
                finishRegistrationConfirmedFailure(attempt: attempt)
                return true
            }
            registrationConfirmationTimedOut = false
            toast = "注册已确认，正在安全恢复登录，请稍候"
            return false
        }
    }

    private func finishRegistrationConfirmedFailure(attempt: PendingRegistrationAttempt) {
        cancelRegistrationConfirmationPolling()
        clearRegistrationRecovery()
        pendingRegistrationReceiptStore.clear()
        resetRegistrationNonSuccessState(failureScreen: attempt.failureScreen)
        registrationResolutionState = .failed
        registrationConfirmationTimedOut = false
        toast = "注册失败，请重新提交注册"
        recordRegistrationResolution(.failed, attempt: attempt)
    }

    private func finishRegistrationConfirmationTimeout(attempt: PendingRegistrationAttempt) {
        guard registrationResolutionState == .pending else { return }
#if DEBUG
        recordRegistrationDiagnostic(.confirmationExpired, elapsedSeconds: registrationNow() - attempt.startedAt)
#endif
        registrationConfirmationTask = nil
        registrationConfirmationTimedOut = true
        toast = registrationConfirmationMessage
        recordRegistrationResolution(.pending, attempt: attempt)
    }

    func cancelRegistrationConfirmationPolling() {
        registrationConfirmationGeneration &+= 1
        registrationConfirmationTask?.cancel()
        registrationConfirmationTask = nil
    }

    func abandonRegistrationConfirmationForAuthenticatedSession() {
        guard registrationResolutionState == .pending else { return }
        cancelRegistrationConfirmationPolling()
        clearRegistrationRecovery()
        pendingRegistrationReceiptStore.clear()
        registrationResolutionState = nil
        registrationConfirmationTimedOut = false
    }

    private func recordRegistrationResolution(
        _ state: RegistrationResolutionState,
        attempt: PendingRegistrationAttempt
    ) {
#if DEBUG
        recordRegistrationResolutionState(
            state,
            elapsedSeconds: max(0, registrationNow() - attempt.startedAt)
        )
#endif
    }

    private func registrationErrorClassificationText(_ error: Error) -> String {
        guard let apiError = error as? IMAPIError else { return "" }
        switch apiError {
        case .businessForbidden(let code, let message, _),
             .conflict(let code, let message),
             .loginSecurity(let code, let message, _),
             .rateLimited(let code, let message, _, _):
            return "\(code) \(message)"
        case .forbidden(let message), .httpStatus(_, let message),
             .server(let message), .unauthorized(let message),
             .badURL(let message), .missingContext(let message):
            return message
        case .securityBlocked, .forcedAuthRequired, .emptyResponse:
            return ""
        }
    }

    private func finishRegistrationAwaitingManualLogin(message: String) {
        isAuthenticated = false
        stopInboxRefreshLoop()
        disableAccessDiagnosticsOverlay()
        apiContext.clearSession(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        activeTab = .chats
        loginWorkspaceSelectionMessage = nil
        authScreen = .accountLogin
        toast = message
    }

    private func finishRegistrationAwaitingApproval(message: String) {
        isAuthenticated = false
        stopInboxRefreshLoop()
        disableAccessDiagnosticsOverlay()
        resetAuthenticatedRemoteData(showLoading: false)
        activeTab = .chats
        loginWorkspaceSelectionMessage = message
        authScreen = .accountLogin
        toast = message
    }

    private func resumeRegistrationWorkspaceJoin(
        from data: RemoteAuthData,
        entryCode: String?,
        generation: Int
    ) async throws -> Bool {
        guard applyAuthData(data), authFlowGeneration.isCurrent(generation) else {
            return false
        }
        let appID = IMAPIContext.normalizedIOSAppID(apiContext.appID)
        let platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, platformToken?.isEmpty == false else { return false }

        var memberships = (data.memberships ?? []).filter { $0.isVisibleInAppScope(appID) }
        if memberships.isEmpty {
            memberships = try await api.listMyTenants(platformToken: platformToken, appID: appID)
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
        }
        if memberships.isEmpty {
            let normalizedEntryCode = normalizedRegistrationTenantCode(entryCode)
            guard !normalizedEntryCode.isEmpty else { return false }
            do {
                memberships = [try await api.joinTenant(
                    code: normalizedEntryCode,
                    platformToken: platformToken,
                    appID: appID
                )]
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_pending" {
                guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
                finishRegistrationAwaitingApproval(message: RegistrationFlowPolicy.pendingWorkspaceApprovalMessage)
                return true
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_rejected" {
                guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
                finishRegistrationAwaitingManualLogin(message: "入企申请已被拒绝，请联系企业管理员")
                return true
            } catch IMAPIError.conflict(let code, _) where [
                "workspace_join_approved", "workspace_already_joined", "workspace_join_conflict"
            ].contains(code) {
                memberships = try await api.listMyTenants(platformToken: platformToken, appID: appID)
            }
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
        }

        let scopedMemberships = memberships.filter { $0.isVisibleInAppScope(appID) }
        guard !scopedMemberships.isEmpty else { return false }
        applyTenantMemberships(scopedMemberships)
        let projected = scopedMemberships.enumerated().map { index, membership in
            enterprise(
                from: membership,
                fallbackAccent: [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7][index % 4]
            )
        }
        if projected.contains(where: \.isWorkspaceJoinPending) {
            finishRegistrationAwaitingApproval(message: RegistrationFlowPolicy.pendingWorkspaceApprovalMessage)
            return true
        }
        if !projected.contains(where: { $0.isWorkspaceJoined && $0.isWorkspaceEnterable }),
           projected.contains(where: \.isWorkspaceJoinRejected) {
            finishRegistrationAwaitingManualLogin(message: "入企申请已被拒绝，请联系企业管理员")
            return true
        }
        if await attemptSingleWorkspaceAutoEnterFromDirectory(
            scopedMemberships,
            syncedMessage: "注册成功，已自动登录",
            fallbackMessage: "注册成功，聊天数据正在同步",
            loginGeneration: generation
        ) {
            return true
        }
        prepareLoginWorkspaceSelectionFromCurrentDirectory(
            message: "注册成功，请选择本次要进入的企业。",
            loginGeneration: generation
        )
        toast = "注册成功，请选择企业"
        return true
    }

    private func registrationCompletionDecision(
        _ data: RemoteAuthData,
        enterpriseContext: PreAuthEnterpriseContext?
    ) -> RegistrationCompletionDecision {
        let session = data.registrationSession
        let sessionTenantID = session?.tenant.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let responseTenantID = data.tenant?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if session != nil {
            let entryStatus = data.entryStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard data.canDirectEnter != false,
                  data.requiresWorkspaceSelection != true,
                  entryStatus.isEmpty || entryStatus == "entered" else {
                return .rejectIncompleteSession(message: RegistrationFlowPolicy.incompleteSessionMessage)
            }
        }
        let matchesResolvedEnterprise: Bool
        if let enterpriseContext {
            matchesResolvedEnterprise = registrationData(data, matches: enterpriseContext)
                && sessionTenantID == enterpriseContext.tenantID
        } else {
            matchesResolvedEnterprise = !data.fallbackToDefaultTenant
                || data.requestedTenantCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !sessionTenantID.isEmpty, !responseTenantID.isEmpty, sessionTenantID != responseTenantID {
                return .rejectIncompleteSession(message: RegistrationFlowPolicy.incompleteSessionMessage)
            }
        }
        return RegistrationFlowPolicy.completionDecision(
            enterpriseCodeFirst: enterpriseContext != nil,
            evidence: RegistrationSessionEvidence(
                hasPlatformSession: !data.platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                hasIMSession: !(session?.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    && !(session?.imUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                hasTenant: session?.tenant.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                hasTenantMember: session?.member.tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                matchesResolvedEnterprise: matchesResolvedEnterprise,
                hasPendingWorkspaceApproval: data.hasPendingWorkspaceApplication
            )
        )
    }

    private func completeRegistrationSession(
        _ data: RemoteAuthData,
        registrationContext: IMAPIContext,
        attempt: PendingRegistrationAttempt,
        authGeneration: Int
    ) async -> Bool {
        guard authFlowGeneration.isCurrent(authGeneration),
              apiContext.isSameAuthAuthority(as: registrationContext.authSessionFence) else { return false }
        if data.registrationSession != nil {
            guard registrationSessionInstallAssessment(
                data, registrationContext: registrationContext,
                platformSessionPersisted: true, tenantSessionPersisted: true,
                hasCompleteIMSession: true
            ) == .accepted else { return false }
        }
        let tenantID = (data.registrationSession?.tenant.id ?? data.tenant?.id ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenantID.isEmpty, !data.account.id.isEmpty,
              !data.platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let platform = data.authSession, platform.isUsable,
              platform.normalizedTokenType == "platform",
              IMAPIContext.normalizedIOSAppID(platform.appID) == attempt.appID,
              platform.deviceID == attempt.deviceID,
              var recovery = loadRegistrationRecovery(attempt: attempt) else { return false }
        recovery.tenantID = tenantID
        recovery.platformSessionID = platform.sessionID
        // Bind the existing recovery receipt before committing platform-only
        // authority. Never activate a platform-signed inline IM token on a
        // tenant data plane with its own signing authority.
        guard saveRegistrationRecovery(recovery),
              applyAuthData(data, registrationTenantID: tenantID) else { return false }
        isAuthenticated = false
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        resetAuthenticatedRemoteData(showLoading: false)
        registrationResolutionState = .pending
        let confirmationGeneration = registrationConfirmationGeneration
        let finished = await finishRegistrationConfirmedSuccess(
            attempt: attempt, generation: confirmationGeneration, authGeneration: authGeneration
        )
        if !finished, registrationRecoveryIsCurrent(
            attempt: attempt, generation: confirmationGeneration, authGeneration: authGeneration
        ) {
            // A failed entry is not a failed registration. Keep the durable
            // platform authority for the existing bounded retry/restart path.
            finishRegistrationConfirmationTimeout(attempt: attempt)
        }
        return true
    }

    private func registrationSessionInstallAssessment(
        _ data: RemoteAuthData,
        registrationContext: IMAPIContext,
        platformSessionPersisted: Bool,
        tenantSessionPersisted: Bool,
        hasCompleteIMSession: Bool
    ) -> RegistrationSessionInstallAssessment {
        guard let session = data.registrationSession else {
            return RegistrationFlowPolicy.sessionInstallAssessment(
                evidence: RegistrationSessionInstallEvidence(
                    hasTenantSession: false,
                    tenantIdentityMatches: false,
                    tenantMemberIdentityMatches: false,
                    appIdentityMatches: false,
                    runtimeContractMatches: false,
                    runtimeIdentityMatches: false,
                    runtimeRouteIsSafe: false,
                    platformSessionPersisted: platformSessionPersisted,
                    tenantSessionPersisted: tenantSessionPersisted,
                    hasCompleteIMSession: hasCompleteIMSession
                )
            )
        }
        let tenantID = session.tenant.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedAppID = IMAPIContext.normalizedIOSAppID(registrationContext.appID)
        let sessionAppID = IMAPIContext.normalizedIOSAppID(session.app.appID)
        let tenantIdentityMatches = !tenantID.isEmpty
        let memberIdentityMatches = !tenantID.isEmpty && session.member.tenantID == tenantID
        let appIdentityMatches = !expectedAppID.isEmpty && sessionAppID == expectedAppID
        let runtimeContractMatches: Bool
        let runtimeIdentityMatches: Bool
        if let runtimeConfig = data.registrationRuntimeConfig {
            let routes = runtimeConfig.runtimeRouteSnapshot
            runtimeContractMatches = runtimeConfig.contractVersion == 2
            runtimeIdentityMatches = routes.appID == expectedAppID && routes.tenantID == tenantID
        } else {
            runtimeContractMatches = true
            runtimeIdentityMatches = true
        }
        return RegistrationFlowPolicy.sessionInstallAssessment(
            evidence: RegistrationSessionInstallEvidence(
                hasTenantSession: true,
                tenantIdentityMatches: tenantIdentityMatches,
                tenantMemberIdentityMatches: memberIdentityMatches,
                appIdentityMatches: appIdentityMatches,
                runtimeContractMatches: runtimeContractMatches,
                runtimeIdentityMatches: runtimeIdentityMatches,
                runtimeRouteIsSafe: registrationSessionRuntimeBases(
                    data,
                    session: session,
                    registrationContext: registrationContext
                ) != nil,
                platformSessionPersisted: platformSessionPersisted,
                tenantSessionPersisted: tenantSessionPersisted,
                hasCompleteIMSession: hasCompleteIMSession
            )
        )
    }

    private func registrationSessionRuntimeBases(
        _ data: RemoteAuthData,
        session: RemoteTenantSwitchResult,
        registrationContext: IMAPIContext
    ) -> (tenant: URL, im: URL?)? {
        let tenantID = session.tenant.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedAppID = IMAPIContext.normalizedIOSAppID(registrationContext.appID)
        if let runtimeConfig = data.registrationRuntimeConfig {
            let routes = runtimeConfig.runtimeRouteSnapshot
            guard runtimeConfig.contractVersion == 2,
                  routes.appID == expectedAppID,
                  routes.tenantID == tenantID,
                  routes.validated(appID: expectedAppID, tenantID: tenantID) != nil,
                  let tenantRoute = Self.freshRuntimeEndpoint(routes, service: .tenantAPI),
                  let resolvedTenantBaseURL = IMAPIClient.normalizedTenantAPIBaseURL(tenantRoute) else {
                return nil
            }
            let imBaseURL = Self.freshRuntimeEndpoint(routes, service: .imAPI)
                .flatMap(IMAPIClient.normalizedIMAPIBaseURL)
            return (resolvedTenantBaseURL, imBaseURL)
        } else {
            // Compatibility for pre-v2 registration responses. New entered responses are
            // required to carry runtime_config and therefore do not rely on this projection.
            guard let server = session.server,
                  let resolvedTenantBaseURL = IMAPIClient.normalizedTenantAPIBaseURL(server.apiHost) else {
                return nil
            }
            let declaredIMBase = server.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let imBaseURL = IMAPIClient.normalizedIMAPIBaseURL(
                declaredIMBase.isEmpty ? resolvedTenantBaseURL.absoluteString : declaredIMBase
            )
            return (resolvedTenantBaseURL, imBaseURL)
        }
    }

    private func registrationData(
        _ data: RemoteAuthData,
        matches context: PreAuthEnterpriseContext
    ) -> Bool {
        guard !data.fallbackToDefaultTenant else { return false }
        if data.hasTypedEntryAuthority {
            guard let authority = RegistrationFlowPolicy.entryAuthority(
                entryType: data.entryType,
                scheme: data.entryScheme,
                canonical: data.entryCanonical,
                submittedEntryCode: context.entryCode
            ),
            authority.entryType == context.entryType,
            authority.scheme == context.entryScheme,
            authority.canonicalCode == context.entryCode else {
                return false
            }
        }
        let canonicalTenantCode = normalizedRegistrationTenantCode(context.tenantCode)
        let requestedTenantCode = normalizedRegistrationTenantCode(data.requestedTenantCode)
        guard !canonicalTenantCode.isEmpty,
              requestedTenantCode == normalizedRegistrationTenantCode(context.entryCode)
                || requestedTenantCode == canonicalTenantCode else {
            return false
        }
        if let session = data.registrationSession {
            guard session.tenant.id == context.tenantID,
                  session.member.tenantID == context.tenantID,
                  IMAPIContext.normalizedIOSAppID(session.app.appID) == context.appID,
                  normalizedRegistrationTenantCode(session.tenant.tenantCode) == canonicalTenantCode
            else { return false }
            if let tenant = data.tenant,
               tenant.id != context.tenantID
                    || normalizedRegistrationTenantCode(tenant.tenantCode) != canonicalTenantCode {
                return false
            }
            if let tenantMember = data.tenantMember,
               tenantMember.tenantID != context.tenantID {
                return false
            }
            return true
        }
        guard IMAPIContext.normalizedIOSAppID(data.authSession?.appID ?? "") == context.appID,
              let tenant = data.tenant,
              tenant.id == context.tenantID,
              normalizedRegistrationTenantCode(tenant.tenantCode) == canonicalTenantCode,
              let tenantMember = data.tenantMember,
              tenantMember.tenantID == context.tenantID else { return false }
        return true
    }

    private func registrationTenantNotFoundAPIError() -> IMAPIError {
        IMAPIError.businessForbidden(code: "tenant_code_not_found", message: "tenant_code_not_found", error: nil)
    }

    private func registrationResponseShouldFailClosedForAppIDIsolation(_ data: RemoteAuthData, requestedEnterpriseCode: String?) -> Bool {
        let requestedCode = normalizedRegistrationTenantCode(requestedEnterpriseCode)
        guard !requestedCode.isEmpty else { return false }
        if data.fallbackToDefaultTenant {
            return true
        }
        if isRegistrationTenantNotFoundText(data.fallbackReason) {
            return true
        }
        if isMemberInviteEntryCode(requestedCode) {
            return false
        }
        if let tenant = data.tenant,
           !registrationTenantCode(tenant.tenantCode, matches: requestedCode) {
            return true
        }
        if let memberships = data.memberships, !memberships.isEmpty {
            let requestedMemberships = memberships.filter { registrationTenantCode($0.tenant.tenantCode, matches: requestedCode) }
            if !requestedMemberships.isEmpty {
                return requestedMemberships.contains(where: registrationMembershipIndicatesAppIDIsolation)
            }
            let codedMemberships = memberships.filter { !normalizedRegistrationTenantCode($0.tenant.tenantCode).isEmpty }
            if !codedMemberships.isEmpty,
               !codedMemberships.contains(where: { registrationTenantCode($0.tenant.tenantCode, matches: requestedCode) }) {
                return true
            }
        }
        return false
    }

    private func registrationShouldFailClosedAfterLogin(enterpriseCode: String?) -> Bool {
        let requestedCode = normalizedRegistrationTenantCode(enterpriseCode)
        guard !requestedCode.isEmpty else { return false }
        if apiContext.hasIMSession,
           registrationTenantCode(currentEnterprise.code, matches: requestedCode),
           !registrationEnterpriseIndicatesAppIDIsolation(currentEnterprise) {
            return false
        }
        if enterprises.contains(where: { enterprise in
            registrationTenantCode(enterprise.code, matches: requestedCode)
                && !registrationEnterpriseIndicatesAppIDIsolation(enterprise)
        }) {
            return false
        }
        return true
    }

    private func registrationTenantCode(_ rawCode: String, matches requestedCode: String) -> Bool {
        normalizedRegistrationTenantCode(rawCode) == requestedCode
    }

    private func registrationMembershipIndicatesAppIDIsolation(_ membership: RemoteTenantMembership) -> Bool {
        !membership.isVisibleInAppScope(currentAppID)
            || isRegistrationTenantNotFoundText(membership.disabledReason)
    }

    private func registrationEnterpriseIndicatesAppIDIsolation(_ enterprise: Enterprise) -> Bool {
        isRegistrationTenantNotFoundText(enterprise.disabledReason)
            || workspaceAccessCode(from: enterprise.disabledReason) == "workspace_not_found"
    }

    private func isMemberInviteEntryCode(_ value: String) -> Bool {
        RegistrationFlowPolicy.normalizedEntryCode(value)?.kind == .memberInvitation
    }

    private func registrationFailureMessage(_ error: Error, enterpriseCode: String) -> String {
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册场景已知 code 优先返回文档文案，避免被通用英文过滤兜底吞掉
        if let mappedMessage = registrationBackendCodeFailureMessage(error) {
            return mappedMessage
        }
        if let pendingMessage = registrationPendingConfirmationMessage(error) {
            return pendingMessage
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        let hasEnterpriseCode = !enterpriseCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isRegistrationEntryCodeRateLimitError(error) {
            return enterpriseContextFailureMessage(error)
        }
        if let message = memberInviteCodeErrorMessage(error) {
            return message
        }
        if hasEnterpriseCode, isRegistrationTenantNotFoundError(error) {
            return "该企业不存在"
        }
        let message = safeRegistrationFailureUserMessage(error)
        if let inviteMessage = memberInviteCodeErrorMessage(message) {
            return inviteMessage
        }
        if hasEnterpriseCode, isRegistrationTenantNotFoundText(message) {
            return "该企业不存在"
        }
        return message
    }

    // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册接口后端 error.code 与前端提示文案精确映射
    private func registrationBackendCodeFailureMessage(_ error: Error) -> String? {
        switch registrationBackendErrorCode(from: error) {
        case "account_username_exists":
            return "账号已存在，请登录或更换账号。"
        case "invalid_user_account_format", "invalid_account_format":
            return "账号须为5–10位英文字母或数字。"
        case "weak_password":
            return "密码须为8–20位，且包含字母和数字。"
        case "tenant_code_required":
            return "请输入企业编码或邀请码。"
        case "tenant_code_not_found":
            return "该企业不存在，请检查企业编码。"
        case "entry_code_invalid":
            return "企业编码或邀请码格式不正确，请检查后重试。"
        case "enterprise_context_invalid":
            return "企业信息已失效或当前不可用，请重新确认企业。"
        case "default_tenant_not_configured":
            return "默认企业尚未配置，请输入企业编码或联系管理员。"
        case "default_tenant_unavailable":
            return "默认企业暂不可用，请输入企业编码或联系管理员。"
        case "registration_disabled":
            return "当前应用暂未开放注册，请联系管理员。"
        case "app_id_required":
            return "应用配置异常，请联系管理员。"
        case "app_not_found":
            return "当前应用未配置或不适用于该企业，请联系管理员。"
        case "app_disabled":
            return "当前应用已停用，请联系管理员。"
        case "captcha_invalid":
            return "验证码无效或已过期，请重新获取。"
        case "client_registration_rate_limited":
            return "今日注册数量已达上限，请稍后再试。"
        case "registration_tenant_code_probe_rate_limited":
            return "企业码验证过于频繁，请稍后再试。"
        case "registered_user_quota_exceeded":
            return "当前企业注册用户数已达上限，请联系企业管理员。"
        case "registration_request_failed":
            return "本次注册未成功，请查看具体原因后重新提交。"
        default:
            return nil
        }
    }

    private func registrationPendingConfirmationMessage(_ error: Error) -> String? {
        switch registrationBackendErrorCode(from: error) {
        case "registration_request_already_submitted":
            return "注册请求已提交，正在确认结果，请勿重复操作。"
        case "registration_status_unavailable":
            return "暂时无法确认注册结果，请稍后查询，勿重复注册。"
        default:
            return nil
        }
    }

    private func registrationBackendErrorCode(from error: Error) -> String {
        guard let apiError = error as? IMAPIError else { return "" }
        let code: String
        switch apiError {
        case .businessForbidden(let value, _, _),
             .conflict(let value, _),
             .loginSecurity(let value, _, _),
             .rateLimited(let value, _, _, _):
            code = value
        default:
            code = ""
        }
        return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束

    private func safeRegistrationFailureUserMessage(_ error: Error) -> String {
        let message = userFacingError(error).trimmingCharacters(in: .whitespacesAndNewlines)
        let containsUserFacingChinese = message.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        guard containsUserFacingChinese else {
            return "请求未通过，请检查后重试"
        }
        let errorCode = appPolicyErrorCode(from: error)
        guard errorCode.isEmpty || !message.lowercased().contains(errorCode) else {
            return "请求未通过，请检查后重试"
        }
        return message
    }

    private func memberInviteCodeErrorMessage(_ error: Error) -> String? {
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .businessForbidden(let code, let message, _),
                 .conflict(let code, let message),
                 .loginSecurity(let code, let message, _),
                 .rateLimited(let code, let message, _, _):
                return memberInviteCodeErrorMessage("\(code) \(message)")
            case .forbidden(let message),
                 .httpStatus(_, let message),
                 .server(let message),
                 .unauthorized(let message),
                 .badURL(let message),
                 .missingContext(let message):
                return memberInviteCodeErrorMessage(message)
            case .securityBlocked, .forcedAuthRequired, .emptyResponse:
                return nil
            }
        }
        return memberInviteCodeErrorMessage(String(describing: error))
    }

    static func memberInviteCodeUserMessage(for value: String) -> String? {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowered.contains("member_invite_code") else { return nil }
        if lowered.contains("sync_pending") || lowered.contains("sync_unavailable") || lowered.contains("unavailable") {
            return "邀请码暂不可用于注册"
        }
        if lowered.contains("tenant_conflict") {
            return "邀请码和企业不匹配"
        }
        return "邀请码无效或已停用"
    }

    private func memberInviteCodeErrorMessage(_ value: String) -> String? {
        Self.memberInviteCodeUserMessage(for: value)
    }

    private func isRegistrationTenantNotFoundError(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else {
            return isRegistrationTenantNotFoundText(String(describing: error))
        }
        switch apiError {
        case .businessForbidden(let code, let message, _),
             .conflict(let code, let message),
             .loginSecurity(let code, let message, _),
             .rateLimited(let code, let message, _, _):
            return isRegistrationTenantNotFoundText("\(code) \(message)")
        case .forbidden(let message),
             .httpStatus(_, let message),
             .server(let message),
             .unauthorized(let message),
             .badURL(let message),
             .missingContext(let message):
            return isRegistrationTenantNotFoundText(message)
        case .securityBlocked, .forcedAuthRequired, .emptyResponse:
            return false
        }
    }

    private func isRegistrationTenantNotFoundText(_ value: String) -> Bool {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        if lowered == "not found" || lowered == "not_found" {
            return true
        }
        return lowered.contains("tenant_code_not_found")
            || lowered.contains("tenant code not found")
            || lowered.contains("tenant_not_found")
            || lowered.contains("workspace_not_found")
            || lowered.contains("app_tenant_not_bound")
            || lowered.contains("enterprise_not_found")
            || lowered.contains("企业码不存在")
            || lowered.contains("企业代码不存在")
            || lowered.contains("企业不存在")
    }

    private func recoverExistingPlatformRegistration(username: String, password: String, enterpriseCode: String?, generation: Int) async throws -> Bool {
        do {
            let platformData = try await api.login(username: username, password: password)
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            guard applyAuthData(platformData) else {
                throw IMAPIError.server("protected_session_persistence_failed")
            }
            let platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            let scopedAppID = IMAPIContext.normalizedIOSAppID(apiContext.appID)
            var memberships = try await api.listMyTenants(platformToken: platformToken, appID: scopedAppID)
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            if memberships.isEmpty {
                let code = enterpriseCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let joinCode = code?.isEmpty == false ? code! : "WXT000001"
                do {
                    let membership = try await api.joinTenant(code: joinCode, platformToken: platformToken, appID: scopedAppID)
                    guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
                    memberships = [membership]
                } catch IMAPIError.conflict {
                    memberships = try await api.listMyTenants(platformToken: platformToken, appID: scopedAppID)
                    guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
                }
            }
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            let requestedCode = normalizedRegistrationTenantCode(enterpriseCode)
            let scopedMemberships = memberships.filter { $0.isVisibleInAppScope(scopedAppID) }
            if !requestedCode.isEmpty {
                let requestedMemberships = memberships.filter { registrationTenantCode($0.tenant.tenantCode, matches: requestedCode) }
                if requestedMemberships.isEmpty
                    || requestedMemberships.contains(where: registrationMembershipIndicatesAppIDIsolation)
                    || !scopedMemberships.contains(where: { registrationTenantCode($0.tenant.tenantCode, matches: requestedCode) }) {
                    throw registrationTenantNotFoundAPIError()
                }
            }
            memberships = scopedMemberships
            guard !memberships.isEmpty else {
                return false
            }
            applyTenantMemberships(memberships)
            apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
            resetAuthenticatedRemoteData(showLoading: false)
            authScreen = .workspaceSelection
            loginWorkspaceSelectionMessage = "已恢复账号，请选择本次要进入的企业。"
            return !memberships.isEmpty
        } catch _ as CancellationError {
            throw CancellationError()
        } catch {
            if isRegistrationTenantNotFoundError(error) {
                throw error
            }
            return false
        }
    }

    @discardableResult
    func refreshRemoteSnapshot(silent: Bool, force: Bool = false) async -> Bool {
        var outcome = SyncFailureDiagnostic.PrimaryOutcome.missingSession
        defer { SyncFailureDiagnostic.persistPrimaryOutcome(outcome) }
        guard apiContext.hasIMSession else {
            isInitialDataLoading = false
            return false
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let syncPlan = remoteSyncEngine.remoteSnapshotSyncPlan(scope: scope, force: force)
        let syncCommand: RemoteSnapshotSyncCommand
        switch syncPlan {
        case .remoteSnapshot(let command):
            syncCommand = command
        case .skip:
            outcome = .skipped
            if force, !scope.isEmpty {
                pendingForcedRemoteSnapshotSuccessorScopes.insert(scope)
            }
            return false
        }
        let syncResult = remoteSyncEngine.beginRemoteSnapshotSync(syncCommand)
        guard syncResult.started else {
            outcome = .alreadyRunning
            if force, !scope.isEmpty {
                pendingForcedRemoteSnapshotSuccessorScopes.insert(scope)
            }
            return false
        }
        let performanceStart = CFAbsoluteTimeGetCurrent()
        let refreshSession = remoteSyncEngine.beginRemoteSnapshotRefresh()
        let generation = refreshSession.generation
        print("[JHT Perf] restore_start generation=\(generation) scope=\(Self.sessionScopeLogToken(scope))")
        defer {
            remoteSyncEngine.finishRemoteSnapshotSync(syncCommand)
            if remoteSyncEngine.finishRemoteSnapshotRefresh(refreshSession) {
                isInitialDataLoading = false
            }
            scheduleForcedRemoteSnapshotSuccessorIfNeeded(scope: scope)
        }

        if !silent {
            syncFailureMessage = nil
        }
        outcome = .obsolete
        let primarySynced = await syncPrimaryConversationData(context: context, scope: scope, refreshSession: refreshSession, silent: silent, forceFull: force, performanceStart: performanceStart)
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return false }
        outcome = primarySynced ? .complete : .incomplete
        refreshSecondarySnapshotInBackground(context: context, scope: scope, refreshSession: refreshSession)
        return primarySynced
    }

    private func scheduleForcedRemoteSnapshotSuccessorIfNeeded(scope: String) {
        guard pendingForcedRemoteSnapshotSuccessorScopes.remove(scope) != nil else {
            return
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isCurrentRemoteScope(scope) else { return }
            _ = await self.refreshRemoteSnapshot(silent: true, force: true)
        }
    }

    private func syncPrimaryConversationData(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession, silent: Bool, forceFull: Bool, performanceStart: CFAbsoluteTime) async -> Bool {
        do {
            return try await performPrimaryConversationSyncAttempt(
                context: context,
                scope: scope,
                refreshSession: refreshSession,
                forceFull: forceFull,
                performanceStart: performanceStart,
                authRefreshed: false
            )
        } catch {
            if error is CancellationError { SyncFailureDiagnostic.persistPrimaryOutcome(.cancelled) }
            guard !(error is CancellationError), isCurrentRemoteRefresh(refreshSession, scope: scope) else { return false }
            if isRefreshableSessionError(error),
               await refreshStoredAuthSessionIfNeeded(reason: "primary_sync", silent: silent, context: context, scope: scope) {
                let refreshedContext = apiContext
                let refreshedScope = remoteDataScopeKey(for: refreshedContext)
                guard refreshedContext.hasIMSession,
                      refreshedScope == scope,
                      isCurrentRemoteRefresh(refreshSession, scope: scope) else { return false }
                do {
                    return try await performPrimaryConversationSyncAttempt(
                        context: refreshedContext,
                        scope: scope,
                        refreshSession: refreshSession,
                        forceFull: forceFull,
                        performanceStart: performanceStart,
                        authRefreshed: true
                    )
                } catch {
                    if error is CancellationError { SyncFailureDiagnostic.persistPrimaryOutcome(.cancelled) }
                    guard !(error is CancellationError), isCurrentRemoteRefresh(refreshSession, scope: scope) else { return false }
                    handlePrimaryConversationSyncFailure(error, silent: silent)
                    return false
                }
            }
            handlePrimaryConversationSyncFailure(error, silent: silent)
            return false
        }
    }

    private func performPrimaryConversationSyncAttempt(
        context: IMAPIContext,
        scope: String,
        refreshSession: RemoteSnapshotRefreshSession,
        forceFull: Bool,
        performanceStart: CFAbsoluteTime,
        authRefreshed: Bool
    ) async throws -> Bool {
        let command = remoteSyncEngine.remoteConversationSyncCommand(forceFull: forceFull || isConversationSnapshotPartial)
        if command.replacesLocalSnapshot {
            return try await performPagedConversationSnapshot(
                context: context, scope: scope, refreshSession: refreshSession,
                command: command, performanceStart: performanceStart
            )
        }
        let diagnostic = SyncFailureDiagnostic.HTTPObservation(.conversationSync)
        let data = try await SyncFailureDiagnostic.$httpObservation.withValue(diagnostic) {
            defer { diagnostic.finish() }
            return try await diagnostic.perform {
                try await api.syncConversations(context: context, version: command.requestedVersion)
            }
        }
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else {
            SyncFailureDiagnostic.persistPrimaryOutcome(.obsolete)
            return false
        }
        guard apiContext.isSameAuthAuthority(as: context.authSessionFence),
              apiContext.deviceID == context.deviceID else {
            SyncFailureDiagnostic.persistPrimaryOutcome(.authorityChanged)
            return false
        }
        let generation = refreshSession.generation
        remoteSyncEngine.finishRemoteConversationSync(command, responseVersion: data.version)
        let applyStart = CFAbsoluteTimeGetCurrent()
        applyRemoteConversations(data.conversations, replacing: command.replacesLocalSnapshot)
        applySearchInvalidations(data.removedConversations.map {
            SearchInvalidationEvent(removedConversation: $0, fallbackTenantID: context.tenantID ?? "")
        })
        logConversationSyncSummary(data: data, requestedVersion: command.requestedVersion, generation: generation, authRefreshed: authRefreshed)
        let applyMs = Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000)
        hasLoadedRemoteSnapshot = true
        lastRemoteSnapshotPrimarySyncedAt = Date()
        syncFailureMessage = nil
        let listReadyMs = Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)
        if authRefreshed {
            print("[JHT Perf] conversation_list_ready_ms=\(listReadyMs) count=\(data.conversations.count) apply_ms=\(applyMs) generation=\(generation) auth_refreshed=true")
        } else {
            print("[JHT Perf] conversation_list_ready_ms=\(listReadyMs) count=\(data.conversations.count) apply_ms=\(applyMs) generation=\(generation)")
        }
        startConversationHistoryPrefetch(
            data.conversations,
            context: context,
            scope: scope,
            refreshSession: refreshSession,
            performanceStart: performanceStart
        )
        schedulePersistedMessageSequenceRecoveries(reason: "remote_snapshot")
        scheduleRemoteSnapshotCacheWrite(
            scope: scope,
            source: .conversationSync,
            replaceMissingConversations: command.replacesLocalSnapshot
        )
        return true
    }

    func makeConversationUserLookup() -> ConversationUserLookup {
        ConversationUserLookup(currentUser: currentUser, currentIdentifiers: currentUserIdentitySet(),
                               contacts: contacts, groupMembers: groups.flatMap(\.members))
    }

    private func indexedConversationRows(_ rows: [Conversation]) -> [String: Conversation] {
        let lookup = makeConversationUserLookup()
        var result: [String: Conversation] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let channelID = remoteChannelID(for: row, lookup: lookup)
            if result[channelID] == nil { result[channelID] = row }
        }
        return result
    }

    private func performPagedConversationSnapshot(
        context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession,
        command: RemoteConversationSyncCommand, performanceStart: CFAbsoluteTime
    ) async throws -> Bool {
        func currentRows() -> [String: Conversation] {
            indexedConversationRows(conversationStore.conversations)
        }
        var authority = ConversationPageAuthority(context: context)
        func validate() throws {
            let currentRefresh = isCurrentRemoteRefresh(refreshSession, scope: scope)
            guard currentRefresh else {
                SyncFailureDiagnostic.persistPrimaryOutcome(.obsolete)
                throw CancellationError()
            }
            do {
                try authority.validate(current: apiContext)
            } catch {
                if error is CancellationError, !Task.isCancelled {
                    SyncFailureDiagnostic.persistPrimaryOutcome(.authorityChanged)
                } else if let failure = error as? ConversationPageFailure,
                          failure.code == "conversation_page_credentials_advanced" {
                    SyncFailureDiagnostic.persistPrimaryOutcome(.credentialsAdvanced)
                }
                throw error
            }
        }
        var presentation = ConversationSnapshotPresentation(current: currentRows())
        var applyingPage = false
        // Observe mutations as they happen, including a toggle/read/delete that
        // changes back before the next page arrives (value comparison alone loses it).
        let changes = conversationStore.$conversations.sink { rows in
            guard !applyingPage else { return }
            presentation.observe(current: self.indexedConversationRows(rows))
        }
        defer { changes.cancel() }
        var firstPage = true
        var prefetchRemotes: [RemoteConversation] = []
        isLoadingMoreConversations = true
        isConversationSnapshotPartial = true
        defer {
            if isCurrentRemoteRefresh(refreshSession, scope: scope) {
                isLoadingMoreConversations = false
            }
        }
        let version = try await ConversationPageLoader.load(
            request: { cursor in
                let diagnostic = SyncFailureDiagnostic.HTTPObservation(.conversationPage)
                return try await SyncFailureDiagnostic.$httpObservation.withValue(diagnostic) {
                    defer { diagnostic.finish() }
                    return try await diagnostic.perform {
                        try await self.api.conversationPage(context: authority.context, cursor: cursor)
                    }
                }
            },
            validate: validate,
            onPage: { page in
                applyingPage = true
                defer { applyingPage = false }
                let current = currentRows()
                let accepted = self.canonicalRemoteConversations(page.conversations).filter { remote in
                    let key = self.normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType)
                    let unchanged = presentation.accept(key, current: current)
                    // A page may contain an older server summary than an already
                    // received local message, even before this refresh began.
                    return unchanged && (current[key]?.lastMsgSeq ?? 0) <= self.remoteConversationLatestSeq(remote)
                }
                self.applyRemoteConversations(accepted, replacing: false)
                presentation.didApply(accepted.map {
                    self.normalizedRemoteChannelID($0.channelID, channelType: $0.channelType)
                }, current: currentRows())
                self.isInitialDataLoading = false
                if firstPage {
                    firstPage = false
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)
                    print("[JHT Perf] conversation_first_page_ready_ms=\(elapsed) count=\(page.conversations.count)")
                    prefetchRemotes = page.conversations
                }
            },
            onRestart: {
                applyingPage = true
                defer { applyingPage = false }
                // Retire this attempt's unchanged presentation before accepting
                // a new snapshot. Concurrent local/realtime changes survive.
                // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改开始：分页快照重启时仅在会话数组变化后发布
                self.conversationStore.replaceConversationsIfChanged(
                    Array(presentation.restarting(current: currentRows()).values)
                        .sorted(by: self.conversationStore.conversationListPrecedes),
                    reason: "paged_snapshot_restart"
                )
                // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改结束
                firstPage = true
                prefetchRemotes = []
            }
        )
        try validate()
        changes.cancel()
        // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改开始：分页快照完成时避免发布完全相同的会话数组
        conversationStore.replaceConversationsIfChanged(
            Array(presentation.completing(current: currentRows()).values)
                .sorted(by: conversationStore.conversationListPrecedes),
            reason: "paged_snapshot_complete"
        )
        // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改结束
        remoteSyncEngine.finishRemoteConversationSync(command, responseVersion: version)
        hasLoadedRemoteSnapshot = true
        isConversationSnapshotPartial = false
        lastRemoteSnapshotPrimarySyncedAt = Date()
        syncFailureMessage = nil
        startConversationHistoryPrefetch(
            prefetchRemotes, context: authority.context, scope: scope,
            refreshSession: refreshSession, performanceStart: performanceStart
        )
        schedulePersistedMessageSequenceRecoveries(reason: "remote_snapshot")
        scheduleRemoteSnapshotCacheWrite(scope: scope, source: .conversationSync, replaceMissingConversations: true)
        return true
    }

    private func handlePrimaryConversationSyncFailure(_ error: Error, silent: Bool) {
        recordSyncFailureDiagnostic(error, endpoint: isConversationSnapshotPartial ? .conversationPage : .conversationSync)
        applySyncFailure(error, silent: silent)
        // A data-plane 401 only proves that this access token was rejected. The
        // refresh endpoint remains the authority for terminal session state.
        // `refreshStoredAuthSessionIfNeeded` has already handled an authoritative
        // expired/revoked/reused response before this fallback is reached.
        if !isUnauthorizedError(error), workspaceAccessCode(from: error) != nil {
            handleRemoteError(error, fallback: "聊天记录同步失败", silent: silent)
        }
    }

    private func logConversationSyncSummary(data: RemoteConversationSyncData, requestedVersion: Int64, generation: Int, authRefreshed: Bool = false) {
        let topConversation = conversations.first
        let topID: String
        if let topConversation {
            let channelID = remoteChannelID(for: topConversation)
            if topConversation.kind == .direct {
                let sum = channelID.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
                topID = "direct#\(abs(sum % 100_000))"
            } else {
                topID = channelID
            }
        } else {
            topID = "none"
        }
        let topTitle = topConversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latestAt = Int(topConversation?.sortTimestamp ?? 0)
        let latestSeq = topConversation?.lastMsgSeq ?? 0
        print("[JHT Perf] conversations_sync requestedVersion=\(requestedVersion) responseVersion=\(data.version) remoteCount=\(data.conversations.count) localCount=\(conversations.count) topConversation=\(topID) topTitle=\(topTitle) latestSeq=\(latestSeq) latestAt=\(latestAt) authRefreshed=\(authRefreshed) generation=\(generation)")
    }

    func refreshStoredAuthSessionIfNeeded(reason: String, silent: Bool, context explicitContext: IMAPIContext? = nil, scope explicitScope: String? = nil) async -> Bool {
        let context = explicitContext ?? apiContext
        let scope = explicitScope ?? (context.hasIMSession ? remoteDataScopeKey(for: context) : "")
        let refreshFence = context.authSessionFence
        func resultIsCurrent(_ result: Bool) -> Bool {
            guard result else { return false }
            if context.hasIMSession, !isCurrentRemoteScope(scope) {
                return false
            }
            return apiContext.isSameAuthAuthority(as: refreshFence)
                || apiContext.credentialsAdvanced(since: refreshFence)
        }
        if context.hasIMSession, !isCurrentRemoteScope(scope) {
            return false
        }
        if apiContext.credentialsAdvanced(since: refreshFence) {
            // This 401 belongs to the access token that another caller already
            // replaced. The caller should replay with apiContext; rotating the
            // captured refresh token again would create a false reuse event.
            return true
        }
        guard apiContext.isSameAuthAuthority(as: refreshFence) else {
            return false
        }
        guard context.hasRefreshSession else { return false }
        if let existing = remoteSyncEngine.currentAuthSessionRefreshTask(for: refreshFence) {
            return resultIsCurrent(await existing.value)
        }
        guard let taskToken = remoteSyncEngine.claimAuthSessionRefreshTask(for: refreshFence) else {
            if let existing = remoteSyncEngine.currentAuthSessionRefreshTask(for: refreshFence) {
                return resultIsCurrent(await existing.value)
            }
            return false
        }
        let task = Task<Bool, Never> { [weak self, context, scope] in
            guard let self else { return false }
            var requestContext = context
            if let pending = self.apiContext.pendingRefreshRequestID,
               !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requestContext.pendingRefreshRequestID = pending
            } else {
                var stagedContext = self.apiContext
                stagedContext.pendingRefreshRequestID = UUID().uuidString.lowercased()
                guard stagedContext.save(sessionStore: self.protectedSessionStore).isCommitted,
                      self.apiContext.isSameAuthAuthority(as: refreshFence) else {
                    return false
                }
                self.apiContext = stagedContext
                requestContext.pendingRefreshRequestID = stagedContext.pendingRefreshRequestID
            }
            do {
                guard requestContext.hasRefreshSession else { return false }
                if requestContext.hasIMSession {
                    guard self.isCurrentRemoteScope(scope) else { return false }
                }
                guard self.apiContext.isSameAuthAuthority(as: refreshFence) else { return false }
                let refreshed = try await self.api.refreshCurrentSession(context: requestContext)
                #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                if reason == "foreground" {
                    GroupForegroundSessionClearDiagnostics.recordPrimaryOutcome(
                        error: nil,
                        scopeCurrent: !context.hasIMSession || self.isCurrentRemoteScope(scope)
                    )
                }
                #endif
                guard refreshed.authSession.isUsable else { return false }
                if context.hasIMSession {
                    guard self.isCurrentRemoteScope(scope) else { return false }
                }
                guard self.applyAuthSessionRefreshResult(refreshed, expectedFence: refreshFence) else { return false }
                let refreshedScope = self.remoteDataScopeKey(for: self.apiContext)
                if let ticket = self.localMessageTicket,
                   self.isCurrentRemoteScope(refreshedScope) {
                    await self.recoverDurableOutbox(ticket: ticket, scope: refreshedScope)
                }
                if !silent {
                    self.toast = "登录状态已恢复"
                }
                print("[JHT Auth] session_refresh_success reason=\(reason) token_type=\(refreshed.authSession.normalizedTokenType) tenant_present=\(!refreshed.authSession.tenantID.isEmpty)")
                return true
            } catch {
                if context.hasIMSession, !self.isCurrentRemoteScope(scope) {
                    return false
                }
                guard self.apiContext.isSameAuthAuthority(as: refreshFence) else { return false }
                let primaryFailure = self.safeAuthRefreshFailureLogClassification(error)
                let refreshRoute: String
                if let tenantSession = context.tenantAuthSession, tenantSession.isUsable {
                    refreshRoute = tenantSession.usesTenantLocalRefreshEndpoint ? "tenant_local" : "platform_tenant"
                } else if context.platformAuthSession?.isUsable == true {
                    refreshRoute = "platform_account"
                } else {
                    refreshRoute = "none"
                }
                #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                if reason == "foreground" {
                    GroupForegroundSessionClearDiagnostics.recordPrimaryOutcome(
                        error: error,
                        scopeCurrent: !context.hasIMSession || self.isCurrentRemoteScope(scope)
                    )
                }
                #endif
                let shouldAttemptTenantFallback = self.shouldAttemptTenantIMSessionFallback(
                    after: error,
                    context: context
                )
                print("[JHT Auth] session_refresh_failure reason=\(reason) endpoint=\(refreshRoute) status=\(primaryFailure.status) code=\(primaryFailure.code) tenant_fallback=\(shouldAttemptTenantFallback)")
                if shouldAttemptTenantFallback {
                    do {
                        let refreshed = try await self.api.refreshTenantIMSession(context: requestContext, expiresInSeconds: nil)
                        #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                        if reason == "foreground" {
                            GroupForegroundSessionClearDiagnostics.recordTenantIMFallback(
                                attempted: true,
                                error: nil,
                                scopeCurrent: self.isCurrentRemoteScope(scope)
                            )
                        }
                        #endif
                        if context.hasIMSession {
                            guard self.isCurrentRemoteScope(scope) else { return false }
                        }
                        try self.applyTenantIMSessionRefreshResult(
                            refreshed,
                            fallbackContext: context,
                            expectedFence: refreshFence
                        )
                        let refreshedScope = self.remoteDataScopeKey(for: self.apiContext)
                        if let ticket = self.localMessageTicket,
                           self.isCurrentRemoteScope(refreshedScope) {
                            await self.recoverDurableOutbox(ticket: ticket, scope: refreshedScope)
                        }
                        if !silent {
                            self.toast = "登录状态已恢复"
                        }
                        print("[JHT DR] tenant_im_session_refresh_success reason=\(reason) endpoint=tenant_im status=2xx code=success tenant_present=\(!(self.apiContext.tenantID ?? "").isEmpty) app_id=\(self.apiContext.appID)")
                        return true
                    } catch is CancellationError {
                        return false
                    } catch {
                        let tenantFailure = self.safeAuthRefreshFailureLogClassification(error)
                        print("[JHT DR] tenant_im_session_refresh_failure reason=\(reason) endpoint=tenant_im status=\(tenantFailure.status) code=\(tenantFailure.code)")
                        #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
                        if reason == "foreground" {
                            GroupForegroundSessionClearDiagnostics.recordTenantIMFallback(
                                attempted: true,
                                error: error,
                                scopeCurrent: !context.hasIMSession || self.isCurrentRemoteScope(scope)
                            )
                        }
                        #endif
                        await self.handleAuthSessionRefreshFailure(error, silent: silent)
                        return false
                    }
                }
                await self.handleAuthSessionRefreshFailure(error, silent: silent)
                return false
            }
        }
        remoteSyncEngine.attachAuthSessionRefreshTask(taskToken, task: task)
        let result = await task.value
        remoteSyncEngine.finishAuthSessionRefreshTask(taskToken)
        return resultIsCurrent(result)
    }

    // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: keep platform session refresh independent from tenant IM refresh.
    func refreshPlatformAuthSessionIfNeeded(
        reason: String,
        silent: Bool,
        context explicitContext: IMAPIContext? = nil,
        force: Bool = false
    ) async -> Bool {
        let context = explicitContext ?? apiContext
        guard let platformSession = context.platformAuthSession,
              platformSession.isUsable,
              context.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        if !force {
            guard let refreshDelay = IMAuthSessionPreemptiveRefreshPolicy.delayUntilRefresh(
                accessExpiresAt: platformSession.accessExpiresAt,
                now: Date().timeIntervalSince1970
            ) else {
                return true
            }
            guard refreshDelay <= 0 else { return true }
        }
        if platformAuthSessionDidAdvance(since: platformSession, platformToken: context.platformToken) {
            return true
        }
        guard let refreshContext = platformRefreshContext(from: context) else { return false }
        let refreshFence = refreshContext.authSessionFence
        if platformAuthSessionDidAdvance(since: platformSession, platformToken: context.platformToken) {
            return true
        }
        if let existing = remoteSyncEngine.currentAuthSessionRefreshTask(for: refreshFence) {
            let result = await existing.value
            return result && platformAuthSessionDidAdvance(since: platformSession, platformToken: context.platformToken)
        }
        guard let taskToken = remoteSyncEngine.claimAuthSessionRefreshTask(for: refreshFence) else {
            if let existing = remoteSyncEngine.currentAuthSessionRefreshTask(for: refreshFence) {
                let result = await existing.value
                return result && platformAuthSessionDidAdvance(since: platformSession, platformToken: context.platformToken)
            }
            return false
        }
        let task = Task<Bool, Never> { [weak self, refreshContext, refreshFence, platformSession, reason] in
            guard let self else { return false }
            var requestContext = refreshContext
            if let pending = self.apiContext.pendingRefreshRequestID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pending.isEmpty {
                requestContext.pendingRefreshRequestID = pending
            } else {
                var stagedContext = self.apiContext
                stagedContext.pendingRefreshRequestID = UUID().uuidString.lowercased()
                guard stagedContext.save(sessionStore: self.protectedSessionStore).isCommitted,
                      self.currentPlatformRefreshFence() == refreshFence else {
                    return false
                }
                self.apiContext = stagedContext
                requestContext.pendingRefreshRequestID = stagedContext.pendingRefreshRequestID
            }
            do {
                guard self.currentPlatformRefreshFence() == refreshFence else { return false }
                let refreshed = try await self.api.refreshCurrentSession(context: requestContext)
                guard self.applyPlatformAuthSessionRefreshResult(
                    refreshed,
                    expectedFence: refreshFence,
                    previousPlatformSession: platformSession
                ) else { return false }
                if !silent {
                    self.toast = "登录状态已恢复"
                }
                print("[JHT Auth] platform_session_refresh_success reason=\(reason) token_type=\(refreshed.authSession.normalizedTokenType)")
                return true
            } catch {
                guard self.currentPlatformRefreshFence() == refreshFence else { return false }
                let failure = self.safeAuthRefreshFailureLogClassification(error)
                print("[JHT Auth] platform_session_refresh_failure reason=\(reason) status=\(failure.status) code=\(failure.code)")
                return false
            }
        }
        remoteSyncEngine.attachAuthSessionRefreshTask(taskToken, task: task)
        let result = await task.value
        remoteSyncEngine.finishAuthSessionRefreshTask(taskToken)
        return result && platformAuthSessionDidAdvance(since: platformSession, platformToken: context.platformToken)
    }

    private func platformRefreshContext(from context: IMAPIContext) -> IMAPIContext? {
        guard context.platformAuthSession?.isUsable == true else { return nil }
        var platformContext = context
        platformContext.tenantAuthSession = nil
        platformContext.accessExpiresAt = context.platformAuthSession?.accessExpiresAt ?? 0
        return platformContext
    }

    private func currentPlatformRefreshFence() -> IMAuthSessionFence? {
        platformRefreshContext(from: apiContext)?.authSessionFence
    }

    private func platformAuthSessionDidAdvance(
        since previous: IMStoredAuthSession,
        platformToken previousToken: String?
    ) -> Bool {
        guard let current = apiContext.platformAuthSession,
              current.isUsable,
              current.normalizedTokenType == "platform" else {
            return false
        }
        if current.sessionID != previous.sessionID { return true }
        if current.authVersion > previous.authVersion { return true }
        if current.sessionGeneration > previous.sessionGeneration { return true }
        if current.accessExpiresAt > previous.accessExpiresAt { return true }
        let oldToken = previousToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !newToken.isEmpty && !oldToken.isEmpty && newToken != oldToken
    }

    private func applyPlatformAuthSessionRefreshResult(
        _ result: RemoteAuthSessionRefreshResult,
        expectedFence: IMAuthSessionFence,
        previousPlatformSession: IMStoredAuthSession
    ) -> Bool {
        guard result.authSession.isUsable else { return false }
        let normalizedType = result.authSession.normalizedTokenType
        guard normalizedType.isEmpty || normalizedType == "platform" else { return false }
        guard currentPlatformRefreshFence() == expectedFence,
              let currentPlatformSession = apiContext.platformAuthSession,
              currentPlatformSession.sessionID == previousPlatformSession.sessionID else {
            return false
        }
        if result.authVersion > 0,
           currentPlatformSession.authVersion > 0,
           result.authVersion < currentPlatformSession.authVersion {
            return false
        }
        if result.sessionGeneration > 0,
           currentPlatformSession.sessionGeneration > 0,
           result.sessionGeneration < currentPlatformSession.sessionGeneration {
            return false
        }
        var candidate = apiContext
        let previousAccessExpiresAt = candidate.accessExpiresAt
        let tenantAccessExpiresAt = candidate.tenantAuthSession?.accessExpiresAt ?? 0
        let refreshedPlatformToken = result.platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? result.platformToken.trimmingCharacters(in: .whitespacesAndNewlines)
            : result.imToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !refreshedPlatformToken.isEmpty {
            candidate.platformToken = refreshedPlatformToken
        }
        if !result.authSession.appID.isEmpty {
            candidate.appID = IMAPIContext.normalizedIOSAppID(result.authSession.appID)
        }
        if !result.authSession.deviceID.isEmpty {
            candidate.deviceID = result.authSession.deviceID
        }
        candidate.persistAuthSession(
            result.authSession,
            fallbackTokenType: "platform",
            fallbackTenantID: nil,
            fallbackAccessExpiresAt: result.expiresAt
        )
        if candidate.hasIMSession {
            candidate.accessExpiresAt = tenantAccessExpiresAt > 0 ? tenantAccessExpiresAt : previousAccessExpiresAt
        } else if result.expiresAt > 0 {
            candidate.accessExpiresAt = result.expiresAt
        }
        candidate.pendingRefreshRequestID = nil
        guard candidate.save(sessionStore: protectedSessionStore).isCommitted,
              currentPlatformRefreshFence() == expectedFence else {
            return false
        }
        apiContext = candidate
        if !result.workspaces.isEmpty {
            applyWorkspaces(result.workspaces)
        }
        return true
    }
    // WDT_IOS_TOKEN_VALIDITY_20260924_END

    private func shouldAttemptTenantIMSessionFallback(after error: Error, context: IMAPIContext) -> Bool {
        guard context.hasIMSession else { return false }
        if DisasterRecoveryFallbackClassifier.shouldFallbackFromPlatformFailure(error) {
            return true
        }
        guard let tenantSession = context.tenantAuthSession,
              tenantSession.isUsable,
              !tenantSession.usesTenantLocalRefreshEndpoint else {
            return false
        }
        let code = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
        return code == "invalid_token" || code == "expired_token"
    }

    private func safeAuthRefreshFailureLogClassification(_ error: Error) -> (status: String, code: String) {
        let normalizedCode = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
        let allowedCodes: Set<String> = [
            "invalid_token", "expired_token", "session_expired", "refresh_token_expired",
            "session_revoked", "refresh_token_reused", "reauth_required", "device_not_found",
            "device_disabled", "device_app_mismatch", "account_locked", "account_disabled",
            "tenant_member_disabled", "tenant_member_not_found", "tenant_service_stopped",
            "security_blocked", "rate_limited", "audit_write_failed", "token_sign_failed"
        ]
        let safeCode = allowedCodes.contains(normalizedCode) ? normalizedCode : "other"
        if let refreshError = error as? IMSessionRefreshRejectionError {
            return (String(refreshError.statusCode), safeCode)
        }
        if error is URLError {
            return ("transport", safeCode)
        }
        guard let apiError = error as? IMAPIError else {
            return ("none", safeCode)
        }
        switch apiError {
        case .unauthorized:
            return ("401", safeCode)
        case .forbidden, .businessForbidden, .forcedAuthRequired, .securityBlocked, .loginSecurity:
            return ("403", safeCode)
        case .rateLimited:
            return ("429", safeCode)
        case .httpStatus(let status, _):
            return (String(status), safeCode)
        case .server:
            return ("5xx_or_decode", safeCode)
        case .missingContext, .badURL, .conflict, .emptyResponse:
            return ("none", safeCode)
        }
    }

    private func applyAuthSessionRefreshResult(
        _ result: RemoteAuthSessionRefreshResult,
        expectedFence: IMAuthSessionFence
    ) -> Bool {
        guard apiContext.accepts(
            authVersion: result.authVersion,
            sessionGeneration: result.sessionGeneration,
            for: expectedFence
        ) else { return false }
        let previousRealtimeToken = apiContext.imToken
        var candidate = apiContext
        let normalizedType = result.authSession.normalizedTokenType
        // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: backend may omit token_type; preserve the refresh authority selected by the request fence.
        let effectiveAuthSessionType: String
        if !normalizedType.isEmpty {
            effectiveAuthSessionType = normalizedType
        } else {
            switch expectedFence.authorityFamily {
            case .platform:
                effectiveAuthSessionType = "platform"
            case .tenant:
                effectiveAuthSessionType = "im"
            case .none:
                effectiveAuthSessionType = ""
            }
        }
        // WDT_IOS_TOKEN_VALIDITY_20260924_END
        // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: generic token can stand for platform bearer only on platform refresh.
        let refreshedPlatformToken = result.platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? result.platformToken.trimmingCharacters(in: .whitespacesAndNewlines)
            : (effectiveAuthSessionType == "platform" ? result.imToken.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        if !refreshedPlatformToken.isEmpty {
            candidate.platformToken = refreshedPlatformToken
        }
        // WDT_IOS_TOKEN_VALIDITY_20260924_END
        if effectiveAuthSessionType != "platform",
           !result.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidate.imToken = result.imToken
            if let tenant = result.tenant {
                candidate.tenantID = tenant.id
            } else if !result.authSession.tenantID.isEmpty {
                candidate.tenantID = result.authSession.tenantID
            }
            if let member = result.member, !member.imUID.isEmpty {
                candidate.imUID = member.imUID
            }
        }
        if !result.authSession.appID.isEmpty {
            candidate.appID = IMAPIContext.normalizedIOSAppID(result.authSession.appID)
        }
        if !result.authSession.deviceID.isEmpty {
            candidate.deviceID = result.authSession.deviceID
        }
        candidate.persistAuthSession(
            result.authSession,
            fallbackTokenType: effectiveAuthSessionType.isEmpty ? nil : effectiveAuthSessionType,
            fallbackTenantID: candidate.tenantID,
            // JHT_MOD_BEGIN AUTH_REFRESH_EXPIRES_AT_PERSISTENCE
            fallbackAccessExpiresAt: result.expiresAt
            // JHT_MOD_END AUTH_REFRESH_EXPIRES_AT_PERSISTENCE
        )
        if result.expiresAt > 0 {
            candidate.accessExpiresAt = result.expiresAt
        }
        candidate.pendingRefreshRequestID = nil
        guard candidate.save(sessionStore: protectedSessionStore).isCommitted,
              apiContext.isSameAuthAuthority(as: expectedFence) else { return false }
        apiContext = candidate
        if let tenant = result.tenant, let member = result.member {
            currentEnterprise = enterprise(from: RemoteTenantMembership(tenant: tenant, member: member), fallbackAccent: currentEnterprise.accentHex)
        }
        if !result.workspaces.isEmpty {
            applyWorkspaces(result.workspaces)
        }
        rebindRealtimeAfterTokenRefreshIfNeeded(previousToken: previousRealtimeToken)
        return true
    }

    private func applyTenantIMSessionRefreshResult(
        _ result: RemoteTenantIMSessionRefreshResult,
        fallbackContext: IMAPIContext,
        expectedFence: IMAuthSessionFence
    ) throws {
        guard apiContext.accepts(
            authVersion: result.authVersion,
            sessionGeneration: result.sessionGeneration,
            for: expectedFence
        ) else { throw CancellationError() }
        let previousRealtimeToken = apiContext.imToken
        let imToken = result.imToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imToken.isEmpty else {
            throw IMAPIError.server("tenant_im_session_refresh_empty_token")
        }
        let tenantID = result.tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fallbackContext.tenantID ?? "")
            : result.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let imUID = result.imUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fallbackContext.imUID ?? "")
            : result.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = result.appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackContext.appID
            : result.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = result.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackContext.deviceID
            : result.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !imUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.server("tenant_im_session_refresh_incomplete_identity")
        }

        var candidate = apiContext
        candidate.imToken = imToken
        candidate.tenantID = tenantID
        candidate.imUID = imUID
        candidate.appID = IMAPIContext.normalizedIOSAppID(appID)
        candidate.deviceID = deviceID
        candidate.advanceAccessCredential(
            authVersion: result.authVersion,
            sessionGeneration: result.sessionGeneration,
            accessExpiresAt: result.expiresAt
        )
        IMTenantIMTokenExpiryStore.save(result.expiresAt)
        guard candidate.save(sessionStore: protectedSessionStore).isCommitted,
              apiContext.isSameAuthAuthority(as: expectedFence) else {
            throw IMAPIError.server("protected_session_persistence_failed")
        }
        apiContext = candidate
        rebindRealtimeAfterTokenRefreshIfNeeded(previousToken: previousRealtimeToken)
    }

    private func rebindRealtimeAfterTokenRefreshIfNeeded(previousToken: String?) {
        let previous = previousToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let current = apiContext.imToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !current.isEmpty,
              current != previous,
              iosRiskTelemetrySceneIsActive,
              isAuthenticated,
              apiContext.hasIMSession else {
            return
        }
        startRealtimeConnection(context: apiContext)
    }

    // JHT_MOD_BEGIN AUTH_REFRESH_EXPIRED_AUTO_LOGIN
    private func authoritativeRefreshSessionExpiryCode(from error: Error) -> String? {
        guard let refreshError = error as? IMSessionRefreshRejectionError else { return nil }
        guard refreshError.statusCode == 401 else { return nil }
        let code = refreshError.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["refresh_token_expired", "session_expired"].contains(code) ? code : nil
    }

    private func tenantCodeForRememberedRefreshRecovery(context: IMAPIContext) -> String {
        let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = [
            currentEnterprise.id == tenantID ? currentEnterprise.code : "",
            enterprises.first { $0.id == tenantID }?.code ?? "",
            currentEnterprise.code
        ]
        return candidates
            .map { normalizedRegistrationTenantCode($0) }
            .first { !$0.isEmpty } ?? ""
    }

    private func loginWithRememberedCredentialsForRefreshRecovery(
        _ credentials: RememberedLoginCredentials,
        context: IMAPIContext
    ) async throws -> RemoteTenantLoginData {
        let tenantCode = tenantCodeForRememberedRefreshRecovery(context: context)
        do {
            return try await api.loginIMUser(
                username: credentials.identifier,
                password: credentials.password,
                slideToken: nil,
                tenantCode: tenantCode,
                enterpriseContextToken: "",
                context: context
            )
        } catch {
            guard isNeutralLoginEndpointUnavailable(error) else { throw error }
            return try await api.loginTenantUser(
                username: credentials.identifier,
                password: credentials.password,
                slideToken: nil,
                context: context
            )
        }
    }

    private func rememberedRefreshRecoveryLoginData(
        _ data: RemoteTenantLoginData,
        matches context: IMAPIContext
    ) -> Bool {
        let expectedAccountID = context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expectedAccountID.isEmpty {
            let accountIDs = [
                data.accountID,
                data.account?.id ?? "",
                data.user?.accountID ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !accountIDs.isEmpty,
                  accountIDs.allSatisfy({ $0 == expectedAccountID }) else {
                return false
            }
        }

        if let session = data.session,
           !session.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let identity = session.effectiveIdentity(tenantID: data.tenant?.tenantID ?? "") else {
                return false
            }
            guard IMAPIContext.normalizedIOSAppID(identity.appID) == IMAPIContext.normalizedIOSAppID(context.appID),
                  identity.deviceID == context.deviceID else {
                return false
            }
            let expectedTenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !expectedTenantID.isEmpty, identity.tenantID != expectedTenantID {
                return false
            }
            let expectedIMUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !expectedIMUID.isEmpty {
                let imUIDs = [
                    session.imUID,
                    data.user?.imUID ?? ""
                ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !imUIDs.isEmpty,
                      imUIDs.allSatisfy({ $0 == expectedIMUID }) else {
                    return false
                }
            }
        }

        return true
    }

    @discardableResult
    private func attemptRememberedLoginAfterRefreshSessionExpiry(
        reason: String,
        code: String,
        silent: Bool
    ) async -> Bool {
        guard !isAuthLoading else {
            print("[JHT Auth] refresh_expired_auto_login_skip reason=\(reason) code=\(code) cause=auth_busy")
            return false
        }
        guard let credentials = rememberedLoginCredentialsForAuthUI() else {
            print("[JHT Auth] refresh_expired_auto_login_skip reason=\(reason) code=\(code) cause=no_remembered_credentials")
            return false
        }
        let originalContext = apiContext
        let originalFence = originalContext.authSessionFence
        let generation = authFlowGeneration.issueToken()
        workspaceSwitchGeneration.invalidate()
        isAuthLoading = true
        defer {
            if authFlowGeneration.isCurrent(generation) {
                isAuthLoading = false
            }
        }
        print("[JHT Auth] refresh_expired_auto_login_start reason=\(reason) code=\(code) mode=\(credentials.mode.storageValue)")
        do {
            let data = try await loginWithRememberedCredentialsForRefreshRecovery(
                credentials,
                context: originalContext
            )
            guard authFlowGeneration.isCurrent(generation) else { return false }
            guard rememberedRefreshRecoveryLoginData(data, matches: originalContext) else {
                throw IMAPIError.forbidden("remembered_login_identity_mismatch")
            }
            guard apiContext.isSameAuthAuthority(as: originalFence) else {
                return apiContext.credentialsAdvanced(since: originalFence)
            }
            await completeTenantLogin(
                data,
                syncedMessage: "登录状态已恢复并同步企业数据",
                fallbackMessage: "登录状态已恢复，聊天数据正在同步",
                allowDefaultAutoEnter: true,
                loginIdentifierFallback: credentials.identifier,
                loginGeneration: generation
            )
            let recovered = apiContext.hasRefreshSession && (isAuthenticated || authScreen == .workspaceSelection)
            print("[JHT Auth] refresh_expired_auto_login_result reason=\(reason) code=\(code) recovered=\(recovered) im_session=\(apiContext.hasIMSession)")
            if recovered, !silent, apiContext.hasIMSession {
                toast = "登录状态已恢复"
            }
            return recovered
        } catch {
            guard authFlowGeneration.isCurrent(generation) else { return false }
            let failure = safeAuthRefreshFailureLogClassification(error)
            print("[JHT Auth] refresh_expired_auto_login_failure reason=\(reason) code=\(code) status=\(failure.status) failure_code=\(failure.code)")
            return false
        }
    }
    // JHT_MOD_END AUTH_REFRESH_EXPIRED_AUTO_LOGIN

    private func handleAuthSessionRefreshFailure(_ error: Error, silent: Bool) async {
        let message = userFacingError(error)
        let termination = refreshSessionTerminationDisposition(error)
        // JHT_MOD_BEGIN AUTH_REFRESH_EXPIRED_AUTO_LOGIN
        let expiredRefreshCode = authoritativeRefreshSessionExpiryCode(from: error)
        let refreshFailureCode = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
        let unauthoritativeExpiryCode = expiredRefreshCode == nil
            && ["refresh_token_expired", "session_expired"].contains(refreshFailureCode)
        if let expiredRefreshCode,
           await attemptRememberedLoginAfterRefreshSessionExpiry(
            reason: "refresh_session_expired",
            code: expiredRefreshCode,
            silent: silent
           ) {
            return
        }
        // JHT_MOD_END AUTH_REFRESH_EXPIRED_AUTO_LOGIN
        if termination == .tenantLocal,
           expiredRefreshCode == nil,
           !unauthoritativeExpiryCode {
            let revokedContext = apiContext
            retirePushDevices(for: revokedContext)
            removeRemoteSnapshotCache(for: revokedContext)
            clearTenantScopedSearchState(reason: "tenant_session_revoked")
            forceWorkspaceSelectionForCurrentAccessBlock(
                DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
            )
            if !silent { toast = message }
            return
        }
        if (termination == .global && !unauthoritativeExpiryCode)
            || expiredRefreshCode != nil {
            #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
            let diagnosticScopeCurrent = !apiContext.hasIMSession
                || isCurrentRemoteScope(remoteDataScopeKey(for: apiContext))
            #endif
            stopInboxRefreshLoop()
            coldLaunchSessionRecoveryTask?.cancel()
            coldLaunchSessionRecoveryTask = nil
            disconnectRealtime(shouldReconnect: false)
            isAuthenticated = false
            activeTab = .chats
            authScreen = .accountLogin
            disableAccessDiagnosticsOverlay()
            apiContext.clearSession(sessionStore: protectedSessionStore)
            #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
            GroupForegroundSessionClearDiagnostics.recordClear(
                origin: .authRefreshTerminal,
                scopeCurrent: diagnosticScopeCurrent,
                postAuthenticated: isAuthenticated,
                postHasRefreshSession: apiContext.hasRefreshSession,
                postHasIMSession: apiContext.hasIMSession
            )
            #endif
            resetAuthenticatedRemoteData(showLoading: false)
            if !silent {
                toast = message
            }
            return
        }
        if !silent {
            showRemoteErrorToast("登录状态续期失败：\(message)")
        }
    }

    private func registerDeviceSilently(context: IMAPIContext, scope: String) async {
        guard context.hasIMSession else { return }
        _ = try? await api.registerDevice(context: context)
        guard isCurrentRemoteScope(scope) else { return }
        registerPendingStandardPushDeviceIfPossible(reason: "device_refresh")
        registerPendingVoIPDeviceIfPossible(reason: "device_refresh")
    }

    private func refreshSecondarySnapshotInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) {
        let generation = refreshSession.generation
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        remoteSyncEngine.cancelSecondarySnapshotTasks()
        let commands = remoteSyncEngine.secondarySnapshotCommands(
            groupsDelayNs: mainShellGroupsSnapshotDelayNs,
            contactsDelayNs: mainShellContactsSnapshotDelayNs,
            profileDeviceDelayNs: mainShellSecondarySnapshotDelayNs
        )
        for command in commands {
            switch command.operation {
            case .groups:
                enqueueSecondarySnapshotTask(
                    name: command.name,
                    snapshotOperation: command.operation,
                    delayNs: command.delayNs,
                    context: context,
                    scope: scope,
                    refreshSession: refreshSession
                ) { [weak self] in
                    guard let self else { return }
                    await self.refreshGroupsInBackground(context: context, scope: scope, refreshSession: refreshSession)
                }
            case .contacts:
                enqueueSecondarySnapshotTask(
                    name: command.name,
                    snapshotOperation: command.operation,
                    delayNs: command.delayNs,
                    context: context,
                    scope: scope,
                    refreshSession: refreshSession
                ) { [weak self] in
                    guard let self else { return }
                    await self.refreshContactsAndNoticesInBackground(context: context, scope: scope, refreshSession: refreshSession)
                }
            case .profileDevice:
                enqueueSecondarySnapshotTask(
                    name: command.name,
                    snapshotOperation: command.operation,
                    delayNs: command.delayNs,
                    context: context,
                    scope: scope,
                    refreshSession: refreshSession
                ) { [weak self] in
                    guard let self else { return }
                    await self.refreshFileUploadConfigInBackground(context: context, scope: scope, refreshSession: refreshSession)
                    await self.refreshTenantProfileInBackground(context: context, scope: scope, refreshSession: refreshSession)
                    await self.registerDeviceSilently(context: context, scope: scope)
                }
            }
        }
        print("[JHT Perf] secondary_queue_scheduled count=\(commands.count) generation=\(generation)")
    }

    private func enqueueSecondarySnapshotTask(
        name: String,
        snapshotOperation: SecondarySnapshotOperation,
        delayNs: UInt64,
        context: IMAPIContext,
        scope: String,
        refreshSession: RemoteSnapshotRefreshSession,
        operation: @escaping @MainActor () async -> Void
    ) {
        let generation = refreshSession.generation
        let syncEngine = remoteSyncEngine
        guard syncEngine.claimSecondarySnapshotTask(snapshotOperation) else { return }
        let task = Task { [weak self, syncEngine] in
            defer {
                syncEngine.finishSecondarySnapshotTask(snapshotOperation)
            }
            guard let self else { return }
            do {
                if delayNs > 0 {
                    try await Task.sleep(nanoseconds: delayNs)
                }
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isCurrentRemoteRefresh(refreshSession, scope: scope),
                  context.hasIMSession else {
                print("[JHT Perf] secondary_queue_drop name=\(name) reason=stale generation=\(generation)")
                return
            }
            print("[JHT Perf] secondary_queue_running name=\(name) delay_ms=\(Int(Double(delayNs) / 1_000_000)) generation=\(generation)")
            await operation()
            print("[JHT Perf] secondary_queue_finished name=\(name) generation=\(generation)")
        }
        syncEngine.attachSecondarySnapshotTask(snapshotOperation, task: task)
    }

    private func refreshFileUploadConfigInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        _ = try? await fetchScopedFileUploadConfig(context: context, scope: scope)
    }

    func refreshTenantProfileInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        let generation = refreshSession.generation
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        markGroupMemberCountPolicyUnresolved(scope: scope)
        guard let devicePolicyAuthority = beginTenantDevicePolicyRequest(context: context) else { return }
        let profileAuthorityRequest = beginCurrentProfileRead(context: context)
        let api = self.api
        let profileDiagnostic = SyncFailureDiagnostic.HTTPObservation(.tenantProfile)
        let contextDiagnostic = SyncFailureDiagnostic.HTTPObservation(.tenantContext)
        let meDiagnostic = SyncFailureDiagnostic.HTTPObservation(.meProfile)
        let workspacesDiagnostic = SyncFailureDiagnostic.HTTPObservation(.workspaces)
        let profileTask = Task {
            try await SyncFailureDiagnostic.$httpObservation.withValue(profileDiagnostic) {
                defer { profileDiagnostic.finish() }
                return try await profileDiagnostic.perform { try await api.tenantProfile(context: context) }
            }
        }
        let tenantContextTask = Task {
            try await SyncFailureDiagnostic.$httpObservation.withValue(contextDiagnostic) {
                defer { contextDiagnostic.finish() }
                return try await contextDiagnostic.perform { try await api.tenantContext(context: context) }
            }
        }
        let meProfileTask = Task {
            try await SyncFailureDiagnostic.$httpObservation.withValue(meDiagnostic) {
                defer { meDiagnostic.finish() }
                return try await meDiagnostic.perform { try await api.meProfile(context: context) }
            }
        }
        let workspacesTask = Task {
            try await SyncFailureDiagnostic.$httpObservation.withValue(workspacesDiagnostic) {
                defer { workspacesDiagnostic.finish() }
                return try await workspacesDiagnostic.perform { try await api.listWorkspaces(context: context) }
            }
        }
        defer {
            profileTask.cancel()
            tenantContextTask.cancel()
            meProfileTask.cancel()
            workspacesTask.cancel()
        }

        do {
            let tenantContext = try await tenantContextTask.value
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            clearSyncFailureDiagnostics(for: .tenantContext)
            guard applyTenantContext(
                tenantContext,
                devicePolicyAuthority: devicePolicyAuthority,
                profileAuthorityRequest: profileAuthorityRequest
            ) else { return }
        } catch {
            recordSyncFailureDiagnostic(error, endpoint: .tenantContext, httpFailure: contextDiagnostic.failure)
            markGroupMemberCountPolicyUnresolved(scope: scope)
            markTenantDevicePolicyUnavailable(authority: devicePolicyAuthority)
            print("[JHT Perf] tenant_profile_soft_fail endpoint=tenant_context generation=\(generation)")
        }

        do {
            let workspaces = try await workspacesTask.value
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            clearSyncFailureDiagnostics(for: .workspaces)
            applyWorkspaces(workspaces)
        } catch {
            recordSyncFailureDiagnostic(error, endpoint: .workspaces, httpFailure: workspacesDiagnostic.failure)
            print("[JHT Perf] tenant_profile_soft_fail endpoint=workspaces generation=\(generation)")
        }

        do {
            let profile = try await profileTask.value
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            clearSyncFailureDiagnostics(for: .tenantProfile)
            applyTenantProfile(profile)
        } catch {
            recordSyncFailureDiagnostic(error, endpoint: .tenantProfile, httpFailure: profileDiagnostic.failure)
            print("[JHT Perf] tenant_profile_soft_fail endpoint=tenant_profile generation=\(generation)")
        }

        do {
            let meProfile = try await meProfileTask.value
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            clearSyncFailureDiagnostics(for: .meProfile)
            applyMeProfile(meProfile, authorityRequest: profileAuthorityRequest)
        } catch {
            recordSyncFailureDiagnostic(error, endpoint: .meProfile, httpFailure: meDiagnostic.failure)
            print("[JHT Perf] tenant_profile_soft_fail endpoint=me_profile generation=\(generation)")
        }
    }

    @discardableResult
    func refreshCurrentEnterpriseProfile(silent: Bool = true) async -> Bool {
        guard isAuthenticated, apiContext.hasIMSession else { return false }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return false }
        guard let devicePolicyAuthority = beginTenantDevicePolicyRequest(context: context) else { return false }
        let profileAuthorityRequest = beginCurrentProfileRead(context: context)
        var updated = false
        let api = self.api
        let workspacesTask = Task { try await api.listWorkspaces(context: context) }
        let tenantContextTask = Task { try await api.tenantContext(context: context) }
        let profileTask = Task { try await api.tenantProfile(context: context) }
        defer {
            workspacesTask.cancel()
            tenantContextTask.cancel()
            profileTask.cancel()
        }
        if let tenantContext = try? await tenantContextTask.value {
            guard isCurrentRemoteScope(scope) else { return false }
            guard applyTenantContext(
                tenantContext,
                devicePolicyAuthority: devicePolicyAuthority,
                profileAuthorityRequest: profileAuthorityRequest
            ) else { return false }
            updated = true
        } else {
            markTenantDevicePolicyUnavailable(authority: devicePolicyAuthority)
        }
        if let workspaces = try? await workspacesTask.value {
            guard isCurrentRemoteScope(scope) else { return false }
            applyWorkspaces(workspaces)
            updated = true
        }
        if let profile = try? await profileTask.value {
            guard isCurrentRemoteScope(scope) else { return false }
            applyTenantProfile(profile)
            updated = true
        }
        if !updated && !silent {
            toast = "企业资料刷新失败"
        }
        return updated
    }

    private func refreshGroupsInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        let directoryGeneration = groupDirectoryRefreshGeneration.issueToken()
        do {
            let remoteGroups = try await api.listGroups(context: context, scope: "all")
            guard !Task.isCancelled,
                  groupDirectoryRefreshGeneration.isCurrent(directoryGeneration),
                  isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyRemoteGroups(remoteGroups)
            refreshInitialGroupBundles(remoteGroups, scope: scope, refreshSession: refreshSession)
        } catch {
            guard !Task.isCancelled,
                  groupDirectoryRefreshGeneration.isCurrent(directoryGeneration),
                  isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            logSyncEndpointFailure("/api/tenant/groups?scope=all", error: error)
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "群聊数据同步失败",
                    silent: true
                )
            }
        }
    }

    @discardableResult
    func refreshGroupDirectory(silent: Bool = true) async -> Bool {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isAuthenticated, context.hasIMSession, isCurrentRemoteScope(scope) else { return false }
        let directoryGeneration = groupDirectoryRefreshGeneration.issueToken()
        do {
            let remoteGroups = try await api.listGroups(context: context, scope: "all")
            guard !Task.isCancelled,
                  groupDirectoryRefreshGeneration.isCurrent(directoryGeneration),
                  isAuthenticated,
                  isCurrentRemoteScope(scope) else { return false }
            applyRemoteGroups(remoteGroups)
            return true
        } catch {
            guard !Task.isCancelled,
                  groupDirectoryRefreshGeneration.isCurrent(directoryGeneration),
                  isAuthenticated,
                  isCurrentRemoteScope(scope) else { return false }
            logSyncEndpointFailure("/api/tenant/groups?scope=all", error: error)
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "群聊数据同步失败",
                    silent: true
                )
            } else if !silent {
                toast = "群列表刷新失败"
            }
            return false
        }
    }

    func refreshContactsAndNoticesInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        let generation = refreshSession.generation
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        profileContactRevisionFence.rebind(scopeHash: scope)
        guard contactStore.beginContactsSync() else {
            print("[JHT Perf] contacts_sync_skip reason=in_flight generation=\(generation)")
            return
        }
        defer { contactStore.finishContactsSync() }
        do {
            let requests = try await api.listFriendApplications(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyFriendApplications(requests)
        } catch {
            logSyncEndpointFailure("/api/tenant/friend-applications", error: error)
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "好友申请同步失败",
                    silent: true
                )
            }
        }
        do {
            let readStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
            let blocked = try await api.listBlacklist(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyBlacklist(blocked, readStamp: readStamp)
        } catch {
            logSyncEndpointFailure("/api/tenant/blacklist", error: error)
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "黑名单同步失败",
                    silent: true
                )
            }
        }
        do {
            let readStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
            let relations = try await api.listFriends(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyFriendRelations(relations, readStamp: readStamp)
            contactStore.setContactsSyncError(nil)
            print("[JHT Perf] contacts_sync_success count=\(relations.count) generation=\(generation)")
        } catch {
            logSyncEndpointFailure("/api/tenant/friends", error: error)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            contactStore.setContactsSyncError(contacts.isEmpty
                ? "通讯录同步失败，请稍后重试"
                : "通讯录同步失败，当前显示上次缓存")
            print("[JHT Perf] contacts_sync_fallback cached_count=\(contacts.count) generation=\(generation)")
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "通讯录同步失败",
                    silent: true
                )
            }
        }
        await refreshOrganizationDirectory(context: context, scope: scope, refreshSession: refreshSession)
        do {
            let devices = try await api.listDevices(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyDevices(devices)
        } catch {
            logSyncEndpointFailure("/api/tenant/devices", error: error)
        }
        do {
            let inbox = try await api.listInbox(context: context)
            let announcements = (try? await api.listAnnouncementInbox(context: context)) ?? []
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyInbox(Self.mergedInboxEntries(inbox, announcements))
        } catch {
            logSyncEndpointFailure("/api/tenant/inbox", error: error)
        }
    }

    func createOrganizationDepartment(parentDepartmentID: String, name: String) async -> Bool {
        guard canManageOrganizationDepartments else {
            toast = "当前账号无部门管理权限"
            return false
        }
        guard apiContext.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            toast = "请输入部门名称"
            return false
        }
        isOrganizationManagementSaving = true
        defer { isOrganizationManagementSaving = false }
        do {
            _ = try await api.createOrganizationDepartment(context: apiContext, parentDepartmentID: parentDepartmentID, name: trimmedName)
            await refreshOrganizationDirectoryForCurrentSnapshot()
            toast = "部门已创建"
            return true
        } catch {
            handleRemoteError(error, fallback: "部门创建失败")
            return false
        }
    }

    func updateOrganizationDepartment(departmentID: String, parentDepartmentID: String?, name: String?) async -> Bool {
        guard canManageOrganizationDepartments else {
            toast = "当前账号无部门管理权限"
            return false
        }
        guard apiContext.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let normalizedID = normalizedOrganizationDepartmentID(departmentID)
        guard normalizedID != "company" else {
            toast = "公司为默认根节点，不能编辑"
            return false
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName?.isEmpty == true {
            toast = "请输入部门名称"
            return false
        }
        isOrganizationManagementSaving = true
        defer { isOrganizationManagementSaving = false }
        do {
            _ = try await api.updateOrganizationDepartment(context: apiContext, departmentID: normalizedID, parentDepartmentID: parentDepartmentID, name: trimmedName)
            await refreshOrganizationDirectoryForCurrentSnapshot()
            toast = "部门已更新"
            return true
        } catch {
            handleRemoteError(error, fallback: "部门更新失败")
            return false
        }
    }

    func deleteOrganizationDepartment(departmentID: String) async -> Bool {
        guard canManageOrganizationDepartments else {
            toast = "当前账号无部门管理权限"
            return false
        }
        guard apiContext.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let normalizedID = normalizedOrganizationDepartmentID(departmentID)
        guard normalizedID != "company" else {
            toast = "公司为默认根节点，不能删除"
            return false
        }
        isOrganizationManagementSaving = true
        defer { isOrganizationManagementSaving = false }
        do {
            try await api.deleteOrganizationDepartment(context: apiContext, departmentID: normalizedID)
            await refreshOrganizationDirectoryForCurrentSnapshot()
            toast = "部门已删除，成员和子部门已迁移"
            return true
        } catch {
            handleRemoteError(error, fallback: "部门删除失败")
            return false
        }
    }

    func addOrganizationMember(departmentID: String, userID: String) async -> Bool {
        guard canManageOrganizationDepartments else {
            toast = "当前账号无部门管理权限"
            return false
        }
        guard apiContext.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let normalizedDepartmentID = normalizedOrganizationDepartmentID(departmentID)
        guard normalizedDepartmentID != "company" else {
            toast = "请先选择具体部门"
            return false
        }
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty else {
            toast = "请选择成员"
            return false
        }
        isOrganizationManagementSaving = true
        defer { isOrganizationManagementSaving = false }
        do {
            try await api.addOrganizationMember(context: apiContext, departmentID: normalizedDepartmentID, userID: normalizedUserID, isPrimary: true)
            await refreshOrganizationDirectoryForCurrentSnapshot()
            toast = "成员部门已变更"
            return true
        } catch {
            handleRemoteError(error, fallback: "成员加入失败")
            return false
        }
    }

    func removeOrganizationMember(departmentID: String, userID: String) async -> Bool {
        guard canManageOrganizationDepartments else {
            toast = "当前账号无部门管理权限"
            return false
        }
        guard apiContext.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let normalizedDepartmentID = normalizedOrganizationDepartmentID(departmentID)
        guard normalizedDepartmentID != "company" else {
            toast = "公司成员没有可移除的部门归属"
            return false
        }
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty else {
            toast = "请选择成员"
            return false
        }
        isOrganizationManagementSaving = true
        defer { isOrganizationManagementSaving = false }
        do {
            try await api.removeOrganizationMember(context: apiContext, departmentID: normalizedDepartmentID, userID: normalizedUserID)
            await refreshOrganizationDirectoryForCurrentSnapshot()
            toast = "成员已移出部门"
            return true
        } catch {
            handleRemoteError(error, fallback: "成员移除失败")
            return false
        }
    }

    private func refreshOrganizationDirectory(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        guard currentAppPolicy?.departmentEnabled == true || tenantDepartmentEnabled || organizationTree?.departmentEnabled == true else {
            clearOrganizationDirectory()
            return
        }
        isOrganizationSyncing = true
        organizationSyncErrorMessage = nil
        defer { isOrganizationSyncing = false }
        do {
            let tree = try await api.organizationTree(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            organizationTree = tree
            tenantDepartmentEnabled = tree.departmentEnabled
            if !tree.departmentEnabled {
                organizationMembersByDepartmentID = [:]
                organizationMemberIndex = [:]
                organizationSyncErrorMessage = nil
                return
            }

            let departmentIDs = organizationDepartmentIDs(from: tree)
            var membersByDepartment: [String: [IMUser]] = [:]
            var memberIndex: [String: IMUser] = [:]
            for departmentID in departmentIDs {
                let normalizedID = normalizedOrganizationDepartmentID(departmentID)
                let list = try await api.organizationMembers(context: context, departmentID: normalizedID)
                guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
                if !list.departmentEnabled {
                    organizationTree = RemoteOrganizationTree.disabledFallback(root: tree.root)
                    tenantDepartmentEnabled = false
                    organizationMembersByDepartmentID = [:]
                    organizationMemberIndex = [:]
                    return
                }
                let users = list.items.map(organizationMemberUser)
                membersByDepartment[normalizedID] = users
                for user in users {
                    for key in organizationIndexKeys(for: user) {
                        memberIndex[key] = user
                    }
                }
            }
            organizationMembersByDepartmentID = membersByDepartment
            organizationMemberIndex = memberIndex
            reapplyAllAvatarRealtimeProjections()
            organizationSyncErrorMessage = nil
        } catch {
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            organizationSyncErrorMessage = organizationMembersByDepartmentID.isEmpty ? "组织架构同步失败，请稍后重试" : "组织架构同步失败，当前显示上次缓存"
            logSyncEndpointFailure("/api/tenant/org/tree", error: error)
            if isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "组织架构同步失败", silent: true)
            }
        }
    }

    func refreshOrganizationDirectoryForCurrentSnapshot() async {
        guard isAuthenticated, apiContext.hasIMSession else {
            clearOrganizationDirectory(disabled: true)
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        guard isDepartmentFeatureEnabled else {
            clearOrganizationDirectory(disabled: true)
            return
        }
        if let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
           isCurrentRemoteRefresh(refreshSession, scope: scope) {
            await refreshOrganizationDirectory(context: context, scope: scope, refreshSession: refreshSession)
            return
        }
        _ = await refreshRemoteSnapshot(silent: true, force: true)
    }

    private func organizationDepartmentIDs(from tree: RemoteOrganizationTree) -> [String] {
        var ids = ["company"]
        func append(_ node: RemoteDepartmentNode) {
            let id = normalizedOrganizationDepartmentID(node.departmentID)
            if !id.isEmpty && !ids.contains(id) {
                ids.append(id)
            }
            node.children.forEach(append)
        }
        if let root = tree.root {
            root.children.forEach(append)
        } else {
            tree.items.forEach(append)
        }
        return ids
    }

    private func organizationMemberUser(_ member: RemoteOrganizationMemberView) -> IMUser {
        let resolvedID = member.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUserID = member.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryID = resolvedID.isEmpty ? resolvedUserID : resolvedID
        let displayName = member.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let department = normalizedDepartmentName(member.departmentName, pathNames: member.departmentPathNames)
        let user = IMUser(
            id: primaryID.isEmpty ? member.id : primaryID,
            userID: resolvedUserID.isEmpty ? primaryID : resolvedUserID,
            name: displayName.isEmpty ? (primaryID.isEmpty ? "未命名成员" : primaryID) : displayName,
            title: member.positionName,
            department: department,
            departmentPathNames: normalizedDepartmentPathNames(member.departmentPathNames, fallbackName: department),
            phone: "",
            email: "",
            status: presenceStatusText(
                rawStatus: member.presenceStatus,
                online: member.onlineKnown ? member.online : nil
            ),
            lastLoginAt: resolvedLastLoginText(member.lastSeenAt),
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(primaryID),
            avatarURL: member.avatar.isEmpty ? "" : resolveTenantAssetURL(member.avatar),
            avatarVersion: member.avatarVersion,
            avatarUpdatedAt: member.avatarUpdatedAt,
            badges: member.role.isEmpty ? [] : [member.role]
        )
        return presentationOverlaidUser(user)
    }

    private func refreshInitialGroupBundles(_ remoteGroups: [RemoteUserGroup], scope: String, refreshSession: RemoteSnapshotRefreshSession) {
        let generation = refreshSession.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.mainShellGroupBundleDelayNs)
            } catch {
                return
            }
            let preloadGroups = Array(remoteGroups.prefix(2))
            guard !preloadGroups.isEmpty else { return }
            print("[JHT Perf] initial_group_bundle_preload_start count=\(preloadGroups.count) secondary=false generation=\(generation)")
            for group in preloadGroups {
                guard self.isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
                await self.refreshGroupBundle(groupID: group.groupID, silent: true, includeSecondaryData: false)
            }
        }
    }

    private func applyAuthData(_ data: RemoteAuthData, registrationTenantID: String? = nil) -> Bool {
        var candidate = apiContext
        if let registrationTenantID {
            candidate.discardRegistrationIMState()
            candidate.tenantID = registrationTenantID
            candidate.platformAuthSession = nil
            candidate.sessionEpoch = UUID().uuidString
            candidate.pendingRefreshRequestID = nil
        }
        candidate.platformToken = data.platformToken
        candidate.accountID = data.account.id
        candidate.persistAuthSession(data.authSession, fallbackTokenType: "platform", fallbackTenantID: nil)
        if registrationTenantID == nil, let tenant = data.tenant, let member = data.tenantMember {
            candidate.tenantID = tenant.id
            candidate.imUID = member.imUID
        }
        guard candidate.save(sessionStore: protectedSessionStore).isCommitted else { return false }
        apiContext = candidate
        let memberAvatar = data.tenantMember?.avatar.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let memberAvatarVersion = data.tenantMember?.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let memberAvatarUpdatedAt = data.tenantMember?.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedMemberAvatar = memberAvatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(memberAvatar)
        let name = data.account.username.isEmpty ? (data.account.phone.isEmpty ? currentUser.name : data.account.phone) : data.account.username
        currentUser = IMUser(
            id: data.tenantMember?.imUID ?? apiContext.imUID ?? currentUser.id,
            userID: data.tenantMember?.imUID ?? apiContext.imUID ?? currentUser.userID,
            username: data.account.username,
            name: name,
            title: "",
            department: "",
            phone: data.account.phone,
            phoneVerified: data.account.phoneVerified,
            realNameVerified: data.account.realNameVerified,
            realNameStatus: data.account.realNameStatus,
            email: currentUser.email,
            status: "在线",
            enterprise: data.tenant?.name ?? currentEnterprise.name,
            avatarSeed: currentUser.avatarSeed,
            avatarURL: resolvedMemberAvatar,
            avatarVersion: memberAvatarVersion.isEmpty ? currentUser.avatarVersion : memberAvatarVersion,
            avatarUpdatedAt: memberAvatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : memberAvatarUpdatedAt,
            badges: currentUser.badges
        )
        if let memberships = data.memberships, !memberships.isEmpty {
            applyTenantMemberships(memberships)
        } else if let tenant = data.tenant, let member = data.tenantMember {
            applyTenantMemberships([RemoteTenantMembership(tenant: tenant, member: member)])
        }
        return true
    }

    func applyTenantLoginData(_ data: RemoteTenantLoginData, loginIdentifierFallback: String? = nil) -> Bool {
        let session = data.session
        let user = data.user
        let tenant = data.tenant
        let hasIMAccessToken = session?.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let effectiveSessionIdentity = session.flatMap {
            $0.effectiveIdentity(tenantID: tenant?.tenantID ?? "")
        }
        guard !hasIMAccessToken || effectiveSessionIdentity != nil else {
            return false
        }
        apiContext.platformToken = data.platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiContext.platformToken : data.platformToken
        apiContext.accountID = [
            data.accountID,
            data.account?.id,
            user?.accountID,
            data.userID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        apiContext.persistAuthSession(data.authSession, fallbackTokenType: "platform", fallbackTenantID: nil)
        if let session, let effectiveSessionIdentity, hasIMAccessToken {
            apiContext.tenantID = effectiveSessionIdentity.tenantID
            apiContext.imUID = session.imUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (user?.imUID ?? apiContext.imUID) : session.imUID
            apiContext.imToken = session.imToken
            apiContext.appID = IMAPIContext.normalizedIOSAppID(effectiveSessionIdentity.appID)
            apiContext.deviceID = effectiveSessionIdentity.deviceID
            apiContext.persistAuthSession(
                session.authSession,
                fallbackTokenType: "im",
                fallbackTenantID: effectiveSessionIdentity.tenantID
            )
        } else {
            apiContext.tenantID = nil
            apiContext.imUID = nil
            apiContext.imToken = nil
        }
        let persistenceResult = apiContext.save(sessionStore: protectedSessionStore)
        resetInitialSplashOverlayEvaluationState()

        let effectiveRole = user?.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user?.role ?? "" : data.role
        if let tenant, !tenant.tenantID.isEmpty {
            let enterprise = Enterprise(
                id: tenant.tenantID,
                name: tenant.name,
                code: tenant.tenantCode,
                role: effectiveRole,
                status: tenant.status,
                memberCount: 0,
                isDefault: tenant.tenantCode.uppercased() == "DEFAULT",
                accentHex: currentEnterprise.accentHex,
                logoURL: tenant.logoURL,
                logoStatus: tenant.logoStatus,
                logoVersion: tenant.logoVersion,
                logoUpdatedAt: tenant.logoUpdatedAt,
                logoCacheKey: tenant.logoCacheKey,
                logoMime: tenant.logoMime,
                logoWidth: tenant.logoWidth,
                logoHeight: tenant.logoHeight
            )
            currentEnterprise = enterprise
            enterprises = [enterprise]
        }
        if let user {
            let userPhone = user.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountPhone = data.account?.phone.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let accountPhoneVerified = data.account?.phoneVerified ?? false
            let accountPhoneBindingKnown = data.account?.phoneBindingKnown ?? false
            let nextPhoneVerified: Bool
            if user.phoneBindingKnown {
                nextPhoneVerified = user.phoneVerified
            } else if accountPhoneBindingKnown {
                nextPhoneVerified = accountPhoneVerified
            } else {
                nextPhoneVerified = !userPhone.isEmpty || !accountPhone.isEmpty
            }
            let nextPhoneCandidate = userPhone.isEmpty ? accountPhone : userPhone
            let nextPhone = nextPhoneVerified ? nextPhoneCandidate : ""
            let usernameFallback = [
                data.account?.username,
                loginIdentifierFallback
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let resolvedUsername = resolvedCurrentUserUsername(
                remoteUsername: user.username,
                fallbackUsername: usernameFallback,
                currentUsername: currentUser.username
            )
            let displayName = preferredDisplayName(
                candidates: [
                    currentProfileAuthorityDisplayNameCandidate(),
                    user.nickname,
                    data.account?.nickname,
                    resolvedUsername,
                    data.account?.username,
                    user.userID,
                    user.imUID
                ],
                identifiers: [user.imUID, user.userID, data.account?.id, data.accountID],
                fallback: user.imUID.isEmpty ? "企业成员" : user.imUID
            )
            currentUser = IMUser(
                id: user.imUID,
                userID: user.userID.isEmpty ? user.imUID : user.userID,
                username: resolvedUsername,
                name: displayName,
                title: "",
                department: "",
                phone: nextPhone,
                phoneVerified: nextPhoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.accountID,
                status: presenceStatusText(
                    rawStatus: user.presenceStatus,
                    online: user.onlineKnown ? user.online : nil
                ),
                lastLoginAt: resolvedLastLoginText(user.lastSeenAt),
                enterprise: tenant?.name ?? currentEnterprise.name,
                avatarSeed: stableSeed(user.imUID),
                avatarURL: user.avatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(user.avatar),
                avatarVersion: user.avatarVersion,
                avatarUpdatedAt: user.avatarUpdatedAt,
                badges: []
            )
        } else if let account = data.account {
            let resolvedUsername = resolvedCurrentUserUsername(
                remoteUsername: account.username,
                fallbackUsername: loginIdentifierFallback,
                currentUsername: currentUser.username
            )
            let displayName = preferredDisplayName(
                candidates: [currentProfileAuthorityDisplayNameCandidate(), account.nickname, resolvedUsername, account.username, account.id],
                identifiers: [account.id, account.username, resolvedUsername],
                fallback: account.id.isEmpty ? "平台账号" : account.id
            )
            let accountStableID = [
                session?.imUID,
                account.id,
                resolvedUsername,
                account.username,
                account.phone
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "pending_platform_account"
            currentUser = IMUser(
                id: accountStableID,
                userID: accountStableID,
                username: resolvedUsername,
                name: displayName,
                title: "",
                department: "",
                phone: account.phone,
                phoneVerified: account.phoneVerified,
                realNameVerified: account.realNameVerified,
                realNameStatus: account.realNameStatus,
                email: account.id,
                status: "在线",
                enterprise: tenant?.name ?? currentEnterprise.name,
                avatarSeed: stableSeed(accountStableID),
                avatarURL: "",
                badges: []
            )
        } else {
            let platformStableID = [
                loginIdentifierFallback,
                data.userID,
                data.accountID,
                apiContext.accountID
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let platformStableID {
                let displayName = preferredDisplayName(
                    candidates: [data.accountID, data.userID, platformStableID],
                    identifiers: [data.accountID, data.userID, platformStableID],
                    fallback: platformStableID
                )
                currentUser = IMUser(
                    id: platformStableID,
                    userID: platformStableID,
                    username: resolvedCurrentUserUsername(
                        remoteUsername: "",
                        fallbackUsername: loginIdentifierFallback,
                        currentUsername: data.accountID
                    ),
                    name: displayName,
                    title: "",
                    department: "",
                    phone: "",
                    phoneVerified: false,
                    realNameVerified: false,
                    realNameStatus: "",
                    email: data.accountID,
                    status: "在线",
                    enterprise: tenant?.name ?? currentEnterprise.name,
                    avatarSeed: stableSeed(platformStableID),
                    avatarURL: "",
                    badges: []
                )
            }
        }
        recordAccessDiagnosticsMerchantEntered()
        return persistenceResult.isCommitted
    }

    @discardableResult
    func applyVerificationStatus(
        _ status: RemoteVerificationStatus,
        preferredPhoneMasked: String = ""
    ) -> Bool {
        let projection = verificationRequirementAuthorityProjection(
            status: status,
            currentUser: currentUser
        )
        let didMatchCurrentUser = projection != nil
        if didMatchCurrentUser {
            verificationRequirementAuthorityScopeKey = remoteDataScopeKey(for: apiContext)
        } else {
            verificationRequirementAuthorityScopeKey = ""
        }
        let currentPhone = currentUser.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredPhone = preferredPhoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusPhone = status.phoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextPhone: String
        if didMatchCurrentUser {
            nextPhone = preferredPhone.isEmpty
                ? (statusPhone.isEmpty ? currentPhone : statusPhone)
                : preferredPhone
        } else {
            // A cross-user payload is not consumed, including its masked
            // presentation fields. Requirement truth fails closed below.
            nextPhone = currentPhone
        }
        let nextUser = IMUser(
            id: currentUser.id,
            userID: currentUser.userID,
            username: currentUser.username,
            name: currentUser.name,
            title: currentUser.title,
            department: currentUser.department,
            departmentPathNames: currentUser.departmentPathNames,
            phone: nextPhone,
            phoneVerified: projection?.phoneSatisfied == true,
            realNameVerified: projection?.realNameSatisfied == true,
            realNameStatus: didMatchCurrentUser ? status.realNameStatus : currentUser.realNameStatus,
            email: currentUser.email,
            status: currentUser.status,
            enterprise: currentUser.enterprise,
            avatarSeed: currentUser.avatarSeed,
            avatarURL: currentUser.avatarURL,
            avatarVersion: currentUser.avatarVersion,
            avatarUpdatedAt: currentUser.avatarUpdatedAt,
            badges: currentUser.badges
        )
        currentUser = nextUser
        reconcileForcedAppPolicyAuthState(for: nextUser)
        return didMatchCurrentUser
    }

    func reconcileForcedAppPolicyAuthState(for user: IMUser) {
        guard let policy = currentAppPolicy else { return }
        let pendingRequirement = AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user)
        if pendingRequirement == nil {
            cancelForcedAppPolicyAuthDestinationTransition()
            forcedAppPolicyAuthPrompt = nil
            forcedAppPolicyAuthDestination = nil
        } else {
            if let pendingDestination = forcedAppPolicyAuthPresentationFence.pendingDestination,
               pendingDestination != pendingRequirement {
                cancelForcedAppPolicyAuthDestinationTransition()
            }
            if let prompt = forcedAppPolicyAuthPrompt, prompt != pendingRequirement {
                forcedAppPolicyAuthPrompt = nil
            }
            if let destination = forcedAppPolicyAuthDestination, destination != pendingRequirement {
                forcedAppPolicyAuthDestination = nil
            }
        }
    }

    func resetAuthenticatedRemoteData(invalidateRefresh: Bool = true, showLoading: Bool? = nil) {
        isLoadingMoreConversations = false
        isConversationSnapshotPartial = false
        purgeCertificationIdentityRoot(rebindCurrentScope: false)
        purgeAvatarRealtimeProjection(rebindCurrentScope: false)
        purgePresenceConnectivityProjection(rebindCurrentScope: false)
        pendingForcedRemoteSnapshotSuccessorScopes.removeAll(keepingCapacity: false)
        clearPendingRealtimeMessages(reason: "remote_data_reset")
        clearRTCTerminalCompensationsForScopeReset()
        for task in messageSequenceRecoveryRetryTasks.values {
            task.cancel()
        }
        messageSequenceRecoveryRetryTasks.removeAll()
        messageSequenceRecoveryTargets.removeAll()
        messageSequenceRecoveryAttempts.removeAll()
        stopRTCMediaStateHeartbeat(reason: "remote_data_reset")
        groupMemberProfileRefreshEpoch &+= 1
        contactsPostApplyReconciliationGeneration &+= 1
        contactsPostApplyReconciliationTask?.cancel()
        contactsPostApplyReconciliationTask = nil
        if invalidateRefresh {
            remoteSyncEngine.reset()
        }
        let shouldShowLoading = showLoading ?? (isAuthenticated && apiContext.hasIMSession)
        isInitialDataLoading = shouldShowLoading
        hasLoadedRemoteSnapshot = false
        lastRemoteSnapshotPrimarySyncedAt = nil
        syncFailureMessage = nil
        isSyncRetrying = false
        favoriteAssetsCollection.invalidateVisibleItems()
        favoriteAssets = []
        isFavoriteAssetsSyncing = false
        favoriteAssetsSyncErrorMessage = nil
        fileStore.reset()
        authoritativeCallLicenseScopeKey = nil
        groupMuteListItemsByGroupID.removeAll()
        groupMuteListLoadingIDs.removeAll()
        groupMuteListMutatingKeys.removeAll()
        groupMuteListErrorMessages.removeAll()
        groupMuteMutatingIDs.removeAll()
        groupMuteErrorMessages.removeAll()
        cancellingFriendRequestIDs.removeAll()
        groupDescriptionMutatingIDs.removeAll()
        groupOwnerTransferMutatingIDs.removeAll()
        groupOwnerTransferIdempotencyState.reset()
        groupMuteMutationTokensByScope.removeAll()
        groupMuteRealtimeGenerationByScope.removeAll()
        for task in groupMuteBoundaryRefreshTasks.values {
            task.cancel()
        }
        groupMuteBoundaryRefreshTasks.removeAll()
        myGroupNicknamesByScopedGroupKey.removeAll()
        myGroupMemberProjectionsByScopedGroupKey.removeAll()
        groupMemberProfileGenerationByScopedGroupKey.removeAll()
        minimumGroupMemberProfileGenerationByScopedGroupKey.removeAll()
        for task in groupMemberProfileRefreshTasks.values {
            task.cancel()
        }
        groupMemberProfileRefreshTasks.removeAll()
        groupMemberProfileRefreshEpochByScopedGroupKey.removeAll()
        stickerManifestPollTask?.cancel()
        stickerManifestPollTask = nil
        stickerStore.resetRuntime()
        stickerMessageFileAssets.removeAll()
        resolvingStickerMessageFileAssetKeys.removeAll()
        failedStickerMessageFileAssetKeys.removeAll()
        contactCardOriginalNamesByScopedUserKey.removeAll()
        canonicalFriendUIDsByIdentity.removeAll()
        canonicalFriendUIDIdentityScope = ""
        contactStore.reset()
        loginLogs = []
        isLoginLogsLoading = false
        loginLogsLoadFailed = false
        conversationStore.reset()
        enterpriseSearchResults = []
        enterpriseSearchMessage = nil
        isEnterpriseSearching = false
        joiningEnterpriseKeys.removeAll()
        invalidateMyInviteCodeState()
        clearTenantClientPolicy()
        clearTenantScopedSearchState(reason: "remote_data_reset")
        governanceItems = []
        releaseCallLifecycle(as: .ended, reason: "session_reset")
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopAllCallPrompts()
        callStore.reset()
        directCallAttempts.removeAll()
        directCallResourceOwners.removeAll()
        directCallCleanupObligations.removeAll()
        rtcTerminalMarkersByCallID.removeAll()
        presentedVideoTerminalCallIDs.removeAll()
        voipPushPayloadsByCallID.removeAll()
        busyRejectedIncomingCallIDs.removeAll()
        releaseAudioSessionForVoiceCall()
    }

    func refreshMyInviteCode(force: Bool = false) async {
        guard isAuthenticated, apiContext.hasIMSession else {
            invalidateMyInviteCodeState()
            return
        }
        guard force || (!isMyInviteCodeLoading && myInviteCode == nil && myInviteCodeErrorMessage == nil) else {
            return
        }
        let context = apiContext
        let authority = myInviteCodeAuthorityKey(for: context)
        myInviteCodeRequestSequence &+= 1
        let requestSequence = myInviteCodeRequestSequence
        myInviteCodeLoadingRequestSequence = requestSequence
        isMyInviteCodeLoading = true
        defer {
            if isCurrentMyInviteCodeRequest(requestSequence, authority: authority) {
                myInviteCodeLoadingRequestSequence = nil
                isMyInviteCodeLoading = false
            }
        }
        do {
            let inviteCode = try await api.myInviteCode(context: context)
            guard isCurrentMyInviteCodeRequest(requestSequence, authority: authority) else { return }
            guard inviteCode.matchesAuthority(
                tenantID: context.tenantID ?? "",
                imUID: context.imUID ?? ""
            ) else {
                throw IMAPIError.businessForbidden(
                    code: "request_identity_mismatch",
                    message: "当前登录身份与邀请码不匹配",
                    error: nil
                )
            }
            myInviteCode = inviteCode
            myInviteCodeErrorMessage = nil
        } catch {
            guard isCurrentMyInviteCodeRequest(requestSequence, authority: authority) else { return }
            myInviteCode = nil
            myInviteCodeErrorMessage = myInviteCodeUserFacingError(error)
        }
    }

    func activateMyInviteCodeForCurrentSession() {
        guard isAuthenticated, apiContext.hasIMSession else {
            invalidateMyInviteCodeState()
            return
        }
        Task { [weak self] in
            await self?.refreshMyInviteCode()
        }
    }

    func reconcileMyInviteCodeAuthority(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        guard myInviteCodeAuthorityKey(for: oldContext) != myInviteCodeAuthorityKey(for: newContext) else {
            return
        }
        invalidateMyInviteCodeState()
    }

    private func invalidateMyInviteCodeState() {
        myInviteCodeRequestSequence &+= 1
        myInviteCodeLoadingRequestSequence = nil
        myInviteCode = nil
        myInviteCodeErrorMessage = nil
        isMyInviteCodeLoading = false
    }

    private func myInviteCodeAuthorityKey(for context: IMAPIContext) -> String {
        let storedSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionDiscriminator: String
        if !storedSessionID.isEmpty {
            sessionDiscriminator = "session=\(storedSessionID)"
        } else {
            sessionDiscriminator = "token=\((context.imToken ?? "").hashValue)"
        }
        return "\(remoteDataScopeKey(for: context))|\(sessionDiscriminator)"
    }

    private func isCurrentMyInviteCodeRequest(_ requestSequence: UInt64, authority: String) -> Bool {
        isAuthenticated
            && apiContext.hasIMSession
            && myInviteCodeRequestSequence == requestSequence
            && myInviteCodeLoadingRequestSequence == requestSequence
            && myInviteCodeAuthorityKey(for: apiContext) == authority
    }

    private func myInviteCodeUserFacingError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "获取邀请码超时，请稍后重试"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
                 .dataNotAllowed:
                return "网络连接不可用，请稍后重试"
            default:
                return "网络或服务不可用，请稍后重试"
            }
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .unauthorized:
                return "登录已失效，请重新登录"
            case .forbidden:
                return "当前账号无权限读取邀请码"
            case .businessForbidden(let code, _, _) where code == "forbidden":
                return "当前账号无权限读取邀请码"
            case .businessForbidden(let code, _, _) where code == "request_identity_mismatch":
                return "当前登录身份与请求不匹配，请重新登录后再试"
            case .emptyResponse:
                return "邀请码接口未返回有效数据，请刷新重试"
            default:
                break
            }
        }
        return userFacingError(error)
    }

    private var hasAuthenticatedRemoteData: Bool {
        !conversations.isEmpty
            || !contacts.isEmpty
            || !groups.isEmpty
            || !inboxItems.isEmpty
    }

    func certificationPresentation(
        forExactUID rawUID: String
    ) -> CertificationPresentation? {
        guard isAuthenticated,
              let activeScope = certificationPresentationRootScope(
                for: apiContext
              ),
              certificationIdentityRoot.scope == activeScope else {
            return nil
        }
        return certificationIdentityRoot.presentation(forExactUID: rawUID)
    }

    func ensureCertificationPresentations(
        forExactUIDs rawUIDs: some Sequence<String>
    ) {
        guard isAuthenticated,
              apiContext.hasIMSession,
              let activeScope = certificationPresentationRootScope(
                for: apiContext
              ) else {
            #if DEBUG
            NSLog("[JHT Certification] stage=scope_unavailable authenticated=%d im_session=%d", isAuthenticated ? 1 : 0, apiContext.hasIMSession ? 1 : 0)
            #endif
            purgeCertificationIdentityRoot(rebindCurrentScope: false)
            return
        }
        if certificationIdentityRoot.scope != activeScope {
            _ = certificationIdentityRoot.bind(activeScope)
            certificationProfileRequestFence.bind(activeScope)
            certificationPresentationRevision &+= 1
            certificationPresentationScopeRevision &+= 1
        } else if certificationProfileRequestFence.scope != activeScope {
            certificationProfileRequestFence.bind(activeScope)
        }
        let uids = CertificationProfileUIDBatch.normalizedAll(rawUIDs)
        let unresolvedUIDs = uids.filter { uid in
            guard let state = certificationIdentityRoot.state(forExactUID: uid) else {
                return true
            }
            return state.needsRefetch
        }
        let queueableUIDs = certificationProfileRequestFence.queueableUIDs(
            from: unresolvedUIDs
        )
        #if DEBUG
        // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：节流重复 ensure 日志，避免性能分析日志刷屏
        CertificationEnsureLogThrottle.shared.log(
            requested: uids.count,
            unresolved: unresolvedUIDs.count,
            queueable: queueableUIDs.count
        )
        // JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束
        #endif
        guard !queueableUIDs.isEmpty else { return }
        pendingCertificationProfileUIDs.formUnion(queueableUIDs)
        scheduleCertificationProfileRefreshIfNeeded()
    }

    func certificationPresentationRootScope(
        for context: IMAPIContext
    ) -> CertificationPresentationRootScope? {
        guard context.hasIMSession else { return nil }
        let tenantID = context.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewerID = context.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionID = storedSessionID.isEmpty
            ? context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            : storedSessionID
        let scope = CertificationPresentationRootScope(
            tenantID: tenantID,
            viewerID: viewerID,
            appID: appID,
            sessionID: sessionID,
            sessionGeneration: certificationSessionGeneration,
            realtimeGeneration: certificationRealtimeGeneration
        )
        return scope.isValid ? scope : nil
    }

    private func certificationContextBindingKey(
        for context: IMAPIContext
    ) -> String? {
        guard context.hasIMSession else { return nil }
        let tenantID = context.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewerID = context.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionID = storedSessionID.isEmpty
            ? context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            : storedSessionID
        guard !tenantID.isEmpty,
              !viewerID.isEmpty,
              !appID.isEmpty,
              !sessionID.isEmpty else {
            return nil
        }
        return [tenantID, viewerID, appID, sessionID]
            .joined(separator: "\u{1f}")
    }

    func reconcileCertificationIdentityScope(
        from previousContext: IMAPIContext,
        to nextContext: IMAPIContext
    ) {
        guard certificationContextBindingKey(for: previousContext)
                != certificationContextBindingKey(for: nextContext) else {
            return
        }
        certificationSessionGeneration &+= 1
        purgeCertificationIdentityRoot(rebindCurrentScope: true)
    }

    func purgeCertificationIdentityRoot(
        rebindCurrentScope: Bool
    ) {
        let hadState = certificationIdentityRoot.scope != nil
            || !certificationIdentityRoot.subjectStates.isEmpty
            || certificationProfileRequestFence.scope != nil
            || !certificationProfileRequestFence.phases.isEmpty
            || !pendingCertificationProfileUIDs.isEmpty
            || certificationProfileRefreshTask != nil
        certificationProfileRequestSequence &+= 1
        certificationProfileRefreshTask?.cancel()
        certificationProfileRefreshTask = nil
        pendingCertificationProfileUIDs.removeAll(keepingCapacity: false)
        certificationIdentityRoot.purge()
        certificationProfileRequestFence.bind(nil)
        if rebindCurrentScope,
           let scope = certificationPresentationRootScope(for: apiContext) {
            _ = certificationIdentityRoot.bind(scope)
            certificationProfileRequestFence.bind(scope)
        }
        if hadState || certificationIdentityRoot.scope != nil {
            certificationPresentationRevision &+= 1
            certificationPresentationScopeRevision &+= 1
        }
    }

    private func scheduleCertificationProfileRefreshIfNeeded() {
        guard certificationProfileRefreshTask == nil,
              !pendingCertificationProfileUIDs.isEmpty else {
            return
        }
        let now = Date()
        let queueable = Set(certificationProfileRequestFence.queueableUIDs(
            from: pendingCertificationProfileUIDs
        ))
        pendingCertificationProfileUIDs.formIntersection(queueable)
        guard !pendingCertificationProfileUIDs.isEmpty,
              let nextRetryAt = certificationProfileRequestFence.nextRetryDate(
                for: pendingCertificationProfileUIDs,
                now: now
              ) else {
            return
        }
        let delay = max(0.05, nextRetryAt.timeIntervalSince(now))
        let delayNanoseconds = UInt64(min(delay, 8) * 1_000_000_000)
        certificationProfileRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.flushCertificationProfileRefresh()
        }
    }

    private func flushCertificationProfileRefresh() async {
        defer {
            certificationProfileRefreshTask = nil
            if !pendingCertificationProfileUIDs.isEmpty {
                scheduleCertificationProfileRefreshIfNeeded()
            }
        }
        guard isAuthenticated,
              apiContext.hasIMSession,
              let requestScope = certificationPresentationRootScope(
                for: apiContext
              ),
              certificationIdentityRoot.scope == requestScope else {
            purgeCertificationIdentityRoot(rebindCurrentScope: false)
            return
        }
        guard let request = certificationProfileRequestFence.begin(
            exactUIDs: pendingCertificationProfileUIDs.sorted(),
            now: Date()
        ) else { return }
        let batch = request.exactUIDs
        let requestWave = request.wave
        pendingCertificationProfileUIDs.subtract(batch)
        certificationProfileRequestSequence &+= 1
        let requestSequence = certificationProfileRequestSequence
        let context = apiContext
        let tenantID = requestScope.tenantID
        let profileAPI = api
        let avatarCommitEpochAtRequest = avatarLocalCommitAuthorityFence.epoch

        #if DEBUG
        NSLog("[JHT Certification] stage=request_started requested=%d", batch.count)
        #endif
        do {
            let avatarRequestStartedAt = DispatchTime.now().uptimeNanoseconds
            let response = try await CertificationProfileRequestBroker.shared.response(
                scope: requestScope,
                exactUIDs: batch
            ) { requestedUIDs in
                try await profileAPI.userProfiles(
                    context: context,
                    exactUIDs: requestedUIDs
                )
            }
            guard !Task.isCancelled,
                  certificationProfileRequestSequence == requestSequence,
                  certificationPresentationRootScope(for: apiContext)
                    == requestScope,
                  certificationIdentityRoot.scope == requestScope else {
                #if DEBUG
                NSLog("[JHT Certification] stage=response_discarded")
                #endif
                return
            }
            let requestedUIDs = Set(batch)
            let responseUIDs = Set(
                response.items.map(\.imUID) + response.missingUIDs
            )
            #if DEBUG
            NSLog("[JHT Certification] stage=response_received requested=%d items=%d missing=%d coverage_valid=%d", batch.count, response.items.count, response.missingUIDs.count, (!response.hasMalformedCoverage && responseUIDs == requestedUIDs) ? 1 : 0)
            #endif
            guard !response.hasMalformedCoverage,
                  responseUIDs == requestedUIDs else {
                _ = certificationIdentityRoot.markMalformedForRefetch(
                    exactUIDs: batch
                )
                pendingCertificationProfileUIDs.formUnion(
                    certificationProfileRequestFence.markFailed(
                        exactUIDs: batch,
                        wave: requestWave,
                        kind: .transient,
                        now: Date()
                    )
                )
                return
            }

            var authoritativeAvatarSummaries: [UserSummaryV2]? = []
            if authoritativeAvatarSummaries != nil {
                for item in response.items {
                    guard case .authoritative(let summary) = item.userSummaryProjection else {
                        authoritativeAvatarSummaries = nil
                        break
                    }
                    authoritativeAvatarSummaries?.append(summary)
                }
                if authoritativeAvatarSummaries?.count != response.items.count {
                    authoritativeAvatarSummaries = nil
                }
            }

            var changed = false
            var resolvedUIDs: Set<String> = []
            var negativeUIDs = Set(response.missingUIDs)
            var malformedUIDs: Set<String> = []
            for item in response.items {
                switch item.userSummaryProjection {
                case .authoritative(let summary):
                    resolvedUIDs.insert(item.imUID)
                    let outcome = certificationIdentityRoot.apply(
                        summary: summary,
                        subjectTenantID: tenantID,
                        responseScope: requestScope,
                        fresh: true
                    )
                    changed = changed
                        || certificationPresentationOutcomeChangesUI(outcome)
                case .authoritativeOmission:
                    negativeUIDs.insert(item.imUID)
                    let outcome = certificationIdentityRoot
                        .applyAuthoritativeMissing(
                            exactUID: item.imUID,
                            responseScope: requestScope,
                            fresh: true
                        )
                    changed = changed
                        || certificationPresentationOutcomeChangesUI(outcome)
                case .malformed:
                    malformedUIDs.insert(item.imUID)
                    _ = certificationIdentityRoot.markMalformedForRefetch(
                        exactUIDs: [item.imUID]
                    )
                    continue
                }
            }
            for uid in response.missingUIDs {
                let outcome = certificationIdentityRoot
                    .applyAuthoritativeMissing(
                        exactUID: uid,
                        responseScope: requestScope,
                        fresh: true
                    )
                changed = changed
                    || certificationPresentationOutcomeChangesUI(outcome)
            }
            #if DEBUG
            let visibleCount = batch.filter { certificationIdentityRoot.presentation(forExactUID: $0) != nil }.count
            let refetchCount = batch.filter { certificationIdentityRoot.state(forExactUID: $0)?.needsRefetch == true }.count
            NSLog("[JHT Certification] stage=projection resolved=%d negative=%d malformed=%d visible=%d needs_refetch=%d", resolvedUIDs.count, negativeUIDs.count, malformedUIDs.count, visibleCount, refetchCount)
            #endif
            if changed {
                certificationPresentationRevision &+= 1
            }
            certificationProfileRequestFence.markResolved(
                exactUIDs: resolvedUIDs,
                wave: requestWave
            )
            certificationProfileRequestFence.markNegative(
                exactUIDs: negativeUIDs,
                wave: requestWave
            )
            if !malformedUIDs.isEmpty {
                pendingCertificationProfileUIDs.formUnion(
                    certificationProfileRequestFence.markFailed(
                        exactUIDs: malformedUIDs,
                        wave: requestWave,
                        kind: .transient,
                        now: Date()
                    )
                )
            }
            if let authoritativeAvatarSummaries,
               avatarLocalCommitAuthorityFence.epoch == avatarCommitEpochAtRequest,
               AvatarAuthorityRefreshBudget.acceptsResponse(
                startedAt: avatarRequestStartedAt,
                completedAt: DispatchTime.now().uptimeNanoseconds
               ),
               AvatarRealtimeSurfaceProjector.isCompleteAvatarAuthorityBatch(
                requestedUIDs: requestedUIDs,
                itemUIDs: response.items.map(\.imUID),
                missingUIDs: response.missingUIDs,
                allItemsAuthoritative: authoritativeAvatarSummaries.count == response.items.count
               ) {
                let outcomes = avatarRealtimeProjection.applyAuthorityBatch(
                    summaries: authoritativeAvatarSummaries,
                    subjectTenantID: tenantID
                )
                handleAvatarRealtimeOutcomes(outcomes)
            }
        } catch {
            #if DEBUG
            NSLog("[JHT Certification] stage=request_failed retryable=%d", Self.certificationProfileFetchFailureKind(error) == .transient ? 1 : 0)
            #endif
            guard certificationProfileRequestSequence == requestSequence,
                  certificationPresentationRootScope(for: apiContext)
                    == requestScope else {
                return
            }
            _ = certificationIdentityRoot.markMalformedForRefetch(
                exactUIDs: batch
            )
            pendingCertificationProfileUIDs.formUnion(
                certificationProfileRequestFence.markFailed(
                    exactUIDs: batch,
                    wave: requestWave,
                    kind: Self.certificationProfileFetchFailureKind(error),
                    now: Date()
                )
            )
        }
    }

    nonisolated static func certificationProfileFetchFailureKind(
        _ error: Error
    ) -> CertificationProfileFetchFailureKind {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL:
                return .terminal
            default:
                return .transient
            }
        }
        guard let apiError = error as? IMAPIError else { return .transient }
        switch apiError {
        case .rateLimited, .server, .emptyResponse:
            return .transient
        case .httpStatus(let status, _):
            if status == 408 || status == 429 || (500...599).contains(status) {
                return .transient
            }
            return .terminal
        case .missingContext, .badURL, .unauthorized, .forbidden,
             .forcedAuthRequired, .businessForbidden, .conflict,
             .securityBlocked, .loginSecurity:
            return .terminal
        }
    }

    func certificationPresentationOutcomeChangesUI(
        _ outcome: CertificationPresentationFenceOutcome
    ) -> Bool {
        switch outcome {
        case .applied, .cleared, .purged:
            return true
        case .invalidated, .purgedForRefetch,
             .idempotent, .ignoredStale, .ignoredForeign:
            return false
        }
    }

    func reconcileAvatarRealtimeScope(
        from previousContext: IMAPIContext,
        to nextContext: IMAPIContext
    ) {
        let previousTenantID = previousContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextTenantID = nextContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard previousTenantID != nextTenantID
                || previousContext.hasIMSession != nextContext.hasIMSession else {
            return
        }
        purgeAvatarRealtimeProjection(rebindCurrentScope: nextContext.hasIMSession)
    }

    private func purgeAvatarRealtimeProjection(rebindCurrentScope: Bool) {
        avatarAuthorityRequestSequence &+= 1
        avatarAuthorityRefreshTask?.cancel()
        avatarAuthorityRefreshTask = nil
        pendingAvatarAuthorityUIDs.removeAll(keepingCapacity: false)
        avatarRealtimeProjection.purge()
        avatarLocalCommitAuthorityFence.purge()
        if rebindCurrentScope,
           let tenantID = apiContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !tenantID.isEmpty {
            avatarRealtimeProjection.bind(tenantID: tenantID)
            avatarLocalCommitAuthorityFence.bind(tenantID: tenantID)
        }
    }

    func reconcilePresenceConnectivityScope(
        from previousContext: IMAPIContext,
        to nextContext: IMAPIContext
    ) {
        let previousTenantID = previousContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextTenantID = nextContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previousViewerID = previousContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextViewerID = nextContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard previousTenantID != nextTenantID
                || previousViewerID != nextViewerID
                || previousContext.hasIMSession != nextContext.hasIMSession else {
            return
        }
        purgePresenceConnectivityProjection(rebindCurrentScope: nextContext.hasIMSession)
    }

    private func purgePresenceConnectivityProjection(rebindCurrentScope: Bool) {
        presenceConnectivityProjection.purge()
        if rebindCurrentScope,
           let tenantID = apiContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !tenantID.isEmpty,
           let viewerID = apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !viewerID.isEmpty {
            presenceConnectivityProjection.bind(
                tenantID: tenantID,
                viewerID: viewerID
            )
        }
        presenceConnectivityPresentationRevision &+= 1
    }

    private func handleAvatarRealtimeOutcomes(_ outcomes: [AvatarRealtimeProjectionOutcome]) {
        var projections: [AvatarRealtimeProjectionValue] = []
        for outcome in outcomes {
            switch outcome {
            case .applied(let projection):
                projections.append(projection)
            case .refetch(let uids, _):
                queueAvatarAuthorityRefetch(uids.isEmpty ? visibleAvatarAuthorityUIDs() : uids)
            case .unrelated, .ignoredForeignTenant, .ignoredStale, .idempotent:
                break
            }
        }
        applyAvatarRealtimeProjections(projections)
    }

    func handleAvatarRealtimeOutcome(_ outcome: AvatarRealtimeProjectionOutcome) {
        switch outcome {
        case .applied(let projection):
            applyAvatarRealtimeProjection(projection)
        case .refetch(let uids, _):
            queueAvatarAuthorityRefetch(uids.isEmpty ? visibleAvatarAuthorityUIDs() : uids)
        case .unrelated, .ignoredForeignTenant, .ignoredStale, .idempotent:
            break
        }
    }

    func handlePresenceConnectivityOutcome(
        _ outcome: PresenceConnectivityProjectionOutcome
    ) {
        switch outcome {
        case .applied, .refetch, .unrelated, .ignoredForeignTenant, .ignoredStale, .idempotent:
            break
        }
    }

    func queueAvatarAuthorityRefetch(_ rawUIDs: Set<String>) {
        guard isAuthenticated, apiContext.hasIMSession else { return }
        let uids = Set(CertificationProfileUIDBatch.normalizedAll(rawUIDs))
        guard !uids.isEmpty else { return }
        pendingAvatarAuthorityUIDs.formUnion(uids)
        scheduleAvatarAuthorityRefreshIfNeeded()
    }

    func visibleAvatarAuthorityUIDs() -> Set<String> {
        var uids: Set<String> = []
        func insert(_ user: IMUser) {
            let uid = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { uids.insert(uid) }
        }
        let sessionUID = apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sessionUID.isEmpty {
            uids.insert(sessionUID)
        } else if currentUser.id != "pending" {
            insert(currentUser)
        }
        let authorityCurrentUID = sessionUID.isEmpty
            ? currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines)
            : sessionUID
        contacts.forEach(insert)
        friendRequests.forEach { request in
            let uid = request.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { uids.insert(uid) }
        }
        groupJoinRequests.values.joined().forEach { request in
            let uid = request.applicantUID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { uids.insert(uid) }
        }
        calls.forEach { record in
            if let uid = AvatarRealtimeSurfaceProjector.authorityUID(for: record) {
                uids.insert(uid)
            }
        }
        groupMuteListItemsByGroupID.values.joined().forEach { item in
            let uid = item.targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { uids.insert(uid) }
        }
        groups.forEach { group in
            group.members.forEach(insert)
            group.admins.forEach(insert)
        }
        let lookup = makeConversationUserLookup()
        conversationStore.conversations.forEach { conversation in
            conversation.participants.forEach(insert)
            if conversation.kind == .direct,
               let peerUID = AvatarRealtimeSurfaceProjector.directPeerUID(
                    conversationID: conversation.id,
                    remoteChannelID: remoteChannelID(for: conversation, lookup: lookup),
                    participantUIDs: conversation.participants.map(\.id),
                    currentUID: authorityCurrentUID
               ) {
                uids.insert(peerUID)
            }
            conversation.messages.forEach { message in
                let uid = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !uid.isEmpty { uids.insert(uid) }
            }
        }
        if let incomingVoiceCall { insert(incomingVoiceCall.caller) }
        if let activeVoiceCall { insert(activeVoiceCall.peer) }
        return uids
    }

    private func scheduleAvatarAuthorityRefreshIfNeeded() {
        guard avatarAuthorityRefreshTask == nil,
              !pendingAvatarAuthorityUIDs.isEmpty else { return }
        let requestSequence = avatarAuthorityRequestSequence
        avatarAuthorityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            for attempt in 0..<5 where !Task.isCancelled {
                await self.flushAvatarAuthorityBatch(requestSequence: requestSequence)
                guard !self.pendingAvatarAuthorityUIDs.isEmpty else { break }
                if attempt < 4 {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
            }
            guard self.avatarAuthorityRequestSequence == requestSequence else { return }
            self.avatarAuthorityRefreshTask = nil
            if !self.pendingAvatarAuthorityUIDs.isEmpty {
                self.scheduleRealtimeRecoveryRefresh(reason: "avatar_authority_incomplete")
            }
        }
    }

    private func flushAvatarAuthorityBatch(requestSequence: Int64) async {
        guard avatarAuthorityRequestSequence == requestSequence,
              isAuthenticated,
              apiContext.hasIMSession,
              let tenantID = apiContext.tenantID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !tenantID.isEmpty else { return }
        let batch = CertificationProfileUIDBatch.normalized(
            pendingAvatarAuthorityUIDs.sorted()
        )
        guard !batch.isEmpty else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let avatarCommitEpochAtRequest = avatarLocalCommitAuthorityFence.epoch
        pendingAvatarAuthorityUIDs.subtract(batch)
        do {
            let requestStartedAt = DispatchTime.now().uptimeNanoseconds
            let response = try await api.userProfiles(context: context, exactUIDs: batch)
            guard !Task.isCancelled,
                  avatarAuthorityRequestSequence == requestSequence,
                  isCurrentRemoteScope(scope),
                  apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) == tenantID else {
                return
            }
            let requestedUIDs = Set(batch)
            guard avatarLocalCommitAuthorityFence.epoch == avatarCommitEpochAtRequest else {
                pendingAvatarAuthorityUIDs.formUnion(requestedUIDs)
                return
            }
            guard AvatarAuthorityRefreshBudget.acceptsResponse(
                startedAt: requestStartedAt,
                completedAt: DispatchTime.now().uptimeNanoseconds
            ) else {
                pendingAvatarAuthorityUIDs.formUnion(requestedUIDs)
                return
            }
            guard AvatarRealtimeSurfaceProjector.hasExactAuthorityCoverage(
                requestedUIDs: requestedUIDs,
                itemUIDs: response.items.map(\.imUID),
                missingUIDs: response.missingUIDs
            ) else {
                pendingAvatarAuthorityUIDs.formUnion(requestedUIDs)
                return
            }
            var summaries: [UserSummaryV2] = []
            summaries.reserveCapacity(response.items.count)
            var allItemsAuthoritative = true
            for item in response.items {
                switch item.userSummaryProjection {
                case .authoritative(let summary):
                    summaries.append(summary)
                case .authoritativeOmission, .malformed:
                    allItemsAuthoritative = false
                }
            }
            guard AvatarRealtimeSurfaceProjector.isCompleteAvatarAuthorityBatch(
                requestedUIDs: requestedUIDs,
                itemUIDs: response.items.map(\.imUID),
                missingUIDs: response.missingUIDs,
                allItemsAuthoritative: allItemsAuthoritative
            ) else {
                pendingAvatarAuthorityUIDs.formUnion(requestedUIDs)
                return
            }
            let outcomes = avatarRealtimeProjection.applyAuthorityBatch(
                summaries: summaries,
                subjectTenantID: tenantID
            )
            var projections: [AvatarRealtimeProjectionValue] = []
            for outcome in outcomes {
                switch outcome {
                case .applied(let projection):
                    projections.append(projection)
                case .refetch(let uids, _):
                    pendingAvatarAuthorityUIDs.formUnion(uids)
                case .unrelated, .ignoredForeignTenant, .ignoredStale, .idempotent:
                    break
                }
            }
            applyAvatarRealtimeProjections(projections)
        } catch {
            guard avatarAuthorityRequestSequence == requestSequence,
                  isCurrentRemoteScope(scope) else { return }
            pendingAvatarAuthorityUIDs.formUnion(batch)
        }
    }

    private func resolvedAvatarRealtimeProjection(
        _ projection: AvatarRealtimeProjectionValue
    ) -> ResolvedAvatarRealtimeProjection? {
#if DEBUG
        avatarRealtimeAssetResolutionCountForTesting &+= 1
#endif
        let resolvedURL = resolveTenantAssetURL(projection.url)
        guard !resolvedURL.isEmpty,
              avatarLocalCommitAuthorityFence.allows(
                projection,
                resolvedProjectionURL: resolvedURL
              ) else { return nil }
        return ResolvedAvatarRealtimeProjection(value: projection, url: resolvedURL)
    }

    private func resolvedAvatarRealtimeProjection(
        forExactUID rawUID: String
    ) -> ResolvedAvatarRealtimeProjection? {
        guard avatarRealtimeProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty,
              let projection = avatarRealtimeProjection.value(forExactUID: uid) else {
            return nil
        }
        return resolvedAvatarRealtimeProjection(projection)
    }

    func resolvedAvatarRealtimeProjectionMap()
        -> [String: ResolvedAvatarRealtimeProjection] {
        guard avatarRealtimeProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return [:]
        }
        var result: [String: ResolvedAvatarRealtimeProjection] = [:]
        result.reserveCapacity(avatarRealtimeProjection.values.count)
        for projection in avatarRealtimeProjection.values {
            if let resolved = resolvedAvatarRealtimeProjection(projection) {
                result[projection.uid] = resolved
            }
        }
        return result
    }

    private func applyAvatarRealtimeProjection(_ projection: AvatarRealtimeProjectionValue) {
        applyAvatarRealtimeProjections([projection])
    }

    func applyAvatarRealtimeProjections(_ projections: [AvatarRealtimeProjectionValue]) {
        var resolvedByUID: [String: ResolvedAvatarRealtimeProjection] = [:]
        for projection in projections {
            guard apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == projection.tenantID else { continue }
            let resolvedURL = resolveTenantAssetURL(projection.url)
            guard !resolvedURL.isEmpty else { continue }
            guard avatarLocalCommitAuthorityFence.consumeIfAuthoritative(
                projection,
                resolvedProjectionURL: resolvedURL
            ) else {
                queueAvatarAuthorityRefetch([projection.uid])
                continue
            }
            // Authority batches have unique UIDs. Preserve sequential field fallback
            // semantics if a caller ever supplies multiple updates for the same UID.
            if resolvedByUID[projection.uid] != nil {
                applyResolvedAvatarRealtimeProjections(resolvedByUID)
                resolvedByUID.removeAll(keepingCapacity: true)
            }
            resolvedByUID[projection.uid] = ResolvedAvatarRealtimeProjection(
                value: projection,
                url: resolvedURL
            )
        }
        applyResolvedAvatarRealtimeProjections(resolvedByUID)
    }

    private func applyResolvedAvatarRealtimeProjections(
        _ projections: [String: ResolvedAvatarRealtimeProjection]
    ) {
        guard !projections.isEmpty else { return }
        var didChange = false

        func projected(_ user: IMUser) -> IMUser {
            guard let resolved = projections[user.id] else { return user }
            return AvatarRealtimeSurfaceProjector.user(
                user,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
        func projected(_ request: FriendRequest) -> FriendRequest {
            guard let resolved = projections[request.userID] else { return request }
            return AvatarRealtimeSurfaceProjector.friendRequest(
                request,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
        func projected(_ request: GroupJoinRequest) -> GroupJoinRequest {
            guard let resolved = projections[request.applicantUID] else { return request }
            return AvatarRealtimeSurfaceProjector.groupJoinRequest(
                request,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
        func projected(_ record: CallRecord) -> CallRecord {
            guard let uid = AvatarRealtimeSurfaceProjector.authorityUID(for: record),
                  let resolved = projections[uid] else {
                return record
            }
            return AvatarRealtimeSurfaceProjector.callRecord(
                record,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
        func projected(_ item: GroupMuteListItem) -> GroupMuteListItem {
            guard let resolved = projections[item.targetUID] else { return item }
            return AvatarRealtimeSurfaceProjector.groupMuteListItem(
                item,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }

        let nextCurrentUser = projected(currentUser)
        if nextCurrentUser != currentUser {
            currentUser = nextCurrentUser
            didChange = true
        }

        let nextContacts = contactStore.contacts.map(projected)
        if nextContacts != contactStore.contacts {
            contactStore.contacts = nextContacts
            didChange = true
        }

        let nextGroups = contactStore.groups.map { group in
            var next = group
            next.members = group.members.map(projected)
            next.admins = group.admins.map(projected)
            return next
        }
        if nextGroups != contactStore.groups {
            contactStore.groups = nextGroups
            didChange = true
        }

        let nextOrganizationMembers = organizationMembersByDepartmentID.mapValues {
            $0.map(projected)
        }
        if nextOrganizationMembers != organizationMembersByDepartmentID {
            organizationMembersByDepartmentID = nextOrganizationMembers
            didChange = true
        }
        let nextOrganizationIndex = organizationMemberIndex.mapValues(projected)
        if nextOrganizationIndex != organizationMemberIndex {
            organizationMemberIndex = nextOrganizationIndex
            didChange = true
        }
        let nextMyGroupMembers = myGroupMemberProjectionsByScopedGroupKey.mapValues(projected)
        if nextMyGroupMembers != myGroupMemberProjectionsByScopedGroupKey {
            myGroupMemberProjectionsByScopedGroupKey = nextMyGroupMembers
            didChange = true
        }

        let sessionUID = apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentUID = sessionUID.isEmpty
            ? currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines)
            : sessionUID
        let lookup = makeConversationUserLookup()
        // JHT_MOD_BEGIN APPSTATE_AVATAR_CONVERSATION_TARGETED_APPLY_PERF_20260912 - 修改开始：会话/消息头像投影改为命中式应用，避免主线程整表深比较
        let conversationProjectionMap = projections.mapValues {
            ConversationStore.AvatarRealtimeConversationProjection(
                uid: $0.value.uid,
                url: $0.url,
                cacheVersion: $0.value.cacheVersion,
                updatedAt: $0.value.updatedAt
            )
        }
        let conversationProjectionResult = conversationStore.applyAvatarRealtimeProjectionsToConversations(
            conversationProjectionMap,
            currentUID: currentUID,
            channelIDForConversation: { [self] conversation in
                remoteChannelID(for: conversation, lookup: lookup)
            },
            projectParticipant: projected
        )
        if conversationProjectionResult.didChange {
            didChange = true
        }
        #if DEBUG
        if conversationProjectionResult.didChange {
            print("[JHT Perf] avatar_projection_conversation_apply conversations=\(conversationProjectionResult.conversationsChanged) participants=\(conversationProjectionResult.participantsChanged) messages=\(conversationProjectionResult.messagesChanged)")
        }
        #endif
        // JHT_MOD_END APPSTATE_AVATAR_CONVERSATION_TARGETED_APPLY_PERF_20260912 - 修改结束

        if var incoming = callStore.incomingVoiceCall {
            let nextCaller = projected(incoming.caller)
            if nextCaller != incoming.caller {
                incoming.caller = nextCaller
                callStore.incomingVoiceCall = incoming
                didChange = true
            }
        }
        if var active = callStore.activeVoiceCall {
            let nextPeer = projected(active.peer)
            if nextPeer != active.peer {
                active.peer = nextPeer
                callStore.activeVoiceCall = active
                didChange = true
            }
        }
        if var preview = callStore.videoCallPreview {
            let nextPeer = projected(preview.peer)
            if nextPeer != preview.peer {
                preview.peer = nextPeer
                callStore.videoCallPreview = preview
                didChange = true
            }
        }

        let nextFriendRequests = contactStore.friendRequests.map(projected)
        if nextFriendRequests != contactStore.friendRequests {
            contactStore.friendRequests = nextFriendRequests
            didChange = true
        }
        let nextGroupJoinRequests = contactStore.groupJoinRequests.mapValues { $0.map(projected) }
        if nextGroupJoinRequests != contactStore.groupJoinRequests {
            contactStore.groupJoinRequests = nextGroupJoinRequests
            didChange = true
        }
        let nextCalls = callStore.calls.map(projected)
        if nextCalls != callStore.calls {
            callStore.calls = nextCalls
            didChange = true
        }
        let nextGroupMuteItems = groupMuteListItemsByGroupID.mapValues { $0.map(projected) }
        if nextGroupMuteItems != groupMuteListItemsByGroupID {
            groupMuteListItemsByGroupID = nextGroupMuteItems
            didChange = true
        }

        if didChange {
            avatarRealtimePresentationRevision &+= 1
        }
    }

    private func applyPresenceConnectivityProjection(
        _ projection: PresenceConnectivityProjectionValue
    ) {
        guard apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines)
                == projection.tenantID else {
            return
        }
        applyPresenceConnectivityProjections([projection.uid: projection])
    }

    private func applyPresenceConnectivityProjections(
        _ projections: [String: PresenceConnectivityProjectionValue]
    ) {
        guard !projections.isEmpty else { return }
        var didChange = false

        func projected(_ user: IMUser) -> IMUser {
            guard let projection = presenceConnectivityProjection(for: user, in: projections) else {
                return user
            }
            let status = presenceStatusText(
                rawStatus: projection.presenceStatus,
                online: projection.online
            )
            let lastLoginAt = projection.lastSeenAt.isEmpty
                ? user.lastLoginAt
                : resolvedLastLoginText(projection.lastSeenAt)
            return userWithPresenceStatus(
                user,
                status: status,
                lastLoginAt: lastLoginAt
            )
        }

        let nextCurrentUser = projected(currentUser)
        if nextCurrentUser != currentUser {
            currentUser = nextCurrentUser
            didChange = true
        }

        let nextContacts = contactStore.contacts.map(projected)
        if nextContacts != contactStore.contacts {
            contactStore.contacts = nextContacts
            didChange = true
        }

        let nextGroups = contactStore.groups.map { group in
            var next = group
            next.members = group.members.map(projected)
            next.admins = group.admins.map(projected)
            return next
        }
        if nextGroups != contactStore.groups {
            contactStore.groups = nextGroups
            didChange = true
        }

        let nextOrganizationMembers = organizationMembersByDepartmentID.mapValues {
            $0.map(projected)
        }
        if nextOrganizationMembers != organizationMembersByDepartmentID {
            organizationMembersByDepartmentID = nextOrganizationMembers
            didChange = true
        }
        let nextOrganizationIndex = organizationMemberIndex.mapValues(projected)
        if nextOrganizationIndex != organizationMemberIndex {
            organizationMemberIndex = nextOrganizationIndex
            didChange = true
        }
        let nextMyGroupMembers = myGroupMemberProjectionsByScopedGroupKey.mapValues(projected)
        if nextMyGroupMembers != myGroupMemberProjectionsByScopedGroupKey {
            myGroupMemberProjectionsByScopedGroupKey = nextMyGroupMembers
            didChange = true
        }

        let updatedConversationParticipants = conversationStore.updateConversationParticipants(projected)
        if updatedConversationParticipants > 0 {
            didChange = true
        }

        if var incoming = callStore.incomingVoiceCall {
            let nextCaller = projected(incoming.caller)
            if nextCaller != incoming.caller {
                incoming.caller = nextCaller
                callStore.incomingVoiceCall = incoming
                didChange = true
            }
        }
        if var active = callStore.activeVoiceCall {
            let nextPeer = projected(active.peer)
            if nextPeer != active.peer {
                active.peer = nextPeer
                callStore.activeVoiceCall = active
                didChange = true
            }
        }
        if var preview = callStore.videoCallPreview {
            let nextPeer = projected(preview.peer)
            if nextPeer != preview.peer {
                preview.peer = nextPeer
                callStore.videoCallPreview = preview
                didChange = true
            }
        }

        if didChange {
            presenceConnectivityPresentationRevision &+= 1
        }
    }

    private func presenceConnectivityProjection(
        for user: IMUser,
        in projections: [String: PresenceConnectivityProjectionValue]
    ) -> PresenceConnectivityProjectionValue? {
        var seen = Set<String>()
        let keys = [user.id, user.userID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        for key in keys {
            if let projection = projections[key] {
                return projection
            }
        }
        return nil
    }

    private func resolvedPresenceConnectivityProjection(
        for user: IMUser
    ) -> PresenceConnectivityProjectionValue? {
        guard presenceConnectivityProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              presenceConnectivityProjection.viewerID
                == (apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
            return nil
        }
        var seen = Set<String>()
        let keys = [user.id, user.userID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        for key in keys {
            if let projection = presenceConnectivityProjection.value(forExactUID: key) {
                return projection
            }
        }
        return nil
    }

    func reapplyAllAvatarRealtimeProjections() {
        guard avatarRealtimeProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !avatarRealtimeProjection.values.isEmpty else {
            reapplyAllPresenceConnectivityProjections()
            return
        }
        applyResolvedAvatarRealtimeProjections(resolvedAvatarRealtimeProjectionMap())
        reapplyAllPresenceConnectivityProjections()
    }

    private func reapplyAllPresenceConnectivityProjections() {
        guard presenceConnectivityProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              presenceConnectivityProjection.viewerID
                == (apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
              !presenceConnectivityProjection.values.isEmpty else {
            return
        }
        let projections = presenceConnectivityProjection.values.reduce(
            into: [String: PresenceConnectivityProjectionValue]()
        ) { result, projection in
            result[projection.uid] = projection
        }
        applyPresenceConnectivityProjections(projections)
    }

    private func avatarRealtimeOverlaidUser(_ user: IMUser) -> IMUser {
        guard let resolved = resolvedAvatarRealtimeProjection(forExactUID: user.id) else {
            return user
        }
        return AvatarRealtimeSurfaceProjector.user(
            user,
            projection: resolved.value,
            resolvedURL: resolved.url
        )
    }

    private func presenceConnectivityOverlaidUser(_ user: IMUser) -> IMUser {
        guard let projection = resolvedPresenceConnectivityProjection(for: user) else {
            return user
        }
        let status = presenceStatusText(
            rawStatus: projection.presenceStatus,
            online: projection.online
        )
        let lastLoginAt = projection.lastSeenAt.isEmpty
            ? user.lastLoginAt
            : resolvedLastLoginText(projection.lastSeenAt)
        return userWithPresenceStatus(user, status: status, lastLoginAt: lastLoginAt)
    }

    func presentationOverlaidUser(_ user: IMUser) -> IMUser {
        presenceConnectivityOverlaidUser(avatarRealtimeOverlaidUser(user))
    }

    func avatarRealtimeOverlaidFriendRequest(_ request: FriendRequest) -> FriendRequest {
        guard let resolved = resolvedAvatarRealtimeProjection(
            forExactUID: request.userID
        ) else {
            return request
        }
        return AvatarRealtimeSurfaceProjector.friendRequest(
            request,
            projection: resolved.value,
            resolvedURL: resolved.url
        )
    }

    func avatarRealtimeOverlaidGroupJoinRequest(
        _ request: GroupJoinRequest
    ) -> GroupJoinRequest {
        guard let resolved = resolvedAvatarRealtimeProjection(
            forExactUID: request.applicantUID
        ) else {
            return request
        }
        return AvatarRealtimeSurfaceProjector.groupJoinRequest(
            request,
            projection: resolved.value,
            resolvedURL: resolved.url
        )
    }

    func avatarRealtimeOverlaidCallRecord(_ record: CallRecord) -> CallRecord {
        guard let uid = AvatarRealtimeSurfaceProjector.authorityUID(for: record),
              let resolved = resolvedAvatarRealtimeProjection(forExactUID: uid) else {
            return record
        }
        return AvatarRealtimeSurfaceProjector.callRecord(
            record,
            projection: resolved.value,
            resolvedURL: resolved.url
        )
    }

    func projectAvatarRealtime(_ results: [UserSearchResult]) -> [UserSearchResult] {
        results.map { result in
            guard let resolved = resolvedAvatarRealtimeProjection(
                forExactUID: result.id
            ) else { return result }
            return AvatarRealtimeSurfaceProjector.userSearchResult(
                result,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
    }

    func projectPresenceConnectivity(_ result: UserSearchResult) -> UserSearchResult {
        guard presenceConnectivityProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              presenceConnectivityProjection.viewerID
                == (apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
            return result
        }
        let identifiers = [result.imUID, result.userID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let projection = identifiers.lazy.compactMap({
            self.presenceConnectivityProjection.value(forExactUID: $0)
        }).first else {
            return result
        }
        return UserSearchResult(
            imUID: result.imUID,
            userID: result.userID,
            nickname: result.nickname,
            phone: result.phone,
            avatarURL: result.avatarURL,
            status: result.status,
            presenceStatus: presenceStatusText(
                rawStatus: projection.presenceStatus,
                online: projection.online
            ),
            relationStatus: result.relationStatus,
            canApplyFriend: result.canApplyFriend,
            reason: result.reason,
            friendAction: result.friendAction,
            friendFlow: result.friendFlow,
            requiresTenantReview: result.requiresTenantReview,
            requiresTargetApproval: result.requiresTargetApproval
        )
    }

	    func remoteDataScopeKey(for context: IMAPIContext) -> String {
	        messageStore.scopeKey(for: context)
	    }

    func profileContactKey(_ kind: String, identifier: String) -> String {
        "\(kind):\(identifier.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func profileContactKeys(kind: String, identifiers: [String]) -> Set<String> {
        Set(identifiers
            .map { profileContactKey(kind, identifier: $0) }
            .filter { !$0.hasSuffix(":") })
    }

    func profileContactMutationKeys(for user: IMUser, kinds: [String]) -> Set<String> {
        let identifiers = userIdentityCandidates(for: user)
        return kinds.reduce(into: Set<String>()) { result, kind in
            result.formUnion(profileContactKeys(kind: kind, identifiers: identifiers))
        }
    }

    func persistProfileContactProjectionIfPossible(
        scope: String,
        revision: UInt64,
        reason: String
    ) {
        guard isCurrentRemoteScope(scope),
              profileContactRevisionFence.scopeHash == scope,
              let ticket = localMessageTicket else { return }
        // JHT_MOD_BEGIN PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改开始：联系人/资料投影构造放到后台，AppState 只捕获当前值快照和执行持久化
        let contactSnapshot = contacts
        let remarkSnapshot = contactRemarks
        let blacklistSnapshot = blacklist
        let originalNameSnapshot = contactCardOriginalNamesByScopedUserKey
        Task {
            let projection = await ProfileContactProjectionBuilder.projectionOffMain(
                scope: scope,
                revision: revision,
                contacts: contactSnapshot,
                remarks: remarkSnapshot,
                blacklist: blacklistSnapshot,
                originalNamesByScopedUserKey: originalNameSnapshot
            )
            do {
                try await messagePersistence.persistProfileContactProjection(
                    ticket: ticket,
                    projection: projection
                )
            } catch LocalMessageDatabaseError.staleSession {
                // A newer mutation/projection already won this scope.
            } catch LocalMessageDatabaseError.staleWriter {
                // Login or account scope changed while this best-effort write was queued.
            } catch {
                logSyncEndpointFailure("local/profile-contact/\(reason)", error: error)
            }
        }
        // JHT_MOD_END PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改结束
    }

    func commitAuthoritativeProfileContactProjection(scope: String, reason: String) {
        guard let revision = profileContactRevisionFence.acceptAuthoritativeProjection(scopeHash: scope) else {
            return
        }
        persistProfileContactProjectionIfPossible(scope: scope, revision: revision, reason: reason)
    }

    private func applyCachedProfileContactProjection(
        _ projection: LocalProfileContactProjection?,
        scope: String,
        readStamp: ProfileContactReadStamp?
    ) {
        guard let projection,
              profileContactRevisionFence.acceptPersistedProjection(
                scopeHash: scope,
                readStamp: readStamp,
                revision: projection.revision
              ) else { return }
        contacts = projection.contacts.map(\.model)
        contactRemarks = projection.remarks
        blacklist = projection.blacklist.map(\.model)
        let originalNameScopePrefix = "\(scope)|"
        contactCardOriginalNamesByScopedUserKey = contactCardOriginalNamesByScopedUserKey.filter { key, _ in
            !key.hasPrefix(originalNameScopePrefix)
        }
        for (identifier, originalName) in projection.originalNames {
            cacheContactCardOriginalName(originalName, identifiers: [identifier], scope: scope)
        }
        contactStore.markFriendRelationsLoaded()
        refreshDirectConversationDisplayNames()
        pruneNonFriendDirectConversations()
    }

    func reconcileLocalMessageScope(from previous: IMAPIContext, to current: IMAPIContext) {
        let previousHash = try? LocalMessageScope(context: previous).scopeHash
        let currentHash = try? LocalMessageScope(context: current).scopeHash
        let sessionAuthorityChanged = previous.sessionEpoch != current.sessionEpoch
            || previous.tenantAuthSession?.sessionID != current.tenantAuthSession?.sessionID
            || previous.platformAuthSession?.sessionID != current.platformAuthSession?.sessionID
        guard previousHash != currentHash || sessionAuthorityChanged else { return }
        let preservesReauthenticatedScope = previousHash != nil && previousHash == currentHash
            && sessionReauthenticationCommit?.old == previous.authSessionFence
            && sessionReauthenticationCommit?.new == current.authSessionFence
        conversationSelectionEpochFence.invalidate()
        let retiredGeneration = localMessageSessionGeneration
        if !preservesReauthenticatedScope { localMessageSessionGeneration &+= 1 }
        if let previousHash, !preservesReauthenticatedScope {
            do {
                _ = try messagePersistence.schedulePurgeExactScope(
                    context: previous,
                    through: retiredGeneration,
                    beforePurge: {
                        _ = await IOSMediaCacheStoreRegistry.shared.invalidate(
                            scopeHash: previousHash,
                            through: retiredGeneration
                        )
                    }
                )
            } catch {
                toast = "本机数据安全清理失败，已阻止旧作用域缓存访问"
            }
        }
        durableOutboxRecoveryTask?.cancel()
        durableOutboxRecoveryTask = nil
        durableReadAckRecoveryTask?.cancel()
        durableReadAckRecoveryGeneration &+= 1
        durableReadAckRecoveryTask = nil
        durableReadAckRecoveryRestartRequested = false
        localMessageTicket = nil
        if !preservesReauthenticatedScope { localMessageProjectionRevision = 0 }
        profileContactRealtimeRefreshTask?.cancel()
        profileContactRealtimeRefreshTask = nil
        profileContactRevisionFence.rebind(scopeHash: "")
        if current.hasIMSession {
            profileContactRevisionFence.rebind(scopeHash: remoteDataScopeKey(for: current))
        }
    }

    func nextLocalMessageProjectionRevision() -> Int64 {
        localMessageProjectionRevision &+= 1
        return localMessageProjectionRevision
    }

    private func localMessageSnapshots(
        from source: [Conversation],
        requiresServerRevalidation: Bool = false
    ) -> [LocalMessageConversationSnapshot] {
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：快照批量投影委托给 Core/AppSupport builder，AppState 只提供上下文
        let inputs = source.map { conversation in
            localMessageProjectionInput(from: conversation)
        }
        return LocalMessageProjectionBuilder.snapshots(
            from: inputs,
            actorID: actorID,
            requiresServerRevalidation: requiresServerRevalidation
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束
    }

    func localMessageSnapshot(
        from conversation: Conversation,
        actorID: String,
        projectedMessages: [ChatMessage]? = nil,
        requiresServerRevalidation: Bool = false
    ) -> LocalMessageConversationSnapshot {
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：单会话快照构建委托给 Core/AppSupport builder
        LocalMessageProjectionBuilder.snapshot(
            from: localMessageProjectionInput(
                from: conversation,
                projectedMessages: projectedMessages
            ),
            actorID: actorID,
            requiresServerRevalidation: requiresServerRevalidation
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：AppState 只负责解析原有 channel 上下文，实际投影在 support builder
    private func localMessageProjectionInput(
        from conversation: Conversation,
        projectedMessages: [ChatMessage]? = nil
    ) -> LocalMessageProjectionInput {
        LocalMessageProjectionInput(
            conversation: conversation,
            channelID: remoteChannelID(for: conversation),
            channelType: apiChannelType(for: conversation.kind),
            projectedMessages: projectedMessages
        )
    }
    // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束

    private func persistentProjectionMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：消息持久化清洗逻辑从 AppState 拆出
        LocalMessageProjectionBuilder.persistentProjectionMessages(messages)
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束
    }

    private func localMutationProjectionMessages(from conversation: Conversation) -> [ChatMessage] {
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：本地变更 tail-window 选择从 AppState 拆出
        LocalMessageProjectionBuilder.localMutationProjectionMessages(from: conversation)
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束
    }

    private func localMutationSnapshot(for conversation: Conversation) -> LocalMessageConversationSnapshot {
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return localMessageSnapshot(
            from: conversation,
            actorID: actorID,
            projectedMessages: localMutationProjectionMessages(from: conversation)
        )
    }

    private func localMutationSnapshot(
        conversationID: String,
        scope: String
    ) -> LocalMessageConversationSnapshot? {
        guard isCurrentRemoteScope(scope),
              let conversation = conversationStore.conversation(id: conversationID) else { return nil }
        let cacheableConversation = shouldShowGroupMemberCount
            ? conversation
            : conversation.scrubbingGroupMemberTotals()
        return localMutationSnapshot(for: cacheableConversation)
    }

    private func localMutationSnapshotsForAllVisibleConversations(scope: String) -> [LocalMessageConversationSnapshot] {
        guard isCurrentRemoteScope(scope) else { return [] }
        let cacheableConversations = shouldShowGroupMemberCount
            ? conversations
            : conversations.map { $0.scrubbingGroupMemberTotals() }
        return cacheableConversations.map(localMutationSnapshot(for:))
    }

    // JHT_MOD_BEGIN APPSTATE_CONVERSATION_SEQUENCE_HELPER_PERF_20260913 - 修改开始：序号计算委托给 helper，避免消息数组 map/max 临时分配
    func latestKnownSequence(for conversation: Conversation) -> Int64 {
        ConversationSequenceInspector.latestKnownSequence(for: conversation)
    }

    func latestKnownSequence(for remote: RemoteConversation) -> Int64 {
        ConversationSequenceInspector.latestKnownSequence(for: remote)
    }

    func latestKnownSequence(for remoteMessages: [RemoteMessage]) -> Int64 {
        ConversationSequenceInspector.latestKnownSequence(for: remoteMessages)
    }
    // JHT_MOD_END APPSTATE_CONVERSATION_SEQUENCE_HELPER_PERF_20260913 - 修改结束

    func locallyHiddenRecord(
        channelID: String,
        channelType: String,
        records: [String: LocalHiddenConversationRecord],
        lookup: ConversationUserLookup? = nil
    ) -> LocalHiddenConversationRecord? {
        let normalizedID = normalizedRemoteChannelID(channelID, channelType: channelType, lookup: lookup)
        let normalizedType = LocalHiddenConversationRecord.normalizedChannelType(channelType)
        let key = LocalHiddenConversationRecord.recordKey(
            channelID: normalizedID,
            channelType: normalizedType
        )
        if let record = records[key] {
            return record
        }
        return records.values.first { record in
            record.channelType == normalizedType
                && normalizedRemoteChannelID(record.channelID, channelType: record.channelType, lookup: lookup) == normalizedID
        }
    }

    func locallyHiddenRecord(
        matching conversation: Conversation,
        records: [String: LocalHiddenConversationRecord],
        lookup: ConversationUserLookup? = nil
    ) -> LocalHiddenConversationRecord? {
        let channelType = apiChannelType(for: conversation.kind)
        if let record = locallyHiddenRecord(
            channelID: remoteChannelID(for: conversation, lookup: lookup),
            channelType: channelType,
            records: records,
            lookup: lookup
        ) {
            return record
        }
        let conversationID = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conversationID.isEmpty else { return nil }
        return records.values.first { $0.conversationID == conversationID }
    }

    func removeLocalHiddenRecord(
        _ record: LocalHiddenConversationRecord,
        from records: inout [String: LocalHiddenConversationRecord]
    ) {
        records = records.filter { element in
            let key = element.key
            let value = element.value
            return key != record.key
                && !(value.channelID == record.channelID && value.channelType == record.channelType)
                && (record.conversationID.isEmpty || value.conversationID != record.conversationID)
        }
    }

    func visibleConversationsAfterLocalHiding(
        _ sourceConversations: [Conversation],
        scope: String,
        lookup: ConversationUserLookup? = nil
    ) -> [Conversation] {
        guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sourceConversations
        }
        var records = LocalHiddenConversationStore.load(scope: scope)
        guard !records.isEmpty else { return sourceConversations }
        var didUpdateRecords = false
        let visible = sourceConversations.filter { conversation in
            guard let record = locallyHiddenRecord(matching: conversation, records: records, lookup: lookup) else {
                return true
            }
            let latestSeq = latestKnownSequence(for: conversation)
            if latestSeq > record.hiddenThroughSeq, latestSeq > 0 {
                removeLocalHiddenRecord(record, from: &records)
                didUpdateRecords = true
                return true
            }
            return false
        }
        if didUpdateRecords {
            LocalHiddenConversationStore.save(records, scope: scope)
        }
        return visible
    }

    func visibleRemoteConversationsAfterLocalHiding(
        _ remoteConversations: [RemoteConversation],
        scope: String,
        lookup: ConversationUserLookup? = nil
    ) -> [RemoteConversation] {
        guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return remoteConversations
        }
        var records = LocalHiddenConversationStore.load(scope: scope)
        guard !records.isEmpty else { return remoteConversations }
        var didUpdateRecords = false
        let visible = remoteConversations.filter { remote in
            let channelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType, lookup: lookup)
            guard let record = locallyHiddenRecord(
                channelID: channelID,
                channelType: remote.channelType,
                records: records,
                lookup: lookup
            ) else {
                return true
            }
            let latestSeq = latestKnownSequence(for: remote)
            if latestSeq > record.hiddenThroughSeq, latestSeq > 0 {
                removeLocalHiddenRecord(record, from: &records)
                didUpdateRecords = true
                return true
            }
            return false
        }
        if didUpdateRecords {
            LocalHiddenConversationStore.save(records, scope: scope)
        }
        return visible
    }

    func isGroupConversationLocallyHidden(groupID: String) -> Bool {
        guard apiContext.hasIMSession else { return false }
        let scope = remoteDataScopeKey(for: apiContext)
        let records = LocalHiddenConversationStore.load(scope: scope)
        guard !records.isEmpty else { return false }
        return locallyHiddenRecord(channelID: groupID, channelType: "group", records: records) != nil
    }

    func hideConversationLocally(_ conversation: Conversation, scope: String) {
        let channelType = apiChannelType(for: conversation.kind)
        let channelID = remoteChannelID(for: conversation)
        guard !channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        LocalHiddenConversationStore.hide(
            LocalHiddenConversationRecord(
                conversationID: conversation.id,
                channelID: channelID,
                channelType: channelType,
                hiddenThroughSeq: latestKnownSequence(for: conversation)
            ),
            scope: scope
        )
    }

    func clearLocalHiddenConversation(channelID: String, channelType: String, scope: String) {
        let normalizedID = normalizedRemoteChannelID(channelID, channelType: channelType)
        guard !normalizedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        LocalHiddenConversationStore.remove(
            channelID: normalizedID,
            channelType: channelType,
            scope: scope
        )
    }

    private func currentProfileAuthorityScope(for context: IMAPIContext) -> CurrentProfileAuthorityScope? {
        CurrentProfileAuthorityScope(
            tenantID: context.tenantID ?? "",
            actorIMUID: context.imUID ?? "",
            appID: IMAPIContext.normalizedIOSAppID(context.appID)
        )
    }

    func beginCurrentProfileRead(context: IMAPIContext) -> CurrentProfileAuthorityRequest? {
        guard let scope = currentProfileAuthorityScope(for: context),
              scope == currentProfileAuthorityScope(for: apiContext) else {
            return nil
        }
        return currentProfileAuthorityFence.beginRead(scope: scope)
    }

    func beginCurrentProfileMutation(context: IMAPIContext) -> CurrentProfileAuthorityRequest? {
        guard let scope = currentProfileAuthorityScope(for: context),
              scope == currentProfileAuthorityScope(for: apiContext) else {
            return nil
        }
        return currentProfileAuthorityFence.beginMutation(scope: scope)
    }

    func currentProfileAuthorityCheckpoint() -> CurrentProfileAuthorityCheckpoint? {
        guard let scope = currentProfileAuthorityScope(for: apiContext),
              currentProfileAuthorityFence.checkpoint?.scope == scope else {
            return nil
        }
        return currentProfileAuthorityFence.checkpoint
    }

    func currentProfileAuthorityDisplayNameCandidate() -> String? {
        currentProfileAuthorityCheckpoint()?.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hydrateCurrentProfileAuthority(from checkpoint: CurrentProfileAuthorityCheckpoint?) {
        currentProfileAuthorityFence.hydrate(
            checkpoint,
            for: currentProfileAuthorityScope(for: apiContext)
        )
    }

    func reconcileCurrentProfileAuthorityScope(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        guard currentProfileAuthorityScope(for: oldContext) != currentProfileAuthorityScope(for: newContext) else {
            return
        }
        let restored = IMCurrentUserIdentityCache.load(context: newContext)?.authorityCheckpoint
        currentProfileAuthorityFence.hydrate(restored, for: currentProfileAuthorityScope(for: newContext))
    }

    func acceptsCurrentProfileAuthority(
        _ snapshot: CurrentProfileAuthoritySnapshot,
        request: CurrentProfileAuthorityRequest
    ) -> Bool {
        switch currentProfileAuthorityFence.consume(snapshot, request: request) {
        case .acceptVersioned, .acceptLegacy:
            return true
        case .rejectPreMutationResponse,
             .rejectScopeMismatch,
             .rejectMalformed,
             .rejectDowngrade,
             .rejectRevisionConflict,
             .rejectLegacyAfterMutation:
            return false
        }
    }

    func currentProfileAuthoritySnapshot(
        from profile: RemoteMeProfile,
        request: CurrentProfileAuthorityRequest
    ) -> CurrentProfileAuthoritySnapshot {
        let isVersioned = profile.userRevision != nil || profile.identityGeneration != nil
        return CurrentProfileAuthoritySnapshot(
            tenantID: isVersioned ? profile.tenantID : (profile.tenantID.isEmpty ? request.scope.tenantID : profile.tenantID),
            imUID: isVersioned ? profile.imUID : (profile.imUID.isEmpty ? request.scope.actorIMUID : profile.imUID),
            appID: request.scope.appID,
            userRevision: profile.userRevision,
            identityGeneration: profile.identityGeneration,
            nickname: profile.nickname,
            avatar: profile.avatar
        )
    }

    func currentProfileAuthoritySnapshot(
        from user: RemoteIMUser,
        context: RemoteTenantContext,
        request: CurrentProfileAuthorityRequest
    ) -> CurrentProfileAuthoritySnapshot {
        let isVersioned = user.userRevision != nil || user.identityGeneration != nil
        let tenantID = user.tenantID.isEmpty ? context.tenantID : user.tenantID
        let appID = context.appID.isEmpty ? request.scope.appID : IMAPIContext.normalizedIOSAppID(context.appID)
        return CurrentProfileAuthoritySnapshot(
            tenantID: isVersioned ? tenantID : (tenantID.isEmpty ? request.scope.tenantID : tenantID),
            imUID: isVersioned ? user.imUID : (user.imUID.isEmpty ? request.scope.actorIMUID : user.imUID),
            appID: appID,
            userRevision: user.userRevision,
            identityGeneration: user.identityGeneration,
            nickname: user.nickname,
            avatar: user.avatar
        )
    }

        func callRecordDataScopeKey(for context: IMAPIContext) -> String {
            [
                // v2 could contain rows copied from an app-wide mirror. Keep
                // that archive intact, but never present its unowned rows.
                "v3",
                "bundle=\(Self.callRecordScopeComponent(Bundle.main.bundleIdentifier ?? ""))",
                "app=\(Self.callRecordScopeComponent(IMAPIContext.normalizedIOSAppID(context.appID)))",
                "account=\(Self.callRecordScopeComponent(context.accountID ?? ""))",
                "tenant=\(Self.callRecordScopeComponent(context.tenantID ?? ""))",
                "im=\(Self.callRecordScopeComponent(context.imUID ?? ""))"
            ].joined(separator: "|")
        }

        private func legacyCallRecordDataScopeKey(for context: IMAPIContext) -> String {
            [
                "v1",
                "app=\(Self.callRecordScopeComponent(IMAPIContext.normalizedIOSAppID(context.appID)))",
                "account=\(Self.callRecordScopeComponent(context.accountID ?? ""))",
                "tenant=\(Self.callRecordScopeComponent(context.tenantID ?? ""))",
                "im=\(Self.callRecordScopeComponent(context.imUID ?? ""))"
            ].joined(separator: "|")
        }

        private static func callRecordScopeComponent(_ value: String) -> String {
            Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }

	    func bindCallRecordPersistence(for context: IMAPIContext) {
	        guard context.hasIMSession,
                      context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
	            callStore.clearCallRecordPersistenceBinding()
	            return
	        }
	        callStore.bindCallRecordPersistence(
                scope: callRecordDataScopeKey(for: context),
                fallbackScopes: [
                    legacyCallRecordDataScopeKey(for: context),
                    remoteDataScopeKey(for: context)
                ]
            )
	    }

        func ensureCallRecordPersistenceBindingIfNeeded() {
            guard apiContext.hasIMSession,
                  !callStore.hasCallRecordPersistenceBinding else { return }
            bindCallRecordPersistence(for: apiContext)
        }

	    func beginTenantDevicePolicyRequest(
        context: IMAPIContext
    ) -> TenantDevicePolicyRequestAuthority? {
        guard let scope = TenantDevicePolicyAuthorityScope(context: context),
              scope == TenantDevicePolicyAuthorityScope(context: apiContext) else {
            return nil
        }
        tenantDevicePolicyRequestGeneration &+= 1
        tenantDeviceMultiplicityPolicyState = .unavailable
        return TenantDevicePolicyRequestAuthority(
            scope: scope,
            generation: tenantDevicePolicyRequestGeneration
        )
    }

    func isCurrentTenantDevicePolicyRequest(
        _ authority: TenantDevicePolicyRequestAuthority
    ) -> Bool {
        tenantDevicePolicyRequestGeneration == authority.generation
            && TenantDevicePolicyAuthorityScope(context: apiContext) == authority.scope
    }

    func markTenantDevicePolicyUnavailable(
        authority: TenantDevicePolicyRequestAuthority
    ) {
        guard isCurrentTenantDevicePolicyRequest(authority) else { return }
        tenantDeviceMultiplicityPolicyState = .unavailable
    }

    private func applyTenantDevicePolicy(
        _ policy: RemoteTenantClientPolicy?,
        authority: TenantDevicePolicyRequestAuthority
    ) {
        guard isCurrentTenantDevicePolicyRequest(authority),
              let policy,
              policy.multiDevicePolicyPresent,
              policy.multiDevicePolicyAuthoritative,
              policy.multiDeviceContractVersion == 1 else {
            markTenantDevicePolicyUnavailable(authority: authority)
            return
        }
        tenantDeviceMultiplicityPolicyState = policy.multiDeviceEnabled
            ? .multipleDevices
            : .singleDevice
    }

    func reconcileTenantDevicePolicyAuthority(
        from previousContext: IMAPIContext,
        to nextContext: IMAPIContext
    ) {
        guard TenantDevicePolicyAuthorityScope(context: previousContext)
                != TenantDevicePolicyAuthorityScope(context: nextContext) else {
            return
        }
        invalidateTenantDevicePolicyState()
    }

    private func invalidateTenantDevicePolicyState() {
        tenantDevicePolicyRequestGeneration &+= 1
        tenantDeviceMultiplicityPolicyState = .unavailable
    }

    func tenantContextMatchesDevicePolicyAuthority(
        _ context: RemoteTenantContext,
        authority: TenantDevicePolicyRequestAuthority
    ) -> Bool {
        let tenantID = context.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let viewerID = context.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return tenantID == authority.scope.tenantID
            && viewerID == authority.scope.viewerID
            && appID == authority.scope.appID
            && deviceID == authority.scope.deviceID
    }

    func applyTenantClientPolicy(
        _ policy: RemoteTenantClientPolicy?,
        context: IMAPIContext,
        devicePolicyAuthority: TenantDevicePolicyRequestAuthority? = nil
    ) {
        guard context.hasIMSession else {
            clearTenantClientPolicy()
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let incoming = policy ?? RemoteTenantClientPolicy(
            showGroupMemberCount: false,
            groupMemberCountPolicyAuthoritative: false,
            groupMemberCountPolicyPresent: false
        )
        let minimumGeneration = minimumGroupMemberCountPolicyGenerationByScope[scope] ?? 0
        let satisfiesPendingInvalidation =
            incoming.groupMemberCountPolicyGeneration >= minimumGeneration
        let decision = resolveGroupMemberCountVisibility(
            storedAuthoritative: GroupMemberCountVisibilityStore.load(scope: scope),
            incoming: incoming
        )
        tenantClientPolicyScopeKey = scope
        tenantClientPolicy = decision.effectivePolicy
        if let devicePolicyAuthority {
            applyTenantDevicePolicy(
                policy,
                authority: devicePolicyAuthority
            )
        }
        groupMemberCountPolicyResolution =
            policy?.groupMemberCountPolicyPresent == true &&
            (policy?.groupMemberCountContractVersion ?? 0) >= 1 &&
            policy?.groupMemberCountPolicyAuthoritative == true &&
            satisfiesPendingInvalidation
            ? .authoritative(
                scope: scope,
                generation: policy?.groupMemberCountPolicyGeneration ?? 0
            )
            : .unresolved(
                scope: scope,
                minimumGeneration: minimumGeneration
            )
        if case .authoritative(_, _) = groupMemberCountPolicyResolution {
            minimumGroupMemberCountPolicyGenerationByScope.removeValue(forKey: scope)
        }
        if let record = decision.authoritativeRecordToPersist {
            GroupMemberCountVisibilityStore.save(record, scope: scope)
        }
        if !shouldShowGroupMemberCount {
            scrubHiddenGroupMemberTotals(scope: scope, clearSearchState: true)
        }
        if !decision.effectivePolicy.showOnlineStatus || !decision.effectivePolicy.showLastLoginTime {
            scrubHiddenPresenceState()
        }
        if decision.effectivePolicy.showOnlineStatus || decision.effectivePolicy.showLastLoginTime {
            reapplyAllPresenceConnectivityProjections()
        }
    }

    private func clearTenantClientPolicy() {
        let previousScope = tenantClientPolicyScopeKey
        tenantClientPolicy = nil
        tenantClientPolicyScopeKey = ""
        invalidateTenantDevicePolicyState()
        let scopeToScrub = previousScope.isEmpty
            ? remoteDataScopeKey(for: apiContext)
            : previousScope
        groupMemberCountPolicyResolution = .unresolved(
            scope: scopeToScrub,
            minimumGeneration: minimumGroupMemberCountPolicyGenerationByScope[scopeToScrub] ?? 0
        )
        groupMemberCountPolicyCheckpoint = nil
        groupMemberCountPolicyRefreshTask?.cancel()
        groupMemberCountPolicyRefreshTask = nil
        scrubHiddenGroupMemberTotals(scope: scopeToScrub, clearSearchState: true)
        scrubHiddenPresenceState()
    }

    func markGroupMemberCountPolicyUnresolved(
        scope: String,
        minimumGeneration: Int64? = nil
    ) {
        guard !scope.isEmpty else { return }
        let nextMinimumGeneration = max(
            minimumGroupMemberCountPolicyGenerationByScope[scope] ?? 0,
            max(0, minimumGeneration ?? 0)
        )
        groupMemberCountPolicyResolution = .unresolved(
            scope: scope,
            minimumGeneration: nextMinimumGeneration
        )
        if let minimumGeneration {
            minimumGroupMemberCountPolicyGenerationByScope[scope] = max(
                minimumGroupMemberCountPolicyGenerationByScope[scope] ?? 0,
                max(0, minimumGeneration)
            )
        }
        scrubHiddenGroupMemberTotals(scope: scope, clearSearchState: true)
    }

    private func groupMemberCountPolicyFenceScope(
        context: IMAPIContext
    ) -> ScopedResponseScope? {
        guard context.hasIMSession else { return nil }
        let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewerID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionID = storedSessionID.isEmpty ? context.deviceID : storedSessionID
        return ScopedResponseScope(
            tenantID: tenantID,
            viewerID: viewerID,
            appID: appID,
            featureKey: "show_group_member_count",
            subjectType: "tenant",
            subjectID: tenantID,
            sessionID: sessionID,
            sessionGeneration: 0,
            capabilityFingerprint: "tenant-policy-v1"
        )
    }

    func refreshGroupMemberCountPolicyAfterRealtimeInvalidation(
        envelope: RealtimeEnvelope
    ) {
        let context = apiContext
        guard context.hasIMSession else {
            clearTenantClientPolicy()
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let eventTenantID = payloadString(envelope.payload, ["tenant_id", "tenantId"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard eventTenantID.isEmpty || eventTenantID == currentTenantID else { return }
        let generationFamily = payloadString(
            envelope.payload,
            ["generation_family", "generationFamily"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eventGeneration = max(
            0,
            payloadInt64(
                envelope.payload,
                ["tenant_policy_generation", "generation"]
            ) ?? 0
        )
        markGroupMemberCountPolicyUnresolved(
            scope: scope,
            minimumGeneration: eventGeneration
        )
        clearGroupAnnouncementReadCounts()
        guard generationFamily.isEmpty || generationFamily == ScopedGenerationFamily.tenantPolicy.rawValue,
              let activeFenceScope = groupMemberCountPolicyFenceScope(context: context) else {
            groupMemberCountPolicyCheckpoint = nil
            return
        }
        if let currentGeneration = groupMemberCountPolicyCheckpoint?
            .version.familyGenerations[.tenantPolicy],
           eventGeneration > currentGeneration + 1 {
            groupMemberCountPolicyCheckpoint = nil
        }
        groupMemberCountPolicyRequestSequence += 1
        let requestSequence = groupMemberCountPolicyRequestSequence
        groupMemberCountPolicyRefreshTask?.cancel()
        groupMemberCountPolicyRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await self.api.tenantContext(context: context)
                guard !Task.isCancelled,
                      self.isCurrentRemoteScope(scope) else {
                    return
                }
                guard let refreshedPolicy = refreshed.clientPolicy,
                      refreshedPolicy.groupMemberCountPolicyPresent,
                      refreshedPolicy.groupMemberCountContractVersion >= 1,
                      refreshedPolicy.groupMemberCountPolicyAuthoritative,
                      refreshedPolicy.groupMemberCountPolicyGeneration >= eventGeneration else {
                    self.markGroupMemberCountPolicyUnresolved(
                        scope: scope,
                        minimumGeneration: eventGeneration
                    )
                    return
                }
                let incoming = ScopedResponseCheckpoint(
                    scope: activeFenceScope,
                    version: ScopedResponseVersion(
                        contractVersion: ScopedResponseVersion.currentContractVersion,
                        revision: refreshedPolicy.groupMemberCountPolicyGeneration,
                        familyGenerations: [
                            .tenantPolicy: refreshedPolicy.groupMemberCountPolicyGeneration
                        ],
                        requestSequence: requestSequence
                    )
                )
                let outcome = ScopedResponseFence.evaluate(
                    current: self.groupMemberCountPolicyCheckpoint,
                    activeScope: self.groupMemberCountPolicyFenceScope(context: self.apiContext),
                    activeRequestSequence: requestSequence,
                    incoming: incoming
                )
                switch outcome {
                case .apply(let checkpoint):
                    self.groupMemberCountPolicyCheckpoint = checkpoint
                    self.applyTenantClientPolicy(refreshedPolicy, context: context)
                case .ignoreIdempotent:
                    self.applyTenantClientPolicy(refreshedPolicy, context: context)
                case .purge, .purgeAndRefetch:
                    self.groupMemberCountPolicyCheckpoint = nil
                    self.markGroupMemberCountPolicyUnresolved(
                        scope: scope,
                        minimumGeneration: eventGeneration
                    )
                case .ignoreStale, .ignoreInactiveRequest, .ignoreForeign:
                    self.markGroupMemberCountPolicyUnresolved(
                        scope: scope,
                        minimumGeneration: eventGeneration
                    )
                }
            } catch {
                guard self.isCurrentRemoteScope(scope) else { return }
                self.markGroupMemberCountPolicyUnresolved(
                    scope: scope,
                    minimumGeneration: eventGeneration
                )
            }
        }
    }

    func scrubHiddenGroupMemberTotals(scope: String, clearSearchState: Bool = false) {
        let scrubbed = clientStateScrubbingGroupMemberTotals(
            groups: groups,
            conversations: conversations,
            clearSearchState: clearSearchState
        )
        groups = scrubbed.groups
        conversationStore.conversations = scrubbed.conversations
        if !scope.isEmpty {
            messageStore.remove(scope: scope)
        }
        if scrubbed.clearsTenantScopedSearchState {
            clearTenantScopedSearchState(reason: "group_member_count_hidden")
        }
    }

    @discardableResult
    func removeRemoteSnapshotCache(for context: IMAPIContext) -> Bool {
        guard context.hasIMSession else { return true }
        var didScheduleLocalCleanup = true
        let retiredGeneration = localMessageSessionGeneration
        localMessageSessionGeneration &+= 1
        localMessageTicket = nil
        let scope = remoteDataScopeKey(for: context)
        messageStore.remove(scope: scope)
        if let scopeHash = try? LocalMessageScope(context: context).scopeHash {
            do {
                _ = try messagePersistence.schedulePurgeExactScope(
                    context: context,
                    through: retiredGeneration,
                    beforePurge: {
                        _ = await IOSMediaCacheStoreRegistry.shared.invalidate(
                            scopeHash: scopeHash,
                            through: retiredGeneration
                        )
                    }
                )
            } catch {
                didScheduleLocalCleanup = false
                toast = "本机数据安全清理失败，已阻止旧作用域缓存访问"
            }
        }
        AttachmentDownloadCachePolicy.purgeLegacyDownloads()
        AttachmentDownloadCachePolicy.purgeTransientStaging()
        FilesPreviewCacheAdapter.purgeLegacyScope(scope)
        SystemPreviewLoader.purgeAllTransientFiles()
        AvatarImageCache.shared.removeAllImages()
        favoriteAssetsCollection.purge(scope: scope)
        favoriteAssets = favoriteAssetsCollection.activeItems
        isFavoriteAssetsSyncing = false
        favoriteAssetsSyncErrorMessage = nil
        return didScheduleLocalCleanup
    }

    func isCurrentRemoteScope(_ scope: String) -> Bool {
        apiContext.hasIMSession && remoteDataScopeKey(for: apiContext) == scope
    }

    func isCurrentRemoteRefresh(_ session: RemoteSnapshotRefreshSession, scope: String) -> Bool {
        remoteSyncEngine.isCurrentRemoteSnapshotRefresh(session) && isCurrentRemoteScope(scope)
    }

    func normalizedOrganizationDepartmentID(_ departmentID: String) -> String {
        let trimmed = departmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "__company__" || trimmed == "__root__" {
            return "company"
        }
        return trimmed
    }

    func normalizedDepartmentPathNames(_ pathNames: [String], fallbackName: String) -> [String] {
        let cleaned = pathNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            return cleaned
        }
        let fallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? ["公司"] : [fallback]
    }

    func normalizedDepartmentName(_ departmentName: String, pathNames: [String]) -> String {
        let trimmed = departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return normalizedDepartmentPathNames(pathNames, fallbackName: "").last ?? ""
    }

    func departmentEnrichedUser(_ user: IMUser) -> IMUser {
        let indexed = organizationIndexKeys(for: user).compactMap { organizationMemberIndex[$0] }.first
        let indexedDepartment = indexed?.department.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let indexedPath = indexed?.departmentPathNames ?? []
        let department = user.department.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? indexedDepartment : user.department
        let path = user.departmentPathNames.isEmpty ? indexedPath : user.departmentPathNames
        if department == user.department && path == user.departmentPathNames {
            return user
        }
        return user.withDepartment(department, pathNames: path)
    }

    private func organizationIndexKeys(for user: IMUser) -> [String] {
        var seen = Set<String>()
        return [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    func clearOrganizationDirectory(disabled: Bool = false) {
        if disabled {
            tenantDepartmentEnabled = false
        }
        organizationTree = nil
        organizationMembersByDepartmentID = [:]
        organizationMemberIndex = [:]
        isOrganizationSyncing = false
        organizationSyncErrorMessage = nil
    }

    func applyCachedRemoteSnapshotIfAvailable(context: IMAPIContext) async -> Bool {
        guard context.hasIMSession else { return false }
        let scope = remoteDataScopeKey(for: context)
        profileContactRevisionFence.rebind(scopeHash: scope)
        let profileContactReadStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        let generation = localMessageSessionGeneration
        groupMemberCountPolicyResolution = .unresolved(
            scope: scope,
            minimumGeneration: minimumGroupMemberCountPolicyGenerationByScope[scope] ?? 0
        )
        if let stored = GroupMemberCountVisibilityStore.load(scope: scope),
           !stored.showGroupMemberCount {
            tenantClientPolicyScopeKey = scope
            tenantClientPolicy = RemoteTenantClientPolicy(
                showGroupMemberCount: false,
                groupMemberCountPolicyGeneration: stored.generation,
                groupMemberCountContractVersion: stored.contractVersion
            )
        }
        do {
            let loaded = try await messagePersistence.activateAndLoad(
                context: context,
                sessionGeneration: generation,
                conversationLimit: 1_200,
                messagesPerConversation: 50
            )
            guard generation == localMessageSessionGeneration,
                  isCurrentRemoteScope(scope) else {
                return false
            }
            localMessageTicket = loaded.ticket
            applyCachedProfileContactProjection(
                loaded.profileContactProjection,
                scope: scope,
                readStamp: profileContactReadStamp
            )
            if !loaded.conversations.isEmpty {
                // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_BEGIN: keep cached restore mapping off MainActor; publish/store mutations stay below.
                let safeCachedConversations = await CachedConversationRestoreBuilder.scrubbedModelsPreparedForLocalHistoryProjectionOffMain(
                    from: loaded.conversations
                )
                guard generation == localMessageSessionGeneration,
                      isCurrentRemoteScope(scope) else {
                    return false
                }
                // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_END
                let visibleCachedConversations = visibleConversationsAfterLocalHiding(
                    safeCachedConversations,
                    scope: scope
                )
                _ = conversationStore.hydrateCachedConversations(visibleCachedConversations)
                refreshDirectConversationDisplayNames()
                pruneNonFriendDirectConversations()
                syncAttachmentFilesFromConversations(visibleCachedConversations)
                hasLoadedRemoteSnapshot = true
                isInitialDataLoading = false
                syncFailureMessage = nil
                await recoverDurableOutbox(ticket: loaded.ticket, scope: scope)
                await reconcileDurableReadAckProjection(ticket: loaded.ticket, scope: scope)
                scheduleDurableReadAckRecovery(ticket: loaded.ticket, runImmediately: true)
                if loaded.pendingOutbox.isEmpty {
                    scheduleDurableOutboxRecovery(ticket: loaded.ticket)
                }
                return true
            }
        } catch {
            localMessageTicket = nil
        }

        guard let loaded = await messageStore.load(scope: scope) else { return false }
        guard isCurrentRemoteScope(scope) else {
            print("[JHT Perf] cached_snapshot_drop reason=stale_scope scope=\(Self.sessionScopeLogToken(scope))")
            return false
        }
        // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_BEGIN: keep legacy cached restore mapping off MainActor; publish/store mutations stay below.
        let safeCachedConversations = await CachedConversationRestoreBuilder.scrubbedConversationsPreparedForLocalHistoryProjectionOffMain(
            loaded.conversations
        )
        guard isCurrentRemoteScope(scope) else {
            print("[JHT Perf] cached_snapshot_drop reason=stale_scope_after_restore scope=\(Self.sessionScopeLogToken(scope))")
            return false
        }
        // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_END
        let visibleCachedConversations = visibleConversationsAfterLocalHiding(
            safeCachedConversations,
            scope: scope
        )
        let cachedConversationCount = conversationStore.hydrateCachedConversations(visibleCachedConversations)
        syncAttachmentFilesFromConversations(visibleCachedConversations)
        hasLoadedRemoteSnapshot = true
        isInitialDataLoading = false
        syncFailureMessage = nil
        if let ticket = localMessageTicket,
           generation == localMessageSessionGeneration {
            let snapshots = LegacySnapshotImporter.snapshots(
                from: visibleCachedConversations,
                channelResolver: { conversation in
                    (
                        self.remoteChannelID(for: conversation),
                        self.apiChannelType(for: conversation.kind)
                    )
                },
                currentActorID: context.imUID ?? ""
            )
            let revision = nextLocalMessageProjectionRevision()
            do {
                let imported = try await messagePersistence.importLegacy(
                    ticket: ticket,
                    snapshots: snapshots,
                    revision: revision
                )
                guard imported,
                      generation == localMessageSessionGeneration,
                      isCurrentRemoteScope(scope) else { return true }
                messageStore.remove(scope: scope)
            } catch {
                // Keep the legacy snapshot intact. Online authority will rebuild the database.
            }
        }
        print("[JHT Perf] cached_snapshot_applied count=\(cachedConversationCount) scope=\(Self.sessionScopeLogToken(scope)) read_ms=\(loaded.readMs) decode_ms=\(loaded.decodeMs) map_sort_ms=\(loaded.mapSortMs)")
        return true
    }

    func recoverDurableOutbox(
        ticket: LocalMessageSessionTicket,
        scope: String
    ) async {
        guard isCurrentRemoteScope(scope), localMessageTicket == ticket else { return }
        let items: [LocalMessageRecoveredOutbox]
        do {
            items = try await messagePersistence.claimOutboxForReplay(
                ticket: ticket,
                authorizationGeneration: ticket.sessionGeneration,
                trigger: .automatic,
                clientMessageID: nil,
                limit: 20
            )
        } catch {
            return
        }
        guard isCurrentRemoteScope(scope), localMessageTicket?.scopeHash == ticket.scopeHash else { return }
        for item in items {
            guard isCurrentRemoteScope(scope) else { continue }
            let message = item.message.model
            if conversationStore.conversation(id: item.conversationID)?
                .messages.contains(where: { $0.id == item.clientMessageID }) != true {
                _ = conversationStore.appendLocalOutgoingMessage(
                    message,
                    to: item.conversationID
                )
            }
            if message.kind == .image || message.kind == .file || message.kind == .voice {
                do {
                    let data: Data?
                    let fileURL: URL?
                    if message.kind == .voice {
                        data = try await messagePersistence.loadStagedAttachment(
                            ticket: ticket,
                            item: item
                        )
                        fileURL = nil
                    } else {
                        data = nil
                        fileURL = try await messagePersistence.stagedAttachmentFileURL(
                            ticket: ticket,
                            item: item
                        )
                    }
                    guard data != nil || fileURL != nil else {
                        throw LocalMessageDatabaseError.missingStagedAttachment
                    }
                    let durationMS = message.attachmentDurationSeconds.map {
                        Int(($0 * 1_000).rounded())
                    }
                    fileStore.rememberPendingAttachmentUpload(
                        PendingAttachmentUpload(
                            kind: message.kind,
                            name: item.attachmentFileName ?? message.attachmentName ?? message.text,
                            mimeType: item.attachmentMimeType ?? attachmentMimeType(from: message),
                            sizeBytes: item.attachmentSizeBytes ?? data.map { Int64($0.count) } ?? 0,
                            data: data,
                            fileURL: fileURL,
                            conversationID: item.conversationID,
                            quote: message.quote,
                            replyContext: message.replyContext,
                            voiceDurationMS: durationMS,
                            voiceWaveform: message.voiceWaveform,
                            onPolicyRejected: nil
                        ),
                        messageID: item.clientMessageID
                    )
                    restoreRecoveredAttachmentCheckpoint(item, message: message)
                    _ = startAttachmentUploadTask(
                        messageID: item.clientMessageID,
                        in: item.conversationID
                    )
                } catch {
                    markMessageFailed(messageID: item.clientMessageID, in: item.conversationID)
                    await updateDurableOutbox(
                        ticket: ticket,
                        messageID: item.clientMessageID,
                        state: .retryWait
                    )
                }
            } else {
                markMessageFailed(messageID: item.clientMessageID, in: item.conversationID)
                resendClaimed(
                    messageID: item.clientMessageID,
                    in: item.conversationID,
                    durableTicket: ticket
                )
            }
        }
    }

    private func restoreRecoveredAttachmentCheckpoint(
        _ item: LocalMessageRecoveredOutbox,
        message: ChatMessage
    ) {
        let fileID = (item.attachmentFileID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else { return }
        switch (item.attachmentPhase ?? "").lowercased() {
        case "uploaded":
            fileStore.recordAttachmentUploadPUTCompleted(
                messageID: item.clientMessageID,
                fileID: fileID
            )
        case "finalized", "message_send":
            if let file = uploadedFileMetadata(from: message, fileIDOverride: fileID) {
                fileStore.recordAttachmentUploadFinalized(
                    messageID: item.clientMessageID,
                    file: file
                )
            }
        default:
            break
        }
    }

    func recoverCachedDurableOutboxForTesting() async -> Bool {
        await applyCachedRemoteSnapshotIfAvailable(context: apiContext)
    }

    func scheduleConversationSnapshotCacheWrite(
        conversationID: String,
        scope: String,
        source: LocalMessageProjectionSource = .localMutation
    ) {
        guard isCurrentRemoteScope(scope),
              let conversation = conversationStore.conversation(id: conversationID) else { return }
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：单会话本地变更快照投影放到后台，AppState 保留状态入口
        let cacheableConversation = shouldShowGroupMemberCount
            ? conversation
            : conversation.scrubbingGroupMemberTotals()
        let input = localMessageProjectionInput(from: cacheableConversation)
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleLocalMessageProjectionWrite(
            scope: scope,
            source: source,
            projectionInputs: [input],
            actorID: actorID,
            localMutationWindowed: true,
            replaceMissingConversations: false
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束
    }

    func persistConversationSnapshotImmediately(
        conversationID: String,
        scope: String,
        source: LocalMessageProjectionSource
    ) async {
        guard isCurrentRemoteScope(scope),
              let conversation = conversationStore.conversation(id: conversationID) else { return }
        let cacheableConversation = shouldShowGroupMemberCount
            ? conversation
            : conversation.scrubbingGroupMemberTotals()
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let context = apiContext
        let generation = localMessageSessionGeneration
        let revision = nextLocalMessageProjectionRevision()
        let existingTicket = localMessageTicket
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：立即持久化前的消息投影在后台生成，避免长消息会话卡住 MainActor
        let snapshot = await LocalMessageProjectionBuilder.snapshotOffMain(
            from: localMessageProjectionInput(
                from: cacheableConversation,
                projectedMessages: cacheableConversation.messages
            ),
            actorID: actorID
        )
        guard generation == localMessageSessionGeneration,
              isCurrentRemoteScope(scope) else { return }
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束
        do {
            let ticket: LocalMessageSessionTicket
            if let existingTicket {
                ticket = existingTicket
            } else {
                ticket = try await messagePersistence.ensureTicket(
                    context: context,
                    sessionGeneration: generation
                )
            }
            guard generation == localMessageSessionGeneration,
                  isCurrentRemoteScope(scope),
                  ticket.sessionGeneration == generation else { return }
            _ = try await messagePersistence.persist(
                ticket: ticket,
                snapshots: [snapshot],
                source: source,
                revision: revision,
                replaceMissingConversations: false
            )
            guard generation == localMessageSessionGeneration,
                  isCurrentRemoteScope(scope) else { return }
            localMessageTicket = ticket
        } catch {
            // The online source remains authoritative. A later projection write retries persistence.
        }
    }

    func scheduleLocalMutationSnapshotCacheWriteForVisibleConversations(scope: String) {
        guard isCurrentRemoteScope(scope) else { return }
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：全部可见会话本地变更快照投影延后到后台任务
        let cacheableConversations = shouldShowGroupMemberCount
            ? conversations
            : conversations.map { $0.scrubbingGroupMemberTotals() }
        let inputs = cacheableConversations.map { conversation in
            localMessageProjectionInput(from: conversation)
        }
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleLocalMessageProjectionWrite(
            scope: scope,
            source: .localMutation,
            projectionInputs: inputs,
            actorID: actorID,
            localMutationWindowed: true,
            replaceMissingConversations: false
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束
    }

    func scheduleRemoteSnapshotCacheWrite(
        scope: String,
        source: LocalMessageProjectionSource = .localMutation,
        replaceMissingConversations: Bool = false
    ) {
        guard isCurrentRemoteScope(scope),
              !conversations.isEmpty || replaceMissingConversations else { return }
        let cacheableConversations = shouldShowGroupMemberCount
            ? conversations
            : conversations.map { $0.scrubbingGroupMemberTotals() }
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：远端快照缓存写入前的批量投影放到后台
        let inputs = cacheableConversations.map { conversation in
            localMessageProjectionInput(from: conversation)
        }
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleLocalMessageProjectionWrite(
            scope: scope,
            source: source,
            projectionInputs: inputs,
            actorID: actorID,
            replaceMissingConversations: replaceMissingConversations
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束
    }

    private func scheduleLocalMessageProjectionWrite(
        scope: String,
        source: LocalMessageProjectionSource,
        snapshots: [LocalMessageConversationSnapshot],
        replaceMissingConversations: Bool
    ) {
        guard isCurrentRemoteScope(scope),
              !snapshots.isEmpty || replaceMissingConversations else { return }
        let context = apiContext
        let generation = localMessageSessionGeneration
        let revision = nextLocalMessageProjectionRevision()
        let existingTicket = localMessageTicket
        Task { [weak self] in
            guard let self else { return }
            do {
                let ticket: LocalMessageSessionTicket
                if let existingTicket {
                    ticket = existingTicket
                } else {
                    ticket = try await self.messagePersistence.ensureTicket(
                        context: context,
                        sessionGeneration: generation
                    )
                }
                guard generation == self.localMessageSessionGeneration,
                      self.isCurrentRemoteScope(scope) else { return }
                _ = try await self.messagePersistence.persist(
                    ticket: ticket,
                    snapshots: snapshots,
                    source: source,
                    revision: revision,
                    replaceMissingConversations: replaceMissingConversations
                )
                guard generation == self.localMessageSessionGeneration,
                      self.isCurrentRemoteScope(scope) else { return }
                self.localMessageTicket = ticket
            } catch {
                // The online server remains authoritative; a later sync can retry persistence.
            }
        }
    }

    // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：快照投影可先在后台完成，再复用原有持久化流程
    private func scheduleLocalMessageProjectionWrite(
        scope: String,
        source: LocalMessageProjectionSource,
        projectionInputs: [LocalMessageProjectionInput],
        actorID: String,
        localMutationWindowed: Bool = false,
        requiresServerRevalidation: Bool = false,
        replaceMissingConversations: Bool
    ) {
        guard isCurrentRemoteScope(scope),
              !projectionInputs.isEmpty || replaceMissingConversations else { return }
        let context = apiContext
        let generation = localMessageSessionGeneration
        let revision = nextLocalMessageProjectionRevision()
        let existingTicket = localMessageTicket
        Task { [weak self, projectionInputs, actorID] in
            let snapshots: [LocalMessageConversationSnapshot]
            if localMutationWindowed {
                snapshots = await LocalMessageProjectionBuilder.localMutationSnapshotsOffMain(
                    from: projectionInputs,
                    actorID: actorID
                )
            } else {
                snapshots = await LocalMessageProjectionBuilder.snapshotsOffMain(
                    from: projectionInputs,
                    actorID: actorID,
                    requiresServerRevalidation: requiresServerRevalidation
                )
            }
            guard let self else { return }
            guard generation == self.localMessageSessionGeneration,
                  self.isCurrentRemoteScope(scope),
                  !snapshots.isEmpty || replaceMissingConversations else { return }
            do {
                let ticket: LocalMessageSessionTicket
                if let existingTicket {
                    ticket = existingTicket
                } else {
                    ticket = try await self.messagePersistence.ensureTicket(
                        context: context,
                        sessionGeneration: generation
                    )
                }
                guard generation == self.localMessageSessionGeneration,
                      self.isCurrentRemoteScope(scope) else { return }
                _ = try await self.messagePersistence.persist(
                    ticket: ticket,
                    snapshots: snapshots,
                    source: source,
                    revision: revision,
                    replaceMissingConversations: replaceMissingConversations
                )
                guard generation == self.localMessageSessionGeneration,
                      self.isCurrentRemoteScope(scope) else { return }
                self.localMessageTicket = ticket
            } catch {
                // The online server remains authoritative; a later sync can retry persistence.
            }
        }
    }
    // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束

    func userFacingError(_ error: Error) -> String {
        if DeviceRevocationDetector.matches(error: error) {
            return DeviceRevocationDetector.logoutMessage
        }
        if let securityInfo = securityBlockedInfo(from: error) {
            return securityInfo.userMessage
        }
        if let mutedMessage = sendPolicyMutedMessage(from: error) {
            return mutedMessage
        }
        if let quotaMessage = licenseQuotaUserMessage(from: error) {
            return quotaMessage
        }
        if let code = workspaceAccessCode(from: error) {
            return workspaceAccessMessage(for: code)
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .missingContext(_):
                return "缺少登录会话，请重新登录"
            case .badURL(_):
                return "接口地址配置错误"
            case .unauthorized(_):
                return "登录已失效，请重新登录"
            case .forcedAuthRequired(let requirement):
                return requirement.promptMessage
            case .securityBlocked(let info):
                return info.userMessage
            case .forbidden(let message):
                if message.contains("account_locked") || message.contains("账号已锁定") {
                    return "账号已锁定，请联系商户后台管理员解锁"
                }
                if message.contains("blocked_by_me") {
                    return "你已拉黑对方，无法发送消息"
                }
                if message.contains("blocked_by_target") || message.contains("message_rejected_by_target") || message.contains("消息拒收") {
                    return "消息已被对方拒收"
                }
                if message.contains("workspace_identity_unlinked") {
                    return "当前 IM 用户未绑定平台账号，暂不能切换或加入企业"
                }
                if message.contains("account_disabled") || message.contains("账号已停用") {
                    return "账号已停用，请联系管理员"
                }
                if message.contains("tenant_member_disabled") || message.contains("成员已停用") {
                    return "当前企业成员关系已停用，请切换其他企业"
                }
                if isGroupMemberNotFoundMessage(message) {
                    return groupMemberNotFoundText
                }
                if message.contains("tenant_member_not_found") {
                    return "当前企业成员关系不存在，请切换其他企业"
                }
                if message.contains("tenant_service_stopped") || message.contains("企业已停用") {
                    return "当前企业已停用，请切换其他企业"
                }
                if message.contains("tenant_service_unavailable") || message.contains("企业服务暂不可用") {
                    return "当前企业服务暂不可用，请切换其他企业或稍后重试"
                }
                if let groupLifecycleMessage = Self.groupLifecycleUserMessage(for: message) {
                    return groupLifecycleMessage
                }
                if isMessagePinForbiddenMessage(message) {
                    return messagePinForbiddenText
                }
                if let storageMessage = storageFailureMessage(from: message) {
                    return storageMessage
                }
                return sanitizeBackendMessage(message, fallback: "无权限执行该操作")
            case .businessForbidden(let code, let message, _):
                let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch normalizedCode {
                case "phone_auth_disabled":
                    return PhoneAuthPresentationPolicy.disabledMessage
                case "group_member_muted":
                    return Self.groupMemberMutedMessage
                case "group_mute_permission_denied":
                    return "禁言名单仅群主或管理员可操作"
                case "group_mute_target_role_not_allowed":
                    return "群主或管理员不能加入禁言名单"
                case "friend_application_cancel_forbidden":
                    return "仅申请发起者可取消该好友申请"
                case "group_owner_transfer_forbidden":
                    return "仅当前群主可以转让群主"
                case "workspace_switch_disabled":
                    return "管理员已关闭企业切换"
                case "tenant_code_required":
                    return "请输入企业编码或邀请码"
                case "entry_code_invalid":
                    return "请输入有效的企业编码或邀请码"
                case "tenant_code_not_found":
                    return "该企业不存在"
                case "identity_prefix_conflict", "enterprise_code_conflict":
                    return "企业身份编码发生冲突，请联系平台管理员"
                case "identity_prefix_locked":
                    return "企业身份前缀已锁定，请联系平台管理员"
                case "user_id_namespace_exhausted", "user_id_idempotency_conflict":
                    return "用户身份暂无法分配，请稍后重试或联系管理员"
                case "member_invite_code_generation_exhausted":
                    return "邀请码暂无法生成，请稍后重试或联系管理员"
                case "member_invite_code_invalid",
                     "member_invite_code_disabled",
                     "member_invite_code_inviter_inactive",
                     "member_invite_code_role_not_allowed",
                     "member_invite_code_app_not_bound":
                    return "邀请码无效或已停用"
                case "member_invite_code_sync_pending",
                     "member_invite_code_sync_unavailable",
                     "member_invite_code_tenant_unavailable",
                     "member_invite_code_unavailable":
                    return "邀请码暂不可用于注册"
                case "member_invite_code_tenant_conflict":
                    return "邀请码和企业不匹配"
                case "registration_tenant_code_probe_rate_limited":
                    return "企业编码或邀请码验证次数过多，请稍后再试"
                case "registered_user_quota_exceeded",
                     "online_quota_exceeded",
                     "online_quota_service_unavailable",
                     "group_member_quota_exceeded":
                    return IMAPIClient.licenseQuotaUserMessage(for: normalizedCode)
                default:
                    break
                }
                if let capabilityMessage = capabilityUserMessage(for: normalizedCode) {
                    return capabilityMessage
                }
                if let groupLifecycleMessage = Self.groupLifecycleUserMessage(for: "\(normalizedCode) \(message)") {
                    return groupLifecycleMessage
                }
                if isGroupMemberNotFoundMessage("\(normalizedCode) \(message)") {
                    return groupMemberNotFoundText
                }
                if let accessCode = workspaceAccessCode(from: normalizedCode) {
                    return workspaceAccessMessage(for: accessCode)
                }
                if let storageMessage = storageFailureMessage(from: message) {
                    return storageMessage
                }
                return sanitizeBackendMessage(message, fallback: "无权限执行该操作")
            case .conflict(let code, let message):
                switch code {
                case "workspace_join_pending":
                    return "入企申请等待审批中"
                case "workspace_join_rejected":
                    return "入企申请已被拒绝，请联系企业管理员"
                case "workspace_join_approved":
                    return "入企申请已通过"
                case "workspace_already_joined":
                    return "已加入该企业"
                case "workspace_join_forbidden":
                    return "当前账号暂不能申请加入该企业"
                case "workspace_tenant_unresolved":
                    return "企业信息暂未同步，请稍后重试"
                case "workspace_directory_unavailable":
                    return "企业目录暂不可用，请稍后重试"
                case "workspace_join_conflict":
                    return "入企申请状态冲突，请刷新后重试"
                case "workspace_join_bad_request", "bad_workspace_join_request":
                    return "入企申请参数不正确，请重新搜索后再试"
                case "workspace_switch_failed":
                    return "企业存在，但切换失败"
                case "workspace_switch_disabled":
                    return "管理员已关闭企业切换"
                case "tenant_code_required":
                    return "请输入企业编码或邀请码"
                case "entry_code_invalid":
                    return "请输入有效的企业编码或邀请码"
                case "tenant_code_not_found":
                    return "该企业不存在"
                case "identity_prefix_conflict", "enterprise_code_conflict":
                    return "企业身份编码发生冲突，请联系平台管理员"
                case "identity_prefix_locked":
                    return "企业身份前缀已锁定，请联系平台管理员"
                case "user_id_namespace_exhausted", "user_id_idempotency_conflict":
                    return "用户身份暂无法分配，请稍后重试或联系管理员"
                case "member_invite_code_generation_exhausted":
                    return "邀请码暂无法生成，请稍后重试或联系管理员"
                case "member_invite_code_invalid",
                     "member_invite_code_disabled",
                     "member_invite_code_inviter_inactive",
                     "member_invite_code_role_not_allowed",
                     "member_invite_code_app_not_bound":
                    return "邀请码无效或已停用"
                case "member_invite_code_sync_pending",
                     "member_invite_code_sync_unavailable",
                     "member_invite_code_tenant_unavailable",
                     "member_invite_code_unavailable":
                    return "邀请码暂不可用于注册"
                case "member_invite_code_tenant_conflict":
                    return "邀请码和企业不匹配"
                case "registration_tenant_code_probe_rate_limited":
                    return "企业编码或邀请码验证次数过多，请稍后再试"
                case "enterprise_code_search_rate_limited", "tenant_code_search_rate_limited":
                    return "搜索次数过多请晚点再试"
                case "client_registration_rate_limited":
                    return "注册用户今日已达上限"
                case "rate_limit_unavailable":
                    return "服务繁忙，请稍后重试"
                case "default_tenant_not_configured":
                    return "默认商户未配置，请联系管理员"
                case "default_tenant_unavailable":
                    return "默认商户不可用，请联系管理员"
                case "registered_user_quota_exceeded",
                     "online_quota_exceeded",
                     "online_quota_service_unavailable",
                     "group_member_quota_exceeded":
                    return IMAPIClient.licenseQuotaUserMessage(for: code)
                case "user_account_locked":
                    return "用户账号已设置，如需修改请联系管理员/商户后台处理。"
                case "invalid_user_account_format", "invalid_account_format":
                    return "账号必须为 5-10 位数字或英文字母"
                case "invalid_avatar":
                    return "头像格式或尺寸不符合要求，请重新选择图片"
                case "file_not_uploaded":
                    return "文件还未上传完成，请重新上传后再试"
                case "file_not_found":
                    return "文件不存在或已被清理"
                case "file_too_large", "file_size_exceeded":
                    return "文件超过大小限制，请压缩后重试"
                case "file_unavailable":
                    return "文件不可用或无权限访问"
                case "validation_error":
                    return "请求参数不正确，请检查后重试"
                case "avatar_url_unavailable":
                    return "头像地址暂不可用，请稍后重试"
                case "tenant_storage_not_configured":
                    return "企业暂未配置文件存储，请联系管理员"
                case "tenant_storage_resource_unavailable":
                    return "企业存储资源暂不可用，请联系管理员"
                case "tenant_storage_provider_unsupported":
                    return "当前存储服务暂不支持上传"
                case "tenant_storage_secret_unresolved":
                    return "企业存储配置未生效，请联系管理员"
                case "group_not_found", "group_member_not_found", "group_already_dissolved":
                    return "该群聊不存在或已解散"
                case "group_owner_cannot_leave":
                    return "群主需先转让群主或解散该群"
                case "permission_denied":
                    return "只有群主可以解散该群"
                case "confirmation_required":
                    return "请确认后再解散该群"
                case "invalid_confirmation":
                    return "请确认后再解散该群"
                case "group_dissolve_in_progress":
                    return "群聊正在解散中，请稍后"
                case "group_join_request_not_found":
                    return "入群申请不存在或已失效"
                case "group_unavailable":
                    return "群聊不可用"
                case "group_join_forbidden":
                    return "无权限处理该入群申请"
                case "admin_delete_forbidden", "message_admin_delete_forbidden":
                    return "无权限删除该消息"
                case "message_not_found", "message_not_visible", "message_invisible":
                    return "消息不存在或已不可见"
                case "message_already_deleted":
                    return "该消息已删除"
                case "target_user_not_found":
                    return "目标用户不存在"
                case "target_user_unavailable":
                    return "目标用户状态不可用"
                case "bad_group_join_request":
                    return "入群申请参数不正确"
                case "group_join_conflict":
                    return "入群申请状态冲突，请刷新后重试"
                case "friend_application_terminal":
                    return "好友申请状态已变化，请查看最新状态"
                case "group_owner_transfer_conflict":
                    return "群主状态已变化，请刷新后重试"
                case "group_announcement_revision_conflict":
                    return "公告已被其他管理员更新，请核对后重试"
                case "group_invite_already_processed", "already_processed":
                    return "该入群邀请已处理"
                case "rtc_media_config_missing", "rtc_ice_config_missing", "rtc_turn_config_missing":
                    return rtcCapabilityFailureMessage(code: code, media: .generic)
                        ?? "通话媒体服务配置缺失，请联系管理员"
                case "rtc_video_not_supported":
                    return "当前仅支持语音通话"
                case "rtc_group_call_not_supported":
                    return "暂不支持群语音通话"
                case "duplicate_call":
                    return "已有进行中的语音呼叫，请勿重复发起"
                case "caller_busy":
                    return "你正在通话中，请结束后再试"
                case "callee_busy":
                    return "对方正在通话中"
                case "rtc_call_not_found":
                    return "通话不存在或已结束"
                case "rtc_call_forbidden":
                    return "无权限操作该通话"
                case "rtc_call_not_ringing":
                    return "该通话已不在待接听状态"
                case "rtc_call_not_active":
                    return "该通话已结束"
                case "message_recall_window_exceeded":
                    return "已超过当前企业最长时间"
                case "voice_call_not_enabled", "video_call_not_enabled", "rtc_license_capabilities_unavailable":
                    return rtcCapabilityFailureMessage(code: code, media: .generic) ?? "当前企业未开通通话"
                case "read_receipts_not_enabled":
                    return "当前企业未开通"
                case "feature_not_enabled", "group_admin_delete_message_not_enabled":
                    return "当前企业未开通"
                case "mention_all_forbidden":
                    return "仅群主或管理员可以 @所有人"
                case "message_pin_forbidden":
                    return messagePinForbiddenText
                case "message_forward_unsupported":
                    return "该消息类型暂不支持转发"
                case "request_identity_mismatch":
                    return "当前登录身份与请求不匹配，请重新登录后再试"
                case "captcha_config_missing",
                     "captcha_scene_disabled",
                     "captcha_scene_not_enabled",
                     "captcha_channel_unavailable",
                     "tenant_not_found",
                     "sms_provider_not_configured",
                     "invalid_sms_template",
                     "captcha_scene_required",
                     "invalid_captcha_channel",
                     "rate_limited",
                     "captcha_request_rate_limited",
                     "captcha_request_cooldown",
                     "invalid_captcha_request_limit",
                     "invalid_captcha_cooldown",
                     "captcha_invalid",
                     "captcha_expired",
                     "slide_captcha_required",
                     "slide_captcha_invalid",
                     "token_sign_failed":
                    return captchaUserMessage(code: code, reason: message, fallback: "验证码服务暂不可用")
                case "conflict":
                    return registrationConflictMessage(message)
                default:
                    return sanitizeBackendMessage(message, fallback: "操作冲突，请刷新后重试")
                }
            case .loginSecurity(let code, let message, let info):
                return loginSecurityMessage(code: code, message: message, info: info)
            case .server(let message):
                if let groupLifecycleMessage = Self.groupLifecycleUserMessage(for: message) {
                    return groupLifecycleMessage
                }
                if let storageMessage = storageFailureMessage(from: message) {
                    return storageMessage
                }
                if message.localizedCaseInsensitiveContains("invalid username or password")
                    || message.localizedCaseInsensitiveContains("unauthorized") {
                    return "账号或密码错误"
                }
                return sanitizeBackendMessage(message, fallback: "服务暂不可用，请稍后重试")
            case .httpStatus(_, let message):
                return sanitizeBackendMessage(message, fallback: "服务暂不可用，请稍后重试")
            case .rateLimited(let code, let message, let retryAfterSeconds, let lockedUntil):
                if code == "login_locked" {
                    return loginLockedMessage(retryAfterSeconds: retryAfterSeconds, lockedUntil: lockedUntil)
                }
                if code == "enterprise_code_search_rate_limited" || code == "tenant_code_search_rate_limited" {
                    return "搜索次数过多请晚点再试"
                }
                if code == "registration_tenant_code_probe_rate_limited" {
                    return "企业编码或邀请码验证次数过多，请稍后再试"
                }
                if code == "client_registration_rate_limited" {
                    return "注册用户今日已达上限"
                }
                if code == "rate_limit_unavailable" {
                    return "服务繁忙，请稍后重试"
                }
                if code == "rate_limited"
                    || code == "captcha_request_cooldown"
                    || code == "captcha_request_rate_limited"
                    || code == "invalid_captcha_request_limit"
                    || code == "invalid_captcha_cooldown" {
                    return captchaUserMessage(code: code, reason: message, fallback: "验证码请求过于频繁，请稍后再试")
                }
                return sanitizeBackendMessage(message, fallback: "操作过于频繁，请稍后再试")
            case .emptyResponse:
                return "接口没有返回有效数据"
            }
        }
        if let localizedDescription = (error as? LocalizedError)?.errorDescription,
           !localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return BackendUserMessageSanitizer.sanitize(
                localizedDescription,
                fallback: "网络或服务不可用，请稍后重试"
            )
        }
        return "网络或服务不可用，请稍后重试"
    }

    func capabilityUserMessage(for code: String) -> String? {
        if let rtcMessage = rtcCapabilityFailureMessage(code: code, media: .generic) {
            return rtcMessage
        }
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "message_recall_window_exceeded":
            return "已超过当前企业最长时间"
        case "voice_call_not_enabled", "read_receipts_not_enabled", "feature_not_enabled", "group_admin_delete_message_not_enabled":
            return "当前企业未开通"
        default:
            return nil
        }
    }

    static func groupLifecycleUserMessage(for value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("group_owner_cannot_leave") {
            return "群主需先转让群主或解散该群"
        }
        if normalized.contains("permission_denied") {
            return "只有群主可以解散该群"
        }
        if normalized.contains("confirmation_required") || normalized.contains("invalid_confirmation") {
            return "请确认后再解散该群"
        }
        if normalized.contains("group_already_dissolved")
            || normalized.contains("group_not_found")
            || normalized.contains("group_member_not_found") {
            return "该群聊不存在或已解散"
        }
        if normalized.contains("group_dissolve_in_progress") {
            return "群聊正在解散中，请稍后"
        }
        if normalized.contains("group_unavailable") {
            return "群聊不可用"
        }
        return nil
    }

    func capabilityUserMessage(
        from error: Error,
        rtcMedia: RTCCapabilityMedia = .generic
    ) -> String? {
        guard let apiError = error as? IMAPIError else { return nil }
        switch apiError {
        case .conflict(let code, _), .businessForbidden(let code, _, _), .loginSecurity(let code, _, _), .rateLimited(let code, _, _, _):
            return rtcCapabilityFailureMessage(code: code, media: rtcMedia)
                ?? capabilityUserMessage(for: code)
        case .forbidden(let message), .httpStatus(_, let message), .server(let message), .unauthorized(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for code in ["rtc_license_capabilities_unavailable", "rtc_media_config_missing", "rtc_ice_config_missing", "rtc_turn_config_missing", "voice_call_not_enabled", "video_call_not_enabled", "message_recall_window_exceeded", "read_receipts_not_enabled", "feature_not_enabled", "group_admin_delete_message_not_enabled"] {
                if normalized.contains(code),
                   let userMessage = rtcCapabilityFailureMessage(code: code, media: rtcMedia)
                    ?? capabilityUserMessage(for: code) {
                    return userMessage
                }
            }
            return nil
        case .securityBlocked(_), .forcedAuthRequired(_), .missingContext(_), .badURL(_), .emptyResponse:
            return nil
        }
    }

    func requireRTCLicense(_ enabled: Bool?, media: RTCCapabilityMedia) throws {
        guard enabled != true else { return }
        let code = enabled == nil ? "rtc_license_capabilities_unavailable"
            : media == .video ? "video_call_not_enabled" : "voice_call_not_enabled"
        let error = IMAPIError.conflict(code: code, message: "")
        _ = presentRTCLicenseFailure(error, media: media)
        throw error
    }

    func currentRTCProviderForCall(context: IMAPIContext, attempt: DirectCallAttempt) async throws -> RemoteRTCProvider {
        // WDT_RTC_IOS1_AUTODROP_20260921_BEGIN: send provider checks with latest credentials for the same call owner.
        let requestContext = apiContext
        guard requestContext.hasIMSession,
              DirectCallContextBinding(context: requestContext) == attempt.context else {
            throw CancellationError()
        }
        // WDT_RTC_IOS1_AUTODROP_20260921_END
        return try await currentRTCProvider(
            context: requestContext,
            media: attempt.mediaMode == "audio" ? .voice : .video,
            isCurrent: { self.isCurrentDirectCallAttempt(attempt) }
        )
    }

    func currentRTCProvider(
        context: IMAPIContext,
        media: RTCCapabilityMedia,
        isCurrent: @MainActor () -> Bool
    ) async throws -> RemoteRTCProvider {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        do {
            let provider = try await api.rtcProvider(context: context)
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
            return provider
        } catch {
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
            _ = presentRTCLicenseFailure(error, media: media)
            // Preserve typed service/auth failures; transport failure is not a
            // trustworthy disabled license and must never reach media setup.
            if error is URLError {
                try requireRTCLicense(nil, media: media)
            }
            throw error
        }
    }

    @discardableResult
    func presentRTCLicenseFailure(_ error: Error, media: RTCCapabilityMedia) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        let code: String
        switch apiError {
        case .conflict(let value, _), .businessForbidden(let value, _, _),
             .loginSecurity(let value, _, _), .rateLimited(let value, _, _, _):
            code = value
        case .server(let value), .httpStatus(_, let value):
            code = value
        default:
            return false
        }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["voice_call_not_enabled", "video_call_not_enabled", "rtc_license_capabilities_unavailable"].contains(normalized),
              let message = rtcCapabilityFailureMessage(code: normalized, media: media) else { return false }
        rtcCapabilityAlertMessage = message
        return true
    }

    func licenseQuotaUserMessage(from error: Error) -> String? {
        guard let apiError = error as? IMAPIError else { return nil }
        switch apiError {
        case .businessForbidden(let code, let message, _),
             .conflict(let code, let message),
             .loginSecurity(let code, let message, _),
             .rateLimited(let code, let message, _, _):
            if let quotaCode = IMAPIClient.licenseQuotaErrorCode(code) {
                return IMAPIClient.licenseQuotaUserMessage(for: quotaCode)
            }
            return licenseQuotaUserMessage(from: message)
        case .forbidden(let message),
             .httpStatus(_, let message),
             .server(let message),
             .unauthorized(let message):
            return licenseQuotaUserMessage(from: message)
        case .securityBlocked(_), .forcedAuthRequired(_), .missingContext(_), .badURL(_), .emptyResponse:
            return nil
        }
    }

    func licenseQuotaUserMessage(from value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for code in [
            "registered_user_quota_exceeded",
            "online_quota_exceeded",
            "online_quota_service_unavailable",
            "group_member_quota_exceeded"
        ] {
            if normalized.contains(code) {
                return IMAPIClient.licenseQuotaUserMessage(for: code)
            }
        }
        return nil
    }

    func isCapabilityError(_ error: Error, code targetCode: String) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        let target = targetCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch apiError {
        case .conflict(let code, _), .loginSecurity(let code, _, _), .rateLimited(let code, _, _, _):
            return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        case .businessForbidden(let code, let message, _):
            let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedCode == target {
                return true
            }
            return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains(target)
        case .forbidden(let message), .httpStatus(_, let message), .server(let message), .unauthorized(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains(target)
        case .securityBlocked(_), .forcedAuthRequired(_), .missingContext(_), .badURL(_), .emptyResponse:
            return false
        }
    }

    private func registrationConflictMessage(_ message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("invalid_user_account_format") || lowered.contains("invalid_account_format") || lowered.contains("5-10") {
            return "账号必须为 5-10 位数字或英文字母"
        }
        if lowered.contains("username") || lowered.contains("account_username") {
            return "账号已存在，请更换账号后重试"
        }
        if lowered.contains("phone") || lowered.contains("account_phone") {
            return "手机号已注册，请直接登录或更换手机号"
        }
        return sanitizeBackendMessage(message, fallback: "账号或手机号已存在")
    }

    private func isAccountAlreadyRegisteredConflict(_ message: String) -> Bool {
        let lowered = message.lowercased()
        if lowered.contains("invalid_user_account_format") || lowered.contains("invalid_account_format") || lowered.contains("5-10") {
            return false
        }
        return lowered.contains("username")
            || lowered.contains("phone")
            || lowered.contains("platform_account")
            || lowered.contains("account_username")
            || lowered.contains("account_phone")
    }

    func sanitizeBackendMessage(_ message: String, fallback: String) -> String {
        Self.sanitizeBackendMessage(message, fallback: fallback)
    }

    private func storageFailureMessage(from message: String) -> String? {
        let lowered = message.lowercased()
        if lowered.contains("tenant_storage_not_configured") {
            return "企业暂未配置文件存储，请联系管理员"
        }
        if lowered.contains("tenant_storage_resource_unavailable") {
            return "企业存储资源暂不可用，请联系管理员"
        }
        if lowered.contains("tenant_storage_provider_unsupported") {
            return "当前存储服务暂不支持上传"
        }
        if lowered.contains("tenant_storage_secret_unresolved") || lowered.contains("secret_ref") {
            return "企业存储配置未生效，请联系管理员"
        }
        if lowered.contains("file_not_uploaded") {
            return "文件还未上传完成，请重新上传后再试"
        }
        if lowered.contains("file_not_found") {
            return "文件不存在或已被清理"
        }
        if lowered.contains("file_unavailable") {
            return "文件不可用或无权限访问"
        }
        if lowered.contains("file_size_exceeded") || lowered.contains("file_too_large") {
            return "文件超过大小限制，请压缩后重试"
        }
        if lowered.contains("validation_error") {
            return "请求参数不正确，请检查后重试"
        }
        return nil
    }

    static func sanitizeBackendMessage(_ message: String, fallback: String) -> String {
        BackendUserMessageSanitizer.sanitize(message, fallback: fallback)
    }

    func loginFailureMessage(_ error: Error) -> String {
        // JHT_MOD_BEGIN LOGIN_AUTH_DEPENDENCY_NO_FALLBACK_20260913 - 修改开始：登录依赖服务不可用展示固定文案
        if isAuthDependencyUnavailableError(error) {
            return "登录服务暂不可用，请稍后重试"
        }
        // JHT_MOD_END LOGIN_AUTH_DEPENDENCY_NO_FALLBACK_20260913 - 修改结束
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .securityBlocked(let info):
                return info.userMessage
            case .loginSecurity(let code, let message, let info):
                return loginSecurityMessage(code: code, message: message, info: info)
            case .rateLimited(let code, _, let retryAfterSeconds, let lockedUntil):
                if code == "login_locked" {
                    return loginLockedMessage(retryAfterSeconds: retryAfterSeconds, lockedUntil: lockedUntil)
                }
                if code == "ip_login_blocked" {
                    return ipLoginBlockedMessage(info: nil)
                }
                return "操作过于频繁，请稍后再试"
            case .unauthorized(let message):
                let lowered = message.lowercased()
                if lowered.contains("invalid_credentials")
                    || lowered.contains("invalid username or password")
                    || lowered.contains("unauthorized") {
                    return "账号或密码错误"
                }
            case .server(let message):
                let lowered = message.lowercased()
                if lowered.contains("login_locked") || lowered.contains("too many") || lowered.contains("rate limit") {
                    return "尝试次数过多，请稍后再试"
                }
                if lowered.contains("invalid username or password") || lowered.contains("unauthorized") {
                    return "账号或密码错误"
                }
            case .badURL(_):
                return "接口地址配置错误"
            default:
                break
            }
        }
        if error is URLError {
            return "登录失败，请检查账号信息或稍后重试"
        }
        return "登录失败，请检查账号信息或稍后重试"
    }

    private func loginSecurityMessage(code: String, message: String, info: RemoteLoginSecurityInfo?) -> String {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedCode {
        case "bad_request":
            return "请输入账号和密码"
        case "phone_auth_disabled":
            return PhoneAuthPresentationPolicy.disabledMessage
        case "slide_captcha_required":
            return "需要完成安全验证后再登录"
        case "slide_captcha_invalid":
            return "安全验证已失效，请重新验证后再登录"
        case "invalid_credentials":
            if let remaining = info?.remainingAttempts, let failed = info?.failedAttempts, failed >= 4 {
                return "账号或密码错误，还可尝试 \(max(0, remaining)) 次"
            }
            return "账号或密码错误"
        case "account_locked", "login_locked":
            return accountLockedMessage(info: info)
        case "account_blocked":
            return "账号因安全策略限制，暂不可登录"
        case "device_blocked":
            return "当前设备暂不可登录"
        case "ip_login_blocked":
            return ipLoginBlockedMessage(info: info)
        case "ip_blocked":
            return "当前网络暂不可登录"
        case "tenant_blocked":
            return "当前企业暂不可访问"
        case "security_policy_denied":
            return "操作被企业安全策略限制"
        case "security_blocked":
            return "访问已被安全策略限制"
        case "account_password_sync_failed":
            return "账号服务暂不可用，请稍后重试"
        case "account_disabled":
            return "账号已停用，请联系管理员"
        case "tenant_member_disabled":
            return "当前企业成员关系已停用，请切换其他企业"
        case "tenant_member_not_found":
            return "当前企业成员关系不存在，请切换其他企业"
        case "workspace_not_found":
            return "目标企业不存在，请返回企业列表重新选择"
        case "workspace_session_unavailable":
            return "当前企业服务暂不可用，请切换其他企业或稍后重试"
        case "workspace_join_forbidden":
            return "当前账号暂不能申请加入该企业"
        case "workspace_tenant_unresolved":
            return "企业信息暂未同步，请稍后重试"
        case "workspace_directory_unavailable":
            return "企业目录暂不可用，请稍后重试"
        case "workspace_join_conflict":
            return "入企申请状态冲突，请刷新后重试"
        case "workspace_join_bad_request", "bad_workspace_join_request":
            return "入企申请参数不正确，请重新搜索后再试"
        case "tenant_service_stopped":
            return "当前企业已停用，请切换其他企业"
        case "tenant_disabled":
            return "当前企业已停用，请切换其他企业"
        case "default_workspace_unavailable", "app_not_found":
            return "当前企业服务暂不可用，请切换其他企业或稍后重试"
        case "workspace_identity_unlinked":
            return "当前账号企业身份未同步，请联系管理员处理"
        case "default_tenant_not_configured":
            return "默认商户未配置，请联系管理员"
        case "default_tenant_unavailable":
            return "默认商户不可用，请联系管理员"
        case "ip_not_allowed":
            return "当前网络不在企业允许登录范围内"
        case "device_binding_required", "device_not_bound":
            return "当前设备未绑定，请联系管理员或按企业流程绑定设备"
        case "license_not_started":
            return "企业许可证未生效，请联系管理员"
        case "license_expired":
            return "企业许可证已过期，请联系管理员续费"
        case "license_inactive":
            return "企业许可证不可用，请联系管理员"
        case "online_quota_exceeded":
            return "企业在线人数已达上限，请稍后再试"
        default:
            return sanitizeBackendMessage(message, fallback: "登录失败，请检查账号信息或稍后重试")
        }
    }

    private func accountLockedMessage(info: RemoteLoginSecurityInfo?) -> String {
        if info?.locked == true || info?.remainingAttempts == 0 {
            return "账号已锁定，请联系商户后台管理员解锁"
        }
        return "账号已锁定，请联系管理员解锁"
    }

    private func ipLoginBlockedMessage(info: RemoteLoginSecurityInfo?) -> String {
        var message = "今日登录失败次数过多，当前网络已被禁止登录"
        let banUntil = info?.banUntil.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !banUntil.isEmpty {
            message += "，\(loginSecurityDateText(banUntil)) 后可再试"
        }
        if let lockedAccountCount = info?.lockedAccountCount, let threshold = info?.threshold, threshold > 0 {
            message += "（已触发 \(lockedAccountCount)/\(threshold) 个锁定账号）"
        }
        return message
    }

    private func loginSecurityDateText(_ raw: String) -> String {
        guard let date = parseRemoteDate(raw) else { return raw }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        out.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return out.string(from: date)
    }

    private func loginLockedMessage(retryAfterSeconds: Int?, lockedUntil: String?) -> String {
        let secondsFromLockedUntil: Int? = lockedUntil
            .flatMap(parseRemoteDate)
            .map { max(0, Int(ceil($0.timeIntervalSinceNow))) }
        let seconds = retryAfterSeconds ?? secondsFromLockedUntil
        guard let seconds, seconds > 0 else {
            return "登录尝试过多，请稍后再试。账号已被临时保护锁定，请稍后再试"
        }
        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        return "登录尝试过多，请稍后再试。账号已被临时保护锁定，约 \(minutes) 分钟后再试"
    }

    private func syncFailureUserMessage(_ error: Error) -> String {
        if let securityInfo = securityBlockedInfo(from: error) {
            return securityInfo.userMessage
        }
        if let code = workspaceAccessCode(from: error) {
            return workspaceAccessMessage(for: code)
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .unauthorized(_):
                return "登录状态已失效，请重新登录"
            case .forbidden(_):
                return "当前账号无权访问该企业数据"
            case .badURL(_):
                return "登录成功，但聊天数据同步失败，请检查网络后重试"
            default:
                return "登录成功，但聊天数据同步失败，请检查网络后重试"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "网络连接异常，正在重试同步"
            default:
                return "登录成功，但聊天数据同步失败，请检查网络后重试"
            }
        }
        return "登录成功，但聊天数据同步失败，请检查网络后重试"
    }

    func workspaceAccessCode(from error: Error) -> String? {
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .securityBlocked(_):
                return "security_blocked"
            case .forbidden(let message), .server(let message):
                return workspaceAccessCode(from: message)
            case .businessForbidden(let code, let message, _):
                return workspaceAccessCode(from: "\(code) \(message)")
            case .conflict(let code, let message):
                return workspaceAccessCode(from: "\(code) \(message)")
            case .loginSecurity(let code, let message, _):
                return workspaceAccessCode(from: "\(code) \(message)")
            case .rateLimited(let code, let message, _, _):
                return workspaceAccessCode(from: "\(code) \(message)")
            default:
                break
            }
        }
        return workspaceAccessCode(from: String(describing: error))
    }

    func workspaceAccessCode(from raw: String) -> String? {
        workspaceAccessCodeFromRaw(raw)
    }

    private func workspaceAccessCodeFromRaw(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        let normalized = raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        if lowered.contains("workspace_switch_disabled")
            || normalized.contains("workspaceswitchdisabled")
            || raw.contains("关闭企业切换") {
            return "workspace_switch_disabled"
        }
        if lowered.contains("account_locked") || normalized.contains("accountlocked") || raw.contains("账号已锁定") {
            return "account_locked"
        }
        if lowered.contains("account_blocked") || normalized.contains("accountblocked") {
            return "account_blocked"
        }
        if lowered.contains("account_disabled") || normalized.contains("accountdisabled") || raw.contains("账号已停用") {
            return "account_disabled"
        }
        if lowered.contains("device_blocked") || normalized.contains("deviceblocked") {
            return "device_blocked"
        }
        if lowered.contains("ip_login_blocked")
            || normalized.contains("iploginblocked")
            || raw.contains("网络已被禁止登录") {
            return "ip_login_blocked"
        }
        if lowered.contains("ip_not_allowed")
            || normalized.contains("ipnotallowed")
            || raw.contains("不在企业允许登录范围") {
            return "ip_not_allowed"
        }
        if lowered.contains("ip_blocked") || normalized.contains("ipblocked") {
            return "ip_blocked"
        }
        if lowered.contains("account_password_sync_failed")
            || normalized.contains("accountpasswordsyncfailed")
            || raw.contains("账号服务暂不可用") {
            return "account_password_sync_failed"
        }
        if lowered.contains("slide_captcha_required")
            || normalized.contains("slidecaptcharequired")
            || raw.contains("需要完成安全验证") {
            return "slide_captcha_required"
        }
        if lowered.contains("invalid_credentials")
            || normalized.contains("invalidcredentials")
            || raw.contains("账号或密码错误") {
            return "invalid_credentials"
        }
        if lowered.contains("tenant_blocked") || normalized.contains("tenantblocked") {
            return "tenant_blocked"
        }
        if lowered.contains("security_policy_denied") || normalized.contains("securitypolicydenied") {
            return "security_policy_denied"
        }
        if lowered.contains("security_blocked") || normalized.contains("securityblocked") || raw.contains("安全策略限制") {
            return "security_blocked"
        }
        if lowered.contains("tenant_service_stopped")
            || lowered.contains("tenant_disabled")
            || normalized.contains("tenantservicestopped")
            || normalized.contains("tenantdisabled")
            || raw.contains("企业已停用") {
            return "tenant_service_stopped"
        }
        if lowered.contains("workspace_session_unavailable")
            || lowered.contains("tenant_service_unavailable")
            || lowered.contains("app_not_found")
            || lowered.contains("access_discovery_app_unavailable")
            || lowered.contains("default_workspace_unavailable")
            || normalized.contains("workspacesessionunavailable")
            || normalized.contains("tenantserviceunavailable")
            || normalized.contains("appnotfound")
            || normalized.contains("accessdiscoveryappunavailable")
            || normalized.contains("defaultworkspaceunavailable")
            || raw.contains("企业服务暂不可用")
            || raw.contains("企业应用不可用")
            || raw.contains("默认企业暂不可进入") {
            return "workspace_session_unavailable"
        }
        if lowered.contains("tenant_member_not_found")
            || normalized.contains("tenantmembernotfound")
            || raw.contains("企业成员不存在")
            || raw.contains("成员关系不存在") {
            return "tenant_member_not_found"
        }
        if lowered.contains("workspace_not_found")
            || lowered.contains("tenant_not_found")
            || lowered.contains("app_tenant_not_bound")
            || normalized.contains("workspacenotfound")
            || normalized.contains("tenantnotfound")
            || normalized.contains("apptenantnotbound")
            || raw.contains("目标企业不存在")
            || raw.contains("企业不存在") {
            return "workspace_not_found"
        }
        if lowered.contains("workspace_identity_unlinked")
            || normalized.contains("workspaceidentityunlinked")
            || raw.contains("企业身份未同步")
            || raw.contains("未绑定平台账号") {
            return "workspace_identity_unlinked"
        }
        if lowered.contains("member_projection_syncing")
            || lowered.contains("member_projection_pending")
            || lowered.contains("member_projection_missing")
            || lowered.contains("member_projection_stale")
            || lowered.contains("member_projection_sync")
            || normalized.contains("memberprojectionsyncing")
            || normalized.contains("memberprojectionpending")
            || normalized.contains("memberprojectionmissing")
            || normalized.contains("memberprojectionstale")
            || raw.contains("成员数据正在同步")
            || raw.contains("企业成员正在同步") {
            return "member_projection_syncing"
        }
        if lowered.contains("member_projection_failed")
            || lowered.contains("member_projection_conflict")
            || lowered.contains("member_projection_rejected")
            || normalized.contains("memberprojectionfailed")
            || normalized.contains("memberprojectionconflict")
            || normalized.contains("memberprojectionrejected")
            || raw.contains("成员数据同步失败")
            || raw.contains("企业成员同步失败") {
            return "member_projection_failed"
        }
        if lowered.contains("tenant_member_disabled")
            || lowered.contains("member_disabled")
            || normalized.contains("tenantmemberdisabled")
            || normalized.contains("memberdisabled")
            || raw.contains("成员已停用")
            || raw.contains("成员关系已停用") {
            return "tenant_member_disabled"
        }
        return nil
    }

    func workspaceAccessMessage(for code: String) -> String {
        switch code {
        case "workspace_switch_disabled":
            return "管理员已关闭企业切换"
        case "account_locked":
            return "账号已锁定，请联系商户后台管理员解锁"
        case "account_blocked":
            return "账号因安全策略限制，暂不可登录"
        case "account_disabled":
            return "账号已停用，请联系管理员"
        case "device_blocked":
            return "当前设备暂不可登录"
        case "ip_login_blocked":
            return "今日登录失败次数过多，当前网络已被禁止登录"
        case "ip_not_allowed":
            return "当前网络不在企业允许登录范围内"
        case "ip_blocked":
            return "当前网络暂不可登录"
        case "account_password_sync_failed":
            return "账号服务暂不可用，请稍后重试"
        case "slide_captcha_required":
            return "需要完成安全验证后再登录"
        case "invalid_credentials":
            return "账号或密码错误"
        case "tenant_blocked":
            return "当前企业暂不可访问"
        case "security_policy_denied":
            return "操作被企业安全策略限制"
        case "security_blocked":
            return "访问已被安全策略限制"
        case "tenant_service_stopped":
            return "当前企业已停用，请切换其他企业"
        case "workspace_session_unavailable", "tenant_service_unavailable":
            return "当前企业服务暂不可用，请切换其他企业或稍后重试"
        case "tenant_member_not_found":
            return "当前企业成员关系不存在，请切换其他企业"
        case "workspace_not_found":
            return "目标企业不存在，请返回企业列表重新选择"
        case "workspace_identity_unlinked":
            return "当前账号企业身份未同步，请联系管理员处理"
        case "member_projection_syncing":
            return "成员数据正在同步，请稍后重试"
        case "member_projection_failed":
            return "成员数据同步失败，请稍后重试或联系管理员"
        case "tenant_member_disabled":
            return "当前企业成员关系已停用，请切换其他企业"
        default:
            return "当前企业暂不可进入，请切换其他企业"
        }
    }

    func defaultWorkspaceReasonMessage(_ rawReason: String) -> String {
        let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if reason.isEmpty {
            return "默认企业暂不可进入，请重新选择企业。"
        }
        if let accessCode = workspaceAccessCode(from: reason) {
            return "\(workspaceAccessMessage(for: accessCode))。请选择其他可进入企业。"
        }
        switch reason {
        case "default_workspace_unavailable", "default_company_unavailable", "default_tenant_unavailable":
            return "默认企业暂不可进入，请重新选择企业。"
        case "default_workspace_not_found", "default_company_not_found", "default_tenant_not_found":
            return "默认企业不存在，请重新选择企业。"
        case "workspace_session_unavailable":
            return "默认企业服务暂不可用，请重新选择企业。"
        case "pending", "pending_approval", "workspace_join_pending", "requires_approval", "approval_required":
            return "默认企业需商户后台审核，当前为待审核状态。"
        case "rejected", "workspace_join_rejected":
            return "默认企业入企申请已被拒绝。"
        case "permission_denied", "forbidden", "no_permission":
            return "默认企业权限不足，请重新选择企业。"
        case "license_blocked", "feature_not_enabled", "capability_disabled":
            return "默认企业当前许可证不可用，请重新选择企业。"
        case "totp_required", "mfa_required", "google_authenticator_required":
            return "默认企业需要完成安全验证，请重新选择企业。"
        default:
            return "默认企业暂不可进入，请重新选择企业。"
        }
    }

    private func defaultWorkspaceFailureMessage(_ error: Error) -> String {
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .conflict(let code, let message):
                if code == "default_workspace_unavailable" {
                    return defaultWorkspaceReasonMessage(message)
                }
            case .server(let message), .forbidden(let message):
                if message.lowercased().contains("default_workspace_unavailable") {
                    return defaultWorkspaceReasonMessage(message)
                }
            default:
                break
            }
        }
        return userFacingError(error)
    }

    func platformWorkspaceSwitchFailureMessage(_ error: Error) -> String {
        if isWorkspaceConnectivityFailure(error) || workspaceAccessCode(from: error) == "workspace_session_unavailable" {
            return "企业服务连接暂不可用，请检查网络后重试"
        }
        if isPlatformWorkspaceSwitchUnavailable(error) {
            return "平台切企业接口暂不可用，请稍后重试或联系管理员"
        }
        return defaultWorkspaceFailureMessage(error)
    }

    private func isWorkspaceConnectivityFailure(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let apiError = error as? IMAPIError else { return false }
        let raw: String
        switch apiError {
        case .httpStatus(let statusCode, _) where [502, 503, 504].contains(statusCode):
            return true
        case .server(let message), .badURL(let message):
            raw = message
        default:
            return false
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("service unavailable")
            || normalized.contains("network_error")
            || normalized.contains("network error")
            || normalized.contains("upstream unavailable")
            || normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized == "502"
            || normalized == "503"
            || normalized == "504"
    }

    func shouldPersistWorkspaceEntryAccessBlock(_ code: String) -> Bool {
        code != "workspace_session_unavailable"
    }

    private func isPlatformWorkspaceSwitchUnavailable(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else {
            return String(describing: error).localizedCaseInsensitiveContains("not found")
        }
        let message: String
        switch apiError {
        case .server(let raw), .badURL(let raw):
            message = raw
        default:
            return false
        }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "not_found"
            || normalized == "not found"
            || normalized.contains("404")
            || normalized.contains("route not found")
            || normalized.contains("endpoint not found")
            || normalized.contains("cannot post")
    }

    func markWorkspaceAccessBlocked(_ code: String, enterpriseID: String? = nil) -> Bool {
        let global = code == "account_locked"
            || code == "account_disabled"
            || code == "ip_login_blocked"
            || code == "account_blocked"
            || code == "device_blocked"
            || code == "ip_blocked"
            || code == "account_password_sync_failed"
            || code == "slide_captcha_required"
            || code == "invalid_credentials"
        let currentIDs = Set([apiContext.tenantID, currentEnterprise.id].compactMap { value -> String? in
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
        let targetID = enterpriseID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTargetValues: [String?] = [apiContext.tenantID, currentEnterprise.id]
        let explicitTargetValues: [String?] = [targetID]
        let targetValues = targetID?.isEmpty == false ? explicitTargetValues : fallbackTargetValues
        let targetIDs = global ? Set<String>() : Set(targetValues.compactMap { value -> String? in
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })

        func blocked(_ enterprise: Enterprise) -> Enterprise {
            var next = enterprise
            next.canSwitch = false
            next.enterable = false
            next.disabledReason = code
            switch code {
            case "account_locked":
                next.accountStatus = "locked"
            case "account_disabled":
                next.accountStatus = "disabled"
            case "account_blocked":
                next.accountStatus = "blocked"
            case "device_blocked":
                next.accountStatus = "device_blocked"
            case "ip_login_blocked":
                next.accountStatus = "ip_blocked"
            case "ip_not_allowed":
                next.tenantStatus = "ip_not_allowed"
            case "ip_blocked":
                next.accountStatus = "ip_blocked"
            case "account_password_sync_failed":
                next.accountStatus = "sync_failed"
            case "slide_captcha_required":
                next.accountStatus = "captcha_required"
            case "invalid_credentials":
                next.accountStatus = "invalid_credentials"
            case "tenant_blocked":
                next.tenantStatus = "blocked"
            case "security_policy_denied":
                next.tenantStatus = "security_denied"
            case "security_blocked":
                next.tenantStatus = "security_blocked"
            case "tenant_service_stopped":
                next.tenantStatus = "disabled"
            case "workspace_session_unavailable", "tenant_service_unavailable":
                next.tenantStatus = "service_unavailable"
            case "tenant_member_not_found":
                next.memberStatus = "not_found"
            case "workspace_not_found":
                next.tenantStatus = "not_found"
            case "workspace_identity_unlinked":
                next.memberStatus = "identity_unlinked"
            case "tenant_member_disabled":
                next.memberStatus = "disabled"
            default:
                break
            }
            return next
        }

        func shouldBlock(_ enterprise: Enterprise) -> Bool {
            global || targetIDs.contains(enterprise.id)
        }

        var affectsCurrent = global || currentIDs.contains(where: targetIDs.contains)
        if global || shouldBlock(currentEnterprise) {
            currentEnterprise = blocked(currentEnterprise)
            affectsCurrent = true
        }
        enterprises = enterprises.map { shouldBlock($0) ? blocked($0) : $0 }
        enterpriseSearchResults = enterpriseSearchResults.map { shouldBlock($0) ? blocked($0) : $0 }
        return affectsCurrent
    }

    func forceWorkspaceSelectionForCurrentAccessBlock(_ code: String) {
        let message = workspaceAccessMessage(for: code)
        let previousContext = apiContext
        let blockedEnterpriseID = [
            previousContext.tenantID,
            currentEnterprise.id
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        let hasPlatformSession = previousContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if hasPlatformSession {
            refreshWorkspaceSelectionListAfterAccessBlock(
                context: previousContext,
                blockedCode: code,
                blockedEnterpriseID: blockedEnterpriseID
            )
        }
        stopInboxRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        prepareSplashForScopeChange(reason: "workspace_access_blocked")
        resetAuthenticatedRemoteData(showLoading: false)
        apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
        isAuthenticated = false
        activeTab = .chats
        if hasPlatformSession {
            authScreen = .workspaceSelection
            loginWorkspaceSelectionMessage = "\(message)。请选择其他可进入企业。"
        } else {
            authScreen = .accountLogin
            loginWorkspaceSelectionMessage = nil
        }
        toast = hasPlatformSession ? message : "\(message)，请重新登录后选择企业"
    }

    private func refreshWorkspaceSelectionListAfterAccessBlock(context: IMAPIContext, blockedCode: String, blockedEnterpriseID: String?) {
        let expectedPlatformToken = context.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expectedPlatformToken.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if context.hasIMSession, let workspaces = try? await self.api.listWorkspaces(context: context) {
                guard self.authScreen == .workspaceSelection,
                      !self.isAuthenticated,
                      self.apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedPlatformToken else { return }
                self.applyWorkspaces(workspaces)
                _ = self.markWorkspaceAccessBlocked(blockedCode, enterpriseID: blockedEnterpriseID)
                return
            }

            let scopedAppID = IMAPIContext.normalizedIOSAppID(context.appID)
            if let memberships = try? await self.api.listMyTenants(platformToken: expectedPlatformToken, appID: scopedAppID), !memberships.isEmpty {
                guard self.authScreen == .workspaceSelection,
                      !self.isAuthenticated,
                      self.apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedPlatformToken else { return }
                self.applyTenantMemberships(memberships)
                _ = self.markWorkspaceAccessBlocked(blockedCode, enterpriseID: blockedEnterpriseID)
            }
        }
    }

    func securityBlockedInfo(from error: Error) -> SecurityBlockedInfo? {
        guard let apiError = error as? IMAPIError else { return nil }
        if case .securityBlocked(let info) = apiError {
            return info
        }
        return nil
    }

    func securityBlockedInfo(from envelope: RealtimeEnvelope) -> SecurityBlockedInfo {
        let payload = realtimeSecurityPayload(from: envelope)

        func string(_ keys: [String]) -> String {
            keys.compactMap { key -> String? in
                let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }.first ?? ""
        }

        let remainingSeconds = Int(string(["remaining_seconds", "remainingSeconds", "retry_after_seconds", "retryAfterSeconds"]))

        return SecurityBlockedInfo(
            scope: string(["scope"]),
            tenantID: string(["tenant_id", "tenantId"]),
            subjectType: string(["subject_type", "subjectType"]),
            reasonCode: string(["reason_code", "reasonCode"]),
            blockType: string(["block_type", "blockType"]),
            status: string(["status"]),
            expiresAt: string(["expires_at", "expiresAt", "blocked_until", "ban_until"]),
            remainingSeconds: remainingSeconds
        )
    }

    func realtimeErrorString(from envelope: RealtimeEnvelope, keys: [String]) -> String {
        let payload = realtimeSecurityPayload(from: envelope)
        return keys.compactMap { key -> String? in
            let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }.first ?? ""
    }

    private func realtimeSecurityPayload(from envelope: RealtimeEnvelope) -> [String: JSONValue] {
        var merged = envelope.payload
        for containerKey in ["error", "data", "payload"] {
            guard let nested = envelope.payload[containerKey]?.objectValue else { continue }
            for (key, value) in nested where merged[key] == nil {
                merged[key] = value
            }
        }
        return merged
    }

    func handleRealtimeNotFriendsError(_ envelope: RealtimeEnvelope) {
        let payload = realtimeSecurityPayload(from: envelope)
        let channelID = [
            payload["channel_id"]?.stringValue,
            payload["conversation_id"]?.stringValue,
            payload["conversationID"]?.stringValue
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !channelID.isEmpty else { return }
        let lookup = makeConversationUserLookup()
        guard let conversation = conversations.first(where: { conversation in
            conversation.id == channelID || remoteChannelID(for: conversation, lookup: lookup) == channelID
        }) else {
            return
        }
        let clientMessageID = [
            payload["client_message_id"]?.stringValue,
            payload["clientMessageID"]?.stringValue,
            payload["message_id"]?.stringValue,
            payload["msg_id"]?.stringValue
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if !clientMessageID.isEmpty {
            markMessageFailed(messageID: clientMessageID, in: conversation.id)
        }
        let context = directFriendRequestContext(from: payload, fallbackTargetUID: directPeerID(for: conversation) ?? "")
        handleNotFriends(for: conversation, context: context, showToast: false)
        logSyncEndpointFailure("/im/ws", error: IMAPIError.businessForbidden(code: context.reasonCode, message: context.disabledMessage, error: nil))
    }

    @discardableResult
    func handleSecurityBlocked(_ info: SecurityBlockedInfo, enterpriseID: String? = nil, silent: Bool = false) -> Bool {
        let message = info.userMessage
        let targetEnterpriseID = enterpriseID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? enterpriseID
            : (info.tenantID.isEmpty ? nil : info.tenantID)

        if info.isGlobalScoped && !info.isTenantScoped {
            stopInboxRefreshLoop()
            disconnectRealtime(shouldReconnect: false)
            resetAuthenticatedRemoteData(showLoading: false)
            disableAccessDiagnosticsOverlay()
            apiContext.clearSession(sessionStore: protectedSessionStore)
            isAuthenticated = false
            activeTab = .chats
            authScreen = .accountLogin
            loginWorkspaceSelectionMessage = nil
            syncFailureMessage = message
            if !silent {
                toast = message
            }
            return true
        }

        let affectsCurrent = markWorkspaceAccessBlocked("security_blocked", enterpriseID: targetEnterpriseID)
        if affectsCurrent {
            disconnectRealtime(shouldReconnect: false)
            forceWorkspaceSelectionForCurrentAccessBlock("security_blocked")
            loginWorkspaceSelectionMessage = "\(message)。请选择其他可进入企业。"
            syncFailureMessage = message
        }
        if !silent {
            toast = message
        }
        return affectsCurrent
    }

    func applySyncFailure(_ error: Error, silent: Bool) {
        let message = syncFailureUserMessage(error)
        if let securityInfo = securityBlockedInfo(from: error) {
            handleSecurityBlocked(securityInfo, silent: silent)
            syncFailureMessage = securityInfo.userMessage
            let redactedError = IMAPIClient.redactedSensitiveLogText(String(describing: error))
            print("[JHT Sync] snapshot_failed user_message=\(securityInfo.userMessage) endpoints=\"\(api.debugEndpointSummary(context: apiContext))\" error=\(redactedError)")
            return
        }
        if let code = workspaceAccessCode(from: error) {
            let affectsCurrent = markWorkspaceAccessBlocked(code)
            if affectsCurrent {
                disconnectRealtime(shouldReconnect: false)
                forceWorkspaceSelectionForCurrentAccessBlock(code)
            }
        }
        syncFailureMessage = message
        let redactedError = IMAPIClient.redactedSensitiveLogText(String(describing: error))
        print("[JHT Sync] snapshot_failed user_message=\(message) endpoints=\"\(api.debugEndpointSummary(context: apiContext))\" error=\(redactedError)")
        if !silent {
            showRemoteErrorToast(message)
        }
    }

    func logSyncEndpointFailure(_ endpoint: String, error: Error, channelID: String? = nil, channelType: String? = nil) {
        if DeviceRevocationDetector.matches(error: error) {
            handleCurrentDeviceRevoked()
            return
        }
        let channelText: String
        if let channelID, let channelType {
            channelText = " channel_id=\(channelID) channel_type=\(channelType)"
        } else {
            channelText = ""
        }
        let redactedError = IMAPIClient.redactedSensitiveLogText(String(describing: error))
        print("[JHT Sync] endpoint_failed endpoint=\(endpoint)\(channelText) endpoints=\"\(api.debugEndpointSummary(context: apiContext))\" error=\(redactedError)")
    }

}

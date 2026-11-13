import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
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
// SwiftUI-observed conversationStore.conversationMessageSnapshots(). Heavy snapshot projection and local message
// cache builders remain delegated to background helpers; this file keeps the
// AppState state boundary explicit.

// MARK: - Remote Registration and Snapshot Sync

extension AppState {
    func registerRemotely(phone: String, account: String, password: String, enterpriseCode: String?, captchaCode: String) async {
        guard !Task.isCancelled else { return }
        #if DEBUG
        if licenseQuotaScreenshotScenario == .registration {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(IMAPIClient.licenseQuotaUserMessage(for: "registered_user_quota_exceeded"))
            return
        }
        #endif
        let trimmedPhone = normalizedMainlandPhone(phone)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCaptchaCode = captchaCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty, (!trimmedPhone.isEmpty || !trimmedAccount.isEmpty) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入注册账号和密码")
            return
        }
        if !trimmedPhone.isEmpty {
            guard isValidMainlandPhone(trimmedPhone) else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入正确的手机号")
                return
            }
        }
        if !trimmedAccount.isEmpty, !isValidAccountUsername(trimmedAccount) {
            // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册账号格式提示按文档统一
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("账号须为5–10位英文字母或数字。")
            // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
            return
        }
        let normalizedEnterpriseCode = RegistrationFlowPolicy.submittedEntryCode(enterpriseCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        registrationRecoveryEntryCode = preAuthEnterpriseContext?.entryCode ?? normalizedEnterpriseCode
        authenticationPresentationStore.isLoading = true // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        let generation = authFlowGeneration.issueToken()
        workspaceSwitchGeneration.invalidate()
        let registrationFailureScreen: AuthScreen = trimmedAccount.isEmpty ? .phoneRegister : .accountRegister
        defer {
            if authFlowGeneration.isCurrent(generation) {
                authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            }
        }

        var submittedAttempt: PendingRegistrationAttempt?
        do {
            guard let policy = await ensureCurrentAppPolicyForAuth() else { return }
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            guard policy.registrationEnabled else {
                setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage)
                return
            }
            if !trimmedPhone.isEmpty, (!policy.phoneAuthEnabled || isPhoneAuthDisabledByServer) {
                disablePhoneAuthForCurrentApp()
                return
            }
            let enterpriseContext = requirePreAuthEnterpriseContextIfConfigured()
            if policy.enterpriseCodeFirst, enterpriseContext == nil { return }
            let authoritativeEnterpriseCode = enterpriseContext?.entryCode ?? normalizedEnterpriseCode
            if !policy.allowDefaultTenantJoin, authoritativeEnterpriseCode.isEmpty {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入企业编码或邀请码")
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入 6 位验证码")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("无法安全保存注册凭据，请重试")
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
                registrationConfirmationStore.snapshot.resolution = .failed // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("注册暂时无法安全提交，请稍后重试")
                return
            }
            registrationConfirmationStore.snapshot = .init() // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
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
                        submittedEntryCode: submittedEntryCode,
                        echoedEntryCode: data.requestedTenantCode,
                        allowsServerDefinedInvite: true // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
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
            if registrationResponseShouldFailClosedForAppIDIsolation(data, requestedEnterpriseCode: requestEnterpriseCode,
                entryAuthority: responseEntryAuthority) { // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(registrationFailureMessage(error, enterpriseCode: normalizedEnterpriseCode))
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(pendingMessage)
                }
                // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
            }
        }
    }

    private func registrationFailureIsExplicit4xx(_ error: Error) -> Bool {
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN
        if let rejection = error as? IMAnonymousDeviceRejectionError { return (400..<500).contains(rejection.statusCode) }
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END
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
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        disableAccessDiagnosticsOverlay()
        apiContext.clearSession(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        activeTab = .chats
        loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        setAuthScreen(failureScreen) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
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
        registrationConfirmationStore.snapshot = .init(resolution: .failed) // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
        resetRegistrationNonSuccessState(failureScreen: failureScreen)
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册错误文案优先按后端 error.code 精确映射，不再通过 message 关键词猜重名
        if let mappedMessage = registrationBackendCodeFailureMessage(error) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(mappedMessage)
        } else if licenseQuotaUserMessage(from: error) != nil
                    || isRegistrationEntryCodeRateLimitError(error) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(registrationFailureMessage(error, enterpriseCode: enterpriseCode))
        } else if let inviteMessage = memberInviteCodeErrorMessage(error) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("注册失败：\(inviteMessage)")
        } else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("注册未通过，请检查填写内容；仍无法完成请联系管理员。")
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
        registrationConfirmationStore.snapshot = .init(resolution: .pending) // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(RegistrationConfirmationPolicy.pendingMessage)
        recordRegistrationResolution(.pending, attempt: attempt)
        startRegistrationConfirmationPolling(attempt: attempt)
    }

    private func finishRegistrationSuccess(attempt: PendingRegistrationAttempt) {
        cancelRegistrationConfirmationPolling()
        clearRegistrationRecovery()
        pendingRegistrationReceiptStore.clear()
        registrationConfirmationStore.snapshot = .init(resolution: .success) // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
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
        registrationConfirmationStore.snapshot.resolution = .pending // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
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

    func loadRegistrationRecovery(attempt: PendingRegistrationAttempt) -> RegistrationSessionRecovery? {
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
        registrationConfirmationStore.snapshot.hasTimedOut = false // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
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

    func saveRegistrationRecovery(_ recovery: RegistrationSessionRecovery) -> Bool {
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
            if let originalCode, RegistrationFlowPolicy.submittedEntryCode(changedEntryCode) == originalCode { return }
        }
        // Cancel the request and fence even transports that deliver a late response.
        registrationSubmissionTask?.cancel()
        registrationSubmissionTask = nil
        registrationSubmissionID = nil
        cancelRegistrationConfirmationPolling()
        authFlowGeneration.invalidate()
        authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        if let receipt = registrationRecoveryReceipt ?? pendingRegistrationReceiptStore.load(), receipt.hasBoundScope,
           let appID = receipt.appID, let deviceID = receipt.deviceID {
            _ = pendingRegistrationReceiptStore.save(PendingRegistrationReceipt(
                requestID: receipt.requestID, appID: appID, deviceID: deviceID,
                failureScreen: receipt.failureScreen, startedAt: receipt.startedAt,
                resolutionState: receipt.resolutionState, sessionRecoveryCancelled: true
            ))
        }
        clearRegistrationRecovery()
        registrationConfirmationStore.snapshot = .init() // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
    }

    func clearRegistrationRecovery() {
        registrationSessionStore.deleteString(forKey: RegistrationSessionRecovery.storageKey)
        registrationRecoveryReceipt = nil
        registrationRecoveryEntryCode = nil
    }

    func registrationRecoveryIsCurrent(
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
    func finishRegistrationConfirmedSuccess(
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("注册成功，已自动登录")
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
            registrationConfirmationStore.snapshot.hasTimedOut = false // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("注册已确认，正在安全恢复登录，请稍候")
            return false
        }
    }

    private func finishRegistrationConfirmedFailure(attempt: PendingRegistrationAttempt) {
        cancelRegistrationConfirmationPolling()
        clearRegistrationRecovery()
        pendingRegistrationReceiptStore.clear()
        resetRegistrationNonSuccessState(failureScreen: attempt.failureScreen)
        registrationConfirmationStore.snapshot = .init(resolution: .failed) // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("注册失败，请重新提交注册")
        recordRegistrationResolution(.failed, attempt: attempt)
    }

    func finishRegistrationConfirmationTimeout(attempt: PendingRegistrationAttempt) {
        guard registrationResolutionState == .pending else { return }
#if DEBUG
        recordRegistrationDiagnostic(.confirmationExpired, elapsedSeconds: registrationNow() - attempt.startedAt)
#endif
        registrationConfirmationTask = nil
        registrationConfirmationStore.snapshot.hasTimedOut = true // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(registrationConfirmationMessage)
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
        registrationConfirmationStore.snapshot = .init() // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

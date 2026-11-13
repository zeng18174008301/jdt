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

extension AppState {
    // WDT_IOS1_LATE_AUTH_REFRESH_FAILURE_AUTHORITY_20261111_BEGIN
    func refreshStoredAuthSessionIfNeeded(reason: String, silent: Bool, context explicitContext: IMAPIContext? = nil, scope explicitScope: String? = nil) async -> Bool {
        await refreshStoredAuthSessionIfNeeded(
            reason: reason, silent: silent, context: explicitContext, scope: explicitScope, persistenceDefaults: .standard
        )
    }

    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
    func refreshStoredAuthSessionIfNeeded(
        reason: String, silent: Bool, context explicitContext: IMAPIContext? = nil,
        scope explicitScope: String? = nil, persistenceDefaults: UserDefaults
    ) async -> Bool {
        // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END
        let context = explicitContext ?? apiContext
        let scope = explicitScope ?? (context.hasIMSession ? remoteDataScopeKey(for: context) : "")
        let refreshFence = context.authSessionFence
        let expectedFailureScope = context.hasIMSession ? scope : nil
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
                guard stagedContext.save(defaults: persistenceDefaults, sessionStore: self.protectedSessionStore).isCommitted,
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
                // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_BEGIN — Cold launch owns admission after its cancellable restore producer resumes.
                guard self.applyAuthSessionRefreshResult(refreshed, expectedFence: refreshFence,
                    rebindAfterOnlineRefresh: reason != "cold_launch", persistenceDefaults: persistenceDefaults) else { return false }
                // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_END
                let refreshedScope = self.remoteDataScopeKey(for: self.apiContext)
                if let ticket = self.localMessageTicket,
                   self.isCurrentRemoteScope(refreshedScope) {
                    await self.recoverDurableOutbox(ticket: ticket, scope: refreshedScope)
                }
                if !silent {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("登录状态已恢复")
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
                        guard self.isCurrentAuthRefreshFailureAuthority(refreshFence, scope: expectedFailureScope) else { return false }
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
                            // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_BEGIN
                            expectedFence: refreshFence,
                            rebindAfterOnlineRefresh: reason != "cold_launch",
                            persistenceDefaults: persistenceDefaults
                            // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_END
                        )
                        let refreshedScope = self.remoteDataScopeKey(for: self.apiContext)
                        if let ticket = self.localMessageTicket,
                           self.isCurrentRemoteScope(refreshedScope) {
                            await self.recoverDurableOutbox(ticket: ticket, scope: refreshedScope)
                        }
                        if !silent {
                            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("登录状态已恢复")
                        }
                        print("[JHT DR] tenant_im_session_refresh_success reason=\(reason) endpoint=tenant_im status=2xx code=success tenant_present=\(!(self.apiContext.tenantID ?? "").isEmpty) app_id=\(self.apiContext.appID)")
                        return true
                    } catch is CancellationError {
                        return false
                    } catch {
                        guard self.isCurrentAuthRefreshFailureAuthority(refreshFence, scope: expectedFailureScope) else { return false }
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
                        await self.handleAuthSessionRefreshFailure(error, silent: silent, expectedFence: refreshFence, expectedScope: expectedFailureScope)
                        return false
                    }
                }
                await self.handleAuthSessionRefreshFailure(error, silent: silent, expectedFence: refreshFence, expectedScope: expectedFailureScope)
                return false
            }
        }
        remoteSyncEngine.attachAuthSessionRefreshTask(taskToken, task: task)
        let result = await task.value
        remoteSyncEngine.finishAuthSessionRefreshTask(taskToken)
        return resultIsCurrent(result)
    }

    // WDT_IOS1_LATE_AUTH_REFRESH_FAILURE_AUTHORITY_20261111_END


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

    func safeAuthRefreshFailureLogClassification(_ error: Error) -> (status: String, code: String) {
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
        // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_BEGIN
        expectedFence: IMAuthSessionFence,
        rebindAfterOnlineRefresh: Bool,
        persistenceDefaults: UserDefaults
        // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_END
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
        guard candidate.save(defaults: persistenceDefaults, sessionStore: protectedSessionStore).isCommitted,
              apiContext.isSameAuthAuthority(as: expectedFence) else { return false }
        commitRefreshedContext(candidate, rebindAfterOnlineRefresh: rebindAfterOnlineRefresh)
        if let tenant = result.tenant, let member = result.member {
            setCurrentEnterprise(enterprise(from: RemoteTenantMembership(tenant: tenant, member: member), fallbackAccent: currentEnterprise.accentHex)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        if !result.workspaces.isEmpty {
            applyWorkspaces(result.workspaces)
        }
        // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_BEGIN — Persistence/fences stay unchanged; cold restore does its own one-shot admission.
        if rebindAfterOnlineRefresh { rebindRealtimeAfterTokenRefreshIfNeeded(previousToken: previousRealtimeToken) }
        // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_END
        return true
    }

    private func applyTenantIMSessionRefreshResult(
        _ result: RemoteTenantIMSessionRefreshResult,
        fallbackContext: IMAPIContext,
        // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_BEGIN
        expectedFence: IMAuthSessionFence,
        rebindAfterOnlineRefresh: Bool,
        persistenceDefaults: UserDefaults
        // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_END
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
        IMTenantIMTokenExpiryStore.save(result.expiresAt, defaults: persistenceDefaults)
        guard candidate.save(defaults: persistenceDefaults, sessionStore: protectedSessionStore).isCommitted,
              apiContext.isSameAuthAuthority(as: expectedFence) else {
            throw IMAPIError.server("protected_session_persistence_failed")
        }
        commitRefreshedContext(candidate, rebindAfterOnlineRefresh: rebindAfterOnlineRefresh)
        // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_BEGIN — Persistence/fences stay unchanged; cold restore does its own one-shot admission.
        if rebindAfterOnlineRefresh { rebindRealtimeAfterTokenRefreshIfNeeded(previousToken: previousRealtimeToken) }
        // WDT_IOS1_COLD_RESTORE_REFRESH_BINDING_20261111_END
    }

    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
    private func commitRefreshedContext(_ candidate: IMAPIContext, rebindAfterOnlineRefresh: Bool) {
        let previousScope = callRecordRuntimeScope(for: apiContext)
        apiContext = candidate
        if rebindAfterOnlineRefresh,
           let currentScope = callRecordRuntimeScope(for: candidate),
           currentScope != previousScope {
            bindCallRecordPersistence(for: candidate)
        }
    }
    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END

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

    // WDT_IOS1_LATE_AUTH_REFRESH_FAILURE_AUTHORITY_20261111_BEGIN — The request authority is captured once before the shared refresh starts.
    private func isCurrentAuthRefreshFailureAuthority(_ expected: IMAuthSessionFence, scope: String?) -> Bool {
        apiContext.isSameAuthAuthority(as: expected) && (scope.map { isCurrentRemoteScope($0) } ?? true)
    }
    private func loginWithRememberedCredentialsForRefreshRecovery(
        _ credentials: RememberedLoginCredentials,
        context: IMAPIContext, expectedFence: IMAuthSessionFence, expectedScope: String?
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
            guard isCurrentAuthRefreshFailureAuthority(expectedFence, scope: expectedScope) else { throw CancellationError() }
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
        silent: Bool, expectedFence: IMAuthSessionFence, expectedScope: String?
    ) async -> Bool {
        guard isCurrentAuthRefreshFailureAuthority(expectedFence, scope: expectedScope) else { return false }
        guard !isAuthLoading else {
            print("[JHT Auth] refresh_expired_auto_login_skip reason=\(reason) code=\(code) cause=auth_busy")
            return false
        }
        guard let credentials = rememberedLoginCredentialsForAuthUI() else {
            print("[JHT Auth] refresh_expired_auto_login_skip reason=\(reason) code=\(code) cause=no_remembered_credentials")
            return false
        }
        let originalContext = apiContext
        let originalFence = expectedFence
        let generation = authFlowGeneration.issueToken()
        workspaceSwitchGeneration.invalidate()
        authenticationPresentationStore.isLoading = true // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        defer {
            if authFlowGeneration.isCurrent(generation) {
                authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            }
        }
        print("[JHT Auth] refresh_expired_auto_login_start reason=\(reason) code=\(code) mode=\(credentials.mode.storageValue)")
        do {
            let data = try await loginWithRememberedCredentialsForRefreshRecovery(
                credentials,
                context: originalContext, expectedFence: expectedFence, expectedScope: expectedScope
            )
            guard authFlowGeneration.isCurrent(generation) else { return false }
            guard rememberedRefreshRecoveryLoginData(data, matches: originalContext) else {
                throw IMAPIError.forbidden("remembered_login_identity_mismatch")
            }
            guard isCurrentAuthRefreshFailureAuthority(originalFence, scope: expectedScope) else {
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已恢复")
            }
            return recovered
        } catch {
            guard authFlowGeneration.isCurrent(generation),
                  isCurrentAuthRefreshFailureAuthority(expectedFence, scope: expectedScope) else { return false }
            let failure = safeAuthRefreshFailureLogClassification(error)
            print("[JHT Auth] refresh_expired_auto_login_failure reason=\(reason) code=\(code) status=\(failure.status) failure_code=\(failure.code)")
            return false
        }
    }
    // JHT_MOD_END AUTH_REFRESH_EXPIRED_AUTO_LOGIN

    private func handleAuthSessionRefreshFailure(_ error: Error, silent: Bool, expectedFence: IMAuthSessionFence, expectedScope: String?) async {
        guard isCurrentAuthRefreshFailureAuthority(expectedFence, scope: expectedScope) else { return }
        // WDT_IOS1_REFRESH_DEVICE_ERROR_AUTHORITY_OWNER_20261111_BEGIN — Preserve the existing full current-device cleanup only after the original authority check.
        if let refreshFailure = error as? IMSessionRefreshRejectionError,
           DeviceRevocationDetector.matches(code: refreshFailure.code, message: nil) {
            handleCurrentDeviceRevoked()
            return
        }
        // WDT_IOS1_REFRESH_DEVICE_ERROR_AUTHORITY_OWNER_20261111_END
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
            silent: silent, expectedFence: expectedFence, expectedScope: expectedScope
           ) {
            return
        }
        // JHT_MOD_END AUTH_REFRESH_EXPIRED_AUTO_LOGIN
        guard isCurrentAuthRefreshFailureAuthority(expectedFence, scope: expectedScope) else { return }
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
            if !silent { /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message) }
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
            setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            activeTab = .chats
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            }
            return
        }
        if !silent {
            showRemoteErrorToast("登录状态续期失败：\(message)")
        }
    }

    // WDT_IOS1_LATE_AUTH_REFRESH_FAILURE_AUTHORITY_20261111_END

}

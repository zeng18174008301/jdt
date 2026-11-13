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
    @discardableResult
    func attemptDefaultWorkspaceAutoEnter(
        from data: RemoteTenantLoginData,
        syncedMessage: String,
        fallbackMessage: String,
        loginGeneration: Int
    ) async -> Bool {
        guard data.autoEnterDefaultWorkspace else { return false }
        guard data.defaultWorkspaceValid == true,
              !data.defaultWorkspaceUnavailable else {
            return false
        }
        let defaultWorkspaceID = normalizedDefaultWorkspaceID(from: data)
        guard let defaultEnterprise = defaultWorkspaceEnterprise(from: data, defaultWorkspaceID: defaultWorkspaceID) else {
            return false
        }
        guard defaultEnterprise.isWorkspaceEnterable,
              !defaultEnterprise.isWorkspaceJoinPending,
              !defaultEnterprise.isWorkspaceJoinRejected else {
            return false
        }
        let expectedPlatformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expectedPlatformToken.isEmpty else { return false }
        let generation = authFlowGeneration.currentToken()

        if canEnterDefaultWorkspaceFromLoginSession(data, enterprise: defaultEnterprise) {
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
                syncedToast: "已进入默认企业 \(currentEnterprise.name)",
                fallbackToast: fallbackMessage
            )
            return true
        }

        guard defaultEnterprise.canSwitch else {
            return false
        }

        do {
            disconnectRealtime(shouldReconnect: false)
            apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
            resetAuthenticatedRemoteData(showLoading: true)
            try await switchPlatformTenant(
                tenantID: defaultEnterprise.id,
                isCurrent: { self.authFlowGeneration.isCurrent(generation) }
            )
            guard authFlowGeneration.isCurrent(generation) else { return true }
            if apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) != expectedPlatformToken {
                prepareLoginWorkspaceSelection(from: data, loginGeneration: loginGeneration)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已变化，请重新选择企业")
                return true
            }
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
                syncedToast: "已进入默认企业 \(currentEnterprise.name)",
                fallbackToast: fallbackMessage
            )
            return true
        } catch {
            guard authFlowGeneration.isCurrent(generation) else { return true }
            prepareLoginWorkspaceSelection(from: data, loginGeneration: loginGeneration)
            if let securityInfo = securityBlockedInfo(from: error) {
                handleSecurityBlocked(securityInfo, enterpriseID: defaultEnterprise.id)
                loginWorkspacePresentationStore.snapshot.message = "\(securityInfo.userMessage)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(securityInfo.userMessage)
            } else if let code = workspaceAccessCode(from: error) {
                if code == "workspace_switch_disabled" {
                    loginWorkspacePresentationStore.snapshot.message = "管理员已关闭企业切换；请使用服务端自动下发的最近可用企业会话进入。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("管理员已关闭企业切换")
                    return true
                }
                let message = shouldPersistWorkspaceEntryAccessBlock(code)
                    ? workspaceAccessMessage(for: code)
                    : platformWorkspaceSwitchFailureMessage(error)
                if shouldPersistWorkspaceEntryAccessBlock(code) {
                    _ = markWorkspaceAccessBlocked(code, enterpriseID: defaultEnterprise.id)
                }
                loginWorkspacePresentationStore.snapshot.message = "\(message)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            } else {
                let message = platformWorkspaceSwitchFailureMessage(error)
                loginWorkspacePresentationStore.snapshot.message = "\(message)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            }
            return true
        }
    }

    func loginWithOptionalSlideCaptcha(
        username: String,
        password: String,
        context explicitContext: IMAPIContext? = nil,
        enterpriseContext: PreAuthEnterpriseContext? = nil
    ) async throws -> RemoteTenantLoginData {
        let context = explicitContext ?? apiContext
        let slideToken = try await slideCaptchaService.tokenIfNeeded(
            scene: "im_user_login",
            tenantCode: "",
            appID: context.appID,
            api: api,
            presentSelfHosted: { [weak self] challenge in
                guard let self else { throw IMAPIError.emptyResponse }
                return try await self.presentSlideCaptcha(challenge)
            }
        )
        return try await loginViaNeutralIMEndpoint(
            username: username,
            password: password,
            slideToken: slideToken,
            context: context,
            enterpriseContext: enterpriseContext
        )
    }

    private func shouldRetryLoginWithSlideCaptcha(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        if case .loginSecurity(let code, _, _) = apiError {
            return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "slide_captcha_required"
        }
        return false
    }

    func canEnterDefaultWorkspaceFromLoginSession(_ data: RemoteTenantLoginData, enterprise: Enterprise) -> Bool {
        let targetTenantID = enterprise.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetTenantID.isEmpty,
              let session = data.session,
              !session.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiContext.hasIMSession else {
            return false
        }
        let contextTenantID = apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard contextTenantID == targetTenantID else { return false }
        return true
    }

    @discardableResult
    func attemptSingleWorkspaceAutoEnterFromDirectory(
        _ memberships: [RemoteTenantMembership],
        syncedMessage: String,
        fallbackMessage: String,
        loginGeneration: Int
    ) async -> Bool {
        guard memberships.count == 1 else { return false }
        let enterprise = enterprise(from: memberships[0], fallbackAccent: currentEnterprise.accentHex)
        guard enterprise.isWorkspaceEnterable,
              enterprise.canSwitch,
              !enterprise.isWorkspaceJoinPending,
              !enterprise.isWorkspaceJoinRejected else {
            return false
        }
        let expectedPlatformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expectedPlatformToken.isEmpty else { return false }
        let generation = authFlowGeneration.currentToken()
        do {
            disconnectRealtime(shouldReconnect: false)
            apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
            resetAuthenticatedRemoteData(showLoading: true)
            try await switchPlatformTenant(
                tenantID: enterprise.id,
                isCurrent: { self.authFlowGeneration.isCurrent(generation) }
            )
            guard authFlowGeneration.isCurrent(generation) else { return true }
            if apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) != expectedPlatformToken {
                prepareLoginWorkspaceSelectionFromCurrentDirectory(
                    message: "登录状态已变化，请重新选择企业",
                    loginGeneration: loginGeneration
                )
                return true
            }
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
                syncedToast: "已进入 \(currentEnterprise.name)",
                fallbackToast: fallbackMessage
            )
            return true
        } catch {
            guard authFlowGeneration.isCurrent(generation) else { return true }
            prepareLoginWorkspaceSelectionFromCurrentDirectory(
                message: "\(platformWorkspaceSwitchFailureMessage(error))。请选择其他可进入企业。",
                loginGeneration: loginGeneration
            )
            if let code = workspaceAccessCode(from: error) {
                let message = shouldPersistWorkspaceEntryAccessBlock(code)
                    ? workspaceAccessMessage(for: code)
                    : platformWorkspaceSwitchFailureMessage(error)
                if shouldPersistWorkspaceEntryAccessBlock(code) {
                    _ = markWorkspaceAccessBlocked(code, enterpriseID: enterprise.id)
                }
                loginWorkspacePresentationStore.snapshot.message = "\(message)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            } else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(platformWorkspaceSwitchFailureMessage(error))
            }
            return true
        }
    }

    func prepareLoginWorkspaceSelectionFromCurrentDirectory(message: String, loginGeneration: Int) {
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.workspaceSelectionTerminal, generation: loginGeneration)
#endif
        loginWorkspacePresentationStore.snapshot.message = message // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
    }

    func startPostLoginRemoteSnapshotRefresh(
        generation: Int,
        context: IMAPIContext,
        immediateToast: String?,
        syncedToast: String?,
        fallbackToast: String?
    ) {
        if let immediateToast {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(immediateToast)
        }
        let scope = remoteDataScopeKey(for: context)
        Task { [weak self] in
            guard let self else { return }
            guard self.authFlowGeneration.isCurrent(generation),
                  self.isCurrentRemoteScope(scope) else { return }
            let synced = await self.refreshRemoteSnapshot(silent: false, force: true)
            guard self.authFlowGeneration.isCurrent(generation),
                  self.isCurrentRemoteScope(scope) else { return }
            if synced, let syncedToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast(syncedToast)
            } else if let syncFailureMessage = self.syncFailureMessage {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast(syncFailureMessage)
            } else if let fallbackToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast(fallbackToast)
            }
            if synced {
                await self.confirmWorkspaceEntryAfterWorkbenchReady(context: context)
            }
            await self.evaluateForcedAppPolicyAuthIfNeeded(
                forceRefreshVerification: true,
                reason: "post_login_remote_snapshot"
            )
        }
    }

    private func confirmWorkspaceEntryAfterWorkbenchReady(context: IMAPIContext) async {
        guard context.hasIMSession,
              isCurrentRemoteScope(remoteDataScopeKey(for: context)),
              let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tenantID.isEmpty else {
            return
        }
        do {
            let result = try await api.confirmWorkspaceEntry(context: context, tenantID: tenantID)
            guard isCurrentRemoteScope(remoteDataScopeKey(for: context)) else { return }
            if !result.defaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loginWorkspacePresentationStore.snapshot.defaultWorkspaceID = result.defaultWorkspaceID // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            }
            if let workspace = result.defaultWorkspace {
                upsertEnterprise(enterprise(from: workspace, fallbackAccent: currentEnterprise.accentHex))
            }
        } catch {
            guard isCurrentRemoteScope(remoteDataScopeKey(for: context)) else { return }
            print("[JHT Auth] workspace_entry_confirm_failed code=\(workspaceAccessCode(from: error) ?? "unknown") tenant_present=\(!tenantID.isEmpty)")
        }
    }

    func defaultWorkspaceEnterprise(from data: RemoteTenantLoginData, defaultWorkspaceID: String) -> Enterprise? {
        let trimmedDefaultID = defaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDefaultID.isEmpty else { return nil }
        let defaultWorkspace = data.workspaces.first { $0.id == trimmedDefaultID }
            ?? data.defaultWorkspace.flatMap { $0.id == trimmedDefaultID ? $0 : nil }
        return defaultWorkspace.map { enterprise(from: $0, fallbackAccent: currentEnterprise.accentHex) }
    }

    func applyLoginWorkspaceState(from data: RemoteTenantLoginData) {
        guard !data.workspaces.isEmpty else { return }
        applyWorkspaces(data.workspaces)
        let preferredIDs = [
            data.autoEnteredWorkspaceID,
            data.tenant?.tenantID ?? "",
            apiContext.tenantID ?? ""
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let current = preferredIDs.compactMap({ id in enterprises.first(where: { $0.id == id }) }).first {
            setCurrentEnterprise(current) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
    }

    private func loginViaNeutralIMEndpoint(
        username: String,
        password: String,
        slideToken: String?,
        context explicitContext: IMAPIContext? = nil,
        enterpriseContext: PreAuthEnterpriseContext? = nil
    ) async throws -> RemoteTenantLoginData {
        let context = explicitContext ?? apiContext
        do {
            return try await api.loginIMUser(
                username: username,
                password: password,
                slideToken: slideToken,
                tenantCode: enterpriseContext?.entryCode ?? "",
                enterpriseContextToken: enterpriseContext?.contextToken ?? "",
                context: context
            )
        } catch {
            if enterpriseContext != nil { throw error }
            guard isNeutralLoginEndpointUnavailable(error) else { throw error }
            return try await api.loginTenantUser(username: username, password: password, slideToken: slideToken, context: context)
        }
    }

    func tenantLoginData(
        _ data: RemoteTenantLoginData,
        matches context: PreAuthEnterpriseContext
    ) -> Bool {
        guard let runtimeConfig = data.runtimeConfig else { return false }
        let routes = runtimeConfig.runtimeRouteSnapshot
        guard runtimeConfig.appID == context.appID,
              runtimeConfig.tenantID == context.tenantID,
              runtimeConfig.routeRevision == context.routeRevision,
              routes == context.runtimeRoutes,
              routes.validated(appID: context.appID, tenantID: context.tenantID) != nil else {
            return false
        }
        if let session = data.session,
           !session.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let tenantID = data.tenant?.tenantID,
                  let identity = session.effectiveIdentity(tenantID: tenantID) else {
                return false
            }
            return identity.appID == context.appID
                && identity.deviceID == context.deviceID
                && identity.tenantID == context.tenantID
        }
        return data.pendingEntryTenantID.isEmpty || data.pendingEntryTenantID == context.tenantID
    }

    func isNeutralLoginEndpointUnavailable(_ error: Error) -> Bool {
        // JHT_MOD_BEGIN LOGIN_AUTH_DEPENDENCY_NO_FALLBACK_20260913 - 修改开始：503 auth_dependency_unavailable 是权威失败，不回退旧租户登录
        if isAuthDependencyUnavailableError(error) {
            return false
        }
        // JHT_MOD_END LOGIN_AUTH_DEPENDENCY_NO_FALLBACK_20260913 - 修改结束
        return DisasterRecoveryFallbackClassifier.shouldFallbackFromPlatformFailure(error)
    }

}

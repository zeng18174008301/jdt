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
// Authentication, profile, and workspace orchestration remains on AppState/MainActor
// because it owns SwiftUI-observed auth state, session fencing, credential staging,
// splash/login presentation, workspace switching UI, and Store/session rebinding.
// Network models and policy helpers stay outside AppState; this file preserves the
// original ordering while making the UI/state boundary explicit.

// MARK: - Authentication, Profile, and Workspace

extension AppState {
    func beginSessionReauthentication() {
        guard isAuthenticated, !isAuthLoading, !isSessionReauthenticationPresented,
              !isShowingLaunchSplash, activeSplashOverlay == nil,
              slideCaptchaPrompt == nil else { return }
        guard (try? LocalMessageScope(context: apiContext)) != nil else {
            toast = "当前账号身份不完整，无法安全恢复登录；本地数据已保留。"
            return
        }
        sessionReauthenticationID = UUID()
        sessionReauthenticationContext = apiContext
        sessionReauthenticationError = nil
        isSessionReauthenticationPresented = true
    }

    func cancelSessionReauthentication() {
        sessionReauthenticationID = nil
        sessionReauthenticationContext = nil
        isSessionReauthenticationPresented = false
        sessionReauthenticationError = nil
        if isSessionReauthenticating { cancelSlideCaptcha() }
    }

    private func isCurrentSessionReauthentication(_ id: UUID, context: IMAPIContext) -> Bool {
        !Task.isCancelled && isAuthenticated && isSessionReauthenticationPresented
            && sessionReauthenticationID == id
            && apiContext.isSameAuthAuthority(as: context.authSessionFence)
    }

    /// A login response is staged, never applied through the ordinary logout/login lifecycle.
    @discardableResult
    func reauthenticateCurrentSession(identifier: String, password: String, enterpriseCode: String) async -> Bool {
        guard !isSessionReauthenticating, let id = sessionReauthenticationID,
              let original = sessionReauthenticationContext,
              isCurrentSessionReauthentication(id, context: original) else { return false }
        let username = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            sessionReauthenticationError = "请输入当前账号和密码"
            return false
        }
        isSessionReauthenticating = true
        sessionReauthenticationError = nil
        defer { isSessionReauthenticating = false }
        do {
            let policy = try await api.currentAppPolicy(appID: original.appID, forceRefresh: true)
            guard isCurrentSessionReauthentication(id, context: original) else { return false }
            guard policy.isUsable else { throw IMAPIError.forbidden("app_policy_unavailable") }
            if isValidMainlandPhone(normalizedMainlandPhone(username)), !policy.phoneAuthEnabled {
                throw IMAPIError.forbidden("phone_auth_disabled")
            }
            var enterpriseContext: PreAuthEnterpriseContext?
            if policy.enterpriseCodeFirst {
                guard let code = normalizedEnterpriseContextCode(enterpriseCode) else {
                    sessionReauthenticationError = "请填写当前企业的企业码"
                    return false
                }
                let result = try await api.resolveEnterpriseContext(
                    tenantCode: code, appID: original.appID, deviceID: original.deviceID
                )
                guard isCurrentSessionReauthentication(id, context: original) else { return false }
                let routes = result.runtimeConfig.runtimeRouteSnapshot
                guard result.tenantID == original.tenantID, result.appID == original.appID,
                      result.tenant?.id == result.tenantID,
                      let entry = RegistrationFlowPolicy.normalizedEntryCode(result.tenantCode),
                      entry.kind == .enterprise,
                      RegistrationFlowPolicy.normalizedEntryCode(result.tenant?.tenantCode ?? "") == entry,
                      let authority = RegistrationFlowPolicy.entryAuthority(
                        entryType: result.entryType, scheme: result.scheme,
                        canonical: result.canonical, submittedEntryCode: code
                      ),
                      !result.contextToken.isEmpty, result.expiresAt > Int64(Date().timeIntervalSince1970),
                      result.routeRevision > 0, result.routeRevision == routes.revision,
                      result.runtimeConfig.routeStatus == "ready",
                      routes.validated(appID: original.appID, tenantID: result.tenantID) != nil else {
                    throw IMAPIError.forbidden("reauth_identity_mismatch")
                }
                enterpriseContext = PreAuthEnterpriseContext(
                    appID: original.appID, deviceID: original.deviceID, tenantID: result.tenantID,
                    tenantCode: entry.normalizedValue, entryCode: authority.canonicalCode,
                    entryType: authority.entryType, entryScheme: authority.scheme,
                    tenantName: result.tenant?.name ?? "", tenantLogoURL: result.tenant?.logoURL ?? "",
                    tenantLogoCacheKey: result.tenant?.logoCacheKey ?? "", contextToken: result.contextToken,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(result.expiresAt)),
                    routeRevision: result.routeRevision, runtimeRoutes: routes
                )
            }
            let data = try await loginWithOptionalSlideCaptcha(
                username: username, password: password, context: original, enterpriseContext: enterpriseContext
            )
            guard isCurrentSessionReauthentication(id, context: original) else { return false }
            if let enterpriseContext, !tenantLoginData(data, matches: enterpriseContext) {
                throw IMAPIError.forbidden("reauth_identity_mismatch")
            }
            var candidate = try Self.sessionReauthenticationCandidate(data: data, original: original)
            var routeCandidate = candidate.hasIMSession ? data.runtimeConfig?.runtimeRouteSnapshot : nil
            if !candidate.hasIMSession {
                // Select only the captured enterprise with the newly authenticated platform bearer.
                // Never use the previous bearer or the response's default workspace.
                guard let token = candidate.platformToken, !token.isEmpty, let tenantID = original.tenantID else {
                    throw IMAPIError.forbidden("reauth_incomplete_session")
                }
                guard let routeAPI = api as? IMAPIClient else {
                    throw IMAPIError.forbidden("reauth_route_staging_unavailable")
                }
                let entered = try await routeAPI.enterTenantCandidate(
                    tenantID: tenantID, platformToken: token, appID: original.appID, deviceID: original.deviceID
                )
                guard isCurrentSessionReauthentication(id, context: original) else { return false }
                let runtime = entered.runtimeConfig
                routeCandidate = runtime.runtimeRouteSnapshot
                guard runtime.appID == original.appID, runtime.tenantID == tenantID,
                      runtime.routeStatus == "ready",
                      runtime.runtimeRouteSnapshot.validated(appID: original.appID, tenantID: tenantID) != nil,
                      !entered.entryTicket.isEmpty,
                      let base = IMAPIClient.normalizedTenantAPIBaseURL(runtime.tenantAPIBaseURL) else {
                    throw IMAPIError.forbidden("reauth_invalid_route")
                }
                let entry = try await api.platformEntry(
                    entryTicket: entered.entryTicket, tenantBaseURL: base,
                    appID: original.appID, deviceID: original.deviceID
                )
                guard isCurrentSessionReauthentication(id, context: original) else { return false }
                guard entry.accountID == original.accountID, entry.tenant.id == tenantID,
                      entry.imUID == original.imUID, entry.appID == original.appID,
                      entry.deviceID == original.deviceID, !entry.imToken.isEmpty,
                      [entry.member.accountID, entry.user?.accountID ?? ""].allSatisfy({ $0.isEmpty || $0 == original.accountID }),
                      entry.member.tenantID.isEmpty || entry.member.tenantID == tenantID,
                      [entry.member.imUID, entry.user?.imUID ?? "", entry.session?.imUID ?? ""].allSatisfy({ $0.isEmpty || $0 == original.imUID }),
                      entry.session?.appID.isEmpty != false || entry.session?.appID == original.appID,
                      entry.session?.deviceID.isEmpty != false || entry.session?.deviceID == original.deviceID else {
                    throw IMAPIError.forbidden("reauth_identity_mismatch")
                }
                candidate.tenantID = tenantID
                candidate.imUID = entry.imUID
                candidate.imToken = entry.imToken
                candidate.tenantAPIBaseURL = base.absoluteString
                candidate.imAPIBaseURL = IMAPIClient.normalizedIMAPIBaseURL(runtime.imAPIBaseURL)?.absoluteString
                try Self.validateSessionReauthenticationAuthority(entry.authSession, original: original)
                try Self.validateSessionReauthenticationAuthority(entry.session?.authSession, original: original)
                candidate.persistAuthSession(entry.session?.authSession, fallbackTokenType: "im", fallbackTenantID: tenantID)
                candidate.persistAuthSession(entry.authSession, fallbackTokenType: "im", fallbackTenantID: tenantID)
            }
            guard try LocalMessageScope(context: candidate) == LocalMessageScope(context: original),
                  isCurrentSessionReauthentication(id, context: original) else {
                throw IMAPIError.forbidden("reauth_identity_mismatch")
            }
            return await commitSessionReauthentication(candidate, original: original, id: id, routes: routeCandidate)
        } catch {
            guard isCurrentSessionReauthentication(id, context: original) else { return false }
            // Deliberately fixed text: server prose and credentials never enter this recovery UI/log.
            sessionReauthenticationError = "验证未完成，请确认使用原账号、密码和企业码；原聊天数据已保留。"
            return false
        }
    }

    private static func validateSessionReauthenticationAuthority(_ session: RemoteAuthSession?, original: IMAPIContext) throws {
        guard let session else { return }
        guard (session.appID.isEmpty || session.appID == original.appID),
              (session.deviceID.isEmpty || session.deviceID == original.deviceID),
              (session.tenantID.isEmpty || session.tenantID == original.tenantID),
              ["", "im", "platform"].contains(session.normalizedTokenType) else {
            throw IMAPIError.forbidden("reauth_identity_mismatch")
        }
    }

    static func sessionReauthenticationCandidate(data: RemoteTenantLoginData, original: IMAPIContext) throws -> IMAPIContext {
        let accountIDs = [data.accountID, data.account?.id ?? "", data.user?.accountID ?? ""]
            .filter { !$0.isEmpty }
        guard !accountIDs.isEmpty, accountIDs.allSatisfy({ $0 == original.accountID }) else {
            throw IMAPIError.forbidden("reauth_identity_mismatch")
        }
        try validateSessionReauthenticationAuthority(data.authSession, original: original)
        try validateSessionReauthenticationAuthority(data.session?.authSession, original: original)
        var candidate = original
        candidate.platformToken = data.platformToken.isEmpty ? nil : data.platformToken
        candidate.platformAuthSession = nil
        candidate.tenantAuthSession = nil
        candidate.imToken = nil
        candidate.accessExpiresAt = 0
        candidate.pendingRefreshRequestID = nil
        candidate.sessionEpoch = UUID().uuidString
        candidate.credentialRevision &+= 1
        candidate.persistAuthSession(data.authSession, fallbackTokenType: "platform", fallbackTenantID: nil)
        if let session = data.session, !session.imToken.isEmpty {
            guard let identity = session.effectiveIdentity(tenantID: data.tenant?.tenantID ?? ""),
                  identity.tenantID == original.tenantID, identity.appID == original.appID,
                  identity.deviceID == original.deviceID, session.imUID == original.imUID,
                  (session.appID.isEmpty || session.appID == original.appID),
                  (session.deviceID.isEmpty || session.deviceID == original.deviceID),
                  data.user?.imUID.isEmpty != false || data.user?.imUID == original.imUID else {
                throw IMAPIError.forbidden("reauth_identity_mismatch")
            }
            if data.canDirectEnter, !data.requiresWorkspaceSelection {
                if let runtime = data.runtimeConfig {
                    guard runtime.appID == original.appID, runtime.tenantID == original.tenantID,
                          runtime.routeStatus == "ready",
                          runtime.runtimeRouteSnapshot.validated(appID: original.appID, tenantID: identity.tenantID) != nil,
                          let base = IMAPIClient.normalizedTenantAPIBaseURL(runtime.tenantAPIBaseURL) else {
                        throw IMAPIError.forbidden("reauth_invalid_route")
                    }
                    candidate.tenantAPIBaseURL = base.absoluteString
                    candidate.imAPIBaseURL = IMAPIClient.normalizedIMAPIBaseURL(runtime.imAPIBaseURL)?.absoluteString
                }
                candidate.imToken = session.imToken
                candidate.persistAuthSession(session.authSession, fallbackTokenType: "im", fallbackTenantID: identity.tenantID)
            }
        }
        return candidate
    }

    private func commitSessionReauthentication(_ candidate: IMAPIContext, original: IMAPIContext, id: UUID, routes: IMRuntimeRouteSnapshot?) async -> Bool {
        guard isCurrentSessionReauthentication(id, context: original) else { return false }
        // Retire old writers using the existing same-scope generation rebind, not a cleanup tombstone.
        let generation = localMessageSessionGeneration &+ 1
        localMessageSessionGeneration = generation
        retireAttachmentUploadOperationsForReauthentication()
        localMessageTicket = nil
        durableOutboxRecoveryTask?.cancel()
        durableOutboxRecoveryTask = nil
        durableReadAckRecoveryTask?.cancel()
        durableReadAckRecoveryTask = nil
        let ticket: LocalMessageSessionTicket
        let projectionFloor: Int64
        do {
            ticket = try await messagePersistence.ensureTicket(context: original, sessionGeneration: generation)
            projectionFloor = try await messagePersistence.projectionRevisionFloor(ticket: ticket)
        } catch {
            if isCurrentSessionReauthentication(id, context: original) {
                sessionReauthenticationError = "本地数据暂不可重新绑定，原数据已保留，请稍后重试。"
            }
            return false
        }
        // Cancellation keeps the original authority with a valid, newly fenced handle.
        guard apiContext.isSameAuthAuthority(as: original.authSessionFence),
              localMessageSessionGeneration == generation else { return false }
        localMessageTicket = ticket
        localMessageProjectionRevision = max(localMessageProjectionRevision, projectionFloor)
        guard isCurrentSessionReauthentication(id, context: original) else { return false }
        guard candidate.save(sessionStore: protectedSessionStore).isCommitted else {
            // A write may succeed before a protected readback fails. Restore the previous
            // snapshot, and do not label an unconfirmed rollback as unchanged credentials.
            let restored = original.save(sessionStore: protectedSessionStore).isCommitted
            sessionReauthenticationError = restored
                ? "登录状态未能安全保存，原聊天数据已保留，请重试。"
                : "登录存储状态待确认，请稍后重试；本地聊天数据未清理。"
            return false
        }
        guard isCurrentSessionReauthentication(id, context: original) else {
            _ = original.save(sessionStore: protectedSessionStore)
            return false
        }
        if let routes {
            do {
                guard let routeAPI = api as? IMAPIClient, let tenantID = candidate.tenantID else {
                    throw IMAPIError.forbidden("reauth_route_staging_unavailable")
                }
                try routeAPI.commitTenantRuntimeRoutes(routes, appID: candidate.appID, tenantID: tenantID)
            } catch {
                let restored = original.save(sessionStore: protectedSessionStore).isCommitted
                sessionReauthenticationError = restored
                    ? "连接路由未能提交，请重试；本地聊天数据已保留。"
                    : "登录存储状态待确认，请稍后重试；本地聊天数据未清理。"
                return false
            }
        }
        // No suspension from durable commit through the one-shot transition and new ticket publication.
        let visibleConversationID = activeRealtimeConversationID
        remoteSyncEngine.reset()
        disconnectRealtime(shouldReconnect: false)
        sessionReauthenticationCommit = (original.authSessionFence, candidate.authSessionFence)
        apiContext = candidate
        sessionReauthenticationCommit = nil
        localMessageTicket = ticket
        if let visibleConversationID {
            activeRealtimeConversationID = visibleConversationID
            _ = conversationSelectionEpochFence.select(
                scope: remoteDataScopeKey(for: candidate), conversationID: visibleConversationID
            )
        }
        sessionReauthenticationID = nil
        sessionReauthenticationContext = nil
        isSessionReauthenticationPresented = false
        sessionReauthenticationError = nil
        startInboxRefreshLoop()
        startRTCCallRefreshLoop()
        startRealtimeConnection(context: candidate)
        Task { [weak self] in
            guard let self, self.apiContext.isSameAuthAuthority(as: candidate.authSessionFence) else { return }
            _ = await self.refreshRemoteSnapshot(silent: true, force: true)
        }
        // Authentication is not a claim that sync or the websocket handshake already succeeded.
        toast = "身份已重新验证，正在恢复连接；原聊天数据已保留。"
        return true
    }

    func completeSlideCaptcha(_ ticket: SlideCaptchaTicket) {
        guard let continuation = slideCaptchaContinuation else { return }
        slideCaptchaContinuation = nil
        slideCaptchaPrompt = nil
        continuation.resume(returning: ticket)
    }

    func cancelSlideCaptcha() {
        guard let continuation = slideCaptchaContinuation else {
            slideCaptchaPrompt = nil
            return
        }
        slideCaptchaContinuation = nil
        slideCaptchaPrompt = nil
        continuation.resume(throwing: IMAPIError.forbidden("已取消滑动验证"))
    }

    private func presentSlideCaptcha(_ challenge: RemoteSlideCaptchaChallenge) async throws -> SlideCaptchaTicket {
        if slideCaptchaContinuation != nil {
            cancelSlideCaptcha()
        }
        return try await withCheckedThrowingContinuation { continuation in
            slideCaptchaContinuation = continuation
            slideCaptchaPrompt = challenge
        }
    }

    @discardableResult
    func refreshCurrentAppPolicyForAuthUI(force: Bool = false) async -> Bool {
		defer { (api as? IMAPIClient)?.finishRuntimeColdLaunch() }
        #if DEBUG
        if authPolicyScreenshotModeEnabled, currentAppPolicy != nil {
            hasResolvedCurrentAppPolicyForAuthUI = true
            isPhoneAuthDisabledByServer = currentAppPolicy?.phoneAuthEnabled == false
            normalizeAuthScreenForPhoneAuthPolicy()
            applyAccessDiagnosticsPolicy(currentAppPolicy!, source: "cache")
            return true
        }
        #endif
        do {
            _ = try await loadCurrentAppPolicy(force: force)
            hasResolvedCurrentAppPolicyForAuthUI = true
            normalizeAuthScreenForPhoneAuthPolicy()
            return true
        } catch {
            disableAccessDiagnosticsOverlay()
            currentAppPolicyErrorMessage = currentAppPolicyFailureMessage(error)
            hasResolvedCurrentAppPolicyForAuthUI = true
            normalizeAuthScreenForPhoneAuthPolicy()
            return false
        }
    }

    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：协议入口返回受控拉取的正文内容
    func legalDocumentContent(for type: LegalDocumentType) async -> LegalDocumentContent? {
        guard !isLegalDocRefreshing else { return nil }
        let appID = currentAppID
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = "当前应用配置缺失，请联系管理员"
            legalDocErrorMessage = message
            toast = message
            return nil
        }
        isLegalDocRefreshing = true
        defer { isLegalDocRefreshing = false }
        do {
            let scopedContext = legalDocumentRequestContext()
            let content = try await api.legalDocumentContent(
                type: type,
                appID: appID,
                context: scopedContext
            )
            legalDocManifest = content.manifest
            legalDocErrorMessage = nil
            return content
        } catch {
            let message = legalDocumentFailureMessage(error)
            legalDocErrorMessage = message
            toast = message
            return nil
        }
    }

    func legalDocumentURL(for type: LegalDocumentType) async -> URL? {
        await legalDocumentContent(for: type)?.sourceURL
    }

    private func legalDocumentRequestContext() -> IMAPIContext? {
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

    private func legalDocumentFailureMessage(_ error: Error) -> String {
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

    private func loadCurrentAppPolicy(force: Bool = false) async throws -> RemoteAppCurrentPolicy {
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
            hasResolvedCurrentAppPolicyForAuthUI = true
            isPhoneAuthDisabledByServer = !policy.phoneAuthEnabled
            normalizeAuthScreenForPhoneAuthPolicy()
            applyAccessDiagnosticsPolicy(policy, source: "cache")
            return policy
        }
        beginAccessDiagnosticsPolicyFetch(appID: appID)
        var lastError: Error?
        for candidate in IMAPIContext.iosAppIDCandidates(preferred: appID) {
            do {
                let policy = try await api.currentAppPolicy(appID: candidate, forceRefresh: force)
                guard policy.isUsable else {
                    forceDisableAccessDiagnosticsOverlay()
                    IMAppPolicyLastGoodStore.clear(appID: candidate)
                    currentAppPolicy = nil
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
                currentAppPolicy = policy
                hasResolvedCurrentAppPolicyForAuthUI = true
                isPhoneAuthDisabledByServer = !policy.phoneAuthEnabled
                applyCurrentAppAuthRouting(policy, allowPreferredAutoResolve: true)
                IMAppPolicyLastGoodStore.save(policy, appID: normalizedPolicyAppID.isEmpty ? candidate : normalizedPolicyAppID)
                applyAccessDiagnosticsPolicy(policy, source: "live")
                if !policy.departmentEnabled {
                    clearOrganizationDirectory(disabled: true)
                }
                currentAppPolicyErrorMessage = nil
                currentAppPolicyExpiresAt = Date().addingTimeInterval(TimeInterval(max(0, policy.cacheTTLSeconds)))
                return policy
            } catch {
                lastError = error
                if DisasterRecoveryFallbackClassifier.isAppPolicyFailClosedError(error) {
                    forceDisableAccessDiagnosticsOverlay()
                    IMAppPolicyLastGoodStore.clear(appID: candidate)
                    currentAppPolicy = nil
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
        guard let entry = IMAppPolicyLastGoodStore.usable(appID: appID) else { return nil }
        currentAppPolicy = entry.policy
        hasResolvedCurrentAppPolicyForAuthUI = true
        isPhoneAuthDisabledByServer = !entry.policy.phoneAuthEnabled
        applyCurrentAppAuthRouting(entry.policy, allowPreferredAutoResolve: false)
        currentAppPolicyErrorMessage = nil
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
        guard let requirement = await pendingForcedAppPolicyRequirementForRequestGate() else { return }
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

    private func pendingForcedAppPolicyRequirementForRequestGate() async -> AppPolicyForcedAuthRequirement? {
        guard isAuthenticated, apiContext.hasIMSession else { return nil }
        let scope = remoteDataScopeKey(for: apiContext)
        let policy: RemoteAppCurrentPolicy
        do {
            policy = try await loadCurrentAppPolicy()
        } catch {
            currentAppPolicyErrorMessage = currentAppPolicyFailureMessage(error)
            return nil
        }
        guard policy.requireRealName || policy.requirePhoneVerification else { return nil }
        if verificationRequirementAuthorityScopeKey != scope {
            await refreshForcedAppPolicyAuthSnapshotIfNeeded(policy: policy)
        }
        guard verificationRequirementAuthorityScopeKey == scope else {
            return policy.requirePhoneVerification ? .phone : .realName
        }
        return AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: currentUser)
    }

    private func refreshForcedAppPolicyAuthSnapshotIfNeeded(policy: RemoteAppCurrentPolicy) async {
        guard isAuthenticated, apiContext.hasIMSession else { return }
        if policy.requirePhoneVerification || policy.requireRealName {
            await refreshVerificationStatus()
        }
    }

    func presentForcedAppPolicyAuthPrompt(_ requirement: AppPolicyForcedAuthRequirement) {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        guard forcedAppPolicyAuthDestination == nil,
              forcedAppPolicyAuthPresentationFence.pendingDestination == nil,
              forcedAppPolicyAuthPrompt != requirement else { return }
        forcedAppPolicyAuthPrompt = requirement
    }

    func ensureCurrentAppPolicyForAuth() async -> RemoteAppCurrentPolicy? {
        do {
            let policy = try await loadCurrentAppPolicy()
            guard policy.isUsable else {
                let message = currentAppPolicyBlockedMessage(policy)
                currentAppPolicyErrorMessage = message
                toast = message
                return nil
            }
            return policy
        } catch {
            let message = currentAppPolicyFailureMessage(error)
            currentAppPolicyErrorMessage = message
            toast = message
            return nil
        }
    }

    func openForcedAppPolicyAuthDestination(_ requirement: AppPolicyForcedAuthRequirement) {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        guard forcedAppPolicyAuthDestination == nil,
              forcedAppPolicyAuthPresentationFence.beginDestinationTransition(requirement) else { return }
        forcedAppPolicyAuthPrompt = nil
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
            guard let self else { return }
            guard self.isAuthenticated,
                  self.apiContext.hasIMSession,
                  self.isCurrentRemoteScope(scope),
                  self.forcedAppPolicyAuthDestination == nil,
                  self.forcedAppPolicyAuthPresentationFence.completeDestinationTransition() == requirement else {
                self.forcedAppPolicyAuthPresentationFence.cancelDestinationTransition()
                self.forcedAppPolicyAuthDestinationTransitionTask = nil
                return
            }
            self.forcedAppPolicyAuthDestinationTransitionTask = nil
            self.forcedAppPolicyAuthDestination = requirement
        }
    }

    func cancelForcedAppPolicyAuthDestinationTransition() {
        forcedAppPolicyAuthDestinationTransitionTask?.cancel()
        forcedAppPolicyAuthDestinationTransitionTask = nil
        forcedAppPolicyAuthPresentationFence.cancelDestinationTransition()
    }

    func forcedAppPolicyAuthDestinationDidDismiss() {
        forcedAppPolicyAuthDestination = nil
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
            forcedAppPolicyAuthPrompt = nil
            forcedAppPolicyAuthDestination = nil
        }

        let policy: RemoteAppCurrentPolicy
        do {
            policy = try await loadCurrentAppPolicy()
        } catch {
            currentAppPolicyErrorMessage = currentAppPolicyFailureMessage(error)
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
        forcedAppPolicyAuthPresentationFence.reset()
        forcedAppPolicyAuthPrompt = nil
        forcedAppPolicyAuthDestination = nil
        forcedAppPolicyAuthScopeKey = ""
        verificationRequirementAuthorityScopeKey = ""
    }

    private func currentAppPolicyBlockedMessage(_ policy: RemoteAppCurrentPolicy) -> String {
        let status = policy.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.localizedCaseInsensitiveContains("disabled") || status.localizedCaseInsensitiveContains("停用") {
            return "当前应用已停用，请联系管理员"
        }
        return "当前应用暂不可用，请联系管理员"
    }

    private func currentAppPolicyFailureMessage(_ error: Error) -> String {
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
        isPhoneAuthDisabledByServer = true
        hasResolvedCurrentAppPolicyForAuthUI = true
        if let policy = currentAppPolicy, policy.phoneAuthEnabled {
            let disabledPolicy = policy.settingPhoneAuthEnabled(false)
            currentAppPolicy = disabledPolicy
            let appID = IMAPIContext.normalizedIOSAppID(
                disabledPolicy.appID.isEmpty ? apiContext.appID : disabledPolicy.appID
            )
            IMAppPolicyLastGoodStore.save(disabledPolicy, appID: appID)
            currentAppPolicyExpiresAt = Date().addingTimeInterval(TimeInterval(max(0, disabledPolicy.cacheTTLSeconds)))
        }
        normalizeAuthScreenForPhoneAuthPolicy()
        toast = PhoneAuthPresentationPolicy.disabledMessage
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

    func normalizedRegistrationTenantCode(_ value: String?) -> String {
        guard let value else { return "" }
        return RegistrationFlowPolicy.normalizedEntryCode(value)?.normalizedValue ?? ""
    }

    private func normalizedEnterpriseContextCode(_ value: String) -> String? {
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
            submittedEntryCode: normalizedCode
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

    @discardableResult
    func resolveEnterpriseContext(enterpriseCode: String, automatic _: Bool = false) async -> Bool {
        guard !isAuthenticated, !apiContext.hasIMSession,
              currentAppPolicy?.enterpriseCodeFirst == true else {
            return false
        }
        guard let normalizedCode = normalizedEnterpriseContextCode(enterpriseCode) else {
            let message = RegistrationFlowPolicy.entryCodePrompt
            enterpriseContextErrorMessage = message
            toast = message
            authScreen = .enterpriseCode
            return false
        }
        cancelRegistrationSessionRecovery()
        let requestAppID = apiContext.appID
        let requestDeviceID = apiContext.deviceID
        let generation = enterpriseContextGeneration.issueToken()
        preAuthEnterpriseContext = nil
        isResolvingEnterpriseContext = true
        enterpriseContextErrorMessage = nil
        defer {
            if enterpriseContextGeneration.isCurrent(generation) {
                isResolvingEnterpriseContext = false
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
            preAuthEnterpriseContext = context
            enterpriseContextErrorMessage = nil
            authScreen = .accountLogin
            return true
        } catch {
            guard enterpriseContextGeneration.isCurrent(generation) else { return false }
            preAuthEnterpriseContext = nil
            let message = enterpriseContextFailureMessage(error)
            enterpriseContextErrorMessage = message
            toast = message
            authScreen = .enterpriseCode
            return false
        }
    }

    func clearPreAuthEnterpriseContext() {
        invalidatePreAuthEnterpriseContext(normalizeScreen: true)
    }

    func invalidatePreAuthEnterpriseContext(normalizeScreen: Bool = true) {
        enterpriseContextGeneration.invalidate()
        preAuthEnterpriseContext = nil
        isResolvingEnterpriseContext = false
        enterpriseContextErrorMessage = nil
        lastPreferredEnterpriseCodeAttempt = ""
        if normalizeScreen {
            normalizeAuthScreenForCurrentAppPolicy()
        }
    }

    private func usablePreAuthEnterpriseContext() -> PreAuthEnterpriseContext? {
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
        authScreen = .enterpriseCode
        let message = "企业码验证已失效，请重新输入"
        enterpriseContextErrorMessage = message
        toast = message
        return nil
    }

    // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：普通登录 409 tenant_code_required 的一次性企业码续登
    private func isTenantCodeRequiredLoginChallenge(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError,
              case let .conflict(code, _) = apiError else { return false }
        return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tenant_code_required"
    }

    func isAuthDependencyUnavailableError(_ error: Error) -> Bool {
        let code = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
        return code == "auth_dependency_unavailable" || code.contains("auth_dependency_unavailable")
    }

    private func presentLoginTenantCodeChallenge(
        generation: Int,
        credentialMode: LoginMode,
        identifier: String,
        password: String,
        context: IMAPIContext
    ) {
        loginTenantCodeChallenge = LoginTenantCodeChallenge(
            generation: generation,
            credentialMode: credentialMode,
            identifier: identifier,
            password: password,
            context: context
        )
        isLoginTenantCodeChallengeActive = true
        loginTenantCodeChallengeIdentifier = identifier
        loginTenantCodeChallengeErrorMessage = nil
        isSubmittingLoginTenantCodeChallenge = false
        authScreen = .tenantCodeChallenge
        toast = "请输入企业码，以确认要登录的企业"
    }

    private func clearLoginTenantCodeChallenge() {
        loginTenantCodeChallenge = nil
        isLoginTenantCodeChallengeActive = false
        loginTenantCodeChallengeIdentifier = ""
        loginTenantCodeChallengeErrorMessage = nil
        isSubmittingLoginTenantCodeChallenge = false
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
        if loginTenantCodeChallenge?.credentialMode == .phone, isPhoneAuthEnabledForAuthUI {
            fallbackScreen = .phoneLogin
        } else {
            fallbackScreen = .accountLogin
        }
        retireLoginTenantCodeChallenge(invalidateGeneration: true)
        isAuthLoading = false
        authScreen = fallbackScreen
    }

    func loginTenantCodeChallengeInputDidChange() {
        loginTenantCodeChallengeErrorMessage = nil
    }

    func submitLoginTenantCodeChallenge(enterpriseCode: String) {
        guard !isSubmittingLoginTenantCodeChallenge,
              let currentChallenge = loginTenantCodeChallenge,
              authScreen == .tenantCodeChallenge else { return }
        guard let normalizedCode = normalizedEnterpriseContextCode(enterpriseCode) else {
            let message = RegistrationFlowPolicy.entryCodePrompt
            loginTenantCodeChallengeErrorMessage = message
            toast = message
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
        loginTenantCodeChallenge = challenge
        isAuthLoading = true
        isSubmittingLoginTenantCodeChallenge = true
        loginTenantCodeChallengeErrorMessage = nil
        workspaceSwitchGeneration.invalidate()
        Task {
            defer {
                discardRememberedLoginAttempt(generation: generation)
                if authFlowGeneration.isCurrent(generation) {
                    isAuthLoading = false
                    isSubmittingLoginTenantCodeChallenge = false
                }
            }
            do {
                let enterpriseContext = try await resolvedPreAuthEnterpriseContext(
                    enterpriseCode: normalizedCode,
                    appID: challenge.context.appID,
                    deviceID: challenge.context.deviceID
                )
                guard authFlowGeneration.isCurrent(generation),
                      loginTenantCodeChallenge?.isCurrent(
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
                      loginTenantCodeChallenge?.isCurrent(
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
                      loginTenantCodeChallenge?.isCurrent(
                        generation: generation,
                        appID: challenge.context.appID,
                        deviceID: challenge.context.deviceID
                      ) == true else { return }
                if handlePhoneAuthDisabledError(error) {
                    clearLoginTenantCodeChallenge()
                    return
                }
                let message = loginTenantCodeChallengeFailureMessage(error)
                loginTenantCodeChallengeErrorMessage = message
                toast = message
                authScreen = .tenantCodeChallenge
            }
        }
    }

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

    private func isEnterpriseContextAuthorityError(_ error: Error) -> Bool {
        ["enterprise_context_invalid", "enterprise_context_expired", "enterprise_context_required"]
            .contains(appPolicyErrorCode(from: error))
    }

    func isRegistrationEntryCodeRateLimitError(_ error: Error) -> Bool {
        ["enterprise_context_rate_limited", "registration_tenant_code_probe_rate_limited"]
            .contains(appPolicyErrorCode(from: error))
    }

    func isValidRegistrationTenantCode(_ value: String?) -> Bool {
        !normalizedRegistrationTenantCode(value).isEmpty
    }

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
        rememberLoginCredentialsEnabledForAuthUI = enabled
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
        rememberLoginCredentialsEnabledForAuthUI = enabled
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

    private func beginRememberedLoginAttempt(
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

    private func discardRememberedLoginAttempt(generation: Int) {
        guard pendingRememberedLoginAttempt?.generation == generation else { return }
        pendingRememberedLoginAttempt = nil
    }

    private func commitRememberedLoginAttemptIfAuthoritative(
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
            toast = "请输入账号和密码"
            return
        }

        cancelRegistrationSessionRecovery()
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：新的登录输入会废弃上一轮临时企业码挑战
        retireLoginTenantCodeChallenge(invalidateGeneration: false)
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        // Login has detached registration before any asynchronous work.
        isAuthLoading = true
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
                isAuthLoading = false
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
                isAuthenticated = false
                stopInboxRefreshLoop()
                resetAuthenticatedRemoteData(showLoading: false)
                disableAccessDiagnosticsOverlay()
                apiContext.clearSession(sessionStore: protectedSessionStore)
                if isRegistrationEntryCodeRateLimitError(error) {
                    invalidatePreAuthEnterpriseContext(normalizeScreen: false)
                    authScreen = .enterpriseCode
                    let message = enterpriseContextFailureMessage(error)
                    enterpriseContextErrorMessage = message
                    toast = message
                } else if isEnterpriseContextAuthorityError(error) {
                    invalidatePreAuthEnterpriseContext(normalizeScreen: false)
                    authScreen = .enterpriseCode
                    let message = enterpriseContextFailureMessage(error)
                    enterpriseContextErrorMessage = message
                    toast = message
                } else if !handlePhoneAuthDisabledError(error) {
                    toast = loginFailureMessage(error)
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
            isAuthenticated = false
            stopInboxRefreshLoop()
            stopRTCCallRefreshLoop()
            disconnectRealtime(shouldReconnect: false)
            apiContext.clearSession(sessionStore: protectedSessionStore)
            resetAuthenticatedRemoteData(showLoading: false)
            authScreen = .accountLogin
            loginWorkspaceSelectionMessage = nil
            toast = "登录状态未能安全保存，请重试"
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
            isAuthenticated = false
            authScreen = .accountLogin
            loginWorkspaceSelectionMessage = nil
            toast = data.pendingApprovalCount > 0 || !data.pendingEntryTenantID.isEmpty
                ? "入企申请等待审批中，审核通过后请重新登录。"
                : "企业登录会话暂不可用，请稍后重试"
            return
        }
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.workspaceResolutionEntered, generation: loginGeneration)
#endif
        loginDefaultWorkspaceID = normalizedDefaultWorkspaceID(from: data)
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
                enterprises = []
                currentEnterprise = Enterprise(id: "pending_workspace_selection", name: "请选择企业", code: "", role: "", status: "待选择", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)
            }
            let message = loginWorkspaceSelectionMessage(from: data, directory: appScopedDirectory)
                ?? (visibleAppScopedMemberships.isEmpty
                ? "当前账号在此 App 下暂无可进入企业，请联系管理员确认企业归属。"
                : "请选择本次要进入的企业。勾选后下次登录会按企业状态自动进入。")
            prepareLoginWorkspaceSelectionFromCurrentDirectory(message: message, loginGeneration: loginGeneration)
            if !visibleAppScopedMemberships.isEmpty, isWorkspaceSwitchDisabledByPolicy {
                loginWorkspaceSelectionMessage = "管理员已关闭企业切换；系统会优先自动进入最近可用企业。当前未获取到可直接进入的企业会话，请联系管理员确认企业成员状态。"
                toast = "未获取到可直接进入的企业会话"
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
            loginWorkspaceSelectionMessage = "管理员已关闭企业切换；系统会优先自动进入最近可用企业。当前未获取到可直接进入的企业会话，请联系管理员确认企业成员状态。"
            toast = "未获取到可直接进入的企业会话"
        }
    }

    private func loadAppScopedTenantDirectoryForLogin() async -> RemoteTenantDirectoryResult? {
        let platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !platformToken.isEmpty else { return nil }
        do {
            return try await api.myTenantDirectory(platformToken: platformToken, appID: currentAppID)
        } catch {
            return nil
        }
    }

    private func loginWorkspaceSelectionMessage(from data: RemoteTenantLoginData, directory: RemoteTenantDirectoryResult? = nil) -> String? {
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

    private func prepareLoginWorkspaceSelection(from data: RemoteTenantLoginData, loginGeneration: Int) {
        isAuthenticated = false
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        recordAccessDiagnosticsMerchantResolving(name: "待选择")
        apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        if data.workspaces.isEmpty {
            enterprises = []
            currentEnterprise = Enterprise(id: "pending_workspace_selection", name: "请选择企业", code: "", role: "", status: "待选择", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)
        }
        authScreen = .workspaceSelection
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.workspaceSelectionTerminal, generation: loginGeneration)
#endif
        loginWorkspaceSelectionMessage = loginWorkspaceSelectionMessage(from: data)
            ?? "请选择本次要进入的企业。勾选后下次登录会按企业状态自动进入。"
    }

    private func loginEntryStatus(from data: RemoteTenantLoginData) -> String {
        data.entryStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedDefaultWorkspaceID(from data: RemoteTenantLoginData) -> String {
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

    @discardableResult
    private func attemptDefaultWorkspaceAutoEnter(
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
                toast = "登录状态已变化，请重新选择企业"
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
                loginWorkspaceSelectionMessage = "\(securityInfo.userMessage)。请选择其他可进入企业。"
                toast = securityInfo.userMessage
            } else if let code = workspaceAccessCode(from: error) {
                if code == "workspace_switch_disabled" {
                    loginWorkspaceSelectionMessage = "管理员已关闭企业切换；请使用服务端自动下发的最近可用企业会话进入。"
                    toast = "管理员已关闭企业切换"
                    return true
                }
                let message = shouldPersistWorkspaceEntryAccessBlock(code)
                    ? workspaceAccessMessage(for: code)
                    : platformWorkspaceSwitchFailureMessage(error)
                if shouldPersistWorkspaceEntryAccessBlock(code) {
                    _ = markWorkspaceAccessBlocked(code, enterpriseID: defaultEnterprise.id)
                }
                loginWorkspaceSelectionMessage = "\(message)。请选择其他可进入企业。"
                toast = message
            } else {
                let message = platformWorkspaceSwitchFailureMessage(error)
                loginWorkspaceSelectionMessage = "\(message)。请选择其他可进入企业。"
                toast = message
            }
            return true
        }
    }

    private func loginWithOptionalSlideCaptcha(
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

    private func canEnterDefaultWorkspaceFromLoginSession(_ data: RemoteTenantLoginData, enterprise: Enterprise) -> Bool {
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
                loginWorkspaceSelectionMessage = "\(message)。请选择其他可进入企业。"
                toast = message
            } else {
                toast = platformWorkspaceSwitchFailureMessage(error)
            }
            return true
        }
    }

    func prepareLoginWorkspaceSelectionFromCurrentDirectory(message: String, loginGeneration: Int) {
        isAuthenticated = false
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        authScreen = .workspaceSelection
#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        PostLoginSuccessConsumptionDiagnostics.advance(.workspaceSelectionTerminal, generation: loginGeneration)
#endif
        loginWorkspaceSelectionMessage = message
    }

    private func startPostLoginRemoteSnapshotRefresh(
        generation: Int,
        context: IMAPIContext,
        immediateToast: String?,
        syncedToast: String?,
        fallbackToast: String?
    ) {
        if let immediateToast {
            toast = immediateToast
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
                self.toast = syncedToast
            } else if let syncFailureMessage = self.syncFailureMessage {
                self.toast = syncFailureMessage
            } else if let fallbackToast {
                self.toast = fallbackToast
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
                loginDefaultWorkspaceID = result.defaultWorkspaceID
            }
            if let workspace = result.defaultWorkspace {
                upsertEnterprise(enterprise(from: workspace, fallbackAccent: currentEnterprise.accentHex))
            }
        } catch {
            guard isCurrentRemoteScope(remoteDataScopeKey(for: context)) else { return }
            print("[JHT Auth] workspace_entry_confirm_failed code=\(workspaceAccessCode(from: error) ?? "unknown") tenant_present=\(!tenantID.isEmpty)")
        }
    }

    private func defaultWorkspaceEnterprise(from data: RemoteTenantLoginData, defaultWorkspaceID: String) -> Enterprise? {
        let trimmedDefaultID = defaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDefaultID.isEmpty else { return nil }
        let defaultWorkspace = data.workspaces.first { $0.id == trimmedDefaultID }
            ?? data.defaultWorkspace.flatMap { $0.id == trimmedDefaultID ? $0 : nil }
        return defaultWorkspace.map { enterprise(from: $0, fallbackAccent: currentEnterprise.accentHex) }
    }

    private func applyLoginWorkspaceState(from data: RemoteTenantLoginData) {
        guard !data.workspaces.isEmpty else { return }
        applyWorkspaces(data.workspaces)
        let preferredIDs = [
            data.autoEnteredWorkspaceID,
            data.tenant?.tenantID ?? "",
            apiContext.tenantID ?? ""
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let current = preferredIDs.compactMap({ id in enterprises.first(where: { $0.id == id }) }).first {
            currentEnterprise = current
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

    private func tenantLoginData(
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

    func registerWithDefaultEnterprise(phone: String = "", account: String = "", password: String = "", captchaCode: String = "") {
        registerAndEnterIM(phone: phone, account: account, password: password,
                           enterpriseCode: "", captchaCode: captchaCode)
    }

    private func makePreloginCaptchaValidityCheck(context: IMAPIContext) -> () -> Bool {
        let authGeneration = authFlowGeneration.currentToken()
        let enterpriseGeneration = enterpriseContextGeneration.currentToken()
        let screen = authScreen
        let scope = remoteDataScopeKey(for: context)
        return { [weak self] in
            guard let self, !Task.isCancelled else { return false }
            return self.authFlowGeneration.isCurrent(authGeneration)
                && self.enterpriseContextGeneration.isCurrent(enterpriseGeneration)
                && self.authScreen == screen
                && IMAPIContext.normalizedIOSAppID(self.apiContext.appID) == IMAPIContext.normalizedIOSAppID(context.appID)
                && self.apiContext.deviceID == context.deviceID
                && self.remoteDataScopeKey(for: self.apiContext) == scope
        }
    }

    func sendRegisterCaptcha(phone: String, tenantCode: String = "") async -> Int? {
        guard isRegistrationEnabledForAuthUI else {
            authScreen = .accountLogin
            toast = EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage
            return nil
        }
        let normalized = normalizedMainlandPhone(phone)
        guard isValidMainlandPhone(normalized) else {
            toast = "请输入正确的手机号"
            return nil
        }
        guard let policy = await ensureCurrentAppPolicyForAuth() else {
            return nil
        }
        guard policy.registrationEnabled else {
            authScreen = .accountLogin
            toast = EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage
            return nil
        }
        guard policy.phoneAuthEnabled, !isPhoneAuthDisabledByServer else {
            disablePhoneAuthForCurrentApp()
            return nil
        }
        let enterpriseContext = requirePreAuthEnterpriseContextIfConfigured()
        if policy.enterpriseCodeFirst, enterpriseContext == nil { return nil }
        let normalizedTenantCode = enterpriseContext?.tenantCode ?? normalizedRegistrationTenantCode(tenantCode)
        if !policy.enterpriseCodeFirst,
           !tenantCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isValidRegistrationTenantCode(tenantCode) {
            toast = "请输入企业编码或邀请码"
            return nil
        }
        if !policy.allowDefaultTenantJoin, normalizedTenantCode.isEmpty {
            toast = "请输入企业编码或邀请码后再获取验证码"
            return nil
        }
        let context = apiContext
        let isCurrent = makePreloginCaptchaValidityCheck(context: context)
        do {
            let required = try await canSendCaptcha(scene: "register", channel: "sms", appID: context.appID, tenantCode: normalizedTenantCode, fallbackToCurrentTenant: false)
            guard isCurrent() else { return nil }
            guard required else {
                toast = "当前注册流程无需验证码"
                return nil
            }
            let result = try await api.sendTenantCaptcha(
                phone: normalized,
                scene: "register",
                tenantCode: normalizedTenantCode,
                context: context
            )
            guard isCurrent() else { return nil }
            toast = phoneCodeSuccessMessage(result, fallbackMinutes: 10)
            return phoneCodeCooldownSeconds(result)
        } catch {
            guard isCurrent() else { return nil }
            if !handlePhoneAuthDisabledError(error) {
                handleRemoteError(error, fallback: "验证码发送失败")
            }
            return nil
        }
    }

    func sendPasswordResetCaptcha(account: String) async -> Int? {
        let normalized = normalizedMainlandPhone(account)
        guard isValidMainlandPhone(normalized) else {
            toast = "请输入正确的手机号"
            return nil
        }
        let context = apiContext
        let isCurrent = makePreloginCaptchaValidityCheck(context: context)
        let tenantCode = captchaTenantCode()
        do {
            let required = try await canSendCaptcha(scene: "password_reset", channel: "sms", appID: context.appID, tenantCode: tenantCode)
            guard isCurrent() else { return nil }
            guard required else {
                toast = "当前找回密码流程无需验证码"
                return nil
            }
            let result = try await api.sendTenantCaptcha(
                phone: normalized,
                scene: "password_reset",
                tenantCode: tenantCode,
                context: context
            )
            guard isCurrent() else { return nil }
            toast = phoneCodeSuccessMessage(result, fallbackMinutes: 10)
            return phoneCodeCooldownSeconds(result)
        } catch {
            guard isCurrent() else { return nil }
            handleRemoteError(error, fallback: "验证码发送失败")
            return nil
        }
    }

    func resetPassword(account: String, code: String, newPassword: String) async -> Bool {
        let phone = normalizedMainlandPhone(account)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidMainlandPhone(phone) else {
            toast = "请输入正确的手机号"
            return false
        }
        guard normalizedCode.count == 6,
              normalizedCode.allSatisfy(\.isNumber) else {
            toast = "请输入 6 位验证码"
            return false
        }
        guard newPassword.count >= 8,
              newPassword.count <= 20,
              newPassword.rangeOfCharacter(from: .letters) != nil,
              newPassword.rangeOfCharacter(from: .decimalDigits) != nil else {
            toast = "新密码需为 8-20 位字母和数字组合"
            return false
        }
        do {
            let response = try await api.resetPassword(
                phone: phone,
                code: normalizedCode,
                newPassword: newPassword
            )
            guard response.reset else {
                toast = "密码重置未完成，请重试"
                return false
            }
            toast = "密码已更新，请重新登录"
            return true
        } catch {
            handleRemoteError(error, fallback: "密码重置失败，请重试")
            return false
        }
    }

    func clearApplicationCaches() async {
        guard !isClearingApplicationCache else { return }
        isClearingApplicationCache = true
        let indexedResult = await clearCurrentIndexedMediaCache()
        let legacyResult = await AppCacheCleaner.clear()
        let result = AppCacheCleanupResult(
            bytesRemoved: indexedResult.bytesRemoved + legacyResult.bytesRemoved,
            failures: indexedResult.failures + legacyResult.failures
        )
        URLCache.shared.removeAllCachedResponses()
        AvatarImageCache.shared.removeAllImages()
        fileStore.clearLocalAttachmentResources()
        isClearingApplicationCache = false
        let size = ByteCountFormatter.string(fromByteCount: result.bytesRemoved, countStyle: .file)
        if result.failures.isEmpty {
            toast = result.bytesRemoved > 0 ? "已清理 \(size) 缓存" : "当前没有可清理缓存"
        } else if result.bytesRemoved > 0 {
            toast = "已清理 \(size)，部分缓存清理失败"
        } else {
            toast = "缓存清理失败，请稍后重试"
        }
    }

    var requiresChatBiometricProtection: Bool {
        biometricProtectionSettings.enabled && biometricProtectionSettings.unlockChats
    }

    var requiresFileBiometricProtection: Bool {
        biometricProtectionSettings.enabled && biometricProtectionSettings.previewFiles
    }

    var biometricAccessScopeToken: String {
        "\(BiometricProtectionStore.scopeKey(context: apiContext))#\(biometricAccessRevision)"
    }

    private var biometricAuthorizationScopeToken: String {
        "\(BiometricProtectionStore.scopeKey(context: apiContext))#\(biometricAuthorizationRevision)"
    }

    func isProtectedAccessAuthorized(_ surface: BiometricProtectedSurface) -> Bool {
        let required: Bool
        switch surface {
        case .chat: required = requiresChatBiometricProtection
        case .filePreview: required = requiresFileBiometricProtection
        }
        guard required else { return true }
        return biometricAuthorizedAccessTokens[surface] == biometricAccessScopeToken
    }

    func revokeBiometricProtectedAccess() {
        guard !biometricAuthorizedAccessTokens.isEmpty else { return }
        biometricAuthorizedAccessTokens.removeAll()
    }

    func saveBiometricProtectionSettings(
        enabled: Bool,
        unlockChats: Bool,
        previewFiles: Bool
    ) async -> Bool {
        let context = apiContext
        let scopeKey = BiometricProtectionStore.scopeKey(context: context)
        let requiresEnableAuthentication = enabled && !biometricProtectionSettings.enabled
        if requiresEnableAuthentication {
            do {
                try await biometricAuthenticator.authenticate(reason: "验证身份以启用 Face ID 保护")
            } catch {
                toast = biometricAuthenticationFailureMessage(error)
                return false
            }
        }
        guard BiometricProtectionStore.scopeKey(context: apiContext) == scopeKey else {
            toast = "登录状态已变化，请重新设置 Face ID"
            return false
        }
        let next = BiometricProtectionSettings(
            enabled: enabled,
            unlockChats: unlockChats,
            previewFiles: previewFiles
        )
        do {
            try BiometricProtectionStore.save(next, context: context, defaults: biometricDefaults)
            biometricProtectionSettings = next
            biometricAccessRevision &+= 1
            biometricAuthorizationRevision &+= 1
            revokeBiometricProtectedAccess()
            toast = enabled ? "Face ID 设置已保存" : "Face ID 已关闭"
            return true
        } catch {
            toast = "Face ID 设置保存失败，请重试"
            return false
        }
    }

    func authorizeProtectedAccess(_ surface: BiometricProtectedSurface) async -> Bool {
        let authorizationScopeToken = biometricAuthorizationScopeToken
        let required: Bool
        switch surface {
        case .chat: required = requiresChatBiometricProtection
        case .filePreview: required = requiresFileBiometricProtection
        }
        guard required else { return true }
        do {
            try await biometricAuthenticator.authenticate(reason: surface.reason)
        } catch {
            toast = biometricAuthenticationFailureMessage(error)
            return false
        }
        guard biometricAuthorizationScopeToken == authorizationScopeToken else {
            toast = "登录状态已变化，请重新验证"
            return false
        }
        let stillRequired: Bool
        switch surface {
        case .chat:
            stillRequired = requiresChatBiometricProtection
        case .filePreview:
            stillRequired = requiresFileBiometricProtection
        }
        if stillRequired {
            biometricAuthorizedAccessTokens[surface] = biometricAccessScopeToken
        }
        return stillRequired
    }

    private func biometricAuthenticationFailureMessage(_ error: Error) -> String {
        let code: LAError.Code?
        if let laError = error as? LAError {
            code = laError.code
        } else {
            let nsError = error as NSError
            code = nsError.domain == LAError.errorDomain ? LAError.Code(rawValue: nsError.code) : nil
        }
        guard let code else { return "Face ID 验证失败，请重试" }
        switch code {
        case .biometryNotAvailable: return "此设备不支持 Face ID"
        case .biometryNotEnrolled: return "请先在系统设置中录入 Face ID"
        case .biometryLockout: return "Face ID 已锁定，请先在系统设置中解锁"
        case .userCancel, .appCancel, .systemCancel: return "Face ID 验证已取消"
        default: return "Face ID 验证失败，请重试"
        }
    }

    @discardableResult
    func enterIM(showToast: Bool = true) -> PostLoginWorkbenchAdmissionOutcome {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let admission = postLoginWorkbenchAdmission.consume(
            hasIMSession: context.hasIMSession,
            scope: scope
        )
        switch admission {
        case .rejectedMissingSession:
            launchSplashDismissTasks.cancel()
            isShowingLaunchSplash = false
            dismissSplashOverlay(reason: "post_login_missing_session", cancelTask: true)
            isRestoringSession = false
            isAuthenticated = false
            stopInboxRefreshLoop()
            stopRTCCallRefreshLoop()
            disconnectRealtime(shouldReconnect: false)
            resetAuthenticatedRemoteData(showLoading: false)
            disableAccessDiagnosticsOverlay()
            apiContext.clearSession(sessionStore: protectedSessionStore)
            authScreen = .accountLogin
            loginWorkspaceSelectionMessage = nil
            toast = "登录会话未完成，请重新登录"
            return admission
        case .duplicate:
            launchSplashDismissTasks.cancel()
            isShowingLaunchSplash = false
            dismissSplashOverlay(reason: "post_login_duplicate", cancelTask: true)
            return admission
        case .admitted:
            launchSplashDismissTasks.cancel()
            isShowingLaunchSplash = false
            dismissSplashOverlay(reason: "post_login_admitted", cancelTask: true)
	        }
	        beginMainShellBootstrapTrace(reason: "enter_im")
	        isAuthenticated = true
	        bindCallRecordPersistence(for: context)
	        activateMyInviteCodeForCurrentSession()
	        activeTab = .chats
        startSplashConfigurationRefresh(
            context: context,
            intent: .tenantEntry,
            reason: "enter_im"
        )
        startInboxRefreshLoop()
        startRTCCallRefreshLoop()
        startRealtimeConnection(context: context)
        replayDeferredNotificationOpensIfPossible()
        registerPendingStandardPushDeviceIfPossible(reason: "enter_im")
        registerPendingVoIPDeviceIfPossible(reason: "enter_im")
        if showToast {
            toast = "已进入 \(currentEnterprise.name)"
        }
        return admission
    }

    func beginMainShellBootstrapTrace(reason: String) {
        mainShellBootstrapTrace.begin()
        print("[JHT Perf] main_shell_bootstrap_start reason=\(reason) scope=\(Self.sessionScopeLogToken(remoteDataScopeKey(for: apiContext)))")
    }

    nonisolated static func sessionScopeLogToken(_ rawScope: String) -> String {
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty else { return "scope:empty" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in scope.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "scope:hash:\(String(hash, radix: 16).suffix(12))"
    }

    func noteMainShellAppeared() {
        ensureRTCSignalingRefreshActive(reason: "main_shell_appear")
        if splashConfigurationRefreshTask == nil,
           !didEvaluateInitialSplashOverlay,
           !pendingInitialSplashOverlayEvaluation,
           apiContext.hasIMSession {
            startSplashConfigurationRefresh(
                context: apiContext,
                intent: isShowingLaunchSplash ? .coldLaunch : .refreshOnly,
                reason: "main_shell_appear"
            )
        }
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                self?.noteMainShellInteractive(reason: "post_appear")
            }
        }
        guard let elapsed = mainShellBootstrapTrace.claimAppearance() else { return }
        print("[JHT Perf] main_shell_appeared_ms=\(elapsed) conversations=\(conversations.count) cached=\(hasLoadedRemoteSnapshot)")
    }

    func dismissSplashOverlay() {
        guard let presentation = activeSplashOverlay,
              presentation.canSkip() else {
            return
        }
        dismissSplashOverlay(reason: "skip", cancelTask: true)
    }

    func startSplashConfigurationRefresh(
        context: IMAPIContext,
        intent: SplashPresentationIntent,
        reason: String
    ) {
        guard context.hasIMSession,
              let splashScope = splashTenantScope(for: context) else {
            finishSplashPresentationIntent(
                intent,
                result: .noSession,
                trigger: reason,
                deadline: nil
            )
            return
        }
        let remoteScope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(remoteScope) else { return }

        splashConfigurationRefreshTask?.cancel()
        let generation = splashConfigurationRefreshGeneration.issueToken()
        let now = Date()
        let deadline = intent.presentationWindowSeconds.map { now.addingTimeInterval($0) }
        if intent.allowsPresentation {
            resetInitialSplashOverlayEvaluationState()
            initialSplashOverlayEvaluationStartedAt = now
            pendingInitialSplashOverlayEvaluation = true
            SplashSnapshotStore.disableSnapshot(
                scope: splashScope,
                reason: "refresh_pending"
            )
        }

        splashConfigurationRefreshTask = Task { @MainActor [weak self, context, splashScope, remoteScope, intent, reason, deadline] in
            guard let self else { return }
            defer {
                if self.splashConfigurationRefreshGeneration.isCurrent(generation) {
                    self.splashConfigurationRefreshTask = nil
                }
            }
            do {
                let remote = try await self.fetchScopedFileUploadConfig(context: context, scope: remoteScope)
                guard self.isCurrentSplashRefresh(
                    generation: generation,
                    scope: splashScope,
                    remoteScope: remoteScope
                ) else {
                    return
                }
                self.handleSplashConfiguration(
                    remote.splashConfiguration,
                    context: context,
                    scope: remoteScope,
                    source: "splash_refresh_\(reason)",
                    splashScope: splashScope,
                    intent: intent,
                    refreshGeneration: generation,
                    deadline: deadline
                )
            } catch {
                guard self.isCurrentSplashRefresh(
                    generation: generation,
                    scope: splashScope,
                    remoteScope: remoteScope
                ) else {
                    return
                }
                SplashSnapshotStore.disableSnapshot(
                    scope: splashScope,
                    reason: "refresh_failed"
                )
                self.finishSplashPresentationIntent(
                    intent,
                    result: .blockedByPolicy("refresh_failed"),
                    trigger: reason,
                    deadline: deadline
                )
                print("[JHT Splash] config_refresh_failed tenant=\(splashScope.tenantID) trigger=\(reason)")
            }
        }
    }

    func isCurrentSplashRefresh(
        generation: Int,
        scope: SplashTenantScope,
        remoteScope: String
    ) -> Bool {
        splashConfigurationRefreshGeneration.isCurrent(generation)
            && isCurrentRemoteScope(remoteScope)
            && splashTenantScope(for: apiContext) == scope
    }

    func prepareSplashForScopeChange(reason: String) {
        resetBatchForwardDraftForScopeChange()
        splashConfigurationRefreshTask?.cancel()
        splashConfigurationRefreshTask = nil
        splashConfigurationRefreshGeneration.invalidate()
        dismissSplashOverlay(reason: reason, cancelTask: true)
        resetInitialSplashOverlayEvaluationState()
    }

    func resetBatchForwardDraftForScopeChange() {
        invalidateBatchForwardSubmission()
        batchForwardState = nil
        batchForwardSourceConversationID = nil
    }

    func invalidateBatchForwardSubmission() {
        batchForwardSubmissionGeneration &+= 1
        batchForwardSubmissionTask?.cancel()
        batchForwardSubmissionTask = nil
    }

    func presentSplashIfAllowed(
        intent: SplashPresentationIntent,
        candidate: SplashRefreshCandidate,
        preparedImage: SplashPreparedImage,
        remoteScope: String,
        trigger: String,
        deadline: Date?
    ) {
        guard intent.allowsPresentation else { return }
        guard isCurrentSplashRefresh(
            generation: candidate.generation,
            scope: candidate.scope,
            remoteScope: remoteScope
        ),
        candidate.matches(
            currentGeneration: splashConfigurationRefreshGeneration.currentToken(),
            currentScope: splashTenantScope(for: apiContext),
            snapshot: SplashSnapshotStore.snapshot(scope: candidate.scope)
        ) else {
            return
        }
        let now = Date()
        guard deadline.map({ now <= $0 }) ?? true else {
            finishSplashPresentationIntent(
                intent,
                result: .blockedByPolicy("presentation_window_expired"),
                trigger: trigger,
                deadline: deadline
            )
            return
        }
        if intent == .coldLaunch {
            guard canPresentColdLaunchSplash(
                hasMainShellBecomeInteractive: hasMainShellBecomeInteractive
            ) else {
                finishSplashPresentationIntent(
                    intent,
                    result: .blockedByPolicy("main_shell_interactive"),
                    trigger: trigger,
                    deadline: deadline
                )
                return
            }
        }
        let result = evaluateSplashOverlay(
            reason: trigger,
            isColdStartLike: true,
            now: now,
            allowReplacingLaunchSplash: true,
            candidate: candidate,
            preparedImage: preparedImage
        )
        finishSplashPresentationIntent(
            intent,
            result: result,
            trigger: trigger,
            deadline: deadline
        )
    }

    func finishSplashPresentationIntent(
        _ intent: SplashPresentationIntent,
        result: SplashOverlayEvaluationResult,
        trigger: String,
        deadline: Date?
    ) {
        guard intent.allowsPresentation else { return }
        let now = Date()
        if intent == .coldLaunch {
            handleInitialSplashOverlayEvaluation(result, trigger: trigger, now: now)
            return
        }
        if result.keepsInitialEvaluationPending,
           deadline.map({ now <= $0 }) ?? false {
            pendingInitialSplashOverlayEvaluation = true
            return
        }
        didEvaluateInitialSplashOverlay = true
        pendingInitialSplashOverlayEvaluation = false
        print("[JHT Splash] scoped_overlay_evaluation_consumed result=\(result.reason) trigger=\(trigger)")
    }

    func evaluateForegroundSplashOverlayIfNeeded(now: Date = Date()) {
        guard let scope = splashTenantScope(for: apiContext) else { return }
        let displayState = SplashSnapshotStore.displayState(scope: scope)
        guard let lastBackgroundedAt = displayState.lastBackgroundedAt else { return }
        let elapsed = now.timeIntervalSince1970 - lastBackgroundedAt
        if elapsed < splashWarmThresholdSeconds {
            return
        }
        guard elapsed >= splashColdEquivalentThresholdSeconds else {
            return
        }
        startSplashConfigurationRefresh(
            context: apiContext,
            intent: .foregroundColdEquivalent,
            reason: "foreground_cold_equivalent"
        )
    }

    @discardableResult
    private func evaluateSplashOverlay(
        reason: String,
        isColdStartLike: Bool,
        now: Date = Date(),
        allowReplacingLaunchSplash: Bool = false,
        candidate: SplashRefreshCandidate,
        preparedImage: SplashPreparedImage
    ) -> SplashOverlayEvaluationResult {
        guard isColdStartLike else {
            return logSplashOverlaySkip(.notColdStartLike, tenantID: nil, trigger: reason)
        }
        guard isAuthenticated else {
            return logSplashOverlaySkip(.notAuthenticated, tenantID: nil, trigger: reason)
        }
        guard apiContext.hasIMSession else {
            return logSplashOverlaySkip(.noSession, tenantID: nil, trigger: reason)
        }
        guard activeSplashOverlay == nil else {
            return logSplashOverlaySkip(.overlayAlreadyActive, tenantID: activeSplashOverlay?.tenantID, trigger: reason)
        }
        guard let scope = splashTenantScope(for: apiContext),
              scope == candidate.scope else {
            return logSplashOverlaySkip(.noTenant, tenantID: nil, trigger: reason)
        }
        let tenantID = scope.tenantID
        guard let snapshot = SplashSnapshotStore.snapshot(scope: scope) else {
            return logSplashOverlaySkip(.notReadyNoSnapshot, tenantID: tenantID, trigger: reason)
        }
        guard candidate.matches(
            currentGeneration: splashConfigurationRefreshGeneration.currentToken(),
            currentScope: scope,
            snapshot: snapshot
        ) else {
            return logSplashOverlaySkip(.blockedByPolicy("stale_candidate"), tenantID: tenantID, trigger: reason)
        }
        guard snapshot.tenantID == tenantID else {
            return logSplashOverlaySkip(.blockedByPolicy("tenant_mismatch"), tenantID: tenantID, trigger: reason)
        }
        guard snapshot.isConfigDisplayable else {
            let policyReason = snapshot.disabledReason.trimmingCharacters(in: .whitespacesAndNewlines)
            return logSplashOverlaySkip(.blockedByPolicy(policyReason.isEmpty ? "config_not_displayable" : policyReason), tenantID: tenantID, trigger: reason)
        }
        guard let cacheKey = snapshot.cacheKey(scope: scope) else {
            return logSplashOverlaySkip(.blockedByPolicy("missing_cache_key"), tenantID: tenantID, trigger: reason)
        }
        guard cacheKey == candidate.cacheKey,
              preparedImage.fileURL == SplashImageDiskCache.shared.fileURL(for: cacheKey) else {
            return logSplashOverlaySkip(.blockedByPolicy("prepared_image_mismatch"), tenantID: tenantID, trigger: reason)
        }
        let displayState = SplashSnapshotStore.displayState(scope: scope)
        guard displayState.canPresent(
            snapshot: snapshot,
            at: now,
            isColdStartLike: true,
            alreadyShownInThisLaunch: didPresentSplashInCurrentActivation
        ) else {
            return logSplashOverlaySkip(.blockedByPolicy("already_shown_in_activation"), tenantID: tenantID, trigger: reason)
        }
        if isShowingLaunchSplash, !allowReplacingLaunchSplash {
            return logSplashOverlaySkip(.launchSplashActive, tenantID: tenantID, trigger: reason)
        }

        let presentation = SplashOverlayPresentation(
            snapshot: snapshot,
            preparedImage: preparedImage,
            startedAt: now
        )
        didPresentSplashInCurrentActivation = true
        SplashSnapshotStore.recordShown(snapshot: snapshot, scope: scope, at: now)
        splashOverlayRemainingSeconds = max(1, Int(ceil(Double(presentation.maxShowMS) / 1000.0)))
        isSplashOverlaySkippable = presentation.canSkip(at: now)
        withAnimation(.easeOut(duration: 0.18)) {
            if isShowingLaunchSplash {
                launchSplashDismissTasks.cancel()
                isShowingLaunchSplash = false
            }
            activeSplashOverlay = presentation
        }
        scheduleSplashOverlayAutoDismiss(presentation)
        print("[JHT Splash] overlay_show tenant=\(tenantID) version=\(snapshot.normalizedVersion) trigger=\(reason) min_ms=\(presentation.minShowMS) max_ms=\(presentation.maxShowMS)")
        return .shown
    }

    @discardableResult
    private func logSplashOverlaySkip(_ result: SplashOverlayEvaluationResult, tenantID: String?, trigger: String) -> SplashOverlayEvaluationResult {
        let tenant = tenantID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tenant, !tenant.isEmpty {
            print("[JHT Splash] overlay_skip tenant=\(tenant) reason=\(result.reason) trigger=\(trigger)")
        } else {
            print("[JHT Splash] overlay_skip reason=\(result.reason) trigger=\(trigger)")
        }
        return result
    }

    private func handleInitialSplashOverlayEvaluation(
        _ result: SplashOverlayEvaluationResult,
        trigger: String,
        now: Date = Date()
    ) {
        if result.keepsInitialEvaluationPending, isWithinInitialSplashOverlayRetryWindow(now: now) {
            pendingInitialSplashOverlayEvaluation = true
            return
        }
        didEvaluateInitialSplashOverlay = true
        pendingInitialSplashOverlayEvaluation = false
        print("[JHT Splash] initial_overlay_evaluation_consumed result=\(result.reason) trigger=\(trigger)")
    }

    private func isWithinInitialSplashOverlayRetryWindow(now: Date = Date()) -> Bool {
        guard let startedAt = initialSplashOverlayEvaluationStartedAt else { return false }
        return now.timeIntervalSince(startedAt) <= initialSplashOverlayRetryWindowSeconds
    }

    func resetInitialSplashOverlayEvaluationState() {
        didEvaluateInitialSplashOverlay = false
        pendingInitialSplashOverlayEvaluation = false
        initialSplashOverlayEvaluationStartedAt = nil
        didPresentSplashInCurrentActivation = false
    }

    private func scheduleSplashOverlayAutoDismiss(_ presentation: SplashOverlayPresentation) {
        splashOverlayDismissTask?.cancel()
        splashOverlayDismissTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let elapsedMS = max(
                    0,
                    Int((now.timeIntervalSince1970 - presentation.startedAt) * 1_000)
                )
                if elapsedMS >= presentation.maxShowMS {
                    break
                }
                guard self?.activeSplashOverlay?.id == presentation.id else { return }
                self?.isSplashOverlaySkippable = presentation.canSkip(at: now)
                let remainingMS = max(0, presentation.maxShowMS - elapsedMS)
                self?.splashOverlayRemainingSeconds = max(1, Int(ceil(Double(remainingMS) / 1000.0)))
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
            guard self?.activeSplashOverlay?.id == presentation.id else { return }
            self?.dismissSplashOverlay(reason: "auto", cancelTask: false)
        }
    }

    func dismissSplashOverlay(reason: String, cancelTask: Bool) {
        if cancelTask {
            splashOverlayDismissTask?.cancel()
        }
        splashOverlayDismissTask = nil
        guard activeSplashOverlay != nil else {
            splashOverlayRemainingSeconds = 0
            isSplashOverlaySkippable = false
            return
        }
        withAnimation(.easeOut(duration: 0.22)) {
            activeSplashOverlay = nil
            splashOverlayRemainingSeconds = 0
            isSplashOverlaySkippable = false
        }
        print("[JHT Splash] overlay_dismiss reason=\(reason)")
    }

    func splashTenantScope(for context: IMAPIContext) -> SplashTenantScope? {
        let principalID = [
            context.accountID,
            context.imUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let tenantBaseURL = IMAPIClient.normalizedTenantAPIBaseURL(context.tenantAPIBaseURL)
            ?? api.tenantBase
        let tenantOrigin = SplashTenantScope.normalizedTenantAPIOrigin(
            tenantBaseURL.absoluteString
        )
        let scope = SplashTenantScope(
            appID: IMAPIContext.normalizedIOSAppID(context.appID),
            accountID: principalID,
            tenantID: context.tenantID ?? "",
            tenantOrigin: tenantOrigin
        )
        return scope.isValid ? scope : nil
    }

    private func noteMainShellInteractive(reason: String) {
		(api as? IMAPIClient)?.finishRuntimeColdLaunch()
        hasMainShellBecomeInteractive = true
        guard let elapsed = mainShellBootstrapTrace.claimInteractive() else { return }
        print("[JHT Perf] main_shell_interactive_ms=\(elapsed) reason=\(reason) conversations=\(conversations.count)")
    }

    func logout() {
        prepareSplashForScopeChange(reason: "logout")
        cancelRegistrationConfirmationPolling()
        clearRegistrationRecovery()
        pendingRegistrationReceiptStore.clear()
        registrationResolutionState = nil
        registrationConfirmationTimedOut = false
        coldLaunchSessionRecoveryTask?.cancel()
        coldLaunchSessionRecoveryTask = nil
        let logoutContext = apiContext
        retirePushDevices(for: logoutContext)
        clearPushRegistrationState()
        let rememberWasEnabled = rememberLoginCredentialsEnabledForAuthUI
        // A normal logout preserves committed remember-me credentials, but must
        // invalidate any in-flight login attempt before fencing its response.
        pendingRememberedLoginAttempt = nil
        purgeCertificationIdentityRoot(rebindCurrentScope: false)
        EmojiPickerPreferenceLifecycle.purgePreviousAuthenticatedScope(
            hasAuthenticatedSession: logoutContext.hasIMSession,
            product: "ios",
            appID: IMAPIContext.normalizedIOSAppID(logoutContext.appID),
            accountID: logoutContext.accountID,
            tenantID: logoutContext.tenantID,
            imUID: logoutContext.imUID
        )
        Task { [api] in
            await api.logoutAuthSessions(context: logoutContext)
        }
        let didScheduleLocalCleanup = removeRemoteSnapshotCache(for: logoutContext)
        isAuthenticated = false
        isAuthLoading = false
        isRestoringSession = false
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        authFlowGeneration.invalidate()
        workspaceSwitchGeneration.invalidate()
        invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：退出登录清理临时企业码挑战
        clearLoginTenantCodeChallenge()
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        activeTab = .chats
        authScreen = .welcome
        loginWorkspaceSelectionMessage = nil
        loginDefaultWorkspaceID = ""
        resetForcedAppPolicyAuthState()
        clearTenantScopedSearchState(reason: "logout")
        disableAccessDiagnosticsOverlay()
        IMAPIContext.clearStoredSession(sessionStore: protectedSessionStore)
        apiContext = IMAPIContext.load(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        normalizeAuthScreenForCurrentAppPolicy()
        if rememberWasEnabled {
            rememberLoginCredentialsEnabledForAuthUI = true
        }
        toast = didScheduleLocalCleanup
            ? "已退出登录"
            : "本机数据安全清理失败，已阻止旧作用域缓存访问"
    }

    @discardableResult
    func cancelCurrentAccount(reason: String? = nil) async -> Bool {
        let cancellationContext = apiContext
        guard cancellationContext.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        do {
            let result = try await api.cancelAccount(context: cancellationContext, reason: reason)
            guard result.cancelled else {
                toast = "账号注销失败，请稍后重试"
                return false
            }
            finishAccountCancellationLocally(context: cancellationContext)
            toast = "账号已注销"
            return true
        } catch {
            guard isCurrentRemoteScope(remoteDataScopeKey(for: cancellationContext)) else { return false }
            handleRemoteError(error, fallback: "账号注销失败")
            return false
        }
    }

    private func finishAccountCancellationLocally(context: IMAPIContext) {
        coldLaunchSessionRecoveryTask?.cancel()
        coldLaunchSessionRecoveryTask = nil
        clearRememberedLoginCredentials()
        purgeCertificationIdentityRoot(rebindCurrentScope: false)
        fileStore.cancelAttachmentDownloadTasks()
        cancelVoiceCallWatchdog()
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        releaseAudioSessionForVoiceCall()
        authFlowGeneration.invalidate()
        workspaceSwitchGeneration.invalidate()
        invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：账号注销清理临时企业码挑战
        clearLoginTenantCodeChallenge()
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        isAuthLoading = false
        isRestoringSession = false
        prepareSplashForScopeChange(reason: "account_cancelled")
        clearPushRegistrationState()
        isAuthenticated = false
        activeTab = .chats
        authScreen = .welcome
        loginWorkspaceSelectionMessage = nil
        loginDefaultWorkspaceID = ""
        resetForcedAppPolicyAuthState()
        clearTenantScopedSearchState(reason: "account_cancelled")
        removeRemoteSnapshotCache(for: context)
        disableAccessDiagnosticsOverlay()
        IMAPIContext.clearStoredSession(resetDeviceIdentity: true, sessionStore: protectedSessionStore)
        apiContext = IMAPIContext.load(sessionStore: protectedSessionStore)
        currentEnterprise = Enterprise(id: "pending", name: "正在同步企业", code: "", role: "", status: "同步中", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)
        currentUser = IMUser(id: "pending", name: "正在同步", title: "", department: "", phone: "", email: "", status: "同步中", enterprise: "正在同步企业", avatarSeed: 0x5D6BFF, badges: [])
        resetAuthenticatedRemoteData(showLoading: false)
        normalizeAuthScreenForCurrentAppPolicy()
        remoteSyncEngine.clearRemoteErrorToastThrottle()
    }

    func handleCurrentDeviceRevoked() {
        guard isAuthenticated || apiContext.hasIMSession || apiContext.hasRefreshSession else { return }
        guard deviceRevocationHandling.begin() else { return }
        defer { deviceRevocationHandling.finish() }
        let revokedContext = apiContext
        clearPushRegistrationState()

        clearRememberedLoginCredentials()
        purgeCertificationIdentityRoot(rebindCurrentScope: false)
        prepareSplashForScopeChange(reason: "device_revoked")
        authFlowGeneration.invalidate()
        workspaceSwitchGeneration.invalidate()
        invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：设备吊销清理临时企业码挑战
        clearLoginTenantCodeChallenge()
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        isAuthLoading = false
        isRestoringSession = false
        remoteSyncEngine.cancelAuthSessionRefreshTask()
        coldLaunchSessionRecoveryTask?.cancel()
        coldLaunchSessionRecoveryTask = nil
        remoteSyncEngine.cancelRealtimeRecoveryTasks()
        conversationStore.cancelAllWarmRefreshTasks()
        fileStore.cancelAttachmentDownloadTasks()
        cancelVoiceCallWatchdog()
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)

        isAuthenticated = false
        activeTab = .chats
        authScreen = .accountLogin
        loginWorkspaceSelectionMessage = nil
        loginDefaultWorkspaceID = ""
        resetForcedAppPolicyAuthState()
        clearTenantScopedSearchState(reason: "device_revoked")
        removeRemoteSnapshotCache(for: revokedContext)
        disableAccessDiagnosticsOverlay()
        IMAPIContext.clearStoredSession(resetDeviceIdentity: true, sessionStore: protectedSessionStore)
        apiContext = IMAPIContext.load(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        normalizeAuthScreenForCurrentAppPolicy()
        remoteSyncEngine.clearRemoteErrorToastThrottle()
        toast = DeviceRevocationDetector.logoutMessage
    }

    private func workspaceEntryStatusMessage(_ state: RemoteWorkspaceEntryState, fallbackEnterpriseName: String) -> String {
        let name = state.tenantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackEnterpriseName
            : state.tenantName
        switch state.normalizedStatus {
        case "pending_approval":
            return "入企申请等待审批中，审核通过后再进入企业。"
        case "preparing":
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "企业数据正在准备中，请稍候。"
                : "\(name) 数据正在准备中，请稍候。"
        case "ready":
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "企业数据已准备好，正在进入。"
                : "\(name) 已准备好，正在进入。"
        case "entered":
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "企业已确认进入，正在同步。"
                : "\(name) 已确认进入，正在同步。"
        case "failed":
            let reason = state.lastError.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? "企业数据准备失败，请稍后重试。" : "企业数据准备失败：\(reason)"
        case "revoked":
            return "该企业进入资格已失效，请选择其他企业。"
        default:
            return "正在确认企业进入状态。"
        }
    }

    private func upsertWorkspaceEntryState(_ state: RemoteWorkspaceEntryState) {
        guard let workspace = state.workspace else { return }
        upsertEnterprise(enterprise(from: workspace, fallbackAccent: currentEnterprise.accentHex))
    }

    private func shouldContinueWorkspaceEntryPolling(
        generation: Int,
        switchGeneration: Int
    ) -> Bool {
        authFlowGeneration.isCurrent(generation)
            && workspaceSwitchGeneration.isCurrent(switchGeneration)
            && authScreen == .workspaceSelection
    }

    private func workspaceEntryPollDelayNanoseconds(_ pollAfterMS: Int) -> UInt64 {
        let bounded = min(max(pollAfterMS, 500), 10_000)
        return UInt64(bounded) * 1_000_000
    }

    private func waitForWorkspaceEntryReady(
        initialState: RemoteWorkspaceEntryState,
        fallbackEnterpriseName: String,
        platformToken: String,
        context: IMAPIContext,
        generation: Int,
        switchGeneration: Int
    ) async throws -> Bool {
        var state = initialState
        var remainingPolls = 30
        while true {
            guard shouldContinueWorkspaceEntryPolling(generation: generation, switchGeneration: switchGeneration) else {
                throw CancellationError()
            }
            upsertWorkspaceEntryState(state)
            loginWorkspaceSelectionMessage = workspaceEntryStatusMessage(state, fallbackEnterpriseName: fallbackEnterpriseName)
            switch state.normalizedStatus {
            case "ready", "entered":
                return true
            case "pending_approval":
                toast = "入企申请等待审批"
                return false
            case "failed":
                toast = "企业数据准备失败，请稍后重试"
                return false
            case "revoked":
                toast = "企业进入资格已失效"
                return false
            case "preparing", "none", "":
                guard remainingPolls > 0 else {
                    loginWorkspaceSelectionMessage = "企业数据仍在准备中，请稍后重试。"
                    toast = "企业数据仍在准备中"
                    return false
                }
                remainingPolls -= 1
                let tenantID = state.effectiveTenantID
                guard !tenantID.isEmpty else {
                    loginWorkspaceSelectionMessage = "企业进入状态暂不可确认，请稍后重试。"
                    toast = "企业进入状态暂不可确认"
                    return false
                }
                try await Task.sleep(nanoseconds: workspaceEntryPollDelayNanoseconds(state.pollAfterMS))
                state = try await api.workspaceEntryStatus(tenantID: tenantID, platformToken: platformToken, context: context)
            default:
                toast = "企业进入状态暂不可用"
                return false
            }
        }
    }

    private func prepareSelectedWorkspaceEntry(
        enterprise: Enterprise,
        generation: Int,
        switchGeneration: Int
    ) async throws -> Bool {
        var platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !platformToken.isEmpty else {
            toast = "登录会话已失效，请重新登录"
            authScreen = .accountLogin
            return false
        }
        loginWorkspaceSelectionMessage = "正在确认企业数据，请稍候。"
        let idempotencyKey = [
            "ios",
            apiContext.accountID ?? "",
            enterprise.id
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "-")
        let prepared: RemoteWorkspaceEntryState
        do {
            prepared = try await api.prepareWorkspaceEntry(
                tenantID: enterprise.id,
                entryCode: nil,
                entrySource: "workspace_selection",
                idempotencyKey: idempotencyKey.isEmpty ? nil : idempotencyKey,
                platformToken: platformToken,
                context: apiContext
            )
        } catch {
            if shouldDeferWorkspaceEntryPreflightUntilPlatformEnter(error) {
                loginWorkspaceSelectionMessage = "正在进入企业，请稍候。"
                return true
            }
            guard shouldRetryPlatformTenantEnterAfterSessionRefresh(error) else {
                throw error
            }
            let refreshed = await refreshStoredAuthSessionIfNeeded(
                reason: "workspace_prepare_unauthorized",
                silent: true,
                context: apiContext
            )
            guard authFlowGeneration.isCurrent(generation),
                  workspaceSwitchGeneration.isCurrent(switchGeneration) else {
                throw error
            }
            guard refreshed else {
                loginWorkspaceSelectionMessage = "正在进入企业，请稍候。"
                return true
            }
            platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !platformToken.isEmpty else {
                loginWorkspaceSelectionMessage = "正在进入企业，请稍候。"
                return true
            }
            do {
                prepared = try await api.prepareWorkspaceEntry(
                    tenantID: enterprise.id,
                    entryCode: nil,
                    entrySource: "workspace_selection",
                    idempotencyKey: idempotencyKey.isEmpty ? nil : idempotencyKey,
                    platformToken: platformToken,
                    context: apiContext
                )
            } catch {
                if shouldDeferWorkspaceEntryPreflightUntilPlatformEnter(error) {
                    loginWorkspaceSelectionMessage = "正在进入企业，请稍候。"
                    return true
                }
                guard shouldRetryPlatformTenantEnterAfterSessionRefresh(error) else {
                    throw error
                }
                loginWorkspaceSelectionMessage = "正在进入企业，请稍候。"
                return true
            }
        }
        return try await waitForWorkspaceEntryReady(
            initialState: prepared,
            fallbackEnterpriseName: enterprise.name,
            platformToken: platformToken,
            context: apiContext,
            generation: generation,
            switchGeneration: switchGeneration
        )
    }

    private func shouldDeferWorkspaceEntryPreflightUntilPlatformEnter(_ error: Error) -> Bool {
        guard case let IMAPIError.missingContext(field) = error else { return false }
        return field == "tenant_api_base_url"
    }

    func selectLoginWorkspace(_ enterprise: Enterprise, makeDefault: Bool) {
        let hasPlatformSession = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !isWorkspaceSwitchDisabledByPolicy else {
            toast = "管理员已关闭企业切换"
            authScreen = .accountLogin
            return
        }
        guard hasPlatformSession else {
            toast = "登录会话已失效，请重新登录"
            authScreen = .accountLogin
            return
        }
        guard enterprise.isWorkspaceEnterable, enterprise.canSwitch else {
            let reason = enterprise.workspaceDisabledDescription
            toast = reason.isEmpty ? "该企业暂不可进入，请联系管理员确认状态" : reason
            return
        }
        guard !isAuthLoading else { return }

        isAuthLoading = true
        let generation = authFlowGeneration.issueToken()
        let switchGeneration = workspaceSwitchGeneration.issueToken()
        Task {
            defer {
                if authFlowGeneration.isCurrent(generation),
                   workspaceSwitchGeneration.isCurrent(switchGeneration) {
                    isAuthLoading = false
                }
            }
            do {
                let entryReady = try await prepareSelectedWorkspaceEntry(
                    enterprise: enterprise,
                    generation: generation,
                    switchGeneration: switchGeneration
                )
                guard entryReady,
                      authFlowGeneration.isCurrent(generation),
                      workspaceSwitchGeneration.isCurrent(switchGeneration) else {
                    return
                }
                // 不再清缓存:进入(尤其重进同企业)时保留按 scope 隔离的本地快照,用于秒显。
                disconnectRealtime(shouldReconnect: false)
                apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
                resetAuthenticatedRemoteData(showLoading: true)
                try await switchPlatformTenant(
                    tenantID: enterprise.id,
                    isCurrent: {
                        self.authFlowGeneration.isCurrent(generation)
                            && self.workspaceSwitchGeneration.isCurrent(switchGeneration)
                    }
                )
                guard authFlowGeneration.isCurrent(generation),
                      workspaceSwitchGeneration.isCurrent(switchGeneration) else {
                    return
                }
                enterIM(showToast: false)
                // 进入后先用目标租户的本地缓存即时渲染会话列表(含已解析名称),再后台刷新合并。
                let enteredContext = apiContext
                let enteredScope = remoteDataScopeKey(for: enteredContext)
                _ = await applyCachedRemoteSnapshotIfAvailable(context: enteredContext)
                guard authFlowGeneration.isCurrent(generation),
                      workspaceSwitchGeneration.isCurrent(switchGeneration),
                      isCurrentRemoteScope(enteredScope) else { return }
                let fallbackToast = makeDefault
                    ? "已进入 \(currentEnterprise.name)，首屏同步成功后保存默认企业"
                    : "已进入 \(currentEnterprise.name)，聊天数据正在同步"
                startPostLoginRemoteSnapshotRefresh(
                    generation: generation,
                    context: enteredContext,
                    immediateToast: fallbackToast,
                    syncedToast: "已进入 \(currentEnterprise.name)",
                    fallbackToast: fallbackToast
                )
            } catch {
                guard authFlowGeneration.isCurrent(generation),
                      workspaceSwitchGeneration.isCurrent(switchGeneration) else { return }
                resetAuthenticatedRemoteData(showLoading: false)
                if isRefreshableSessionError(error) {
                    disableAccessDiagnosticsOverlay()
                    apiContext.clearSession(sessionStore: protectedSessionStore)
                    apiContext.save(sessionStore: protectedSessionStore)
                    isAuthenticated = false
                    authScreen = .accountLogin
                    loginWorkspaceSelectionMessage = nil
                    toast = "登录已失效，请重新登录"
                    return
                }
                apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
                apiContext.save(sessionStore: protectedSessionStore)
                isAuthenticated = false
                authScreen = .workspaceSelection
                if let securityInfo = securityBlockedInfo(from: error) {
                    handleSecurityBlocked(securityInfo, enterpriseID: enterprise.id)
                    loginWorkspaceSelectionMessage = "\(securityInfo.userMessage)。请选择其他可进入企业。"
                    toast = securityInfo.userMessage
                } else if let code = workspaceAccessCode(from: error) {
                    if code == "workspace_switch_disabled" {
                        resetAuthenticatedRemoteData(showLoading: false)
                        disableAccessDiagnosticsOverlay()
                        apiContext.clearSession(sessionStore: protectedSessionStore)
                        isAuthenticated = false
                        authScreen = .accountLogin
                        loginWorkspaceSelectionMessage = nil
                        toast = workspaceAccessMessage(for: code)
                        return
                    }
                    let message = shouldPersistWorkspaceEntryAccessBlock(code)
                        ? workspaceAccessMessage(for: code)
                        : platformWorkspaceSwitchFailureMessage(error)
                    if shouldPersistWorkspaceEntryAccessBlock(code) {
                        _ = markWorkspaceAccessBlocked(code, enterpriseID: enterprise.id)
                    }
                    loginWorkspaceSelectionMessage = "\(message)。请选择其他可进入企业。"
                    toast = message
                } else {
                    let message = platformWorkspaceSwitchFailureMessage(error)
                    loginWorkspaceSelectionMessage = "\(message)。请选择其他可进入企业。"
                    toast = message
                }
            }
        }
    }

    func cancelLoginWorkspaceSelection() {
        isAuthenticated = false
        authFlowGeneration.invalidate()
        stopInboxRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        resetAuthenticatedRemoteData(showLoading: false)
        disableAccessDiagnosticsOverlay()
        apiContext.clearSession(sessionStore: protectedSessionStore)
        loginWorkspaceSelectionMessage = nil
        loginDefaultWorkspaceID = ""
        authScreen = .accountLogin
    }

    func clearDefaultWorkspacePreference() {
        let hasPlatformSession = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasPlatformSession else {
            toast = "登录会话已失效，请重新登录"
            return
        }
        guard !loginDefaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast = "当前没有默认企业"
            return
        }
        Task {
            do {
                let result = try await api.clearDefaultWorkspace(platformToken: apiContext.platformToken)
                loginDefaultWorkspaceID = result.defaultWorkspaceID
                if let workspace = result.defaultWorkspace {
                    upsertEnterprise(enterprise(from: workspace, fallbackAccent: currentEnterprise.accentHex))
                }
                toast = loginDefaultWorkspaceID.isEmpty ? "已清除默认企业" : "默认企业已更新"
            } catch {
                handleRemoteError(error, fallback: "清除默认企业失败")
            }
        }
    }

    private func applyCurrentUserProfileLocally(
        name: String? = nil,
        username: String? = nil,
        avatarSeed: UInt? = nil,
        avatarURL: String? = nil,
        avatarVersion: String? = nil,
        avatarUpdatedAt: String? = nil
    ) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmedName?.isEmpty == false ? trimmedName! : currentUser.name
        let nextUsername = trimmedUsername ?? currentUser.username
        let trimmedAvatarURL = avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAvatarURL = trimmedAvatarURL.map { resolveTenantAssetURL($0) }
        let nextAvatarVersion = avatarVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextAvatarUpdatedAt = avatarUpdatedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appliedAvatarVersion = nextAvatarVersion?.isEmpty == false
            ? nextAvatarVersion!
            : currentUser.avatarVersion
        let appliedAvatarUpdatedAt = nextAvatarUpdatedAt?.isEmpty == false
            ? nextAvatarUpdatedAt!
            : currentUser.avatarUpdatedAt

        currentUser = IMUser(
            id: currentUser.id,
            userID: currentUser.userID,
            username: nextUsername,
            name: nextName,
            title: currentUser.title,
            department: currentUser.department,
            departmentPathNames: currentUser.departmentPathNames,
            phone: currentUser.phone,
            phoneVerified: currentUser.phoneVerified,
            realNameVerified: currentUser.realNameVerified,
            realNameStatus: currentUser.realNameStatus,
            email: currentUser.email,
            status: currentUser.status,
            enterprise: currentUser.enterprise,
            avatarSeed: avatarSeed ?? currentUser.avatarSeed,
            avatarURL: resolvedAvatarURL?.isEmpty == false ? resolvedAvatarURL! : currentUser.avatarURL,
            avatarVersion: appliedAvatarVersion,
            avatarUpdatedAt: appliedAvatarUpdatedAt,
            badges: currentUser.badges
        )
        if let resolvedAvatarURL, !resolvedAvatarURL.isEmpty {
            propagateCurrentUserAvatarLocally(
                resolvedAvatarURL,
                avatarVersion: appliedAvatarVersion,
                avatarUpdatedAt: appliedAvatarUpdatedAt
            )
        }
    }

    func resolveTenantAssetURL(_ rawValue: String, context: IMAPIContext? = nil) -> String {
        api.resolveTenantAssetURL(rawValue, context: context ?? apiContext)
    }

    private func propagateCurrentUserAvatarLocally(_ avatarURL: String, avatarVersion: String = "", avatarUpdatedAt: String = "") {
        let trimmedAvatarURL = avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAvatarURL.isEmpty else { return }
        let trimmedVersion = avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUpdatedAt = avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIDs = currentUserIdentitySet()

        func updatedAvatarUser(_ user: IMUser) -> IMUser {
            guard userIdentityCandidates(for: user).contains(where: { currentIDs.contains($0) }) else {
                return user
            }
            return IMUser(
                id: user.id,
                userID: user.userID,
                username: user.username,
                name: user.name,
                title: user.title,
                department: user.department,
                departmentPathNames: user.departmentPathNames,
                phone: user.phone,
                phoneVerified: user.phoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.email,
                status: user.status,
                enterprise: user.enterprise,
                avatarSeed: user.avatarSeed,
                avatarURL: trimmedAvatarURL,
                avatarVersion: trimmedVersion.isEmpty ? user.avatarVersion : trimmedVersion,
                avatarUpdatedAt: trimmedUpdatedAt.isEmpty ? user.avatarUpdatedAt : trimmedUpdatedAt,
                badges: user.badges
            )
        }

        contacts = contacts.map(updatedAvatarUser)
        for index in groups.indices {
            groups[index].members = groups[index].members.map(updatedAvatarUser)
            groups[index].admins = groups[index].admins.map(updatedAvatarUser)
        }
        conversationStore.updateConversationParticipants(updatedAvatarUser)
    }

    private func recordCurrentUserAvatarCommitAuthority(
        context: IMAPIContext,
        resolvedAvatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String
    ) {
        let tenantID = context.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionUID = context.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentUID = currentUser.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = sessionUID.isEmpty ? currentUID : sessionUID
        guard !tenantID.isEmpty, !uid.isEmpty else { return }

        let retired = avatarRealtimeProjection.retireExactUIDAfterLocalCommit(uid)
        let checkpoint = currentProfileAuthorityCheckpoint()
        avatarLocalCommitAuthorityFence.record(
            tenantID: tenantID,
            uid: uid,
            resolvedURL: resolvedAvatarURL,
            cacheVersion: avatarVersion,
            updatedAt: avatarUpdatedAt,
            minimumRemoteRevision: max(
                retired?.revision ?? 0,
                checkpoint?.userRevision ?? 0
            ),
            minimumRemoteGeneration: max(
                retired?.generation ?? 0,
                checkpoint?.identityGeneration ?? 0
            )
        )
        _ = beginCurrentProfileMutation(context: context)
        avatarRealtimePresentationRevision &+= 1
        queueAvatarAuthorityRefetch([uid])
    }

    func replaceCurrentUserAndProject(_ nextUser: IMUser, persistIdentity: Bool = true) {
        let previousIdentity = currentUserIdentitySet()

        func projected(_ user: IMUser) -> IMUser {
            guard userIdentityCandidates(for: user).contains(where: { previousIdentity.contains($0) }) else {
                return user
            }
            return IMUser(
                id: user.id,
                userID: user.userID,
                username: nextUser.username.isEmpty ? user.username : nextUser.username,
                name: nextUser.name,
                title: nextUser.title,
                department: nextUser.department,
                departmentPathNames: nextUser.departmentPathNames,
                phone: nextUser.phone,
                phoneVerified: nextUser.phoneVerified,
                realNameVerified: nextUser.realNameVerified,
                realNameStatus: nextUser.realNameStatus,
                email: nextUser.email,
                status: nextUser.status,
                lastLoginAt: nextUser.lastLoginAt,
                enterprise: nextUser.enterprise,
                avatarSeed: nextUser.avatarSeed,
                avatarURL: nextUser.avatarURL,
                avatarVersion: nextUser.avatarVersion,
                avatarUpdatedAt: nextUser.avatarUpdatedAt,
                badges: nextUser.badges
            )
        }

        suppressCurrentUserIdentityPersistence = !persistIdentity
        currentUser = nextUser
        suppressCurrentUserIdentityPersistence = false
        contacts = contacts.map(projected)
        for index in groups.indices {
            groups[index].members = groups[index].members.map(projected)
            groups[index].admins = groups[index].admins.map(projected)
        }
        conversationStore.updateConversationParticipants(projected)
    }

    private func rollbackCurrentUserProfileIfCurrent(
        _ previousUser: IMUser,
        ticket: ProfileContactMutationTicket,
        scope: String
    ) {
        guard isCurrentRemoteScope(scope),
              profileContactRevisionFence.isCurrent(ticket) else { return }
        replaceCurrentUserAndProject(previousUser)
    }

    func updateCurrentUserProfile(name: String? = nil, username: String? = nil) async -> Bool {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedUsername = trimmedUsername ?? ""
        let currentUsername = currentUser.username.trimmingCharacters(in: .whitespacesAndNewlines)

        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard trimmedName?.isEmpty == false || trimmedUsername?.isEmpty == false else {
            toast = "请输入要保存的资料"
            return false
        }
        if let trimmedUsername, !trimmedUsername.isEmpty, !currentUsername.isEmpty, trimmedUsername != currentUsername {
            toast = "用户账号已设置，如需修改请联系管理员/商户后台处理。"
            return false
        }
        if let trimmedUsername, !trimmedUsername.isEmpty, !isValidAccountUsername(trimmedUsername) {
            toast = "账号必须为 5-10 位数字或英文字母"
            return false
        }
        guard let mutationRequest = beginCurrentProfileMutation(context: context) else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        profileContactRevisionFence.rebind(scopeHash: scope)
        guard let projectionTicket = profileContactRevisionFence.beginMutation(
            scopeHash: scope,
            keys: ["profile:self"]
        ) else {
            toast = "登录状态已变化，请重试保存资料"
            return false
        }
        let previousUser = currentUser
        let optimisticUser = IMUser(
            id: currentUser.id,
            userID: currentUser.userID,
            username: trimmedUsername ?? currentUser.username,
            name: trimmedName ?? currentUser.name,
            title: currentUser.title,
            department: currentUser.department,
            departmentPathNames: currentUser.departmentPathNames,
            phone: currentUser.phone,
            phoneVerified: currentUser.phoneVerified,
            realNameVerified: currentUser.realNameVerified,
            realNameStatus: currentUser.realNameStatus,
            email: currentUser.email,
            status: currentUser.status,
            lastLoginAt: currentUser.lastLoginAt,
            enterprise: currentUser.enterprise,
            avatarSeed: currentUser.avatarSeed,
            avatarURL: currentUser.avatarURL,
            avatarVersion: currentUser.avatarVersion,
            avatarUpdatedAt: currentUser.avatarUpdatedAt,
            badges: currentUser.badges
        )
        replaceCurrentUserAndProject(optimisticUser, persistIdentity: false)

        do {
            let profile = try await api.updateMeProfile(context: context, nickname: trimmedName, username: trimmedUsername)
            guard isCurrentRemoteScope(scope),
                  profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            let responseUsername = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedUsername != nil,
               !responseUsername.isEmpty,
               responseUsername.localizedCaseInsensitiveCompare(requestedUsername) != .orderedSame {
                rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
                await refreshRemoteSnapshot(silent: true, force: true)
                toast = "用户账号保存失败，请稍后重试"
                return false
            }
            var acceptedProfile = applyMeProfile(
                profile,
                authorityRequest: mutationRequest,
                usernameFallback: trimmedUsername,
                nicknameFallback: trimmedName
            )
            if let readbackRequest = beginCurrentProfileRead(context: context) {
                do {
                    let readback = try await api.meProfile(context: context)
                    guard isCurrentRemoteScope(scope),
                          profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
                    if applyMeProfile(readback, authorityRequest: readbackRequest) {
                        acceptedProfile = true
                    }
                } catch {
                    logSyncEndpointFailure("/api/tenant/me/profile", error: error)
                }
            }
            guard profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            guard acceptedProfile else {
                rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
                await refreshRemoteSnapshot(silent: true, force: true)
                toast = "个人资料保存失败，请稍后重试"
                return false
            }
            toast = trimmedUsername != nil && trimmedName == nil ? "用户账号已更新" : "个人资料已更新"
            return true
        } catch IMAPIError.conflict(let code, _) where code.localizedCaseInsensitiveCompare("user_account_locked") == .orderedSame {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            toast = "用户账号已设置，如需修改请联系管理员/商户后台处理。"
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch IMAPIError.conflict(let code, _) where isUserAccountFormatErrorCode(code) {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            toast = "账号必须为 5-10 位数字或英文字母"
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch IMAPIError.conflict {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            toast = "用户账号已被占用"
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch IMAPIError.server(let message) where message.localizedCaseInsensitiveContains("invalid_account_format")
            || message.localizedCaseInsensitiveContains("invalid_user_account_format")
            || message.localizedCaseInsensitiveContains("5-10") {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            toast = "账号必须为 5-10 位数字或英文字母"
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch IMAPIError.server(let message) where message.localizedCaseInsensitiveContains("validation_error")
            || message.localizedCaseInsensitiveContains("username") {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            toast = "用户账号格式不正确"
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            handleRemoteError(error, fallback: "个人资料保存失败")
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        }
    }

    func changeMyPassword(currentPassword: String, newPassword: String) async -> Bool {
        let current = currentPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            toast = "请输入当前密码"
            return false
        }
        guard next.count >= 8, next.count <= 20,
              next.rangeOfCharacter(from: .letters) != nil,
              next.rangeOfCharacter(from: .decimalDigits) != nil else {
            toast = "新密码需为8-20位并包含字母和数字"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        let profileAuthorityRequest = beginCurrentProfileRead(context: context)
        do {
            let result = try await api.changeMyPassword(context: context, currentPassword: current, newPassword: next)
            guard isCurrentRemoteScope(scope) else { return false }
            if let profile = result.profile {
                applyMeProfile(profile, authorityRequest: profileAuthorityRequest)
            }
            toast = "密码已更新"
            return result.updated || result.sessionRemainsActive
        } catch IMAPIError.unauthorized(let message) where message.contains("当前密码") || message.localizedCaseInsensitiveContains("current_password_incorrect") {
            guard isCurrentRemoteScope(scope) else { return false }
            toast = "当前密码错误"
            return false
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            let code = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
            if code.contains("current_password_incorrect") || code.contains("当前密码") {
                toast = "当前密码错误"
            } else if code.contains("weak_password") {
                toast = "新密码需为8-20位并包含字母和数字"
            } else if code.contains("workspace_directory_unavailable") || code.contains("account_password_sync_failed") {
                toast = "密码同步暂不可用，请稍后重试"
            } else {
                handleRemoteError(error, fallback: "密码保存失败，请稍后重试")
            }
            return false
        }
    }

    func uploadCurrentUserAvatar(imageData: Data, mimeType: String, width: Int, height: Int) async -> Bool {
        await uploadCurrentUserAvatarResult(
            imageData: imageData,
            mimeType: mimeType,
            width: width,
            height: height
        ).success
    }

    func uploadCurrentUserAvatarResult(
        imageData: Data,
        mimeType: String,
        width: Int,
        height: Int
    ) async -> AvatarUploadResult {
        guard !imageData.isEmpty else {
            toast = "请选择头像图片"
            return .failed(.unknown, safeCode: "empty_image")
        }
        guard imageData.count <= 2 * 1024 * 1024 else {
            toast = "头像图片不能超过 2 MB"
            return .failed(.unknown, safeCode: "image_too_large")
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return .failed(.unknown, safeCode: "missing_session")
        }
        let scope = remoteDataScopeKey(for: context)
        let fileName = mimeType == "image/png" ? "avatar.png" : "avatar.jpg"
        let presign: RemoteAvatarUploadData
        do {
            presign = try await api.presignAvatarUpload(
                context: context,
                fileName: fileName,
                mimeType: mimeType,
                sizeBytes: imageData.count,
                width: width,
                height: height
            )
        } catch {
            guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
            return avatarUploadFailure(stage: .presign, label: "获取头像上传凭证失败", error: error)
        }
        guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
        do {
            // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_AVATAR_UPLOAD_GUARD - 修改开始：头像仍要求后端返回上传描述，避免公共媒体兼容影响既有头像流程
            guard let upload = presign.upload else {
                throw IMAPIError.server("avatar_upload_descriptor_missing")
            }
            try await api.uploadAvatarBinary(upload: upload, data: imageData, mimeType: mimeType)
            // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_AVATAR_UPLOAD_GUARD - 修改结束
        } catch {
            guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
            return avatarUploadFailure(stage: .put, label: "头像图片上传失败", error: error)
        }
        guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
        let commit: RemoteAvatarCommitData
        do {
            commit = try await api.commitAvatar(context: context, fileID: presign.file.id)
        } catch {
            guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
            return avatarUploadFailure(stage: .commit, label: "保存头像资料失败", error: error)
        }
        guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
        let avatarURL = commit.avatarURL.isEmpty ? commit.profile.avatar : commit.avatarURL
        let resolvedAvatarURL = resolvedAvatarURL(from: avatarURL, fileID: presign.file.id)
        guard !resolvedAvatarURL.isEmpty else {
            return avatarUploadFailure(
                stage: .commit,
                label: "保存头像资料失败",
                error: IMAPIError.server("后端未返回头像地址")
            )
        }
        AvatarImageCache.shared.store(imageData, for: resolvedAvatarURL)
        let avatarCacheKey = AvatarImageCache.cacheKey(
            url: resolvedAvatarURL,
            version: commit.avatarVersion,
            updatedAt: commit.avatarUpdatedAt
        )
        AvatarImageCache.shared.store(imageData, for: avatarCacheKey)
        recordCurrentUserAvatarCommitAuthority(
            context: context,
            resolvedAvatarURL: resolvedAvatarURL,
            avatarVersion: commit.avatarVersion,
            avatarUpdatedAt: commit.avatarUpdatedAt
        )
        applyCurrentUserProfileLocally(
            avatarURL: resolvedAvatarURL,
            avatarVersion: commit.avatarVersion,
            avatarUpdatedAt: commit.avatarUpdatedAt
        )
        Task { await refreshRemoteSnapshot(silent: true, force: true) }
        toast = "头像已更新"
        return .succeeded
    }

    private func avatarUploadFailure(
        stage: AvatarUploadFailureStage,
        label: String,
        error: Error
    ) -> AvatarUploadResult {
        handleRemoteError(avatarUploadStageError(label, error: error), fallback: "头像上传失败")
        let metadata = Self.avatarUploadFailureMetadata(error)
        return .failed(stage, safeCode: metadata.safeCode, status: metadata.status)
    }

    nonisolated static func avatarUploadFailureMetadata(_ error: Error) -> (safeCode: String?, status: Int?) {
        let rawCode: String?
        var status: Int?
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .businessForbidden(let code, _, _), .conflict(let code, _),
                 .loginSecurity(let code, _, _), .rateLimited(let code, _, _, _):
                rawCode = code
            case .httpStatus(let value, _):
                rawCode = "http_status"
                status = value
            case .missingContext:
                rawCode = "missing_context"
            case .badURL:
                rawCode = "invalid_url"
            case .unauthorized:
                rawCode = "unauthorized"
            case .forbidden:
                rawCode = "forbidden"
            case .forcedAuthRequired:
                rawCode = "forced_auth_required"
            case .server(let message):
                rawCode = "server_error"
                status = httpStatusFromSafeMessage(message)
            case .securityBlocked:
                rawCode = "security_blocked"
            case .emptyResponse:
                rawCode = "empty_response"
            }
        } else if let urlError = error as? URLError {
            rawCode = urlError.code == .timedOut ? "network_timeout" : "network_error"
        } else {
            rawCode = "unknown"
        }
        let code = rawCode.flatMap(sanitizedAvatarUploadSafeCode) ?? "unknown"
        return (code, status.flatMap { (100...599).contains($0) ? $0 : nil })
    }

    nonisolated private static func sanitizedAvatarUploadSafeCode(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
                      || scalar.value == 95 || scalar.value == 45 || scalar.value == 46
              }) else { return nil }
        return value
    }

    nonisolated private static func httpStatusFromSafeMessage(_ message: String) -> Int? {
        let tokens = message.uppercased().split { !$0.isLetter && !$0.isNumber }
        for index in tokens.indices where tokens[index] == "HTTP" {
            let next = tokens.index(after: index)
            if next < tokens.endIndex, let status = Int(tokens[next]), (100...599).contains(status) {
                return status
            }
        }
        return nil
    }

    func updateGroupProfile(groupID: String, name: String?, avatarImageData: Data?, mimeType: String = "image/jpeg", width: Int = 512, height: Int = 512) async -> Bool {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard let group = group(id: groupID), canManageGroup(group) else {
            toast = "仅群主或管理员可以编辑群资料"
            return false
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldUpdateName = !trimmedName.isEmpty && trimmedName != group.name
        var avatarFileID: String?

        do {
            if let avatarImageData {
                guard width == height, width >= 128, width <= 2048 else {
                    toast = "头像尺寸不符合要求，请重新裁剪后上传"
                    return false
                }
                guard avatarImageData.count <= 2 * 1024 * 1024 else {
                    toast = "头像图片不能超过 2 MB"
                    return false
                }
                let fileName = mimeType == "image/png" ? "group-avatar.png" : "group-avatar.jpg"
                let presign: RemoteAvatarUploadData
                do {
                    presign = try await api.presignGroupAvatarUpload(
                        context: context,
                        groupID: groupID,
                        fileName: fileName,
                        mimeType: mimeType,
                        sizeBytes: avatarImageData.count,
                        width: width,
                        height: height
                    )
                } catch {
                    throw avatarUploadStageError("获取群头像上传凭证失败", error: error)
                }
                guard isCurrentRemoteScope(scope) else { return false }
                do {
                    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_GROUP_AVATAR_UPLOAD_GUARD - 修改开始：群头像仍要求上传描述，不复用聊天附件 uploaded-without-upload 兼容
                    guard let upload = presign.upload else {
                        throw IMAPIError.server("group_avatar_upload_descriptor_missing")
                    }
                    try await api.uploadGroupAvatarBinary(upload: upload, data: avatarImageData, mimeType: mimeType)
                    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_GROUP_AVATAR_UPLOAD_GUARD - 修改结束
                } catch {
                    throw avatarUploadStageError("群头像图片上传失败", error: error)
                }
                guard isCurrentRemoteScope(scope) else { return false }
                avatarFileID = presign.file.id
            }

            guard shouldUpdateName || avatarFileID != nil else {
                toast = "群资料没有变化"
                return false
            }

            let response: RemoteGroupProfileUpdateResponse
            do {
                response = try await api.updateGroupProfile(
                    context: context,
                    groupID: groupID,
                    name: shouldUpdateName ? trimmedName : nil,
                    avatarFileID: avatarFileID,
                    expectedGroupRevision: group.groupRevision
                )
            } catch IMAPIError.conflict(let code, _)
                where code == "group_revision_conflict" || code == "group_revision_required" {
                guard isCurrentRemoteScope(scope) else { return false }
                await refreshGroupBundle(groupID: groupID, silent: true, includeSecondaryData: false)
                toast = "群资料已被其他管理员更新，请核对后重试"
                return false
            } catch {
                throw avatarUploadStageError(avatarFileID == nil ? "保存群资料失败" : "保存群头像资料失败", error: error)
            }
            guard isCurrentRemoteScope(scope) else { return false }
            var mapped = groupInfo(from: response.effectiveGroup, existing: group)
            let committedRevision = response.effectiveGroup.groupRevision
            let acceptsCommittedProfile = group.groupRevision <= 0
                || committedRevision >= group.groupRevision
            if let avatarFileID, acceptsCommittedProfile {
                let committedAvatarPath = authoritativeGroupAvatarPath(response.avatarURL)
                let fallbackAvatarPath = authoritativeGroupAvatarPath(
                    "/api/tenant/avatar/\(avatarFileID.urlPathEncoded)"
                )
                if !committedAvatarPath.isEmpty || !fallbackAvatarPath.isEmpty {
                    mapped.avatarURL = committedAvatarPath.isEmpty ? fallbackAvatarPath : committedAvatarPath
                }
                mapped.avatarVersion = response.avatarVersion.isEmpty ? mapped.avatarVersion : response.avatarVersion
                mapped.avatarUpdatedAt = response.avatarUpdatedAt.isEmpty ? mapped.avatarUpdatedAt : response.avatarUpdatedAt
            }
            if let index = groups.firstIndex(where: { $0.id == groupID }) {
                groups[index] = mapped
            } else {
                groups.append(mapped)
            }
            if let avatarImageData, !mapped.avatarURL.isEmpty {
                storeGroupAvatarImage(avatarImageData, for: mapped)
            }
            ensureGroupConversationExists(mapped)
            await refreshGroupBundle(groupID: groupID, silent: true)
            _ = await refreshRemoteSnapshot(silent: true, force: true)
            toast = "群资料已更新"
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            let message = userFacingError(error)
            if message.localizedCaseInsensitiveContains("unprocessable")
                || message.localizedCaseInsensitiveContains("尺寸")
                || message.localizedCaseInsensitiveContains("mime")
                || message.localizedCaseInsensitiveContains("format") {
                toast = "头像格式或尺寸不符合要求，请重新选择图片"
            } else {
                handleRemoteError(error, fallback: "群资料更新失败")
            }
            return false
        }
    }

    func myGroupNickname(groupID: String) -> String {
        myGroupNicknamesByScopedGroupKey[groupMemberProfileCacheKey(groupID: groupID)] ?? ""
    }

    func myGroupMemberProjection(groupID: String) -> IMUser? {
        myGroupMemberProjectionsByScopedGroupKey[groupMemberProfileCacheKey(groupID: groupID)]
    }

    func updateMyGroupNickname(groupID: String, rawValue: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty else {
            toast = "群信息不可用，请刷新后重试"
            return false
        }
        let normalizedNickname: String
        do {
            normalizedNickname = try GroupNicknameInputPolicy.normalize(rawValue)
        } catch let error as GroupNicknameInputError {
            toast = error.userMessage
            return false
        } catch {
            toast = "群昵称格式不正确"
            return false
        }

        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        let profileKey = groupMemberProfileCacheKey(groupID: normalizedGroupID, context: context)
        let refreshEpoch = groupMemberProfileRefreshEpoch
        let groupRefreshEpoch = groupMemberProfileRefreshEpochByScopedGroupKey[profileKey] ?? 0
        let expectedIMUID = context.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let profile = try await api.updateMyGroupNickname(
                context: context,
                groupID: normalizedGroupID,
                groupNickname: normalizedNickname
            )
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return false }
            let responseGroupID = profile.groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard responseGroupID == normalizedGroupID else {
                toast = "群昵称响应与当前群不匹配，请刷新后重试"
                return false
            }
            let responseIMUID = profile.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expectedIMUID.isEmpty, responseIMUID == expectedIMUID else {
                toast = "群昵称响应与当前账号不匹配，请刷新后重试"
                return false
            }
            groupMemberProfileRefreshEpochByScopedGroupKey[profileKey, default: 0] &+= 1
            let postMutationGroupRefreshEpoch =
                groupMemberProfileRefreshEpochByScopedGroupKey[profileKey] ?? 0
            groupMemberProfileRefreshTasks.removeValue(forKey: profileKey)?.cancel()
            applyMyGroupMemberProfile(profile, fallbackGroupID: normalizedGroupID)
            await refreshGroupBundle(
                groupID: normalizedGroupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: postMutationGroupRefreshEpoch
            ) else { return false }
            toast = normalizedNickname.isEmpty ? "群昵称已清除" : "群昵称已更新"
            return true
        } catch {
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return false }
            let normalizedCode = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
            if normalizedCode.contains("invalid_group_nickname") {
                toast = "群昵称格式不正确，请修改后重试"
            } else if normalizedCode.contains("group_membership_not_found")
                        || isGroupMemberNotFoundMessage(normalizedCode) {
                toast = "你已不在该群，无法修改群昵称"
            } else {
                handleRemoteError(error, fallback: "群昵称保存失败")
            }
            return false
        }
    }

    func groupMemberProfileCacheKey(groupID: String, context: IMAPIContext? = nil) -> String {
        let resolvedContext = context ?? apiContext
        return "\(remoteDataScopeKey(for: resolvedContext))|\(groupID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func isCurrentGroupMemberProfileRefresh(
        scope: String,
        key: String,
        globalEpoch: UInt64,
        groupEpoch: UInt64
    ) -> Bool {
        isCurrentRemoteScope(scope)
            && groupMemberProfileRefreshEpoch == globalEpoch
            && (groupMemberProfileRefreshEpochByScopedGroupKey[key] ?? 0) == groupEpoch
    }

    func shouldAcceptGroupMemberProfileGeneration(_ generation: Int64, key: String) -> Bool {
        let positiveFloor = max(
            groupMemberProfileGenerationByScopedGroupKey[key] ?? 0,
            minimumGroupMemberProfileGenerationByScopedGroupKey[key] ?? 0
        )
        guard positiveFloor > 0 else {
            // Compatibility: an older server may omit generations until this
            // scope has observed its first versioned profile.
            return true
        }
        return generation > 0 && generation >= positiveFloor
    }

    func recordAcceptedGroupMemberProfileGeneration(_ generation: Int64, key: String) {
        guard generation > 0 else { return }
        groupMemberProfileGenerationByScopedGroupKey[key] = max(
            groupMemberProfileGenerationByScopedGroupKey[key] ?? 0,
            generation
        )
        if generation >= (minimumGroupMemberProfileGenerationByScopedGroupKey[key] ?? 0) {
            minimumGroupMemberProfileGenerationByScopedGroupKey.removeValue(forKey: key)
        }
    }

    func groupMemberProfileGenerationFloor(groupID: String) -> Int64 {
        let key = groupMemberProfileCacheKey(groupID: groupID)
        return max(
            groupMemberProfileGenerationByScopedGroupKey[key] ?? 0,
            minimumGroupMemberProfileGenerationByScopedGroupKey[key] ?? 0
        )
    }

    @discardableResult
    func cacheMyGroupNickname(_ nickname: String, groupID: String, generation: Int64) -> Bool {
        let key = groupMemberProfileCacheKey(groupID: groupID)
        guard shouldAcceptGroupMemberProfileGeneration(generation, key: key) else { return false }
        myGroupNicknamesByScopedGroupKey[key] = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        recordAcceptedGroupMemberProfileGeneration(generation, key: key)
        return true
    }

    func applyMyGroupMemberProfile(_ profile: RemoteGroupMemberProfile, fallbackGroupID: String) {
        let groupID = profile.groupID.isEmpty ? fallbackGroupID : profile.groupID
        let generation = max(profile.groupMembershipGeneration, profile.revision)
        guard cacheMyGroupNickname(profile.groupNickname, groupID: groupID, generation: generation) else {
            return
        }
        let resolvedName = [
            profile.groupNickname,
            profile.rawNickname,
            profile.displayName,
            profile.imUID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "未命名成员"
        myGroupMemberProjectionsByScopedGroupKey[
            groupMemberProfileCacheKey(groupID: groupID)
        ] = currentUser.withName(resolvedName)
        // A successful self-profile mutation is authoritative even while the
        // group summary is being materialized or refreshed. Persist the
        // scoped projection before consulting the optional in-memory group so
        // the detail sheet, member list and a subsequently inserted
        // conversation cannot fall back to the stale global nickname.
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let identities = Set([
            profile.imUID,
            apiContext.imUID ?? "",
            currentUser.id,
            currentUser.userID
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        groups[index].members = groups[index].members.map { member in
            identities.contains(member.id) || identities.contains(member.userID)
                ? member.withName(resolvedName)
                : member
        }
        groups[index].admins = groups[index].admins.map { member in
            identities.contains(member.id) || identities.contains(member.userID)
                ? member.withName(resolvedName)
                : member
        }
        conversationStore.setGroupConversationParticipants(
            groupID: groupID,
            groupName: groups[index].name,
            participants: groups[index].members,
            memberCount: shouldShowGroupMemberCount ? groups[index].effectiveMemberCount : nil
        )
    }

    private func resolvedAvatarURL(from rawValue: String, fileID: String) -> String {
        let resolved = resolveTenantAssetURL(rawValue)
        if !resolved.isEmpty {
            return resolved
        }
        let trimmedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFileID.isEmpty else { return "" }
        return resolveTenantAssetURL("/api/tenant/avatar/\(trimmedFileID.urlPathEncoded)")
    }

    func authoritativeGroupAvatarPath(_ rawValue: String) -> String {
        guard let request = TenantRelativeImageURLResolver.request(
            rawValue,
            routeContext: avatarImageRouteContext
        ), case let .tenantRelative(relativeValue) = request,
              let parsed = URL(string: relativeValue),
              parsed.host == nil,
              parsed.query == nil,
              parsed.fragment == nil,
              TenantRelativeImageURLResolver.isStableTenantAvatarPath(parsed.path) else {
            return ""
        }
        return parsed.path
    }

    private func storeGroupAvatarImage(_ data: Data, for group: GroupInfo) {
        let cacheKey = groupAvatarCacheKey(
            groupID: group.id,
            avatarURL: group.avatarURL,
            avatarVersion: group.avatarVersion,
            avatarUpdatedAt: group.avatarUpdatedAt
        )
        guard !cacheKey.isEmpty,
              let request = TenantRelativeImageURLResolver.request(
                group.avatarURL,
                routeContext: avatarImageRouteContext
              ),
              let storageKey = request.storageCacheKey(
                cacheKey,
                routeContext: avatarImageRouteContext
              ) else {
            return
        }
        AvatarImageCache.shared.store(data, for: storageKey)
    }

    private func avatarUploadStageError(_ stage: String, error: Error) -> IMAPIError {
        let detail = userFacingError(error).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return .server(stage) }
        if detail.localizedCaseInsensitiveContains(stage) {
            return .server(detail)
        }
        return .server("\(stage)：\(detail)")
    }

    func isValidAccountUsername(_ username: String) -> Bool {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...10).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
        }
    }

    private func isUserAccountFormatErrorCode(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "invalid_user_account_format" || normalized == "invalid_account_format"
    }

    func refreshVerificationStatus() async {
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        do {
            let status = try await api.verificationStatus(context: context)
            guard isCurrentRemoteScope(scope) else { return }
            applyVerificationStatus(status)
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            handleRemoteError(error, fallback: "认证状态同步失败")
        }
    }

    func sendPhoneBindingCode(phone: String) async -> Int? {
        let normalized = normalizedMainlandPhone(phone)
        guard isValidMainlandPhone(normalized) else {
            toast = "请输入正确的手机号"
            return nil
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        guard let sessionScope = PhoneBindingChallengeSessionScope(context: context) else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        let issueGeneration = beginPhoneBindingChallengeIssue()
        do {
            let tenantCode = captchaTenantCode()
#if DEBUG
            let phoneSuffix = String(normalized.suffix(4))
            captchaLogger.info("phone_bind_captcha start tenantCode=\(tenantCode, privacy: .public) phoneSuffix=\(phoneSuffix, privacy: .public)")
#endif
            guard try await canSendCaptcha(scene: "phone_bind", channel: "sms", appID: context.appID, tenantCode: tenantCode) else {
                guard isCurrentPhoneBindingChallengeIssue(
                    generation: issueGeneration,
                    sessionScope: sessionScope
                ) else { return nil }
#if DEBUG
                captchaLogger.info("phone_bind_captcha not_required")
#endif
                toast = "当前手机号绑定流程无需验证码"
                return nil
            }
            guard isCurrentPhoneBindingChallengeIssue(
                generation: issueGeneration,
                sessionScope: sessionScope
            ) else { return nil }
#if DEBUG
            captchaLogger.info("phone_bind_captcha sending")
#endif
            let challenge = try await api.sendPhoneBindingChallenge(context: context, phone: normalized)
            guard isCurrentPhoneBindingChallengeIssue(
                generation: issueGeneration,
                sessionScope: sessionScope
            ) else { return nil }
            let requestID = challenge.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard challenge.sent, !requestID.isEmpty else {
                throw IMAPIError.businessForbidden(
                    code: "phone_binding_request_id_missing",
                    message: "手机号验证请求标识缺失，请重新获取验证码",
                    error: nil
                )
            }
            pendingPhoneBindingChallenge = PendingPhoneBindingChallenge(
                sessionScope: sessionScope,
                normalizedPhone: normalized,
                requestID: requestID,
                issueGeneration: issueGeneration
            )
#if DEBUG
            captchaLogger.info("phone_bind_captcha sent cooldown=\(challenge.cooldownSeconds, privacy: .public)")
#endif
            toast = phoneBindingChallengeSuccessMessage(challenge)
            return phoneBindingChallengeCooldownSeconds(challenge)
        } catch {
            guard isCurrentPhoneBindingChallengeIssue(
                generation: issueGeneration,
                sessionScope: sessionScope
            ) else { return nil }
#if DEBUG
            captchaLogger.error("phone_bind_captcha failed message=\(self.userFacingError(error), privacy: .public)")
#endif
            handleRemoteError(error, fallback: "验证码发送失败")
            return nil
        }
    }

    private func captchaTenantCode(_ explicit: String = "", fallbackToCurrentTenant: Bool = true) -> String {
        let provided = explicit.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !provided.isEmpty { return provided }
        guard fallbackToCurrentTenant else { return "" }
        return currentEnterprise.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func canSendCaptcha(scene: String, channel: String, appID: String, tenantCode: String = "", fallbackToCurrentTenant: Bool = true) async throws -> Bool {
        let entry = try await api.captchaEntryStatus(scene: scene, channel: channel, tenantCode: captchaTenantCode(tenantCode, fallbackToCurrentTenant: fallbackToCurrentTenant), appID: appID).preferredEntry(scene: scene, channel: channel)
        guard let entry else {
            throw IMAPIError.server("验证码入口状态不可用")
        }
        if !entry.required {
            return false
        }
        guard entry.enabled && entry.available else {
            throw IMAPIError.forbidden(entry.unavailableMessage)
        }
        return true
    }

    func captchaRequired(scene: String, channel: String, appID: String, tenantCode: String = "", fallbackToCurrentTenant: Bool = true) async throws -> Bool {
        let entry = try await api.captchaEntryStatus(scene: scene, channel: channel, tenantCode: captchaTenantCode(tenantCode, fallbackToCurrentTenant: fallbackToCurrentTenant), appID: appID).preferredEntry(scene: scene, channel: channel)
        guard let entry else {
            throw IMAPIError.server("验证码入口状态不可用")
        }
        guard entry.required else {
            return false
        }
        guard entry.enabled && entry.available else {
            throw IMAPIError.forbidden(entry.unavailableMessage)
        }
        return true
    }

    private func phoneCodeSuccessMessage(_ result: RemotePhoneCodeResult, fallbackMinutes: Int) -> String {
        var message = "验证码已发送"
        let phoneMasked = result.phoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phoneMasked.isEmpty {
            message += "至 \(phoneMasked)"
        }
        let seconds = result.expiresInSeconds
        if seconds > 0 {
            let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
            message += "，\(minutes) 分钟内有效"
        } else if fallbackMinutes > 0 {
            message += "，\(fallbackMinutes) 分钟内有效"
        }
        return message
    }

    private func phoneCodeCooldownSeconds(_ result: RemotePhoneCodeResult, fallbackSeconds: Int = 60) -> Int {
        let explicitSeconds = result.cooldownSeconds
        if explicitSeconds > 0 {
            return min(max(explicitSeconds, 1), 3_600)
        }
        return fallbackSeconds
    }

    private func phoneBindingChallengeSuccessMessage(_ challenge: RemotePhoneBindingChallenge) -> String {
        var message = "验证码已发送"
        let phoneMasked = challenge.phoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phoneMasked.isEmpty {
            message += "至 \(phoneMasked)"
        }
        if challenge.expiresInSeconds > 0 {
            let minutes = max(1, Int(ceil(Double(challenge.expiresInSeconds) / 60.0)))
            message += "，\(minutes) 分钟内有效"
        }
        return message
    }

    private func phoneBindingChallengeCooldownSeconds(
        _ challenge: RemotePhoneBindingChallenge,
        fallbackSeconds: Int = 60
    ) -> Int {
        guard challenge.cooldownSeconds > 0 else { return fallbackSeconds }
        return min(max(challenge.cooldownSeconds, 1), 3_600)
    }

    private func beginPhoneBindingChallengeIssue() -> UInt64 {
        phoneBindingChallengeIssueGeneration &+= 1
        pendingPhoneBindingChallenge = nil
        return phoneBindingChallengeIssueGeneration
    }

    func invalidatePhoneBindingChallenge(ownedBy scope: PhoneBindingChallengeSessionScope?) {
        phoneBindingChallengeIssueGeneration &+= 1
        guard let scope,
              pendingPhoneBindingChallenge?.sessionScope == scope else {
            return
        }
        pendingPhoneBindingChallenge = nil
    }

    private func isCurrentPhoneBindingChallengeIssue(
        generation: UInt64,
        sessionScope: PhoneBindingChallengeSessionScope
    ) -> Bool {
        phoneBindingChallengeIssueGeneration == generation
            && PhoneBindingChallengeSessionScope(context: apiContext) == sessionScope
    }

    private func isCurrentPhoneBindingChallenge(
        _ challenge: PendingPhoneBindingChallenge
    ) -> Bool {
        pendingPhoneBindingChallenge == challenge
            && phoneBindingChallengeIssueGeneration == challenge.issueGeneration
            && PhoneBindingChallengeSessionScope(context: apiContext) == challenge.sessionScope
    }

    private func clearPhoneBindingChallenge(_ challenge: PendingPhoneBindingChallenge) {
        guard pendingPhoneBindingChallenge == challenge else { return }
        pendingPhoneBindingChallenge = nil
    }

    func verifyPhoneBinding(phone: String, code: String) async -> Bool {
        await verifyPhoneBinding(
            phone: phone,
            code: code,
            requestID: pendingPhoneBindingChallenge?.requestID ?? ""
        )
    }

    func verifyPhoneBinding(phone: String, code: String, requestID: String) async -> Bool {
        let normalizedPhone = normalizedMainlandPhone(phone)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidMainlandPhone(normalizedPhone), normalizedCode.count >= 4 else {
            toast = "请填写手机号和验证码"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        guard let sessionScope = PhoneBindingChallengeSessionScope(context: context),
              !normalizedRequestID.isEmpty,
              let challenge = pendingPhoneBindingChallenge,
              challenge.sessionScope == sessionScope,
              challenge.normalizedPhone == normalizedPhone,
              challenge.requestID == normalizedRequestID,
              isCurrentPhoneBindingChallenge(challenge) else {
            toast = "手机号验证码请求已失效，请重新获取"
            return false
        }
        let submittedPhoneMasked = maskedPhoneDisplayText(normalizedPhone)
        do {
            let verifiedUser = try await api.verifyPhoneBinding(
                context: context,
                phone: normalizedPhone,
                code: normalizedCode,
                requestID: normalizedRequestID
            )
            guard isCurrentPhoneBindingChallenge(challenge) else { return false }
            let verifiedUserIMUID = verifiedUser.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard verifiedUser.phoneBindingKnown,
                  verifiedUser.phoneVerified,
                  verifiedUserIMUID == sessionScope.imUID else {
                clearPhoneBindingChallenge(challenge)
                toast = "该验证码未建立手机号持有证明，请重新获取短信验证码"
                return false
            }
            let status = try await api.verificationStatus(context: context)
            guard isCurrentPhoneBindingChallenge(challenge) else { return false }
            let statusIMUID = status.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            let statusPhoneMasked = status.phoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
            guard status.phoneBindingKnown,
                  status.phoneBound,
                  statusIMUID == sessionScope.imUID,
                  statusPhoneMasked == submittedPhoneMasked else {
                clearPhoneBindingChallenge(challenge)
                toast = "手机号绑定状态校验失败，请重新获取短信验证码"
                return false
            }
            clearPhoneBindingChallenge(challenge)
            guard applyVerificationStatus(
                status,
                preferredPhoneMasked: submittedPhoneMasked
            ) else {
                toast = "手机号绑定状态校验失败，请重新获取短信验证码"
                return false
            }
            toast = "手机号已绑定"
            return true
        } catch {
            guard isCurrentPhoneBindingChallenge(challenge) else { return false }
            clearPhoneBindingChallenge(challenge)
            handleRemoteError(error, fallback: "手机号绑定失败")
            return false
        }
    }

    func submitRealNameVerification(realName: String, idNumber: String) async -> Bool {
        realNameSubmissionErrorMessage = ""
        let normalizedName = RealNameValidator.sanitizedName(realName)
        let normalizedID = RealNameValidator.sanitizedIDNumber(idNumber)
        guard RealNameValidator.isValidName(normalizedName) else {
            toast = "真实姓名格式不正确"
            realNameSubmissionErrorMessage = "真实姓名格式不正确"
            return false
        }
        guard RealNameValidator.isValidChineseResidentID(normalizedID) else {
            toast = "身份证号码格式不正确"
            realNameSubmissionErrorMessage = "身份证号码格式不正确"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            realNameSubmissionErrorMessage = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        do {
            let status = try await api.submitRealNameVerification(context: context, realName: normalizedName, idNumber: normalizedID)
            guard isCurrentRemoteScope(scope) else { return false }
            guard applyVerificationStatus(status) else {
                realNameSubmissionErrorMessage = "实名认证状态校验失败，请稍后重试"
                toast = realNameSubmissionErrorMessage
                return false
            }
            let normalizedStatus = status.realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status.realNameRequirementSatisfied == true {
                toast = "实名认证已通过"
                return true
            }
            if normalizedStatus == "rejected" {
                realNameSubmissionErrorMessage = realNameVerificationFailedText
                toast = realNameSubmissionErrorMessage
                return false
            }
            toast = "实名认证申请已提交"
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            let message = userFacingError(error)
            realNameSubmissionErrorMessage = message == realNameVerificationFailedText ? message : "实名认证提交失败：\(message)"
            handleRemoteError(error, fallback: "实名认证提交失败")
            toast = realNameSubmissionErrorMessage
            return false
        }
    }

    func switchEnterprise(_ enterprise: Enterprise) {
        guard canUseEnterpriseDirectory else {
            toast = "请先登录后再切换企业"
            return
        }
        guard !isWorkspaceSwitchDisabledByPolicy else {
            toast = "管理员已关闭企业切换"
            return
        }
        guard enterprise.isWorkspaceJoined || enterprises.contains(where: { $0.id == enterprise.id && $0.isWorkspaceJoined }) else {
            toast = "该企业不在当前账号已加入列表，无法切换"
            return
        }
        guard enterprise.isWorkspaceEnterable else {
            let reason = enterprise.workspaceDisabledDescription
            toast = reason.isEmpty ? "该企业暂不可进入，请确认成员状态" : reason
            return
        }
        guard enterprise.canSwitch else {
            let reason = enterprise.workspaceDisabledDescription
            toast = reason.isEmpty ? "该企业暂不可切换，请联系管理员确认成员状态" : reason
            return
        }
        let previousEnterprise = currentEnterprise
        let previousContext = apiContext
        let switchGeneration = workspaceSwitchGeneration.issueToken()
        Task {
            do {
                // 保留账号/租户隔离缓存；仅在当前企业响应确认配置后复用，避免切换时闪现旧图。
                purgeCertificationIdentityRoot(rebindCurrentScope: false)
                prepareSplashForScopeChange(reason: "workspace_switch_start")
                retirePushDevices(for: previousContext)
                disconnectRealtime(shouldReconnect: false)
                EmojiPickerPreferenceLifecycle.purgePreviousAuthenticatedScope(
                    hasAuthenticatedSession: previousContext.hasIMSession,
                    product: "ios",
                    appID: IMAPIContext.normalizedIOSAppID(previousContext.appID),
                    accountID: previousContext.accountID,
                    tenantID: previousContext.tenantID,
                    imUID: previousContext.imUID
                )
                apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
                resetAuthenticatedRemoteData(showLoading: true)
                try await switchPlatformTenant(
                    tenantID: enterprise.id,
                    isCurrent: { self.workspaceSwitchGeneration.isCurrent(switchGeneration) }
                )
	                guard workspaceSwitchGeneration.isCurrent(switchGeneration) else { return }
	                let switchedContext = apiContext
	                let switchedScope = remoteDataScopeKey(for: switchedContext)
	                bindCallRecordPersistence(for: switchedContext)
	                activateMyInviteCodeForCurrentSession()
	                startSplashConfigurationRefresh(
                    context: switchedContext,
                    intent: .tenantEntry,
                    reason: "workspace_switch"
                )
                _ = await applyCachedRemoteSnapshotIfAvailable(context: switchedContext)
                guard workspaceSwitchGeneration.isCurrent(switchGeneration),
                      isCurrentRemoteScope(switchedScope) else { return }
                _ = await refreshRemoteSnapshot(silent: true, force: true)
                guard workspaceSwitchGeneration.isCurrent(switchGeneration),
                      isCurrentRemoteScope(switchedScope) else { return }
                startRealtimeConnection(context: switchedContext)
                registerPendingStandardPushDeviceIfPossible(reason: "workspace_switch")
                registerPendingVoIPDeviceIfPossible(reason: "workspace_switch")
                toast = "已切换到 \(enterprise.name)"
                enterpriseSwitchCompletionRevision &+= 1
            } catch {
                guard workspaceSwitchGeneration.isCurrent(switchGeneration) else { return }
                let workspaceAccessCode = workspaceAccessCode(from: error)
                apiContext = previousContext
                apiContext.save(sessionStore: protectedSessionStore)
                currentEnterprise = previousEnterprise
                if workspaceAccessCode != "workspace_switch_disabled" {
                    startSplashConfigurationRefresh(
                        context: previousContext,
                        intent: .refreshOnly,
                        reason: "workspace_switch_rollback"
                    )
                }
                if let securityInfo = securityBlockedInfo(from: error) {
                    let affectsCurrent = handleSecurityBlocked(securityInfo, enterpriseID: enterprise.id)
                    if !affectsCurrent {
                        startRealtimeConnection()
                    }
                    return
                }
                if let code = workspaceAccessCode {
                    if code == "workspace_switch_disabled" {
                        startRealtimeConnection()
                        toast = workspaceAccessMessage(for: code)
                        return
                    }
                    guard shouldPersistWorkspaceEntryAccessBlock(code) else {
                        startRealtimeConnection()
                        toast = platformWorkspaceSwitchFailureMessage(error)
                        return
                    }
                    let affectsCurrent = markWorkspaceAccessBlocked(code, enterpriseID: enterprise.id)
                    if affectsCurrent {
                        disconnectRealtime(shouldReconnect: false)
                        forceWorkspaceSelectionForCurrentAccessBlock(code)
                    } else {
                        startRealtimeConnection()
                    }
                    toast = workspaceAccessMessage(for: code)
                    return
                }
                startRealtimeConnection()
                handleRemoteError(error, fallback: "企业存在，但切换失败")
            }
        }
    }

    func joinEnterprise(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            toast = "请输入企业编码或邀请码"
            return
        }
        toast = "请先搜索后台已有企业，再提交加入"
    }

    func enterpriseJoinKey(_ enterprise: Enterprise) -> String {
        let id = enterprise.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty {
            return "id:\(id)"
        }
        let code = enterprise.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !code.isEmpty {
            return "code:\(code)"
        }
        return "name:\(enterprise.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func workspaceDirectoryErrorMessage(_ error: Error, fallback: String) -> String {
        let mapped = userFacingError(error).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = mapped.isEmpty ? fallback : mapped
        return isRawWorkspaceDirectoryError(candidate) ? fallback : candidate
    }

    private func isRawWorkspaceDirectoryError(_ message: String) -> Bool {
        let lowered = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        let rawMarkers = [
            "sqlstate",
            "invalid input syntax",
            "uuid",
            "pq:",
            "duplicate key",
            "could not",
            "stack trace",
            "traceback",
            "syntax error",
            "cast",
            "constraint"
        ]
        return rawMarkers.contains { lowered.contains($0) }
    }

    func clearEnterpriseSearch() {
        enterpriseSearchResults = []
        enterpriseSearchMessage = nil
        isEnterpriseSearching = false
    }

    func searchEnterprises(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearEnterpriseSearch()
            return
        }
        guard canUseEnterpriseDirectory else {
            enterpriseSearchResults = []
            enterpriseSearchMessage = "请先登录后再搜索或加入企业。"
            toast = "请先登录后再搜索企业"
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            enterpriseSearchResults = []
            enterpriseSearchMessage = "请先登录后再搜索或加入企业。"
            toast = "请先登录后再搜索企业"
            return
        }
        let scope = remoteDataScopeKey(for: context)

        isEnterpriseSearching = true
        enterpriseSearchMessage = nil
        Task {
            defer {
                if isCurrentRemoteScope(scope) {
                    isEnterpriseSearching = false
                }
            }
            do {
                let workspaces = try await api.searchWorkspaces(context: context, keyword: trimmed)
                guard isCurrentRemoteScope(scope) else { return }
                let mapped = workspaces.enumerated().map { index, workspace in
                    enterprise(from: workspace, fallbackAccent: [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7][index % 4])
                }
                enterpriseSearchResults = mapped
                enterpriseSearchMessage = mapped.isEmpty ? "后台没有匹配的企业，请确认企业编码或邀请码后再搜索。" : nil
                handleWorkspaceApplicationStatus(mapped)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                enterpriseSearchResults = []
                if let apiError = error as? IMAPIError {
                    switch apiError {
                    case .unauthorized, .forbidden, .securityBlocked:
                        handleRemoteError(error, fallback: "企业搜索失败")
                        enterpriseSearchMessage = workspaceDirectoryErrorMessage(error, fallback: "企业搜索失败，请稍后重试")
                    case .server(let message):
                        let lowered = message.lowercased()
                        if lowered.contains("not found")
                            || lowered.contains("not exist")
                            || lowered.contains("no rows")
                            || lowered.contains("invalid status") {
                            enterpriseSearchMessage = "后台没有匹配的企业，请确认企业编码或邀请码后再搜索。"
                        } else {
                            enterpriseSearchMessage = workspaceDirectoryErrorMessage(error, fallback: "企业目录暂不可用，请稍后重试")
                            toast = "企业搜索失败：\(enterpriseSearchMessage ?? "服务不可用")"
                        }
                    default:
                        enterpriseSearchMessage = workspaceDirectoryErrorMessage(error, fallback: "企业搜索失败，请稍后重试")
                        toast = "企业搜索失败：\(enterpriseSearchMessage ?? "服务不可用")"
                    }
                } else {
                    enterpriseSearchMessage = workspaceDirectoryErrorMessage(error, fallback: "企业搜索失败，请稍后重试")
                    toast = "企业搜索失败：\(enterpriseSearchMessage ?? "服务不可用")"
                }
            }
        }
    }

    func joinEnterprise(_ enterprise: Enterprise) {
        guard canUseEnterpriseDirectory else {
            toast = "请先登录后再申请加入企业"
            return
        }
        let joinKey = enterpriseJoinKey(enterprise)
        guard enterpriseSearchResults.contains(where: { enterpriseJoinKey($0) == joinKey }) else {
            toast = "请先搜索后台已有企业，再提交加入"
            return
        }
        if !enterprise.isWorkspaceEnterable, !enterprise.workspaceDisabledDescription.isEmpty {
            toast = enterprise.workspaceDisabledDescription
            return
        }
        if enterprise.isWorkspaceJoinPending {
            toast = "入企申请等待审批中"
            return
        }
        if enterprise.isWorkspaceJoinRejected {
            toast = "入企申请已被拒绝，请联系企业管理员"
            return
        }
        if enterprise.isWorkspaceJoinApproved || enterprises.contains(where: { ($0.id == enterprise.id || (!$0.code.isEmpty && $0.code == enterprise.code)) && $0.isWorkspaceJoined }) {
            switchEnterprise(enterprise)
            return
        }
        let tenantCode = enterprise.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !tenantCode.isEmpty else {
            toast = "企业码缺失，请重新搜索后再试"
            return
        }
        guard !joiningEnterpriseKeys.contains(joinKey) else {
            toast = "正在提交申请，请稍候"
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "请先登录后再申请加入企业"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        joiningEnterpriseKeys.insert(joinKey)

        Task {
            defer {
                if isCurrentRemoteScope(scope) {
                    joiningEnterpriseKeys.remove(joinKey)
                }
            }
            do {
                let result = try await api.joinWorkspace(context: context, tenantCode: tenantCode)
                guard isCurrentRemoteScope(scope) else { return }
                var joinedEnterprise = result.tenant
                    .map { self.enterprise(from: $0, fallbackAccent: enterprise.accentHex) }
                    ?? enterprise
                joinedEnterprise.applicationID = result.application?.id ?? joinedEnterprise.applicationID
                joinedEnterprise.applicationStatus = result.application?.status ?? joinedEnterprise.applicationStatus
                if !result.joinType.isEmpty || result.requiresApproval {
                    let requiresApproval = result.joinType == "approval_required"
                        || result.joinType == "requires_approval"
                        || result.joinType == "approval"
                        || result.requiresApproval
                    joinedEnterprise.approvalRequired = requiresApproval
                    if requiresApproval,
                       joinedEnterprise.joinStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       joinedEnterprise.applicationStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        joinedEnterprise.joinStatus = "pending"
                        joinedEnterprise.applicationStatus = "pending"
                    }
                }
                if !result.status.isEmpty {
                    joinedEnterprise.joinStatus = result.status
                }
                if joinedEnterprise.applicationStatus.isEmpty, !result.status.isEmpty {
                    joinedEnterprise.applicationStatus = result.status
                }
                if joinedEnterprise.isWorkspaceJoinPending {
                    upsertEnterprise(joinedEnterprise)
                    upsertEnterpriseSearchResult(joinedEnterprise)
                    toast = "入企申请已提交，等待审批"
                    return
                }
                if joinedEnterprise.isWorkspaceJoinRejected {
                    upsertEnterpriseSearchResult(joinedEnterprise)
                    toast = "入企申请已被拒绝，请联系企业管理员"
                    return
                }
                if joinedEnterprise.isWorkspaceJoined {
                    let workspaces = try await api.listWorkspaces(context: context)
                    guard isCurrentRemoteScope(scope) else { return }
                    applyWorkspaces(workspaces)
                    toast = joinedEnterprise.isWorkspaceJoinApproved ? "入企申请已通过" : "已加入 \(joinedEnterprise.name)"
                    let refreshed = enterprises.first { $0.id == joinedEnterprise.id || (!$0.code.isEmpty && $0.code == joinedEnterprise.code) }
                    let target = refreshed ?? joinedEnterprise
                    if target.isWorkspaceEnterable {
                        switchEnterprise(target)
                    }
                    return
                }
                upsertEnterpriseSearchResult(joinedEnterprise)
                toast = "企业加入状态已更新"
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_pending" {
                guard isCurrentRemoteScope(scope) else { return }
                var pending = enterprise
                pending.joinStatus = "pending"
                pending.applicationStatus = "pending"
                pending.approvalRequired = true
                pending.canSwitch = false
                upsertEnterprise(pending)
                upsertEnterpriseSearchResult(pending)
                toast = "入企申请等待审批中"
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_rejected" {
                guard isCurrentRemoteScope(scope) else { return }
                var rejected = enterprise
                rejected.joinStatus = "rejected"
                rejected.applicationStatus = "rejected"
                rejected.canSwitch = false
                upsertEnterpriseSearchResult(rejected)
                toast = "入企申请已被拒绝，请联系企业管理员"
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_approved" {
                guard isCurrentRemoteScope(scope) else { return }
                var approved = enterprise
                approved.joinStatus = "approved"
                approved.applicationStatus = "approved"
                approved.canSwitch = true
                upsertEnterprise(approved)
                upsertEnterpriseSearchResult(approved)
                toast = "入企申请已通过"
            } catch IMAPIError.conflict(let code, _) where code == "workspace_already_joined" {
                guard isCurrentRemoteScope(scope) else { return }
                do {
                    let workspaces = try await api.listWorkspaces(context: context)
                    guard isCurrentRemoteScope(scope) else { return }
                    applyWorkspaces(workspaces)
                    if let joined = enterprises.first(where: { $0.id == enterprise.id || (!$0.code.isEmpty && $0.code == enterprise.code) }) {
                        switchEnterprise(joined)
                    } else {
                        toast = "已加入该企业"
                    }
                } catch {
                    guard isCurrentRemoteScope(scope) else { return }
                    handleRemoteError(error, fallback: "刷新企业列表失败")
                }
            } catch IMAPIError.conflict(let code, _) where code == "workspace_directory_unavailable" || code == "workspace_tenant_unresolved" || code == "workspace_join_forbidden" || code == "workspace_join_bad_request" || code == "bad_workspace_join_request" {
                guard isCurrentRemoteScope(scope) else { return }
                toast = workspaceDirectoryErrorMessage(IMAPIError.conflict(code: code, message: ""), fallback: "入企申请暂不可用，请稍后重试")
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if let apiError = error as? IMAPIError,
                   case .unauthorized = apiError {
                    handleRemoteError(apiError, fallback: "企业加入失败")
                } else if let apiError = error as? IMAPIError,
                          case .securityBlocked = apiError {
                    handleRemoteError(apiError, fallback: "企业加入失败")
                } else {
                    let message = workspaceDirectoryErrorMessage(error, fallback: "企业加入失败，请稍后重试")
                    toast = message.hasPrefix("企业加入失败") ? message : "企业加入失败：\(message)"
                }
            }
        }
    }

    func registerAndEnterIM(phone: String = "", account: String = "", password: String = "", enterpriseCode: String, captchaCode: String = "") {
        guard isRegistrationEnabledForAuthUI else {
            authScreen = .accountLogin
            toast = EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage
            return
        }
        guard !isRegistrationSubmissionBlocked, registrationSubmissionTask == nil,
              !isAuthenticated, !apiContext.hasIMSession else { return }
        cancelRegistrationSessionRecovery()
        let submissionID = UUID()
        registrationSubmissionID = submissionID
        isAuthLoading = true
        registrationSubmissionTask = Task { @MainActor in
            defer {
                if registrationSubmissionID == submissionID {
                    registrationSubmissionTask = nil
                    registrationSubmissionID = nil
                    isAuthLoading = false
                }
            }
            await registerRemotely(
                phone: phone, account: account, password: password,
                enterpriseCode: enterpriseCode, captchaCode: captchaCode
            )
        }
    }

}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    func urlPathSegmentEncoded() throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw IMAPIError.badURL("invalid path segment")
        }
        return encoded
    }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
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

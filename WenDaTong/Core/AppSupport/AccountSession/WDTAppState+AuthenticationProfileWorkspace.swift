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

// WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
@MainActor
final class SessionReauthenticationStore {
    struct Snapshot: Equatable {
        var presentationID: UUID?
        var isSubmitting = false
        var errorMessage: String?

        var isPresented: Bool { presentationID != nil }
    }

    @Published private(set) var snapshot = Snapshot()
    fileprivate var context: IMAPIContext?
    private var submissionID: UUID?

    fileprivate func present(context: IMAPIContext) {
        self.context = context
        snapshot = Snapshot(presentationID: UUID(), isSubmitting: snapshot.isSubmitting)
    }

    fileprivate func dismiss() {
        context = nil
        if snapshot.isPresented || snapshot.errorMessage != nil {
            snapshot = Snapshot(isSubmitting: snapshot.isSubmitting)
        }
    }

    fileprivate func beginSubmission() -> UUID? {
        guard submissionID == nil else { return nil }
        let id = UUID()
        submissionID = id
        snapshot = Snapshot(presentationID: snapshot.presentationID, isSubmitting: true)
        return id
    }

    fileprivate func finishSubmission(_ id: UUID) {
        guard submissionID == id else { return }
        submissionID = nil
        snapshot.isSubmitting = false
    }

    fileprivate func setError(_ message: String, for presentationID: UUID) {
        guard snapshot.presentationID == presentationID, snapshot.errorMessage != message else { return }
        snapshot.errorMessage = message
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
// WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END

extension AppState {
    func beginSessionReauthentication() {
        guard isAuthenticated, !isAuthLoading, !isSessionReauthenticationPresented,
              !isShowingLaunchSplash, activeSplashOverlay == nil,
              slideCaptchaPresentationStore.challenge == nil else { return } // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
        guard (try? LocalMessageScope(context: apiContext)) != nil else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前账号身份不完整，无法安全恢复登录；本地数据已保留。")
            return
        }
        // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
        sessionReauthenticationStore.present(context: apiContext)
    }

    func cancelSessionReauthentication(presentationID: UUID? = nil) {
        let store = sessionReauthenticationStore
        if let presentationID, store.snapshot.presentationID != presentationID { return }
        store.dismiss()
        if store.snapshot.isSubmitting { cancelSlideCaptcha() }
    }

    private func isCurrentSessionReauthentication(_ id: UUID, context: IMAPIContext) -> Bool {
        !Task.isCancelled && isAuthenticated
            && sessionReauthenticationStore.snapshot.presentationID == id
            && apiContext.isSameAuthAuthority(as: context.authSessionFence)
    }
    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END

    /// A login response is staged, never applied through the ordinary logout/login lifecycle.
    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
    @discardableResult
    func reauthenticateCurrentSession(
        identifier: String,
        password: String,
        enterpriseCode: String,
        presentationID: UUID? = nil
    ) async -> Bool {
        let store = sessionReauthenticationStore
        guard !store.snapshot.isSubmitting, let id = store.snapshot.presentationID,
              presentationID == nil || presentationID == id,
              let original = store.context,
              isCurrentSessionReauthentication(id, context: original) else { return false }

        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Capture at the original owner/installed-auth phase before its request suspends.
        let requestAuthority = original.authSessionFence

        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END
        let username = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            store.setError("请输入当前账号和密码", for: id)
            return false
        }
        guard let submissionID = store.beginSubmission() else { return false }
        defer { store.finishSubmission(submissionID) }
    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END
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
                    store.setError("请填写当前企业的企业码", for: id) // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
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
                    tenantID: tenantID, platformToken: token, appID: original.appID, deviceID: original.deviceID, requestAuthority: requestAuthority
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
                    appID: original.appID, deviceID: original.deviceID, requestAuthority: requestAuthority
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
            store.setError("验证未完成，请确认使用原账号、密码和企业码；原聊天数据已保留。", for: id) // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
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
                sessionReauthenticationStore.setError("本地数据暂不可重新绑定，原数据已保留，请稍后重试。", for: id) // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
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
            // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
            sessionReauthenticationStore.setError(
                restored ? "登录状态未能安全保存，原聊天数据已保留，请重试。" : "登录存储状态待确认，请稍后重试；本地聊天数据未清理。",
                for: id
            )
            // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END
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
                // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
                sessionReauthenticationStore.setError(
                    restored ? "连接路由未能提交，请重试；本地聊天数据已保留。" : "登录存储状态待确认，请稍后重试；本地聊天数据未清理。",
                    for: id
                )
                // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END
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
        sessionReauthenticationStore.dismiss() // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
        startInboxRefreshLoop()
        startRTCCallRefreshLoop()
        startRealtimeConnection(context: candidate)
        Task { [weak self] in
            guard let self, self.apiContext.isSameAuthAuthority(as: candidate.authSessionFence) else { return }
            _ = await self.refreshRemoteSnapshot(silent: true, force: true)
        }
        // Authentication is not a claim that sync or the websocket handshake already succeeded.
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("身份已重新验证，正在恢复连接；原聊天数据已保留。")
        return true
    }

    // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110_BEGIN
    func cancelSlideCaptcha() {
        slideCaptchaPresentationStore.cancel()
    }

    func presentSlideCaptcha(_ challenge: RemoteSlideCaptchaChallenge) async throws -> SlideCaptchaTicket {
        try await slideCaptchaPresentationStore.present(challenge)
    }
    // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110_END

    @discardableResult
    func refreshCurrentAppPolicyForAuthUI(force: Bool = false) async -> Bool {
		defer { (api as? IMAPIClient)?.finishRuntimeColdLaunch() }
        #if DEBUG
        if authPolicyScreenshotModeEnabled, currentAppPolicy != nil {
            appPolicyPresentationStore.snapshot.hasResolvedCurrentAppPolicyForAuthUI = true // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            appPolicyPresentationStore.snapshot.isPhoneAuthDisabledByServer = currentAppPolicy?.phoneAuthEnabled == false // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            normalizeAuthScreenForPhoneAuthPolicy()
            applyAccessDiagnosticsPolicy(currentAppPolicy!, source: "cache")
            return true
        }
        #endif
        do {
            _ = try await loadCurrentAppPolicy(force: force)
            appPolicyPresentationStore.snapshot.hasResolvedCurrentAppPolicyForAuthUI = true // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            normalizeAuthScreenForPhoneAuthPolicy()
            return true
        } catch {
            disableAccessDiagnosticsOverlay()
            appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = currentAppPolicyFailureMessage(error) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            appPolicyPresentationStore.snapshot.hasResolvedCurrentAppPolicyForAuthUI = true // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            normalizeAuthScreenForPhoneAuthPolicy()
            return false
        }
    }

    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：协议入口返回受控拉取的正文内容
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_BEGIN
    func legalDocumentContent(for type: LegalDocumentType) async -> Result<LegalDocumentContent, LegalDocumentLoadFailure> {
        let appID = currentAppID
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(LegalDocumentLoadFailure(message: "当前应用配置缺失，请联系管理员"))
        }
        let context = legalDocumentRequestContext()
        do {
            let content = try await api.legalDocumentContent(type: type, appID: appID, context: context)
            return .success(content)
        } catch {
            return .failure(LegalDocumentLoadFailure(message: legalDocumentFailureMessage(error)))
        }
    }
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_END

}

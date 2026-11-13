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

    func finishRegistrationAwaitingManualLogin(message: String) {
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        stopInboxRefreshLoop()
        disableAccessDiagnosticsOverlay()
        apiContext.clearSession(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        activeTab = .chats
        loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
    }

    private func finishRegistrationAwaitingApproval(message: String) {
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        stopInboxRefreshLoop()
        disableAccessDiagnosticsOverlay()
        resetAuthenticatedRemoteData(showLoading: false)
        activeTab = .chats
        loginWorkspacePresentationStore.snapshot.message = message // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
    }

    func resumeRegistrationWorkspaceJoin(
        from data: RemoteAuthData,
        entryCode: String?,
        generation: Int
    ) async throws -> Bool {
        guard applyAuthData(data), authFlowGeneration.isCurrent(generation) else {
            return false
        }

        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Capture at the original owner/installed-auth phase before its request suspends.
        let requestAuthority = apiContext.authSessionFence

        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END
        do {
        let appID = IMAPIContext.normalizedIOSAppID(apiContext.appID)
        let platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, platformToken?.isEmpty == false else { return false }

        var memberships = (data.memberships ?? []).filter { $0.isVisibleInAppScope(appID) }
        if memberships.isEmpty {
            memberships = try await api.listMyTenants(platformToken: platformToken, appID: appID, requestAuthority: requestAuthority)
            guard authFlowGeneration.isCurrent(generation), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
        }
        if memberships.isEmpty {
            // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_BEGIN
            let normalizedEntryCode = RegistrationFlowPolicy.submittedEntryCode(entryCode)
            guard !normalizedEntryCode.isEmpty else { return false }
            do {
                memberships = [try await api.joinTenantAfterRegistration(
                    // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_END
                    code: normalizedEntryCode,
                    platformToken: platformToken,
                    appID: appID, requestAuthority: requestAuthority
                )]
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_pending" {
                guard authFlowGeneration.isCurrent(generation), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
                finishRegistrationAwaitingApproval(message: RegistrationFlowPolicy.pendingWorkspaceApprovalMessage)
                return true
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_rejected" {
                guard authFlowGeneration.isCurrent(generation), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
                finishRegistrationAwaitingManualLogin(message: "入企申请已被拒绝，请联系企业管理员")
                return true
            } catch IMAPIError.conflict(let code, _) where [
                "workspace_join_approved", "workspace_already_joined", "workspace_join_conflict"
            ].contains(code) {
                memberships = try await api.listMyTenants(platformToken: platformToken, appID: appID, requestAuthority: requestAuthority)
            }
            guard authFlowGeneration.isCurrent(generation), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("注册成功，请选择企业")
        return true

        } catch {
            guard authFlowGeneration.isCurrent(generation), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
            throw error
        }
}

    func registrationCompletionDecision(
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

    func completeRegistrationSession(
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
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        resetAuthenticatedRemoteData(showLoading: false)
        registrationConfirmationStore.snapshot.resolution = .pending // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
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

    func registrationData(
        _ data: RemoteAuthData,
        matches context: PreAuthEnterpriseContext
    ) -> Bool {
        guard !data.fallbackToDefaultTenant else { return false }
        if data.hasTypedEntryAuthority {
            guard let authority = RegistrationFlowPolicy.entryAuthority(
                entryType: data.entryType,
                scheme: data.entryScheme,
                canonical: data.entryCanonical,
                submittedEntryCode: context.entryCode,
                echoedEntryCode: data.requestedTenantCode,
                allowsServerDefinedInvite: true // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
            ),
            authority.entryType == context.entryType,
            authority.scheme == context.entryScheme,
            authority.canonicalCode == context.entryCode else {
                return false
            }
        }
        let canonicalTenantCode = normalizedRegistrationTenantCode(context.tenantCode)
        let requestedTenantCode = RegistrationFlowPolicy.submittedEntryCode(data.requestedTenantCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        guard !canonicalTenantCode.isEmpty,
              requestedTenantCode == context.entryCode
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

    func registrationResponseShouldFailClosedForAppIDIsolation(_ data: RemoteAuthData, requestedEnterpriseCode: String?,
        entryAuthority: RegistrationEntryAuthority? = nil) -> Bool {
        let requestedCode = RegistrationFlowPolicy.submittedEntryCode(requestedEnterpriseCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        guard !requestedCode.isEmpty else { return false }
        if data.fallbackToDefaultTenant {
            return true
        }
        if isRegistrationTenantNotFoundText(data.fallbackReason) {
            return true
        }
        // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_BEGIN
        if entryAuthority?.kind == .memberInvitation || isMemberInviteEntryCode(requestedCode) {
            return false
        }
        if RegistrationFlowPolicy.normalizedEntryCode(requestedCode) == nil {
            // A legacy success can bind a server-defined code by echoing it.
            return RegistrationFlowPolicy.submittedEntryCode(data.requestedTenantCode) != requestedCode
        }
        // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_END
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

    func registrationFailureMessage(_ error: Error, enterpriseCode: String) -> String {
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
    func registrationBackendCodeFailureMessage(_ error: Error) -> String? {
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

    func registrationPendingConfirmationMessage(_ error: Error) -> String? {
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
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN
        if let rejection = error as? IMAnonymousDeviceRejectionError { return rejection.userMessage }
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END
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

    func memberInviteCodeErrorMessage(_ error: Error) -> String? {
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

    func memberInviteCodeErrorMessage(_ value: String) -> String? {
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
        var requestAuthority = apiContext.authSessionFence
        do {
            let platformData = try await api.login(username: username, password: password)
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            guard applyAuthData(platformData) else {
                throw IMAPIError.server("protected_session_persistence_failed")
            }

        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Capture at the original owner/installed-auth phase before its request suspends.
            requestAuthority = apiContext.authSessionFence

        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END
            let platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            let scopedAppID = IMAPIContext.normalizedIOSAppID(apiContext.appID)
            var memberships = try await api.listMyTenants(platformToken: platformToken, appID: scopedAppID, requestAuthority: requestAuthority)
            guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
            if memberships.isEmpty {
                let code = enterpriseCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let joinCode = code?.isEmpty == false ? code! : "WXT000001"
                do {
                    let membership = try await api.joinTenant(code: joinCode, platformToken: platformToken, appID: scopedAppID, requestAuthority: requestAuthority)
                    guard authFlowGeneration.isCurrent(generation) else { throw CancellationError() }
                    memberships = [membership]
                } catch IMAPIError.conflict {
                    memberships = try await api.listMyTenants(platformToken: platformToken, appID: scopedAppID, requestAuthority: requestAuthority)
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
            setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            loginWorkspacePresentationStore.snapshot.message = "已恢复账号，请选择本次要进入的企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            return !memberships.isEmpty
        } catch _ as CancellationError {
            throw CancellationError()
        } catch {
            guard authFlowGeneration.isCurrent(generation), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
            if isRegistrationTenantNotFoundError(error) {
                throw error
            }
            return false
        }
    }

}

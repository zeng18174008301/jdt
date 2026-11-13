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

extension AppState {
    func workspaceAccessCodeFromRaw(_ raw: String) -> String? {
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
            setCurrentEnterprise(blocked(currentEnterprise)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            affectsCurrent = true
        }
        setEnterprises(enterprises.map { shouldBlock($0) ? blocked($0) : $0 }) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        enterpriseDirectoryStore.projectSearchResults { shouldBlock($0) ? blocked($0) : $0 } // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110
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
        purgeSearchHistoryForAccessBlock(code, context: previousContext, tenant: blockedEnterpriseID) // WDT_IOS1_SEARCH_HISTORY_20261113
        let hasPlatformSession = previousContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if hasPlatformSession {
            refreshWorkspaceSelectionListAfterAccessBlock(
                context: previousContext,
                requestAuthority: apiContext.authSessionFence,
                blockedCode: code,
                blockedEnterpriseID: blockedEnterpriseID
            )
        }
        stopInboxRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        prepareSplashForScopeChange(reason: "workspace_access_blocked")
        resetAuthenticatedRemoteData(showLoading: false)
        apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        activeTab = .chats
        if hasPlatformSession {
            setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            loginWorkspacePresentationStore.snapshot.message = "\(message)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        } else {
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(hasPlatformSession ? message : "\(message)，请重新登录后选择企业")
    }

    private func refreshWorkspaceSelectionListAfterAccessBlock(context: IMAPIContext, requestAuthority: IMAuthSessionFence, blockedCode: String, blockedEnterpriseID: String?) {
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Capture at the original owner/installed-auth phase before its request suspends.
        // The caller captures the post-access-block root authority before this Task starts.
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END

        let expectedPlatformToken = context.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expectedPlatformToken.isEmpty else { return }
        Task { [weak self] in
            guard let self, self.apiContext.isSameAuthAuthority(as: requestAuthority) else { return }
            if context.hasIMSession, let workspaces = try? await self.api.listWorkspaces(context: context) {
                guard self.apiContext.isSameAuthAuthority(as: requestAuthority),
                      self.authScreen == .workspaceSelection,
                      !self.isAuthenticated,
                      self.apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedPlatformToken else { return }
                self.applyWorkspaces(workspaces)
                _ = self.markWorkspaceAccessBlocked(blockedCode, enterpriseID: blockedEnterpriseID)
                return
            }

            let scopedAppID = IMAPIContext.normalizedIOSAppID(context.appID)
            if let memberships = try? await self.api.listMyTenants(platformToken: expectedPlatformToken, appID: scopedAppID, requestAuthority: requestAuthority), !memberships.isEmpty {
                guard self.apiContext.isSameAuthAuthority(as: requestAuthority),
                      self.authScreen == .workspaceSelection,
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
        guard let conversation = conversationStore.conversationMessageSnapshots().first(where: { conversation in
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
            setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            activeTab = .chats
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            bootstrapPresentationStore.sync.syncFailureMessage = message // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            if !silent {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            }
            return true
        }

        let affectsCurrent = markWorkspaceAccessBlocked("security_blocked", enterpriseID: targetEnterpriseID)
        if affectsCurrent {
            disconnectRealtime(shouldReconnect: false)
            forceWorkspaceSelectionForCurrentAccessBlock("security_blocked")
            loginWorkspacePresentationStore.snapshot.message = "\(message)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            bootstrapPresentationStore.sync.syncFailureMessage = message // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        }
        if !silent {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
        }
        return affectsCurrent
    }

    func applySyncFailure(_ error: Error, silent: Bool) {
        let message = syncFailureUserMessage(error)
        if let securityInfo = securityBlockedInfo(from: error) {
            handleSecurityBlocked(securityInfo, silent: silent)
            bootstrapPresentationStore.sync.syncFailureMessage = securityInfo.userMessage // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
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
        bootstrapPresentationStore.sync.syncFailureMessage = message // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

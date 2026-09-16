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

// MARK: - Remote Error Handling

extension AppState {
    func retryRemoteSync() {
        guard isAuthenticated, !isSyncRetrying else { return }
        isSyncRetrying = true
        syncFailureMessage = nil
        Task {
            let synced = await refreshRemoteSnapshot(silent: false, force: true)
            isSyncRetrying = false
            if synced {
                toast = "聊天数据已同步"
            }
        }
    }

    func retryContactsSync() {
        guard isAuthenticated,
              apiContext.hasIMSession,
              !isContactsSyncing else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
              isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        contactStore.setContactsSyncError(nil)
        Task {
            await refreshContactsAndNoticesInBackground(context: context, scope: scope, refreshSession: refreshSession)
        }
    }

    func isSendPolicyForbidden(_ error: Error) -> Bool {
        sendPolicyMutedMessage(from: error) != nil
    }

    func isGroupAllMutedError(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .businessForbidden(let code, let message, _),
             .conflict(let code, let message),
             .loginSecurity(let code, let message, _),
             .rateLimited(let code, let message, _, _):
            if isGroupMemberMutedCode(code) || isGroupMemberMutedText(message) {
                return false
            }
            return isSendPolicyMutedCode(code) || isSendPolicyMutedText(message)
        case .forbidden(let message),
             .httpStatus(_, let message),
             .server(let message),
             .unauthorized(let message):
            return !isGroupMemberMutedText(message) && isSendPolicyMutedText(message)
        case .securityBlocked(_), .forcedAuthRequired(_), .missingContext(_), .badURL(_), .emptyResponse:
            return false
        }
    }

    func sendPolicyMutedMessage(from error: Error) -> String? {
        guard let apiError = error as? IMAPIError else { return nil }
        switch apiError {
        case .businessForbidden(let code, let message, _),
             .conflict(let code, let message),
             .loginSecurity(let code, let message, _),
             .rateLimited(let code, let message, _, _):
            if isGroupMemberMutedCode(code) || isGroupMemberMutedText(message) {
                return Self.groupMemberMutedMessage
            }
            if isSendPolicyMutedCode(code) || isSendPolicyMutedText(message) {
                return Self.globalMutedMessage
            }
        case .forbidden(let message),
             .httpStatus(_, let message),
             .server(let message),
             .unauthorized(let message):
            if isGroupMemberMutedText(message) {
                return Self.groupMemberMutedMessage
            }
            if isSendPolicyMutedText(message) {
                return Self.globalMutedMessage
            }
        case .securityBlocked(_), .forcedAuthRequired(_), .missingContext(_), .badURL(_), .emptyResponse:
            break
        }
        return nil
    }

    private func isSendPolicyMutedCode(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "global_muted" || normalized == "group_muted"
    }

    func isGroupMemberMutedError(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .businessForbidden(let code, let message, _),
             .conflict(let code, let message),
             .loginSecurity(let code, let message, _),
             .rateLimited(let code, let message, _, _):
            return isGroupMemberMutedCode(code) || isGroupMemberMutedText(message)
        case .forbidden(let message),
             .httpStatus(_, let message),
             .server(let message),
             .unauthorized(let message):
            return isGroupMemberMutedText(message)
        case .securityBlocked(_), .forcedAuthRequired(_), .missingContext(_), .badURL(_), .emptyResponse:
            return false
        }
    }

    private func isGroupMemberMutedCode(_ code: String) -> Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "group_member_muted"
    }

    private func isGroupMemberMutedText(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("group_member_muted")
            || message.contains("你已被禁言，无法在该群发送消息")
    }

    private func isSendPolicyMutedText(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("global_muted")
            || normalized.contains("group_muted")
            || message.contains("全局禁言")
            || message.contains("全员禁言")
            || message.contains("消息禁言策略")
    }

    func localSendPolicyBlockedMessage(for conversation: Conversation) -> String? {
        guard conversation.kind == .group,
              let group = group(for: conversation) else {
            return nil
        }
        if group.groupMuted && !canManageGroup(group) {
            return Self.groupMemberMutedMessage
        }
        if group.allMuteRepairRequired && group.allMuted && !canManageGroup(group) {
            return Self.globalMutedMessage
        }
        guard !canCurrentUserSend(in: group) else { return nil }
        return Self.globalMutedMessage
    }

    func markGroupMutedForConversation(_ conversation: Conversation, muted: Bool = true) {
        guard conversation.kind == .group,
              let group = group(for: conversation),
              let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].groupMuted = muted
    }

    func isNotFriendsError(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        if case .businessForbidden(let code, let message, _) = apiError {
            return isNotFriendsForbiddenMessage("\(code) \(message)")
        }
        if case .forbidden(let message) = apiError {
            return isNotFriendsForbiddenMessage(message)
        }
        return false
    }

    func isNotFriendsForbiddenMessage(_ message: String) -> Bool {
        message.contains("not_friends")
            || message.contains("friendship_required")
            || message.contains("需先添加好友")
    }

    func directFriendRequestContext(from error: Error, fallback conversation: Conversation) -> DirectFriendRequestContext {
        let fallbackTarget = directPeerID(for: conversation) ?? ""
        guard let apiError = error as? IMAPIError else {
            return DirectFriendRequestContext(targetUID: fallbackTarget, canApplyFriend: nil, friendRequestStatus: "", reasonCode: "friendship_required")
        }
        if case .businessForbidden(_, _, let errorBody) = apiError {
            return directFriendRequestContext(from: errorBody, fallbackTargetUID: fallbackTarget)
        }
        return DirectFriendRequestContext(targetUID: fallbackTarget, canApplyFriend: nil, friendRequestStatus: "", reasonCode: "friendship_required")
    }

    func directFriendRequestContext(from error: APIEnvelopeError?, fallbackTargetUID: String) -> DirectFriendRequestContext {
        let targetUID = [
            error?.peerIMUID,
            error?.peerUserID,
            error?.targetUID,
            fallbackTargetUID
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return DirectFriendRequestContext(
            targetUID: targetUID,
            canApplyFriend: error?.canApplyFriend,
            friendRequestStatus: error?.friendRequestStatus ?? "",
            reasonCode: error?.reasonCode ?? error?.code ?? "friendship_required",
            friendAction: error?.friendAction ?? "",
            friendFlow: error?.friendFlow ?? ""
        )
    }

    func directFriendRequestContext(from payload: [String: JSONValue], fallbackTargetUID: String) -> DirectFriendRequestContext {
        func string(_ keys: [String]) -> String {
            keys.compactMap { key -> String? in
                let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }.first ?? ""
        }

        func bool(_ keys: [String]) -> Bool? {
            keys.compactMap { key -> Bool? in
                guard let value = payload[key] else { return nil }
                if let boolValue = value.boolValue { return boolValue }
                let normalized = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                if ["true", "1", "yes"].contains(normalized) { return true }
                if ["false", "0", "no"].contains(normalized) { return false }
                return nil
            }.first ?? nil
        }

        let targetUID = [
            string(["peer_im_uid", "peerImUID", "peer_user_id", "peerUserID", "target_uid", "targetUID"]),
            fallbackTargetUID
        ].first { !$0.isEmpty } ?? ""
        return DirectFriendRequestContext(
            targetUID: targetUID,
            canApplyFriend: bool(["can_apply_friend", "canApplyFriend"]),
            friendRequestStatus: string(["friend_request_status", "friendRequestStatus", "relation_status", "relationStatus"]),
            reasonCode: string(["reason_code", "reasonCode", "code"]),
            friendAction: string(["friend_action", "friendAction"]),
            friendFlow: string(["friend_flow", "friendFlow"])
        )
    }

    func refreshGroupPolicyAfterSendFailure(_ conversation: Conversation, scope: String) async {
        guard conversation.kind == .group,
              isCurrentRemoteScope(scope) else { return }
        await refreshGroupBundle(groupID: remoteChannelID(for: conversation), silent: true)
    }

    func isUnauthorizedError(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        if case .unauthorized(_) = apiError {
            return true
        }
        return false
    }

    @discardableResult
    func recoverDataPlaneUnauthorizedIfPossible(
        _ error: Error,
        context: IMAPIContext,
        scope: String,
        fallback: String,
        silent: Bool
    ) async -> Bool {
        guard isUnauthorizedError(error) else { return false }
        if DeviceRevocationDetector.matches(error: error) {
            handleCurrentDeviceRevoked()
            return false
        }
        let refreshed = await refreshStoredAuthSessionIfNeeded(
            reason: "data_plane_unauthorized",
            silent: true,
            context: context,
            scope: scope
        )
        guard isAuthenticated, isCurrentRemoteScope(scope) else { return false }
        if refreshed {
            return true
        }
        applySyncFailure(error, silent: silent)
        if !silent {
            showRemoteErrorToast("\(fallback)：登录状态暂时无法验证，请稍后重试")
        }
        return false
    }

    func isRefreshableSessionError(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .unauthorized:
            return apiContext.hasRefreshSession
        case .forbidden(let message), .server(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return apiContext.hasRefreshSession
                && (normalized.contains("session_expired")
                    || normalized.contains("reauth_required")
                    || normalized.contains("登录会话已过期")
                    || normalized.contains("需要重新验证"))
        default:
            return false
        }
    }

    private func isRefreshSessionTerminalError(_ error: Error) -> Bool {
        refreshSessionTerminationDisposition(error) != .retryable
    }

    func refreshSessionTerminationDisposition(
        _ error: Error
    ) -> IMAuthSessionTerminationDisposition {
        IMAuthSessionTerminationPolicy.disposition(
            code: DisasterRecoveryFallbackClassifier.normalizedCode(from: error),
            lifetimeMode: apiContext.authorityLifetimeMode,
            authorityFamily: apiContext.authSessionFence.authorityFamily
        )
    }

    func handleRemoteError(
        _ error: Error,
        fallback: String,
        silent: Bool = false,
        rtcMedia: RTCCapabilityMedia = .generic
    ) {
        #if DEBUG
        if authPolicyScreenshotModeEnabled {
            return
        }
        #endif
        if DeviceRevocationDetector.matches(error: error) {
            handleCurrentDeviceRevoked()
            return
        }
        if let securityInfo = securityBlockedInfo(from: error) {
            handleSecurityBlocked(securityInfo, silent: silent)
            return
        }
        if let quotaMessage = licenseQuotaUserMessage(from: error) {
            if !silent {
                toast = quotaMessage
            }
            return
        }
        if let mutedMessage = sendPolicyMutedMessage(from: error) {
            if !silent {
                toast = mutedMessage
            }
            return
        }
        if let code = workspaceAccessCode(from: error) {
            let affectsCurrent = markWorkspaceAccessBlocked(code)
            if affectsCurrent {
                disconnectRealtime(shouldReconnect: false)
                forceWorkspaceSelectionForCurrentAccessBlock(code)
            }
            if !silent {
                toast = workspaceAccessMessage(for: code)
            }
            return
        }
        if let capabilityMessage = capabilityUserMessage(from: error, rtcMedia: rtcMedia) {
            if !silent {
                if !presentRTCLicenseFailure(error, media: rtcMedia) {
                    toast = capabilityMessage
                }
            }
            return
        }
        if isNotFriendsError(error) {
            return
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .forcedAuthRequired(let requirement):
                presentForcedAppPolicyAuthPrompt(requirement)
                return
            case .securityBlocked(let info):
                handleSecurityBlocked(info, silent: silent)
                return
            case .unauthorized:
                handleNonAuthoritativeUnauthorized(error, fallback: fallback, silent: silent)
                return
            case .forbidden(let message):
                if !silent {
                    if isNotFriendsForbiddenMessage(message) {
                        return
                    } else if isMessagePinForbiddenMessage(message) {
                        toast = messagePinForbiddenText
                    } else if message.contains("blocked_by_me") {
                        toast = "你已拉黑对方，无法发送消息"
                    } else if message.contains("blocked_by_target") || message.contains("message_rejected_by_target") || message.contains("消息拒收") {
                        toast = "消息已被对方拒收"
                    } else if message.contains("workspace_identity_unlinked") {
                        toast = "当前 IM 用户未绑定平台账号，暂不能切换或加入企业"
                    } else if message.contains("成员已停用") || message.contains("tenant_member_disabled") {
                        toast = "当前企业成员关系已停用，请切换其他企业"
                    } else if isGroupMemberNotFoundMessage(message) {
                        toast = groupMemberNotFoundText
                    } else if message.contains("tenant_member_not_found") {
                        toast = "当前企业成员关系不存在，请切换其他企业"
                    } else if message.contains("企业已停用") || message.contains("tenant_service_stopped") {
                        toast = "当前企业已停用，请切换其他企业"
                    } else if message.contains("tenant_service_unavailable") || message.contains("企业服务暂不可用") {
                        toast = "当前企业服务暂不可用，请切换其他企业或稍后重试"
                    } else {
                        toast = sanitizeBackendMessage(message, fallback: "\(fallback)：无权限")
                    }
                }
                return
            default:
                break
            }
        }
        if !silent {
            showRemoteErrorToast("\(fallback)：\(userFacingError(error))")
        }
    }

    private func handleNonAuthoritativeUnauthorized(_ error: Error, fallback: String, silent: Bool) {
        let context = apiContext
        guard context.hasIMSession || context.hasRefreshSession else {
            isAuthenticated = false
            authScreen = .accountLogin
            if !silent {
                toast = "登录会话未建立，请重新登录"
            }
            return
        }
        let scope = context.hasIMSession ? remoteDataScopeKey(for: context) : ""
        applySyncFailure(error, silent: silent)
        if !silent {
            showRemoteErrorToast("\(fallback)：登录状态暂时无法验证，请稍后重试")
        }
        Task { [weak self, context, scope] in
            guard let self else { return }
            if context.hasIMSession,
               !self.isCurrentRemoteScope(scope) {
                return
            }
            // Only the refresh authority may classify this session as terminal.
            // Its terminal handler retains the existing revoke/expired/reused
            // clearing semantics; unavailable or nonterminal refresh preserves.
            _ = await self.refreshStoredAuthSessionIfNeeded(
                reason: "remote_error_unauthorized",
                silent: true,
                context: context,
                scope: scope
            )
        }
    }

    func showRemoteErrorToast(_ message: String) {
        let safeMessage = sanitizeBackendMessage(message, fallback: "操作失败，请稍后重试")
        let now = Date()
        let plan = remoteSyncEngine.remoteErrorToastPlan(message: safeMessage, now: now, throttleInterval: 12)
        guard case .show(let normalized) = plan else {
            return
        }
        remoteSyncEngine.rememberRemoteErrorToastShown(message: normalized, at: now)
        toast = normalized
    }

}

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

// WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_BEGIN
@MainActor
final class RTCCapabilityAlertStore {
    @Published var message: String?

    func observe<Content: View>(@ViewBuilder content: @escaping (String?) -> Content) -> some View {
        PublisherSnapshotView(initialValue: message, updates: $message.eraseToAnyPublisher(), content: content)
    }
}
// WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_END

extension AppState {
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
        // WDT_RECEIPT_DETAIL_SCOPE_20261023: only dedicated dissolve codes carry this meaning.
        let codes = Set(normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        if codes.contains("group_dissolve_permission_denied") || codes.contains("group_dissolve_forbidden") {
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

    // WDT_RECEIPT_DETAIL_SCOPE_20261023: used only at the actual dissolve/preview endpoints.
    static func groupDissolvePermissionMessage(for error: Error) -> String? {
        let code: String
        switch error {
        case IMAPIError.businessForbidden(let value, _, _), IMAPIError.conflict(let value, _):
            code = value
        case IMAPIError.forbidden(let value), IMAPIError.httpStatus(403, let value):
            code = value.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        default:
            return nil
        }
        guard code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "permission_denied" else { return nil }
        return "只有群主可以解散该群"
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
        rtcCapabilityAlertStore.message = message // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
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

    func registrationConflictMessage(_ message: String) -> String {
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

    func storageFailureMessage(from message: String) -> String? {
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

    func loginSecurityMessage(code: String, message: String, info: RemoteLoginSecurityInfo?) -> String {
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

    func loginLockedMessage(retryAfterSeconds: Int?, lockedUntil: String?) -> String {
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

    func syncFailureUserMessage(_ error: Error) -> String {
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

}

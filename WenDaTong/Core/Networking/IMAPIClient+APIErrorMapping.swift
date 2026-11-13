import Foundation
import CryptoKit
import Dispatch

@MainActor
extension IMAPIClient {
    nonisolated static func requestID(from result: HTTPTransportResult) -> String? {
        result.value(forHTTPHeaderField: "X-Request-Id")
            ?? result.value(forHTTPHeaderField: "X-Request-ID")
            ?? result.value(forHTTPHeaderField: "Request-Id")
    }

    static func isLoginRequestPath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "/api/tenant/auth/login"
            || normalized == "/api/platform/auth/im-login"
    }

    static func isAccessDiscoveryRequestPath(_ path: String) -> Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "/api/tenant/access/v1/endpoints"
    }

    static func isTerminalAccessDiscoveryErrorCode(_ code: String) -> Bool {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "access_discovery_disabled",
             "access_discovery_tenant_mismatch",
             "access_discovery_app_unavailable":
            return true
        default:
            return false
        }
    }

    static func loginFailureCode(_ code: String, statusCode: Int) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let knownCodes: Set<String> = [
            "bad_request",
            "invalid_credentials",
            "slide_captcha_required",
            "slide_captcha_invalid",
            "account_locked",
            "account_blocked",
            "login_locked",
            "ip_login_blocked",
            "device_blocked",
            "ip_blocked",
            "tenant_blocked",
            "security_policy_denied",
            "security_blocked",
            "account_disabled",
            "tenant_member_disabled",
            "tenant_member_not_found",
            "tenant_service_stopped",
            "tenant_disabled",
            "tenant_service_unavailable",
            "workspace_session_unavailable",
            "default_workspace_unavailable",
            "app_not_found",
            "workspace_identity_unlinked",
            "workspace_not_found",
            "app_tenant_not_bound",
            "ip_not_allowed",
            "device_binding_required",
            "device_not_bound",
            "license_not_started",
            "license_expired",
            "license_inactive",
            "account_password_sync_failed",
            "phone_auth_disabled",
            "token_sign_failed"
        ]
        if knownCodes.contains(normalized) {
            return normalized
        }
        switch statusCode {
        case 400:
            return "bad_request"
        case 401:
            return "invalid_credentials"
        case 423:
            return "account_locked"
        case 429:
            return "ip_login_blocked"
        default:
            return nil
        }
    }

    static func licenseCapabilityErrorCode(_ code: String) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let capabilityCodes: Set<String> = [
            "message_recall_window_exceeded",
            "voice_call_not_enabled",
            "video_call_not_enabled",
            "rtc_license_capabilities_unavailable",
            "rtc_media_config_missing",
            "rtc_ice_config_missing",
            "rtc_turn_config_missing",
            "read_receipts_not_enabled",
            "feature_not_enabled",
            "group_admin_delete_message_not_enabled"
        ]
        return capabilityCodes.contains(normalized) ? normalized : nil
    }

    static func licenseQuotaErrorCode(_ code: String) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "registered_user_quota_exceeded",
             "online_quota_exceeded",
             "online_quota_service_unavailable",
             "group_member_quota_exceeded":
            return normalized
        default:
            return nil
        }
    }

    static func licenseQuotaUserMessage(for code: String) -> String {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "registered_user_quota_exceeded":
            return "当前企业注册用户数已达上限，请联系企业管理员"
        case "online_quota_exceeded":
            return "当前企业在线人数已达上限，请稍后重试或联系企业管理员"
        case "online_quota_service_unavailable":
            return "在线服务暂时不可用，请稍后重试"
        case "group_member_quota_exceeded":
            return "该群人数已达上限，暂时无法加入"
        default:
            return ""
        }
    }

    nonisolated static func retryAfterSeconds(from result: HTTPTransportResult) -> Int? {
        let raw = result.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        if let seconds = Int(raw) {
            return max(0, seconds)
        }
        if let date = HTTPDateFormatter.date(from: raw) {
            return max(0, Int(ceil(date.timeIntervalSinceNow)))
        }
        return nil
    }

    static func userMessage(for error: APIEnvelopeError?, fallback: String) -> String {
        let code = effectiveErrorCode(for: error)
        let backendMessage = [error?.message, error?.reason]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        switch code {
        case "bad_request":
            return "请输入账号和密码"
        case "login_locked":
            return "登录尝试过多，请稍后再试"
        case "invalid_credentials":
            return "账号或密码错误"
        case "slide_captcha_required":
            return "需要完成安全验证后再登录"
        case "slide_captcha_invalid":
            return "安全验证已失效，请重新验证后再登录"
        case "invalid_user_account_format", "invalid_account_format":
            return "账号必须为 5-10 位数字或英文字母"
        case "account_locked":
            return "账号已锁定，请联系商户后台管理员解锁"
        case "account_blocked":
            return "账号因安全策略限制，暂不可登录"
        case "device_blocked":
            return "当前设备暂不可登录"
        case "ip_blocked":
            return "当前网络暂不可登录"
        case "tenant_blocked":
            return "当前企业暂不可访问"
        case "security_policy_denied":
            return "操作被企业安全策略限制"
        case "security_blocked":
            return SecurityBlockedInfo(error: error).userMessage
        case "ip_login_blocked":
            return "今日登录失败次数过多，当前网络已被禁止登录"
        case "account_password_sync_failed":
            return "账号服务暂不可用，请稍后重试"
        case "registered_user_quota_exceeded":
            return licenseQuotaUserMessage(for: "registered_user_quota_exceeded")
        case "online_quota_exceeded":
            return licenseQuotaUserMessage(for: "online_quota_exceeded")
        case "online_quota_service_unavailable":
            return licenseQuotaUserMessage(for: "online_quota_service_unavailable")
        case "group_member_quota_exceeded":
            return licenseQuotaUserMessage(for: "group_member_quota_exceeded")
        case "ip_not_allowed":
            return "当前网络不在企业允许登录范围内"
        case "session_expired":
            return "登录会话已过期，请重新登录"
        case "refresh_token_expired":
            return "登录续期已过期，请重新登录"
        case "session_revoked":
            return "登录会话已失效，请重新登录"
        case "refresh_token_reused":
            return "登录续期凭证异常，请重新登录"
        case "reauth_required":
            return "当前登录状态需要重新验证"
        case "risk_blocked":
            return "访问已被安全策略限制"
        case "global_muted":
            return globalMutedMessageText
        case "group_muted":
            return globalMutedMessageText
        case "group_member_muted":
            return groupMemberMutedMessageText
        case "group_mute_permission_denied":
            return "禁言名单仅群主或管理员可操作"
        case "group_mute_target_role_not_allowed":
            return "群主或管理员不能加入禁言名单"
        case "not_friends":
            return "需先添加好友后才能发起私聊"
        case "friend_not_found":
            return "好友关系已变化，请刷新联系人后重试"
        case "invalid_friend_remark":
            return "好友备注最多 128 个字符"
        case "friend_remark_readback_failed":
            return "备注可能已保存，正在重新确认"
        case "friend_relation_changed":
            return FriendAddPresentation.relationChangedMessage
        case "client_friend_requests_disabled":
            return "当前关系状态已更新，请重试"
        case "blocked_by_me":
            return "你已拉黑对方，无法发送消息"
        case "blocked_by_target", "message_rejected_by_target":
            return "消息已被对方拒收"
        case "workspace_identity_unlinked":
            return "当前账号企业身份未同步，请联系管理员处理"
        case "workspace_switch_disabled":
            return "管理员已关闭企业切换"
        case "account_disabled":
            return "账号已停用，请联系管理员"
        case "tenant_member_disabled":
            return "当前企业成员关系已停用，请切换其他企业"
        case "tenant_member_not_found":
            return "当前企业成员关系不存在，请切换其他企业"
        case "workspace_not_found", "app_tenant_not_bound":
            return "目标企业不存在，请返回企业列表重新选择"
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
        case "tenant_service_stopped":
            return "当前企业已停用，请切换其他企业"
        case "tenant_disabled":
            return "当前企业已停用，请切换其他企业"
        case "workspace_session_unavailable", "tenant_service_unavailable", "default_workspace_unavailable", "app_not_found":
            return "当前企业服务暂不可用，请切换其他企业或稍后重试"
        case "missing_entry_ticket", "invalid_entry_ticket", "entry_ticket_expired", "entry_ticket_replayed", "entry_ticket_audience_mismatch":
            return "企业入口票据校验失败"
        case "group_not_found":
            return "群聊不存在或已删除"
        case "group_create_not_allowed":
            return "管理员已关闭成员建群"
        case "group_join_request_not_found":
            return "入群申请不存在或已失效"
        case "group_unavailable":
            return "群聊不可用"
        case "group_join_forbidden":
            return "无权限处理该入群申请"
        case "permission_denied", "admin_delete_forbidden", "message_admin_delete_forbidden":
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
        case "group_invite_already_processed", "already_processed":
            return "该入群邀请已处理"
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
        case "provider_rejected", "kyc_auto_failed":
            return realNameVerificationFailedText
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
        case "rtc_media_config_missing", "rtc_ice_config_missing", "rtc_turn_config_missing":
            return rtcCapabilityFailureMessage(code: code ?? "", media: .generic)
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
            return rtcCapabilityFailureMessage(code: code ?? "", media: .generic) ?? "当前企业未开通通话"
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
        case "group_announcement_forbidden":
            return "无权限查看或处理该群公告"
        case "group_member_required":
            return "仅群成员可以查看该群公告"
        case "group_announcement_disabled":
            return "群公告功能暂不可用"
        case "group_announcement_not_found":
            return "群公告不存在或已失效"
        case "group_announcement_revision_conflict":
            return "公告已被其他管理员更新，请核对后重试"
        case "invalid_group_announcement":
            return "群公告内容不符合要求"
        case "invalid_group_description":
            return "群描述不能超过 500 个字符"
        case "friend_application_cancel_forbidden":
            return "仅申请发起者可取消该好友申请"
        case "friend_application_not_found":
            return "好友申请不存在或已失效"
        case "friend_application_terminal":
            return "好友申请状态已变化，请查看最新状态"
        case "group_owner_transfer_bad_request":
            return "群主转让参数不正确，请重试"
        case "group_owner_transfer_forbidden":
            return "仅当前群主可以转让群主"
        case "group_owner_transfer_target_not_found":
            return "目标成员已不在群内，请刷新后重试"
        case "group_owner_transfer_conflict":
            return "群主状态已变化，请刷新后重试"
        case "announcement_content_required":
            return "请输入公告内容"
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
             "captcha_device_proof_required",
             "invalid_captcha_request_limit",
             "invalid_captcha_cooldown",
             "captcha_invalid",
             "captcha_expired",
             "token_sign_failed":
            return captchaUserMessage(code: code, reason: backendMessage, fallback: "验证码服务暂不可用")
        case "forbidden":
            return Self.sanitizeBackendMessage(backendMessage ?? "", fallback: "无权限执行该操作")
        default:
            return Self.sanitizeBackendMessage(backendMessage ?? "", fallback: fallback)
        }
    }

    static func isNoCurrentGroupAnnouncementMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized.contains("group_announcement_not_found")
            || normalized.contains("announcement_not_found")
            || normalized.contains("not found")
            || normalized.contains("不存在")
            || normalized.contains("已失效")
            || normalized.contains("暂无")
    }

    static func effectiveErrorCode(for error: APIEnvelopeError?) -> String? {
        let code = error?.code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let reasonCode = error?.reasonCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let genericCodes: Set<String> = ["", "not_found", "bad_request", "forbidden", "conflict", "api_error"]
        if !reasonCode.isEmpty, genericCodes.contains(code) {
            return reasonCode
        }
        if !code.isEmpty {
            return code
        }
        return reasonCode.isEmpty ? nil : reasonCode
    }

    static func isFriendshipRequiredError(_ error: APIEnvelopeError) -> Bool {
        let combined = [
            error.code,
            error.reasonCode,
            error.reason,
            error.message
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")
        return combined.contains("not_friends")
            || combined.contains("friendship_required")
            || combined.contains("需先添加好友")
    }

    static func sanitizeBackendMessage(_ message: String, fallback: String) -> String {
        BackendUserMessageSanitizer.sanitize(message, fallback: fallback)
    }
}

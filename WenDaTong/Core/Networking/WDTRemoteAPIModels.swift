// WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_BEGIN
import Foundation
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

func safeCaptchaBackendReason(_ reason: String?) -> String {
    let trimmed = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let lowered = trimmed.lowercased()
    let blockedFragments = [
        "secret",
        "token",
        "device_proof",
        "preauth_device",
        "credential",
        "private_key",
        "private key",
        "key_ref",
        "secret_ref",
        "key ref",
        "secret ref",
        "sqlstate",
        "stack trace",
        "panic",
        "internal server error"
    ]
    if blockedFragments.contains(where: { lowered.contains($0) }) {
        return ""
    }
    return trimmed
}

func captchaUserMessage(code: String?, reason: String?, fallback: String) -> String {
    let normalizedCode = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalizedCode {
    case "captcha_config_missing":
        return "验证码配置缺失，请联系管理员"
    case "captcha_scene_disabled", "captcha_scene_not_enabled":
        return "当前场景未开启验证码"
    case "captcha_channel_unavailable":
        return "当前验证码通道不可用"
    case "tenant_not_found":
        return "企业不存在或不可用，请确认企业编码或邀请码"
    case "sms_provider_not_configured":
        return "短信服务未配置，请联系管理员"
    case "invalid_sms_template":
        return "短信模板未配置或不可用，请联系管理员"
    case "captcha_scene_required":
        return "当前操作需要完成验证码"
    case "invalid_captcha_channel":
        return "验证码通道不正确"
    case "rate_limit_unavailable":
        return "服务繁忙，请稍后重试"
    case "rate_limited", "captcha_request_cooldown", "captcha_request_rate_limited", "invalid_captcha_request_limit", "invalid_captcha_cooldown":
        let trimmedReason = safeCaptchaBackendReason(reason)
        return trimmedReason.isEmpty ? "验证码请求过于频繁，请稍后再试" : trimmedReason
    case "captcha_invalid":
        return "验证码错误或已失效"
    case "captcha_expired":
        return "验证码已过期，请重新获取"
    case "captcha_device_proof_required":
        return "设备验证已失效，请重新获取验证码"
    case "slide_captcha_required":
        return "请先完成滑动验证"
    case "slide_captcha_invalid":
        return "滑动验证已失效，请重新验证"
    case "token_sign_failed":
        return "验证码服务暂不可用，请稍后再试"
    default:
        let trimmedReason = safeCaptchaBackendReason(reason)
        return trimmedReason.isEmpty ? fallback : trimmedReason
    }
}

typealias APIEnvelope<T: Decodable> = IM4Data.APIEnvelope<T>

// WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_BEGIN

// WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_END

enum RemoteRegistrationStatus: String, Decodable, Sendable {
    case success = "SUCCESS"
    case pending = "PENDING"
    case failed = "FAILED"
}

struct RemoteRegistrationSessionResult: Decodable {
    let auth: RemoteAuthData
    let appID: String
    let deviceID: String
    let tenantID: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id", deviceID = "device_id", tenantID = "tenant_id"
    }

    init(from decoder: Decoder) throws {
        auth = try RemoteAuthData(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(String.self, forKey: .appID)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        tenantID = try c.decode(String.self, forKey: .tenantID)
    }

    func matches(_ recovery: RegistrationSessionRecovery) -> Bool {
        appID == recovery.appID && deviceID == recovery.deviceID && !tenantID.isEmpty
            && (recovery.tenantID == nil || recovery.tenantID == tenantID)
            && auth.tenant?.id == tenantID && auth.tenantMember?.tenantID == tenantID
            && auth.entryStatus == "registration_session_ready"
            && !auth.platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && auth.authSession?.isUsable == true
            && auth.authSession?.appID == appID && auth.authSession?.deviceID == deviceID
            && auth.authSession?.clientType == "ios" && auth.authSession?.normalizedTokenType == "platform"
    }
}

struct RemoteRegistrationConfirmation: Decodable, Sendable {
    let status: RemoteRegistrationStatus
}

typealias APILoginSecurityEnvelope = IM4Data.APILoginSecurityEnvelope

typealias APIErrorEnvelope = IM4Data.APIErrorEnvelope

typealias APIEnvelopeError = IM4Data.APIEnvelopeError

struct EmptyPayload: Decodable {}

extension KeyedDecodingContainer {
    // WDT_IOS1_SAFE_NUMERIC_20261023_BEGIN
    func decodeLossyStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            guard value.isFinite else { return nil }
            return Int64(exactly: value).map(String.init) ?? String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeLossyIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(exactly: value.rounded(.towardZero))
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeLossyInt64IfPresent(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int64(exactly: value.rounded(.towardZero))
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            guard let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite else { return nil }
            return parsed
        }
        return nil
    }

    // WDT_IOS1_SAFE_NUMERIC_20261023_END

    func decodeLossyBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y", "enabled"].contains(normalized) { return true }
            if ["false", "0", "no", "n", "disabled"].contains(normalized) { return false }
        }
        return nil
    }

    func decodeConfiguredBoolIfPresent(forKey key: Key) -> Bool? {
        guard contains(key) else { return nil }
        return decodeLossyBoolIfPresent(forKey: key) ?? false
    }

    func decodeStrictBoolIfPresent(forKey key: Key) -> Bool? {
        guard contains(key) else { return nil }
        return try? decode(Bool.self, forKey: key)
    }

    func decodeStrictIntIfPresent(forKey key: Key) -> Int? {
        guard contains(key) else { return nil }
        return try? decode(Int.self, forKey: key)
    }

    func decodeStrictInt64IfPresent(forKey key: Key) -> Int64? {
        guard contains(key) else { return nil }
        return try? decode(Int64.self, forKey: key)
    }

    func containsInvalidStrictValue<T: Decodable>(_ type: T.Type, forKey key: Key) -> Bool {
        guard contains(key) else { return false }
        return (try? decode(T.self, forKey: key)) == nil
    }
}

enum HTTPDateFormatter {
    static func date(from raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: raw)
    }
}

typealias RemoteList<T: Decodable> = IM4Data.RemoteList<T>

func decodeFlexibleBoolIfPresent<K: CodingKey>(_ container: KeyedDecodingContainer<K>, keys: [K]) -> Bool? {
    for key in keys {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y", "verified", "approved", "passed", "success", "已认证", "已验证"].contains(normalized) {
                return true
            }
            if ["false", "0", "no", "n", "unverified", "unbound", "未认证", "未验证", "未绑定"].contains(normalized) {
                return false
            }
        }
    }
    return nil
}

func decodeFlexibleBool<K: CodingKey>(_ container: KeyedDecodingContainer<K>, keys: [K]) -> Bool {
    if let value = decodeFlexibleBoolIfPresent(container, keys: keys) {
        return value
    }
    return false
}

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias JSONValue = IM4Data.JSONValue

extension JSONValue {
    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.anyValue)
        case .array(let value): return value.map(\.anyValue)
        case .null: return NSNull()
        }
    }
}
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END


extension APILoginSecurityEnvelope {
    var resolvedError: APIEnvelopeError? {
        let mergedCode = error?.code ?? code ?? reasonCode
        let mergedReasonCode = error?.reasonCode ?? reasonCode
        let mergedMessage = error?.message ?? message
        let mergedReason = error?.reason
        let mergedRetryAfterSeconds = error?.retryAfterSeconds
        let mergedLockedUntil = error?.lockedUntil
        let mergedScope = error?.scope
        let mergedTenantID = error?.tenantID
        let mergedSubjectType = error?.subjectType
        let mergedBlockType = error?.blockType
        let mergedStatus = error?.status
        let mergedExpiresAt = error?.expiresAt
        let mergedRemainingSeconds = error?.remainingSeconds
        guard mergedCode != nil
            || mergedReasonCode != nil
            || mergedMessage != nil
            || mergedReason != nil
            || mergedRetryAfterSeconds != nil
            || mergedLockedUntil != nil
            || mergedScope != nil
            || mergedTenantID != nil
            || mergedSubjectType != nil
            || mergedBlockType != nil
            || mergedStatus != nil
            || mergedExpiresAt != nil
            || mergedRemainingSeconds != nil else {
            return nil
        }
        return APIEnvelopeError(
            code: mergedCode,
            reasonCode: mergedReasonCode,
            message: mergedMessage,
            reason: mergedReason,
            retryAfterSeconds: mergedRetryAfterSeconds,
            lockedUntil: mergedLockedUntil,
            scope: mergedScope,
            tenantID: mergedTenantID,
            subjectType: mergedSubjectType,
            blockType: mergedBlockType,
            status: mergedStatus,
            expiresAt: mergedExpiresAt,
            remainingSeconds: mergedRemainingSeconds
        )
    }
}

extension APIErrorEnvelope {
    var resolvedError: APIEnvelopeError? {
        let mergedCode = error?.code ?? code ?? reasonCode ?? data?.code ?? data?.reasonCode
        let mergedReasonCode = error?.reasonCode ?? reasonCode ?? data?.reasonCode
        let mergedMessage = error?.message ?? message ?? reason ?? data?.message
        let mergedReason = error?.reason ?? reason ?? data?.reason
        let mergedRetryAfterSeconds = error?.retryAfterSeconds ?? data?.retryAfterSeconds
        let mergedLockedUntil = error?.lockedUntil ?? data?.lockedUntil
        let mergedScope = error?.scope ?? data?.scope
        let mergedTenantID = error?.tenantID ?? data?.tenantID
        let mergedSubjectType = error?.subjectType ?? data?.subjectType
        let mergedBlockType = error?.blockType ?? data?.blockType
        let mergedStatus = error?.status ?? data?.status
        let mergedExpiresAt = error?.expiresAt ?? data?.expiresAt
        let mergedRemainingSeconds = error?.remainingSeconds ?? data?.remainingSeconds
        let mergedPeerIMUID = error?.peerIMUID ?? data?.peerIMUID
        let mergedPeerUserID = error?.peerUserID ?? data?.peerUserID
        let mergedTargetUID = error?.targetUID ?? data?.targetUID
        let mergedCanApplyFriend = error?.canApplyFriend ?? data?.canApplyFriend
        let mergedFriendRequestStatus = error?.friendRequestStatus ?? data?.friendRequestStatus
        let mergedFriendAction = error?.friendAction ?? data?.friendAction
        let mergedFriendFlow = error?.friendFlow ?? data?.friendFlow
        guard mergedCode != nil
            || mergedReasonCode != nil
            || mergedMessage != nil
            || mergedReason != nil
            || mergedRetryAfterSeconds != nil
            || mergedLockedUntil != nil
            || mergedScope != nil
            || mergedTenantID != nil
            || mergedSubjectType != nil
            || mergedBlockType != nil
            || mergedStatus != nil
            || mergedExpiresAt != nil
            || mergedRemainingSeconds != nil
            || mergedPeerIMUID != nil
            || mergedPeerUserID != nil
            || mergedTargetUID != nil
            || mergedCanApplyFriend != nil
            || mergedFriendRequestStatus != nil
            || mergedFriendAction != nil
            || mergedFriendFlow != nil else {
            return nil
        }
        return APIEnvelopeError(
            code: mergedCode,
            reasonCode: mergedReasonCode,
            message: mergedMessage,
            reason: mergedReason,
            retryAfterSeconds: mergedRetryAfterSeconds,
            lockedUntil: mergedLockedUntil,
            scope: mergedScope,
            tenantID: mergedTenantID,
            subjectType: mergedSubjectType,
            blockType: mergedBlockType,
            status: mergedStatus,
            expiresAt: mergedExpiresAt,
            remainingSeconds: mergedRemainingSeconds,
            peerIMUID: mergedPeerIMUID,
            peerUserID: mergedPeerUserID,
            targetUID: mergedTargetUID,
            canApplyFriend: mergedCanApplyFriend,
            friendRequestStatus: mergedFriendRequestStatus,
            friendAction: mergedFriendAction,
            friendFlow: mergedFriendFlow
        )
    }
}
// WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_END

import Foundation
import CryptoKit

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

struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool?
    let data: T?
    let error: APIEnvelopeError?
}

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

struct APILoginSecurityEnvelope: Decodable {
    let code: String?
    let reasonCode: String?
    let message: String?
    let error: APIEnvelopeError?
    let data: RemoteLoginSecurityInfo?

    enum CodingKeys: String, CodingKey {
        case code
        case reasonCode = "reason_code"
        case message
        case error
        case data
    }

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

struct APIErrorEnvelope: Decodable {
    let ok: Bool?
    let code: String?
    let reasonCode: String?
    let message: String?
    let reason: String?
    let error: APIEnvelopeError?
    let data: APIEnvelopeError?

    enum CodingKeys: String, CodingKey {
        case ok
        case code
        case reasonCode = "reason_code"
        case message
        case reason
        case error
        case data
    }

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

struct APIEnvelopeError: Decodable {
    let code: String?
    let reasonCode: String?
    let message: String?
    let reason: String?
    let retryAfterSeconds: Int?
    let lockedUntil: String?
    let scope: String?
    let tenantID: String?
    let subjectType: String?
    let blockType: String?
    let status: String?
    let expiresAt: String?
    let remainingSeconds: Int?
    let peerIMUID: String?
    let peerUserID: String?
    let targetUID: String?
    let canApplyFriend: Bool?
    let friendRequestStatus: String?
    let friendAction: String?
    let friendFlow: String?

    enum CodingKeys: String, CodingKey {
        case code
        case reasonCode = "reason_code"
        case message
        case reason
        case reasonText = "reason_text"
        case retryAfter = "retry_after"
        case retryAfterSeconds = "retry_after_seconds"
        case retryAfterCamel = "retryAfter"
        case lockedUntil = "locked_until"
        case lockedUntilCamel = "lockedUntil"
        case blockedUntil = "blocked_until"
        case banUntil = "ban_until"
        case scope
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case subjectType = "subject_type"
        case subjectTypeCamel = "subjectType"
        case reasonCodeCamel = "reasonCode"
        case blockType = "block_type"
        case blockTypeCamel = "blockType"
        case status
        case expiresAt = "expires_at"
        case expiresAtCamel = "expiresAt"
        case remainingSeconds = "remaining_seconds"
        case remainingSecondsCamel = "remainingSeconds"
        case peerIMUID = "peer_im_uid"
        case peerIMUIDCamel = "peerImUID"
        case peerUserID = "peer_user_id"
        case peerUserIDCamel = "peerUserID"
        case targetUID = "target_uid"
        case targetUIDCamel = "targetUID"
        case canApplyFriend = "can_apply_friend"
        case canApplyFriendCamel = "canApplyFriend"
        case friendRequestStatus = "friend_request_status"
        case friendRequestStatusCamel = "friendRequestStatus"
        case relationStatus = "relation_status"
        case relationStatusCamel = "relationStatus"
        case friendAction = "friend_action"
        case friendActionCamel = "friendAction"
        case friendFlow = "friend_flow"
        case friendFlowCamel = "friendFlow"
        case error
    }

    init(
        code: String?,
        reasonCode: String? = nil,
        message: String?,
        reason: String? = nil,
        retryAfterSeconds: Int? = nil,
        lockedUntil: String? = nil,
        scope: String? = nil,
        tenantID: String? = nil,
        subjectType: String? = nil,
        blockType: String? = nil,
        status: String? = nil,
        expiresAt: String? = nil,
        remainingSeconds: Int? = nil,
        peerIMUID: String? = nil,
        peerUserID: String? = nil,
        targetUID: String? = nil,
        canApplyFriend: Bool? = nil,
        friendRequestStatus: String? = nil,
        friendAction: String? = nil,
        friendFlow: String? = nil
    ) {
        self.code = code
        self.reasonCode = reasonCode
        self.message = message
        self.reason = reason
        self.retryAfterSeconds = retryAfterSeconds
        self.lockedUntil = lockedUntil
        self.scope = scope
        self.tenantID = tenantID
        self.subjectType = subjectType
        self.blockType = blockType
        self.status = status
        self.expiresAt = expiresAt
        self.remainingSeconds = remainingSeconds
        self.peerIMUID = peerIMUID
        self.peerUserID = peerUserID
        self.targetUID = targetUID
        self.canApplyFriend = canApplyFriend
        self.friendRequestStatus = friendRequestStatus
        self.friendAction = friendAction
        self.friendFlow = friendFlow
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            code = value
            reasonCode = nil
            message = value
            reason = nil
            retryAfterSeconds = nil
            lockedUntil = nil
            scope = nil
            tenantID = nil
            subjectType = nil
            blockType = nil
            status = nil
            expiresAt = nil
            remainingSeconds = nil
            peerIMUID = nil
            peerUserID = nil
            targetUID = nil
            canApplyFriend = nil
            friendRequestStatus = nil
            friendAction = nil
            friendFlow = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try c.decodeIfPresent(APIEnvelopeError.self, forKey: .error)
        let decodedReasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode)
            ?? c.decodeIfPresent(String.self, forKey: .reasonCodeCamel)
        reasonCode = decodedReasonCode ?? nested?.reasonCode
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? decodedReasonCode ?? nested?.code ?? nested?.reasonCode
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? nested?.message
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
            ?? c.decodeIfPresent(String.self, forKey: .reasonText)
            ?? nested?.reason
        let retryAfterValue = c.decodeLossyIntIfPresent(forKey: .retryAfter)
            ?? c.decodeLossyIntIfPresent(forKey: .retryAfterSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .retryAfterCamel)
            ?? nested?.retryAfterSeconds
        retryAfterSeconds = retryAfterValue
        lockedUntil = try c.decodeIfPresent(String.self, forKey: .lockedUntil)
            ?? c.decodeIfPresent(String.self, forKey: .lockedUntilCamel)
            ?? c.decodeIfPresent(String.self, forKey: .blockedUntil)
            ?? c.decodeIfPresent(String.self, forKey: .banUntil)
            ?? nested?.lockedUntil
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? nested?.scope
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? nested?.tenantID
        subjectType = try c.decodeIfPresent(String.self, forKey: .subjectType)
            ?? c.decodeIfPresent(String.self, forKey: .subjectTypeCamel)
            ?? nested?.subjectType
        blockType = try c.decodeIfPresent(String.self, forKey: .blockType)
            ?? c.decodeIfPresent(String.self, forKey: .blockTypeCamel)
            ?? nested?.blockType
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? nested?.status
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
            ?? c.decodeIfPresent(String.self, forKey: .expiresAtCamel)
            ?? nested?.expiresAt
        remainingSeconds = c.decodeLossyIntIfPresent(forKey: .remainingSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .remainingSecondsCamel)
            ?? nested?.remainingSeconds
        peerIMUID = try c.decodeIfPresent(String.self, forKey: .peerIMUID)
            ?? c.decodeIfPresent(String.self, forKey: .peerIMUIDCamel)
            ?? nested?.peerIMUID
        peerUserID = try c.decodeIfPresent(String.self, forKey: .peerUserID)
            ?? c.decodeIfPresent(String.self, forKey: .peerUserIDCamel)
            ?? nested?.peerUserID
        targetUID = try c.decodeIfPresent(String.self, forKey: .targetUID)
            ?? c.decodeIfPresent(String.self, forKey: .targetUIDCamel)
            ?? nested?.targetUID
        canApplyFriend = c.decodeLossyBoolIfPresent(forKey: .canApplyFriend)
            ?? c.decodeLossyBoolIfPresent(forKey: .canApplyFriendCamel)
            ?? nested?.canApplyFriend
        friendRequestStatus = try c.decodeIfPresent(String.self, forKey: .friendRequestStatus)
            ?? c.decodeIfPresent(String.self, forKey: .friendRequestStatusCamel)
            ?? c.decodeIfPresent(String.self, forKey: .relationStatus)
            ?? c.decodeIfPresent(String.self, forKey: .relationStatusCamel)
            ?? nested?.friendRequestStatus
        friendAction = try c.decodeIfPresent(String.self, forKey: .friendAction)
            ?? c.decodeIfPresent(String.self, forKey: .friendActionCamel)
            ?? nested?.friendAction
        friendFlow = try c.decodeIfPresent(String.self, forKey: .friendFlow)
            ?? c.decodeIfPresent(String.self, forKey: .friendFlowCamel)
            ?? nested?.friendFlow
    }
}

struct RemoteAppBootstrap: Codable, Equatable {
    struct Directory: Codable, Equatable {
        let apiBaseURL: String
        let endpoints: [String]
        let fallbackDomains: [String]
        let status: String

        enum CodingKeys: String, CodingKey {
            case apiBaseURL = "api_base_url"
            case apiBaseURLCamel = "apiBaseUrl"
            case endpoints
            case fallbackDomains = "fallback_domains"
            case fallbackDomainsCamel = "fallbackDomains"
            case status
        }

        init(apiBaseURL: String = "", endpoints: [String] = [], fallbackDomains: [String] = [], status: String = "") {
            self.apiBaseURL = apiBaseURL
            self.endpoints = endpoints
            self.fallbackDomains = fallbackDomains
            self.status = status
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL)
                ?? c.decodeIfPresent(String.self, forKey: .apiBaseURLCamel)
                ?? ""
            endpoints = try c.decodeIfPresent([String].self, forKey: .endpoints) ?? []
            fallbackDomains = try c.decodeIfPresent([String].self, forKey: .fallbackDomains)
                ?? c.decodeIfPresent([String].self, forKey: .fallbackDomainsCamel)
                ?? []
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(apiBaseURL, forKey: .apiBaseURL)
            try c.encode(endpoints, forKey: .endpoints)
            try c.encode(fallbackDomains, forKey: .fallbackDomains)
            try c.encode(status, forKey: .status)
        }
    }

    struct Legal: Codable, Equatable {
        let legalDocsURL: String
        let manifestURL: String

        enum CodingKeys: String, CodingKey {
            case legalDocsURL = "legal_docs_url"
            case legalDocsURLCamel = "legalDocsUrl"
            case manifestURL = "manifest_url"
            case manifestURLCamel = "manifestUrl"
        }

        init(legalDocsURL: String = "", manifestURL: String = "") {
            self.legalDocsURL = legalDocsURL
            self.manifestURL = manifestURL
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            legalDocsURL = try c.decodeIfPresent(String.self, forKey: .legalDocsURL)
                ?? c.decodeIfPresent(String.self, forKey: .legalDocsURLCamel)
                ?? ""
            manifestURL = try c.decodeIfPresent(String.self, forKey: .manifestURL)
                ?? c.decodeIfPresent(String.self, forKey: .manifestURLCamel)
                ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(legalDocsURL, forKey: .legalDocsURL)
            try c.encode(manifestURL, forKey: .manifestURL)
        }
    }

    let appID: String
    let displayName: String
    let platform: String
    let status: String
    let domains: [String]
    let bootstrapHost: String
    let appDomain: String
    let configVersion: String
    let ttlSeconds: Int
    let directory: Directory
    let legal: Legal
    let configHash: String
	let contractVersion: Int
	let routeRevision: UInt64
	let routeSource: String
	let routeStatus: String
	let routes: [String: IMRuntimeRouteEndpointSet]
	let preferredEndpoints: [String: [String]]
	let routingPolicy: IMRuntimeRoutePolicy
    var environment: String? = nil
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var publicationStatus: String? = nil
    var keysetRevision: UInt64? = nil
    let accessDiagnosticsOverlayEnabled: Bool
    let phoneAuthEnabled: Bool
    let registrationEnabled: Bool
    let enterpriseCodeFirst: Bool
    let preferredEnterpriseCode: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case platform
        case status
        case domains
        case bootstrapHost = "bootstrap_host"
        case bootstrapHostCamel = "bootstrapHost"
        case appDomain = "app_domain"
        case appDomainCamel = "appDomain"
        case configVersion = "config_version"
        case configVersionCamel = "configVersion"
        case ttlSeconds = "ttl_seconds"
        case ttlSecondsCamel = "ttlSeconds"
        case directory
        case legal
        case configHash = "config_hash"
        case configHashCamel = "configHash"
		case contractVersion = "contract_version"
		case revision
		case routeRevision = "route_revision"
		case routeSource = "route_source"
		case routeStatus = "route_status"
		case routes
		case preferredEndpoints = "preferred_endpoints"
		case routingPolicy = "routing_policy"
        case environment
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case publicationStatus = "publication_status"
        case keysetRevision = "keyset_revision"
        case accessDiagnosticsOverlayEnabled = "access_diagnostics_overlay_enabled"
        case accessDiagnosticsOverlayEnabledCamel = "accessDiagnosticsOverlayEnabled"
        case debugFeatures = "debug_features"
        case debugFeaturesCamel = "debugFeatures"
        case phoneAuthEnabled = "phone_auth_enabled"
        case phoneAuthEnabledCamel = "phoneAuthEnabled"
        case registrationEnabled = "registration_enabled"
        case registrationEnabledCamel = "registrationEnabled"
        case openRegistration = "open_registration"
        case openRegistrationCamel = "openRegistration"
        case enterpriseCodeFirst = "enterprise_code_first"
        case enterpriseCodeFirstCamel = "enterpriseCodeFirst"
        case preferEnterpriseCode = "prefer_enterprise_code"
        case preferEnterpriseCodeCamel = "preferEnterpriseCode"
        case preferredEnterpriseCode = "preferred_enterprise_code"
        case preferredEnterpriseCodeCamel = "preferredEnterpriseCode"
        case policy
        case appPolicy = "app_policy"
        case appPolicyCamel = "appPolicy"
        case authPolicy = "auth_policy"
        case authPolicyCamel = "authPolicy"
        case registerPolicy = "register_policy"
        case registerPolicyCamel = "registerPolicy"
        case loginPolicy = "login_policy"
        case loginPolicyCamel = "loginPolicy"
        case tenantPool = "tenant_pool"
        case tenantPoolCamel = "tenantPool"
    }

    enum DebugFeaturesCodingKeys: String, CodingKey {
        case accessDiagnosticsOverlayEnabled = "access_diagnostics_overlay_enabled"
        case accessDiagnosticsOverlayEnabledCamel = "accessDiagnosticsOverlayEnabled"
    }

    enum AppAuthPolicyCodingKeys: String, CodingKey {
        case phoneAuthEnabled = "phone_auth_enabled"
        case phoneAuthEnabledCamel = "phoneAuthEnabled"
        case registrationEnabled = "registration_enabled"
        case registrationEnabledCamel = "registrationEnabled"
        case openRegistration = "open_registration"
        case openRegistrationCamel = "openRegistration"
        case registrationOpen = "registration_open"
        case registrationOpenCamel = "registrationOpen"
        case enabled
        case enterpriseCodeFirst = "enterprise_code_first"
        case enterpriseCodeFirstCamel = "enterpriseCodeFirst"
        case preferEnterpriseCode = "prefer_enterprise_code"
        case preferEnterpriseCodeCamel = "preferEnterpriseCode"
    }

    init(
        appID: String,
        displayName: String = "",
        platform: String = "",
        status: String = "",
        domains: [String] = [],
        bootstrapHost: String = "",
        appDomain: String = "",
        configVersion: String = "",
        ttlSeconds: Int = 300,
        directory: Directory = Directory(),
        legal: Legal = Legal(),
        configHash: String = "",
		contractVersion: Int = 0,
		routeRevision: UInt64 = 0,
		routeSource: String = "",
		routeStatus: String = "",
		routes: [String: IMRuntimeRouteEndpointSet] = [:],
		preferredEndpoints: [String: [String]] = [:],
		routingPolicy: IMRuntimeRoutePolicy = .init(),
        environment: String? = nil,
        publicationID: String? = nil,
        publicationRevision: UInt64? = nil,
        profileFingerprint: String? = nil,
        lifetimeMode: IMSessionLifetimeMode? = nil,
        publicationStatus: String? = nil,
        keysetRevision: UInt64? = nil,
        accessDiagnosticsOverlayEnabled: Bool = false,
        phoneAuthEnabled: Bool = true,
        registrationEnabled: Bool = true,
        enterpriseCodeFirst: Bool = false,
        preferredEnterpriseCode: String = ""
    ) {
        self.appID = appID
        self.displayName = displayName
        self.platform = platform
        self.status = status
        self.domains = domains
        self.bootstrapHost = bootstrapHost
        self.appDomain = appDomain
        self.configVersion = configVersion
        self.ttlSeconds = ttlSeconds
        self.directory = directory
        self.legal = legal
        self.configHash = configHash
		self.contractVersion = contractVersion
		self.routeRevision = routeRevision
		self.routeSource = routeSource
		self.routeStatus = routeStatus
		self.routes = routes
		self.preferredEndpoints = preferredEndpoints
		self.routingPolicy = routingPolicy
        self.environment = environment
        self.publicationID = publicationID
        self.publicationRevision = publicationRevision
        self.profileFingerprint = profileFingerprint
        self.lifetimeMode = lifetimeMode
        self.publicationStatus = publicationStatus
        self.keysetRevision = keysetRevision
        self.accessDiagnosticsOverlayEnabled = accessDiagnosticsOverlayEnabled
        self.phoneAuthEnabled = phoneAuthEnabled
        self.registrationEnabled = registrationEnabled
        self.enterpriseCodeFirst = enterpriseCodeFirst
        self.preferredEnterpriseCode = preferredEnterpriseCode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let policyRoot = (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .policy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .appPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .appPolicyCamel))
        let policySources = [policyRoot, c].compactMap { $0 }
        func firstConfiguredPolicyBool(_ keys: [CodingKeys]) -> Bool? {
            for source in policySources {
                for key in keys where source.contains(key) {
                    return source.decodeLossyBoolIfPresent(forKey: key) ?? false
                }
            }
            return nil
        }
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        bootstrapHost = try c.decodeIfPresent(String.self, forKey: .bootstrapHost)
            ?? c.decodeIfPresent(String.self, forKey: .bootstrapHostCamel)
            ?? ""
        appDomain = try c.decodeIfPresent(String.self, forKey: .appDomain)
            ?? c.decodeIfPresent(String.self, forKey: .appDomainCamel)
            ?? ""
        configVersion = try c.decodeIfPresent(String.self, forKey: .configVersion)
            ?? c.decodeIfPresent(String.self, forKey: .configVersionCamel)
            ?? ""
        ttlSeconds = c.decodeLossyIntIfPresent(forKey: .ttlSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .ttlSecondsCamel)
            ?? 300
        directory = try c.decodeIfPresent(Directory.self, forKey: .directory) ?? Directory()
        legal = try c.decodeIfPresent(Legal.self, forKey: .legal) ?? Legal()
        configHash = try c.decodeIfPresent(String.self, forKey: .configHash)
            ?? c.decodeIfPresent(String.self, forKey: .configHashCamel)
            ?? ""
		contractVersion = try c.decodeIfPresent(Int.self, forKey: .contractVersion) ?? 0
		routeRevision = try c.decodeIfPresent(UInt64.self, forKey: .revision)
			?? c.decodeIfPresent(UInt64.self, forKey: .routeRevision) ?? 0
		routeSource = try c.decodeIfPresent(String.self, forKey: .routeSource) ?? ""
		routeStatus = try c.decodeIfPresent(String.self, forKey: .routeStatus) ?? ""
		routes = try c.decodeIfPresent([String: IMRuntimeRouteEndpointSet].self, forKey: .routes) ?? [:]
		preferredEndpoints = try c.decodeIfPresent([String: [String]].self, forKey: .preferredEndpoints) ?? [:]
		routingPolicy = try c.decodeIfPresent(IMRuntimeRoutePolicy.self, forKey: .routingPolicy) ?? .init(contractVersion: 0)
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        publicationID = try c.decodeIfPresent(String.self, forKey: .publicationID)
        publicationRevision = try c.decodeIfPresent(UInt64.self, forKey: .publicationRevision)
        profileFingerprint = try c.decodeIfPresent(String.self, forKey: .profileFingerprint)
        lifetimeMode = .authoritativeValue(try c.decodeIfPresent(String.self, forKey: .lifetimeMode))
        if !c.contains(.lifetimeMode) { lifetimeMode = nil }
        publicationStatus = try c.decodeIfPresent(String.self, forKey: .publicationStatus)
            ?? (publicationID == nil ? nil : status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        keysetRevision = try c.decodeIfPresent(UInt64.self, forKey: .keysetRevision)
        let debugFeatures = try? c.nestedContainer(keyedBy: DebugFeaturesCodingKeys.self, forKey: .debugFeatures)
        let debugFeaturesCamel = try? c.nestedContainer(keyedBy: DebugFeaturesCodingKeys.self, forKey: .debugFeaturesCamel)
        accessDiagnosticsOverlayEnabled = c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
            ?? debugFeaturesCamel?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? debugFeaturesCamel?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
            ?? false
        let primary = policyRoot ?? c
        let authPolicy = (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .authPolicy))
            ?? (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .authPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .authPolicy))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .authPolicyCamel))
        let registerPolicy = (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .registerPolicy))
            ?? (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .registerPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .registerPolicy))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .registerPolicyCamel))
        let loginPolicy = (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .loginPolicy))
            ?? (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .loginPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .loginPolicy))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .loginPolicyCamel))
        let tenantPool = (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .tenantPool))
            ?? (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .tenantPoolCamel))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .tenantPool))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .tenantPoolCamel))
        let nestedPolicySources = [authPolicy, registerPolicy, loginPolicy, tenantPool].compactMap { $0 }
        func firstNestedConfiguredPolicyBool(_ keys: [AppAuthPolicyCodingKeys]) -> Bool? {
            for source in nestedPolicySources {
                for key in keys where source.contains(key) {
                    return source.decodeLossyBoolIfPresent(forKey: key) ?? false
                }
            }
            return nil
        }
        phoneAuthEnabled = policyRoot?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? policyRoot?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? authPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? authPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? registerPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? registerPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? loginPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? loginPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? tenantPool?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? tenantPool?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? true
        registrationEnabled = firstConfiguredPolicyBool([
            .registrationEnabled, .registrationEnabledCamel, .openRegistration, .openRegistrationCamel
        ])
            ?? firstNestedConfiguredPolicyBool([
                .registrationEnabled, .registrationEnabledCamel, .openRegistration, .openRegistrationCamel
            ])
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .enabled)
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .registrationOpen)
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .registrationOpenCamel)
            ?? true
        enterpriseCodeFirst = firstConfiguredPolicyBool([
            .enterpriseCodeFirst, .enterpriseCodeFirstCamel, .preferEnterpriseCode, .preferEnterpriseCodeCamel
        ])
            ?? firstNestedConfiguredPolicyBool([
                .enterpriseCodeFirst, .enterpriseCodeFirstCamel, .preferEnterpriseCode, .preferEnterpriseCodeCamel
            ])
            ?? false
        let rawPreferred = try c.decodeIfPresent(String.self, forKey: .preferredEnterpriseCode)
            ?? c.decodeIfPresent(String.self, forKey: .preferredEnterpriseCodeCamel)
            ?? ""
        preferredEnterpriseCode = Self.validPreferredEnterpriseCode(
            rawPreferred,
            appID: appID,
            enterpriseCodeFirst: enterpriseCodeFirst
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appID, forKey: .appID)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(platform, forKey: .platform)
        try c.encode(status, forKey: .status)
        try c.encode(domains, forKey: .domains)
        try c.encode(bootstrapHost, forKey: .bootstrapHost)
        try c.encode(appDomain, forKey: .appDomain)
        try c.encode(configVersion, forKey: .configVersion)
        try c.encode(ttlSeconds, forKey: .ttlSeconds)
        try c.encode(directory, forKey: .directory)
        try c.encode(legal, forKey: .legal)
        try c.encode(configHash, forKey: .configHash)
		try c.encode(contractVersion, forKey: .contractVersion)
		try c.encode(routeRevision, forKey: .revision)
		try c.encode(routeSource, forKey: .routeSource)
		try c.encode(routeStatus, forKey: .routeStatus)
		try c.encode(routes, forKey: .routes)
		try c.encode(preferredEndpoints, forKey: .preferredEndpoints)
		try c.encode(routingPolicy, forKey: .routingPolicy)
        try c.encodeIfPresent(environment, forKey: .environment)
        try c.encodeIfPresent(publicationID, forKey: .publicationID)
        try c.encodeIfPresent(publicationRevision, forKey: .publicationRevision)
        try c.encodeIfPresent(profileFingerprint, forKey: .profileFingerprint)
        try c.encodeIfPresent(lifetimeMode, forKey: .lifetimeMode)
        try c.encodeIfPresent(publicationStatus, forKey: .publicationStatus)
        try c.encodeIfPresent(keysetRevision, forKey: .keysetRevision)
        try c.encode(accessDiagnosticsOverlayEnabled, forKey: .accessDiagnosticsOverlayEnabled)
        try c.encode(phoneAuthEnabled, forKey: .phoneAuthEnabled)
        try c.encode(registrationEnabled, forKey: .registrationEnabled)
        try c.encode(enterpriseCodeFirst, forKey: .enterpriseCodeFirst)
        if !preferredEnterpriseCode.isEmpty {
            try c.encode(preferredEnterpriseCode, forKey: .preferredEnterpriseCode)
        }
    }

    var normalizedAppID: String {
        IMAPIContext.normalizedIOSAppID(appID)
    }

    var normalizedConfigVersion: String {
        configVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validPreferredEnterpriseCode(_ rawValue: String, appID: String, enterpriseCodeFirst: Bool) -> String {
        guard enterpriseCodeFirst else { return "" }
        let exactAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedAppIDs = Set([IMAPIContext.canonicalIOSAppID, "jht-ios-main", "ios-main"])
        guard allowedAppIDs.contains(exactAppID) else { return "" }
        guard let entry = RegistrationFlowPolicy.normalizedEntryCode(rawValue),
              entry.kind == .enterprise else { return "" }
        return entry.normalizedValue
    }
}

enum AccessDiagnosticsOverlayConfiguration: String, Codable, Equatable {
    case unavailable
    case disabled
    case enabled

    init(configuredValue: Bool?, fieldWasPresent: Bool) {
        if let configuredValue {
            self = configuredValue ? .enabled : .disabled
        } else {
            self = fieldWasPresent ? .disabled : .unavailable
        }
    }

    var isEnabled: Bool { self == .enabled }

    var displayText: String {
        switch self {
        case .unavailable: return "配置未获取"
        case .disabled: return "已关闭"
        case .enabled: return "已启用"
        }
    }
}

struct RemoteAppCurrentPolicy: Codable, Equatable {
    let appID: String
    let platform: String
    let status: String
    let allowWorkspaceSwitch: Bool
    let allowDefaultTenantJoin: Bool
    let requireRealName: Bool
    let requirePhoneVerification: Bool
    let phoneAuthEnabled: Bool
    let registrationEnabled: Bool
    let enterpriseCodeFirst: Bool
    let preferredEnterpriseCode: String
    let supportContactEmail: String
    let supportContactConfigured: Bool
    let departmentEnabled: Bool
    let accessDiagnosticsOverlayConfiguration: AccessDiagnosticsOverlayConfiguration
    let accessDiagnosticsCopyEnabled: Bool
    let cacheTTLSeconds: Int

    var accessDiagnosticsOverlayEnabled: Bool {
        accessDiagnosticsOverlayConfiguration.isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case platform
        case status
        case allowWorkspaceSwitch = "allow_workspace_switch"
        case allowWorkspaceSwitchCamel = "allowWorkspaceSwitch"
        case allowDefaultTenantJoin = "allow_default_tenant_join"
        case allowDefaultTenantJoinCamel = "allowDefaultTenantJoin"
        case requireRealName = "require_real_name"
        case requireRealNameCamel = "requireRealName"
        case requirePhoneVerification = "require_phone_verification"
        case requirePhoneVerificationCamel = "requirePhoneVerification"
        case phoneAuthEnabled = "phone_auth_enabled"
        case phoneAuthEnabledCamel = "phoneAuthEnabled"
        case registrationEnabled = "registration_enabled"
        case registrationEnabledCamel = "registrationEnabled"
        case openRegistration = "open_registration"
        case openRegistrationCamel = "openRegistration"
        case registrationOpen = "registration_open"
        case registrationOpenCamel = "registrationOpen"
        case enabled
        case enterpriseCodeFirst = "enterprise_code_first"
        case enterpriseCodeFirstCamel = "enterpriseCodeFirst"
        case preferEnterpriseCode = "prefer_enterprise_code"
        case preferEnterpriseCodeCamel = "preferEnterpriseCode"
        case preferredEnterpriseCode = "preferred_enterprise_code"
        case preferredEnterpriseCodeCamel = "preferredEnterpriseCode"
        case policy
        case appPolicy = "app_policy"
        case appPolicyCamel = "appPolicy"
        case authPolicy = "auth_policy"
        case authPolicyCamel = "authPolicy"
        case registerPolicy = "register_policy"
        case registerPolicyCamel = "registerPolicy"
        case loginPolicy = "login_policy"
        case loginPolicyCamel = "loginPolicy"
        case tenantPool = "tenant_pool"
        case tenantPoolCamel = "tenantPool"
        case supportContactEmail = "support_contact_email"
        case supportContactEmailCamel = "supportContactEmail"
        case supportContactConfigured = "support_contact_configured"
        case supportContactConfiguredCamel = "supportContactConfigured"
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
        case accessDiagnosticsOverlayEnabled = "access_diagnostics_overlay_enabled"
        case accessDiagnosticsOverlayEnabledCamel = "accessDiagnosticsOverlayEnabled"
        case accessDiagnosticsCopyEnabled = "access_diagnostics_copy_enabled"
        case accessDiagnosticsCopyEnabledCamel = "accessDiagnosticsCopyEnabled"
        case debugFeatures = "debug_features"
        case debugFeaturesCamel = "debugFeatures"
        case organization
        case cacheTTLSeconds = "cache_ttl_seconds"
        case cacheTTLSecondsCamel = "cacheTtlSeconds"
        case cacheTTLSecondsUpperCamel = "cacheTTLSeconds"
    }

    enum OrganizationCodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
    }

    enum DebugFeaturesCodingKeys: String, CodingKey {
        case accessDiagnosticsOverlayEnabled = "access_diagnostics_overlay_enabled"
        case accessDiagnosticsOverlayEnabledCamel = "accessDiagnosticsOverlayEnabled"
        case accessDiagnosticsCopyEnabled = "access_diagnostics_copy_enabled"
        case accessDiagnosticsCopyEnabledCamel = "accessDiagnosticsCopyEnabled"
    }

    init(
        appID: String,
        platform: String = "",
        status: String,
        allowWorkspaceSwitch: Bool,
        allowDefaultTenantJoin: Bool,
        requireRealName: Bool = false,
        requirePhoneVerification: Bool = false,
        phoneAuthEnabled: Bool = true,
        registrationEnabled: Bool = true,
        enterpriseCodeFirst: Bool = false,
        preferredEnterpriseCode: String = "",
        supportContactEmail: String = "",
        supportContactConfigured: Bool = false,
        departmentEnabled: Bool = false,
        accessDiagnosticsOverlayConfiguration: AccessDiagnosticsOverlayConfiguration? = nil,
        accessDiagnosticsOverlayEnabled: Bool? = nil,
        accessDiagnosticsCopyEnabled: Bool = false,
        cacheTTLSeconds: Int
    ) {
        self.appID = appID
        self.platform = platform
        self.status = status
        self.allowWorkspaceSwitch = allowWorkspaceSwitch
        self.allowDefaultTenantJoin = allowDefaultTenantJoin
        self.requireRealName = requireRealName
        self.requirePhoneVerification = requirePhoneVerification
        self.phoneAuthEnabled = phoneAuthEnabled
        self.registrationEnabled = registrationEnabled
        self.enterpriseCodeFirst = enterpriseCodeFirst
        self.preferredEnterpriseCode = RemoteAppBootstrap.validPreferredEnterpriseCode(
            preferredEnterpriseCode,
            appID: appID,
            enterpriseCodeFirst: enterpriseCodeFirst
        )
        self.supportContactEmail = supportContactEmail
        self.supportContactConfigured = supportContactConfigured
        self.departmentEnabled = departmentEnabled
        self.accessDiagnosticsOverlayConfiguration = accessDiagnosticsOverlayConfiguration
            ?? AccessDiagnosticsOverlayConfiguration(
                configuredValue: accessDiagnosticsOverlayEnabled,
                fieldWasPresent: accessDiagnosticsOverlayEnabled != nil
            )
        self.accessDiagnosticsCopyEnabled = accessDiagnosticsCopyEnabled
        self.cacheTTLSeconds = cacheTTLSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let policyRoot = (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .policy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .appPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .appPolicyCamel))
        let primary = policyRoot ?? c
        let authPolicy = (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .authPolicy))
            ?? (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .authPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .authPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .authPolicyCamel))
        let registerPolicy = (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .registerPolicy))
            ?? (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .registerPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .registerPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .registerPolicyCamel))
        let loginPolicy = (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .loginPolicy))
            ?? (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .loginPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .loginPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .loginPolicyCamel))
        let tenantPool = (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .tenantPool))
            ?? (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .tenantPoolCamel))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .tenantPool))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .tenantPoolCamel))
        let sources = [primary, c] + [authPolicy, registerPolicy, loginPolicy, tenantPool].compactMap { $0 }
        func firstBool(_ keys: [CodingKeys]) -> Bool? {
            for source in sources {
                for key in keys {
                    if let value = source.decodeLossyBoolIfPresent(forKey: key) { return value }
                }
            }
            return nil
        }
        func firstConfiguredBool(
            _ configuredSources: [KeyedDecodingContainer<CodingKeys>],
            keys: [CodingKeys]
        ) -> Bool? {
            for source in configuredSources {
                for key in keys where source.contains(key) {
                    return source.decodeLossyBoolIfPresent(forKey: key) ?? false
                }
            }
            return nil
        }
        func firstString(_ keys: [CodingKeys]) -> String? {
            for source in sources {
                for key in keys {
                    do {
                        if let value = try source.decodeIfPresent(String.self, forKey: key) { return value }
                    } catch {
                        continue
                    }
                }
            }
            return nil
        }
        let rootAppID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
        appID = firstString([.appID, .appIDCamel]) ?? rootAppID ?? ""
        platform = firstString([.platform]) ?? ""
        status = firstString([.status]) ?? ""
        allowWorkspaceSwitch = firstBool([.allowWorkspaceSwitch, .allowWorkspaceSwitchCamel]) ?? false
        allowDefaultTenantJoin = firstConfiguredBool(
            sources,
            keys: [.allowDefaultTenantJoin, .allowDefaultTenantJoinCamel]
        ) ?? true
        requireRealName = firstBool([.requireRealName, .requireRealNameCamel])
            ?? false
        requirePhoneVerification = firstBool([.requirePhoneVerification, .requirePhoneVerificationCamel])
            ?? false
        phoneAuthEnabled = firstBool([.phoneAuthEnabled, .phoneAuthEnabledCamel]) ?? true
        registrationEnabled = firstConfiguredBool(sources, keys: [
            .registrationEnabled, .registrationEnabledCamel, .openRegistration, .openRegistrationCamel
        ])
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .enabled)
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .registrationOpen)
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .registrationOpenCamel)
            ?? true
        enterpriseCodeFirst = firstConfiguredBool(sources, keys: [
            .enterpriseCodeFirst, .enterpriseCodeFirstCamel, .preferEnterpriseCode, .preferEnterpriseCodeCamel
        ]) ?? false
        let rawPreferred = try c.decodeIfPresent(String.self, forKey: .preferredEnterpriseCode)
            ?? c.decodeIfPresent(String.self, forKey: .preferredEnterpriseCodeCamel)
            ?? ""
        preferredEnterpriseCode = RemoteAppBootstrap.validPreferredEnterpriseCode(
            rawPreferred,
            appID: appID,
            enterpriseCodeFirst: enterpriseCodeFirst
        )
        supportContactEmail = firstString([.supportContactEmail, .supportContactEmailCamel]) ?? ""
        supportContactConfigured = firstBool([.supportContactConfigured, .supportContactConfiguredCamel]) ?? false
        let organization = try? c.nestedContainer(keyedBy: OrganizationCodingKeys.self, forKey: .organization)
        departmentEnabled = c.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? organization?.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? organization?.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? false
        let debugFeatures = (try? c.nestedContainer(keyedBy: DebugFeaturesCodingKeys.self, forKey: .debugFeatures))
            ?? (try? c.nestedContainer(keyedBy: DebugFeaturesCodingKeys.self, forKey: .debugFeaturesCamel))
        let accessDiagnosticsOverlayFieldWasPresent = c.contains(.accessDiagnosticsOverlayEnabled)
            || c.contains(.accessDiagnosticsOverlayEnabledCamel)
            || debugFeatures?.contains(.accessDiagnosticsOverlayEnabled) == true
            || debugFeatures?.contains(.accessDiagnosticsOverlayEnabledCamel) == true
        let accessDiagnosticsOverlayValue = c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
        accessDiagnosticsOverlayConfiguration = AccessDiagnosticsOverlayConfiguration(
            configuredValue: accessDiagnosticsOverlayValue,
            fieldWasPresent: accessDiagnosticsOverlayFieldWasPresent
        )
        accessDiagnosticsCopyEnabled = c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsCopyEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsCopyEnabledCamel)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsCopyEnabled)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsCopyEnabledCamel)
            ?? false
        cacheTTLSeconds = c.decodeLossyIntIfPresent(forKey: .cacheTTLSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .cacheTTLSecondsCamel)
            ?? c.decodeLossyIntIfPresent(forKey: .cacheTTLSecondsUpperCamel)
            ?? 60
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appID, forKey: .appID)
        try c.encode(platform, forKey: .platform)
        try c.encode(status, forKey: .status)
        try c.encode(allowWorkspaceSwitch, forKey: .allowWorkspaceSwitch)
        try c.encode(allowDefaultTenantJoin, forKey: .allowDefaultTenantJoin)
        try c.encode(requireRealName, forKey: .requireRealName)
        try c.encode(requirePhoneVerification, forKey: .requirePhoneVerification)
        try c.encode(phoneAuthEnabled, forKey: .phoneAuthEnabled)
        try c.encode(registrationEnabled, forKey: .registrationEnabled)
        try c.encode(enterpriseCodeFirst, forKey: .enterpriseCodeFirst)
        if !preferredEnterpriseCode.isEmpty {
            try c.encode(preferredEnterpriseCode, forKey: .preferredEnterpriseCode)
        }
        try c.encode(supportContactEmail, forKey: .supportContactEmail)
        try c.encode(supportContactConfigured, forKey: .supportContactConfigured)
        try c.encode(departmentEnabled, forKey: .departmentEnabled)
        if accessDiagnosticsOverlayConfiguration != .unavailable {
            try c.encode(accessDiagnosticsOverlayEnabled, forKey: .accessDiagnosticsOverlayEnabled)
        }
        try c.encode(accessDiagnosticsCopyEnabled, forKey: .accessDiagnosticsCopyEnabled)
        try c.encode(cacheTTLSeconds, forKey: .cacheTTLSeconds)
    }

    var isUsable: Bool {
        let normalizedStatus = status
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        return ["active", "enabled", "normal", "available", "usable"].contains(normalizedStatus)
    }

    func settingPhoneAuthEnabled(_ enabled: Bool) -> RemoteAppCurrentPolicy {
        RemoteAppCurrentPolicy(
            appID: appID,
            platform: platform,
            status: status,
            allowWorkspaceSwitch: allowWorkspaceSwitch,
            allowDefaultTenantJoin: allowDefaultTenantJoin,
            requireRealName: requireRealName,
            requirePhoneVerification: requirePhoneVerification,
            phoneAuthEnabled: enabled,
            registrationEnabled: registrationEnabled,
            enterpriseCodeFirst: enterpriseCodeFirst,
            preferredEnterpriseCode: preferredEnterpriseCode,
            supportContactEmail: supportContactEmail,
            supportContactConfigured: supportContactConfigured,
            departmentEnabled: departmentEnabled,
            accessDiagnosticsOverlayConfiguration: accessDiagnosticsOverlayConfiguration,
            accessDiagnosticsCopyEnabled: accessDiagnosticsCopyEnabled,
            cacheTTLSeconds: cacheTTLSeconds
        )
    }

    func settingStartupPolicyHints(from bootstrap: RemoteAppBootstrap) -> RemoteAppCurrentPolicy {
        let sameApp = IMAPIContext.normalizedIOSAppID(bootstrap.appID) == IMAPIContext.normalizedIOSAppID(appID)
        return RemoteAppCurrentPolicy(
            appID: appID,
            platform: platform,
            status: status,
            allowWorkspaceSwitch: allowWorkspaceSwitch,
            allowDefaultTenantJoin: allowDefaultTenantJoin,
            requireRealName: requireRealName,
            requirePhoneVerification: requirePhoneVerification,
            phoneAuthEnabled: phoneAuthEnabled,
            registrationEnabled: bootstrap.registrationEnabled,
            enterpriseCodeFirst: bootstrap.enterpriseCodeFirst,
            preferredEnterpriseCode: sameApp && bootstrap.enterpriseCodeFirst ? bootstrap.preferredEnterpriseCode : "",
            supportContactEmail: supportContactEmail,
            supportContactConfigured: supportContactConfigured,
            departmentEnabled: departmentEnabled,
            accessDiagnosticsOverlayConfiguration: accessDiagnosticsOverlayConfiguration,
            accessDiagnosticsCopyEnabled: accessDiagnosticsCopyEnabled,
            cacheTTLSeconds: cacheTTLSeconds
        )
    }
}

enum LegalDocumentType: String, CaseIterable, Identifiable {
    case terms
    case privacy

    var id: String { rawValue }

    var fixedWebURL: URL {
        switch self {
        case .terms:
            return URL(string: "https://wdatong.cn/ios_yonghu.html")!
        case .privacy:
            return URL(string: "https://wdatong.cn/ios_yinsi.html")!
        }
    }

    var title: String {
        switch self {
        case .terms:
            return "用户协议"
        case .privacy:
            return "隐私政策"
        }
    }

    var symbol: String {
        switch self {
        case .terms:
            return "doc.text.fill"
        case .privacy:
            return "hand.raised.fill"
        }
    }

    func matches(_ rawValue: String) -> Bool {
        let normalized = Self.normalized(rawValue)
        switch self {
        case .terms:
            return ["terms", "user_terms", "user_agreement", "agreement", "service_terms"].contains(normalized)
        case .privacy:
            return ["privacy", "privacy_policy", "policy"].contains(normalized)
        }
    }

    static func normalized(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }
}

struct RemoteLegalDocManifest: Decodable, Equatable {
    let appID: String
    let manifestRevision: Int64
    let manifestHash: String
    let updatedAt: String
    let docs: [RemoteLegalDoc]

    init(
        appID: String,
        manifestRevision: Int64 = 0,
        manifestHash: String = "",
        updatedAt: String = "",
        docs: [RemoteLegalDoc]
    ) {
        self.appID = appID
        self.manifestRevision = manifestRevision
        self.manifestHash = manifestHash
        self.updatedAt = updatedAt
        self.docs = docs
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case manifestRevision = "manifest_revision"
        case manifestRevisionCamel = "manifestRevision"
        case manifestHash = "manifest_hash"
        case manifestHashCamel = "manifestHash"
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
        case docs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        manifestRevision = c.decodeLossyInt64IfPresent(forKey: .manifestRevision)
            ?? c.decodeLossyInt64IfPresent(forKey: .manifestRevisionCamel)
            ?? 0
        manifestHash = try c.decodeIfPresent(String.self, forKey: .manifestHash)
            ?? c.decodeIfPresent(String.self, forKey: .manifestHashCamel)
            ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel)
            ?? ""
        docs = try c.decodeIfPresent([RemoteLegalDoc].self, forKey: .docs) ?? []
    }

    func document(type: LegalDocumentType) -> RemoteLegalDoc? {
        docs.first { type.matches($0.docType) }
    }
}

struct RemoteLegalDoc: Decodable, Equatable {
    let docType: String
    let version: Int64
    let title: String
    let downloadURL: String
    let downloadExpiresAt: String
    let mimeType: String
    let sizeBytes: Int64
    let checksum: String

    init(
        docType: String,
        version: Int64 = 0,
        title: String,
        downloadURL: String,
        downloadExpiresAt: String = "",
        mimeType: String = "text/html",
        sizeBytes: Int64 = 0,
        checksum: String = ""
    ) {
        self.docType = docType
        self.version = version
        self.title = title
        self.downloadURL = downloadURL
        self.downloadExpiresAt = downloadExpiresAt
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.checksum = checksum
    }

    enum CodingKeys: String, CodingKey {
        case docType = "doc_type"
        case docTypeCamel = "docType"
        case version
        case title
        case downloadURL = "download_url"
        case downloadURLCamel = "downloadUrl"
        case downloadURLUpperCamel = "downloadURL"
        case downloadExpiresAt = "download_expires_at"
        case downloadExpiresAtCamel = "downloadExpiresAt"
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case sizeBytes = "size_bytes"
        case sizeBytesCamel = "sizeBytes"
        case checksum
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDocType = try c.decodeIfPresent(String.self, forKey: .docType)
            ?? c.decodeIfPresent(String.self, forKey: .docTypeCamel)
            ?? ""
        docType = decodedDocType
        version = c.decodeLossyInt64IfPresent(forKey: .version) ?? 0
        let defaultTitle = LegalDocumentType.allCases.first { $0.matches(decodedDocType) }?.title ?? "协议内容"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? defaultTitle
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadURLCamel)
            ?? c.decodeIfPresent(String.self, forKey: .downloadURLUpperCamel)
            ?? ""
        downloadExpiresAt = try c.decodeIfPresent(String.self, forKey: .downloadExpiresAt)
            ?? c.decodeIfPresent(String.self, forKey: .downloadExpiresAtCamel)
            ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            ?? c.decodeIfPresent(String.self, forKey: .mimeTypeCamel)
            ?? ""
        sizeBytes = c.decodeLossyInt64IfPresent(forKey: .sizeBytes)
            ?? c.decodeLossyInt64IfPresent(forKey: .sizeBytesCamel)
            ?? 0
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum) ?? ""
    }
}

// JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：协议正文由客户端受控 HTTP 拉取后内嵌展示
struct LegalDocumentContent: Equatable {
    let type: LegalDocumentType
    let title: String
    let html: String
    let sourceURL: URL
    let baseURL: URL
    let manifest: RemoteLegalDocManifest

    var displayHTML: String {
        let policy = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        """
        let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty else { return policy }
        if let headRange = trimmedHTML.range(of: "<head", options: [.caseInsensitive]),
           let headEnd = trimmedHTML[headRange.lowerBound...].range(of: ">") {
            var value = trimmedHTML
            value.insert(contentsOf: "\n\(policy)\n", at: headEnd.upperBound)
            return value
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \(policy)
        </head>
        <body>
        \(trimmedHTML)
        </body>
        </html>
        """
    }
}
// JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

struct RemoteLoginSecurityInfo: Decodable, Equatable {
    let surface: String
    let day: String
    let failedAttempts: Int?
    let remainingAttempts: Int?
    let maxAttempts: Int?
    let locked: Bool
    let banUntil: String
    let lockedAccountCount: Int?
    let threshold: Int?

    enum CodingKeys: String, CodingKey {
        case surface
        case day
        case failedAttempts = "failed_attempts"
        case remainingAttempts = "remaining_attempts"
        case maxAttempts = "max_attempts"
        case locked
        case banUntil = "ban_until"
        case lockedAccountCount = "locked_account_count"
        case threshold
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decodeIfPresent(String.self, forKey: .surface) ?? ""
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        failedAttempts = c.decodeLossyIntIfPresent(forKey: .failedAttempts)
        remainingAttempts = c.decodeLossyIntIfPresent(forKey: .remainingAttempts)
        maxAttempts = c.decodeLossyIntIfPresent(forKey: .maxAttempts)
        locked = c.decodeLossyBoolIfPresent(forKey: .locked) ?? false
        banUntil = try c.decodeIfPresent(String.self, forKey: .banUntil) ?? ""
        lockedAccountCount = c.decodeLossyIntIfPresent(forKey: .lockedAccountCount)
        threshold = c.decodeLossyIntIfPresent(forKey: .threshold)
    }
}

struct EmptyPayload: Decodable {}

extension KeyedDecodingContainer {
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
            return value.rounded() == value ? String(Int64(value)) : String(value)
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
            return Int(value)
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
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

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

struct RemoteList<T: Decodable>: Decodable {
    let items: [T]
    let selfMember: T?
    let total: Int?
    let limit: Int?
    let offset: Int?
    let hasMore: Bool?
    let nextOffset: Int?
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case selfMember = "self_member"
        case selfMemberCamel = "selfMember"
        case total
        case totalCount = "total_count"
        case count
        case limit
        case offset
        case hasMore = "has_more"
        case hasMoreCamel = "hasMore"
        case nextOffset = "next_offset"
        case nextOffsetCamel = "nextOffset"
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([T].self, forKey: .items) ?? []
        selfMember = try c.decodeIfPresent(T.self, forKey: .selfMember)
            ?? c.decodeIfPresent(T.self, forKey: .selfMemberCamel)
        total = Self.decodeFlexibleInt(from: c, keys: [.total, .totalCount, .count])
        limit = Self.decodeFlexibleInt(from: c, keys: [.limit])
        offset = Self.decodeFlexibleInt(from: c, keys: [.offset])
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreCamel)
        nextOffset = Self.decodeFlexibleInt(from: c, keys: [.nextOffset, .nextOffsetCamel])
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .nextCursorCamel)
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端消息分页结果标记为可跨任务传递的值快照
struct RemoteMessageSyncResult: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    let items: [RemoteMessage]
    let hasMore: Bool?
    let hasMoreBefore: Bool?
    let hasMoreAfter: Bool?
    let nextAfterSeq: Int64?
    let historyVisibleFromSeq: Int64
    let historyLimited: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case hasMoreCamel = "hasMore"
        case hasMoreBefore = "has_more_before"
        case hasMoreBeforeCamel = "hasMoreBefore"
        case hasMoreAfter = "has_more_after"
        case hasMoreAfterCamel = "hasMoreAfter"
        case nextAfterSeq = "next_after_seq"
        case nextAfterSeqCamel = "nextAfterSeq"
        case historyVisibleFromSeq = "history_visible_from_seq"
        case historyVisibleFromSeqCamel = "historyVisibleFromSeq"
        case historyLimited = "history_limited"
        case historyLimitedCamel = "historyLimited"
    }

    init(
        items: [RemoteMessage],
        hasMore: Bool? = nil,
        hasMoreBefore: Bool? = nil,
        hasMoreAfter: Bool? = nil,
        nextAfterSeq: Int64? = nil,
        historyVisibleFromSeq: Int64 = 1,
        historyLimited: Bool = false
    ) {
        self.items = items
        self.hasMore = hasMore
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.nextAfterSeq = nextAfterSeq
        self.historyVisibleFromSeq = max(1, historyVisibleFromSeq)
        self.historyLimited = historyLimited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteMessage].self, forKey: .items) ?? []
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreCamel)
        hasMoreBefore = c.decodeLossyBoolIfPresent(forKey: .hasMoreBefore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreBeforeCamel)
        hasMoreAfter = c.decodeLossyBoolIfPresent(forKey: .hasMoreAfter)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreAfterCamel)
        nextAfterSeq = c.decodeLossyInt64IfPresent(forKey: .nextAfterSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .nextAfterSeqCamel)
        historyVisibleFromSeq = max(
            1,
            c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeq)
                ?? c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeqCamel)
                ?? 1
        )
        historyLimited = c.decodeLossyBoolIfPresent(forKey: .historyLimited)
            ?? c.decodeLossyBoolIfPresent(forKey: .historyLimitedCamel)
            ?? false
    }
}

struct RemoteTenantDirectoryResult: Decodable {
    let appID: String
    let appScoped: Bool
    let workspaceCount: Int
    let enterableWorkspaceCount: Int
    let selectionMode: String
    let emptyReason: String
    let entryStatus: String
    let pendingEntryTenantID: String
    let pendingApprovalCount: Int
    let requiresWorkspaceSelection: Bool?
    let items: [RemoteTenantMembership]
    let workspaces: [RemoteTenantMembership]

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case appScoped = "app_scoped"
        case appScopedCamel = "appScoped"
        case workspaceCount = "workspace_count"
        case workspaceCountCamel = "workspaceCount"
        case enterableWorkspaceCount = "enterable_workspace_count"
        case enterableWorkspaceCountCamel = "enterableWorkspaceCount"
        case selectionMode = "selection_mode"
        case selectionModeCamel = "selectionMode"
        case emptyReason = "empty_reason"
        case emptyReasonCamel = "emptyReason"
        case entryStatus = "entry_status"
        case entryStatusCamel = "entryStatus"
        case pendingEntryTenantID = "pending_entry_tenant_id"
        case pendingEntryTenantIDCamel = "pendingEntryTenantId"
        case pendingApprovalCount = "pending_approval_count"
        case pendingApprovalCountCamel = "pendingApprovalCount"
        case requiresWorkspaceSelection = "requires_workspace_selection"
        case requiresWorkspaceSelectionCamel = "requiresWorkspaceSelection"
        case items
        case memberships
        case workspaces
        case tenants
    }

    var preferredMemberships: [RemoteTenantMembership] {
        workspaces.isEmpty ? items : workspaces
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        appScoped = c.decodeLossyBoolIfPresent(forKey: .appScoped)
            ?? c.decodeLossyBoolIfPresent(forKey: .appScopedCamel)
            ?? false
        workspaceCount = c.decodeLossyIntIfPresent(forKey: .workspaceCount)
            ?? c.decodeLossyIntIfPresent(forKey: .workspaceCountCamel)
            ?? 0
        enterableWorkspaceCount = c.decodeLossyIntIfPresent(forKey: .enterableWorkspaceCount)
            ?? c.decodeLossyIntIfPresent(forKey: .enterableWorkspaceCountCamel)
            ?? 0
        selectionMode = try c.decodeIfPresent(String.self, forKey: .selectionMode)
            ?? c.decodeIfPresent(String.self, forKey: .selectionModeCamel)
            ?? ""
        emptyReason = try c.decodeIfPresent(String.self, forKey: .emptyReason)
            ?? c.decodeIfPresent(String.self, forKey: .emptyReasonCamel)
            ?? ""
        entryStatus = try c.decodeIfPresent(String.self, forKey: .entryStatus)
            ?? c.decodeIfPresent(String.self, forKey: .entryStatusCamel)
            ?? ""
        pendingEntryTenantID = try c.decodeIfPresent(String.self, forKey: .pendingEntryTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .pendingEntryTenantIDCamel)
            ?? ""
        pendingApprovalCount = c.decodeLossyIntIfPresent(forKey: .pendingApprovalCount)
            ?? c.decodeLossyIntIfPresent(forKey: .pendingApprovalCountCamel)
            ?? 0
        requiresWorkspaceSelection = c.decodeLossyBoolIfPresent(forKey: .requiresWorkspaceSelection)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresWorkspaceSelectionCamel)
        let decodedItems = try c.decodeIfPresent([RemoteTenantMembership].self, forKey: .items)
            ?? c.decodeIfPresent([RemoteTenantMembership].self, forKey: .memberships)
            ?? []
        items = decodedItems
        workspaces = try c.decodeIfPresent([RemoteTenantMembership].self, forKey: .workspaces)
            ?? c.decodeIfPresent([RemoteTenantMembership].self, forKey: .tenants)
            ?? []
    }
}

struct RemoteGroupMembersResult {
    let items: [RemoteUserGroupMember]
    let selfMember: RemoteUserGroupMember?
    let total: Int?
    let limit: Int?
    let offset: Int?
    let hasMore: Bool?
    let nextOffset: Int?
    let nextCursor: String?

    init(
        items: [RemoteUserGroupMember],
        selfMember: RemoteUserGroupMember? = nil,
        total: Int?,
        limit: Int? = nil,
        offset: Int? = nil,
        hasMore: Bool? = nil,
        nextOffset: Int? = nil,
        nextCursor: String? = nil
    ) {
        self.items = items
        self.selfMember = selfMember
        self.total = total
        self.limit = limit
        self.offset = offset
        self.hasMore = hasMore
        self.nextOffset = nextOffset
        self.nextCursor = nextCursor
    }
}

enum GroupNicknameInputError: Error, Equatable {
    case tooLong
    case containsControlCharacter

    var userMessage: String {
        switch self {
        case .tooLong:
            return "群昵称最多 64 个字符"
        case .containsControlCharacter:
            return "群昵称不能包含控制字符或换行"
        }
    }
}

enum GroupNicknameInputPolicy {
    static let maximumUnicodeScalarCount = 64
    private static let bidiControlScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    static func normalize(_ rawValue: String) throws -> String {
        let normalized = rawValue
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.unicodeScalars.count > maximumUnicodeScalarCount {
            throw GroupNicknameInputError.tooLong
        }
        if normalized.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || bidiControlScalars.contains(scalar.value)
        }) {
            throw GroupNicknameInputError.containsControlCharacter
        }
        return normalized
    }
}

enum GroupMemberDisplayNameResolver {
    static func resolve(
        authoritativeDisplayName: String,
        viewerRemarks: [String?],
        groupNickname: String,
        globalNickname: String,
        stableIdentifier: String,
        isCurrentUser: Bool
    ) -> String {
        let nickname = groupNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty { return nickname }
        if !isCurrentUser {
            for candidate in viewerRemarks {
                if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }
        // Explicit fields define the current contract. Older servers may still
        // project a contact remark into display_name, ahead of group_nickname.
        return [globalNickname, authoritativeDisplayName, stableIdentifier]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名成员"
    }

    static func projectedName(for user: IMUser) -> String {
        [user.name, user.username, user.userID, user.id]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名成员"
    }
}

struct RemoteAvatarUploadData: Decodable {
    let file: RemoteAvatarFile
    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_OPTIONAL_UPLOAD - 修改开始：兼容 presign 返回 file.status=uploaded 且不带 upload 描述
    let upload: RemoteSignedUpload?
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_OPTIONAL_UPLOAD - 修改结束
}

struct RemoteUploadedFileResponse: Decodable {
    let file: RemoteAvatarFile

    enum CodingKeys: String, CodingKey {
        case file
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try c.decodeIfPresent(RemoteAvatarFile.self, forKey: .file) {
            file = nested
        } else {
            file = try RemoteAvatarFile(from: decoder)
        }
    }
}

struct RemoteAvatarFile: Decodable {
    let id: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let status: String
    let uploadStatus: String
    let previewAvailable: Bool
    let downloadAvailable: Bool
    let previewURL: String
    let downloadURL: String
    let downloadEndpoint: String
    let detailEndpoint: String
    let cacheKey: String
    let version: String
    let checksum: String
    let mediaCategory: String
    let fileExtension: String
    let thumbnailURL: String
    let posterURL: String
    let coverURL: String
    let previewKind: String
    let contentDisposition: String
    let width: Int?
    let height: Int?
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case fileID = "file_id"
        case fileName = "file_name"
        case name
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case size
        case status
        case uploadStatus = "upload_status"
        case previewAvailable = "preview_available"
        case downloadAvailable = "download_available"
        case previewURL = "preview_url"
        case downloadURL = "download_url"
        case downloadPublic = "download_public"
        case downloadEndpoint = "download_endpoint"
        case detailEndpoint = "detail_endpoint"
        case cacheKey = "cache_key"
        case thumbObjectKey = "thumb_object_key"
        case thumbnailObjectKey = "thumbnail_object_key"
        case objectKey = "object_key"
        case version
        case fileVersion = "file_version"
        case cacheVersion = "cache_version"
        case checksum
        case mediaCategory = "media_category"
        case fileExtension = "extension"
        case thumbnailURL = "thumbnail_url"
        case thumbURL = "thumb_url"
        case thumbnailEndpoint = "thumbnail_endpoint"
        case previewThumbnailURL = "preview_thumbnail_url"
        case thumbnailPreviewURL = "thumbnail_preview_url"
        case posterURL = "poster_url"
        case posterEndpoint = "poster_endpoint"
        case videoPosterURL = "video_poster_url"
        case coverURL = "cover_url"
        case coverEndpoint = "cover_endpoint"
        case videoCoverURL = "video_cover_url"
        case previewKind = "preview_kind"
        case contentDisposition = "content_disposition"
        case width
        case height
        case durationSeconds = "duration_seconds"
        case duration
        case durationMS = "duration_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .fileID)
            ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes)
            ?? c.decodeIfPresent(Int.self, forKey: .size)
            ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        uploadStatus = try c.decodeIfPresent(String.self, forKey: .uploadStatus) ?? status
        previewAvailable = try c.decodeIfPresent(Bool.self, forKey: .previewAvailable) ?? false
        downloadAvailable = try c.decodeIfPresent(Bool.self, forKey: .downloadAvailable) ?? false
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL) ?? ""
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPublic)
            ?? ""
        downloadEndpoint = try c.decodeIfPresent(String.self, forKey: .downloadEndpoint) ?? ""
        detailEndpoint = try c.decodeIfPresent(String.self, forKey: .detailEndpoint) ?? ""
        let objectKey = try c.decodeIfPresent(String.self, forKey: .thumbObjectKey)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailObjectKey)
            ?? c.decodeIfPresent(String.self, forKey: .objectKey)
            ?? ""
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? objectKey
        version = try c.decodeIfPresent(String.self, forKey: .version)
            ?? c.decodeIfPresent(String.self, forKey: .fileVersion)
            ?? c.decodeIfPresent(String.self, forKey: .cacheVersion)
            ?? ""
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum) ?? ""
        mediaCategory = try c.decodeIfPresent(String.self, forKey: .mediaCategory) ?? ""
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .previewThumbnailURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailPreviewURL)
            ?? ""
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL)
            ?? c.decodeIfPresent(String.self, forKey: .posterEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .videoPosterURL)
            ?? ""
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
            ?? c.decodeIfPresent(String.self, forKey: .coverEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .videoCoverURL)
            ?? ""
        previewKind = try c.decodeIfPresent(String.self, forKey: .previewKind) ?? ""
        contentDisposition = try c.decodeIfPresent(String.self, forKey: .contentDisposition) ?? ""
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        if let seconds = c.decodeLossyDoubleIfPresent(forKey: .durationSeconds)
            ?? c.decodeLossyDoubleIfPresent(forKey: .duration) {
            durationSeconds = seconds
        } else if let milliseconds = c.decodeLossyDoubleIfPresent(forKey: .durationMS) {
            durationSeconds = milliseconds / 1000.0
        } else {
            durationSeconds = nil
        }
    }

    func merged(with fallback: RemoteAvatarFile) -> RemoteAvatarFile {
        RemoteAvatarFile(
            id: id.isEmpty ? fallback.id : id,
            fileName: fileName.isEmpty ? fallback.fileName : fileName,
            mimeType: mimeType.isEmpty ? fallback.mimeType : mimeType,
            sizeBytes: sizeBytes > 0 ? sizeBytes : fallback.sizeBytes,
            status: status.isEmpty ? fallback.status : status,
            uploadStatus: uploadStatus.isEmpty ? fallback.uploadStatus : uploadStatus,
            previewAvailable: previewAvailable || fallback.previewAvailable,
            downloadAvailable: downloadAvailable || fallback.downloadAvailable,
            previewURL: previewURL.isEmpty ? fallback.previewURL : previewURL,
            downloadURL: downloadURL.isEmpty ? fallback.downloadURL : downloadURL,
            downloadEndpoint: downloadEndpoint.isEmpty ? fallback.downloadEndpoint : downloadEndpoint,
            detailEndpoint: detailEndpoint.isEmpty ? fallback.detailEndpoint : detailEndpoint,
            cacheKey: cacheKey.isEmpty ? fallback.cacheKey : cacheKey,
            version: version.isEmpty ? fallback.version : version,
            checksum: checksum.isEmpty ? fallback.checksum : checksum,
            mediaCategory: mediaCategory.isEmpty ? fallback.mediaCategory : mediaCategory,
            fileExtension: fileExtension.isEmpty ? fallback.fileExtension : fileExtension,
            thumbnailURL: thumbnailURL.isEmpty ? fallback.thumbnailURL : thumbnailURL,
            posterURL: posterURL.isEmpty ? fallback.posterURL : posterURL,
            coverURL: coverURL.isEmpty ? fallback.coverURL : coverURL,
            previewKind: previewKind.isEmpty ? fallback.previewKind : previewKind,
            contentDisposition: contentDisposition.isEmpty ? fallback.contentDisposition : contentDisposition,
            width: width ?? fallback.width,
            height: height ?? fallback.height,
            durationSeconds: durationSeconds ?? fallback.durationSeconds
        )
    }

    init(
        id: String,
        fileName: String,
        mimeType: String,
        sizeBytes: Int,
        status: String,
        uploadStatus: String,
        previewAvailable: Bool,
        downloadAvailable: Bool,
        previewURL: String,
        downloadURL: String,
        downloadEndpoint: String,
        detailEndpoint: String,
        cacheKey: String,
        version: String,
        checksum: String,
        mediaCategory: String,
        fileExtension: String,
        thumbnailURL: String,
        posterURL: String,
        coverURL: String,
        previewKind: String,
        contentDisposition: String,
        width: Int?,
        height: Int?,
        durationSeconds: Double?
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.status = status
        self.uploadStatus = uploadStatus
        self.previewAvailable = previewAvailable
        self.downloadAvailable = downloadAvailable
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.downloadEndpoint = downloadEndpoint
        self.detailEndpoint = detailEndpoint
        self.cacheKey = cacheKey
        self.version = version
        self.checksum = checksum
        self.mediaCategory = mediaCategory
        self.fileExtension = fileExtension
        self.thumbnailURL = thumbnailURL
        self.posterURL = posterURL
        self.coverURL = coverURL
        self.previewKind = previewKind
        self.contentDisposition = contentDisposition
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }
}

struct RemoteSignedUpload: Decodable {
    let url: String
    let method: String
    let headers: [String: String]

    enum CodingKeys: String, CodingKey {
        case url
        case method
        case headers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "PUT"
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

struct RemoteDepartmentNode: Decodable, Identifiable, Hashable {
    let departmentID: String
    let parentDepartmentID: String
    let name: String
    let status: String
    let isVirtual: Bool
    let departmentPath: [String]
    let departmentPathNames: [String]
    let depth: Int
    let memberCount: Int
    let children: [RemoteDepartmentNode]

    var id: String { departmentID }

    enum CodingKeys: String, CodingKey {
        case departmentID = "department_id"
        case departmentIDCamel = "departmentId"
        case id
        case parentDepartmentID = "parent_department_id"
        case parentDepartmentIDCamel = "parentDepartmentId"
        case parentID = "parent_id"
        case name
        case status
        case isVirtual = "is_virtual"
        case isVirtualCamel = "isVirtual"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
        case depth
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        departmentID = try c.decodeIfPresent(String.self, forKey: .departmentID)
            ?? c.decodeIfPresent(String.self, forKey: .departmentIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        parentDepartmentID = try c.decodeIfPresent(String.self, forKey: .parentDepartmentID)
            ?? c.decodeIfPresent(String.self, forKey: .parentDepartmentIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .parentID)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        isVirtual = c.decodeLossyBoolIfPresent(forKey: .isVirtual)
            ?? c.decodeLossyBoolIfPresent(forKey: .isVirtualCamel)
            ?? false
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
        depth = c.decodeLossyIntIfPresent(forKey: .depth) ?? 0
        memberCount = c.decodeLossyIntIfPresent(forKey: .memberCount)
            ?? c.decodeLossyIntIfPresent(forKey: .memberCountCamel)
            ?? 0
        children = try c.decodeIfPresent([RemoteDepartmentNode].self, forKey: .children) ?? []
    }
}

struct RemoteOrganizationTree: Decodable {
    let departmentEnabled: Bool
    let canManage: Bool
    let canManageDepartment: Bool
    let root: RemoteDepartmentNode?
    let items: [RemoteDepartmentNode]

    enum CodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
        case canManage = "can_manage"
        case canManageCamel = "canManage"
        case canManageDepartment = "can_manage_department"
        case canManageDepartmentCamel = "canManageDepartment"
        case root
        case items
    }

    init(departmentEnabled: Bool, canManage: Bool = false, canManageDepartment: Bool = false, root: RemoteDepartmentNode?, items: [RemoteDepartmentNode]) {
        self.departmentEnabled = departmentEnabled
        self.canManage = canManage
        self.canManageDepartment = canManageDepartment
        self.root = root
        self.items = items
    }

    static func disabledFallback(root: RemoteDepartmentNode?) -> RemoteOrganizationTree {
        RemoteOrganizationTree(departmentEnabled: false, root: root, items: [])
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        departmentEnabled = c.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? false
        canManage = c.decodeLossyBoolIfPresent(forKey: .canManage)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageCamel)
            ?? false
        canManageDepartment = c.decodeLossyBoolIfPresent(forKey: .canManageDepartment)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageDepartmentCamel)
            ?? canManage
        root = try c.decodeIfPresent(RemoteDepartmentNode.self, forKey: .root)
        items = try c.decodeIfPresent([RemoteDepartmentNode].self, forKey: .items) ?? []
    }
}

struct RemoteOrganizationMemberView: Decodable, Identifiable, Hashable {
    let imUID: String
    let userID: String
    let nickname: String
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let role: String
    let status: String
    let presenceStatus: String
    let online: Bool
    let onlineKnown: Bool
    let lastSeenAt: String
    let departmentID: String
    let departmentName: String
    let departmentPath: [String]
    let departmentPathNames: [String]
    let positionName: String
    let isPrimary: Bool
    let sortOrder: Int
    let createdAt: String

    var id: String { imUID.isEmpty ? userID : imUID }

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case nickname
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case role
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case departmentID = "department_id"
        case departmentIDCamel = "departmentId"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
        case positionName = "position_name"
        case positionNameCamel = "positionName"
        case isPrimary = "is_primary"
        case isPrimaryCamel = "isPrimary"
        case sortOrder = "sort_order"
        case sortOrderCamel = "sortOrder"
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        presenceStatus = try c.decodeIfPresent(String.self, forKey: .presenceStatus) ?? ""
        let decodedOnline = c.decodeLossyBoolIfPresent(forKey: .online)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
        online = decodedOnline ?? false
        onlineKnown = decodedOnline != nil
        lastSeenAt = [
            try c.decodeIfPresent(String.self, forKey: .lastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAt),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAtCamel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        departmentID = try c.decodeIfPresent(String.self, forKey: .departmentID)
            ?? c.decodeIfPresent(String.self, forKey: .departmentIDCamel)
            ?? ""
        departmentName = try c.decodeIfPresent(String.self, forKey: .departmentName)
            ?? c.decodeIfPresent(String.self, forKey: .departmentNameCamel)
            ?? ""
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
        positionName = try c.decodeIfPresent(String.self, forKey: .positionName)
            ?? c.decodeIfPresent(String.self, forKey: .positionNameCamel)
            ?? ""
        isPrimary = c.decodeLossyBoolIfPresent(forKey: .isPrimary)
            ?? c.decodeLossyBoolIfPresent(forKey: .isPrimaryCamel)
            ?? false
        sortOrder = c.decodeLossyIntIfPresent(forKey: .sortOrder)
            ?? c.decodeLossyIntIfPresent(forKey: .sortOrderCamel)
            ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtCamel)
            ?? ""
    }
}

struct RemoteOrganizationMemberList: Decodable {
    let departmentEnabled: Bool
    let canManage: Bool
    let canManageDepartment: Bool
    let departmentID: String
    let items: [RemoteOrganizationMemberView]

    enum CodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
        case canManage = "can_manage"
        case canManageCamel = "canManage"
        case canManageDepartment = "can_manage_department"
        case canManageDepartmentCamel = "canManageDepartment"
        case departmentID = "department_id"
        case departmentIDCamel = "departmentId"
        case items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        departmentEnabled = c.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? false
        canManage = c.decodeLossyBoolIfPresent(forKey: .canManage)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageCamel)
            ?? false
        canManageDepartment = c.decodeLossyBoolIfPresent(forKey: .canManageDepartment)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageDepartmentCamel)
            ?? canManage
        departmentID = try c.decodeIfPresent(String.self, forKey: .departmentID)
            ?? c.decodeIfPresent(String.self, forKey: .departmentIDCamel)
            ?? "company"
        items = try c.decodeIfPresent([RemoteOrganizationMemberView].self, forKey: .items) ?? []
    }
}

struct RemoteRTCProvider: Decodable {
    let iceTransportPolicyVersion: Int?
    let callTypes: [String]
    let videoSupported: Bool
    let voiceCallEnabled: Bool?
    let videoCallEnabled: Bool?
    let capabilitiesVersion: String
    let mediaPlaneConfigured: Bool
    let iceServersConfigured: Bool
    let callTimeoutSeconds: Int?

    var supportsAudio: Bool {
        callTypes.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "audio" }
    }

    var supportsVideo: Bool {
        videoSupported
            && videoCallEnabled != false
            && capabilitiesVersion == RTCDeviceCapabilities.protocolVersion
            && callTypes.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" }
    }

    enum CodingKeys: String, CodingKey {
        case iceTransportPolicyVersion = "ice_transport_policy_version"
        case callTypes = "call_types"
        case videoSupported = "video_supported"
        case voiceCallEnabled = "voice_call_enabled"
        case videoCallEnabled = "video_call_enabled"
        case capabilitiesVersion = "capabilities_version"
        case mediaPlaneConfigured = "media_plane_configured"
        case iceServersConfigured = "ice_servers_configured"
        case callTimeoutSeconds = "call_timeout_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iceTransportPolicyVersion = c.contains(.iceTransportPolicyVersion)
            ? try c.decode(Int.self, forKey: .iceTransportPolicyVersion) : nil
        guard iceTransportPolicyVersion == nil || iceTransportPolicyVersion == 1 else {
            throw RTCIcePolicyError.invalidPolicy
        }
        callTypes = try c.decodeIfPresent([String].self, forKey: .callTypes) ?? []
        videoSupported = c.decodeLossyBoolIfPresent(forKey: .videoSupported) ?? false
        voiceCallEnabled = c.decodeLossyBoolIfPresent(forKey: .voiceCallEnabled)
        videoCallEnabled = c.decodeLossyBoolIfPresent(forKey: .videoCallEnabled)
        capabilitiesVersion = try c.decodeIfPresent(String.self, forKey: .capabilitiesVersion) ?? ""
        mediaPlaneConfigured = c.decodeLossyBoolIfPresent(forKey: .mediaPlaneConfigured) ?? false
        iceServersConfigured = c.decodeLossyBoolIfPresent(forKey: .iceServersConfigured) ?? mediaPlaneConfigured
        callTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .callTimeoutSeconds)
    }
}

struct RTCDeviceCapabilities: Codable, Sendable, Equatable {
    static let protocolVersion = "video-call-v1"

    let version: String
    let audio: Bool
    let video: Bool
    let cameraAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case audio
        case video
        case cameraAvailable = "camera_available"
    }

    init(
        version: String = Self.protocolVersion,
        audio: Bool = true,
        video: Bool,
        cameraAvailable: Bool
    ) {
        self.version = version
        self.audio = audio
        self.video = video
        self.cameraAvailable = cameraAvailable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older/voice-only RTC responses legitimately omit the version and
        // capability booleans through Go's `omitempty`.  A missing optional
        // capability must not turn a successful HTTP 201 create response into
        // a transport error (whose localized phrase is just "created").
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        audio = c.decodeLossyBoolIfPresent(forKey: .audio) ?? false
        video = c.decodeLossyBoolIfPresent(forKey: .video) ?? false
        cameraAvailable = c.decodeLossyBoolIfPresent(forKey: .cameraAvailable) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(audio, forKey: .audio)
        try c.encode(video, forKey: .video)
        try c.encode(cameraAvailable, forKey: .cameraAvailable)
    }

    var requestBody: [String: Any] {
        [
            "version": version,
            "audio": audio,
            "video": video,
            "camera_available": cameraAvailable
        ]
    }
}

struct RemoteRTCCallsData: Decodable {
    let calls: [RemoteRTCCall]

    enum CodingKeys: String, CodingKey {
        case calls
        case items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = try c.decodeIfPresent([RemoteRTCCall].self, forKey: .calls)
            ?? c.decodeIfPresent([RemoteRTCCall].self, forKey: .items)
            ?? []
    }
}

struct RemoteRTCDevice: Codable, Sendable, Equatable {
    let uid: String
    let deviceID: String
    let deviceType: String
    let appID: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case uid
        case deviceID = "device_id"
        case deviceType = "device_type"
    }

    init(uid: String = "", deviceID: String = "", deviceType: String = "", appID: String = "") {
        self.uid = uid
        self.deviceID = deviceID
        self.deviceType = deviceType
        self.appID = appID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType) ?? ""
    }
}

struct RemoteRTCRoomParticipant: Codable, Sendable, Equatable {
    let uid: String
    let deviceID: String
    let deviceType: String
    let role: String
    let joinedAt: String

    enum CodingKeys: String, CodingKey {
        case uid
        case imUID = "im_uid"
        case userID = "user_id"
        case deviceID = "device_id"
        case deviceId = "deviceId"
        case id
        case deviceType = "device_type"
        case deviceTypeCamel = "deviceType"
        case appID = "app_id"
        case role
        case status
        case joinedAt = "joined_at"
        case joinedAtCamel = "joinedAt"
    }

    init(uid: String = "", deviceID: String = "", deviceType: String = "", role: String = "", joinedAt: String = "") {
        self.uid = uid
        self.deviceID = deviceID
        self.deviceType = deviceType
        self.role = role
        self.joinedAt = joinedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid)
            ?? c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .userID)
            ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
            ?? c.decodeIfPresent(String.self, forKey: .deviceId)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType)
            ?? c.decodeIfPresent(String.self, forKey: .deviceTypeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .appID)
            ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role)
            ?? c.decodeIfPresent(String.self, forKey: .status)
            ?? ""
        joinedAt = try c.decodeIfPresent(String.self, forKey: .joinedAt)
            ?? c.decodeIfPresent(String.self, forKey: .joinedAtCamel)
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(deviceType, forKey: .deviceType)
        try c.encode(role, forKey: .role)
        try c.encode(joinedAt, forKey: .joinedAt)
    }
}

struct RemoteRTCCallResponse: Decodable {
    // Bound to the actual scoped provider observation used by this create request.
    var requiresAcceptedDeviceBeforeJoin = false
    let call: RemoteRTCCall
    let rtcToken: String

    enum CodingKeys: String, CodingKey {
        case call
        case rtcToken = "rtc_token"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        call = try c.decodeIfPresent(RemoteRTCCall.self, forKey: .call) ?? RemoteRTCCall()
        rtcToken = try c.decodeIfPresent(String.self, forKey: .rtcToken) ?? ""
        guard RTCCallRecordRedialFreshnessContext.acceptsCreatedCall(call) else {
            throw DecodingError.dataCorruptedError(
                forKey: .call,
                in: c,
                debugDescription: "Redial create response did not contain a fresh call identity"
            )
        }
    }
}

struct RemoteRTCParticipantProfile: Decodable, Equatable, Sendable {
    let uid: String
    let userID: String
    let displayName: String
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case uid
        case imUID = "im_uid"
        case userID = "user_id"
        case userIDCamel = "userId"
        case id
        case displayName = "display_name"
        case nickname
        case name
        case username
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    init(
        uid: String = "",
        userID: String = "",
        displayName: String = "",
        avatar: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = ""
    ) {
        self.uid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatar = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatarVersion = avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatarUpdatedAt = avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uid: try c.decodeIfPresent(String.self, forKey: .uid)
                ?? c.decodeIfPresent(String.self, forKey: .imUID)
                ?? c.decodeIfPresent(String.self, forKey: .id)
                ?? "",
            userID: try c.decodeIfPresent(String.self, forKey: .userID)
                ?? c.decodeIfPresent(String.self, forKey: .userIDCamel)
                ?? "",
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName)
                ?? c.decodeIfPresent(String.self, forKey: .nickname)
                ?? c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .username)
                ?? "",
            avatar: try c.decodeIfPresent(String.self, forKey: .avatar)
                ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
                ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
                ?? "",
            avatarVersion: try c.decodeIfPresent(String.self, forKey: .avatarVersion)
                ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
                ?? c.decodeIfPresent(String.self, forKey: .version)
                ?? "",
            avatarUpdatedAt: try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
                ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
                ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
                ?? ""
        )
    }

    static func from(dictionary: [String: Any]?) -> RemoteRTCParticipantProfile? {
        guard let dictionary else { return nil }
        let profile = RemoteRTCParticipantProfile(
            uid: firstString(dictionary, keys: ["uid", "im_uid", "imUID", "id"]),
            userID: firstString(dictionary, keys: ["user_id", "userID", "userId"]),
            displayName: firstString(dictionary, keys: ["display_name", "displayName", "nickname", "name", "username"]),
            avatar: firstString(dictionary, keys: ["avatar", "avatar_url", "avatarURL", "avatarUrl"]),
            avatarVersion: firstString(dictionary, keys: ["avatar_version", "avatarVersion", "version"]),
            avatarUpdatedAt: firstString(dictionary, keys: ["avatar_updated_at", "avatarUpdatedAt", "updated_at", "updatedAt"])
        )
        return profile.isEmpty ? nil : profile
    }

    var isEmpty: Bool {
        [uid, userID, displayName, avatar, avatarVersion, avatarUpdatedAt].allSatisfy { $0.isEmpty }
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] {
                return stringValue(value)
            }
        }
        return ""
    }

    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct RemoteRTCCall: Decodable {
    let id: String
    let status: String
    let roomID: String
    let rtcToken: String
    let callerUID: String
    let calleeUID: String
    let channelID: String
    let channelType: String
    let callType: String
    let requestedMediaMode: String
    let mediaMode: String
    let peerCapabilityStatus: String
    let callerCapabilities: RTCDeviceCapabilities?
    let callerDevice: RemoteRTCDevice?
    let calleeDevice: RemoteRTCDevice?
    let acceptedDevice: RemoteRTCDevice?
    let callerProfile: RemoteRTCParticipantProfile?
    let calleeProfile: RemoteRTCParticipantProfile?
    let callerName: String
    let calleeName: String
    let callerAvatarURL: String
    let callerAvatarVersion: String
    let callerAvatarUpdatedAt: String
    let calleeAvatarURL: String
    let calleeAvatarVersion: String
    let calleeAvatarUpdatedAt: String
    let createdAt: String
    let updatedAt: String
    let startedAt: String
    let acceptedAt: String
    let endedAt: String
    let endReason: String
    let stateVersion: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case callID = "call_id"
        case status
        case roomID = "room_id"
        case rtcToken = "rtc_token"
        case callerUID = "caller_uid"
        case calleeUID = "callee_uid"
        case targetUID = "target_uid"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case callType = "call_type"
        case requestedMediaMode = "requested_media_mode"
        case mediaMode = "media_mode"
        case peerCapabilityStatus = "peer_capability_status"
        case callerCapabilities = "caller_capabilities"
        case callerDevice = "caller_device"
        case calleeDevice = "callee_device"
        case acceptedDevice = "accepted_device"
        case callerProfile = "caller_profile"
        case callerProfileCamel = "callerProfile"
        case caller
        case fromProfile = "from_profile"
        case calleeProfile = "callee_profile"
        case calleeProfileCamel = "calleeProfile"
        case callee
        case targetProfile = "target_profile"
        case callerName = "caller_name"
        case callerNameCamel = "callerName"
        case fromName = "from_name"
        case calleeName = "callee_name"
        case calleeNameCamel = "calleeName"
        case targetName = "target_name"
        case callerAvatar = "caller_avatar"
        case callerAvatarURL = "caller_avatar_url"
        case callerAvatarURLCamel = "callerAvatarUrl"
        case callerAvatarVersion = "caller_avatar_version"
        case callerAvatarVersionCamel = "callerAvatarVersion"
        case callerAvatarUpdatedAt = "caller_avatar_updated_at"
        case callerAvatarUpdatedAtCamel = "callerAvatarUpdatedAt"
        case calleeAvatar = "callee_avatar"
        case calleeAvatarURL = "callee_avatar_url"
        case calleeAvatarURLCamel = "calleeAvatarUrl"
        case targetAvatar = "target_avatar"
        case targetAvatarURL = "target_avatar_url"
        case calleeAvatarVersion = "callee_avatar_version"
        case calleeAvatarVersionCamel = "calleeAvatarVersion"
        case targetAvatarVersion = "target_avatar_version"
        case calleeAvatarUpdatedAt = "callee_avatar_updated_at"
        case calleeAvatarUpdatedAtCamel = "calleeAvatarUpdatedAt"
        case targetAvatarUpdatedAt = "target_avatar_updated_at"
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
        case startedAt = "started_at"
        case startedAtCamel = "startedAt"
        case acceptedAt = "accepted_at"
        case acceptedAtCamel = "acceptedAt"
        case endedAt = "ended_at"
        case endedAtCamel = "endedAt"
        case endReason = "end_reason"
        case endReasonCamel = "endReason"
        case stateVersion = "state_version"
        case stateVersionCamel = "stateVersion"
    }

    init(
        id: String = "",
        status: String = "",
        roomID: String = "",
        rtcToken: String = "",
        callerUID: String = "",
        calleeUID: String = "",
        channelID: String = "",
        channelType: String = "",
        callType: String = "",
        requestedMediaMode: String = "",
        mediaMode: String = "",
        peerCapabilityStatus: String = "",
        callerCapabilities: RTCDeviceCapabilities? = nil,
        callerDevice: RemoteRTCDevice? = nil,
        calleeDevice: RemoteRTCDevice? = nil,
        acceptedDevice: RemoteRTCDevice? = nil,
        callerProfile: RemoteRTCParticipantProfile? = nil,
        calleeProfile: RemoteRTCParticipantProfile? = nil,
        callerName: String = "",
        calleeName: String = "",
        callerAvatarURL: String = "",
        callerAvatarVersion: String = "",
        callerAvatarUpdatedAt: String = "",
        calleeAvatarURL: String = "",
        calleeAvatarVersion: String = "",
        calleeAvatarUpdatedAt: String = "",
        createdAt: String = "",
        updatedAt: String = "",
        startedAt: String = "",
        acceptedAt: String = "",
        endedAt: String = "",
        endReason: String = "",
        stateVersion: Int64 = 0
    ) {
        self.id = id
        self.status = status
        self.roomID = roomID
        self.rtcToken = rtcToken
        self.callerUID = callerUID
        self.calleeUID = calleeUID
        self.channelID = channelID
        self.channelType = channelType
        self.callType = callType
        self.requestedMediaMode = requestedMediaMode
        self.mediaMode = mediaMode
        self.peerCapabilityStatus = peerCapabilityStatus
        self.callerCapabilities = callerCapabilities
        self.callerDevice = callerDevice
        self.calleeDevice = calleeDevice
        self.acceptedDevice = acceptedDevice
        self.callerProfile = callerProfile
        self.calleeProfile = calleeProfile
        self.callerName = callerName
        self.calleeName = calleeName
        self.callerAvatarURL = callerAvatarURL
        self.callerAvatarVersion = callerAvatarVersion
        self.callerAvatarUpdatedAt = callerAvatarUpdatedAt
        self.calleeAvatarURL = calleeAvatarURL
        self.calleeAvatarVersion = calleeAvatarVersion
        self.calleeAvatarUpdatedAt = calleeAvatarUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.acceptedAt = acceptedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.stateVersion = stateVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .callID)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        roomID = try c.decodeIfPresent(String.self, forKey: .roomID) ?? ""
        rtcToken = try c.decodeIfPresent(String.self, forKey: .rtcToken) ?? ""
        callerUID = try c.decodeIfPresent(String.self, forKey: .callerUID) ?? ""
        calleeUID = try c.decodeIfPresent(String.self, forKey: .calleeUID)
            ?? c.decodeIfPresent(String.self, forKey: .targetUID)
            ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        callType = try c.decodeIfPresent(String.self, forKey: .callType) ?? ""
        requestedMediaMode = try c.decodeIfPresent(String.self, forKey: .requestedMediaMode) ?? callType
        mediaMode = try c.decodeIfPresent(String.self, forKey: .mediaMode) ?? callType
        peerCapabilityStatus = try c.decodeIfPresent(String.self, forKey: .peerCapabilityStatus) ?? "unknown"
        callerCapabilities = try c.decodeIfPresent(RTCDeviceCapabilities.self, forKey: .callerCapabilities)
        callerDevice = try c.decodeIfPresent(RemoteRTCDevice.self, forKey: .callerDevice)
        calleeDevice = try c.decodeIfPresent(RemoteRTCDevice.self, forKey: .calleeDevice)
        acceptedDevice = try c.decodeIfPresent(RemoteRTCDevice.self, forKey: .acceptedDevice)
        callerProfile = try c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .callerProfile)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .callerProfileCamel)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .caller)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .fromProfile)
        calleeProfile = try c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .calleeProfile)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .calleeProfileCamel)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .callee)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .targetProfile)
        callerName = try c.decodeIfPresent(String.self, forKey: .callerName)
            ?? c.decodeIfPresent(String.self, forKey: .callerNameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .fromName)
            ?? callerProfile?.displayName
            ?? ""
        calleeName = try c.decodeIfPresent(String.self, forKey: .calleeName)
            ?? c.decodeIfPresent(String.self, forKey: .calleeNameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .targetName)
            ?? calleeProfile?.displayName
            ?? ""
        callerAvatarURL = try c.decodeIfPresent(String.self, forKey: .callerAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .callerAvatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .callerAvatarURLCamel)
            ?? callerProfile?.avatar
            ?? ""
        callerAvatarVersion = try c.decodeIfPresent(String.self, forKey: .callerAvatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .callerAvatarVersionCamel)
            ?? callerProfile?.avatarVersion
            ?? ""
        callerAvatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .callerAvatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .callerAvatarUpdatedAtCamel)
            ?? callerProfile?.avatarUpdatedAt
            ?? ""
        calleeAvatarURL = try c.decodeIfPresent(String.self, forKey: .calleeAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .calleeAvatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .calleeAvatarURLCamel)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatarURL)
            ?? calleeProfile?.avatar
            ?? ""
        calleeAvatarVersion = try c.decodeIfPresent(String.self, forKey: .calleeAvatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .calleeAvatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatarVersion)
            ?? calleeProfile?.avatarVersion
            ?? ""
        calleeAvatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .calleeAvatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .calleeAvatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatarUpdatedAt)
            ?? calleeProfile?.avatarUpdatedAt
            ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtCamel)
            ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel)
            ?? ""
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
            ?? c.decodeIfPresent(String.self, forKey: .startedAtCamel)
            ?? ""
        acceptedAt = try c.decodeIfPresent(String.self, forKey: .acceptedAt)
            ?? c.decodeIfPresent(String.self, forKey: .acceptedAtCamel)
            ?? ""
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
            ?? c.decodeIfPresent(String.self, forKey: .endedAtCamel)
            ?? ""
        endReason = try c.decodeIfPresent(String.self, forKey: .endReason)
            ?? c.decodeIfPresent(String.self, forKey: .endReasonCamel)
            ?? ""
        stateVersion = c.decodeLossyInt64IfPresent(forKey: .stateVersion)
            ?? c.decodeLossyInt64IfPresent(forKey: .stateVersionCamel)
            ?? 0
    }
}

struct RemoteRTCRoomJoinData: Decodable {
    let roomID: String
    let rtcToken: String
    let media: RemoteRTCMedia
    let selfParticipant: RemoteRTCRoomParticipant?
    let peerParticipant: RemoteRTCRoomParticipant?
    let participants: [RemoteRTCRoomParticipant]

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case rtcToken = "rtc_token"
        case media
        case participant
        case selfParticipant = "self_participant"
        case peerParticipant = "peer_participant"
        case participants
    }

    enum MediaCodingKeys: String, CodingKey {
        case roomID = "room_id"
        case rtcToken = "rtc_token"
    }

    init(
        roomID: String = "",
        rtcToken: String = "",
        media: RemoteRTCMedia = RemoteRTCMedia(),
        selfParticipant: RemoteRTCRoomParticipant? = nil,
        peerParticipant: RemoteRTCRoomParticipant? = nil,
        participants: [RemoteRTCRoomParticipant] = []
    ) {
        self.roomID = roomID
        self.rtcToken = rtcToken
        self.media = media
        self.selfParticipant = selfParticipant
        self.peerParticipant = peerParticipant
        self.participants = participants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mediaContainer = try? c.nestedContainer(keyedBy: MediaCodingKeys.self, forKey: .media)
        roomID = try c.decodeIfPresent(String.self, forKey: .roomID)
            ?? mediaContainer?.decodeIfPresent(String.self, forKey: .roomID)
            ?? ""
        rtcToken = try c.decodeIfPresent(String.self, forKey: .rtcToken)
            ?? mediaContainer?.decodeIfPresent(String.self, forKey: .rtcToken)
            ?? ""
        media = try c.decodeIfPresent(RemoteRTCMedia.self, forKey: .media) ?? RemoteRTCMedia()
        let legacyParticipant = try c.decodeIfPresent(RemoteRTCRoomParticipant.self, forKey: .participant)
        selfParticipant = try c.decodeIfPresent(RemoteRTCRoomParticipant.self, forKey: .selfParticipant)
            ?? legacyParticipant
        peerParticipant = try c.decodeIfPresent(RemoteRTCRoomParticipant.self, forKey: .peerParticipant)
        let decodedParticipants = try c.decodeIfPresent([RemoteRTCRoomParticipant].self, forKey: .participants) ?? []
        if decodedParticipants.isEmpty, let legacyParticipant {
            participants = [legacyParticipant]
        } else {
            participants = decodedParticipants
        }
    }
}

enum RTCIcePolicyError: Error, LocalizedError {
    case invalidPolicy, missingPolicy, changedPolicy, relayUnavailable

    var errorDescription: String? {
        switch self {
        case .relayUnavailable: return "通话连接失败，请稍后重试"
        default: return "通话连接策略暂不可用，请稍后重试"
        }
    }
}

struct RTCIcePolicy: Decodable, Sendable, Equatable {
    enum Transport: String, Decodable, Sendable { case all, relay }
    let transport: Transport
    let version: Int
    let revision: String

    // Only an explicitly negotiated legacy server may reach this default.
    static let legacy = Self(transport: .all, version: 0, revision: "")

    enum CodingKeys: String, CodingKey {
        case transport = "ice_transport_policy"
        case version = "ice_transport_policy_version"
        case revision = "rtc_config_revision"
    }

    init(transport: Transport, version: Int, revision: String) {
        self.transport = transport
        self.version = version
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decode(Transport.self, forKey: .transport)
        version = try c.decode(Int.self, forKey: .version)
        revision = try c.decode(String.self, forKey: .revision)
        guard version == 1, !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RTCIcePolicyError.invalidPolicy
        }
    }

    static func decodeIfPresent(from decoder: Decoder) throws -> Self? {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.transport) || c.contains(.version) || c.contains(.revision) else { return nil }
        return try Self(from: decoder)
    }

    // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：保留后端 ICE policy 合同解析，但 iOS 不再因 relay policy 强制阻断非中继路径
    static func resolve(_ value: Self?, requiresV1: Bool, servers _: [RemoteRTCIceServer]) throws -> Self {
        guard let value else {
            guard !requiresV1 else { throw RTCIcePolicyError.missingPolicy }
            return .legacy
        }
        return value
    }
    // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束

    func validateReplacement(_ value: Self?) throws {
        guard (value ?? .legacy) == self else { throw RTCIcePolicyError.changedPolicy }
    }

    func validateServers(_ servers: [RemoteRTCIceServer]) throws {
        guard transport == .relay else { return }
        let usable = servers.contains { server in
            guard !(server.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !(server.credential ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return server.urls.contains { raw in
                let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, ["turn", "turns"].contains(parts[0].lowercased()),
                      let url = URLComponents(string: String(parts[0]) + "://" + String(parts[1])),
                      let host = url.host, !host.isEmpty,
                      url.user == nil, url.password == nil, url.path.isEmpty else { return false }
                return url.port.map { (1...65535).contains($0) } ?? true
            }
        }
        guard usable else { throw RTCIcePolicyError.relayUnavailable }
    }
}

struct RemoteRTCMedia: Decodable {
    let owtBaseURL: String
    let icePolicy: RTCIcePolicy?
    let iceServers: [RemoteRTCIceServer]
    let iceCredentialExpiresAt: String
    let iceCredentialRefreshAfter: String

    let turnRouteTelemetry: RemoteRTCTurnRouteTelemetry?

    enum CodingKeys: String, CodingKey {
        case owtBaseURL = "owt_base_url"
        case turnRouteTelemetry = "turn_route_telemetry"
        case iceServers = "ice_servers"
        case iceCredentialExpiresAt = "ice_credential_expires_at"
        case iceCredentialRefreshAfter = "ice_credential_refresh_after"
    }

    init(
        owtBaseURL: String = "",
        iceServers: [RemoteRTCIceServer] = [],
        iceCredentialExpiresAt: String = "",
        iceCredentialRefreshAfter: String = "",
        turnRouteTelemetry: RemoteRTCTurnRouteTelemetry? = nil,
        icePolicy: RTCIcePolicy? = nil
    ) {
        self.owtBaseURL = owtBaseURL
        self.icePolicy = icePolicy
        self.iceServers = iceServers
        self.iceCredentialExpiresAt = iceCredentialExpiresAt
        self.iceCredentialRefreshAfter = iceCredentialRefreshAfter
        self.turnRouteTelemetry = turnRouteTelemetry
    }

    init(from decoder: Decoder) throws {
        icePolicy = try RTCIcePolicy.decodeIfPresent(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Optional telemetry must never make otherwise valid media credentials fail.
        turnRouteTelemetry = try? c.decode(RemoteRTCTurnRouteTelemetry.self, forKey: .turnRouteTelemetry)
        owtBaseURL = try c.decodeIfPresent(String.self, forKey: .owtBaseURL) ?? ""
        iceServers = try c.decodeIfPresent([RemoteRTCIceServer].self, forKey: .iceServers) ?? []
        iceCredentialExpiresAt = try c.decodeIfPresent(String.self, forKey: .iceCredentialExpiresAt) ?? ""
        iceCredentialRefreshAfter = try c.decodeIfPresent(String.self, forKey: .iceCredentialRefreshAfter) ?? ""
    }
}

struct RemoteRTCIceServer: Decodable {
    let urls: [String]
    let username: String?
    let credential: String?

    enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? c.decodeIfPresent([String].self, forKey: .urls) {
            urls = array
        } else if let single = try? c.decodeIfPresent(String.self, forKey: .urls) {
            urls = [single]
        } else {
            urls = []
        }
        username = try c.decodeIfPresent(String.self, forKey: .username)
        credential = try c.decodeIfPresent(String.self, forKey: .credential)
    }
}

struct RemoteRTCIceCredentials: Decodable {
    let icePolicy: RTCIcePolicy?
    let iceServers: [RemoteRTCIceServer]
    let rtcToken: String
    let iceCredentialExpiresAt: String
    let iceCredentialRefreshAfter: String

    let turnRouteTelemetry: RemoteRTCTurnRouteTelemetry?

    enum CodingKeys: String, CodingKey {
        case turnRouteTelemetry = "turn_route_telemetry"
        case iceServers = "ice_servers"
        case rtcToken = "rtc_token"
        case iceCredentialExpiresAt = "ice_credential_expires_at"
        case iceCredentialRefreshAfter = "ice_credential_refresh_after"
    }

    init(
        iceServers: [RemoteRTCIceServer] = [],
        rtcToken: String = "",
        iceCredentialExpiresAt: String = "",
        iceCredentialRefreshAfter: String = "",
        turnRouteTelemetry: RemoteRTCTurnRouteTelemetry? = nil,
        icePolicy: RTCIcePolicy? = nil
    ) {
        self.icePolicy = icePolicy
        self.iceServers = iceServers
        self.rtcToken = rtcToken
        self.iceCredentialExpiresAt = iceCredentialExpiresAt
        self.iceCredentialRefreshAfter = iceCredentialRefreshAfter
        self.turnRouteTelemetry = turnRouteTelemetry
    }

    init(from decoder: Decoder) throws {
        icePolicy = try RTCIcePolicy.decodeIfPresent(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Optional telemetry must never make otherwise valid media credentials fail.
        turnRouteTelemetry = try? c.decode(RemoteRTCTurnRouteTelemetry.self, forKey: .turnRouteTelemetry)
        iceServers = try c.decode([RemoteRTCIceServer].self, forKey: .iceServers)
        rtcToken = try c.decode(String.self, forKey: .rtcToken)
        iceCredentialExpiresAt = try c.decode(String.self, forKey: .iceCredentialExpiresAt)
        iceCredentialRefreshAfter = try c.decode(String.self, forKey: .iceCredentialRefreshAfter)
    }
}

struct RemoteRTCTurnRouteTelemetry: Decodable, Sendable, Equatable {
    struct Node: Decodable, Sendable, Equatable {
        let nodeID: String
        let urls: [String]
        enum CodingKeys: String, CodingKey { case nodeID = "node_id", urls }
    }
    let schemaVersion: String
    let mappingVersion: String
    let nodes: [Node]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", mappingVersion = "mapping_version", nodes
    }
    var isSupported: Bool {
        schemaVersion == "rtc-turn-route-v1"
            && mappingVersion.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            && !nodes.isEmpty && nodes.count <= 256
            && nodes.allSatisfy {
                $0.nodeID.range(of: "^tn_[0-9a-f]{32}$", options: .regularExpression) != nil
                    && !$0.urls.isEmpty && $0.urls.count <= 32
            }
    }
}

struct RTCTurnRouteObservation: Sendable, Equatable {
    struct Transport: Sendable, Equatable {
        let transportID: Int
        let routeEpoch: Int
        let selectionBasis: String
        let localCandidateType: String
        let remoteCandidateType: String
        let localRelayProtocol: String
        let nodeID: String?
        let unknownReason: String
        let bytesSent: Int64?
        let bytesReceived: Int64?

        var requestBody: [String: Any] {
            var body: [String: Any] = [
                "transport_id": transportID, "route_epoch": routeEpoch,
                "selection_basis": selectionBasis, "local_candidate_type": localCandidateType,
                "remote_candidate_type": remoteCandidateType, "local_relay_protocol": localRelayProtocol,
                "unknown_reason": unknownReason
            ]
            if let nodeID { body["node_id"] = nodeID }
            if let bytesSent, let bytesReceived {
                body["bytes_sent"] = bytesSent
                body["bytes_received"] = bytesReceived
            }
            return body
        }
    }
    let connectionID: String
    let mappingVersion: String
    let transports: [Transport]
    var requestBody: [String: Any] {
        ["schema_version": "rtc-turn-route-v1", "connection_id": connectionID,
         "mapping_version": mappingVersion, "transports": transports.map(\.requestBody)]
    }
}

struct RTCQualitySample: Sendable, Equatable {
    static let schemaVersion = "rtc-quality-v1"

    let sampledAt: Date
    let sampleSeq: Int64
    let connectionRoute: String
    let candidateProtocol: String
    let rttMS: Double?
    let jitterMS: Double?
    let packetLossPct: Double?
    let availableOutgoingBitrateKbps: Double?
    let inboundBitrateKbps: Double?
    let outboundBitrateKbps: Double?
    let framesPerSecond: Double?
    let framesDropped: Int64?
    let audioConcealmentPct: Double?
    let freezeCount: Int64?
    var routeObservation: RTCTurnRouteObservation? = nil

    var requestBody: [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: Any] = [
            "sampled_at": formatter.string(from: sampledAt),
            "sample_seq": sampleSeq,
            "connection_route": connectionRoute,
            "candidate_protocol": candidateProtocol
        ]
        if let rttMS { body["rtt_ms"] = rttMS }
        if let jitterMS { body["jitter_ms"] = jitterMS }
        if let packetLossPct { body["packet_loss_pct"] = packetLossPct }
        if let availableOutgoingBitrateKbps { body["available_outgoing_bitrate_kbps"] = availableOutgoingBitrateKbps }
        if let inboundBitrateKbps { body["inbound_bitrate_kbps"] = inboundBitrateKbps }
        if let outboundBitrateKbps { body["outbound_bitrate_kbps"] = outboundBitrateKbps }
        if let framesPerSecond { body["frames_per_second"] = framesPerSecond }
        if let framesDropped { body["frames_dropped"] = framesDropped }
        if let audioConcealmentPct { body["audio_concealment_pct"] = audioConcealmentPct }
        if let freezeCount { body["freeze_count"] = freezeCount }
        if let routeObservation { body["route_observation"] = routeObservation.requestBody }
        return body
    }
}

struct RemoteRTCQualityBatchResult: Decodable, Sendable, Equatable {
    let schemaVersion: String
    let acceptedCount: Int64
    let duplicateCount: Int64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case acceptedCount = "accepted_count"
        case duplicateCount = "duplicate_count"
    }
}

enum RemoteRTCSignalKind: Codable, Sendable, Equatable {
    case offer
    case answer
    case candidate
    case iceComplete
    case iceRestart
    case renegotiate
    case mediaState
    case bye
    case unknown(String)

    var rawValue: String {
        switch self {
        case .offer: return "offer"
        case .answer: return "answer"
        case .candidate: return "candidate"
        case .iceComplete: return "ice_complete"
        case .iceRestart: return "ice_restart"
        case .renegotiate: return "renegotiate"
        case .mediaState: return "media_state"
        case .bye: return "bye"
        case .unknown(let value): return value
        }
    }

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "offer": self = .offer
        case "answer": self = .answer
        case "candidate": self = .candidate
        case "ice_complete": self = .iceComplete
        case "ice_restart": self = .iceRestart
        case "renegotiate": self = .renegotiate
        case "media_state", "media-state": self = .mediaState
        case "bye": self = .bye
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct RemoteRTCSignalEnvelope: Codable, Sendable, Equatable {
    let protocolVersion: String
    let messageID: String
    let seq: Int
    let negotiationID: String
    let callID: String
    let toUID: String
    let toDevice: String
    let kind: RemoteRTCSignalKind
    let data: [String: JSONValue]
    let sentAt: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case messageID = "message_id"
        case seq
        case negotiationID = "negotiation_id"
        case callID = "call_id"
        case toUID = "to_uid"
        case toDevice = "to_device"
        case kind
        case data
        case sentAt = "sent_at"
    }

    init(
        protocolVersion: String = "",
        messageID: String = "",
        seq: Int = 0,
        negotiationID: String = "",
        callID: String = "",
        toUID: String = "",
        toDevice: String = "",
        kind: RemoteRTCSignalKind,
        data: [String: JSONValue] = [:],
        sentAt: String = ""
    ) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.seq = seq
        self.negotiationID = negotiationID
        self.callID = callID
        self.toUID = toUID
        self.toDevice = toDevice
        self.kind = kind
        self.data = data
        self.sentAt = sentAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(String.self, forKey: .protocolVersion) ?? ""
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        negotiationID = try c.decodeIfPresent(String.self, forKey: .negotiationID) ?? ""
        callID = try c.decodeIfPresent(String.self, forKey: .callID) ?? ""
        toUID = try c.decodeIfPresent(String.self, forKey: .toUID) ?? ""
        toDevice = try c.decodeIfPresent(String.self, forKey: .toDevice) ?? ""
        kind = try c.decodeIfPresent(RemoteRTCSignalKind.self, forKey: .kind) ?? .unknown("")
        data = try c.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
        sentAt = try c.decodeIfPresent(String.self, forKey: .sentAt) ?? ""
    }
}

struct RemoteRTCSignalItemsData: Codable, Sendable, Equatable {
    let items: [RemoteRTCSignalItem]
    let nextCursor: String
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    init(items: [RemoteRTCSignalItem] = [], nextCursor: String = "", hasMore: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteRTCSignalItem].self, forKey: .items) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor) ?? ""
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore) ?? false
    }
}

struct RemoteRTCSignalItem: Codable, Sendable, Equatable {
    let serverCursor: String
    let messageID: String
    let seq: Int
    let negotiationID: String
    let callID: String
    let fromUID: String
    let fromDevice: String
    let toUID: String
    let toDevice: String
    let kind: RemoteRTCSignalKind
    let data: [String: JSONValue]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case serverCursor = "server_cursor"
        case messageID = "message_id"
        case seq
        case negotiationID = "negotiation_id"
        case callID = "call_id"
        case fromUID = "from_uid"
        case fromDevice = "from_device"
        case toUID = "to_uid"
        case toDevice = "to_device"
        case kind
        case data
        case createdAt = "created_at"
    }

    init(
        serverCursor: String = "",
        messageID: String = "",
        seq: Int = 0,
        negotiationID: String = "",
        callID: String = "",
        fromUID: String = "",
        fromDevice: String = "",
        toUID: String = "",
        toDevice: String = "",
        kind: RemoteRTCSignalKind,
        data: [String: JSONValue] = [:],
        createdAt: String = ""
    ) {
        self.serverCursor = serverCursor
        self.messageID = messageID
        self.seq = seq
        self.negotiationID = negotiationID
        self.callID = callID
        self.fromUID = fromUID
        self.fromDevice = fromDevice
        self.toUID = toUID
        self.toDevice = toDevice
        self.kind = kind
        self.data = data
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverCursor = try c.decodeIfPresent(String.self, forKey: .serverCursor) ?? ""
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        negotiationID = try c.decodeIfPresent(String.self, forKey: .negotiationID) ?? ""
        callID = try c.decodeIfPresent(String.self, forKey: .callID) ?? ""
        fromUID = try c.decodeIfPresent(String.self, forKey: .fromUID) ?? ""
        fromDevice = try c.decodeIfPresent(String.self, forKey: .fromDevice) ?? ""
        toUID = try c.decodeIfPresent(String.self, forKey: .toUID) ?? ""
        toDevice = try c.decodeIfPresent(String.self, forKey: .toDevice) ?? ""
        kind = try c.decodeIfPresent(RemoteRTCSignalKind.self, forKey: .kind) ?? .unknown("")
        data = try c.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct RemoteRTCSignalPostResult: Decodable, Sendable, Equatable {
    let messageID: String
    let serverCursor: String
    let duplicate: Bool
    let serverReceivedAt: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case serverCursor = "server_cursor"
        case duplicate
        case serverReceivedAt = "server_received_at"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        serverCursor = try c.decodeIfPresent(String.self, forKey: .serverCursor) ?? ""
        duplicate = c.decodeLossyBoolIfPresent(forKey: .duplicate) ?? false
        serverReceivedAt = try c.decodeIfPresent(String.self, forKey: .serverReceivedAt) ?? ""
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt) ?? ""
    }
}

struct RemoteRTCSessionDescriptionSignalData: Codable, Sendable, Equatable {
    let type: String
    let sdp: String

    var isOfferOrAnswer: Bool {
        ["offer", "answer"].contains(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    init(type: String = "", sdp: String = "") {
        self.type = type
        self.sdp = sdp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        sdp = try c.decodeIfPresent(String.self, forKey: .sdp) ?? ""
    }
}

struct RemoteRTCIceCandidateSignalData: Codable, Sendable, Equatable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
    let usernameFragment: String?

    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_mline_index"
        case usernameFragment = "username_fragment"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case sdpMid
        case sdpMLineIndex
        case usernameFragment
    }

    init(candidate: String = "", sdpMid: String? = nil, sdpMLineIndex: Int? = nil, usernameFragment: String? = nil) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.usernameFragment = usernameFragment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        candidate = try c.decodeIfPresent(String.self, forKey: .candidate) ?? ""
        sdpMid = try c.decodeIfPresent(String.self, forKey: .sdpMid)
            ?? legacy.decodeIfPresent(String.self, forKey: .sdpMid)
        sdpMLineIndex = try c.decodeIfPresent(Int.self, forKey: .sdpMLineIndex)
            ?? legacy.decodeIfPresent(Int.self, forKey: .sdpMLineIndex)
        usernameFragment = try c.decodeIfPresent(String.self, forKey: .usernameFragment)
            ?? legacy.decodeIfPresent(String.self, forKey: .usernameFragment)
    }
}

struct RemoteRTCIceCandidatesSignalData: Codable, Sendable, Equatable {
    let candidates: [RemoteRTCIceCandidateSignalData]

    enum CodingKeys: String, CodingKey {
        case candidates
    }

    init(candidates: [RemoteRTCIceCandidateSignalData] = []) {
        self.candidates = candidates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let batch = try c.decodeIfPresent([RemoteRTCIceCandidateSignalData].self, forKey: .candidates) {
            candidates = batch
        } else {
            let single = try RemoteRTCIceCandidateSignalData(from: decoder)
            candidates = single.candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [single]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(candidates, forKey: .candidates)
    }
}

struct RemoteRTCByeSignalData: Codable, Sendable, Equatable {
    let reason: String

    init(reason: String = "") {
        self.reason = reason
    }
}

enum RTCVoiceMediaState: String, Codable, Sendable, Equatable {
    case preparing
    case signaling
    case connecting
    case connected
    case unstable
    case failed
    case closed

    var qualifiesForConnectedAt: Bool {
        self == .connected
    }
}

enum RTCVoiceMediaEvent: String, Codable, Sendable, Equatable {
    case callAccepted
    case roomJoined
    case localTrackReady
    case remoteAudioTrackReady
    case remoteAudioRTPReady
    case localDescriptionSet
    case remoteDescriptionSet
    case iceChecking
    case iceConnected
    case iceCompleted
    case peerConnectionConnected
    case connectionRecovered
    case iceDisconnected
    case iceFailed
    // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：区分本机媒体启动失败与真实 ICE 失败
    case mediaStartFailed
    // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
    case recoveryExhausted
    case closed

    var mediaState: RTCVoiceMediaState {
        switch self {
        case .callAccepted, .roomJoined, .localTrackReady:
            return .preparing
        case .remoteAudioTrackReady, .remoteAudioRTPReady:
            return .connecting
        case .localDescriptionSet, .remoteDescriptionSet:
            return .signaling
        case .iceChecking:
            return .connecting
        case .iceConnected, .iceCompleted, .peerConnectionConnected, .connectionRecovered:
            return .connecting
        case .iceDisconnected:
            return .unstable
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
        case .iceFailed, .mediaStartFailed, .recoveryExhausted:
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            return .failed
        case .closed:
            return .closed
        }
    }

    var qualifiesForConnectedAt: Bool {
        mediaState.qualifiesForConnectedAt
    }
}

struct RemoteRTCCallEventsData: Decodable {
    let events: [RemoteRTCCallEvent]

    enum CodingKeys: String, CodingKey {
        case events
        case items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([RemoteRTCCallEvent].self, forKey: .events)
            ?? c.decodeIfPresent([RemoteRTCCallEvent].self, forKey: .items)
            ?? []
    }
}

struct RemoteRTCCallEvent: Decodable {
    let id: String
    let notificationID: String
    let type: String
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case notificationID = "notification_id"
        case type
        case event
        case eventType = "event_type"
        case callID = "call_id"
        case status
        case callerUID = "caller_uid"
        case calleeUID = "callee_uid"
        case targetUID = "target_uid"
        case roomID = "room_id"
        case channelID = "channel_id"
        case callType = "call_type"
        case requestedMediaMode = "requested_media_mode"
        case mediaMode = "media_mode"
        case stateVersion = "state_version"
        case callerDevice = "caller_device"
        case calleeDevice = "callee_device"
        case acceptedDevice = "accepted_device"
        case callerDeviceID = "caller_device_id"
        case calleeDeviceID = "callee_device_id"
        case acceptedDeviceID = "accepted_device_id"
        case call
        case payload
        case rtcCall = "rtc_call"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        notificationID = try c.decodeIfPresent(String.self, forKey: .notificationID) ?? ""
        let decodedType = try c.decodeIfPresent(String.self, forKey: .type)
            ?? c.decodeIfPresent(String.self, forKey: .event)
            ?? c.decodeIfPresent(String.self, forKey: .eventType)
            ?? ""
        let decodedStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        type = decodedType.isEmpty && !decodedStatus.isEmpty ? "rtc.call.\(decodedStatus)" : decodedType
        var decodedPayload = try c.decodeIfPresent([String: JSONValue].self, forKey: .payload)
            ?? c.decodeIfPresent([String: JSONValue].self, forKey: .rtcCall)
            ?? [:]
        if decodedPayload["call"] == nil,
           let nestedCall = try c.decodeIfPresent([String: JSONValue].self, forKey: .call),
           !nestedCall.isEmpty {
            decodedPayload["call"] = .object(nestedCall)
        }
        func merge(_ value: String?, key: String) {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  decodedPayload[key] == nil else { return }
            decodedPayload[key] = .string(value)
        }
        merge(id, key: "event_id")
        merge(type, key: "event")
        merge(try c.decodeIfPresent(String.self, forKey: .callID), key: "call_id")
        merge(decodedStatus, key: "status")
        merge(try c.decodeIfPresent(String.self, forKey: .callerUID), key: "caller_uid")
        merge(try c.decodeIfPresent(String.self, forKey: .calleeUID), key: "callee_uid")
        merge(try c.decodeIfPresent(String.self, forKey: .targetUID), key: "target_uid")
        merge(try c.decodeIfPresent(String.self, forKey: .roomID), key: "room_id")
        merge(try c.decodeIfPresent(String.self, forKey: .channelID), key: "channel_id")
        func mergeValue(_ codingKey: CodingKeys, key: String) throws {
            guard decodedPayload[key] == nil,
                  let value = try c.decodeIfPresent(JSONValue.self, forKey: codingKey) else { return }
            decodedPayload[key] = value
        }
        try mergeValue(.callType, key: "call_type")
        try mergeValue(.requestedMediaMode, key: "requested_media_mode")
        try mergeValue(.mediaMode, key: "media_mode")
        try mergeValue(.stateVersion, key: "state_version")
        try mergeValue(.callerDevice, key: "caller_device")
        try mergeValue(.calleeDevice, key: "callee_device")
        try mergeValue(.acceptedDevice, key: "accepted_device")
        try mergeValue(.callerDeviceID, key: "caller_device_id")
        try mergeValue(.calleeDeviceID, key: "callee_device_id")
        try mergeValue(.acceptedDeviceID, key: "accepted_device_id")
        payload = decodedPayload
    }
}

struct RTCVoIPPushPayload: Equatable, Sendable {
    let kind: String
    let event: String
    let callID: String
    let roomID: String
    let tenantID: String
    let callerUID: String
    let calleeUID: String
    let callerName: String
    let calleeName: String
    let callerAvatarURL: String
    let callerAvatarVersion: String
    let callerAvatarUpdatedAt: String
    let calleeAvatarURL: String
    let calleeAvatarVersion: String
    let calleeAvatarUpdatedAt: String
    let callerProfile: RemoteRTCParticipantProfile?
    let calleeProfile: RemoteRTCParticipantProfile?
    let callType: String
    let provider: String
    let issuedAt: String
    let expiresAt: String

    init?(_ userInfo: [AnyHashable: Any]) {
        var dictionary: [String: Any] = [:]
        userInfo.forEach { key, value in
            dictionary[String(describing: key)] = value
        }
        self.init(dictionary: dictionary)
    }

    init?(dictionary: [String: Any]) {
        let dictionary = Self.normalizedVoIPPayloadDictionary(dictionary)
        let decodedKind = Self.firstString(dictionary, keys: ["kind", "type"]).lowercased()
        guard decodedKind == "rtc_call" else { return nil }
        let decodedCallID = Self.firstString(dictionary, keys: ["call_id", "callID", "id"])
        guard !decodedCallID.isEmpty else { return nil }

        kind = decodedKind
        event = Self.firstString(dictionary, keys: ["event", "status"]).lowercased()
        callID = decodedCallID
        roomID = Self.firstString(dictionary, keys: ["room_id", "roomID"])
        tenantID = Self.firstString(dictionary, keys: ["tenant_id", "tenantID"])
        callerUID = Self.firstString(dictionary, keys: ["caller_uid", "callerUID", "from_uid", "fromUID"])
        calleeUID = Self.firstString(dictionary, keys: ["callee_uid", "calleeUID", "target_uid", "targetUID"])
        callerProfile = RemoteRTCParticipantProfile.from(
            dictionary: Self.dictionaryValue(dictionary["caller_profile"])
                ?? Self.dictionaryValue(dictionary["callerProfile"])
                ?? Self.dictionaryValue(dictionary["caller"])
                ?? Self.dictionaryValue(dictionary["from_profile"])
        )
        calleeProfile = RemoteRTCParticipantProfile.from(
            dictionary: Self.dictionaryValue(dictionary["callee_profile"])
                ?? Self.dictionaryValue(dictionary["calleeProfile"])
                ?? Self.dictionaryValue(dictionary["callee"])
                ?? Self.dictionaryValue(dictionary["target_profile"])
        )
        callerName = Self.fallbackString(Self.firstString(dictionary, keys: ["caller_name", "callerName", "from_name", "fromName"]), callerProfile?.displayName ?? "")
        calleeName = Self.fallbackString(Self.firstString(dictionary, keys: ["callee_name", "calleeName", "target_name", "targetName"]), calleeProfile?.displayName ?? "")
        callerAvatarURL = Self.fallbackString(Self.firstString(dictionary, keys: ["caller_avatar", "caller_avatar_url", "callerAvatar", "callerAvatarUrl", "from_avatar", "fromAvatar"]), callerProfile?.avatar ?? "")
        callerAvatarVersion = Self.fallbackString(Self.firstString(dictionary, keys: ["caller_avatar_version", "callerAvatarVersion", "from_avatar_version", "fromAvatarVersion"]), callerProfile?.avatarVersion ?? "")
        callerAvatarUpdatedAt = Self.fallbackString(Self.firstString(dictionary, keys: ["caller_avatar_updated_at", "callerAvatarUpdatedAt", "from_avatar_updated_at", "fromAvatarUpdatedAt"]), callerProfile?.avatarUpdatedAt ?? "")
        calleeAvatarURL = Self.fallbackString(Self.firstString(dictionary, keys: ["callee_avatar", "callee_avatar_url", "calleeAvatar", "calleeAvatarUrl", "target_avatar", "target_avatar_url", "targetAvatar", "targetAvatarUrl"]), calleeProfile?.avatar ?? "")
        calleeAvatarVersion = Self.fallbackString(Self.firstString(dictionary, keys: ["callee_avatar_version", "calleeAvatarVersion", "target_avatar_version", "targetAvatarVersion"]), calleeProfile?.avatarVersion ?? "")
        calleeAvatarUpdatedAt = Self.fallbackString(Self.firstString(dictionary, keys: ["callee_avatar_updated_at", "calleeAvatarUpdatedAt", "target_avatar_updated_at", "targetAvatarUpdatedAt"]), calleeProfile?.avatarUpdatedAt ?? "")
        callType = Self.firstString(dictionary, keys: ["call_type", "callType"]).lowercased()
        provider = Self.firstString(dictionary, keys: ["provider"]).lowercased()
        issuedAt = Self.firstString(dictionary, keys: ["issued_at", "issuedAt"])
        expiresAt = Self.firstString(dictionary, keys: ["expires_at", "expiresAt"])
    }

    var isRinging: Bool {
        event == "ringing"
    }

    var isPushKitEligibleRinging: Bool {
        kind == "rtc_call" && event == "ringing" && !callID.isEmpty
    }

    func deliveryFreshness(now: Date = Date()) -> RTCVoIPPushDeliveryFreshness {
        let formatter = ISO8601DateFormatter()
        guard !expiresAt.isEmpty, let expiry = formatter.date(from: expiresAt) else {
            return .unknown
        }
        if !issuedAt.isEmpty,
           let issued = formatter.date(from: issuedAt),
           expiry <= issued {
            return .invalidWindow
        }
        return expiry <= now ? .expired : .fresh
    }

    var isTerminal: Bool {
        ["cancel", "canceled", "ended", "timeout", "timed_out", "answered_elsewhere"].contains(event)
    }

    var normalizedTerminalEvent: String {
        switch event {
        case "cancel":
            return "canceled"
        case "timeout":
            return "timed_out"
        default:
            return event
        }
    }

    var deterministicUUID: UUID {
        Self.deterministicUUIDForCallKit(callID)
    }

    static func deterministicUUIDForCallKit(_ value: String) -> UUID {
        deterministicUUID(for: value)
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] {
                return stringValue(value)
            }
        }
        return ""
    }

    private static func fallbackString(_ value: String, _ fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    private static func normalizedVoIPPayloadDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        guard var nested = dictionaryValue(dictionary["rtc_call"]) ?? dictionaryValue(dictionary["rtcCall"]) else {
            return dictionary
        }
        for (key, value) in dictionary where key != "aps" && key != "rtc_call" && key != "rtcCall" {
            if nested[key] == nil {
                nested[key] = value
            }
        }
        return nested
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            dictionary.forEach { key, value in
                out[String(describing: key)] = value
            }
            return out
        }
        return nil
    }

    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func deterministicUUID(for value: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x84222325cbf29ce4
        for byte in value.utf8 {
            h1 ^= UInt64(byte)
            h1 = h1 &* 0x100000001b3
            h2 ^= UInt64(byte) &+ 0x9e3779b97f4a7c15
            h2 = h2 &* 0x100000001b3
        }
        var bytes = withUnsafeBytes(of: h1.bigEndian, Array.init)
        bytes.append(contentsOf: withUnsafeBytes(of: h2.bigEndian, Array.init))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuidString = bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress!).uuidString
        }
        return UUID(uuidString: uuidString) ?? UUID()
    }
}

enum RTCVoIPPushDeliveryFreshness: Equatable, Sendable {
    case unknown
    case fresh
    case expired
    case invalidWindow
}

struct RemoteAvatarCommitData: Decodable {
    let profile: RemoteAvatarProfile
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case profile
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatar
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(RemoteAvatarProfile.self, forKey: .profile) ?? RemoteAvatarProfile()
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? c.decodeIfPresent(String.self, forKey: .avatar)
            ?? profile.avatar
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? profile.avatarVersion
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? profile.avatarUpdatedAt
    }
}

struct RemoteAvatarProfile: Decodable {
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    init(avatar: String = "", avatarVersion: String = "", avatarUpdatedAt: String = "") {
        self.avatar = avatar
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
    }
}

struct RemoteCaptchaEntryStatus: Decodable {
    let entries: [RemoteCaptchaEntry]

    enum CodingKeys: String, CodingKey {
        case entries
        case items
        case entry
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let entries = try? c.decodeIfPresent([RemoteCaptchaEntry].self, forKey: .entries) {
            self.entries = entries
        } else if let items = try? c.decodeIfPresent([RemoteCaptchaEntry].self, forKey: .items) {
            self.entries = items
        } else if let entry = try? c.decodeIfPresent(RemoteCaptchaEntry.self, forKey: .entry) {
            self.entries = [entry]
        } else {
            self.entries = []
        }
    }

    func preferredEntry(scene: String, channel: String) -> RemoteCaptchaEntry? {
        let normalizedScene = scene.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedChannel = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first {
            $0.normalizedScene == normalizedScene && $0.normalizedChannel == normalizedChannel
        } ?? entries.first {
            $0.normalizedChannel == normalizedChannel
        } ?? entries.first
    }
}

struct RemoteCaptchaEntry: Decodable {
    let enabled: Bool
    let available: Bool
    let required: Bool
    let source: String
    let provider: String
    let scene: String
    let channel: String
    let templateConfigured: Bool?
    let secretConfigured: Bool?
    let ttlSeconds: Int?
    let rateLimit: Int?
    let resource: String
    let configSummary: String
    let reasonCode: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case available
        case required
        case source
        case provider
        case scene
        case channel
        case templateConfigured = "template_configured"
        case secretConfigured = "secret_configured"
        case ttlSeconds = "ttl_seconds"
        case rateLimit = "rate_limit"
        case resource
        case configSummary = "config_summary"
        case reasonCode = "reason_code"
        case reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decodeLossyBoolIfPresent(forKey: .enabled) ?? false
        available = c.decodeLossyBoolIfPresent(forKey: .available) ?? false
        required = c.decodeLossyBoolIfPresent(forKey: .required) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        templateConfigured = c.decodeLossyBoolIfPresent(forKey: .templateConfigured)
        secretConfigured = c.decodeLossyBoolIfPresent(forKey: .secretConfigured)
        ttlSeconds = c.decodeLossyIntIfPresent(forKey: .ttlSeconds)
        rateLimit = c.decodeLossyIntIfPresent(forKey: .rateLimit)
        resource = (try? c.decodeIfPresent(String.self, forKey: .resource)) ?? ""
        configSummary = (try? c.decodeIfPresent(String.self, forKey: .configSummary)) ?? ""
        reasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    var normalizedScene: String {
        scene.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedChannel: String {
        channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var unavailableMessage: String {
        captchaUserMessage(code: reasonCode, reason: reason, fallback: "验证码服务暂不可用")
    }
}

struct RemoteSlideCaptchaConfig: Decodable {
    let enabled: Bool
    let available: Bool
    let required: Bool
    let provider: String
    let surface: String
    let appID: String
    let clientKey: String
    let scene: String
    let tokenTTLSeconds: Int
    let sdkURL: String
    let reasonCode: String
    let reason: String
    let extra: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case enabled
        case available
        case required
        case provider
        case surface
        case appID = "app_id"
        case clientKey = "client_key"
        case scene
        case tokenTTLSeconds = "token_ttl_seconds"
        case sdkURL = "sdk_url"
        case reasonCode = "reason_code"
        case reason
        case extra
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decodeLossyBoolIfPresent(forKey: .enabled) ?? false
        available = c.decodeLossyBoolIfPresent(forKey: .available) ?? enabled
        required = c.decodeLossyBoolIfPresent(forKey: .required) ?? enabled
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        surface = try c.decodeIfPresent(String.self, forKey: .surface) ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        clientKey = try c.decodeIfPresent(String.self, forKey: .clientKey) ?? ""
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
        tokenTTLSeconds = try c.decodeIfPresent(Int.self, forKey: .tokenTTLSeconds) ?? 0
        sdkURL = try c.decodeIfPresent(String.self, forKey: .sdkURL) ?? ""
        reasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        extra = try c.decodeIfPresent([String: JSONValue].self, forKey: .extra) ?? [:]
    }

    var unavailableMessage: String {
        captchaUserMessage(code: reasonCode, reason: reason, fallback: "滑动验证暂不可用")
    }
}

struct RemoteSlideCaptchaChallenge: Decodable {
    let provider: String
    let challengeID: String
    let backgroundImage: String
    let pieceImage: String
    let pieceY: Int
    let width: Int
    let height: Int
    let pieceSize: Int
    let challengeTTLSeconds: Int
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case provider
        case challengeID = "challenge_id"
        case challengeIDCamel = "challengeId"
        case backgroundImage = "background_image"
        case backgroundImageCamel = "backgroundImage"
        case pieceImage = "piece_image"
        case pieceImageCamel = "pieceImage"
        case pieceY = "piece_y"
        case pieceYCamel = "pieceY"
        case width
        case height
        case pieceSize = "piece_size"
        case pieceSizeCamel = "pieceSize"
        case challengeTTLSeconds = "challenge_ttl_seconds"
        case challengeTTLSecondsCamel = "challengeTTLSeconds"
        case expiresAt = "expires_at"
        case expiresAtCamel = "expiresAt"
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        provider = try root.decodeIfPresent(String.self, forKey: .provider) ?? "self_hosted_slide"
        challengeID = try root.decodeIfPresent(String.self, forKey: .challengeID)
            ?? root.decodeIfPresent(String.self, forKey: .challengeIDCamel)
            ?? ""
        backgroundImage = try root.decodeIfPresent(String.self, forKey: .backgroundImage)
            ?? root.decodeIfPresent(String.self, forKey: .backgroundImageCamel)
            ?? ""
        pieceImage = try root.decodeIfPresent(String.self, forKey: .pieceImage)
            ?? root.decodeIfPresent(String.self, forKey: .pieceImageCamel)
            ?? ""
        pieceY = try root.decodeIfPresent(Int.self, forKey: .pieceY)
            ?? root.decodeIfPresent(Int.self, forKey: .pieceYCamel)
            ?? 0
        width = try root.decodeIfPresent(Int.self, forKey: .width) ?? 320
        height = try root.decodeIfPresent(Int.self, forKey: .height) ?? 160
        pieceSize = try root.decodeIfPresent(Int.self, forKey: .pieceSize)
            ?? root.decodeIfPresent(Int.self, forKey: .pieceSizeCamel)
            ?? 48
        challengeTTLSeconds = try root.decodeIfPresent(Int.self, forKey: .challengeTTLSeconds)
            ?? root.decodeIfPresent(Int.self, forKey: .challengeTTLSecondsCamel)
            ?? 120
        expiresAt = try root.decodeIfPresent(String.self, forKey: .expiresAt)
            ?? root.decodeIfPresent(String.self, forKey: .expiresAtCamel)
            ?? ""
    }
}

struct SlideCaptchaTicket: @unchecked Sendable {
    let ticket: String
    let randstr: String
    let challengeID: String
    let lotNumber: String
    let captchaOutput: String
    let passToken: String
    let genTime: String
    let extra: [String: Any]
}

struct SlideCaptchaVerifyRequest {
    let scene: String
    let body: [String: Any]

    init(scene: String, config: RemoteSlideCaptchaConfig, ticket: SlideCaptchaTicket) {
        self.scene = scene
        body = [
            "scene": scene,
            "provider": config.provider.isEmpty ? "development" : config.provider,
            "ticket": ticket.ticket,
            "randstr": ticket.randstr,
            "challenge_id": ticket.challengeID,
            "lot_number": ticket.lotNumber,
            "captcha_output": ticket.captchaOutput,
            "pass_token": ticket.passToken,
            "gen_time": ticket.genTime,
            "extra": config.extra.mapValues(\.anyValue).merging(ticket.extra) { _, new in new }
        ]
    }
}

struct RemoteSlideCaptchaVerifyResult: Decodable {
    let slideToken: String

    enum CodingKeys: String, CodingKey {
        case slideToken = "slide_token"
        case camelSlideToken = "slideToken"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slideToken = try c.decodeIfPresent(String.self, forKey: .slideToken)
            ?? c.decodeIfPresent(String.self, forKey: .camelSlideToken)
            ?? ""
    }
}

enum IMSessionLifetimeMode: String, Codable, Equatable, Sendable {
    case absolute
    case untilRevoked = "until_revoked"

    static func authoritativeValue(_ raw: String?) -> IMSessionLifetimeMode {
        guard let raw else { return .absolute }
        return IMSessionLifetimeMode(
            rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) ?? .absolute
    }
}

struct RemoteAuthSession: Decodable {
    let sessionID: String
    let refreshToken: String
    let refreshExpiresAt: Int64
    let clientType: String
    let deviceID: String
    let appID: String
    let tokenType: String
    let tenantID: String
    let rotated: Bool
    let requiresKeychain: Bool
    let authVersion: Int64
    let sessionGeneration: Int64
    let accessExpiresAt: Int64
    let lifetimeMode: IMSessionLifetimeMode

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionIDCamel = "sessionId"
        case refreshToken = "refresh_token"
        case refreshTokenCamel = "refreshToken"
        case refreshExpiresAt = "refresh_expires_at"
        case refreshExpiresAtCamel = "refreshExpiresAt"
        case expiresAt = "expires_at"
        case clientType = "client_type"
        case clientTypeCamel = "clientType"
        case deviceID = "device_id"
        case deviceIDCamel = "deviceId"
        case appID = "app_id"
        case appIDCamel = "appId"
        case tokenType = "token_type"
        case tokenTypeCamel = "tokenType"
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case rotated
        case requiresKeychain = "requires_keychain"
        case requiresKeychainCamel = "requiresKeychain"
        case authVersion = "auth_version"
        case authVersionCamel = "authVersion"
        case sessionGeneration = "session_generation"
        case sessionGenerationCamel = "sessionGeneration"
        case accessExpiresAt = "access_expires_at"
        case accessExpiresAtCamel = "accessExpiresAt"
        case lifetimeMode = "lifetime_mode"
        case lifetimeModeCamel = "lifetimeMode"
    }

    var isUsable: Bool {
        !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedTokenType: String {
        tokenType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
            ?? c.decodeIfPresent(String.self, forKey: .sessionIDCamel)
            ?? ""
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
            ?? c.decodeIfPresent(String.self, forKey: .refreshTokenCamel)
            ?? ""
        refreshExpiresAt = c.decodeLossyInt64IfPresent(forKey: .refreshExpiresAt)
            ?? c.decodeLossyInt64IfPresent(forKey: .refreshExpiresAtCamel)
            ?? c.decodeLossyInt64IfPresent(forKey: .expiresAt)
            ?? 0
        clientType = try c.decodeIfPresent(String.self, forKey: .clientType)
            ?? c.decodeIfPresent(String.self, forKey: .clientTypeCamel)
            ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
            ?? c.decodeIfPresent(String.self, forKey: .deviceIDCamel)
            ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType)
            ?? c.decodeIfPresent(String.self, forKey: .tokenTypeCamel)
            ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        rotated = c.decodeLossyBoolIfPresent(forKey: .rotated) ?? false
        requiresKeychain = c.decodeLossyBoolIfPresent(forKey: .requiresKeychain)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresKeychainCamel)
            ?? false
        authVersion = c.decodeLossyInt64IfPresent(forKey: .authVersion)
            ?? c.decodeLossyInt64IfPresent(forKey: .authVersionCamel)
            ?? 0
        sessionGeneration = c.decodeLossyInt64IfPresent(forKey: .sessionGeneration)
            ?? c.decodeLossyInt64IfPresent(forKey: .sessionGenerationCamel)
            ?? 0
        accessExpiresAt = c.decodeLossyInt64IfPresent(forKey: .accessExpiresAt)
            ?? c.decodeLossyInt64IfPresent(forKey: .accessExpiresAtCamel)
            ?? 0
        lifetimeMode = .authoritativeValue(
            try c.decodeIfPresent(String.self, forKey: .lifetimeMode)
                ?? c.decodeIfPresent(String.self, forKey: .lifetimeModeCamel)
        )
    }
}

struct RemoteTenantIMSessionRefreshResult: Decodable, Equatable {
    let imToken: String
    let expiresAt: Int64
    let imUID: String
    let tenantID: String
    let appID: String
    let deviceID: String
    let tokenType: String
    let authVersion: Int64
    let sessionGeneration: Int64

    enum CodingKeys: String, CodingKey {
        case imToken = "im_token"
        case token
        case expiresAt = "expires_at"
        case accessExpiresAt = "access_expires_at"
        case imUID = "im_uid"
        case uid
        case tenantID = "tenant_id"
        case appID = "app_id"
        case deviceID = "device_id"
        case tokenType = "token_type"
        case session
        case authSession = "auth_session"
        case authVersion = "auth_version"
        case sessionGeneration = "session_generation"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let session = try c.decodeIfPresent(RemoteTenantIMSessionRefreshResult.SessionFields.self, forKey: .session)
        let authSession = try c.decodeIfPresent(RemoteTenantIMSessionRefreshResult.AuthSessionFields.self, forKey: .authSession)

        imToken = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .imToken),
            try c.decodeIfPresent(String.self, forKey: .token),
            session?.imToken,
            session?.token
        )
        expiresAt = c.decodeLossyInt64IfPresent(forKey: .expiresAt)
            ?? c.decodeLossyInt64IfPresent(forKey: .accessExpiresAt)
            ?? session?.expiresAt
            ?? session?.accessExpiresAt
            ?? authSession?.accessExpiresAt
            ?? 0
        imUID = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .imUID),
            try c.decodeIfPresent(String.self, forKey: .uid),
            session?.imUID,
            session?.uid
        )
        tenantID = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .tenantID),
            session?.tenantID,
            authSession?.tenantID
        )
        appID = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .appID),
            session?.appID,
            authSession?.appID
        )
        deviceID = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .deviceID),
            session?.deviceID,
            authSession?.deviceID
        )
        tokenType = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .tokenType),
            session?.tokenType,
            authSession?.tokenType
        )
        authVersion = c.decodeLossyInt64IfPresent(forKey: .authVersion)
            ?? session?.authVersion
            ?? authSession?.authVersion
            ?? 0
        sessionGeneration = c.decodeLossyInt64IfPresent(forKey: .sessionGeneration)
            ?? session?.sessionGeneration
            ?? authSession?.sessionGeneration
            ?? 0
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private struct SessionFields: Decodable, Equatable {
        let imToken: String
        let token: String
        let expiresAt: Int64
        let accessExpiresAt: Int64
        let imUID: String
        let uid: String
        let tenantID: String
        let appID: String
        let deviceID: String
        let tokenType: String
        let authVersion: Int64
        let sessionGeneration: Int64

        enum CodingKeys: String, CodingKey {
            case imToken = "im_token"
            case token
            case expiresAt = "expires_at"
            case accessExpiresAt = "access_expires_at"
            case imUID = "im_uid"
            case uid
            case tenantID = "tenant_id"
            case appID = "app_id"
            case deviceID = "device_id"
            case tokenType = "token_type"
            case authVersion = "auth_version"
            case sessionGeneration = "session_generation"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            imToken = try c.decodeIfPresent(String.self, forKey: .imToken) ?? ""
            token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
            expiresAt = c.decodeLossyInt64IfPresent(forKey: .expiresAt) ?? 0
            accessExpiresAt = c.decodeLossyInt64IfPresent(forKey: .accessExpiresAt) ?? 0
            imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
            uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
            tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID) ?? ""
            appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
            deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
            tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? ""
            authVersion = c.decodeLossyInt64IfPresent(forKey: .authVersion) ?? 0
            sessionGeneration = c.decodeLossyInt64IfPresent(forKey: .sessionGeneration) ?? 0
        }
    }

    private struct AuthSessionFields: Decodable, Equatable {
        let tokenType: String
        let tenantID: String
        let appID: String
        let deviceID: String
        let accessExpiresAt: Int64
        let authVersion: Int64
        let sessionGeneration: Int64

        enum CodingKeys: String, CodingKey {
            case tokenType = "token_type"
            case tenantID = "tenant_id"
            case appID = "app_id"
            case deviceID = "device_id"
            case accessExpiresAt = "access_expires_at"
            case authVersion = "auth_version"
            case sessionGeneration = "session_generation"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? ""
            tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID) ?? ""
            appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
            deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
            accessExpiresAt = c.decodeLossyInt64IfPresent(forKey: .accessExpiresAt) ?? 0
            authVersion = c.decodeLossyInt64IfPresent(forKey: .authVersion) ?? 0
            sessionGeneration = c.decodeLossyInt64IfPresent(forKey: .sessionGeneration) ?? 0
        }
    }
}

struct RemoteTenantLoginData: Decodable {
    let account: RemoteAccount?
    let userID: String
    let accountID: String
    let platformToken: String
    let authSession: RemoteAuthSession?
    let tenant: RemoteTenantProfile?
    let user: RemoteIMUser?
    let role: String
    let session: RemoteIMSession?
    let requiresWorkspaceSelection: Bool
    let canDirectEnter: Bool
    let autoEnteredWorkspaceID: String
    let workspaces: [RemoteWorkspaceTenant]
    let defaultWorkspaceID: String
    let defaultWorkspace: RemoteWorkspaceTenant?
    let autoEnterDefaultWorkspace: Bool
    let defaultWorkspaceValid: Bool?
    let defaultWorkspaceUnavailable: Bool
    let defaultWorkspaceReason: String
    let entryStatus: String
    let pendingEntryTenantID: String
    let pendingApprovalCount: Int
    let runtimeConfig: RemoteTenantEnterRuntimeConfig?

    enum CodingKeys: String, CodingKey {
        case account
        case userID = "user_id"
        case accountID = "account_id"
        case platformToken = "platform_token"
        case authSession = "auth_session"
        case tenant
        case user
        case role
        case session
        case requiresWorkspaceSelection = "requires_workspace_selection"
        case canDirectEnter = "can_direct_enter"
        case autoEnteredWorkspaceID = "auto_entered_workspace_id"
        case workspaces
        case defaultWorkspaceID = "default_workspace_id"
        case defaultWorkspaceIDCamel = "defaultWorkspaceId"
        case defaultCompanyID = "default_company_id"
        case defaultCompanyIDCamel = "defaultCompanyId"
        case defaultTenantID = "default_tenant_id"
        case defaultTenantIDCamel = "defaultTenantId"
        case defaultWorkspace = "default_workspace"
        case defaultCompany = "default_company"
        case defaultTenant = "default_tenant"
        case autoEnterDefaultCompany = "auto_enter_default_company"
        case autoEnterDefaultCompanyCamel = "autoEnterDefaultCompany"
        case autoEnterDefaultWorkspace = "auto_enter_default_workspace"
        case autoEnterDefaultWorkspaceCamel = "autoEnterDefaultWorkspace"
        case autoEnterDefaultTenant = "auto_enter_default_tenant"
        case autoEnterDefaultTenantCamel = "autoEnterDefaultTenant"
        case defaultCompanyValid = "default_company_valid"
        case defaultCompanyValidCamel = "defaultCompanyValid"
        case defaultWorkspaceValid = "default_workspace_valid"
        case defaultWorkspaceValidCamel = "defaultWorkspaceValid"
        case defaultTenantValid = "default_tenant_valid"
        case defaultTenantValidCamel = "defaultTenantValid"
        case defaultWorkspaceUnavailable = "default_workspace_unavailable"
        case defaultCompanyUnavailable = "default_company_unavailable"
        case defaultTenantUnavailable = "default_tenant_unavailable"
        case defaultWorkspaceReason = "default_workspace_reason"
        case defaultWorkspaceReasonCamel = "defaultWorkspaceReason"
        case defaultCompanyInvalidReason = "default_company_invalid_reason"
        case defaultCompanyInvalidReasonCamel = "defaultCompanyInvalidReason"
        case defaultWorkspaceInvalidReason = "default_workspace_invalid_reason"
        case defaultWorkspaceInvalidReasonCamel = "defaultWorkspaceInvalidReason"
        case defaultTenantInvalidReason = "default_tenant_invalid_reason"
        case defaultTenantInvalidReasonCamel = "defaultTenantInvalidReason"
        case defaultCompanyReason = "default_company_reason"
        case defaultCompanyReasonCamel = "defaultCompanyReason"
        case defaultTenantReason = "default_tenant_reason"
        case defaultTenantReasonCamel = "defaultTenantReason"
        case entryStatus = "entry_status"
        case entryStatusCamel = "entryStatus"
        case pendingEntryTenantID = "pending_entry_tenant_id"
        case pendingEntryTenantIDCamel = "pendingEntryTenantId"
        case pendingApprovalCount = "pending_approval_count"
        case pendingApprovalCountCamel = "pendingApprovalCount"
        case runtimeConfig = "runtime_config"
        case runtimeConfigCamel = "runtimeConfig"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decodeIfPresent(RemoteAccount.self, forKey: .account)
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        platformToken = try c.decodeIfPresent(String.self, forKey: .platformToken) ?? ""
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : nil)
        let sessionPayload = try c.decodeIfPresent(RemoteTenantLoginSessionPayload.self, forKey: .session)
        tenant = try c.decodeIfPresent(RemoteTenantProfile.self, forKey: .tenant)
            ?? sessionPayload?.tenant
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? sessionPayload?.user
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        session = sessionPayload?.session
        requiresWorkspaceSelection = c.decodeLossyBoolIfPresent(forKey: .requiresWorkspaceSelection) ?? false
        canDirectEnter = c.decodeLossyBoolIfPresent(forKey: .canDirectEnter) ?? true
        autoEnteredWorkspaceID = try c.decodeIfPresent(String.self, forKey: .autoEnteredWorkspaceID) ?? ""
        workspaces = try c.decodeIfPresent([RemoteWorkspaceTenant].self, forKey: .workspaces) ?? []
        defaultWorkspaceID = try c.decodeIfPresent(String.self, forKey: .defaultWorkspaceID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantIDCamel)
            ?? ""
        defaultWorkspace = try c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultWorkspace)
            ?? c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultCompany)
            ?? c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultTenant)
        autoEnterDefaultWorkspace = c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultCompany)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultCompanyCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultWorkspace)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultWorkspaceCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultTenant)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultTenantCamel)
            ?? false
        defaultWorkspaceValid = c.decodeLossyBoolIfPresent(forKey: .defaultCompanyValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultCompanyValidCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceValidCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantValidCamel)
        let explicitUnavailable = c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceUnavailable)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultCompanyUnavailable)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantUnavailable)
        defaultWorkspaceUnavailable = explicitUnavailable ?? (defaultWorkspaceValid == false)
        defaultWorkspaceReason = try c.decodeIfPresent(String.self, forKey: .defaultWorkspaceReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantReasonCamel)
            ?? ""
        entryStatus = try c.decodeIfPresent(String.self, forKey: .entryStatus)
            ?? c.decodeIfPresent(String.self, forKey: .entryStatusCamel)
            ?? ""
        pendingEntryTenantID = try c.decodeIfPresent(String.self, forKey: .pendingEntryTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .pendingEntryTenantIDCamel)
            ?? ""
        pendingApprovalCount = c.decodeLossyIntIfPresent(forKey: .pendingApprovalCount)
            ?? c.decodeLossyIntIfPresent(forKey: .pendingApprovalCountCamel)
            ?? 0
        runtimeConfig = try c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfig)
            ?? c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfigCamel)
    }
}

struct RemoteTenantLoginSessionPayload: Decodable {
    let session: RemoteIMSession
    let tenant: RemoteTenantProfile?
    let user: RemoteIMUser?

    enum CodingKeys: String, CodingKey {
        case tenant
        case user
        case member
    }

    init(from decoder: Decoder) throws {
        session = try RemoteIMSession(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decodeIfPresent(RemoteTenantProfile.self, forKey: .tenant)
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? c.decodeIfPresent(RemoteIMUser.self, forKey: .member)
    }
}

struct RemoteIMUser: Decodable {
    let tenantID: String
    let imUID: String
    let userID: String
    let username: String
    let accountID: String
    let nickname: String
    let userRevision: Int64?
    let identityGeneration: Int64?
    let phone: String
    let phoneVerified: Bool
    let phoneBindingKnown: Bool
    let realNameVerified: Bool
    let realNameStatus: String
    let status: String
    let presenceStatus: String
    let online: Bool
    let onlineKnown: Bool
    let lastSeenAt: String
    let role: String
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let departmentName: String
    let departmentPath: [String]
    let departmentPathNames: [String]

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantID"
        case imUID = "im_uid"
        case userID = "user_id"
        case username
        case accountID = "account_id"
        case nickname
        case userRevision = "user_revision"
        case userRevisionCamel = "userRevision"
        case identityGeneration = "identity_generation"
        case identityGenerationCamel = "identityGeneration"
        case phone
        case phoneMasked = "phone_masked"
        case phoneVerified = "phone_verified"
        case phoneVerifiedAt = "phone_verified_at"
        case phoneBound = "phone_bound"
        case mobileVerified = "mobile_verified"
        case realNameVerified = "real_name_verified"
        case realNameStatus = "real_name_status"
        case kycStatus = "kyc_status"
        case kyc
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case role
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        userRevision = c.decodeLossyInt64IfPresent(forKey: .userRevision)
            ?? c.decodeLossyInt64IfPresent(forKey: .userRevisionCamel)
        identityGeneration = c.decodeLossyInt64IfPresent(forKey: .identityGeneration)
            ?? c.decodeLossyInt64IfPresent(forKey: .identityGenerationCamel)
        phone = try c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? c.decodeIfPresent(String.self, forKey: .phone)
            ?? ""
        let verifiedAt = try c.decodeIfPresent(String.self, forKey: .phoneVerifiedAt) ?? ""
        let explicitPhoneVerified = decodeFlexibleBoolIfPresent(c, keys: [.phoneVerified, .phoneBound, .mobileVerified])
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        phoneVerified = explicitPhoneVerified
            ?? (!verifiedAt.isEmpty || !normalizedPhone.isEmpty)
        phoneBindingKnown = explicitPhoneVerified != nil || !verifiedAt.isEmpty || !normalizedPhone.isEmpty
        realNameStatus = try c.decodeIfPresent(String.self, forKey: .realNameStatus)
            ?? c.decodeIfPresent(String.self, forKey: .kycStatus)
            ?? c.decodeIfPresent(String.self, forKey: .kyc)
            ?? ""
        realNameVerified = decodeFlexibleBool(c, keys: [.realNameVerified])
            || ["verified", "approved", "passed", "success", "认证通过", "已认证"].contains(realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        presenceStatus = try c.decodeIfPresent(String.self, forKey: .presenceStatus) ?? ""
        let decodedOnline = c.decodeLossyBoolIfPresent(forKey: .online)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
        online = decodedOnline ?? false
        onlineKnown = decodedOnline != nil
        lastSeenAt = [
            try c.decodeIfPresent(String.self, forKey: .lastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAt),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAtCamel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        departmentName = try c.decodeIfPresent(String.self, forKey: .departmentName)
            ?? c.decodeIfPresent(String.self, forKey: .departmentNameCamel)
            ?? ""
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
    }
}

struct RemoteIMSessionIdentity: Equatable {
    let appID: String
    let deviceID: String
    let tenantID: String
}

struct RemoteIMSession: Decodable {
    let imUID: String
    let appID: String
    let deviceID: String
    let imToken: String
    let expiresAt: Int64
    let authSession: RemoteAuthSession?

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case uid
        case appID = "app_id"
        case deviceID = "device_id"
        case imToken = "im_token"
        case token
        case expiresAt = "expires_at"
        case authSession = "auth_session"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .uid)
            ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
            ?? c.decodeIfPresent(String.self, forKey: .token)
            ?? ""
        expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? 0
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : nil)
    }

    func effectiveIdentity(tenantID: String) -> RemoteIMSessionIdentity? {
        let topLevelTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let effectiveAppID = Self.resolveIdentityField(
            topLevel: appID,
            nested: authSession?.appID
        ),
        let effectiveDeviceID = Self.resolveIdentityField(
            topLevel: deviceID,
            nested: authSession?.deviceID
        ),
        let effectiveTenantID = Self.resolveIdentityField(
            topLevel: topLevelTenantID,
            nested: authSession?.tenantID
        ) else {
            return nil
        }
        return RemoteIMSessionIdentity(
            appID: effectiveAppID,
            deviceID: effectiveDeviceID,
            tenantID: effectiveTenantID
        )
    }

    private static func resolveIdentityField(topLevel: String, nested: String?) -> String? {
        let topLevelValue = topLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        let nestedValue = (nested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !topLevelValue.isEmpty, !nestedValue.isEmpty, topLevelValue != nestedValue {
            return nil
        }
        let effectiveValue = topLevelValue.isEmpty ? nestedValue : topLevelValue
        return effectiveValue.isEmpty ? nil : effectiveValue
    }
}

struct RemoteVerificationStatus: Decodable {
    let imUID: String
    let userID: String
    let accountID: String
    let phoneRequirementSatisfied: Bool?
    let realNameRequirementSatisfied: Bool?
    let phoneBound: Bool
    let phoneBindingKnown: Bool
    let phoneMasked: String
    let realNameVerified: Bool
    let realNameMasked: String
    let idCardMasked: String
    let realNameStatus: String
    let realNameRejectReason: String

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case accountID = "account_id"
        case phoneRequirementSatisfied = "phone_requirement_satisfied"
        case realNameRequirementSatisfied = "real_name_requirement_satisfied"
        case phoneBound = "phone_bound"
        case phoneVerified = "phone_verified"
        case phoneVerifiedAt = "phone_verified_at"
        case mobileVerified = "mobile_verified"
        case phoneMasked = "phone_masked"
        case phone
        case realNameVerified = "real_name_verified"
        case realNameMasked = "real_name_masked"
        case idCardMasked = "id_card_masked"
        case realNameStatus = "real_name_status"
        case realNameRejectReason = "real_name_reject_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        phoneRequirementSatisfied = try c.decodeIfPresent(Bool.self, forKey: .phoneRequirementSatisfied)
        realNameRequirementSatisfied = try c.decodeIfPresent(Bool.self, forKey: .realNameRequirementSatisfied)
        let decodedPhone = try c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? c.decodeIfPresent(String.self, forKey: .phone)
            ?? ""
        phoneMasked = decodedPhone
        let explicitPhoneBound = decodeFlexibleBoolIfPresent(c, keys: [.phoneBound, .phoneVerified, .mobileVerified])
        phoneBound = explicitPhoneBound
            ?? phoneRequirementSatisfied
            ?? false
        phoneBindingKnown = explicitPhoneBound != nil
            || phoneRequirementSatisfied != nil
        realNameStatus = try c.decodeIfPresent(String.self, forKey: .realNameStatus) ?? "unsubmitted"
        realNameVerified = decodeFlexibleBool(c, keys: [.realNameVerified])
        realNameMasked = try c.decodeIfPresent(String.self, forKey: .realNameMasked) ?? ""
        idCardMasked = try c.decodeIfPresent(String.self, forKey: .idCardMasked) ?? ""
        realNameRejectReason = try c.decodeIfPresent(String.self, forKey: .realNameRejectReason) ?? ""
    }
}

struct RemotePhoneCodeResult: Decodable {
    let sent: Bool
    let requestID: String
    let phoneMasked: String
    let expiresInSeconds: Int
    let cooldownSeconds: Int

    enum CodingKeys: String, CodingKey {
        case sent
        case requestID = "request_id"
        case phoneMasked = "phone_masked"
        case phone
        case expiresInSeconds = "expires_in_seconds"
        case expiresIn = "expires_in"
        case cooldownSeconds = "cooldown_seconds"
        case cooldown = "cooldown"
        case retryAfterSeconds = "retry_after_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = try c.decodeIfPresent(Bool.self, forKey: .sent) ?? true
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        phoneMasked = try c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? c.decodeIfPresent(String.self, forKey: .phone)
            ?? ""
        expiresInSeconds = try c.decodeIfPresent(Int.self, forKey: .expiresInSeconds)
            ?? c.decodeIfPresent(Int.self, forKey: .expiresIn)
            ?? 0
        cooldownSeconds = c.decodeLossyIntIfPresent(forKey: .cooldownSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .cooldown)
            ?? c.decodeLossyIntIfPresent(forKey: .retryAfterSeconds)
            ?? 0
    }
}

struct RemoteAuthData: Decodable {
    let account: RemoteAccount
    let platformToken: String
    let authSession: RemoteAuthSession?
    let registrationSession: RemoteTenantSwitchResult?
    let registrationRuntimeConfig: RemoteTenantEnterRuntimeConfig?
    let requiresApproval: Bool
    let canDirectEnter: Bool?
    let entryStatus: String
    let entryType: String
    let entryScheme: String
    let entryCanonical: String
    let requiresWorkspaceSelection: Bool?
    let tenant: RemoteTenant?
    let tenantMember: RemoteTenantMember?
    let memberships: [RemoteTenantMembership]?
    let fallbackToDefaultTenant: Bool
    let fallbackReason: String
    let requestedTenantCode: String
    let defaultTenantCode: String

    enum CodingKeys: String, CodingKey {
        case account
        case platformToken = "platform_token"
        case authSession = "auth_session"
        case registrationSession = "session"
        case registrationRuntimeConfig = "runtime_config"
        case requiresApproval = "requires_approval"
        case canDirectEnter = "can_direct_enter"
        case entryStatus = "entry_status"
        case entryType = "entry_type"
        case entryScheme = "scheme"
        case entryCanonical = "canonical"
        case requiresWorkspaceSelection = "requires_workspace_selection"
        case tenant
        case tenantMember = "tenant_member"
        case memberships
        case fallbackToDefaultTenant = "fallback_to_default_tenant"
        case fallbackReason = "fallback_reason"
        case requestedTenantCode = "requested_tenant_code"
        case defaultTenantCode = "default_tenant_code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(RemoteAccount.self, forKey: .account)
        platformToken = try c.decodeIfPresent(String.self, forKey: .platformToken) ?? ""
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : nil)
        registrationSession = try c.decodeIfPresent(RemoteTenantSwitchResult.self, forKey: .registrationSession)
        registrationRuntimeConfig = try c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .registrationRuntimeConfig)
        requiresApproval = c.decodeLossyBoolIfPresent(forKey: .requiresApproval) ?? false
        canDirectEnter = c.decodeLossyBoolIfPresent(forKey: .canDirectEnter)
        entryStatus = try c.decodeIfPresent(String.self, forKey: .entryStatus) ?? ""
        entryType = try c.decodeIfPresent(String.self, forKey: .entryType) ?? ""
        entryScheme = try c.decodeIfPresent(String.self, forKey: .entryScheme) ?? ""
        entryCanonical = try c.decodeIfPresent(String.self, forKey: .entryCanonical) ?? ""
        requiresWorkspaceSelection = c.decodeLossyBoolIfPresent(forKey: .requiresWorkspaceSelection)
        tenant = try c.decodeIfPresent(RemoteTenant.self, forKey: .tenant)
        tenantMember = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .tenantMember)
        memberships = try c.decodeIfPresent([RemoteTenantMembership].self, forKey: .memberships)
        fallbackToDefaultTenant = c.decodeLossyBoolIfPresent(forKey: .fallbackToDefaultTenant) ?? false
        fallbackReason = try c.decodeIfPresent(String.self, forKey: .fallbackReason) ?? ""
        requestedTenantCode = try c.decodeIfPresent(String.self, forKey: .requestedTenantCode) ?? ""
        defaultTenantCode = try c.decodeIfPresent(String.self, forKey: .defaultTenantCode) ?? ""
    }

    var hasPendingWorkspaceApplication: Bool {
        if Self.isPendingWorkspaceStatus(entryStatus) { return true }
        if requiresApproval { return true }
        if let memberships, memberships.contains(where: { membership in
            let statuses = [
                membership.joinStatus,
                membership.applicationStatus,
                membership.member.status
            ]
            if statuses.contains(where: Self.isPendingWorkspaceStatus) {
                return true
            }
            let hasResolvedStatus = statuses.contains(where: Self.isApprovedOrJoinedWorkspaceStatus)
                || statuses.contains(where: Self.isRejectedWorkspaceStatus)
            return membership.approvalRequired && !hasResolvedStatus
        }) {
            return true
        }
        if let tenantMember, Self.isPendingWorkspaceStatus(tenantMember.status) {
            return true
        }
        return false
    }

    var hasTypedEntryAuthority: Bool {
        !entryScheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !entryCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var requiresRegistrationWorkspaceJoinRetry: Bool {
        guard registrationSession == nil, !hasPendingWorkspaceApplication else { return false }
        if memberships?.isEmpty == false { return true }
        return [
            "accountcreated", "joined", "alreadyjoined", "approved", "workspacejoinapproved"
        ].contains(Self.normalizedWorkspaceStatus(entryStatus))
    }

    private static func isPendingWorkspaceStatus(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        return [
            "pending", "pendingapproval", "pendingreview", "waiting", "waitingapproval", "submitted",
            "reviewing", "approvalrequired", "requiresapproval", "requiresreview", "workspacejoinpending"
        ].contains(normalized)
    }

    private static func isApprovedOrJoinedWorkspaceStatus(_ value: String) -> Bool {
        let normalized = normalizedWorkspaceStatus(value)
        return [
            "approved", "approve", "accepted", "pass", "passed", "through", "autoapproved", "autoaccepted",
            "autopassed", "workspacejoinapproved", "joined", "alreadyjoined", "workspacealreadyjoined",
            "active", "enabled", "normal"
        ].contains(normalized)
    }

    private static func isRejectedWorkspaceStatus(_ value: String) -> Bool {
        let normalized = normalizedWorkspaceStatus(value)
        return [
            "rejected", "reject", "denied", "declined", "refused", "workspacejoinrejected"
        ].contains(normalized)
    }

    private static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }
}

struct RemoteEnterpriseContextTenantPresentation: Decodable, Equatable {
    let id: String
    let tenantCode: String
    let name: String
    let logoURL: String
    let logoCacheKey: String

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case tenantCode = "tenant_code"
        case name
        case tenantName = "tenant_name"
        case logoURL = "logo_url"
        case logoURLCamel = "logoUrl"
        case logoCacheKey = "logo_cache_key"
        case logoCacheKeyCamel = "logoCacheKey"
    }

    init(id: String, tenantCode: String, name: String, logoURL: String, logoCacheKey: String) {
        self.id = id
        self.tenantCode = tenantCode
        self.name = name
        self.logoURL = logoURL
        self.logoCacheKey = logoCacheKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? ""
        logoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            ?? c.decodeIfPresent(String.self, forKey: .logoURLCamel)
            ?? ""
        logoCacheKey = try c.decodeIfPresent(String.self, forKey: .logoCacheKey)
            ?? c.decodeIfPresent(String.self, forKey: .logoCacheKeyCamel)
            ?? ""
    }
}

struct RemoteAccount: Decodable {
    let id: String
    let username: String
    let nickname: String
    let phone: String
    let phoneVerified: Bool
    let phoneBindingKnown: Bool
    let realNameVerified: Bool
    let realNameStatus: String
    let role: String
    let status: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
            ?? c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
            ?? c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? ""
        let verifiedAt = try c.decodeIfPresent(String.self, forKey: .phoneVerifiedAt) ?? ""
        let explicitPhoneVerified = decodeFlexibleBoolIfPresent(c, keys: [.phoneVerified, .phoneBound, .mobileVerified])
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        phoneVerified = explicitPhoneVerified
            ?? (!verifiedAt.isEmpty || !normalizedPhone.isEmpty)
        phoneBindingKnown = explicitPhoneVerified != nil || !verifiedAt.isEmpty || !normalizedPhone.isEmpty
        realNameStatus = try c.decodeIfPresent(String.self, forKey: .realNameStatus)
            ?? c.decodeIfPresent(String.self, forKey: .kycStatus)
            ?? c.decodeIfPresent(String.self, forKey: .kyc)
            ?? ""
        realNameVerified = decodeFlexibleBool(c, keys: [.realNameVerified])
            || ["verified", "approved", "passed", "success", "认证通过", "已认证"].contains(realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, username, nickname, phone, role, status
        case phoneMasked = "phone_masked"
        case displayName = "display_name"
        case name
        case phoneVerified = "phone_verified"
        case phoneVerifiedAt = "phone_verified_at"
        case phoneBound = "phone_bound"
        case mobileVerified = "mobile_verified"
        case realNameVerified = "real_name_verified"
        case realNameStatus = "real_name_status"
        case kycStatus = "kyc_status"
        case kyc
    }
}

private func displayableTenantLogoURL(primary: String, fallback: String) -> String {
    let normalizedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedPrimary.isEmpty {
        return normalizedPrimary
    }
    let normalizedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedFallback.isEmpty else { return "" }
    if normalizedFallback.hasPrefix("/api/tenant/avatar/") || normalizedFallback.hasPrefix("//") {
        return normalizedFallback
    }
    guard let url = URL(string: normalizedFallback),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "data"].contains(scheme) else {
        return ""
    }
    return normalizedFallback
}

struct RemoteTenant: Decodable {
    let id: String
    let tenantCode: String
    let name: String
    let status: String
    let logoURL: String
    let logoStatus: String
    let logoVersion: String
    let logoUpdatedAt: String
    let logoCacheKey: String
    let logoMime: String
    let logoWidth: Int?
    let logoHeight: Int?
    let entryType: String
    let entryScheme: String
    let entryCanonical: String
    let inviterNickname: String
    let inviterDisplayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case code
        case name
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case status
        case logoURL = "logo_url"
        case logoUrl = "logoUrl"
        case logoStatus = "logo_status"
        case logoStatusCamel = "logoStatus"
        case logoVersion = "logo_version"
        case logoVersionCamel = "logoVersion"
        case logoUpdatedAt = "logo_updated_at"
        case logoUpdatedAtCamel = "logoUpdatedAt"
        case logoCacheKey = "logo_cache_key"
        case logoCacheKeyCamel = "logoCacheKey"
        case logoObjectKey = "logo_object_key"
        case logoMime = "logo_mime"
        case logoMimeCamel = "logoMime"
        case logoWidth = "logo_width"
        case logoWidthCamel = "logoWidth"
        case logoHeight = "logo_height"
        case logoHeightCamel = "logoHeight"
        case entryType = "entry_type"
        case entryTypeCamel = "entryType"
        case entryScheme = "scheme"
        case entryCanonical = "canonical"
        case inviterNickname = "inviter_nickname"
        case inviterNicknameCamel = "inviterNickname"
        case inviterDisplayName = "inviter_display_name"
        case inviterDisplayNameCamel = "inviterDisplayName"
    }

    init(profile: RemoteTenantProfile) {
        id = profile.tenantID
        tenantCode = profile.tenantCode
        name = profile.name
        status = profile.status
        logoURL = profile.logoURL
        logoStatus = profile.logoStatus
        logoVersion = profile.logoVersion
        logoUpdatedAt = profile.logoUpdatedAt
        logoCacheKey = profile.logoCacheKey
        logoMime = profile.logoMime
        logoWidth = profile.logoWidth
        logoHeight = profile.logoHeight
        entryType = ""
        entryScheme = ""
        entryCanonical = ""
        inviterNickname = ""
        inviterDisplayName = ""
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .code)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        let decodedLogoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            ?? c.decodeIfPresent(String.self, forKey: .logoUrl)
            ?? ""
        let decodedLogoObjectKey = try c.decodeIfPresent(String.self, forKey: .logoObjectKey) ?? ""
        logoURL = displayableTenantLogoURL(primary: decodedLogoURL, fallback: decodedLogoObjectKey)
        logoStatus = try c.decodeIfPresent(String.self, forKey: .logoStatus)
            ?? c.decodeIfPresent(String.self, forKey: .logoStatusCamel)
            ?? ""
        logoVersion = try c.decodeIfPresent(String.self, forKey: .logoVersion)
            ?? c.decodeIfPresent(String.self, forKey: .logoVersionCamel)
            ?? ""
        logoUpdatedAt = try c.decodeIfPresent(String.self, forKey: .logoUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .logoUpdatedAtCamel)
            ?? ""
        logoCacheKey = try c.decodeIfPresent(String.self, forKey: .logoCacheKey)
            ?? c.decodeIfPresent(String.self, forKey: .logoCacheKeyCamel)
            ?? decodedLogoObjectKey
        logoMime = try c.decodeIfPresent(String.self, forKey: .logoMime)
            ?? c.decodeIfPresent(String.self, forKey: .logoMimeCamel)
            ?? ""
        logoWidth = c.decodeLossyIntIfPresent(forKey: .logoWidth)
            ?? c.decodeLossyIntIfPresent(forKey: .logoWidthCamel)
        logoHeight = c.decodeLossyIntIfPresent(forKey: .logoHeight)
            ?? c.decodeLossyIntIfPresent(forKey: .logoHeightCamel)
        entryType = try c.decodeIfPresent(String.self, forKey: .entryType)
            ?? c.decodeIfPresent(String.self, forKey: .entryTypeCamel)
            ?? ""
        entryScheme = try c.decodeIfPresent(String.self, forKey: .entryScheme) ?? ""
        entryCanonical = try c.decodeIfPresent(String.self, forKey: .entryCanonical) ?? ""
        inviterNickname = try c.decodeIfPresent(String.self, forKey: .inviterNickname)
            ?? c.decodeIfPresent(String.self, forKey: .inviterNicknameCamel)
            ?? ""
        inviterDisplayName = try c.decodeIfPresent(String.self, forKey: .inviterDisplayName)
            ?? c.decodeIfPresent(String.self, forKey: .inviterDisplayNameCamel)
            ?? ""
    }
}

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

struct RemoteTenantMember: Decodable {
    let id: String
    let tenantID: String
    let accountID: String
    let imUID: String
    let userID: String
    let username: String
    let nickname: String
    let status: String
    let role: String
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case memberID = "member_id"
        case tenantMemberID = "tenant_member_id"
        case tenantID = "tenant_id"
        case accountID = "account_id"
        case imUID = "im_uid"
        case memberIMUID = "member_im_uid"
        case userID = "user_id"
        case username
        case nickname
        case displayName = "display_name"
        case name
        case status
        case memberStatus = "member_status"
        case tenantMemberStatus = "tenant_member_status"
        case role
        case memberRole = "member_role"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .memberID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantMemberID)
            ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID) ?? ""
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .memberIMUID)
            ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
            ?? c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .memberStatus)
            ?? c.decodeIfPresent(String.self, forKey: .tenantMemberStatus)
            ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role)
            ?? c.decodeIfPresent(String.self, forKey: .memberRole)
            ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
    }
}

private enum RemoteWorkspaceAdmissionReconciliation {
    static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    static func projectionReasonCode(status: String) -> String {
        let normalized = normalizedWorkspaceStatus(status)
        if ["missing", "pending", "queued", "syncing", "inprogress", "stale"].contains(normalized) {
            return "member_projection_syncing"
        }
        if ["failed", "failure", "error", "conflict", "rejected", "reject"].contains(normalized) {
            return "member_projection_failed"
        }
        return ""
    }

    static func isStaleMemberProjectionSyncingReady(
        reason: String,
        projectionStatus: String,
        joinStatus: String,
        applicationStatus: String,
        accountStatus: String = "",
        tenantStatus: String,
        memberStatus: String,
        role: String
    ) -> Bool {
        guard isMemberProjectionSyncingReason(reason),
              isProjectionReady(projectionStatus),
              !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard joinedStatusAllowsEntry(joinStatus),
              applicationStatusAllowsEntry(applicationStatus),
              accountStatusAllowsEntry(accountStatus),
              tenantStatusAllowsEntry(tenantStatus),
              memberStatusAllowsEntry(memberStatus) else {
            return false
        }
        return true
    }

    private static func isMemberProjectionSyncingReason(_ reason: String) -> Bool {
        switch normalizedWorkspaceStatus(reason) {
        case "memberprojectionsyncing", "memberprojectionpending", "memberprojectionmissing", "memberprojectionstale", "memberprojectionsync":
            return true
        default:
            return false
        }
    }

    private static func isProjectionReady(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "applied", "ready", "current", "synced", "synchronized", "complete", "completed", "success", "succeeded", "ok":
            return true
        default:
            return false
        }
    }

    private static func joinedStatusAllowsEntry(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "joined", "alreadyjoined", "workspacealreadyjoined", "active", "enabled", "normal", "approved", "accepted", "passed", "workspacejoinapproved":
            return true
        default:
            return false
        }
    }

    private static func applicationStatusAllowsEntry(_ status: String) -> Bool {
        let normalized = normalizedWorkspaceStatus(status)
        guard !normalized.isEmpty else { return true }
        switch normalized {
        case "approved", "accepted", "passed", "active", "enabled", "normal", "joined", "workspacejoinapproved":
            return true
        default:
            return false
        }
    }

    private static func accountStatusAllowsEntry(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "", "normal", "active", "enabled", "unlocked":
            return true
        default:
            return false
        }
    }

    private static func tenantStatusAllowsEntry(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "", "normal", "active", "enabled":
            return true
        default:
            return false
        }
    }

    private static func memberStatusAllowsEntry(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "normal", "active", "enabled", "joined":
            return true
        default:
            return false
        }
    }
}

struct RemoteTenantMembership: Decodable {
    let tenant: RemoteTenant
    let member: RemoteTenantMember
    let joinStatus: String
    let applicationID: String
    let applicationStatus: String
    let approvalRequired: Bool
    let canSwitch: Bool?
    let enterable: Bool?
    let disabledReason: String
    let appID: String
    let appTenantBound: Bool?
    let appBindingStatus: String

    enum CodingKeys: String, CodingKey {
        case tenant
        case member
        case joinStatus = "join_status"
        case membershipStatus = "membership_status"
        case applicationID = "application_id"
        case applicationStatus = "application_status"
        case approvalRequired = "approval_required"
        case requiresApproval = "requires_approval"
        case canSwitch = "can_switch"
        case canEnter = "can_enter"
        case enterable
        case disabledReason = "disabled_reason"
        case reasonCode = "reason_code"
        case reasonText = "reason_text"
        case reasonMessage = "reason_message"
        case memberProjectionStatus = "member_projection_status"
        case memberProjectionStatusCamel = "memberProjectionStatus"
        case memberProjectionReasonCode = "member_projection_reason_code"
        case memberProjectionReasonCodeCamel = "memberProjectionReasonCode"
        case application
        case appID = "app_id"
        case appIDCamel = "appId"
        case appTenantBound = "app_tenant_bound"
        case appTenantBoundCamel = "appTenantBound"
        case appBindingStatus = "app_binding_status"
        case appBindingStatusCamel = "appBindingStatus"
    }

    enum ApplicationCodingKeys: String, CodingKey {
        case id
        case applicationID = "application_id"
        case status
        case applicationStatus = "application_status"
    }

    init(tenant: RemoteTenant, member: RemoteTenantMember) {
        self.tenant = tenant
        self.member = member
        joinStatus = member.status
        applicationID = ""
        applicationStatus = ""
        approvalRequired = false
        canSwitch = nil
        enterable = nil
        disabledReason = ""
        appID = ""
        appTenantBound = nil
        appBindingStatus = ""
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decodeIfPresent(RemoteTenant.self, forKey: .tenant)
            ?? RemoteTenant(from: decoder)
        member = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .member)
            ?? RemoteTenantMember(from: decoder)
        let application = try? c.nestedContainer(keyedBy: ApplicationCodingKeys.self, forKey: .application)
        applicationID = try c.decodeIfPresent(String.self, forKey: .applicationID)
            ?? application?.decodeIfPresent(String.self, forKey: .id)
            ?? application?.decodeIfPresent(String.self, forKey: .applicationID)
            ?? ""
        applicationStatus = try c.decodeIfPresent(String.self, forKey: .applicationStatus)
            ?? application?.decodeIfPresent(String.self, forKey: .applicationStatus)
            ?? application?.decodeIfPresent(String.self, forKey: .status)
            ?? ""
        approvalRequired = c.decodeLossyBoolIfPresent(forKey: .approvalRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresApproval)
            ?? false
        let decodedJoinStatus = try c.decodeIfPresent(String.self, forKey: .joinStatus)
            ?? c.decodeIfPresent(String.self, forKey: .membershipStatus)
            ?? (applicationStatus.isEmpty ? member.status : applicationStatus)
        joinStatus = decodedJoinStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && approvalRequired
            ? "pending"
            : decodedJoinStatus
        let decodedCanSwitch = c.decodeLossyBoolIfPresent(forKey: .canSwitch)
        let decodedEnterable = c.decodeLossyBoolIfPresent(forKey: .enterable)
            ?? c.decodeLossyBoolIfPresent(forKey: .canEnter)
        let decodedDisabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason) ?? ""
        let decodedReasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode) ?? ""
        let decodedReasonText = try c.decodeIfPresent(String.self, forKey: .reasonText) ?? ""
        let decodedReasonMessage = try c.decodeIfPresent(String.self, forKey: .reasonMessage) ?? ""
        let decodedProjectionStatus = try c.decodeIfPresent(String.self, forKey: .memberProjectionStatus)
            ?? c.decodeIfPresent(String.self, forKey: .memberProjectionStatusCamel)
            ?? ""
        let projectionReason = try c.decodeIfPresent(String.self, forKey: .memberProjectionReasonCode)
            ?? c.decodeIfPresent(String.self, forKey: .memberProjectionReasonCodeCamel)
            ?? RemoteWorkspaceAdmissionReconciliation.projectionReasonCode(status: decodedProjectionStatus)
        let rawDisabledReason = [
            decodedDisabledReason,
            decodedReasonCode,
            projectionReason,
            decodedReasonText,
            decodedReasonMessage
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let projectionSyncingReasonIsStale = RemoteWorkspaceAdmissionReconciliation.isStaleMemberProjectionSyncingReady(
            reason: rawDisabledReason,
            projectionStatus: decodedProjectionStatus,
            joinStatus: joinStatus,
            applicationStatus: applicationStatus,
            tenantStatus: tenant.status,
            memberStatus: member.status,
            role: member.role
        )
        canSwitch = projectionSyncingReasonIsStale && decodedCanSwitch == false ? true : decodedCanSwitch
        enterable = projectionSyncingReasonIsStale && decodedEnterable == false ? true : decodedEnterable
        disabledReason = projectionSyncingReasonIsStale ? "" : rawDisabledReason
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        appTenantBound = c.decodeLossyBoolIfPresent(forKey: .appTenantBound)
            ?? c.decodeLossyBoolIfPresent(forKey: .appTenantBoundCamel)
        appBindingStatus = try c.decodeIfPresent(String.self, forKey: .appBindingStatus)
            ?? c.decodeIfPresent(String.self, forKey: .appBindingStatusCamel)
            ?? ""
    }

    private static func projectionReasonCode(status: String) -> String {
        let normalized = normalizedWorkspaceStatus(status)
        if ["missing", "pending", "queued", "syncing", "inprogress", "stale"].contains(normalized) {
            return "member_projection_syncing"
        }
        if ["failed", "failure", "error", "conflict", "rejected", "reject"].contains(normalized) {
            return "member_projection_failed"
        }
        return ""
    }

    private static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }
}

extension RemoteTenantMembership {
    var explicitlyNotBoundToApp: Bool {
        if appTenantBound == false {
            return true
        }
        let normalizedStatus = appBindingStatus
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        guard !normalizedStatus.isEmpty else { return false }
        return !["bound", "active", "enabled", "available", "ok"].contains(normalizedStatus)
    }

    func isVisibleInAppScope(_ expectedAppID: String) -> Bool {
        if explicitlyNotBoundToApp {
            return false
        }
        let normalizedExpected = IMAPIContext.normalizedIOSAppID(expectedAppID)
        let normalizedMembershipAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : IMAPIContext.normalizedIOSAppID(appID)
        if !normalizedMembershipAppID.isEmpty,
           normalizedMembershipAppID != normalizedExpected {
            return false
        }
        return true
    }
}

struct RemoteTenantEnterRuntimeConfig: Decodable, Equatable {
    let tenantAPIBaseURL: String
    let tenantAPIBaseURLSource: String
    let tenantAPIBaseURLConfigured: Bool
    let imAPIBaseURL: String
    let configStatus: String
    let missingFields: [String]
	let contractVersion: Int
	let appID: String
	let tenantID: String
	let routeRevision: UInt64
	let routeSource: String
	let routeStatus: String
	let routeHash: String
	let routes: [String: IMRuntimeRouteEndpointSet]
	let routingPolicy: IMRuntimeRoutePolicy
    var environment: String? = nil
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var publicationStatus: String? = nil
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case tenantAPIBaseURL = "tenant_api_base_url"
        case tenantAPIBaseURLCamel = "tenantApiBaseUrl"
        case tenantAPIBaseURLSource = "tenant_api_base_url_source"
        case tenantAPIBaseURLSourceCamel = "tenantApiBaseUrlSource"
        case tenantAPIBaseURLConfigured = "tenant_api_base_url_configured"
        case tenantAPIBaseURLConfiguredCamel = "tenantApiBaseUrlConfigured"
        case imAPIBaseURL = "im_api_base_url"
        case imAPIBaseURLCamel = "imApiBaseUrl"
        case configStatus = "config_status"
        case configStatusCamel = "configStatus"
        case missingFields = "missing_fields"
        case missingFieldsCamel = "missingFields"
		case contractVersion = "contract_version"
		case appID = "app_id"
		case tenantID = "tenant_id"
		case routeRevision = "route_revision"
		case routeSource = "route_source"
		case routeStatus = "route_status"
		case routeHash = "route_hash"
		case routes
		case routingPolicy = "routing_policy"
        case environment
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case publicationStatus = "publication_status"
        case status
        case keysetRevision = "keyset_revision"
    }

    var hasTenantAPIBaseURL: Bool {
        !tenantAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantAPIBaseURL = try c.decodeIfPresent(String.self, forKey: .tenantAPIBaseURL)
            ?? c.decodeIfPresent(String.self, forKey: .tenantAPIBaseURLCamel)
            ?? ""
        tenantAPIBaseURLSource = try c.decodeIfPresent(String.self, forKey: .tenantAPIBaseURLSource)
            ?? c.decodeIfPresent(String.self, forKey: .tenantAPIBaseURLSourceCamel)
            ?? ""
        tenantAPIBaseURLConfigured = c.decodeLossyBoolIfPresent(forKey: .tenantAPIBaseURLConfigured)
            ?? c.decodeLossyBoolIfPresent(forKey: .tenantAPIBaseURLConfiguredCamel)
            ?? false
        imAPIBaseURL = try c.decodeIfPresent(String.self, forKey: .imAPIBaseURL)
            ?? c.decodeIfPresent(String.self, forKey: .imAPIBaseURLCamel)
            ?? ""
        configStatus = try c.decodeIfPresent(String.self, forKey: .configStatus)
            ?? c.decodeIfPresent(String.self, forKey: .configStatusCamel)
            ?? ""
        missingFields = try c.decodeIfPresent([String].self, forKey: .missingFields)
            ?? c.decodeIfPresent([String].self, forKey: .missingFieldsCamel)
            ?? []
		contractVersion = try c.decodeIfPresent(Int.self, forKey: .contractVersion) ?? 0
		appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
		tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID) ?? ""
		routeRevision = try c.decodeIfPresent(UInt64.self, forKey: .routeRevision) ?? 0
		routeSource = try c.decodeIfPresent(String.self, forKey: .routeSource) ?? ""
		routeStatus = try c.decodeIfPresent(String.self, forKey: .routeStatus) ?? ""
		routeHash = try c.decodeIfPresent(String.self, forKey: .routeHash) ?? ""
		routes = try c.decodeIfPresent([String: IMRuntimeRouteEndpointSet].self, forKey: .routes) ?? [:]
		routingPolicy = try c.decodeIfPresent(IMRuntimeRoutePolicy.self, forKey: .routingPolicy) ?? .init(contractVersion: 0)
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        publicationID = try c.decodeIfPresent(String.self, forKey: .publicationID)
        publicationRevision = try c.decodeIfPresent(UInt64.self, forKey: .publicationRevision)
        profileFingerprint = try c.decodeIfPresent(String.self, forKey: .profileFingerprint)
        lifetimeMode = c.contains(.lifetimeMode)
            ? .authoritativeValue(try c.decodeIfPresent(String.self, forKey: .lifetimeMode))
            : nil
        publicationStatus = try c.decodeIfPresent(String.self, forKey: .publicationStatus)
            ?? c.decodeIfPresent(String.self, forKey: .status)
        keysetRevision = try c.decodeIfPresent(UInt64.self, forKey: .keysetRevision)
    }

	var runtimeRouteSnapshot: IMRuntimeRouteSnapshot {
		.init(
			contractVersion: contractVersion,
			appID: appID,
			tenantID: tenantID,
			revision: routeRevision,
			source: routeSource,
			status: routeStatus,
			configHash: routeHash,
			services: routes,
			policy: routingPolicy,
			hashScope: .tenantEntry,
            environment: environment,
            publicationID: publicationID,
            publicationRevision: publicationRevision,
            profileFingerprint: profileFingerprint,
            lifetimeMode: lifetimeMode,
            publicationStatus: publicationStatus,
            keysetRevision: keysetRevision
		)
	}
}

struct RemoteEnterpriseContextResult: Decodable, Equatable {
    let appID: String
    let tenantID: String
    let contextToken: String
    let expiresAt: Int64
    let ttlSeconds: Int
    let routeRevision: UInt64
    let runtimeConfig: RemoteTenantEnterRuntimeConfig
    let tenant: RemoteEnterpriseContextTenantPresentation?
    let entryType: String
    let scheme: String
    let canonical: String
    let tenantCode: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case entryType = "entry_type"
        case entryTypeCamel = "entryType"
        case scheme
        case canonical
        case contextToken = "context_token"
        case contextTokenCamel = "contextToken"
        case expiresAt = "expires_at"
        case expiresAtCamel = "expiresAt"
        case ttlSeconds = "ttl_seconds"
        case ttlSecondsCamel = "ttlSeconds"
        case routeRevision = "route_revision"
        case routeRevisionCamel = "routeRevision"
        case runtimeConfig = "runtime_config"
        case runtimeConfigCamel = "runtimeConfig"
        case tenant
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case tenantLogoURL = "tenant_logo_url"
        case tenantLogoURLCamel = "tenantLogoUrl"
        case tenantLogoCacheKey = "tenant_logo_cache_key"
        case tenantLogoCacheKeyCamel = "tenantLogoCacheKey"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? ""
        entryType = try c.decodeIfPresent(String.self, forKey: .entryType)
            ?? c.decodeIfPresent(String.self, forKey: .entryTypeCamel)
            ?? ""
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? ""
        canonical = try c.decodeIfPresent(String.self, forKey: .canonical) ?? ""
        contextToken = try c.decodeIfPresent(String.self, forKey: .contextToken)
            ?? c.decodeIfPresent(String.self, forKey: .contextTokenCamel)
            ?? ""
        expiresAt = c.decodeLossyInt64IfPresent(forKey: .expiresAt)
            ?? c.decodeLossyInt64IfPresent(forKey: .expiresAtCamel)
            ?? 0
        ttlSeconds = c.decodeLossyIntIfPresent(forKey: .ttlSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .ttlSecondsCamel)
            ?? 0
        routeRevision = try c.decodeIfPresent(UInt64.self, forKey: .routeRevision)
            ?? c.decodeIfPresent(UInt64.self, forKey: .routeRevisionCamel)
            ?? 0
        runtimeConfig = try c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfig)
            ?? c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfigCamel)
            ?? RemoteTenantEnterRuntimeConfig(from: decoder)
        if let nested = try c.decodeIfPresent(RemoteEnterpriseContextTenantPresentation.self, forKey: .tenant) {
            tenant = nested
        } else {
            let name = try c.decodeIfPresent(String.self, forKey: .tenantName)
                ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
                ?? ""
            let logoURL = try c.decodeIfPresent(String.self, forKey: .tenantLogoURL)
                ?? c.decodeIfPresent(String.self, forKey: .tenantLogoURLCamel)
                ?? ""
            let logoCacheKey = try c.decodeIfPresent(String.self, forKey: .tenantLogoCacheKey)
                ?? c.decodeIfPresent(String.self, forKey: .tenantLogoCacheKeyCamel)
                ?? ""
            tenant = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : RemoteEnterpriseContextTenantPresentation(
                    id: tenantID,
                    tenantCode: tenantCode,
                    name: name,
                    logoURL: logoURL,
                    logoCacheKey: logoCacheKey
                )
        }
    }
}

struct RemoteTenantServerRoute: Decodable {
    let apiHost: String
    let gatewayHost: String

    enum CodingKeys: String, CodingKey {
        case apiHost = "api_host"
        case apiHostCamel = "apiHost"
        case gatewayHost = "gateway_host"
        case gatewayHostCamel = "gatewayHost"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiHost = try c.decodeIfPresent(String.self, forKey: .apiHost)
            ?? c.decodeIfPresent(String.self, forKey: .apiHostCamel)
            ?? ""
        gatewayHost = try c.decodeIfPresent(String.self, forKey: .gatewayHost)
            ?? c.decodeIfPresent(String.self, forKey: .gatewayHostCamel)
            ?? ""
    }
}

struct RemoteTenantEnterResult: Decodable, Equatable {
    let entryTicket: String
    let runtimeConfig: RemoteTenantEnterRuntimeConfig

    enum CodingKeys: String, CodingKey {
        case entryTicket = "entry_ticket"
        case entryTicketCamel = "entryTicket"
        case ticket
        case entry
        case runtimeConfig = "runtime_config"
        case runtimeConfigCamel = "runtimeConfig"
    }

    private enum EntryCodingKeys: String, CodingKey {
        case ticket
        case entryTicket = "entry_ticket"
        case entryTicketCamel = "entryTicket"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entry = try? c.nestedContainer(keyedBy: EntryCodingKeys.self, forKey: .entry)
        entryTicket = try c.decodeIfPresent(String.self, forKey: .entryTicket)
            ?? c.decodeIfPresent(String.self, forKey: .entryTicketCamel)
            ?? c.decodeIfPresent(String.self, forKey: .ticket)
            ?? entry?.decodeIfPresent(String.self, forKey: .ticket)
            ?? entry?.decodeIfPresent(String.self, forKey: .entryTicket)
            ?? entry?.decodeIfPresent(String.self, forKey: .entryTicketCamel)
            ?? ""
        let nestedRuntime = try c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfig)
            ?? c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfigCamel)
        let topLevelRuntime = try RemoteTenantEnterRuntimeConfig(from: decoder)
        runtimeConfig = nestedRuntime?.hasTenantAPIBaseURL == true ? nestedRuntime! : topLevelRuntime
    }
}

struct RemoteTenantPlatformEntryResult: Decodable {
    let tenant: RemoteTenant
    let member: RemoteTenantMember
    let user: RemoteIMUser?
    let imUID: String
    let imToken: String
    let apiToken: String
    let session: RemoteIMSession?
    let authSession: RemoteAuthSession?
    let accountID: String
    let appID: String
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case tenant
        case member
        case user
        case imUID = "im_uid"
        case imUIDCamel = "imUid"
        case uid
        case imToken = "im_token"
        case imTokenCamel = "imToken"
        case apiToken = "api_token"
        case apiTokenCamel = "apiToken"
        case token
        case session
        case authSession = "auth_session"
        case authSessionCamel = "authSession"
        case refreshSession = "refresh_session"
        case refreshSessionCamel = "refreshSession"
        case accountID = "account_id"
        case accountIDCamel = "accountId"
        case platformAccountID = "platform_account_id"
        case platformAccountIDCamel = "platformAccountId"
        case appID = "app_id"
        case appIDCamel = "appId"
        case deviceID = "device_id"
        case deviceIDCamel = "deviceId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decodeIfPresent(RemoteTenant.self, forKey: .tenant)
            ?? RemoteTenant(from: decoder)
        member = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .member)
            ?? RemoteTenantMember(from: decoder)
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? c.decodeIfPresent(RemoteIMUser.self, forKey: .member)
        let sessionPayload = try c.decodeIfPresent(RemoteTenantLoginSessionPayload.self, forKey: .session)
        let decodedSession: RemoteIMSession?
        if let session = sessionPayload?.session {
            decodedSession = session
        } else {
            decodedSession = try c.decodeIfPresent(RemoteIMSession.self, forKey: .session)
        }
        session = decodedSession
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
            ?? c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSessionCamel)
        let refreshSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .refreshSession)
            ?? c.decodeIfPresent(RemoteAuthSession.self, forKey: .refreshSessionCamel)
        authSession = refreshSession?.isUsable == true
            ? refreshSession
            : (nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : decodedSession?.authSession))
        apiToken = try c.decodeIfPresent(String.self, forKey: .apiToken)
            ?? c.decodeIfPresent(String.self, forKey: .apiTokenCamel)
            ?? ""
        imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
            ?? c.decodeIfPresent(String.self, forKey: .imTokenCamel)
            ?? c.decodeIfPresent(String.self, forKey: .token)
            ?? decodedSession?.imToken
            ?? apiToken
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .imUIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .uid)
            ?? decodedSession?.imUID
            ?? user?.imUID
            ?? member.imUID
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
            ?? c.decodeIfPresent(String.self, forKey: .accountIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .platformAccountID)
            ?? c.decodeIfPresent(String.self, forKey: .platformAccountIDCamel)
            ?? user?.accountID
            ?? member.accountID
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? decodedSession?.appID
            ?? authSession?.appID
            ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
            ?? c.decodeIfPresent(String.self, forKey: .deviceIDCamel)
            ?? decodedSession?.deviceID
            ?? authSession?.deviceID
            ?? ""
    }
}

struct RemoteTenantSwitchResult: Decodable {
    let tenant: RemoteTenant
    let server: RemoteTenantServerRoute?
    let app: RemoteApp
    let member: RemoteTenantMember
    let user: RemoteIMUser?
    let imUID: String
    let imToken: String
    let session: RemoteIMSession?
    let authSession: RemoteAuthSession?

    enum CodingKeys: String, CodingKey {
        case tenant
        case server
        case app
        case member
        case user
        case imUID = "im_uid"
        case imToken = "im_token"
        case session
        case authSession = "auth_session"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decode(RemoteTenant.self, forKey: .tenant)
        server = try c.decodeIfPresent(RemoteTenantServerRoute.self, forKey: .server)
        app = try c.decodeIfPresent(RemoteApp.self, forKey: .app) ?? RemoteApp(appID: "")
        member = try c.decode(RemoteTenantMember.self, forKey: .member)
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? c.decodeIfPresent(RemoteIMUser.self, forKey: .member)
        session = try c.decodeIfPresent(RemoteIMSession.self, forKey: .session)
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : session?.authSession)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? session?.imUID
            ?? member.imUID
        imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
            ?? session?.imToken
            ?? ""
    }
}

struct RemoteWorkspaceTenant: Decodable {
    let id: String
    let tenantCode: String
    let name: String
    let status: String
    let logoURL: String
    let logoStatus: String
    let logoVersion: String
    let logoUpdatedAt: String
    let logoCacheKey: String
    let logoMime: String
    let logoWidth: Int?
    let logoHeight: Int?
    let joinStatus: String
    let memberRole: String
    let applicationID: String
    let applicationStatus: String
    let approvalRequired: Bool
    let current: Bool
    let canSwitch: Bool
    let accountStatus: String
    let tenantStatus: String
    let memberStatus: String
    let enterable: Bool?
    let disabledReason: String

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case code
        case name
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case status
        case logoURL = "logo_url"
        case logoUrl = "logoUrl"
        case logoStatus = "logo_status"
        case logoStatusCamel = "logoStatus"
        case logoVersion = "logo_version"
        case logoVersionCamel = "logoVersion"
        case logoUpdatedAt = "logo_updated_at"
        case logoUpdatedAtCamel = "logoUpdatedAt"
        case logoCacheKey = "logo_cache_key"
        case logoCacheKeyCamel = "logoCacheKey"
        case logoObjectKey = "logo_object_key"
        case logoMime = "logo_mime"
        case logoMimeCamel = "logoMime"
        case logoWidth = "logo_width"
        case logoWidthCamel = "logoWidth"
        case logoHeight = "logo_height"
        case logoHeightCamel = "logoHeight"
        case joinStatus = "join_status"
        case membershipStatus = "membership_status"
        case memberRole = "member_role"
        case applicationID = "application_id"
        case applicationStatus = "application_status"
        case approvalRequired = "approval_required"
        case requiresApproval = "requires_approval"
        case current
        case canSwitch = "can_switch"
        case canEnter = "can_enter"
        case accountStatus = "account_status"
        case tenantStatus = "tenant_status"
        case memberStatus = "member_status"
        case enterable
        case disabledReason = "disabled_reason"
        case reasonCode = "reason_code"
        case reasonText = "reason_text"
        case reasonMessage = "reason_message"
        case memberProjectionStatus = "member_projection_status"
        case memberProjectionStatusCamel = "memberProjectionStatus"
        case memberProjectionReasonCode = "member_projection_reason_code"
        case memberProjectionReasonCodeCamel = "memberProjectionReasonCode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .code)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        let decodedLogoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            ?? c.decodeIfPresent(String.self, forKey: .logoUrl)
            ?? ""
        let decodedLogoObjectKey = try c.decodeIfPresent(String.self, forKey: .logoObjectKey) ?? ""
        logoURL = displayableTenantLogoURL(primary: decodedLogoURL, fallback: decodedLogoObjectKey)
        logoStatus = try c.decodeIfPresent(String.self, forKey: .logoStatus)
            ?? c.decodeIfPresent(String.self, forKey: .logoStatusCamel)
            ?? ""
        logoVersion = try c.decodeIfPresent(String.self, forKey: .logoVersion)
            ?? c.decodeIfPresent(String.self, forKey: .logoVersionCamel)
            ?? ""
        logoUpdatedAt = try c.decodeIfPresent(String.self, forKey: .logoUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .logoUpdatedAtCamel)
            ?? ""
        logoCacheKey = try c.decodeIfPresent(String.self, forKey: .logoCacheKey)
            ?? c.decodeIfPresent(String.self, forKey: .logoCacheKeyCamel)
            ?? decodedLogoObjectKey
        logoMime = try c.decodeIfPresent(String.self, forKey: .logoMime)
            ?? c.decodeIfPresent(String.self, forKey: .logoMimeCamel)
            ?? ""
        logoWidth = c.decodeLossyIntIfPresent(forKey: .logoWidth)
            ?? c.decodeLossyIntIfPresent(forKey: .logoWidthCamel)
        logoHeight = c.decodeLossyIntIfPresent(forKey: .logoHeight)
            ?? c.decodeLossyIntIfPresent(forKey: .logoHeightCamel)
        let decodedJoinStatus = try c.decodeIfPresent(String.self, forKey: .joinStatus)
            ?? c.decodeIfPresent(String.self, forKey: .membershipStatus)
            ?? ""
        memberRole = try c.decodeIfPresent(String.self, forKey: .memberRole) ?? ""
        applicationID = try c.decodeIfPresent(String.self, forKey: .applicationID) ?? ""
        applicationStatus = try c.decodeIfPresent(String.self, forKey: .applicationStatus) ?? ""
        approvalRequired = c.decodeLossyBoolIfPresent(forKey: .approvalRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresApproval)
            ?? false
        joinStatus = decodedJoinStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && approvalRequired
            ? "pending"
            : decodedJoinStatus
        current = c.decodeLossyBoolIfPresent(forKey: .current) ?? false
        accountStatus = try c.decodeIfPresent(String.self, forKey: .accountStatus) ?? ""
        tenantStatus = try c.decodeIfPresent(String.self, forKey: .tenantStatus) ?? status
        memberStatus = try c.decodeIfPresent(String.self, forKey: .memberStatus) ?? joinStatus
        let decodedEnterable = c.decodeLossyBoolIfPresent(forKey: .enterable)
            ?? c.decodeLossyBoolIfPresent(forKey: .canEnter)
        let decodedDisabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason) ?? ""
        let decodedReasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode) ?? ""
        let decodedReasonText = try c.decodeIfPresent(String.self, forKey: .reasonText) ?? ""
        let decodedReasonMessage = try c.decodeIfPresent(String.self, forKey: .reasonMessage) ?? ""
        let decodedProjectionStatus = try c.decodeIfPresent(String.self, forKey: .memberProjectionStatus)
            ?? c.decodeIfPresent(String.self, forKey: .memberProjectionStatusCamel)
            ?? ""
        let projectionReason = try c.decodeIfPresent(String.self, forKey: .memberProjectionReasonCode)
            ?? c.decodeIfPresent(String.self, forKey: .memberProjectionReasonCodeCamel)
            ?? RemoteWorkspaceAdmissionReconciliation.projectionReasonCode(status: decodedProjectionStatus)
        let rawDisabledReason = [
            decodedDisabledReason,
            decodedReasonCode,
            projectionReason,
            decodedReasonText,
            decodedReasonMessage
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let decodedCanSwitch = c.decodeLossyBoolIfPresent(forKey: .canSwitch)
        let normalizedJoinStatus = Self.normalizedWorkspaceStatus(joinStatus)
        let normalizedAccountStatus = Self.normalizedWorkspaceStatus(accountStatus)
        let normalizedTenantStatus = Self.normalizedWorkspaceStatus(tenantStatus)
        let normalizedMemberStatus = Self.normalizedWorkspaceStatus(memberStatus)
        let activeAccountStatuses = ["", "normal", "active", "enabled"]
        let activeTenantStatuses = ["", "normal", "active", "enabled"]
        let activeMemberStatuses = ["", "normal", "active", "enabled", "joined"]
        let statusAllowsEntry = activeAccountStatuses.contains(normalizedAccountStatus)
            && activeTenantStatuses.contains(normalizedTenantStatus)
            && activeMemberStatuses.contains(normalizedMemberStatus)
        let fallbackCanSwitch = decodedCanSwitch ?? ["joined", "alreadyjoined", "approved", "autoapproved", "accepted", "passed", "active", "enabled", "normal"].contains(normalizedJoinStatus)
        let projectionSyncingReasonIsStale = RemoteWorkspaceAdmissionReconciliation.isStaleMemberProjectionSyncingReady(
            reason: rawDisabledReason,
            projectionStatus: decodedProjectionStatus,
            joinStatus: joinStatus,
            applicationStatus: applicationStatus,
            accountStatus: accountStatus,
            tenantStatus: tenantStatus,
            memberStatus: memberStatus,
            role: memberRole
        )
        disabledReason = projectionSyncingReasonIsStale ? "" : rawDisabledReason
        enterable = projectionSyncingReasonIsStale && decodedEnterable == false ? true : decodedEnterable
        canSwitch = projectionSyncingReasonIsStale && decodedCanSwitch == false
            ? true
            : (decodedCanSwitch ?? (enterable ?? (fallbackCanSwitch && statusAllowsEntry)))
    }

    private static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    private static func projectionReasonCode(status: String) -> String {
        let normalized = normalizedWorkspaceStatus(status)
        if ["missing", "pending", "queued", "syncing", "inprogress", "stale"].contains(normalized) {
            return "member_projection_syncing"
        }
        if ["failed", "failure", "error", "conflict", "rejected", "reject"].contains(normalized) {
            return "member_projection_failed"
        }
        return ""
    }
}

struct RemoteWorkspaceJoinApplication: Decodable {
    let id: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case applicationID = "application_id"
        case status
        case applicationStatus = "application_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .applicationID)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .applicationStatus)
            ?? ""
    }
}

struct RemoteWorkspaceJoinResult: Decodable {
    let tenant: RemoteWorkspaceTenant?
    let member: RemoteTenantMember?
    let application: RemoteWorkspaceJoinApplication?
    let status: String
    let joinType: String
    let requiresApproval: Bool

    enum CodingKeys: String, CodingKey {
        case tenant
        case workspace
        case member
        case application
        case status
        case joinStatus = "join_status"
        case membershipStatus = "membership_status"
        case applicationStatus = "application_status"
        case joinType = "join_type"
        case approvalRequired = "approval_required"
        case requiresApproval = "requires_approval"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .tenant)
            ?? c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .workspace)
        member = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .member)
        application = try c.decodeIfPresent(RemoteWorkspaceJoinApplication.self, forKey: .application)
        requiresApproval = c.decodeLossyBoolIfPresent(forKey: .approvalRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresApproval)
            ?? false
        let decodedStatus = try c.decodeIfPresent(String.self, forKey: .status)
        let decodedJoinStatus = try c.decodeIfPresent(String.self, forKey: .joinStatus)
        let decodedMembershipStatus = try c.decodeIfPresent(String.self, forKey: .membershipStatus)
        let decodedApplicationStatus = try c.decodeIfPresent(String.self, forKey: .applicationStatus)
        status = decodedStatus
            ?? decodedJoinStatus
            ?? decodedMembershipStatus
            ?? decodedApplicationStatus
            ?? application?.status
            ?? tenant?.joinStatus
            ?? (requiresApproval ? "pending" : nil)
            ?? ""
        joinType = (try c.decodeIfPresent(String.self, forKey: .joinType) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct RemoteMyInviteCode: Decodable, Equatable {
    let enabled: Bool
    let status: String
    let reasonCode: String
    let item: RemoteMemberInviteCodeItem?

    enum CodingKeys: String, CodingKey {
        case enabled
        case status
        case reasonCode = "reason_code"
        case reasonCodeCamel = "reasonCode"
        case item
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decodeLossyBoolIfPresent(forKey: .enabled) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? Self.itemStatusFallback(from: c)
        reasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode)
            ?? c.decodeIfPresent(String.self, forKey: .reasonCodeCamel)
            ?? ""
        item = try c.decodeIfPresent(RemoteMemberInviteCodeItem.self, forKey: .item)
    }

    private static func itemStatusFallback(from container: KeyedDecodingContainer<CodingKeys>) -> String {
        guard let item = try? container.decodeIfPresent(RemoteMemberInviteCodeItem.self, forKey: .item) else {
            return ""
        }
        return item.status
    }

    var memberInviteCode: String {
        item?.memberInviteCode.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var isSyncFailed: Bool {
        item?.syncStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "failed"
    }

    var isUsableForRegistration: Bool {
        enabled && !isSyncFailed && !memberInviteCode.isEmpty
    }

    var shouldHidePersonalInviteModule: Bool {
        !enabled
            && item == nil
            && reasonCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "member_invite_code_role_not_allowed"
    }

    func matchesAuthority(tenantID: String, imUID: String) -> Bool {
        guard let item else { return true }
        let expectedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedIMUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let responseTenantID = item.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let responseIMUID = item.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !expectedTenantID.isEmpty
            && !expectedIMUID.isEmpty
            && responseTenantID == expectedTenantID
            && responseIMUID == expectedIMUID
    }
}

struct MyInviteCodePresentation: Equatable {
    let title: String
    let subtitle: String
    let displayCode: String
    let copyValue: String?
    let isUsableForRegistration: Bool
    let isWarning: Bool
    let shouldShowStats: Bool

    init(inviteCode: RemoteMyInviteCode?, isLoading: Bool, errorMessage: String?) {
        let code = inviteCode?.memberInviteCode.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usable = inviteCode?.isUsableForRegistration == true && !code.isEmpty
        displayCode = code
        isUsableForRegistration = usable
        copyValue = !isLoading && usable ? code : nil
        shouldShowStats = usable && inviteCode?.item != nil
        isWarning = !error.isEmpty || inviteCode?.isSyncFailed == true || (!code.isEmpty && !usable)

        if isLoading {
            title = "正在获取"
            subtitle = "正在读取当前企业邀请码"
        } else if !code.isEmpty {
            title = code
            if !error.isEmpty {
                subtitle = error
            } else if inviteCode?.isSyncFailed == true {
                subtitle = "邀请码暂不可用于注册"
            } else if usable {
                subtitle = "可分享给同企业成员注册"
            } else {
                subtitle = "邀请码当前不可用于注册"
            }
        } else if !error.isEmpty {
            title = "暂不可读取"
            subtitle = error
        } else {
            title = "暂不可用"
            subtitle = "当前角色暂无邀请码"
        }
    }
}

struct RemoteMemberInviteCodeItem: Decodable, Equatable {
    let id: String
    let tenantID: String
    let imUID: String
    let userID: String
    let displayName: String
    let role: String
    let memberInviteCode: String
    let status: String
    let syncStatus: String
    let syncErrorCode: String
    let syncVersion: Int
    let inviteCount: Int
    let joinedCount: Int
    let pendingCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case imUID = "im_uid"
        case imUIDCamel = "imUID"
        case userID = "user_id"
        case userIDCamel = "userID"
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case role
        case memberInviteCode = "member_invite_code"
        case status
        case syncStatus = "sync_status"
        case syncStatusCamel = "syncStatus"
        case syncErrorCode = "sync_error_code"
        case syncErrorCodeCamel = "syncErrorCode"
        case syncVersion = "sync_version"
        case syncVersionCamel = "syncVersion"
        case inviteCount = "invite_count"
        case inviteCountCamel = "inviteCount"
        case joinedCount = "joined_count"
        case joinedCountCamel = "joinedCount"
        case pendingCount = "pending_count"
        case pendingCountCamel = "pendingCount"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .imUIDCamel)
            ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
            ?? c.decodeIfPresent(String.self, forKey: .userIDCamel)
            ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        memberInviteCode = try c.decodeIfPresent(String.self, forKey: .memberInviteCode) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        syncStatus = try c.decodeIfPresent(String.self, forKey: .syncStatus)
            ?? c.decodeIfPresent(String.self, forKey: .syncStatusCamel)
            ?? ""
        syncErrorCode = try c.decodeIfPresent(String.self, forKey: .syncErrorCode)
            ?? c.decodeIfPresent(String.self, forKey: .syncErrorCodeCamel)
            ?? ""
        syncVersion = c.decodeLossyIntIfPresent(forKey: .syncVersion)
            ?? c.decodeLossyIntIfPresent(forKey: .syncVersionCamel)
            ?? 0
        inviteCount = c.decodeLossyIntIfPresent(forKey: .inviteCount)
            ?? c.decodeLossyIntIfPresent(forKey: .inviteCountCamel)
            ?? 0
        joinedCount = c.decodeLossyIntIfPresent(forKey: .joinedCount)
            ?? c.decodeLossyIntIfPresent(forKey: .joinedCountCamel)
            ?? 0
        pendingCount = c.decodeLossyIntIfPresent(forKey: .pendingCount)
            ?? c.decodeLossyIntIfPresent(forKey: .pendingCountCamel)
            ?? 0
    }
}

struct RemoteAuthSessionRefreshResult: Decodable {
    let platformToken: String
    let imToken: String
    let expiresAt: Int64
    let authSession: RemoteAuthSession
    let tenant: RemoteTenant?
    let member: RemoteTenantMember?
    let workspaces: [RemoteWorkspaceTenant]
    let authVersion: Int64
    let sessionGeneration: Int64

    enum CodingKeys: String, CodingKey {
        case platformToken = "platform_token"
        // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: match Android platform refresh field compatibility.
        case platformTokenCamel = "platformToken"
        // WDT_IOS_TOKEN_VALIDITY_20260924_END
        case imToken = "im_token"
        case imTokenCamel = "imToken"
        case apiToken = "api_token"
        case apiTokenCamel = "apiToken"
        case token
        case expiresAt = "expires_at"
        case accessExpiresAt = "access_expires_at"
        case authSession = "auth_session"
        case authSessionCamel = "authSession"
        case refreshSession = "refresh_session"
        case refreshSessionCamel = "refreshSession"
        case session
        case tenant
        case member
        case workspaces
        case authVersion = "auth_version"
        case sessionGeneration = "session_generation"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sessionPayload = try c.decodeIfPresent(RemoteTenantLoginSessionPayload.self, forKey: .session)
        // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: platform refresh may return snake_case or camelCase.
        platformToken = try c.decodeIfPresent(String.self, forKey: .platformToken)
            ?? c.decodeIfPresent(String.self, forKey: .platformTokenCamel)
            ?? ""
        // WDT_IOS_TOKEN_VALIDITY_20260924_END
        imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
            ?? c.decodeIfPresent(String.self, forKey: .imTokenCamel)
            ?? c.decodeIfPresent(String.self, forKey: .apiToken)
            ?? c.decodeIfPresent(String.self, forKey: .apiTokenCamel)
            ?? c.decodeIfPresent(String.self, forKey: .token)
            ?? sessionPayload?.session.imToken
            ?? ""
        expiresAt = c.decodeLossyInt64IfPresent(forKey: .expiresAt)
            ?? c.decodeLossyInt64IfPresent(forKey: .accessExpiresAt)
            ?? sessionPayload?.session.expiresAt
            ?? 0
        authSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
            ?? c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSessionCamel)
            ?? c.decodeIfPresent(RemoteAuthSession.self, forKey: .refreshSession)
            ?? c.decodeIfPresent(RemoteAuthSession.self, forKey: .refreshSessionCamel)
            ?? sessionPayload?.session.authSession
            ?? RemoteAuthSession(from: decoder)
        if let decodedTenant = try c.decodeIfPresent(RemoteTenant.self, forKey: .tenant) {
            tenant = decodedTenant
        } else if let sessionTenant = sessionPayload?.tenant {
            tenant = RemoteTenant(profile: sessionTenant)
        } else {
            tenant = try RemoteTenant(from: decoder)
        }
        member = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .member)
        workspaces = try c.decodeIfPresent([RemoteWorkspaceTenant].self, forKey: .workspaces) ?? []
        authVersion = c.decodeLossyInt64IfPresent(forKey: .authVersion)
            ?? authSession.authVersion
        sessionGeneration = c.decodeLossyInt64IfPresent(forKey: .sessionGeneration)
            ?? authSession.sessionGeneration
    }
}

struct RemoteWorkspaceSwitchResult: Decodable {
    let tenant: RemoteWorkspaceTenant
    let member: RemoteTenantMember
    let user: RemoteIMUser?
    let session: RemoteIMSession
    let authSession: RemoteAuthSession?

    enum CodingKeys: String, CodingKey {
        case tenant
        case member
        case user
        case session
        case authSession = "auth_session"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decode(RemoteWorkspaceTenant.self, forKey: .tenant)
        member = try c.decode(RemoteTenantMember.self, forKey: .member)
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? c.decodeIfPresent(RemoteIMUser.self, forKey: .member)
        session = try c.decode(RemoteIMSession.self, forKey: .session)
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : session.authSession)
    }
}

struct RemoteDefaultWorkspaceResult: Decodable {
    let defaultWorkspaceID: String
    let defaultWorkspace: RemoteWorkspaceTenant?
    let defaultWorkspaceValid: Bool?
    let defaultWorkspaceReason: String

    enum CodingKeys: String, CodingKey {
        case defaultWorkspaceID = "default_workspace_id"
        case defaultWorkspaceIDCamel = "defaultWorkspaceId"
        case defaultCompanyID = "default_company_id"
        case defaultCompanyIDCamel = "defaultCompanyId"
        case defaultTenantID = "default_tenant_id"
        case defaultTenantIDCamel = "defaultTenantId"
        case defaultWorkspace = "default_workspace"
        case defaultCompany = "default_company"
        case defaultTenant = "default_tenant"
        case defaultCompanyValid = "default_company_valid"
        case defaultCompanyValidCamel = "defaultCompanyValid"
        case defaultWorkspaceValid = "default_workspace_valid"
        case defaultWorkspaceValidCamel = "defaultWorkspaceValid"
        case defaultTenantValid = "default_tenant_valid"
        case defaultTenantValidCamel = "defaultTenantValid"
        case defaultCompanyInvalidReason = "default_company_invalid_reason"
        case defaultCompanyInvalidReasonCamel = "defaultCompanyInvalidReason"
        case defaultWorkspaceInvalidReason = "default_workspace_invalid_reason"
        case defaultWorkspaceInvalidReasonCamel = "defaultWorkspaceInvalidReason"
        case defaultTenantInvalidReason = "default_tenant_invalid_reason"
        case defaultTenantInvalidReasonCamel = "defaultTenantInvalidReason"
        case defaultWorkspaceReason = "default_workspace_reason"
        case defaultWorkspaceReasonCamel = "defaultWorkspaceReason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultWorkspaceID = try c.decodeIfPresent(String.self, forKey: .defaultWorkspaceID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantIDCamel)
            ?? ""
        defaultWorkspace = try c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultWorkspace)
            ?? c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultCompany)
            ?? c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultTenant)
        defaultWorkspaceValid = c.decodeLossyBoolIfPresent(forKey: .defaultCompanyValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultCompanyValidCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceValidCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantValidCamel)
        defaultWorkspaceReason = try c.decodeIfPresent(String.self, forKey: .defaultWorkspaceReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantInvalidReasonCamel)
            ?? ""
    }
}

struct RemoteWorkspaceEntryState: Decodable {
    let status: String
    let tenantID: String
    let tenantName: String
    let tenantCode: String
    let pendingEntryTenantID: String
    let entrySource: String
    let canSwitch: Bool
    let pollAfterMS: Int
    let lastErrorCode: String
    let lastError: String
    let workspace: RemoteWorkspaceTenant?

    enum CodingKeys: String, CodingKey {
        case status
        case entryStatus = "entry_status"
        case entryStatusCamel = "entryStatus"
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case pendingEntryTenantID = "pending_entry_tenant_id"
        case pendingEntryTenantIDCamel = "pendingEntryTenantId"
        case entrySource = "entry_source"
        case entrySourceCamel = "entrySource"
        case canSwitch = "can_switch"
        case canSwitchCamel = "canSwitch"
        case pollAfterMS = "poll_after_ms"
        case pollAfterMSCamel = "pollAfterMs"
        case pollAfterMSUpperCamel = "pollAfterMS"
        case lastErrorCode = "last_error_code"
        case lastErrorCodeCamel = "lastErrorCode"
        case lastError = "last_error"
        case lastErrorCamel = "lastError"
        case workspace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .workspace)
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .entryStatus)
            ?? c.decodeIfPresent(String.self, forKey: .entryStatusCamel)
            ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? workspace?.id
            ?? ""
        tenantName = try c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
            ?? workspace?.name
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? workspace?.tenantCode
            ?? ""
        pendingEntryTenantID = try c.decodeIfPresent(String.self, forKey: .pendingEntryTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .pendingEntryTenantIDCamel)
            ?? ""
        entrySource = try c.decodeIfPresent(String.self, forKey: .entrySource)
            ?? c.decodeIfPresent(String.self, forKey: .entrySourceCamel)
            ?? ""
        canSwitch = c.decodeLossyBoolIfPresent(forKey: .canSwitch)
            ?? c.decodeLossyBoolIfPresent(forKey: .canSwitchCamel)
            ?? true
        pollAfterMS = c.decodeLossyIntIfPresent(forKey: .pollAfterMS)
            ?? c.decodeLossyIntIfPresent(forKey: .pollAfterMSCamel)
            ?? c.decodeLossyIntIfPresent(forKey: .pollAfterMSUpperCamel)
            ?? 0
        lastErrorCode = try c.decodeIfPresent(String.self, forKey: .lastErrorCode)
            ?? c.decodeIfPresent(String.self, forKey: .lastErrorCodeCamel)
            ?? ""
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
            ?? c.decodeIfPresent(String.self, forKey: .lastErrorCamel)
            ?? ""
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var effectiveTenantID: String {
        [
            tenantID,
            pendingEntryTenantID,
            workspace?.id ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
    }
}

struct RemoteApp: Decodable {
    let appID: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
    }
}

struct RemoteTenantProfile: Decodable {
    let tenantID: String
    let tenantCode: String
    let name: String
    let status: String
    let logoURL: String
    let logoStatus: String
    let logoVersion: String
    let logoUpdatedAt: String
    let logoCacheKey: String
    let logoMime: String
    let logoWidth: Int?
    let logoHeight: Int?

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case id
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case code
        case name
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case status
        case logoURL = "logo_url"
        case logoUrl = "logoUrl"
        case logoStatus = "logo_status"
        case logoStatusCamel = "logoStatus"
        case logoVersion = "logo_version"
        case logoVersionCamel = "logoVersion"
        case logoUpdatedAt = "logo_updated_at"
        case logoUpdatedAtCamel = "logoUpdatedAt"
        case logoCacheKey = "logo_cache_key"
        case logoCacheKeyCamel = "logoCacheKey"
        case logoObjectKey = "logo_object_key"
        case logoMime = "logo_mime"
        case logoMimeCamel = "logoMime"
        case logoWidth = "logo_width"
        case logoWidthCamel = "logoWidth"
        case logoHeight = "logo_height"
        case logoHeightCamel = "logoHeight"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .code)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        let decodedLogoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            ?? c.decodeIfPresent(String.self, forKey: .logoUrl)
            ?? ""
        let decodedLogoObjectKey = try c.decodeIfPresent(String.self, forKey: .logoObjectKey) ?? ""
        logoURL = displayableTenantLogoURL(primary: decodedLogoURL, fallback: decodedLogoObjectKey)
        logoStatus = try c.decodeIfPresent(String.self, forKey: .logoStatus)
            ?? c.decodeIfPresent(String.self, forKey: .logoStatusCamel)
            ?? ""
        logoVersion = try c.decodeIfPresent(String.self, forKey: .logoVersion)
            ?? c.decodeIfPresent(String.self, forKey: .logoVersionCamel)
            ?? ""
        logoUpdatedAt = try c.decodeIfPresent(String.self, forKey: .logoUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .logoUpdatedAtCamel)
            ?? ""
        logoCacheKey = try c.decodeIfPresent(String.self, forKey: .logoCacheKey)
            ?? c.decodeIfPresent(String.self, forKey: .logoCacheKeyCamel)
            ?? decodedLogoObjectKey
        logoMime = try c.decodeIfPresent(String.self, forKey: .logoMime)
            ?? c.decodeIfPresent(String.self, forKey: .logoMimeCamel)
            ?? ""
        logoWidth = c.decodeLossyIntIfPresent(forKey: .logoWidth)
            ?? c.decodeLossyIntIfPresent(forKey: .logoWidthCamel)
        logoHeight = c.decodeLossyIntIfPresent(forKey: .logoHeight)
            ?? c.decodeLossyIntIfPresent(forKey: .logoHeightCamel)
    }
}

struct RemoteMeProfile: Decodable {
    let tenantID: String
    let imUID: String
    let userID: String
    let username: String
    let nickname: String
    let userRevision: Int64?
    let identityGeneration: Int64?
    let phone: String
    let phoneVerified: Bool
    let phoneBindingKnown: Bool
    let status: String
    let presenceStatus: String
    let online: Bool
    let onlineKnown: Bool
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let departmentName: String
    let departmentPath: [String]
    let departmentPathNames: [String]

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantID"
        case imUID = "im_uid"
        case userID = "user_id"
        case username
        case nickname
        case userRevision = "user_revision"
        case userRevisionCamel = "userRevision"
        case identityGeneration = "identity_generation"
        case identityGenerationCamel = "identityGeneration"
        case phone
        case phoneMasked = "phone_masked"
        case phoneVerified = "phone_verified"
        case phoneVerifiedAt = "phone_verified_at"
        case phoneBound = "phone_bound"
        case mobileVerified = "mobile_verified"
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        userRevision = c.decodeLossyInt64IfPresent(forKey: .userRevision)
            ?? c.decodeLossyInt64IfPresent(forKey: .userRevisionCamel)
        identityGeneration = c.decodeLossyInt64IfPresent(forKey: .identityGeneration)
            ?? c.decodeLossyInt64IfPresent(forKey: .identityGenerationCamel)
        phone = try c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? c.decodeIfPresent(String.self, forKey: .phone)
            ?? ""
        let phoneVerifiedAt = try c.decodeIfPresent(String.self, forKey: .phoneVerifiedAt) ?? ""
        let explicitPhoneVerified = decodeFlexibleBoolIfPresent(c, keys: [.phoneVerified, .phoneBound, .mobileVerified])
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        phoneVerified = explicitPhoneVerified
            ?? (!phoneVerifiedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !normalizedPhone.isEmpty)
        phoneBindingKnown = explicitPhoneVerified != nil
            || !phoneVerifiedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !normalizedPhone.isEmpty
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        presenceStatus = try c.decodeIfPresent(String.self, forKey: .presenceStatus) ?? ""
        let decodedOnline = c.decodeLossyBoolIfPresent(forKey: .online)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
        online = decodedOnline ?? false
        onlineKnown = decodedOnline != nil
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        departmentName = try c.decodeIfPresent(String.self, forKey: .departmentName)
            ?? c.decodeIfPresent(String.self, forKey: .departmentNameCamel)
            ?? ""
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
    }
}

struct RemoteAccountCancellationResponse: Decodable {
    let cancelled: Bool
    let profile: RemoteMeProfile?

    enum CodingKeys: String, CodingKey {
        case cancelled
        case profile
        case user
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cancelled = c.decodeLossyBoolIfPresent(forKey: .cancelled) ?? false
        profile = try c.decodeIfPresent(RemoteMeProfile.self, forKey: .profile)
            ?? c.decodeIfPresent(RemoteMeProfile.self, forKey: .user)
    }
}

struct RemotePasswordChangeResponse: Decodable {
    let updated: Bool
    let requiresRelogin: Bool
    let sessionRemainsActive: Bool
    let profile: RemoteMeProfile?

    enum CodingKeys: String, CodingKey {
        case updated
        case requiresRelogin = "requires_relogin"
        case requiresReloginCamel = "requiresRelogin"
        case sessionRemainsActive = "session_remains_active"
        case sessionRemainsActiveCamel = "sessionRemainsActive"
        case profile
        case user
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updated = c.decodeLossyBoolIfPresent(forKey: .updated) ?? false
        requiresRelogin = c.decodeLossyBoolIfPresent(forKey: .requiresRelogin)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresReloginCamel)
            ?? false
        sessionRemainsActive = c.decodeLossyBoolIfPresent(forKey: .sessionRemainsActive)
            ?? c.decodeLossyBoolIfPresent(forKey: .sessionRemainsActiveCamel)
            ?? true
        profile = try c.decodeIfPresent(RemoteMeProfile.self, forKey: .profile)
            ?? c.decodeIfPresent(RemoteMeProfile.self, forKey: .user)
    }
}

struct RemoteTenantContext: Decodable {
    let tenantID: String
    let imUID: String
    let appID: String
    let deviceID: String
    let tenant: RemoteTenantProfile
    let user: RemoteIMUser?
    let departmentEnabled: Bool?
    let clientPolicy: RemoteTenantClientPolicy?

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case id
        case imUID = "im_uid"
        case appID = "app_id"
        case deviceID = "device_id"
        case tenant
        case user
        case tenantPolicy = "tenant_policy"
        case tenantPolicyCamel = "tenantPolicy"
        case organization
    }

    enum TenantPolicyCodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
        case organization
    }

    enum OrganizationCodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        if let nestedTenant = try c.decodeIfPresent(RemoteTenantProfile.self, forKey: .tenant) {
            tenant = nestedTenant
        } else {
            tenant = try RemoteTenantProfile(from: decoder)
        }
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
        clientPolicy = try c.decodeIfPresent(RemoteTenantClientPolicy.self, forKey: .tenantPolicy)
            ?? c.decodeIfPresent(RemoteTenantClientPolicy.self, forKey: .tenantPolicyCamel)
        let policy = (try? c.nestedContainer(keyedBy: TenantPolicyCodingKeys.self, forKey: .tenantPolicy))
            ?? (try? c.nestedContainer(keyedBy: TenantPolicyCodingKeys.self, forKey: .tenantPolicyCamel))
        let policyOrganization = policy.flatMap {
            try? $0.nestedContainer(keyedBy: OrganizationCodingKeys.self, forKey: .organization)
        }
        let rootOrganization = try? c.nestedContainer(keyedBy: OrganizationCodingKeys.self, forKey: .organization)
        departmentEnabled = policy?.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? policy?.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? policyOrganization?.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? policyOrganization?.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? rootOrganization?.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? rootOrganization?.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
    }
}

struct RemoteTenantClientPolicy: Decodable, Equatable {
    let allowMemberGroupCreation: Bool
    let hideMembershipSystemMessages: Bool
    let clientFriendRequests: Bool
    let showGroupMemberCount: Bool
    let groupMemberCountPolicyGeneration: Int64
    let groupMemberCountContractVersion: Int
    let groupMemberCountPolicyAuthoritative: Bool
    let groupMemberCountPolicyPresent: Bool
    let showOnlineStatus: Bool
    let showLastLoginTime: Bool
    let loginRequireBoundDevice: Bool
    let multiDeviceEnabled: Bool
    let multiDeviceContractVersion: Int
    let multiDevicePolicyAuthoritative: Bool
    let multiDevicePolicyPresent: Bool
    let messageExportEnabled: Bool
    let mediaOfflinePolicy: String
    let mediaOfflinePolicyPresent: Bool

    enum CodingKeys: String, CodingKey {
        case group
        case relationship
        case visibility
        case device
        case export
        case mediaCache = "media_cache"
        case mediaCacheCamel = "mediaCache"
        case mediaOfflinePolicy = "media_offline_policy"
        case mediaOfflinePolicyCamel = "mediaOfflinePolicy"
        case allowMemberGroupCreation = "allow_member_group_creation"
        case allowMemberGroupCreationCamel = "allowMemberGroupCreation"
        case onlyInternalCanCreateGroup = "only_internal_can_create_group"
        case onlyInternalCanCreateGroupCamel = "onlyInternalCanCreateGroup"
        case hideMembershipSystemMessages = "hide_membership_system_messages"
        case hideMembershipSystemMessagesCamel = "hideMembershipSystemMessages"
        case clientFriendRequests = "client_friend_requests"
        case clientFriendRequestsCamel = "clientFriendRequests"
        case showGroupMemberCount = "show_group_member_count"
        case showGroupMemberCountCamel = "showGroupMemberCount"
        case tenantPolicyGeneration = "tenant_policy_generation"
        case tenantPolicyGenerationCamel = "tenantPolicyGeneration"
        case contractVersion = "contract_version"
        case contractVersionCamel = "contractVersion"
        case authoritative
        case showOnlineStatus = "show_online_status"
        case showOnlineStatusCamel = "showOnlineStatus"
        case showLastLoginTime = "show_last_login_time"
        case showLastLoginTimeCamel = "showLastLoginTime"
        case loginRequireBoundDevice = "login_require_bound_device"
        case loginRequireBoundDeviceCamel = "loginRequireBoundDevice"
        case messageExportEnabled = "message_export_enabled"
        case messageExportEnabledCamel = "messageExportEnabled"
    }

    enum GroupCodingKeys: String, CodingKey {
        case allowMemberGroupCreation = "allow_member_group_creation"
        case allowMemberGroupCreationCamel = "allowMemberGroupCreation"
        case onlyInternalCanCreateGroup = "only_internal_can_create_group"
        case onlyInternalCanCreateGroupCamel = "onlyInternalCanCreateGroup"
        case hideMembershipSystemMessages = "hide_membership_system_messages"
        case hideMembershipSystemMessagesCamel = "hideMembershipSystemMessages"
    }

    enum RelationshipCodingKeys: String, CodingKey {
        case clientFriendRequests = "client_friend_requests"
        case clientFriendRequestsCamel = "clientFriendRequests"
    }

    enum VisibilityCodingKeys: String, CodingKey {
        case showGroupMemberCount = "show_group_member_count"
        case showGroupMemberCountCamel = "showGroupMemberCount"
        case tenantPolicyGeneration = "tenant_policy_generation"
        case tenantPolicyGenerationCamel = "tenantPolicyGeneration"
        case contractVersion = "contract_version"
        case contractVersionCamel = "contractVersion"
        case authoritative
        case showOnlineStatus = "show_online_status"
        case showOnlineStatusCamel = "showOnlineStatus"
        case showLastLoginTime = "show_last_login_time"
        case showLastLoginTimeCamel = "showLastLoginTime"
    }

    enum DeviceCodingKeys: String, CodingKey {
        case loginRequireBoundDevice = "login_require_bound_device"
        case loginRequireBoundDeviceCamel = "loginRequireBoundDevice"
        case multiDeviceEnabled = "multi_device_enabled"
        case authoritative
        case contractVersion = "contract_version"
    }

    enum ExportCodingKeys: String, CodingKey {
        case messageExportEnabled = "message_export_enabled"
        case messageExportEnabledCamel = "messageExportEnabled"
    }

    enum MediaCacheCodingKeys: String, CodingKey {
        case offlinePolicy = "offline_policy"
        case offlinePolicyCamel = "offlinePolicy"
    }

    init(
        allowMemberGroupCreation: Bool = false,
        hideMembershipSystemMessages: Bool = false,
        clientFriendRequests: Bool = false,
        showGroupMemberCount: Bool = false,
        groupMemberCountPolicyGeneration: Int64 = 0,
        groupMemberCountContractVersion: Int = 0,
        groupMemberCountPolicyAuthoritative: Bool = false,
        groupMemberCountPolicyPresent: Bool = false,
        showOnlineStatus: Bool = true,
        showLastLoginTime: Bool = false,
        loginRequireBoundDevice: Bool = false,
        multiDeviceEnabled: Bool = false,
        multiDeviceContractVersion: Int = 0,
        multiDevicePolicyAuthoritative: Bool = false,
        multiDevicePolicyPresent: Bool = false,
        messageExportEnabled: Bool = false,
        mediaOfflinePolicy: String = "standard",
        mediaOfflinePolicyPresent: Bool = false
    ) {
        self.allowMemberGroupCreation = allowMemberGroupCreation
        self.hideMembershipSystemMessages = hideMembershipSystemMessages
        self.clientFriendRequests = clientFriendRequests
        self.showGroupMemberCount = showGroupMemberCount
        self.groupMemberCountPolicyGeneration = max(0, groupMemberCountPolicyGeneration)
        self.groupMemberCountContractVersion = max(0, groupMemberCountContractVersion)
        self.groupMemberCountPolicyAuthoritative = groupMemberCountPolicyAuthoritative
        self.groupMemberCountPolicyPresent = groupMemberCountPolicyPresent
        self.showOnlineStatus = showOnlineStatus
        self.showLastLoginTime = showLastLoginTime
        self.loginRequireBoundDevice = loginRequireBoundDevice
        self.multiDeviceEnabled = multiDeviceEnabled
        self.multiDeviceContractVersion = max(0, multiDeviceContractVersion)
        self.multiDevicePolicyAuthoritative = multiDevicePolicyAuthoritative
        self.multiDevicePolicyPresent = multiDevicePolicyPresent
        self.messageExportEnabled = messageExportEnabled
        self.mediaOfflinePolicy = mediaOfflinePolicy
        self.mediaOfflinePolicyPresent = mediaOfflinePolicyPresent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let group = try? c.nestedContainer(keyedBy: GroupCodingKeys.self, forKey: .group)
        let relationship = try? c.nestedContainer(keyedBy: RelationshipCodingKeys.self, forKey: .relationship)
        let visibility = try? c.nestedContainer(keyedBy: VisibilityCodingKeys.self, forKey: .visibility)
        let device = try? c.nestedContainer(keyedBy: DeviceCodingKeys.self, forKey: .device)
        let export = try? c.nestedContainer(keyedBy: ExportCodingKeys.self, forKey: .export)
        let mediaCache = (try? c.nestedContainer(keyedBy: MediaCacheCodingKeys.self, forKey: .mediaCache))
            ?? (try? c.nestedContainer(keyedBy: MediaCacheCodingKeys.self, forKey: .mediaCacheCamel))

        let explicitMemberCreate = group?.decodeLossyBoolIfPresent(forKey: .allowMemberGroupCreation)
            ?? group?.decodeLossyBoolIfPresent(forKey: .allowMemberGroupCreationCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .allowMemberGroupCreation)
            ?? c.decodeLossyBoolIfPresent(forKey: .allowMemberGroupCreationCamel)
        let compatOnlyInternal = group?.decodeLossyBoolIfPresent(forKey: .onlyInternalCanCreateGroup)
            ?? group?.decodeLossyBoolIfPresent(forKey: .onlyInternalCanCreateGroupCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .onlyInternalCanCreateGroup)
            ?? c.decodeLossyBoolIfPresent(forKey: .onlyInternalCanCreateGroupCamel)
        allowMemberGroupCreation = explicitMemberCreate ?? compatOnlyInternal.map { !$0 } ?? false
        hideMembershipSystemMessages = group?.decodeLossyBoolIfPresent(forKey: .hideMembershipSystemMessages)
            ?? group?.decodeLossyBoolIfPresent(forKey: .hideMembershipSystemMessagesCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .hideMembershipSystemMessages)
            ?? c.decodeLossyBoolIfPresent(forKey: .hideMembershipSystemMessagesCamel)
            ?? false
        clientFriendRequests = relationship?.decodeLossyBoolIfPresent(forKey: .clientFriendRequests)
            ?? relationship?.decodeLossyBoolIfPresent(forKey: .clientFriendRequestsCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .clientFriendRequests)
            ?? c.decodeLossyBoolIfPresent(forKey: .clientFriendRequestsCamel)
            ?? false
        let strictShowGroupMemberCount =
            visibility?.decodeStrictBoolIfPresent(forKey: .showGroupMemberCount)
                ?? visibility?.decodeStrictBoolIfPresent(forKey: .showGroupMemberCountCamel)
                ?? c.decodeStrictBoolIfPresent(forKey: .showGroupMemberCount)
                ?? c.decodeStrictBoolIfPresent(forKey: .showGroupMemberCountCamel)
        let strictGroupMemberCountGeneration =
            visibility?.decodeStrictInt64IfPresent(forKey: .tenantPolicyGeneration)
                ?? visibility?.decodeStrictInt64IfPresent(forKey: .tenantPolicyGenerationCamel)
                ?? c.decodeStrictInt64IfPresent(forKey: .tenantPolicyGeneration)
                ?? c.decodeStrictInt64IfPresent(forKey: .tenantPolicyGenerationCamel)
        let strictGroupMemberCountContractVersion =
            visibility?.decodeStrictIntIfPresent(forKey: .contractVersion)
                ?? visibility?.decodeStrictIntIfPresent(forKey: .contractVersionCamel)
                ?? c.decodeStrictIntIfPresent(forKey: .contractVersion)
                ?? c.decodeStrictIntIfPresent(forKey: .contractVersionCamel)
        let strictGroupMemberCountAuthoritative =
            visibility?.decodeStrictBoolIfPresent(forKey: .authoritative)
                ?? c.decodeStrictBoolIfPresent(forKey: .authoritative)
        showGroupMemberCount = strictShowGroupMemberCount ?? false
        groupMemberCountPolicyGeneration = max(0, strictGroupMemberCountGeneration ?? 0)
        groupMemberCountContractVersion = max(0, strictGroupMemberCountContractVersion ?? 0)
        groupMemberCountPolicyAuthoritative = strictGroupMemberCountAuthoritative ?? false
        let hasShowGroupMemberCount =
            visibility?.contains(.showGroupMemberCount) == true ||
            visibility?.contains(.showGroupMemberCountCamel) == true ||
            c.contains(.showGroupMemberCount) ||
            c.contains(.showGroupMemberCountCamel)
        let hasGroupMemberCountGeneration =
            visibility?.contains(.tenantPolicyGeneration) == true ||
            visibility?.contains(.tenantPolicyGenerationCamel) == true ||
            c.contains(.tenantPolicyGeneration) ||
            c.contains(.tenantPolicyGenerationCamel)
        let hasGroupMemberCountContractVersion =
            visibility?.contains(.contractVersion) == true ||
            visibility?.contains(.contractVersionCamel) == true ||
            c.contains(.contractVersion) ||
            c.contains(.contractVersionCamel)
        let hasGroupMemberCountAuthoritative =
            visibility?.contains(.authoritative) == true ||
            c.contains(.authoritative)
        let hasInvalidShowGroupMemberCount =
            visibility?.containsInvalidStrictValue(Bool.self, forKey: .showGroupMemberCount) == true ||
            visibility?.containsInvalidStrictValue(Bool.self, forKey: .showGroupMemberCountCamel) == true ||
            c.containsInvalidStrictValue(Bool.self, forKey: .showGroupMemberCount) ||
            c.containsInvalidStrictValue(Bool.self, forKey: .showGroupMemberCountCamel)
        let hasInvalidGroupMemberCountGeneration =
            visibility?.containsInvalidStrictValue(Int64.self, forKey: .tenantPolicyGeneration) == true ||
            visibility?.containsInvalidStrictValue(Int64.self, forKey: .tenantPolicyGenerationCamel) == true ||
            c.containsInvalidStrictValue(Int64.self, forKey: .tenantPolicyGeneration) ||
            c.containsInvalidStrictValue(Int64.self, forKey: .tenantPolicyGenerationCamel)
        let hasInvalidGroupMemberCountContractVersion =
            visibility?.containsInvalidStrictValue(Int.self, forKey: .contractVersion) == true ||
            visibility?.containsInvalidStrictValue(Int.self, forKey: .contractVersionCamel) == true ||
            c.containsInvalidStrictValue(Int.self, forKey: .contractVersion) ||
            c.containsInvalidStrictValue(Int.self, forKey: .contractVersionCamel)
        let hasInvalidGroupMemberCountAuthoritative =
            visibility?.containsInvalidStrictValue(Bool.self, forKey: .authoritative) == true ||
            c.containsInvalidStrictValue(Bool.self, forKey: .authoritative)
        groupMemberCountPolicyPresent =
            hasShowGroupMemberCount &&
            hasGroupMemberCountGeneration &&
            hasGroupMemberCountContractVersion &&
            hasGroupMemberCountAuthoritative &&
            !hasInvalidShowGroupMemberCount &&
            !hasInvalidGroupMemberCountGeneration &&
            !hasInvalidGroupMemberCountContractVersion &&
            !hasInvalidGroupMemberCountAuthoritative &&
            strictShowGroupMemberCount != nil &&
            strictGroupMemberCountGeneration.map { $0 >= 0 } == true &&
            strictGroupMemberCountContractVersion.map { $0 >= 1 } == true &&
            strictGroupMemberCountAuthoritative != nil
        showOnlineStatus = visibility?.decodeLossyBoolIfPresent(forKey: .showOnlineStatus)
            ?? visibility?.decodeLossyBoolIfPresent(forKey: .showOnlineStatusCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .showOnlineStatus)
            ?? c.decodeLossyBoolIfPresent(forKey: .showOnlineStatusCamel)
            ?? true
        showLastLoginTime = visibility?.decodeLossyBoolIfPresent(forKey: .showLastLoginTime)
            ?? visibility?.decodeLossyBoolIfPresent(forKey: .showLastLoginTimeCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .showLastLoginTime)
            ?? c.decodeLossyBoolIfPresent(forKey: .showLastLoginTimeCamel)
            ?? false
        loginRequireBoundDevice = device?.decodeLossyBoolIfPresent(forKey: .loginRequireBoundDevice)
            ?? device?.decodeLossyBoolIfPresent(forKey: .loginRequireBoundDeviceCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .loginRequireBoundDevice)
            ?? c.decodeLossyBoolIfPresent(forKey: .loginRequireBoundDeviceCamel)
            ?? false
        let strictMultiDeviceEnabled = device?.decodeStrictBoolIfPresent(forKey: .multiDeviceEnabled)
        let strictMultiDeviceAuthoritative = device?.decodeStrictBoolIfPresent(forKey: .authoritative)
        let strictMultiDeviceContractVersion = device?.decodeStrictIntIfPresent(forKey: .contractVersion)
        let hasMultiDeviceEnabled = device?.contains(.multiDeviceEnabled) == true
        let hasMultiDeviceAuthoritative = device?.contains(.authoritative) == true
        let hasMultiDeviceContractVersion = device?.contains(.contractVersion) == true
        let hasInvalidMultiDeviceEnabled =
            device?.containsInvalidStrictValue(Bool.self, forKey: .multiDeviceEnabled) == true
        let hasInvalidMultiDeviceAuthoritative =
            device?.containsInvalidStrictValue(Bool.self, forKey: .authoritative) == true
        let hasInvalidMultiDeviceContractVersion =
            device?.containsInvalidStrictValue(Int.self, forKey: .contractVersion) == true
        multiDeviceEnabled = strictMultiDeviceEnabled ?? false
        multiDeviceContractVersion = max(0, strictMultiDeviceContractVersion ?? 0)
        multiDevicePolicyAuthoritative = strictMultiDeviceAuthoritative ?? false
        multiDevicePolicyPresent =
            hasMultiDeviceEnabled &&
            hasMultiDeviceAuthoritative &&
            hasMultiDeviceContractVersion &&
            !hasInvalidMultiDeviceEnabled &&
            !hasInvalidMultiDeviceAuthoritative &&
            !hasInvalidMultiDeviceContractVersion &&
            strictMultiDeviceEnabled != nil &&
            strictMultiDeviceAuthoritative == true &&
            strictMultiDeviceContractVersion == 1
        messageExportEnabled = export?.decodeLossyBoolIfPresent(forKey: .messageExportEnabled)
            ?? export?.decodeLossyBoolIfPresent(forKey: .messageExportEnabledCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .messageExportEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .messageExportEnabledCamel)
            ?? false
        let decodedMediaOfflinePolicy = (try? mediaCache?.decodeIfPresent(String.self, forKey: .offlinePolicy))
            ?? (try? mediaCache?.decodeIfPresent(String.self, forKey: .offlinePolicyCamel))
            ?? (try? c.decodeIfPresent(String.self, forKey: .mediaOfflinePolicy))
            ?? (try? c.decodeIfPresent(String.self, forKey: .mediaOfflinePolicyCamel))
        mediaOfflinePolicy = decodedMediaOfflinePolicy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "standard"
        mediaOfflinePolicyPresent = decodedMediaOfflinePolicy != nil
    }
}

struct RemoteFriendRelation: Decodable {
    let ownerUID: String
    let friendUID: String
    let authoritativeFriendUID: String?
    let friendUserID: String
    let authoritativeFriendUserID: String?
    let ownerAvatar: String
    let friendAvatar: String
    let friendAvatarVersion: String
    let friendAvatarUpdatedAt: String
    let friendNickname: String
    let displayName: String
    let rawNickname: String
    let displayNameSource: String
    let friendStatus: String
    let friendOnline: Bool
    let friendOnlineKnown: Bool
    let friendLastSeenAt: String
    let friendPhone: String
    let friendPhoneMasked: String
    let remark: String?
    let departmentName: String
    let departmentPath: [String]
    let departmentPathNames: [String]

    var visiblePhone: String {
        friendPhoneMasked.isEmpty ? friendPhone : friendPhoneMasked
    }

    enum CodingKeys: String, CodingKey {
        case ownerUID = "owner_uid"
        case ownerIMUID = "owner_im_uid"
        case friendUID = "friend_uid"
        case friendIMUID = "friend_im_uid"
        case friendUserID = "friend_user_id"
        case imUID = "im_uid"
        case userID = "user_id"
        case peerUID = "peer_uid"
        case targetUID = "target_uid"
        case ownerAvatar = "owner_avatar"
        case friendAvatar = "friend_avatar"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case friendAvatarVersion = "friend_avatar_version"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case friendAvatarUpdatedAt = "friend_avatar_updated_at"
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case friendNickname = "friend_nickname"
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case rawNickname = "raw_nickname"
        case rawNicknameCamel = "rawNickname"
        case displayNameSource = "display_name_source"
        case displayNameSourceCamel = "displayNameSource"
        case friendPhone = "friend_phone"
        case friendPhoneMasked = "friend_phone_masked"
        case phone
        case phoneMasked = "phone_masked"
        case nickname
        case name
        case status
        case presenceStatus = "presence_status"
        case friendStatus = "friend_status"
        case friendStatusCamel = "friendStatus"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case friendOnline = "friend_online"
        case friendOnlineCamel = "friendOnline"
        case friendLastSeenAt = "friend_last_seen_at"
        case friendLastSeenAtCamel = "friendLastSeenAt"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case remark
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerUID = [
            try c.decodeIfPresent(String.self, forKey: .ownerUID),
            try c.decodeIfPresent(String.self, forKey: .ownerIMUID)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let canonicalFriendUID = try c.decodeIfPresent(String.self, forKey: .friendUID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        authoritativeFriendUID = canonicalFriendUID.isEmpty ? nil : canonicalFriendUID
        let canonicalFriendUserID = try c.decodeIfPresent(String.self, forKey: .friendUserID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        authoritativeFriendUserID = canonicalFriendUserID.isEmpty ? nil : canonicalFriendUserID
        friendUID = [
            try c.decodeIfPresent(String.self, forKey: .friendUID),
            try c.decodeIfPresent(String.self, forKey: .friendIMUID),
            try c.decodeIfPresent(String.self, forKey: .friendUserID),
            try c.decodeIfPresent(String.self, forKey: .imUID),
            try c.decodeIfPresent(String.self, forKey: .userID),
            try c.decodeIfPresent(String.self, forKey: .peerUID),
            try c.decodeIfPresent(String.self, forKey: .targetUID)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        friendUserID = [
            try c.decodeIfPresent(String.self, forKey: .friendUserID),
            try c.decodeIfPresent(String.self, forKey: .userID),
            friendUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        ownerAvatar = try c.decodeIfPresent(String.self, forKey: .ownerAvatar) ?? ""
        friendAvatar = try c.decodeIfPresent(String.self, forKey: .friendAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        friendAvatarVersion = try c.decodeIfPresent(String.self, forKey: .friendAvatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        friendAvatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .friendAvatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        friendNickname = try c.decodeIfPresent(String.self, forKey: .friendNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .nickname)
            ?? ""
        rawNickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? friendNickname
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? friendNickname
        displayNameSource = try c.decodeIfPresent(String.self, forKey: .displayNameSource)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameSourceCamel)
            ?? ""
        friendStatus = [
            try c.decodeIfPresent(String.self, forKey: .presenceStatus),
            try c.decodeIfPresent(String.self, forKey: .friendStatus),
            try c.decodeIfPresent(String.self, forKey: .friendStatusCamel),
            try c.decodeIfPresent(String.self, forKey: .status)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let decodedFriendOnline = c.decodeLossyBoolIfPresent(forKey: .friendOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .friendOnlineCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .online)
            ?? false
        friendOnline = decodedFriendOnline
        friendOnlineKnown = c.decodeLossyBoolIfPresent(forKey: .friendOnline) != nil
            || c.decodeLossyBoolIfPresent(forKey: .friendOnlineCamel) != nil
            || c.decodeLossyBoolIfPresent(forKey: .isOnline) != nil
            || c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel) != nil
            || c.decodeLossyBoolIfPresent(forKey: .online) != nil
        friendLastSeenAt = [
            try c.decodeIfPresent(String.self, forKey: .friendLastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .friendLastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAt),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAtCamel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        friendPhone = try c.decodeIfPresent(String.self, forKey: .friendPhone)
            ?? c.decodeIfPresent(String.self, forKey: .phone)
            ?? ""
        friendPhoneMasked = try c.decodeIfPresent(String.self, forKey: .friendPhoneMasked)
            ?? c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? ""
        remark = try c.decodeIfPresent(String.self, forKey: .remark)
        departmentName = try c.decodeIfPresent(String.self, forKey: .departmentName)
            ?? c.decodeIfPresent(String.self, forKey: .departmentNameCamel)
            ?? ""
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
    }
}

struct RemoteFriendProfile: Decodable {
    let imUID: String
    let userID: String
    let nickname: String
    let displayName: String
    let rawNickname: String
    let displayNameSource: String
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let phone: String
    let phoneMasked: String
    let remark: String
    let departmentName: String
    let departmentPath: [String]
    let departmentPathNames: [String]

    var visiblePhone: String {
        phoneMasked.isEmpty ? phone : phoneMasked
    }

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case nickname
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case rawNickname = "raw_nickname"
        case rawNicknameCamel = "rawNickname"
        case displayNameSource = "display_name_source"
        case displayNameSourceCamel = "displayNameSource"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case phone
        case phoneMasked = "phone_masked"
        case remark
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        nickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .nickname)
            ?? ""
        rawNickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? nickname
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? nickname
        displayNameSource = try c.decodeIfPresent(String.self, forKey: .displayNameSource)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameSourceCamel)
            ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        phoneMasked = try c.decodeIfPresent(String.self, forKey: .phoneMasked) ?? ""
        remark = try c.decodeIfPresent(String.self, forKey: .remark) ?? ""
        departmentName = try c.decodeIfPresent(String.self, forKey: .departmentName)
            ?? c.decodeIfPresent(String.self, forKey: .departmentNameCamel)
            ?? ""
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
    }
}

struct RemoteBlacklistRelation: Decodable {
    let ownerUID: String
    let blockedUID: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case ownerUID = "owner_uid"
        case blockedUID = "blocked_uid"
        case reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerUID = try c.decodeIfPresent(String.self, forKey: .ownerUID) ?? ""
        blockedUID = try c.decodeIfPresent(String.self, forKey: .blockedUID) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

struct RemoteFriendApplication: Decodable {
    let id: String
    let applicantUID: String
    let applicantName: String
    let applicantAvatar: String
    let targetUID: String
    let targetName: String
    let targetAvatar: String
    let sourceGroupName: String?
    let source: String
    let status: String
    let tenantReviewStatus: String
    let direction: String
    let actionableByCurrentUser: Bool?
    let peerReviewStatus: String
    let message: String?
    let outcome: String
    let relationStatus: String
    let friendAction: String
    let friendFlow: String
    let directlyEstablished: Bool
    let requiresTenantReview: Bool?
    let requiresTargetApproval: Bool?
    let resolutionMode: String

    enum CodingKeys: String, CodingKey {
        case id
        case applicantUID = "applicant_uid"
        case applicantName = "applicant_name"
        case applicantNickname = "applicant_nickname"
        case applicantAvatar = "applicant_avatar"
        case targetUID = "target_uid"
        case targetName = "target_name"
        case targetNickname = "target_nickname"
        case targetAvatar = "target_avatar"
        case sourceGroupName = "source_group_name"
        case source
        case status
        case tenantReviewStatus = "tenant_review_status"
        case direction
        case actionableByCurrentUser = "actionable_by_current_user"
        case peerReviewStatus = "peer_review_status"
        case message
        case outcome
        case relationStatus = "relation_status"
        case friendAction = "friend_action"
        case friendFlow = "friend_flow"
        case directlyEstablished = "directly_established"
        case requiresTenantReview = "requires_tenant_review"
        case requiresTargetApproval = "requires_target_approval"
        case resolutionMode = "resolution_mode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        applicantUID = try c.decodeIfPresent(String.self, forKey: .applicantUID) ?? ""
        applicantName = try c.decodeIfPresent(String.self, forKey: .applicantName)
            ?? c.decodeIfPresent(String.self, forKey: .applicantNickname)
            ?? ""
        applicantAvatar = try c.decodeIfPresent(String.self, forKey: .applicantAvatar) ?? ""
        targetUID = try c.decodeIfPresent(String.self, forKey: .targetUID) ?? ""
        targetName = try c.decodeIfPresent(String.self, forKey: .targetName)
            ?? c.decodeIfPresent(String.self, forKey: .targetNickname)
            ?? ""
        targetAvatar = try c.decodeIfPresent(String.self, forKey: .targetAvatar) ?? ""
        sourceGroupName = try c.decodeIfPresent(String.self, forKey: .sourceGroupName)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        tenantReviewStatus = try c.decodeIfPresent(String.self, forKey: .tenantReviewStatus) ?? ""
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        actionableByCurrentUser = try c.decodeIfPresent(Bool.self, forKey: .actionableByCurrentUser)
        peerReviewStatus = try c.decodeIfPresent(String.self, forKey: .peerReviewStatus) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        relationStatus = try c.decodeIfPresent(String.self, forKey: .relationStatus) ?? ""
        friendAction = try c.decodeIfPresent(String.self, forKey: .friendAction) ?? ""
        friendFlow = try c.decodeIfPresent(String.self, forKey: .friendFlow) ?? ""
        directlyEstablished = c.decodeLossyBoolIfPresent(forKey: .directlyEstablished) ?? false
        requiresTenantReview = c.decodeLossyBoolIfPresent(forKey: .requiresTenantReview)
        requiresTargetApproval = c.decodeLossyBoolIfPresent(forKey: .requiresTargetApproval)
        resolutionMode = try c.decodeIfPresent(String.self, forKey: .resolutionMode) ?? ""
    }
}

struct RemoteUserSearchItem: Decodable {
    let imUID: String
    let userID: String
    let nickname: String
    let displayName: String
    let rawNickname: String
    let displayNameSource: String
    let remark: String
    let phone: String
    let phoneMasked: String
    let avatar: String
    let status: String
    let presenceStatus: String
    let online: Bool
    let onlineKnown: Bool
    let lastSeenAt: String
    let relationStatus: String
    let canApplyFriend: Bool
    let reason: String
    let friendAction: String
    let friendFlow: String
    let requiresTenantReview: Bool?
    let requiresTargetApproval: Bool?

    var visiblePhone: String {
        phoneMasked.isEmpty ? phone : phoneMasked
    }

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case nickname
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case rawNickname = "raw_nickname"
        case rawNicknameCamel = "rawNickname"
        case displayNameSource = "display_name_source"
        case displayNameSourceCamel = "displayNameSource"
        case remark
        case phone
        case phoneMasked = "phone_masked"
        case avatar
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case relationStatus = "relation_status"
        case canApplyFriend = "can_apply_friend"
        case reason
        case friendAction = "friend_action"
        case friendFlow = "friend_flow"
        case requiresTenantReview = "requires_tenant_review"
        case requiresTargetApproval = "requires_target_approval"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        nickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .nickname)
            ?? userID
        rawNickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? nickname
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? nickname
        displayNameSource = try c.decodeIfPresent(String.self, forKey: .displayNameSource)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameSourceCamel)
            ?? ""
        remark = try c.decodeIfPresent(String.self, forKey: .remark) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        phoneMasked = try c.decodeIfPresent(String.self, forKey: .phoneMasked) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        presenceStatus = try c.decodeIfPresent(String.self, forKey: .presenceStatus) ?? ""
        let decodedOnline = c.decodeLossyBoolIfPresent(forKey: .online)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
        online = decodedOnline ?? false
        onlineKnown = decodedOnline != nil
        lastSeenAt = [
            try c.decodeIfPresent(String.self, forKey: .lastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAt),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAtCamel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        relationStatus = try c.decodeIfPresent(String.self, forKey: .relationStatus) ?? "none"
        canApplyFriend = try c.decodeIfPresent(Bool.self, forKey: .canApplyFriend) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        friendAction = try c.decodeIfPresent(String.self, forKey: .friendAction)
            ?? (canApplyFriend ? "request" : "none")
        friendFlow = try c.decodeIfPresent(String.self, forKey: .friendFlow) ?? ""
        requiresTenantReview = c.decodeLossyBoolIfPresent(forKey: .requiresTenantReview)
        requiresTargetApproval = c.decodeLossyBoolIfPresent(forKey: .requiresTargetApproval)
    }
}

enum RemoteUserSummaryProjection: Equatable, Sendable {
    case authoritative(UserSummaryV2)
    case authoritativeOmission
    case malformed
}

enum RemoteUserProfilesError: Error, Equatable {
    case invalidUID
    case duplicateUID(String)
    case overlappingUID(String)
    case invalidLimit
    case tooManyResults
}

struct RemoteUserProfileSummary: Decodable, Equatable, Sendable {
    let imUID: String
    let userID: String
    let userSummaryProjection: RemoteUserSummaryProjection

    private enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case userSummary = "user_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try container.decode(String.self, forKey: .imUID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        userID = try container.decodeIfPresent(String.self, forKey: .userID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? imUID
        guard !imUID.isEmpty else {
            throw RemoteUserProfilesError.invalidUID
        }
        guard let rawSummary = try container.decodeIfPresent(
            JSONValue.self,
            forKey: .userSummary
        ) else {
            userSummaryProjection = .authoritativeOmission
            return
        }
        guard case .object = rawSummary,
              let data = try? JSONEncoder().encode(rawSummary),
              let summary = try? JSONDecoder().decode(UserSummaryV2.self, from: data),
              userID == imUID,
              summary.imUID == imUID,
              summary.userID == imUID else {
            userSummaryProjection = .malformed
            return
        }
        userSummaryProjection = .authoritative(summary)
    }
}

struct RemoteUserProfilesResponse: Decodable, Equatable, Sendable {
    let items: [RemoteUserProfileSummary]
    let missingUIDs: [String]
    let maxUIDs: Int

    private enum CodingKeys: String, CodingKey {
        case items
        case missingUIDs = "missing_uids"
        case maxUIDs = "max_uids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([RemoteUserProfileSummary].self, forKey: .items)
        missingUIDs = try container.decode([String].self, forKey: .missingUIDs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        maxUIDs = try container.decode(Int.self, forKey: .maxUIDs)
        guard maxUIDs > 0, maxUIDs <= CertificationProfileUIDBatch.maximumCount else {
            throw RemoteUserProfilesError.invalidLimit
        }
        guard items.count + missingUIDs.count <= maxUIDs else {
            throw RemoteUserProfilesError.tooManyResults
        }

        var itemUIDs: Set<String> = []
        for item in items {
            guard itemUIDs.insert(item.imUID).inserted else {
                throw RemoteUserProfilesError.duplicateUID(item.imUID)
            }
        }
        var missingSet: Set<String> = []
        for uid in missingUIDs {
            guard !uid.isEmpty else {
                throw RemoteUserProfilesError.invalidUID
            }
            guard missingSet.insert(uid).inserted else {
                throw RemoteUserProfilesError.duplicateUID(uid)
            }
            guard !itemUIDs.contains(uid) else {
                throw RemoteUserProfilesError.overlappingUID(uid)
            }
        }
    }
}

struct RemoteFriendApplyResult: Decodable {
    let id: String
    let status: String
    let outcome: String
    let relationStatus: String
    let friendAction: String
    let friendFlow: String
    let directlyEstablished: Bool
    let requiresTenantReview: Bool?
    let requiresTargetApproval: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case applicationID = "application_id"
        case requestID = "request_id"
        case status
        case outcome
        case relationStatus = "relation_status"
        case friendAction = "friend_action"
        case friendFlow = "friend_flow"
        case directlyEstablished = "directly_established"
        case requiresTenantReview = "requires_tenant_review"
        case requiresTargetApproval = "requires_target_approval"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .applicationID)
            ?? c.decodeIfPresent(String.self, forKey: .requestID)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        relationStatus = try c.decodeIfPresent(String.self, forKey: .relationStatus) ?? ""
        friendAction = try c.decodeIfPresent(String.self, forKey: .friendAction) ?? ""
        friendFlow = try c.decodeIfPresent(String.self, forKey: .friendFlow) ?? ""
        directlyEstablished = c.decodeLossyBoolIfPresent(forKey: .directlyEstablished) ?? false
        requiresTenantReview = c.decodeLossyBoolIfPresent(forKey: .requiresTenantReview)
        requiresTargetApproval = c.decodeLossyBoolIfPresent(forKey: .requiresTargetApproval)
    }
}

struct RemoteGroupInviteApprovalReviewResponse: Decodable {
    let request: RemoteGroupInviteApprovalReviewRequest?
    let status: String
    let resultText: String
    let approverName: String
    let approverAccountID: String
    let decidedAt: String
    let alreadyProcessed: Bool

    enum CodingKeys: String, CodingKey {
        case request
        case status
        case requestStatus = "request_status"
        case approvalStatus = "approval_status"
        case resultText = "result_text"
        case result
        case message
        case approverName = "approver_name"
        case decidedByName = "decided_by_name"
        case reviewedByName = "reviewed_by_name"
        case reviewerName = "reviewer_name"
        case approverAccountID = "approver_account_id"
        case approverUID = "approver_uid"
        case decidedByUID = "decided_by_uid"
        case reviewedBy = "reviewed_by"
        case reviewerUID = "reviewer_uid"
        case decidedAt = "decided_at"
        case reviewedAt = "reviewed_at"
        case processedAt = "processed_at"
        case alreadyProcessed = "already_processed"
        case processed
    }

    init() {
        request = nil
        status = ""
        resultText = ""
        approverName = ""
        approverAccountID = ""
        decidedAt = ""
        alreadyProcessed = false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = try c.decodeIfPresent(RemoteGroupInviteApprovalReviewRequest.self, forKey: .request)
        status = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .status),
            try c.decodeIfPresent(String.self, forKey: .requestStatus),
            try c.decodeIfPresent(String.self, forKey: .approvalStatus)
        )
        resultText = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .resultText),
            try c.decodeIfPresent(String.self, forKey: .result),
            try c.decodeIfPresent(String.self, forKey: .message)
        )
        approverName = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .approverName),
            try c.decodeIfPresent(String.self, forKey: .decidedByName),
            try c.decodeIfPresent(String.self, forKey: .reviewedByName),
            try c.decodeIfPresent(String.self, forKey: .reviewerName)
        )
        approverAccountID = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .approverAccountID),
            try c.decodeIfPresent(String.self, forKey: .approverUID),
            try c.decodeIfPresent(String.self, forKey: .decidedByUID),
            try c.decodeIfPresent(String.self, forKey: .reviewedBy),
            try c.decodeIfPresent(String.self, forKey: .reviewerUID)
        )
        decidedAt = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .decidedAt),
            try c.decodeIfPresent(String.self, forKey: .reviewedAt),
            try c.decodeIfPresent(String.self, forKey: .processedAt)
        )
        alreadyProcessed = c.decodeLossyBoolIfPresent(forKey: .alreadyProcessed)
            ?? c.decodeLossyBoolIfPresent(forKey: .processed)
            ?? false
    }

    func resolvedStatus(fallback: String) -> String {
        Self.firstNonEmpty(status, request?.status, alreadyProcessed ? "processed" : "", fallback)
    }

    func resolvedResultText(fallback: String) -> String {
        let explicit = Self.firstNonEmpty(resultText, request?.resultText, request?.reviewReason)
        if !explicit.isEmpty { return explicit }
        switch resolvedStatus(fallback: fallback).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approved", "approve", "accepted", "pass", "passed":
            return "已通过"
        case "rejected", "reject", "denied", "declined", "refused":
            return "已拒绝"
        case "canceled", "cancelled", "cancel":
            return "已取消"
        case "expired", "expire", "timed_out", "timeout":
            return "已过期"
        case "processed":
            return "已处理"
        default:
            return fallback
        }
    }

    func resolvedApproverName(fallback: String) -> String {
        Self.firstNonEmpty(approverName, request?.approverName, fallback)
    }

    func resolvedApproverAccountID() -> String {
        Self.firstNonEmpty(approverAccountID, request?.approverAccountID)
    }

    func resolvedDecidedAt(fallback: String) -> String {
        Self.firstNonEmpty(decidedAt, request?.decidedAt, fallback)
    }

    fileprivate static func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
}

struct RemoteGroupInviteApprovalReviewRequest: Decodable {
    let status: String
    let resultText: String
    let reviewReason: String
    let approverName: String
    let approverAccountID: String
    let decidedAt: String

    enum CodingKeys: String, CodingKey {
        case status
        case requestStatus = "request_status"
        case approvalStatus = "approval_status"
        case resultText = "result_text"
        case result
        case reviewReason = "review_reason"
        case approverName = "approver_name"
        case decidedByName = "decided_by_name"
        case reviewedByName = "reviewed_by_name"
        case reviewerName = "reviewer_name"
        case approverAccountID = "approver_account_id"
        case approverUID = "approver_uid"
        case decidedByUID = "decided_by_uid"
        case reviewedBy = "reviewed_by"
        case reviewerUID = "reviewer_uid"
        case decidedAt = "decided_at"
        case reviewedAt = "reviewed_at"
        case processedAt = "processed_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .status),
            try c.decodeIfPresent(String.self, forKey: .requestStatus),
            try c.decodeIfPresent(String.self, forKey: .approvalStatus)
        )
        resultText = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .resultText),
            try c.decodeIfPresent(String.self, forKey: .result)
        )
        reviewReason = try c.decodeIfPresent(String.self, forKey: .reviewReason) ?? ""
        approverName = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .approverName),
            try c.decodeIfPresent(String.self, forKey: .decidedByName),
            try c.decodeIfPresent(String.self, forKey: .reviewedByName),
            try c.decodeIfPresent(String.self, forKey: .reviewerName)
        )
        approverAccountID = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .approverAccountID),
            try c.decodeIfPresent(String.self, forKey: .approverUID),
            try c.decodeIfPresent(String.self, forKey: .decidedByUID),
            try c.decodeIfPresent(String.self, forKey: .reviewedBy),
            try c.decodeIfPresent(String.self, forKey: .reviewerUID)
        )
        decidedAt = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .decidedAt),
            try c.decodeIfPresent(String.self, forKey: .reviewedAt),
            try c.decodeIfPresent(String.self, forKey: .processedAt)
        )
    }
}

struct RemoteUserDevice: Decodable {
    let id: String
    let deviceID: String
    let deviceType: String
    let appID: String
    let status: String
    let banned: Bool
    let lastSeenAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case deviceType = "device_type"
        case appID = "app_id"
        case status
        case banned
        case lastSeenAt = "last_seen_at"
    }
}

struct RemoteMyLoginLog: Decodable {
    let id: String
    let deviceType: String
    let result: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case deviceType = "device_type"
        case result
        case createdAt = "created_at"
    }
}

struct RemoteDeviceRegistration: Equatable, Sendable {
    let deviceType: String
    let pushTokenType: String?
    let pushToken: String?
    let bundleID: String?
    let environment: String?

    init(
        deviceType: String = "ios",
        pushTokenType: String? = nil,
        pushToken: String? = "",
        bundleID: String? = nil,
        environment: String? = nil
    ) {
        self.deviceType = deviceType
        self.pushTokenType = pushTokenType
        self.pushToken = pushToken
        self.bundleID = bundleID
        self.environment = environment
    }

    static func standardIOS() -> RemoteDeviceRegistration {
        RemoteDeviceRegistration(deviceType: "ios", pushTokenType: nil, pushToken: "")
    }

    static func apns(token: String, bundleID: String, environment: String) -> RemoteDeviceRegistration {
        RemoteDeviceRegistration(
            deviceType: "ios",
            pushTokenType: "apns",
            pushToken: token,
            bundleID: bundleID,
            environment: environment
        )
    }

    static func voip(token: String, bundleID: String, environment: String) -> RemoteDeviceRegistration {
        RemoteDeviceRegistration(
            deviceType: "ios",
            pushTokenType: "voip",
            pushToken: token,
            bundleID: bundleID,
            environment: environment
        )
    }

    var requestBody: [String: Any] {
        var body: [String: Any] = ["device_type": deviceType]
        if let pushTokenType, !pushTokenType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["push_token_type"] = pushTokenType
        }
        if let pushToken {
            body["push_token"] = pushToken
        }
        if let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["bundle_id"] = bundleID
        }
        if let environment, !environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["environment"] = environment
        }
        return body
    }

    var deduplicationKey: String {
        [
            deviceType,
            pushTokenType ?? "",
            pushToken ?? "",
            bundleID ?? "",
            environment ?? ""
        ].joined(separator: "|")
    }

    var tokenFingerprint: String? {
        guard let normalized = pushToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum RemotePushTokenProvider: String, Codable, Equatable, Sendable {
    case apns
    case apnsVoIP = "apns_voip"
}

enum RemotePushTokenSlot: String, Codable, Equatable, Sendable {
    case ordinary
    case voip
}

enum RemotePushTokenRetirementStatus: String, Codable, Equatable, Sendable {
    case retired
    case alreadyEmpty = "already_empty"
    case superseded
}

struct RemotePushTokenRetirementResponse: Decodable, Equatable, Sendable {
    let status: RemotePushTokenRetirementStatus
    let slot: RemotePushTokenSlot
    let provider: RemotePushTokenProvider
    let terminal: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case slot
        case provider
        case terminal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(RemotePushTokenRetirementStatus.self, forKey: .status)
        slot = try container.decode(RemotePushTokenSlot.self, forKey: .slot)
        provider = try container.decode(RemotePushTokenProvider.self, forKey: .provider)
        terminal = try container.decode(Bool.self, forKey: .terminal)
        let expectedSlot: RemotePushTokenSlot = provider == .apns ? .ordinary : .voip
        guard slot == expectedSlot else {
            throw DecodingError.dataCorruptedError(
                forKey: .slot,
                in: container,
                debugDescription: "push token provider and slot must match"
            )
        }
    }
}

enum RemoteNotificationTargetKind: String, Decodable, Equatable, Sendable {
    case conversation
    case system
}

struct RemoteNotificationTargetResolution: Decodable, Equatable, Sendable {
    let kind: RemoteNotificationTargetKind
    let conversationID: String?
    let systemDestination: String?
    let messageID: String?
    let channelSeq: Int64?

    enum CodingKeys: String, CodingKey {
        case kind
        case conversationID = "conversation_id"
        case systemDestination = "system_destination"
        case messageID = "message_id"
        case channelSeq = "channel_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(RemoteNotificationTargetKind.self, forKey: .kind)
        conversationID = try Self.decodeOmittedNonEmptyString(.conversationID, from: container)
        systemDestination = try Self.decodeOmittedNonEmptyString(.systemDestination, from: container)
        messageID = try Self.decodeOmittedNonEmptyString(.messageID, from: container)
        if container.contains(.channelSeq) {
            guard try !container.decodeNil(forKey: .channelSeq) else {
                throw DecodingError.valueNotFound(
                    Int64.self,
                    .init(codingPath: container.codingPath + [CodingKeys.channelSeq], debugDescription: "channel_seq must be omitted instead of null")
                )
            }
            let decoded = try container.decode(Int64.self, forKey: .channelSeq)
            guard decoded > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .channelSeq, in: container, debugDescription: "channel_seq must be positive")
            }
            channelSeq = decoded
        } else {
            channelSeq = nil
        }

        switch kind {
        case .conversation:
            guard conversationID != nil, systemDestination == nil else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "conversation target shape is invalid")
            }
        case .system:
            guard conversationID == nil, systemDestination == "system_notification" else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "system target shape is invalid")
            }
        }
    }

    private static func decodeOmittedNonEmptyString(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        guard try !container.decodeNil(forKey: key) else {
            throw DecodingError.valueNotFound(
                String.self,
                .init(codingPath: container.codingPath + [key], debugDescription: "optional strings must be omitted instead of null")
            )
        }
        let value = try container.decode(String.self, forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "identifier must not be empty")
        }
        return value
    }
}

struct RemoteInboxEntry: Decodable {
    let id: String
    let kind: String
    let title: String
    let summary: String
    let senderAvatarURL: String
    let readAt: String?
    let createdAt: String?
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case category
        case type
        case notificationType = "notification_type"
        case channel
        case title
        case summary
        case senderAvatarURL = "sender_avatar_url"
        case senderAvatar = "sender_avatar"
        case avatarURL = "avatar_url"
        case avatar
        case readAt = "read_at"
        case createdAt = "created_at"
        case payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = [
            try c.decodeIfPresent(String.self, forKey: .kind),
            try c.decodeIfPresent(String.self, forKey: .category),
            try c.decodeIfPresent(String.self, forKey: .type),
            try c.decodeIfPresent(String.self, forKey: .notificationType),
            try c.decodeIfPresent(String.self, forKey: .channel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        senderAvatarURL = try c.decodeIfPresent(String.self, forKey: .senderAvatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .senderAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatar)
            ?? ""
        readAt = try c.decodeIfPresent(String.self, forKey: .readAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        payload = try c.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
    }
}

struct RemoteSystemInboxReadResponse: Decodable {
    let items: [RemoteInboxEntry]
    let imReadAck: RemoteIMReadAckTarget?

    enum CodingKeys: String, CodingKey {
        case items
        case imReadAck = "im_read_ack"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteInboxEntry].self, forKey: .items) ?? []
        imReadAck = try c.decodeIfPresent(RemoteIMReadAckTarget.self, forKey: .imReadAck)
    }
}

struct RemoteIMReadAckTarget: Decodable {
    let channelID: String
    let channelType: String
    let applied: Bool
    let lastRead: Int64
    let receipts: [RemoteMessageReceipt]

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
        case applied
        case lastRead = "last_read"
        case receipts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        applied = try c.decodeIfPresent(Bool.self, forKey: .applied) ?? false
        lastRead = try c.decodeIfPresent(Int64.self, forKey: .lastRead) ?? 0
        receipts = try c.decodeIfPresent([RemoteMessageReceipt].self, forKey: .receipts) ?? []
    }
}

struct RemoteUserGroup: Decodable {
    let groupID: String
    let groupRevision: Int64
    let name: String
    let avatar: String
    let avatarSource: String
    let avatarProvided: Bool
    let avatarVersion: String
    let avatarUpdatedAt: String
    let notice: String
    let groupDescription: String?
    let ownerUID: String
    let ownerName: String
    let memberCount: Int?
    let myRole: String
    let muted: Bool
    let allMuted: Bool
    let allMutedMode: String
    let allMutedActive: Bool?
    let allMutedStartAt: String?
    let allMutedEndAt: String?
    let allMutedUpdatedAt: String?
    let allMutedRepairRequired: Bool
    let serverTime: String?
    let nextBoundaryAt: String?
    let inviteConfirmRequired: Bool
    let historyVisibleFromSeq: Int64
    let historyLimited: Bool
    let groupMuted: Bool
    let canManageMuteList: Bool?
    let muteListCount: Int?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case groupRevision = "group_revision"
        case name
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarSource = "avatar_source"
        case avatarSourceCamel = "avatarSource"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case notice
        case groupDescription = "description"
        case ownerUID = "owner_uid"
        case ownerName = "owner_name"
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case membersCount = "members_count"
        case membersCountCamel = "membersCount"
        case memberTotal = "member_total"
        case memberNum = "member_num"
        case memberNumCamel = "memberNum"
        case totalMembers = "total_members"
        case totalMembersCamel = "totalMembers"
        case membersTotal = "members_total"
        case membersTotalCamel = "membersTotal"
        case total
        case myRole = "my_role"
        case muted
        case allMuted = "all_muted"
        case allMutedMode = "all_muted_mode"
        case allMutedActive = "all_muted_active"
        case allMutedStartAt = "all_muted_start_at"
        case allMutedEndAt = "all_muted_end_at"
        case allMutedUpdatedAt = "all_muted_updated_at"
        case allMutedRepairRequired = "all_muted_repair_required"
        case serverTime = "server_time"
        case nextBoundaryAt = "next_boundary_at"
        case inviteConfirmRequired = "invite_confirm_required"
        case inviteConfirmRequiredCamel = "inviteConfirmRequired"
        case inviteConfirm = "invite_confirm"
        case inviteConfirmCamel = "inviteConfirm"
        case approval
        case historyVisibleFromSeq = "history_visible_from_seq"
        case historyVisibleFromSeqCamel = "historyVisibleFromSeq"
        case historyLimited = "history_limited"
        case historyLimitedCamel = "historyLimited"
        case groupMuted = "group_muted"
        case groupMutedCamel = "groupMuted"
        case canManageMuteList = "can_manage_mute_list"
        case canManageMuteListCamel = "canManageMuteList"
        case muteListCount = "mute_list_count"
        case muteListCountCamel = "muteListCount"
        case createdAt = "created_at"
    }

    static let empty = RemoteUserGroup()

    init() {
        groupID = ""
        groupRevision = 0
        name = ""
        avatar = ""
        avatarSource = ""
        avatarProvided = false
        avatarVersion = ""
        avatarUpdatedAt = ""
        notice = ""
        groupDescription = nil
        ownerUID = ""
        ownerName = ""
        memberCount = nil
        myRole = "member"
        muted = false
        allMuted = false
        allMutedMode = ""
        allMutedActive = nil
        allMutedStartAt = nil
        allMutedEndAt = nil
        allMutedUpdatedAt = nil
        allMutedRepairRequired = false
        serverTime = nil
        nextBoundaryAt = nil
        inviteConfirmRequired = false
        historyVisibleFromSeq = 1
        historyLimited = false
        groupMuted = false
        canManageMuteList = nil
        muteListCount = nil
        createdAt = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        groupRevision = max(0, c.decodeLossyInt64IfPresent(forKey: .groupRevision) ?? 0)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        avatarProvided = c.contains(.avatar) || c.contains(.avatarURL) || c.contains(.avatarURLCamel)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarSource = try c.decodeIfPresent(String.self, forKey: .avatarSource)
            ?? c.decodeIfPresent(String.self, forKey: .avatarSourceCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? ""
        groupDescription = try c.decodeIfPresent(String.self, forKey: .groupDescription)
        ownerUID = try c.decodeIfPresent(String.self, forKey: .ownerUID) ?? ""
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName) ?? ""
        memberCount = Self.decodeFlexibleInt(
            from: c,
            keys: [
                .memberCount,
                .memberCountCamel,
                .membersCount,
                .membersCountCamel,
                .memberTotal,
                .memberNum,
                .memberNumCamel,
                .totalMembers,
                .totalMembersCamel,
                .membersTotal,
                .membersTotalCamel,
                .total
            ]
        )
        myRole = try c.decodeIfPresent(String.self, forKey: .myRole) ?? "member"
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        allMuted = try c.decodeIfPresent(Bool.self, forKey: .allMuted) ?? false
        allMutedMode = try c.decodeIfPresent(String.self, forKey: .allMutedMode) ?? ""
        allMutedActive = c.decodeStrictBoolIfPresent(forKey: .allMutedActive)
        allMutedStartAt = try c.decodeIfPresent(String.self, forKey: .allMutedStartAt)
        allMutedEndAt = try c.decodeIfPresent(String.self, forKey: .allMutedEndAt)
        allMutedUpdatedAt = try c.decodeIfPresent(String.self, forKey: .allMutedUpdatedAt)
        allMutedRepairRequired = c.decodeStrictBoolIfPresent(forKey: .allMutedRepairRequired) ?? false
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime)
        nextBoundaryAt = try c.decodeIfPresent(String.self, forKey: .nextBoundaryAt)
        inviteConfirmRequired = c.decodeLossyBoolIfPresent(forKey: .inviteConfirmRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirmRequiredCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirm)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirmCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .approval)
            ?? false
        historyVisibleFromSeq = max(
            1,
            c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeq)
                ?? c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeqCamel)
                ?? 1
        )
        historyLimited = c.decodeLossyBoolIfPresent(forKey: .historyLimited)
            ?? c.decodeLossyBoolIfPresent(forKey: .historyLimitedCamel)
            ?? false
        groupMuted = c.decodeLossyBoolIfPresent(forKey: .groupMuted)
            ?? c.decodeLossyBoolIfPresent(forKey: .groupMutedCamel)
            ?? false
        canManageMuteList = c.decodeLossyBoolIfPresent(forKey: .canManageMuteList)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageMuteListCamel)
        muteListCount = Self.decodeFlexibleInt(from: c, keys: [.muteListCount, .muteListCountCamel])
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

struct RemoteGroupDetail: Decodable {
    let summary: RemoteUserGroup
    let myRole: String
    let owner: RemoteUserGroupMember?
    let admins: [RemoteUserGroupMember]
    let memberCount: Int?
    let currentAnnouncement: RemoteGroupAnnouncement?
    let settings: RemoteGroupSettings
    let groupMuted: Bool
    let canManageMuteList: Bool?
    let muteListCount: Int?

    var historyVisibleFromSeq: Int64 { summary.historyVisibleFromSeq }
    var historyLimited: Bool { summary.historyLimited }

    enum CodingKeys: String, CodingKey {
        case group
        case summary
        case myRole = "my_role"
        case owner
        case admins
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case membersCount = "members_count"
        case membersCountCamel = "membersCount"
        case memberTotal = "member_total"
        case memberNum = "member_num"
        case memberNumCamel = "memberNum"
        case totalMembers = "total_members"
        case totalMembersCamel = "totalMembers"
        case membersTotal = "members_total"
        case membersTotalCamel = "membersTotal"
        case total
        case currentAnnouncement = "current_announcement"
        case settings
        case groupMuted = "group_muted"
        case groupMutedCamel = "groupMuted"
        case canManageMuteList = "can_manage_mute_list"
        case canManageMuteListCamel = "canManageMuteList"
        case muteListCount = "mute_list_count"
        case muteListCountCamel = "muteListCount"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let summaryCandidate = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .summary)
        let groupCandidate = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .group)
        let decodedSummary = summaryCandidate ?? groupCandidate ?? .empty
        summary = decodedSummary
        myRole = try c.decodeIfPresent(String.self, forKey: .myRole) ?? decodedSummary.myRole
        owner = try c.decodeIfPresent(RemoteUserGroupMember.self, forKey: .owner)
        admins = try c.decodeIfPresent([RemoteUserGroupMember].self, forKey: .admins) ?? []
        memberCount = Self.decodeFlexibleInt(
            from: c,
            keys: [
                .memberCount,
                .memberCountCamel,
                .membersCount,
                .membersCountCamel,
                .memberTotal,
                .memberNum,
                .memberNumCamel,
                .totalMembers,
                .totalMembersCamel,
                .membersTotal,
                .membersTotalCamel,
                .total
            ]
        ) ?? decodedSummary.memberCount
        currentAnnouncement = try c.decodeIfPresent(RemoteGroupAnnouncement.self, forKey: .currentAnnouncement)
        settings = try c.decodeIfPresent(RemoteGroupSettings.self, forKey: .settings) ?? .empty
        groupMuted = c.decodeLossyBoolIfPresent(forKey: .groupMuted)
            ?? c.decodeLossyBoolIfPresent(forKey: .groupMutedCamel)
            ?? decodedSummary.groupMuted
        canManageMuteList = c.decodeLossyBoolIfPresent(forKey: .canManageMuteList)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageMuteListCamel)
            ?? decodedSummary.canManageMuteList
            ?? settings.canManageMuteList
        muteListCount = Self.decodeFlexibleInt(from: c, keys: [.muteListCount, .muteListCountCamel])
            ?? decodedSummary.muteListCount
            ?? settings.muteListCount
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

struct RemoteGroupSummaryCounts: Decodable {
    let memberCount: Int?
    let adminCount: Int
    let pendingJoinRequestCount: Int
    let fileCount: Int

    enum CodingKeys: String, CodingKey {
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case adminCount = "admin_count"
        case adminCountCamel = "adminCount"
        case pendingJoinRequestCount = "pending_join_request_count"
        case pendingJoinRequestCountCamel = "pendingJoinRequestCount"
        case fileCount = "file_count"
        case fileCountCamel = "fileCount"
    }

    init() {
        memberCount = nil
        adminCount = 0
        pendingJoinRequestCount = 0
        fileCount = 0
    }

    init(memberCount: Int?, adminCount: Int, pendingJoinRequestCount: Int, fileCount: Int) {
        self.memberCount = memberCount
        self.adminCount = adminCount
        self.pendingJoinRequestCount = pendingJoinRequestCount
        self.fileCount = fileCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberCount = c.decodeLossyIntIfPresent(forKey: .memberCount)
            ?? c.decodeLossyIntIfPresent(forKey: .memberCountCamel)
        adminCount = c.decodeLossyIntIfPresent(forKey: .adminCount)
            ?? c.decodeLossyIntIfPresent(forKey: .adminCountCamel)
            ?? 0
        pendingJoinRequestCount = c.decodeLossyIntIfPresent(forKey: .pendingJoinRequestCount)
            ?? c.decodeLossyIntIfPresent(forKey: .pendingJoinRequestCountCamel)
            ?? 0
        fileCount = c.decodeLossyIntIfPresent(forKey: .fileCount)
            ?? c.decodeLossyIntIfPresent(forKey: .fileCountCamel)
            ?? 0
    }
}

struct RemoteGroupSummary: Decodable {
    let summary: RemoteUserGroup
    let myRole: String
    let memberCount: Int?
    let owner: RemoteUserGroupMember?
    let memberPreview: [RemoteUserGroupMember]
    let counts: RemoteGroupSummaryCounts
    let currentAnnouncement: RemoteGroupAnnouncement?
    let settings: RemoteGroupSettings
    let historyVisibleFromSeq: Int64
    let historyLimited: Bool
    let groupMuted: Bool
    let canManageMuteList: Bool?
    let muteListCount: Int?

    enum CodingKeys: String, CodingKey {
        case group
        case summary
        case myRole = "my_role"
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case membersCount = "members_count"
        case membersCountCamel = "membersCount"
        case total
        case owner
        case memberPreview = "member_preview"
        case memberPreviewCamel = "memberPreview"
        case counts
        case currentAnnouncement = "current_announcement"
        case settings
        case historyVisibleFromSeq = "history_visible_from_seq"
        case historyVisibleFromSeqCamel = "historyVisibleFromSeq"
        case historyLimited = "history_limited"
        case historyLimitedCamel = "historyLimited"
        case groupMuted = "group_muted"
        case groupMutedCamel = "groupMuted"
        case canManageMuteList = "can_manage_mute_list"
        case canManageMuteListCamel = "canManageMuteList"
        case muteListCount = "mute_list_count"
        case muteListCountCamel = "muteListCount"
    }

    var isMemberPreviewComplete: Bool {
        guard let memberCount else { return false }
        return memberCount > 0 && memberPreview.count >= memberCount
    }

    init(
        summary: RemoteUserGroup,
        myRole: String,
        memberCount: Int?,
        owner: RemoteUserGroupMember?,
        memberPreview: [RemoteUserGroupMember],
        counts: RemoteGroupSummaryCounts,
        currentAnnouncement: RemoteGroupAnnouncement?,
        settings: RemoteGroupSettings,
        historyVisibleFromSeq: Int64 = 1,
        historyLimited: Bool = false,
        groupMuted: Bool = false,
        canManageMuteList: Bool? = nil,
        muteListCount: Int? = nil
    ) {
        self.summary = summary
        self.myRole = myRole
        self.memberCount = memberCount
        self.owner = owner
        self.memberPreview = memberPreview
        self.counts = counts
        self.currentAnnouncement = currentAnnouncement
        self.settings = settings
        self.historyVisibleFromSeq = max(1, historyVisibleFromSeq)
        self.historyLimited = historyLimited
        self.groupMuted = groupMuted
        self.canManageMuteList = canManageMuteList
        self.muteListCount = muteListCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let summaryCandidate = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .summary)
        let groupCandidate = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .group)
        let decodedSummary = summaryCandidate ?? groupCandidate ?? .empty
        summary = decodedSummary
        myRole = try c.decodeIfPresent(String.self, forKey: .myRole) ?? decodedSummary.myRole
        let decodedCounts = try c.decodeIfPresent(RemoteGroupSummaryCounts.self, forKey: .counts) ?? RemoteGroupSummaryCounts()
        counts = decodedCounts
        let decodedMemberCount = Self.decodeFlexibleInt(
            from: c,
            keys: [.memberCount, .memberCountCamel, .membersCount, .membersCountCamel, .total]
        ) ?? decodedCounts.memberCount
        memberCount = (decodedMemberCount ?? 0) > 0 ? decodedMemberCount : decodedSummary.memberCount
        owner = try c.decodeIfPresent(RemoteUserGroupMember.self, forKey: .owner)
        memberPreview = try c.decodeIfPresent([RemoteUserGroupMember].self, forKey: .memberPreview)
            ?? c.decodeIfPresent([RemoteUserGroupMember].self, forKey: .memberPreviewCamel)
            ?? []
        currentAnnouncement = try c.decodeIfPresent(RemoteGroupAnnouncement.self, forKey: .currentAnnouncement)
        settings = try c.decodeIfPresent(RemoteGroupSettings.self, forKey: .settings) ?? .empty
        historyVisibleFromSeq = max(
            1,
            c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeq)
                ?? c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeqCamel)
                ?? decodedSummary.historyVisibleFromSeq
        )
        historyLimited = c.decodeLossyBoolIfPresent(forKey: .historyLimited)
            ?? c.decodeLossyBoolIfPresent(forKey: .historyLimitedCamel)
            ?? decodedSummary.historyLimited
        groupMuted = c.decodeLossyBoolIfPresent(forKey: .groupMuted)
            ?? c.decodeLossyBoolIfPresent(forKey: .groupMutedCamel)
            ?? decodedSummary.groupMuted
        canManageMuteList = c.decodeLossyBoolIfPresent(forKey: .canManageMuteList)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageMuteListCamel)
            ?? decodedSummary.canManageMuteList
            ?? settings.canManageMuteList
        muteListCount = Self.decodeFlexibleInt(from: c, keys: [.muteListCount, .muteListCountCamel])
            ?? decodedSummary.muteListCount
            ?? settings.muteListCount
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

struct RemoteGroupLeaveResult: Decodable, Sendable {
    let left: Bool
    let groupID: String
    let leftAt: String
    let conversationRemoved: Bool
    let notificationAudience: String
    let notificationCount: Int
    let searchInvalidations: [SearchInvalidationEvent]

    enum CodingKeys: String, CodingKey {
        case left
        case groupID = "group_id"
        case groupIDCamel = "groupId"
        case leftAt = "left_at"
        case leftAtCamel = "leftAt"
        case conversationRemoved = "conversation_removed"
        case conversationRemovedCamel = "conversationRemoved"
        case notificationAudience = "notification_audience"
        case notificationAudienceCamel = "notificationAudience"
        case notificationCount = "notification_count"
        case notificationCountCamel = "notificationCount"
        case searchInvalidations = "search_invalidations"
        case searchInvalidationsCamel = "searchInvalidations"
    }

    init(
        left: Bool = false,
        groupID: String = "",
        leftAt: String = "",
        conversationRemoved: Bool = false,
        notificationAudience: String = "",
        notificationCount: Int = 0,
        searchInvalidations: [SearchInvalidationEvent] = []
    ) {
        self.left = left
        self.groupID = groupID
        self.leftAt = leftAt
        self.conversationRemoved = conversationRemoved
        self.notificationAudience = notificationAudience
        self.notificationCount = notificationCount
        self.searchInvalidations = searchInvalidations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decodeIfPresent(Bool.self, forKey: .left) ?? false
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
            ?? c.decodeIfPresent(String.self, forKey: .groupIDCamel)
            ?? ""
        leftAt = try c.decodeIfPresent(String.self, forKey: .leftAt)
            ?? c.decodeIfPresent(String.self, forKey: .leftAtCamel)
            ?? ""
        conversationRemoved = try c.decodeIfPresent(Bool.self, forKey: .conversationRemoved)
            ?? c.decodeIfPresent(Bool.self, forKey: .conversationRemovedCamel)
            ?? false
        notificationAudience = try c.decodeIfPresent(String.self, forKey: .notificationAudience)
            ?? c.decodeIfPresent(String.self, forKey: .notificationAudienceCamel)
            ?? ""
        notificationCount = try c.decodeIfPresent(Int.self, forKey: .notificationCount)
            ?? c.decodeIfPresent(Int.self, forKey: .notificationCountCamel)
            ?? 0
        searchInvalidations = try c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidations)
            ?? c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidationsCamel)
            ?? []
    }
}

struct RemoteGroupDissolvePreview: Decodable, Sendable {
    let groupID: String
    let memberCount: Int?
    let affectedMembers: Int?
    let confirmationRequired: Bool
    let confirmationText: String
    let confirmationMode: String
    let effects: [String]

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case groupIDCamel = "groupId"
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case affectedMembers = "affected_members"
        case affectedMembersCamel = "affectedMembers"
        case confirmationRequired = "confirmation_required"
        case confirmationRequiredCamel = "confirmationRequired"
        case confirmationText = "confirmation_text"
        case confirmationTextCamel = "confirmationText"
        case confirmationMode = "confirmation_mode"
        case confirmationModeCamel = "confirmationMode"
        case effects
    }

    init(
        groupID: String = "",
        memberCount: Int? = nil,
        affectedMembers: Int? = nil,
        confirmationRequired: Bool = true,
        confirmationText: String = "",
        confirmationMode: String = "button",
        effects: [String] = []
    ) {
        self.groupID = groupID
        self.memberCount = memberCount
        self.affectedMembers = affectedMembers
        self.confirmationRequired = confirmationRequired
        self.confirmationText = confirmationText
        self.confirmationMode = confirmationMode
        self.effects = effects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
            ?? c.decodeIfPresent(String.self, forKey: .groupIDCamel)
            ?? ""
        memberCount = Self.decodeFlexibleInt(from: c, keys: [.memberCount, .memberCountCamel])
        affectedMembers = Self.decodeFlexibleInt(from: c, keys: [.affectedMembers, .affectedMembersCamel]) ?? memberCount
        confirmationRequired = try c.decodeIfPresent(Bool.self, forKey: .confirmationRequired)
            ?? c.decodeIfPresent(Bool.self, forKey: .confirmationRequiredCamel)
            ?? true
        confirmationText = try c.decodeIfPresent(String.self, forKey: .confirmationText)
            ?? c.decodeIfPresent(String.self, forKey: .confirmationTextCamel)
            ?? ""
        confirmationMode = try c.decodeIfPresent(String.self, forKey: .confirmationMode)
            ?? c.decodeIfPresent(String.self, forKey: .confirmationModeCamel)
            ?? "button"
        effects = try c.decodeIfPresent([String].self, forKey: .effects) ?? []
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

struct RemoteGroupDissolveResult: Decodable, Sendable {
    let dissolved: Bool
    let groupID: String
    let status: String
    let dissolvedAt: String
    let removedMembers: Int
    let removedConversations: Int
    let notificationCount: Int
    let searchInvalidations: [SearchInvalidationEvent]

    enum CodingKeys: String, CodingKey {
        case dissolved
        case groupID = "group_id"
        case groupIDCamel = "groupId"
        case status
        case dissolvedAt = "dissolved_at"
        case dissolvedAtCamel = "dissolvedAt"
        case removedMembers = "removed_members"
        case removedMembersCamel = "removedMembers"
        case removedConversations = "removed_conversations"
        case removedConversationsCamel = "removedConversations"
        case notificationCount = "notification_count"
        case notificationCountCamel = "notificationCount"
        case searchInvalidations = "search_invalidations"
        case searchInvalidationsCamel = "searchInvalidations"
    }

    init(
        dissolved: Bool = false,
        groupID: String = "",
        status: String = "",
        dissolvedAt: String = "",
        removedMembers: Int = 0,
        removedConversations: Int = 0,
        notificationCount: Int = 0,
        searchInvalidations: [SearchInvalidationEvent] = []
    ) {
        self.dissolved = dissolved
        self.groupID = groupID
        self.status = status
        self.dissolvedAt = dissolvedAt
        self.removedMembers = removedMembers
        self.removedConversations = removedConversations
        self.notificationCount = notificationCount
        self.searchInvalidations = searchInvalidations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dissolved = try c.decodeIfPresent(Bool.self, forKey: .dissolved) ?? false
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
            ?? c.decodeIfPresent(String.self, forKey: .groupIDCamel)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        dissolvedAt = try c.decodeIfPresent(String.self, forKey: .dissolvedAt)
            ?? c.decodeIfPresent(String.self, forKey: .dissolvedAtCamel)
            ?? ""
        removedMembers = Self.decodeFlexibleInt(from: c, keys: [.removedMembers, .removedMembersCamel]) ?? 0
        removedConversations = Self.decodeFlexibleInt(from: c, keys: [.removedConversations, .removedConversationsCamel]) ?? 0
        notificationCount = Self.decodeFlexibleInt(from: c, keys: [.notificationCount, .notificationCountCamel]) ?? 0
        searchInvalidations = try c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidations)
            ?? c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidationsCamel)
            ?? []
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

struct RemoteGroupSettings: Decodable {
    let groupRevision: Int64
    let groupDescription: String?
    let muted: Bool
    let inviteConfirmRequired: Bool
    let allMuted: Bool
    let allMutedMode: String
    let allMutedActive: Bool?
    let allMutedStartAt: String?
    let allMutedEndAt: String?
    let allMutedUpdatedAt: String?
    let allMutedRepairRequired: Bool
    let serverTime: String?
    let nextBoundaryAt: String?
    let pendingJoinRequestCount: Int
    let fileCount: Int
    let blacklistCount: Int
    let historyVisible: Bool
    let canManageMuteList: Bool?
    let muteListCount: Int?

    enum CodingKeys: String, CodingKey {
        case groupRevision = "group_revision"
        case groupDescription = "description"
        case muted
        case historyVisible = "history_visible"
        case historyVisibleCamel = "historyVisible"
        case inviteConfirmRequired = "invite_confirm_required"
        case inviteConfirmRequiredCamel = "inviteConfirmRequired"
        case inviteConfirm = "invite_confirm"
        case inviteConfirmCamel = "inviteConfirm"
        case approval
        case allMuted = "all_muted"
        case allMutedMode = "all_muted_mode"
        case allMutedActive = "all_muted_active"
        case allMutedStartAt = "all_muted_start_at"
        case allMutedEndAt = "all_muted_end_at"
        case allMutedUpdatedAt = "all_muted_updated_at"
        case allMutedRepairRequired = "all_muted_repair_required"
        case serverTime = "server_time"
        case nextBoundaryAt = "next_boundary_at"
        case pendingJoinRequestCount = "pending_join_request_count"
        case fileCount = "file_count"
        case blacklistCount = "blacklist_count"
        case canManageMuteList = "can_manage_mute_list"
        case canManageMuteListCamel = "canManageMuteList"
        case muteListCount = "mute_list_count"
        case muteListCountCamel = "muteListCount"
    }

    static let empty = RemoteGroupSettings()

    init() {
        groupRevision = 0
        groupDescription = nil
        muted = false
        inviteConfirmRequired = false
        allMuted = false
        allMutedMode = ""
        allMutedActive = nil
        allMutedStartAt = nil
        allMutedEndAt = nil
        allMutedUpdatedAt = nil
        allMutedRepairRequired = false
        serverTime = nil
        nextBoundaryAt = nil
        pendingJoinRequestCount = 0
        fileCount = 0
        blacklistCount = 0
        historyVisible = true
        canManageMuteList = nil
        muteListCount = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupRevision = max(0, c.decodeLossyInt64IfPresent(forKey: .groupRevision) ?? 0)
        groupDescription = try c.decodeIfPresent(String.self, forKey: .groupDescription)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        inviteConfirmRequired = c.decodeLossyBoolIfPresent(forKey: .inviteConfirmRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirmRequiredCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirm)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirmCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .approval)
            ?? false
        allMuted = try c.decodeIfPresent(Bool.self, forKey: .allMuted) ?? false
        allMutedMode = try c.decodeIfPresent(String.self, forKey: .allMutedMode) ?? ""
        allMutedActive = c.decodeStrictBoolIfPresent(forKey: .allMutedActive)
        allMutedStartAt = try c.decodeIfPresent(String.self, forKey: .allMutedStartAt)
        allMutedEndAt = try c.decodeIfPresent(String.self, forKey: .allMutedEndAt)
        allMutedUpdatedAt = try c.decodeIfPresent(String.self, forKey: .allMutedUpdatedAt)
        allMutedRepairRequired = c.decodeStrictBoolIfPresent(forKey: .allMutedRepairRequired) ?? false
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime)
        nextBoundaryAt = try c.decodeIfPresent(String.self, forKey: .nextBoundaryAt)
        pendingJoinRequestCount = try c.decodeIfPresent(Int.self, forKey: .pendingJoinRequestCount) ?? 0
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        blacklistCount = try c.decodeIfPresent(Int.self, forKey: .blacklistCount) ?? 0
        historyVisible = c.decodeLossyBoolIfPresent(forKey: .historyVisible)
            ?? c.decodeLossyBoolIfPresent(forKey: .historyVisibleCamel)
            ?? true
        canManageMuteList = c.decodeLossyBoolIfPresent(forKey: .canManageMuteList)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageMuteListCamel)
        muteListCount = c.decodeLossyIntIfPresent(forKey: .muteListCount)
            ?? c.decodeLossyIntIfPresent(forKey: .muteListCountCamel)
    }
}

struct RemoteGroupHistoryVisibilitySettingsRequest: Encodable {
    let historyVisible: Bool

    enum CodingKeys: String, CodingKey {
        case historyVisible = "history_visible"
    }
}

struct RemoteGroupMuteListItem: Decodable {
    let groupID: String
    let targetUID: String
    let targetUserID: String
    let targetUsername: String
    let targetNickname: String
    let targetAvatar: String
    let targetRole: String
    let operatorUID: String
    let operatorName: String
    let reason: String
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case groupIDCamel = "groupId"
        case targetUID = "target_uid"
        case targetUIDCamel = "targetUID"
        case imUID = "im_uid"
        case uid
        case targetUserID = "target_user_id"
        case targetUserIDCamel = "targetUserID"
        case userID = "user_id"
        case targetUsername = "target_username"
        case targetUsernameCamel = "targetUsername"
        case username
        case targetNickname = "target_nickname"
        case targetNicknameCamel = "targetNickname"
        case nickname
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case targetAvatar = "target_avatar"
        case targetAvatarCamel = "targetAvatar"
        case avatar
        case avatarURL = "avatar_url"
        case targetRole = "target_role"
        case targetRoleCamel = "targetRole"
        case role
        case operatorUID = "operator_uid"
        case operatorUIDCamel = "operatorUID"
        case operatorName = "operator_name"
        case operatorNameCamel = "operatorName"
        case reason
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = (try c.decodeIfPresent(String.self, forKey: .groupID)
            ?? c.decodeIfPresent(String.self, forKey: .groupIDCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedTargetUID = try c.decodeIfPresent(String.self, forKey: .targetUID)
        let decodedTargetUIDCamel = try c.decodeIfPresent(String.self, forKey: .targetUIDCamel)
        let decodedIMUID = try c.decodeIfPresent(String.self, forKey: .imUID)
        let decodedUID = try c.decodeIfPresent(String.self, forKey: .uid)
        let decodedTargetUserID = try c.decodeIfPresent(String.self, forKey: .targetUserID)
        let decodedUserID = try c.decodeIfPresent(String.self, forKey: .userID)
        targetUID = [
            decodedTargetUID,
            decodedTargetUIDCamel,
            decodedIMUID,
            decodedUID,
            decodedTargetUserID,
            decodedUserID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        targetUserID = [
            decodedTargetUserID,
            try c.decodeIfPresent(String.self, forKey: .targetUserIDCamel),
            decodedUserID,
            targetUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        targetUsername = (try c.decodeIfPresent(String.self, forKey: .targetUsername)
            ?? c.decodeIfPresent(String.self, forKey: .targetUsernameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .username)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        targetNickname = [
            try c.decodeIfPresent(String.self, forKey: .targetNickname),
            try c.decodeIfPresent(String.self, forKey: .targetNicknameCamel),
            try c.decodeIfPresent(String.self, forKey: .displayName),
            try c.decodeIfPresent(String.self, forKey: .displayNameCamel),
            try c.decodeIfPresent(String.self, forKey: .nickname)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        targetAvatar = (try c.decodeIfPresent(String.self, forKey: .targetAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatarCamel)
            ?? c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        targetRole = (try c.decodeIfPresent(String.self, forKey: .targetRole)
            ?? c.decodeIfPresent(String.self, forKey: .targetRoleCamel)
            ?? c.decodeIfPresent(String.self, forKey: .role)
            ?? "member").trimmingCharacters(in: .whitespacesAndNewlines)
        operatorUID = (try c.decodeIfPresent(String.self, forKey: .operatorUID)
            ?? c.decodeIfPresent(String.self, forKey: .operatorUIDCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        operatorName = (try c.decodeIfPresent(String.self, forKey: .operatorName)
            ?? c.decodeIfPresent(String.self, forKey: .operatorNameCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        reason = (try c.decodeIfPresent(String.self, forKey: .reason) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtCamel)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel)
    }
}

struct RemoteGroupMemberProfile: Decodable {
    let contractVersion: Int
    let groupID: String
    let imUID: String
    let groupNickname: String
    let rawNickname: String
    let displayName: String
    let displayNameSource: String
    let revision: Int64
    let groupMembershipGeneration: Int64
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case groupID = "group_id"
        case imUID = "im_uid"
        case groupNickname = "group_nickname"
        case rawNickname = "raw_nickname"
        case displayName = "display_name"
        case displayNameSource = "display_name_source"
        case revision
        case groupMembershipGeneration = "group_membership_generation"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = c.decodeLossyIntIfPresent(forKey: .contractVersion) ?? 0
        groupID = (try c.decodeIfPresent(String.self, forKey: .groupID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        imUID = (try c.decodeIfPresent(String.self, forKey: .imUID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        groupNickname = (try c.decodeIfPresent(String.self, forKey: .groupNickname) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        rawNickname = (try c.decodeIfPresent(String.self, forKey: .rawNickname) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = (try c.decodeIfPresent(String.self, forKey: .displayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayNameSource = (try c.decodeIfPresent(String.self, forKey: .displayNameSource) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        revision = c.decodeLossyInt64IfPresent(forKey: .revision) ?? 0
        groupMembershipGeneration = c.decodeLossyInt64IfPresent(forKey: .groupMembershipGeneration) ?? revision
        updatedAt = (try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RemoteUserGroupMember: Decodable {
    let memberID: String
    let imUID: String
    let userID: String
    let accountID: String
    let nickname: String
    let displayName: String
    let rawNickname: String
    let displayNameSource: String
    let remark: String
    let groupNickname: String
    let revision: Int64
    let groupMembershipGeneration: Int64
    let phone: String
    let phoneMasked: String
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let status: String
    let presenceStatus: String
    let online: Bool
    let onlineKnown: Bool
    let lastSeenAt: String
    let role: String
    let isOwner: Bool
    let isAdmin: Bool
    let joinedAt: String?
    let departmentName: String
    let departmentPath: [String]
    let departmentPathNames: [String]

    var visiblePhone: String {
        phoneMasked.isEmpty ? phone : phoneMasked
    }

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case imUID = "im_uid"
        case userID = "user_id"
        case accountID = "account_id"
        case memberUID = "member_uid"
        case uid
        case nickname
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case rawNickname = "raw_nickname"
        case rawNicknameCamel = "rawNickname"
        case displayNameSource = "display_name_source"
        case displayNameSourceCamel = "displayNameSource"
        case remark
        case groupNickname = "group_nickname"
        case revision
        case groupMembershipGeneration = "group_membership_generation"
        case phone
        case phoneMasked = "phone_masked"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case role
        case isOwner = "is_owner"
        case isAdmin = "is_admin"
        case joinedAt = "joined_at"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberID = (try c.decodeIfPresent(String.self, forKey: .memberID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedIMUID = [
            try c.decodeIfPresent(String.self, forKey: .imUID),
            try c.decodeIfPresent(String.self, forKey: .userID),
            try c.decodeIfPresent(String.self, forKey: .memberUID),
            try c.decodeIfPresent(String.self, forKey: .uid)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        imUID = decodedIMUID
        userID = [
            try c.decodeIfPresent(String.self, forKey: .userID),
            decodedIMUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        accountID = (try c.decodeIfPresent(String.self, forKey: .accountID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        nickname = (try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .nickname)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rawNickname = (try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? nickname).trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = (try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        displayNameSource = (try c.decodeIfPresent(String.self, forKey: .displayNameSource)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameSourceCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        remark = (try c.decodeIfPresent(String.self, forKey: .remark) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        groupNickname = (try c.decodeIfPresent(String.self, forKey: .groupNickname) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        revision = c.decodeLossyInt64IfPresent(forKey: .revision) ?? 0
        groupMembershipGeneration = c.decodeLossyInt64IfPresent(forKey: .groupMembershipGeneration) ?? revision
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        phoneMasked = try c.decodeIfPresent(String.self, forKey: .phoneMasked) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        presenceStatus = try c.decodeIfPresent(String.self, forKey: .presenceStatus) ?? ""
        let decodedOnline = c.decodeLossyBoolIfPresent(forKey: .online)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
        online = decodedOnline ?? false
        onlineKnown = decodedOnline != nil
        lastSeenAt = [
            try c.decodeIfPresent(String.self, forKey: .lastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAt),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAtCamel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "member"
        isOwner = (try c.decodeIfPresent(Bool.self, forKey: .isOwner)) ?? (role == "owner")
        isAdmin = (try c.decodeIfPresent(Bool.self, forKey: .isAdmin)) ?? (role == "admin" || role == "owner")
        joinedAt = try c.decodeIfPresent(String.self, forKey: .joinedAt)
        departmentName = try c.decodeIfPresent(String.self, forKey: .departmentName)
            ?? c.decodeIfPresent(String.self, forKey: .departmentNameCamel)
            ?? ""
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
    }
}

struct RemoteGroupAnnouncementList: Decodable {
    let items: [RemoteGroupAnnouncement]
    let current: RemoteGroupAnnouncement?
    let topBanner: RemoteGroupAnnouncement?

    enum CodingKeys: String, CodingKey {
        case items
        case current
        case topBanner = "top_banner"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteGroupAnnouncement].self, forKey: .items) ?? []
        current = try c.decodeIfPresent(RemoteGroupAnnouncement.self, forKey: .current)
        topBanner = try c.decodeIfPresent(RemoteGroupAnnouncement.self, forKey: .topBanner)
    }
}

struct RemoteGroupAnnouncement: Decodable {
    let id: String
    let groupID: String
    let title: String
    let content: String
    let createdBy: String
    let status: String
    let summary: String
    let createdAt: String?
    let updatedAt: String?
    let publishedAt: String?
    let unread: Bool
    let readAt: String?
    let displayPosition: String
    let readAction: String
    let readCount: Int?
    let unreadCount: Int?
    let recipientCount: Int?
    let canViewReadCounts: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case announcementID = "announcement_id"
        case groupID = "group_id"
        case title
        case content
        case createdBy = "created_by"
        case status
        case summary
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case publishedAt = "published_at"
        case unread
        case readAt = "read_at"
        case displayPosition = "display_position"
        case readAction = "read_action"
        case readCount = "read_count"
        case unreadCount = "unread_count"
        case recipientCount = "recipient_count"
        case canViewReadCounts = "can_view_read_counts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .announcementID)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        readAt = try c.decodeIfPresent(String.self, forKey: .readAt)
        displayPosition = try c.decodeIfPresent(String.self, forKey: .displayPosition) ?? ""
        readAction = try c.decodeIfPresent(String.self, forKey: .readAction) ?? ""
        readCount = c.decodeLossyIntIfPresent(forKey: .readCount)
        unreadCount = c.decodeLossyIntIfPresent(forKey: .unreadCount)
        recipientCount = c.decodeLossyIntIfPresent(forKey: .recipientCount)
        canViewReadCounts = c.decodeLossyBoolIfPresent(forKey: .canViewReadCounts) ?? false
    }
}

struct RemoteGroupSettingsMutationResult: Decodable {
    let groupID: String
    let settings: RemoteGroupSettings

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        settings = try c.decodeIfPresent(RemoteGroupSettings.self, forKey: .settings) ?? .empty
    }
}

struct RemoteGroupOwnerTransferResult: Decodable {
    let group: RemoteUserGroup
    let previousOwnerUID: String
    let newOwnerUID: String
    let oldOwnerRole: String
    let previousOwner: RemoteUserGroupMember?
    let newOwner: RemoteUserGroupMember?
    let transferredAt: String
    let idempotent: Bool

    enum CodingKeys: String, CodingKey {
        case group
        case previousOwnerUID = "previous_owner_uid"
        case newOwnerUID = "new_owner_uid"
        case oldOwnerRole = "old_owner_role"
        case previousOwner = "previous_owner"
        case newOwner = "new_owner"
        case transferredAt = "transferred_at"
        case idempotent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .group) ?? .empty
        previousOwnerUID = try c.decodeIfPresent(String.self, forKey: .previousOwnerUID) ?? ""
        newOwnerUID = try c.decodeIfPresent(String.self, forKey: .newOwnerUID) ?? ""
        oldOwnerRole = try c.decodeIfPresent(String.self, forKey: .oldOwnerRole) ?? ""
        previousOwner = try c.decodeIfPresent(RemoteUserGroupMember.self, forKey: .previousOwner)
        newOwner = try c.decodeIfPresent(RemoteUserGroupMember.self, forKey: .newOwner)
        transferredAt = try c.decodeIfPresent(String.self, forKey: .transferredAt) ?? ""
        idempotent = c.decodeLossyBoolIfPresent(forKey: .idempotent) ?? false
    }
}

struct RemoteSplashConfiguration: Equatable, Sendable {
    let licenseEnabled: Bool
    let configEnabled: Bool?
    let splashEnabled: Bool
    let assetID: String
    let imageURL: String
    let version: String
    let cacheKey: String
    let cacheStrategy: String
    let width: Int?
    let height: Int?
    let mimeType: String
    let sizeBytes: Int64?
    let etag: String
    let sha256: String
    let minIntervalSec: Int?
    let dailyCap: Int?
    let minShowMS: Int?
    let maxShowMS: Int?
    let actionURL: String
    let serverDisabledReason: String

    var disabledReason: String {
        if !licenseEnabled { return "license_disabled" }
        let serverReason = serverDisabledReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverReason.isEmpty { return serverReason }
        guard let configEnabled else { return "splash_config_missing" }
        if !configEnabled { return "splash_config_disabled" }
        if !splashEnabled { return "splash_disabled" }
        if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "missing_version" }
        if imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "missing_image_url" }
        return ""
    }

    func makeSnapshot(tenantID: String, resolvedImageURL: String, fetchedAt: Date = Date()) -> SplashConfigSnapshot {
        SplashConfigSnapshot(
        tenantID: tenantID,
        licenseEnabled: licenseEnabled,
        splashEnabled: splashEnabled,
            assetID: assetID,
            imageURL: resolvedImageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? imageURL : resolvedImageURL,
            version: version,
            cacheKeyOverride: cacheKey,
            width: width,
            height: height,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            etag: etag,
            sha256: sha256,
            minIntervalSec: minIntervalSec,
            dailyCap: dailyCap,
            minShowMS: minShowMS,
            maxShowMS: maxShowMS,
            actionURL: actionURL,
            fetchedAt: fetchedAt.timeIntervalSince1970,
            disabledReason: disabledReason,
            prefetchStatus: disabledReason.isEmpty ? .pending : .skipped,
            lastPrefetchAt: nil,
            lastPrefetchError: ""
        )
    }

    static let empty = RemoteSplashConfiguration(
        licenseEnabled: false,
        configEnabled: nil,
        splashEnabled: false,
        assetID: "",
        imageURL: "",
        version: "",
        cacheKey: "",
        cacheStrategy: "",
        width: nil,
        height: nil,
        mimeType: "",
        sizeBytes: nil,
        etag: "",
        sha256: "",
        minIntervalSec: nil,
        dailyCap: nil,
        minShowMS: nil,
        maxShowMS: nil,
        actionURL: "",
        serverDisabledReason: ""
    )

}

struct RemoteFileUploadConfig: Decodable {
    let maxBytes: Int64
    let maxMB: Int
    let source: String
    let messageRecallMaxMinutes: Int
    let voiceCallEnabled: Bool
    let videoCallEnabled: Bool
    let voiceCallLicenseKnown: Bool
    let videoCallLicenseKnown: Bool
    let readReceiptsEnabled: Bool
    let groupAdminDeleteMessageEnabled: Bool
    let splashConfiguration: RemoteSplashConfiguration

    enum CodingKeys: String, CodingKey {
        case fileUploadMaxBytes = "file_upload_max_bytes"
        case maxFileSizeBytes = "max_file_size_bytes"
        case maxBytes = "max_bytes"
        case maxMB = "max_mb"
        case source
        case messageRecallMaxMinutes = "message_recall_max_minutes"
        case voiceCallEnabled = "voice_call_enabled"
        case videoCallEnabled = "video_call_enabled"
        case readReceiptsEnabled = "read_receipts_enabled"
        case groupAdminDeleteMessageEnabled = "group_admin_delete_message_enabled"
        case features
        case splash
        case splashEnabled = "splash_enabled"
        case splashLicenseEnabled = "splash_license_enabled"
        case splashConfigEnabled = "splash_config_enabled"
        case splashAssetID = "splash_asset_id"
        case splashImageURL = "splash_image_url"
        case splashVersion = "splash_version"
        case splashWidth = "splash_width"
        case splashHeight = "splash_height"
        case splashMimeType = "splash_mime_type"
        case splashSizeBytes = "splash_size_bytes"
        case splashETag = "splash_etag"
        case splashSHA256 = "splash_sha256"
        case splashCacheKey = "splash_cache_key"
        case splashCacheStrategy = "splash_cache_strategy"
        case splashDisabledReason = "splash_disabled_reason"
        case splashMinIntervalSec = "splash_min_interval_sec"
        case splashDailyCap = "splash_daily_cap"
        case splashMinShowMS = "splash_min_show_ms"
        case splashMaxShowMS = "splash_max_show_ms"
        case splashActionURL = "splash_action_url"
    }

    enum FeatureCodingKeys: String, CodingKey {
        case messageRecallMaxMinutes = "message_recall_max_minutes"
        case voiceCallEnabled = "voice_call_enabled"
        case videoCallEnabled = "video_call_enabled"
        case readReceiptsEnabled = "read_receipts_enabled"
        case groupAdminDeleteMessageEnabled = "group_admin_delete_message_enabled"
        case splashEnabled = "splash_enabled"
        case splashLicenseEnabled = "splash_license_enabled"
        case splashConfigEnabled = "splash_config_enabled"
    }

    enum SplashCodingKeys: String, CodingKey {
        case enabled
        case splashEnabled = "splash_enabled"
        case licenseEnabled = "license_enabled"
        case splashLicenseEnabled = "splash_license_enabled"
        case configEnabled = "config_enabled"
        case splashConfigEnabled = "splash_config_enabled"
        case assetID = "asset_id"
        case splashAssetID = "splash_asset_id"
        case imageURL = "image_url"
        case splashImageURL = "splash_image_url"
        case version
        case splashVersion = "splash_version"
        case width
        case splashWidth = "splash_width"
        case height
        case splashHeight = "splash_height"
        case mimeType = "mime_type"
        case splashMimeType = "splash_mime_type"
        case sizeBytes = "size_bytes"
        case splashSizeBytes = "splash_size_bytes"
        case etag
        case splashETag = "splash_etag"
        case sha256
        case splashSHA256 = "splash_sha256"
        case cacheKey = "cache_key"
        case splashCacheKey = "splash_cache_key"
        case cacheStrategy = "cache_strategy"
        case splashCacheStrategy = "splash_cache_strategy"
        case disabledReason = "disabled_reason"
        case splashDisabledReason = "splash_disabled_reason"
        case minIntervalSec = "min_interval_sec"
        case splashMinIntervalSec = "splash_min_interval_sec"
        case dailyCap = "daily_cap"
        case splashDailyCap = "splash_daily_cap"
        case minShowMS = "min_show_ms"
        case splashMinShowMS = "splash_min_show_ms"
        case maxShowMS = "max_show_ms"
        case splashMaxShowMS = "splash_max_show_ms"
        case actionURL = "action_url"
        case splashActionURL = "splash_action_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let features = try? c.nestedContainer(keyedBy: FeatureCodingKeys.self, forKey: .features)
        let splash = try? c.nestedContainer(keyedBy: SplashCodingKeys.self, forKey: .splash)

        func splashString(_ topKey: CodingKeys, nestedKeys: [SplashCodingKeys]) -> String {
            if let value = c.decodeLossyStringIfPresent(forKey: topKey) {
                return value
            }
            guard let splash else { return "" }
            for key in nestedKeys {
                if let value = splash.decodeLossyStringIfPresent(forKey: key) {
                    return value
                }
            }
            return ""
        }

        func splashBool(_ topKey: CodingKeys, featureKey: FeatureCodingKeys?, nestedKeys: [SplashCodingKeys]) -> Bool? {
            if let value = c.decodeLossyBoolIfPresent(forKey: topKey) {
                return value
            }
            if let featureKey, let value = features?.decodeLossyBoolIfPresent(forKey: featureKey) {
                return value
            }
            guard let splash else { return nil }
            for key in nestedKeys {
                if let value = splash.decodeLossyBoolIfPresent(forKey: key) {
                    return value
                }
            }
            return nil
        }

        func splashInt(_ topKey: CodingKeys, nestedKeys: [SplashCodingKeys]) -> Int? {
            if let value = c.decodeLossyIntIfPresent(forKey: topKey) {
                return value
            }
            guard let splash else { return nil }
            for key in nestedKeys {
                if let value = splash.decodeLossyIntIfPresent(forKey: key) {
                    return value
                }
            }
            return nil
        }

        func splashInt64(_ topKey: CodingKeys, nestedKeys: [SplashCodingKeys]) -> Int64? {
            if let value = c.decodeLossyInt64IfPresent(forKey: topKey) {
                return value
            }
            guard let splash else { return nil }
            for key in nestedKeys {
                if let value = splash.decodeLossyInt64IfPresent(forKey: key) {
                    return value
                }
            }
            return nil
        }

        maxBytes = try c.decodeIfPresent(Int64.self, forKey: .fileUploadMaxBytes)
            ?? c.decodeIfPresent(Int64.self, forKey: .maxFileSizeBytes)
            ?? c.decodeIfPresent(Int64.self, forKey: .maxBytes)
            ?? FileUploadConfig.defaultValue.maxBytes
        maxMB = try c.decodeIfPresent(Int.self, forKey: .maxMB)
            ?? max(1, Int((maxBytes + 1024 * 1024 - 1) / (1024 * 1024)))
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? FileUploadConfig.defaultValue.source
        messageRecallMaxMinutes = c.decodeLossyIntIfPresent(forKey: .messageRecallMaxMinutes)
            ?? features?.decodeLossyIntIfPresent(forKey: .messageRecallMaxMinutes)
            ?? FileUploadConfig.defaultValue.messageRecallMaxMinutes
        let voiceLicense = c.decodeLossyBoolIfPresent(forKey: .voiceCallEnabled)
            ?? features?.decodeLossyBoolIfPresent(forKey: .voiceCallEnabled)
        let videoLicense = c.decodeLossyBoolIfPresent(forKey: .videoCallEnabled)
            ?? features?.decodeLossyBoolIfPresent(forKey: .videoCallEnabled)
        voiceCallEnabled = voiceLicense ?? false
        videoCallEnabled = videoLicense ?? false
        voiceCallLicenseKnown = voiceLicense != nil
        videoCallLicenseKnown = videoLicense != nil
        readReceiptsEnabled = c.decodeLossyBoolIfPresent(forKey: .readReceiptsEnabled)
            ?? features?.decodeLossyBoolIfPresent(forKey: .readReceiptsEnabled)
            ?? FileUploadConfig.defaultValue.readReceiptsEnabled
        groupAdminDeleteMessageEnabled = c.decodeLossyBoolIfPresent(forKey: .groupAdminDeleteMessageEnabled)
            ?? features?.decodeLossyBoolIfPresent(forKey: .groupAdminDeleteMessageEnabled)
            ?? FileUploadConfig.defaultValue.groupAdminDeleteMessageEnabled
        splashConfiguration = RemoteSplashConfiguration(
            licenseEnabled: splashBool(
                .splashLicenseEnabled,
                featureKey: .splashLicenseEnabled,
                nestedKeys: [.splashLicenseEnabled, .licenseEnabled]
            ) ?? false,
            configEnabled: splashBool(
                .splashConfigEnabled,
                featureKey: .splashConfigEnabled,
                nestedKeys: [.splashConfigEnabled, .configEnabled]
            ),
            splashEnabled: splashBool(
                .splashEnabled,
                featureKey: .splashEnabled,
                nestedKeys: [.splashEnabled, .enabled]
            ) ?? false,
            assetID: splashString(.splashAssetID, nestedKeys: [.splashAssetID, .assetID]),
            imageURL: splashString(.splashImageURL, nestedKeys: [.splashImageURL, .imageURL]),
            version: splashString(.splashVersion, nestedKeys: [.splashVersion, .version]),
            cacheKey: splashString(.splashCacheKey, nestedKeys: [.splashCacheKey, .cacheKey]),
            cacheStrategy: splashString(.splashCacheStrategy, nestedKeys: [.splashCacheStrategy, .cacheStrategy]),
            width: splashInt(.splashWidth, nestedKeys: [.splashWidth, .width]),
            height: splashInt(.splashHeight, nestedKeys: [.splashHeight, .height]),
            mimeType: splashString(.splashMimeType, nestedKeys: [.splashMimeType, .mimeType]),
            sizeBytes: splashInt64(.splashSizeBytes, nestedKeys: [.splashSizeBytes, .sizeBytes]),
            etag: splashString(.splashETag, nestedKeys: [.splashETag, .etag]),
            sha256: splashString(.splashSHA256, nestedKeys: [.splashSHA256, .sha256]),
            minIntervalSec: splashInt(.splashMinIntervalSec, nestedKeys: [.splashMinIntervalSec, .minIntervalSec]),
            dailyCap: splashInt(.splashDailyCap, nestedKeys: [.splashDailyCap, .dailyCap]),
            minShowMS: splashInt(.splashMinShowMS, nestedKeys: [.splashMinShowMS, .minShowMS]),
            maxShowMS: splashInt(.splashMaxShowMS, nestedKeys: [.splashMaxShowMS, .maxShowMS]),
            actionURL: splashString(.splashActionURL, nestedKeys: [.splashActionURL, .actionURL]),
            serverDisabledReason: splashString(.splashDisabledReason, nestedKeys: [.splashDisabledReason, .disabledReason])
        )
    }

    var model: FileUploadConfig {
        FileUploadConfig(
            maxBytes: maxBytes,
            maxMB: maxMB,
            source: source,
            messageRecallMaxMinutes: messageRecallMaxMinutes,
            voiceCallEnabled: voiceCallEnabled,
            videoCallEnabled: videoCallEnabled,
            readReceiptsEnabled: readReceiptsEnabled,
            groupAdminDeleteMessageEnabled: groupAdminDeleteMessageEnabled,
            voiceCallLicenseKnown: voiceCallLicenseKnown,
            videoCallLicenseKnown: videoCallLicenseKnown
        )
    }
}

struct RemoteGroupFile: Decodable {
    let fileID: String
    let name: String
    let type: String
    let mimeType: String
    let category: String
    let size: Int64
    let uploaderUID: String
    let uploaderName: String
    let channelID: String
    let channelType: String
    let channelSeq: Int64
    let groupID: String
    let sourceName: String
    let createdAt: String?
    let previewAvailable: Bool
    let downloadAvailable: Bool
    let previewURL: String
    let downloadURL: String
    let status: String
    let cacheKey: String
    let version: String
    let checksum: String
    let mediaCategory: String
    let contentType: String
    let kind: String
    let fileExtension: String
    let thumbnailURL: String
    let posterURL: String
    let coverURL: String
    let previewKind: String
    let contentDisposition: String
    let width: Int?
    let height: Int?
    let durationSeconds: Double?

    var channelScopeText: String {
        switch channelType {
        case "group":
            return "群文件"
        case "direct":
            return "私聊文件"
        default:
            return channelID.isEmpty ? "文件模块" : channelID
        }
    }

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case id
        case name
        case fileName = "file_name"
        case type
        case mimeType = "mime_type"
        case category
        case size
        case sizeBytes = "size_bytes"
        case uploaderUID = "uploader_uid"
        case uploaderName = "uploader_name"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case seq
        case groupID = "group_id"
        case sourceName = "source_name"
        case createdAt = "created_at"
        case previewAvailable = "preview_available"
        case downloadAvailable = "download_available"
        case previewURL = "preview_url"
        case downloadURL = "download_url"
        case downloadPublic = "download_public"
        case status
        case uploadStatus = "upload_status"
        case cacheKey = "cache_key"
        case version
        case fileVersion = "file_version"
        case cacheVersion = "cache_version"
        case checksum
        case mediaCategory = "media_category"
        case contentType = "content_type"
        case contentTypeCamel = "contentType"
        case kind
        case fileExtension = "extension"
        case thumbnailURL = "thumbnail_url"
        case thumbURL = "thumb_url"
        case thumbnailEndpoint = "thumbnail_endpoint"
        case previewThumbnailURL = "preview_thumbnail_url"
        case thumbnailPreviewURL = "thumbnail_preview_url"
        case posterURL = "poster_url"
        case posterEndpoint = "poster_endpoint"
        case videoPosterURL = "video_poster_url"
        case coverURL = "cover_url"
        case coverEndpoint = "cover_endpoint"
        case videoCoverURL = "video_cover_url"
        case previewKind = "preview_kind"
        case contentDisposition = "content_disposition"
        case width
        case height
        case durationSeconds = "duration_seconds"
        case duration
        case durationMS = "duration_ms"
    }

    init(
        fileID: String,
        name: String,
        type: String,
        mimeType: String,
        category: String,
        size: Int64,
        uploaderUID: String,
        uploaderName: String,
        channelID: String,
        channelType: String,
        channelSeq: Int64 = 0,
        groupID: String,
        sourceName: String,
        createdAt: String?,
        previewAvailable: Bool,
        downloadAvailable: Bool,
        previewURL: String,
        downloadURL: String,
        status: String,
        cacheKey: String = "",
        version: String = "",
        checksum: String = "",
        mediaCategory: String = "",
        contentType: String = "",
        kind: String = "",
        fileExtension: String = "",
        thumbnailURL: String = "",
        posterURL: String = "",
        coverURL: String = "",
        previewKind: String = "",
        contentDisposition: String = "",
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil
    ) {
        self.fileID = fileID
        self.name = name
        self.type = type
        self.mimeType = mimeType
        self.category = category
        self.size = size
        self.uploaderUID = uploaderUID
        self.uploaderName = uploaderName
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.groupID = groupID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.previewAvailable = previewAvailable
        self.downloadAvailable = downloadAvailable
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.status = status
        self.cacheKey = cacheKey
        self.version = version
        self.checksum = checksum
        self.mediaCategory = mediaCategory
        self.contentType = contentType
        self.kind = kind
        self.fileExtension = fileExtension
        self.thumbnailURL = thumbnailURL
        self.posterURL = posterURL
        self.coverURL = coverURL
        self.previewKind = previewKind
        self.contentDisposition = contentDisposition
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .fileName)
            ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
            ?? c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
            ?? 0
        uploaderUID = try c.decodeIfPresent(String.self, forKey: .uploaderUID) ?? ""
        uploaderName = try c.decodeIfPresent(String.self, forKey: .uploaderName) ?? ""
        let decodedGroupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        let decodedChannelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? (decodedGroupID.isEmpty ? "" : "group")
        channelSeq = c.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
            ?? c.decodeLossyInt64IfPresent(forKey: .seq)
            ?? 0
        groupID = decodedGroupID
        channelID = decodedChannelID.isEmpty ? decodedGroupID : decodedChannelID
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        previewAvailable = try c.decodeIfPresent(Bool.self, forKey: .previewAvailable) ?? false
        downloadAvailable = try c.decodeIfPresent(Bool.self, forKey: .downloadAvailable) ?? false
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL) ?? ""
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPublic)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .uploadStatus)
            ?? ""
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version)
            ?? c.decodeIfPresent(String.self, forKey: .fileVersion)
            ?? c.decodeIfPresent(String.self, forKey: .cacheVersion)
            ?? ""
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum) ?? ""
        mediaCategory = try c.decodeIfPresent(String.self, forKey: .mediaCategory) ?? ""
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
            ?? c.decodeIfPresent(String.self, forKey: .contentTypeCamel)
            ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .previewThumbnailURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailPreviewURL)
            ?? ""
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL)
            ?? c.decodeIfPresent(String.self, forKey: .posterEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .videoPosterURL)
            ?? ""
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
            ?? c.decodeIfPresent(String.self, forKey: .coverEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .videoCoverURL)
            ?? ""
        previewKind = try c.decodeIfPresent(String.self, forKey: .previewKind) ?? ""
        contentDisposition = try c.decodeIfPresent(String.self, forKey: .contentDisposition) ?? ""
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        if let seconds = c.decodeLossyDoubleIfPresent(forKey: .durationSeconds)
            ?? c.decodeLossyDoubleIfPresent(forKey: .duration) {
            durationSeconds = seconds
        } else if let milliseconds = c.decodeLossyDoubleIfPresent(forKey: .durationMS) {
            durationSeconds = milliseconds / 1000.0
        } else {
            durationSeconds = nil
        }
    }
}

struct RemoteFavoriteAssetsResponse: Decodable, Equatable {
    let items: [RemoteFavoriteAssetItem]
    let nextCursor: String
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
        case hasMore = "has_more"
        case hasMoreCamel = "hasMore"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteFavoriteAssetItem].self, forKey: .items) ?? []
        let snakeCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        let camelCursor = try c.decodeIfPresent(String.self, forKey: .nextCursorCamel)
        nextCursor = snakeCursor ?? camelCursor ?? ""
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreCamel)
            ?? false
    }
}

struct RemoteFavoriteAssetItem: Decodable, Equatable {
    let tenantID: String
    let messageID: String
    let channelID: String
    let channelType: String
    let channelSeq: Int64
    let fromUID: String
    let senderUID: String
    let senderUserID: String
    let fromUserID: String
    let contentType: String
    let payload: [String: JSONValue]
    let status: String
    let createdAt: String?
    let favoritedAt: String?
    let favoriteVersion: Int64
    let category: String
    let displayText: String
    let cursor: String

    var resolvedSenderID: String {
        [fromUID, senderUID, senderUserID, fromUserID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case messageID = "message_id"
        case messageIDCamel = "messageId"
        case id
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case seq
        case fromUID = "from_uid"
        case fromUIDCamel = "fromUid"
        case senderUID = "sender_uid"
        case senderUIDCamel = "senderUid"
        case senderUserID = "sender_user_id"
        case senderUserIDCamel = "senderUserId"
        case fromUserID = "from_user_id"
        case fromUserIDCamel = "fromUserId"
        case contentType = "content_type"
        case contentTypeCamel = "contentType"
        case payload
        case status
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case favoritedAt = "favorited_at"
        case favoritedAtCamel = "favoritedAt"
        case favoriteVersion = "favorite_version"
        case favoriteVersionCamel = "favoriteVersion"
        case version
        case category
        case displayText = "display_text"
        case displayTextCamel = "displayText"
        case cursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPayload = try c.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        payload = decodedPayload
        tenantID = Self.decodeString(from: c, keys: [.tenantID, .tenantIDCamel], fallback: decodedPayload["tenant_id"]?.stringValue)
        messageID = Self.decodeString(from: c, keys: [.messageID, .messageIDCamel, .id], fallback: decodedPayload["message_id"]?.stringValue)
        channelID = Self.decodeString(from: c, keys: [.channelID, .channelIDCamel], fallback: decodedPayload["channel_id"]?.stringValue)
        channelType = Self.decodeString(from: c, keys: [.channelType, .channelTypeCamel], fallback: decodedPayload["channel_type"]?.stringValue)
        channelSeq = c.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
            ?? c.decodeLossyInt64IfPresent(forKey: .seq)
            ?? 0
        fromUID = Self.decodeString(from: c, keys: [.fromUID, .fromUIDCamel], fallback: decodedPayload["from_uid"]?.stringValue)
        senderUID = Self.decodeString(from: c, keys: [.senderUID, .senderUIDCamel], fallback: decodedPayload["sender_uid"]?.stringValue)
        senderUserID = Self.decodeString(from: c, keys: [.senderUserID, .senderUserIDCamel], fallback: decodedPayload["sender_user_id"]?.stringValue)
        fromUserID = Self.decodeString(from: c, keys: [.fromUserID, .fromUserIDCamel], fallback: decodedPayload["from_user_id"]?.stringValue)
        contentType = Self.decodeString(from: c, keys: [.contentType, .contentTypeCamel], fallback: decodedPayload["content_type"]?.stringValue)
        status = Self.decodeString(from: c, keys: [.status], fallback: decodedPayload["status"]?.stringValue)
        createdAt = Self.decodeOptionalString(from: c, keys: [.createdAt, .createdAtCamel])
        favoritedAt = Self.decodeOptionalString(from: c, keys: [.favoritedAt, .favoritedAtCamel])
        favoriteVersion = c.decodeLossyInt64IfPresent(forKey: .favoriteVersion)
            ?? c.decodeLossyInt64IfPresent(forKey: .favoriteVersionCamel)
            ?? c.decodeLossyInt64IfPresent(forKey: .version)
            ?? 0
        category = Self.decodeString(from: c, keys: [.category], fallback: decodedPayload["category"]?.stringValue)
        displayText = Self.decodeString(from: c, keys: [.displayText, .displayTextCamel], fallback: decodedPayload["display_text"]?.stringValue)
        cursor = Self.decodeString(from: c, keys: [.cursor], fallback: decodedPayload["cursor"]?.stringValue)
    }

    private static func decodeString(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys], fallback: String? = nil) -> String {
        decodeOptionalString(from: container, keys: keys) ?? fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func decodeOptionalString(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }
}

struct RemoteUserFileDetail: Decodable {
    let file: RemoteUserFileObject
    let previewAvailable: Bool
    let downloadAvailable: Bool
    let previewURL: String
    let downloadURL: String
    let contentDisposition: String

    enum CodingKeys: String, CodingKey {
        case file
        case previewAvailable = "preview_available"
        case downloadAvailable = "download_available"
        case previewURL = "preview_url"
        case downloadURL = "download_url"
        case downloadPublic = "download_public"
        case contentDisposition = "content_disposition"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(RemoteUserFileObject.self, forKey: .file)
        previewAvailable = try c.decodeIfPresent(Bool.self, forKey: .previewAvailable) ?? false
        downloadAvailable = try c.decodeIfPresent(Bool.self, forKey: .downloadAvailable) ?? false
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL) ?? ""
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPublic)
            ?? ""
        contentDisposition = try c.decodeIfPresent(String.self, forKey: .contentDisposition)
            ?? file.contentDisposition
    }
}

struct RemoteUserFileObject: Decodable {
    let id: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int64
    let uploaderUID: String
    let status: String
    let createdAt: String?
    let cacheKey: String
    let version: String
    let checksum: String
    let mediaCategory: String
    let contentType: String
    let kind: String
    let fileExtension: String
    let thumbnailURL: String
    let posterURL: String
    let coverURL: String
    let previewKind: String
    let contentDisposition: String
    let width: Int?
    let height: Int?
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case fileID = "file_id"
        case fileName = "file_name"
        case name
        case mimeType = "mime_type"
        case extensionValue = "extension"
        case kind
        case sizeBytes = "size_bytes"
        case size
        case uploaderUID = "uploader_uid"
        case status
        case uploadStatus = "upload_status"
        case createdAt = "created_at"
        case cacheKey = "cache_key"
        case version
        case fileVersion = "file_version"
        case cacheVersion = "cache_version"
        case checksum
        case mediaCategory = "media_category"
        case contentType = "content_type"
        case contentTypeCamel = "contentType"
        case thumbnailURL = "thumbnail_url"
        case thumbURL = "thumb_url"
        case thumbnailEndpoint = "thumbnail_endpoint"
        case previewThumbnailURL = "preview_thumbnail_url"
        case thumbnailPreviewURL = "thumbnail_preview_url"
        case posterURL = "poster_url"
        case posterEndpoint = "poster_endpoint"
        case videoPosterURL = "video_poster_url"
        case coverURL = "cover_url"
        case coverEndpoint = "cover_endpoint"
        case videoCoverURL = "video_cover_url"
        case previewKind = "preview_kind"
        case contentDisposition = "content_disposition"
        case width
        case height
        case durationSeconds = "duration_seconds"
        case duration
        case durationMS = "duration_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .fileID)
            ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
            ?? c.decodeIfPresent(Int64.self, forKey: .size)
            ?? 0
        uploaderUID = try c.decodeIfPresent(String.self, forKey: .uploaderUID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .uploadStatus)
            ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version)
            ?? c.decodeIfPresent(String.self, forKey: .fileVersion)
            ?? c.decodeIfPresent(String.self, forKey: .cacheVersion)
            ?? ""
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum) ?? ""
        mediaCategory = try c.decodeIfPresent(String.self, forKey: .mediaCategory) ?? ""
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
            ?? c.decodeIfPresent(String.self, forKey: .contentTypeCamel)
            ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        fileExtension = try c.decodeIfPresent(String.self, forKey: .extensionValue) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .previewThumbnailURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailPreviewURL)
            ?? ""
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL)
            ?? c.decodeIfPresent(String.self, forKey: .posterEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .videoPosterURL)
            ?? ""
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
            ?? c.decodeIfPresent(String.self, forKey: .coverEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .videoCoverURL)
            ?? ""
        previewKind = try c.decodeIfPresent(String.self, forKey: .previewKind) ?? ""
        contentDisposition = try c.decodeIfPresent(String.self, forKey: .contentDisposition) ?? ""
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        if let seconds = c.decodeLossyDoubleIfPresent(forKey: .durationSeconds)
            ?? c.decodeLossyDoubleIfPresent(forKey: .duration) {
            durationSeconds = seconds
        } else if let milliseconds = c.decodeLossyDoubleIfPresent(forKey: .durationMS) {
            durationSeconds = milliseconds / 1000.0
        } else {
            durationSeconds = nil
        }
    }
}

struct RemoteGroupJoinRequest: Decodable {
    let id: String
    let groupID: String
    let applicantUID: String
    let applicantName: String
    let applicantAvatar: String
    let inviterAvatar: String
    let inviterName: String
    let status: String
    let message: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case applicantUID = "applicant_uid"
        case targetUID = "target_uid"
        case inviterUID = "inviter_uid"
        case applicantName = "applicant_name"
        case targetName = "target_name"
        case inviteeName = "invitee_name"
        case applicantAvatar = "applicant_avatar"
        case inviterAvatar = "inviter_avatar"
        case inviterName = "inviter_name"
        case status
        case message
        case reason
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        applicantUID = try c.decodeIfPresent(String.self, forKey: .applicantUID)
            ?? c.decodeIfPresent(String.self, forKey: .targetUID)
            ?? c.decodeIfPresent(String.self, forKey: .inviterUID)
            ?? ""
        applicantName = try c.decodeIfPresent(String.self, forKey: .applicantName)
            ?? c.decodeIfPresent(String.self, forKey: .targetName)
            ?? c.decodeIfPresent(String.self, forKey: .inviteeName)
            ?? ""
        applicantAvatar = try c.decodeIfPresent(String.self, forKey: .applicantAvatar) ?? ""
        inviterAvatar = try c.decodeIfPresent(String.self, forKey: .inviterAvatar) ?? ""
        inviterName = try c.decodeIfPresent(String.self, forKey: .inviterName) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        message = try c.decodeIfPresent(String.self, forKey: .message)
            ?? c.decodeIfPresent(String.self, forKey: .reason)
            ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

struct RemoteCreateGroupJoinRequestResponse: Decodable {
    let status: String
    let request: RemoteGroupJoinRequest?
    let joinRequests: [RemoteGroupJoinRequest]
    let notifications: [RemoteInboxEntry]
    let systemMessages: [RemoteMessage]
    let items: [RemoteGroupMember]

    enum CodingKeys: String, CodingKey {
        case status
        case request
        case joinRequests = "join_requests"
        case requests
        case notifications
        case systemMessages = "system_messages"
        case items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        request = try c.decodeIfPresent(RemoteGroupJoinRequest.self, forKey: .request)
        joinRequests = try c.decodeIfPresent([RemoteGroupJoinRequest].self, forKey: .joinRequests)
            ?? c.decodeIfPresent([RemoteGroupJoinRequest].self, forKey: .requests)
            ?? []
        notifications = (try? c.decodeIfPresent([RemoteInboxEntry].self, forKey: .notifications)) ?? []
        systemMessages = try c.decodeIfPresent([RemoteMessage].self, forKey: .systemMessages) ?? []
        items = try c.decodeIfPresent([RemoteGroupMember].self, forKey: .items) ?? []
    }

    var requiresApproval: Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requestStatus = request?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["pending", "pending_approval", "waiting_approval", "submitted"].contains(normalizedStatus)
            || ["pending", "pending_approval", "waiting_approval", "submitted"].contains(requestStatus)
            || !joinRequests.isEmpty
    }
}

struct RemoteGroupDNDResult: Decodable {
    let muted: Bool
}

struct RemoteRawGroup: Decodable {
    let groupID: String
    let groupRevision: Int64
    let name: String
    let avatar: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case groupRevision = "group_revision"
        case name
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    init(groupID: String, groupRevision: Int64 = 0, name: String = "", avatar: String = "", avatarVersion: String = "", avatarUpdatedAt: String = "") {
        self.groupID = groupID
        self.groupRevision = groupRevision
        self.name = name
        self.avatar = avatar
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        groupRevision = max(0, c.decodeLossyInt64IfPresent(forKey: .groupRevision) ?? 0)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
    }
}

struct RemoteGroupProfileUpdateResponse: Decodable {
    let group: RemoteUserGroup?
    let summary: RemoteUserGroup?
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case group
        case summary
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatar
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = try container.decodeIfPresent(RemoteUserGroup.self, forKey: .group)
        summary = try container.decodeIfPresent(RemoteUserGroup.self, forKey: .summary)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? container.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? container.decodeIfPresent(String.self, forKey: .avatar)
            ?? summary?.avatar
            ?? group?.avatar
            ?? ""
        avatarVersion = try container.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? container.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? container.decodeIfPresent(String.self, forKey: .version)
            ?? summary?.avatarVersion
            ?? group?.avatarVersion
            ?? ""
        avatarUpdatedAt = try container.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? container.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? summary?.avatarUpdatedAt
            ?? group?.avatarUpdatedAt
            ?? ""
    }

    var effectiveGroup: RemoteUserGroup {
        summary ?? group ?? .empty
    }
}

struct RemoteCreateGroupResponse: Decodable {
    let group: RemoteRawGroup
    let members: [RemoteGroupMember]
    let systemMessages: [RemoteMessage]

    enum CodingKeys: String, CodingKey {
        case group
        case members
        case systemMessages = "system_messages"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decodeIfPresent(RemoteRawGroup.self, forKey: .group) ?? RemoteRawGroup(groupID: "")
        members = try c.decodeIfPresent([RemoteGroupMember].self, forKey: .members) ?? []
        systemMessages = try c.decodeIfPresent([RemoteMessage].self, forKey: .systemMessages) ?? []
    }
}

struct RemoteInviteGroupMembersResponse: Decodable {
    let items: [RemoteGroupMember]
    let systemMessages: [RemoteMessage]
    let status: String
    let joinRequests: [RemoteGroupJoinRequest]
    let notifications: [RemoteInboxEntry]
    let pendingApproval: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case systemMessages = "system_messages"
        case status
        case joinRequests = "join_requests"
        case requests
        case notifications
        case pendingApproval = "pending_approval"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteGroupMember].self, forKey: .items) ?? []
        systemMessages = try c.decodeIfPresent([RemoteMessage].self, forKey: .systemMessages) ?? []
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        joinRequests = try c.decodeIfPresent([RemoteGroupJoinRequest].self, forKey: .joinRequests)
            ?? c.decodeIfPresent([RemoteGroupJoinRequest].self, forKey: .requests)
            ?? []
        notifications = (try? c.decodeIfPresent([RemoteInboxEntry].self, forKey: .notifications)) ?? []
        pendingApproval = try c.decodeIfPresent(Bool.self, forKey: .pendingApproval) ?? false
    }

    var requiresApproval: Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return pendingApproval
            || !joinRequests.isEmpty
            || ["pending", "pending_approval", "waiting_approval", "submitted"].contains(normalizedStatus)
    }
}

struct RemoteGroup: Decodable {
    let groupID: String
    enum CodingKeys: String, CodingKey { case groupID = "group_id" }
}

struct RemoteGroupMember: Decodable {
    let imUID: String
    let role: String
    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = [
            try c.decodeIfPresent(String.self, forKey: .imUID),
            try c.decodeIfPresent(String.self, forKey: .userID)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "member"
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话分页结果标记为可跨任务传递的值快照
struct RemoteConversationPage: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    let conversations: [RemoteConversation]
    let hasMore: Bool
    let nextCursor: String?
    let snapshotID: String?
    let snapshotVersion: Int64?

    enum CodingKeys: String, CodingKey {
        case conversations
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case snapshotID = "snapshot_id"
        case snapshotVersion = "snapshot_version"
    }
}

struct ConversationPageFailure: Error, LocalizedError {
    let statusCode: Int
    let code: String
    var errorDescription: String? { "会话加载未完成，请重试同步" }
}

@MainActor
enum ConversationPageLoader {
    static func load(
        request: (String) async throws -> RemoteConversationPage,
        validate: () throws -> Void,
        onPage: (RemoteConversationPage) throws -> Void,
        onRestart: () throws -> Void,
        delay: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> Int64 {
        var retries = 0
        var restarted = false
        while true {
            var cursor = ""
            var seenCursors = Set<String>()
            var snapshotID: String?
            var version: Int64?
            do {
                while true {
                    try Task.checkCancellation()
                    try validate()
                    let page: RemoteConversationPage
                    do {
                        page = try await request(cursor)
                    } catch {
                        try validate()
                        let transient: Bool
                        if let failure = error as? ConversationPageFailure {
                            transient = (500...599).contains(failure.statusCode)
                        } else if let urlError = error as? URLError {
                            transient = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(urlError.code)
                        } else {
                            transient = false
                        }
                        guard transient, retries < 2 else { throw error }
                        retries += 1
                        try await delay(retries == 1 ? 400_000_000 : 1_000_000_000)
                        continue
                    }
                    try Task.checkCancellation()
                    try validate()
                    let id = page.snapshotID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let pageVersion = page.snapshotVersion ?? 0
                    guard !id.isEmpty, pageVersion >= 0,
                          snapshotID == nil || snapshotID == id,
                          version == nil || version == pageVersion else {
                        throw ConversationPageFailure(statusCode: 0, code: "invalid_snapshot")
                    }
                    snapshotID = id
                    version = pageVersion
                    if page.hasMore {
                        let next = page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !next.isEmpty, next != cursor, seenCursors.insert(next).inserted else {
                            throw ConversationPageFailure(statusCode: 0, code: "invalid_cursor")
                        }
                        cursor = next
                    }
                    try onPage(page)
                    if !page.hasMore { return pageVersion }
                    await Task.yield()
                }
            } catch let failure as ConversationPageFailure where !restarted && (
                failure.code == "conversation_page_cursor_expired"
                    || failure.code == "conversation_page_credentials_advanced"
            ) {
                try Task.checkCancellation()
                try validate()
                restarted = true
                try onRestart()
            }
        }
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话同步结果标记为可跨任务传递的值快照
struct RemoteConversationSyncData: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    let version: Int64
    let conversations: [RemoteConversation]
    let removedConversations: [RemoteRemovedConversation]

    enum CodingKeys: String, CodingKey {
        case version
        case conversations
        case removedConversations = "removed_conversations"
        case removedConversationsCamel = "removedConversations"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decodeLossyInt64IfPresent(forKey: .version) ?? 0
        conversations = try c.decodeIfPresent([RemoteConversation].self, forKey: .conversations) ?? []
        removedConversations = try c.decodeIfPresent([RemoteRemovedConversation].self, forKey: .removedConversations)
            ?? c.decodeIfPresent([RemoteRemovedConversation].self, forKey: .removedConversationsCamel)
            ?? []
    }
}

struct RemoteRemovedConversation: Decodable, Sendable, Equatable {
    let tenantID: String
    let channelID: String
    let channelType: String
    let reason: String
    let version: Int64
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case id
        case conversationID = "conversation_id"
        case conversationIDCamel = "conversationId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case type
        case reason
        case version
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
            ?? c.decodeIfPresent(String.self, forKey: .channelIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .conversationID)
            ?? c.decodeIfPresent(String.self, forKey: .conversationIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType)
            ?? c.decodeIfPresent(String.self, forKey: .channelTypeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .type)
            ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        version = c.decodeLossyInt64IfPresent(forKey: .version) ?? 0
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel)
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：置顶消息响应标记为可跨任务传递的值快照
struct RemotePinnedMessagesResponse: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    let items: [RemoteMessage]
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话模型标记为可跨任务传递的值快照
struct RemoteConversation: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    let channelID: String
    let channelType: String
    let unreadCount: Int
    let unreadReactionCount: Int
    let hasReactionUnread: Bool
    let lastMsgSeq: Int64
    let lastReadSeq: Int64
    let firstUnreadSeq: Int64
    let firstUnreadMessageID: String
    let unreadAnchorSeq: Int64
    let unreadAnchorState: String
    let version: Int64
    let stick: Bool
    let mute: Bool
    let muteProvided: Bool
    let lastActivityAt: String?
    let lastMessageAt: String?
    let updatedAt: String?
    let displayName: String
    let avatar: String
    let avatarProvided: Bool
    let avatarVersion: String
    let avatarUpdatedAt: String
    let lastMessage: RemoteMessage?
    let pinnedMessages: [RemoteMessage]
    let pinnedMessagesProvided: Bool
    let hasMention: Bool
    let mentionCount: Int
    let mentionSummary: RemoteMentionSummary?
    let historyVisibleFromSeq: Int64
    let historyLimited: Bool

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
        case unreadCount = "unread_count"
        case unreadReactionCount = "unread_reaction_count"
        case hasReactionUnread = "has_reaction_unread"
        case lastMsgSeq = "last_msg_seq"
        case lastReadSeq = "last_read_seq"
        case lastRead = "last_read"
        case firstUnreadSeq = "first_unread_seq"
        case firstUnreadMessageID = "first_unread_message_id"
        case unreadAnchorSeq = "unread_anchor_seq"
        case unreadAnchorState = "unread_anchor_state"
        case version
        case pinned
        case stick
        case sticky
        case top
        case isPinned = "is_pinned"
        case isPinnedCamel = "isPinned"
        case isStick = "is_stick"
        case isStickCamel = "isStick"
        case isSticky = "is_sticky"
        case isStickyCamel = "isSticky"
        case isTop = "is_top"
        case isTopCamel = "isTop"
        case mute
        case muted
        case dnd
        case isMuted = "is_muted"
        case isMutedCamel = "isMuted"
        case doNotDisturb = "do_not_disturb"
        case doNotDisturbCamel = "doNotDisturb"
        case lastActivityAt = "last_activity_at"
        case lastMessageAt = "last_message_at"
        case updatedAt = "updated_at"
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case name
        case title
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case lastMessage = "last_message"
        case pinnedMessages = "pinned_messages"
        case hasMention = "has_mention"
        case mentionCount = "mention_count"
        case mentionSummary = "mention_summary"
        case historyVisibleFromSeq = "history_visible_from_seq"
        case historyVisibleFromSeqCamel = "historyVisibleFromSeq"
        case historyLimited = "history_limited"
        case historyLimitedCamel = "historyLimited"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try container.decodeIfPresent(String.self, forKey: .channelType) ?? "direct"
        unreadCount = max(0, try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0)
        unreadReactionCount = max(0, try container.decodeIfPresent(Int.self, forKey: .unreadReactionCount) ?? 0)
        hasReactionUnread = Self.decodeHasReactionUnread(from: container, fallback: unreadReactionCount > 0)
        lastMsgSeq = try container.decodeIfPresent(Int64.self, forKey: .lastMsgSeq) ?? 0
        lastReadSeq = max(
            try container.decodeIfPresent(Int64.self, forKey: .lastReadSeq) ?? 0,
            try container.decodeIfPresent(Int64.self, forKey: .lastRead) ?? 0
        )
        firstUnreadSeq = max(0, try container.decodeIfPresent(Int64.self, forKey: .firstUnreadSeq) ?? 0)
        firstUnreadMessageID = try container.decodeIfPresent(String.self, forKey: .firstUnreadMessageID) ?? ""
        unreadAnchorSeq = max(0, try container.decodeIfPresent(Int64.self, forKey: .unreadAnchorSeq) ?? firstUnreadSeq)
        unreadAnchorState = try container.decodeIfPresent(String.self, forKey: .unreadAnchorState) ?? (firstUnreadSeq > 0 ? "ready" : "none")
        version = try container.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        stick = Self.decodePinnedState(from: container)
        mute = Self.decodeMutedState(from: container)
        muteProvided = Self.hasMutedStateField(in: container)
        lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt)
        lastMessageAt = try container.decodeIfPresent(String.self, forKey: .lastMessageAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? ""
        avatarProvided = container.contains(.avatar)
            || container.contains(.avatarURL)
            || container.contains(.avatarURLCamel)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
            ?? container.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? container.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try container.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? container.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? ""
        avatarUpdatedAt = try container.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? ""
        lastMessage = try container.decodeIfPresent(RemoteMessage.self, forKey: .lastMessage)
        pinnedMessages = try container.decodeIfPresent([RemoteMessage].self, forKey: .pinnedMessages) ?? []
        pinnedMessagesProvided = container.contains(.pinnedMessages)
        hasMention = try container.decodeIfPresent(Bool.self, forKey: .hasMention) ?? false
        mentionCount = max(0, try container.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0)
        mentionSummary = try container.decodeIfPresent(RemoteMentionSummary.self, forKey: .mentionSummary)
        historyVisibleFromSeq = max(
            1,
            container.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeq)
                ?? container.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeqCamel)
                ?? 1
        )
        historyLimited = container.decodeLossyBoolIfPresent(forKey: .historyLimited)
            ?? container.decodeLossyBoolIfPresent(forKey: .historyLimitedCamel)
            ?? false
    }

    private static func decodePinnedState(from container: KeyedDecodingContainer<CodingKeys>) -> Bool {
        [
            .pinned,
            .stick,
            .sticky,
            .top,
            .isPinned,
            .isPinnedCamel,
            .isStick,
            .isStickCamel,
            .isSticky,
            .isStickyCamel,
            .isTop,
            .isTopCamel
        ]
        .contains { container.decodeLossyBoolIfPresent(forKey: $0) == true }
    }

    private static func decodeMutedState(from container: KeyedDecodingContainer<CodingKeys>) -> Bool {
        [
            .mute,
            .muted,
            .dnd,
            .isMuted,
            .isMutedCamel,
            .doNotDisturb,
            .doNotDisturbCamel
        ]
        .contains { container.decodeLossyBoolIfPresent(forKey: $0) == true }
    }

    private static func hasMutedStateField(in container: KeyedDecodingContainer<CodingKeys>) -> Bool {
        [
            .mute,
            .muted,
            .dnd,
            .isMuted,
            .isMutedCamel,
            .doNotDisturb,
            .doNotDisturbCamel
        ]
        .contains { container.contains($0) }
    }

    private static func decodeHasReactionUnread(from container: KeyedDecodingContainer<CodingKeys>, fallback: Bool) -> Bool {
        if let boolValue = try? container.decode(Bool.self, forKey: .hasReactionUnread) {
            return boolValue
        }
        if let intValue = try? container.decode(Int.self, forKey: .hasReactionUnread) {
            return intValue > 0
        }
        if let stringValue = try? container.decode(String.self, forKey: .hasReactionUnread) {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "y"].contains(normalized)
        }
        return fallback
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端 mention 摘要标记为可跨任务传递的值快照
struct RemoteMentionSummary: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    let type: String
    let text: String
    let messageID: String
    let channelSeq: Int64

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case messageID = "message_id"
        case channelSeq = "channel_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        channelSeq = try container.decodeIfPresent(Int64.self, forKey: .channelSeq) ?? 0
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端消息模型标记为可跨任务传递的值快照
struct RemoteMessage: Decodable, Sendable {
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
    let messageID: String
    let clientMsgNo: String?
    let channelID: String
    let channelType: String
    let channelSeq: Int64
    let fromUID: String
    let senderProvenance: BatchForwardSenderProvenance
    let senderDisplayName: String
    let senderAvatar: String
    let senderAvatarVersion: String
    let senderAvatarUpdatedAt: String
    let contentType: String
    let payload: [String: JSONValue]
    let quote: String?
    let status: String
    let readStatus: String?
    let readCount: Int?
    let readAt: String?
    let createdAt: String?
    let isEdited: Bool
	let editRevision: Int64

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case id
        case clientMsgNo = "client_msg_no"
        case clientMessageID = "client_message_id"
        case clientID = "client_id"
        case clientMsgID = "client_msg_id"
        case localID = "local_id"
        case localIDCamel = "localId"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case channelSeq = "channel_seq"
        case seq
        case fromUID = "from_uid"
        case senderUID = "sender_uid"
        case senderUserID = "sender_user_id"
        case fromUserID = "from_user_id"
        case senderName = "sender_name"
        case senderDisplayName = "sender_display_name"
        case senderNickname = "sender_nickname"
        case fromName = "from_name"
        case fromNickname = "from_nickname"
        case displayName = "display_name"
        case nickname
        case senderAvatar = "sender_avatar"
        case senderAvatarURL = "sender_avatar_url"
        case fromAvatar = "from_avatar"
        case avatar
        case senderAvatarVersion = "sender_avatar_version"
        case senderAvatarVersionCamel = "senderAvatarVersion"
        case fromAvatarVersion = "from_avatar_version"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case senderAvatarUpdatedAt = "sender_avatar_updated_at"
        case senderAvatarUpdatedAtCamel = "senderAvatarUpdatedAt"
        case fromAvatarUpdatedAt = "from_avatar_updated_at"
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case contentType = "content_type"
        case payload
        case quote
        case quoteText = "quote_text"
        case quotedText = "quoted_text"
        case replyQuote = "reply_quote"
        case replyTo = "reply_to"
        case replyToCamel = "replyTo"
        case replyMessage = "reply_message"
        case replyMessageCamel = "replyMessage"
        case quotedMessage = "quoted_message"
        case quoted
        case reply
        case messageExtra = "message_extra"
        case status
        case readStatus = "read_status"
        case readCount = "read_count"
        case readAt = "read_at"
        case createdAt = "created_at"
        case isEdited = "is_edited"
        case edited
        case editedAt = "edited_at"
        case editedAtCamel = "editedAt"
		case editRevision = "edit_revision"
		case editRevisionCamel = "editRevision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decodedPayload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        for (payloadKey, codingKey) in [
            ("reply_to", CodingKeys.replyTo),
            ("replyTo", .replyToCamel),
            ("reply_message", .replyMessage),
            ("replyMessage", .replyMessageCamel),
            ("quoted_message", .quotedMessage),
            ("quoted", .quoted),
            ("reply", .reply),
            ("message_extra", .messageExtra)
        ] {
            if decodedPayload[payloadKey] == nil,
               let topLevelValue = try container.decodeIfPresent(JSONValue.self, forKey: codingKey) {
                decodedPayload[payloadKey] = topLevelValue
            }
        }
        payload = decodedPayload
        messageID = Self.decodeString(from: container, keys: [.messageID, .id])
        clientMsgNo = Self.decodeOptionalString(from: container, keys: [.clientMsgNo, .clientMessageID, .clientID, .clientMsgID, .localID, .localIDCamel])
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["client_msg_no", "client_message_id", "client_id", "client_msg_id", "local_id", "localId"]
            )
        channelID = Self.decodeString(from: container, keys: [.channelID], fallback: payload["channel_id"]?.stringValue)
        channelType = Self.decodeString(from: container, keys: [.channelType], fallback: payload["channel_type"]?.stringValue)
        channelSeq = Self.decodeInt64(from: container, keys: [.channelSeq, .seq])
        let authoritativeSenderUID = Self.decodeOptionalString(
            from: container,
            keys: [.fromUID, .senderUID, .senderUserID, .fromUserID]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSenderUID = [
            payload["from_uid"]?.stringValue,
            payload["sender_uid"]?.stringValue,
            payload["sender_user_id"]?.stringValue,
            payload["from_user_id"]?.stringValue
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let authoritativeSenderUID, !authoritativeSenderUID.isEmpty {
            fromUID = authoritativeSenderUID
            senderProvenance = .authoritativeStored
        } else {
            fromUID = fallbackSenderUID ?? ""
            senderProvenance = fallbackSenderUID == nil ? .unknown : .clientSupplied
        }
        senderDisplayName = Self.decodeOptionalString(
            from: container,
            keys: [.senderDisplayName, .senderName, .senderNickname, .fromName, .fromNickname, .displayName, .nickname]
        )
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["sender_display_name", "sender_name", "sender_nickname", "from_name", "from_nickname", "display_name", "nickname", "user_name"]
            )
            ?? ""
        senderAvatar = Self.decodeOptionalString(
            from: container,
            keys: [.senderAvatar, .senderAvatarURL, .fromAvatar, .avatar]
        )
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["sender_avatar", "sender_avatar_url", "from_avatar", "avatar", "avatar_url"]
            )
            ?? ""
        senderAvatarVersion = Self.decodeOptionalString(
            from: container,
            keys: [.senderAvatarVersion, .senderAvatarVersionCamel, .fromAvatarVersion, .avatarVersion, .avatarVersionCamel, .version]
        )
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["sender_avatar_version", "senderAvatarVersion", "from_avatar_version", "avatar_version", "avatarVersion", "version"]
            )
            ?? ""
        senderAvatarUpdatedAt = Self.decodeOptionalString(
            from: container,
            keys: [.senderAvatarUpdatedAt, .senderAvatarUpdatedAtCamel, .fromAvatarUpdatedAt, .avatarUpdatedAt, .avatarUpdatedAtCamel, .updatedAt]
        )
            ?? Self.decodeOptionalString(
                from: payload,
                keys: ["sender_avatar_updated_at", "senderAvatarUpdatedAt", "from_avatar_updated_at", "avatar_updated_at", "avatarUpdatedAt", "updated_at", "updatedAt"]
            )
            ?? ""
        contentType = Self.decodeString(from: container, keys: [.contentType], fallback: payload["content_type"]?.stringValue)
        quote = Self.decodeOptionalString(from: container, keys: [.quote, .quoteText, .quotedText, .replyQuote])
        status = Self.decodeString(from: container, keys: [.status])
        readStatus = Self.decodeOptionalString(from: container, keys: [.readStatus])
        readCount = try container.decodeIfPresent(Int.self, forKey: .readCount)
        readAt = Self.decodeOptionalString(from: container, keys: [.readAt])
        createdAt = Self.decodeOptionalString(from: container, keys: [.createdAt])
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isEdited = normalizedStatus == "edited"
            || Self.decodeOptionalBool(from: container, keys: [.isEdited, .edited]) == true
            || Self.decodeOptionalString(from: container, keys: [.editedAt, .editedAtCamel]) != nil
            || payload["is_edited"]?.boolValue == true
            || payload["edited"]?.boolValue == true
            || Self.hasNonEmptyString(in: payload, keys: ["edited_at", "editedAt"])
		let topLevelEditRevision = Self.decodeInt64(from: container, keys: [.editRevision, .editRevisionCamel])
		editRevision = topLevelEditRevision > 0
			? topLevelEditRevision
			: Int64(payload["edit_revision"]?.stringValue ?? payload["editRevision"]?.stringValue ?? "") ?? 0
    }

    private static func decodeString(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys], fallback: String? = nil) -> String {
        decodeOptionalString(from: container, keys: keys) ?? fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func decodeOptionalString(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    private static func decodeOptionalString(from payload: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func decodeOptionalBool(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Bool? {
        for key in keys {
            do {
                if let value = try container.decodeIfPresent(Bool.self, forKey: key) {
                    return value
                }
                if let value = try container.decodeIfPresent(Int.self, forKey: key) {
                    return value != 0
                }
                if let value = try container.decodeIfPresent(String.self, forKey: key) {
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if ["true", "1", "yes"].contains(normalized) { return true }
                    if ["false", "0", "no"].contains(normalized) { return false }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private static func hasNonEmptyString(in payload: [String: JSONValue], keys: [String]) -> Bool {
        decodeOptionalString(from: payload, keys: keys) != nil
    }

    private static func decodeInt64(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int64 {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Int64(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return 0
    }
}

struct RemoteReadAckResponse: Decodable {
    static let empty = RemoteReadAckResponse(
        channelID: "",
        channelType: "",
        lastReadSeq: 0,
        readReceipts: []
    )

    let channelID: String
    let channelType: String
    let lastReadSeq: Int64?
    let readReceipts: [RemoteMessageReceipt]

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
        case lastReadSeq = "last_read_seq"
        case readReceipts = "read_receipts"
    }

    init(channelID: String, channelType: String, lastReadSeq: Int64, readReceipts: [RemoteMessageReceipt]) {
        self.channelID = channelID
        self.channelType = channelType
        self.lastReadSeq = lastReadSeq
        self.readReceipts = readReceipts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        lastReadSeq = try c.decodeIfPresent(Int64.self, forKey: .lastReadSeq) ?? 0
        readReceipts = try c.decodeIfPresent([RemoteMessageReceipt].self, forKey: .readReceipts) ?? []
    }
}

struct RemoteMessageReadReceiptResponse: Decodable {
    let read: Bool
    let readCount: Int?
    let unreadCount: Int?
    let memberCount: Int?
    let targetCount: Int?
    let canViewDetails: Bool
    let readReceiptsEnabled: Bool?
    let featureStatus: String
    let featureMessage: String
    let items: [RemoteMessageReceipt]
    let unreadItems: [RemoteMessageReadParticipant]
    let reactions: [RemoteMessageReactionReceipt]

    var hasReceiptDetails: Bool {
        readCount != nil
            || unreadCount != nil
            || memberCount != nil
            || targetCount != nil
            || !items.isEmpty
            || !unreadItems.isEmpty
            || !reactions.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case read
        case readCount = "read_count"
        case unreadCount = "unread_count"
        case memberCount = "member_count"
        case targetCount = "receipt_target_count"
        case canViewDetails = "can_view_details"
        case readReceiptsEnabled = "read_receipts_enabled"
        case featureStatus = "feature_status"
        case featureMessage = "feature_message"
        case items
        case unreadItems = "unread_items"
        case reactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        read = try container.decodeIfPresent(Bool.self, forKey: .read) ?? false
        readCount = try container.decodeIfPresent(Int.self, forKey: .readCount)
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount)
        memberCount = try container.decodeIfPresent(Int.self, forKey: .memberCount)
        targetCount = try container.decodeIfPresent(Int.self, forKey: .targetCount)
        canViewDetails = try container.decodeIfPresent(Bool.self, forKey: .canViewDetails) ?? false
        readReceiptsEnabled = container.decodeLossyBoolIfPresent(forKey: .readReceiptsEnabled)
        featureStatus = try container.decodeIfPresent(String.self, forKey: .featureStatus) ?? ""
        featureMessage = try container.decodeIfPresent(String.self, forKey: .featureMessage) ?? ""
        items = try container.decodeIfPresent([RemoteMessageReceipt].self, forKey: .items) ?? []
        unreadItems = try container.decodeIfPresent([RemoteMessageReadParticipant].self, forKey: .unreadItems) ?? []
        reactions = try container.decodeIfPresent([RemoteMessageReactionReceipt].self, forKey: .reactions) ?? []
    }
}

struct RemoteMessageReadParticipant: Decodable {
    let imUID: String
    let displayName: String
    let nickname: String
    let remark: String
    let readAt: String?
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case displayName = "display_name"
        case nickname
        case remark
        case readAt = "read_at"
        case readAtCamel = "readAt"
        case deviceID = "device_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try container.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        remark = try container.decodeIfPresent(String.self, forKey: .remark) ?? ""
        readAt = container.decodeLossyStringIfPresent(forKey: .readAt)
            ?? container.decodeLossyStringIfPresent(forKey: .readAtCamel)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
    }
}

struct RemoteMessageReceipt: Decodable {
    let messageID: String
    let channelID: String
    let channelType: String
    let fromUID: String
    let imUID: String
    let deviceID: String
    let receiptType: String
    let channelSeq: Int64
    let createdAt: String?
    let displayName: String
    let nickname: String
    let remark: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case fromUID = "from_uid"
        case imUID = "im_uid"
        case deviceID = "device_id"
        case receiptType = "receipt_type"
        case channelSeq = "channel_seq"
        case createdAt = "created_at"
        case displayName = "display_name"
        case nickname
        case remark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try container.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        fromUID = try container.decodeIfPresent(String.self, forKey: .fromUID) ?? ""
        imUID = try container.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        receiptType = try container.decodeIfPresent(String.self, forKey: .receiptType) ?? ""
        channelSeq = try container.decodeIfPresent(Int64.self, forKey: .channelSeq) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        remark = try container.decodeIfPresent(String.self, forKey: .remark) ?? ""
    }
}

struct RemoteMessageReceiptSyncResult: Decodable {
    let items: [RemoteMessageReceipt]
    let readReceiptsEnabled: Bool?
    let featureStatus: String
    let readUpToSeq: Int64?
    let canViewReadReceiptDetails: Bool?

    enum CodingKeys: String, CodingKey {
        case items
        case readReceiptsEnabled = "read_receipts_enabled"
        case featureStatus = "feature_status"
        case readUpToSeq = "read_up_to_seq"
        case canViewReadReceiptDetails = "can_view_read_receipt_details"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([RemoteMessageReceipt].self, forKey: .items) ?? []
        readReceiptsEnabled = container.decodeLossyBoolIfPresent(forKey: .readReceiptsEnabled)
        featureStatus = try container.decodeIfPresent(String.self, forKey: .featureStatus) ?? ""
        // An absent/malformed scalar must not discard otherwise valid receipt items.
        let sequence = try? container.decode(Int64.self, forKey: .readUpToSeq)
        readUpToSeq = sequence.flatMap { $0 >= 0 ? $0 : nil }
        canViewReadReceiptDetails = container.decodeLossyBoolIfPresent(forKey: .canViewReadReceiptDetails)
    }
}

struct RemoteMessageReactionReceipt: Decodable {
    let tenantID: String
    let messageID: String
    let channelID: String
    let channelType: String
    let operatorUID: String
    let emoji: String
    let action: String
    let payload: [String: JSONValue]
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case messageID = "message_id"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case operatorUID = "operator_uid"
        case emoji
        case action
        case payload
        case createdAt = "created_at"
    }

    var operatorName: String {
        payload["nickname"]?.stringValue
            ?? payload["display_name"]?.stringValue
            ?? payload["operator_name"]?.stringValue
            ?? payload["actor_name"]?.stringValue
            ?? ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPayload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        payload = decodedPayload
        tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID)
            ?? decodedPayload["tenant_id"]?.stringValue
            ?? ""
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
            ?? decodedPayload["message_id"]?.stringValue
            ?? decodedPayload["msg_id"]?.stringValue
            ?? ""
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID)
            ?? decodedPayload["channel_id"]?.stringValue
            ?? ""
        channelType = try container.decodeIfPresent(String.self, forKey: .channelType)
            ?? decodedPayload["channel_type"]?.stringValue
            ?? ""
        operatorUID = try container.decodeIfPresent(String.self, forKey: .operatorUID)
            ?? decodedPayload["operator_uid"]?.stringValue
            ?? decodedPayload["actor_uid"]?.stringValue
            ?? decodedPayload["from_uid"]?.stringValue
            ?? decodedPayload["sender_uid"]?.stringValue
            ?? decodedPayload["user_id"]?.stringValue
            ?? ""
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
            ?? decodedPayload["emoji"]?.stringValue
            ?? decodedPayload["reaction"]?.stringValue
            ?? ""
        action = try container.decodeIfPresent(String.self, forKey: .action)
            ?? decodedPayload["action"]?.stringValue
            ?? "add"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? decodedPayload["created_at"]?.stringValue
            ?? decodedPayload["createdAt"]?.stringValue
            ?? decodedPayload["updated_at"]?.stringValue
            ?? decodedPayload["updatedAt"]?.stringValue
    }
}

struct RemoteMessageSearchResponse: Decodable {
    let items: [RemoteMessageSearchResult]
    let hasMore: Bool
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextOffset = "next_offset"
    }
}

struct RemoteMessageSearchResult: Decodable {
    let message: RemoteMessage
    let matchText: String?

    enum CodingKeys: String, CodingKey {
        case message
        case matchText = "match_text"
    }
}

struct RemoteTenantSearchResponse: Decodable, Sendable {
    let query: String
    let scope: String
    let types: [String]
    let limit: Int
    let searchID: String?
    let requestID: String?
    let elapsedMS: Int?
    let resultsByType: [String: RemoteTenantSearchBucket]
    let items: [RemoteTenantSearchResult]
    let compatibility: [String: JSONValue]
    let analytics: [String: JSONValue]
    let parsedFilters: [RemoteTenantSearchParsedFilter]
    let conversationSearch: RemoteTenantConversationSearch?
    let conversationDateAnchor: RemoteTenantConversationDateAnchor?

    enum CodingKeys: String, CodingKey {
        case query
        case scope
        case types
        case limit
        case searchID = "search_id"
        case searchIDCamel = "searchId"
        case requestID = "request_id"
        case requestIDCamel = "requestId"
        case elapsedMS = "elapsed_ms"
        case elapsedMSCamel = "elapsedMs"
        case resultsByType = "results_by_type"
        case resultsByTypeCamel = "resultsByType"
        case items
        case compatibility
        case analytics
        case parsedFilters = "parsed_filters"
        case parsedFiltersCamel = "parsedFilters"
        case conversationSearch = "conversation_search"
        case conversationSearchCamel = "conversationSearch"
        case conversationDateAnchor = "conversation_date_anchor"
        case conversationDateAnchorCamel = "conversationDateAnchor"
    }

    init(
        query: String = "",
        scope: String = "",
        types: [String] = [],
        limit: Int = 0,
        searchID: String? = nil,
        requestID: String? = nil,
        elapsedMS: Int? = nil,
        resultsByType: [String: RemoteTenantSearchBucket] = [:],
        items: [RemoteTenantSearchResult] = [],
        compatibility: [String: JSONValue] = [:],
        analytics: [String: JSONValue] = [:],
        parsedFilters: [RemoteTenantSearchParsedFilter] = [],
        conversationSearch: RemoteTenantConversationSearch? = nil,
        conversationDateAnchor: RemoteTenantConversationDateAnchor? = nil
    ) {
        self.query = query
        self.scope = scope
        self.types = types
        self.limit = limit
        self.searchID = searchID
        self.requestID = requestID
        self.elapsedMS = elapsedMS
        self.resultsByType = resultsByType
        self.items = items
        self.compatibility = compatibility
        self.analytics = analytics
        self.parsedFilters = parsedFilters
        self.conversationSearch = conversationSearch
        self.conversationDateAnchor = conversationDateAnchor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        limit = c.decodeLossyIntIfPresent(forKey: .limit) ?? 0
        searchID = try c.decodeIfPresent(String.self, forKey: .searchID)
            ?? c.decodeIfPresent(String.self, forKey: .searchIDCamel)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
            ?? c.decodeIfPresent(String.self, forKey: .requestIDCamel)
        elapsedMS = c.decodeLossyIntIfPresent(forKey: .elapsedMS)
            ?? c.decodeLossyIntIfPresent(forKey: .elapsedMSCamel)
        resultsByType = Self.decodeResultsByType(from: decoder)
        items = try c.decodeIfPresent([RemoteTenantSearchResult].self, forKey: .items) ?? []
        compatibility = try c.decodeIfPresent([String: JSONValue].self, forKey: .compatibility) ?? [:]
        analytics = try c.decodeIfPresent([String: JSONValue].self, forKey: .analytics) ?? [:]
        parsedFilters = try c.decodeIfPresent([RemoteTenantSearchParsedFilter].self, forKey: .parsedFilters)
            ?? c.decodeIfPresent([RemoteTenantSearchParsedFilter].self, forKey: .parsedFiltersCamel)
            ?? []
        conversationSearch = try c.decodeIfPresent(RemoteTenantConversationSearch.self, forKey: .conversationSearch)
            ?? c.decodeIfPresent(RemoteTenantConversationSearch.self, forKey: .conversationSearchCamel)
        conversationDateAnchor = try c.decodeIfPresent(RemoteTenantConversationDateAnchor.self, forKey: .conversationDateAnchor)
            ?? c.decodeIfPresent(RemoteTenantConversationDateAnchor.self, forKey: .conversationDateAnchorCamel)
    }

    private static func decodeResultsByType(from decoder: Decoder) -> [String: RemoteTenantSearchBucket] {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return [:] }
        if let value = try? c.decode(RemoteTenantSearchResultsByType.self, forKey: .resultsByType) {
            return value.buckets
        }
        if let value = try? c.decode(RemoteTenantSearchResultsByType.self, forKey: .resultsByTypeCamel) {
            return value.buckets
        }
        return [:]
    }
}

struct RemoteTenantSearchBucket: Decodable, Sendable {
    let items: [RemoteTenantSearchResult]
    let count: Int
    let hasMore: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case count
        case hasMore = "has_more"
        case hasMoreCamel = "hasMore"
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
    }

    init(items: [RemoteTenantSearchResult], count: Int? = nil, hasMore: Bool = false, nextCursor: String? = nil) {
        self.items = items
        self.count = count ?? items.count
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        if let legacyItems = try? [RemoteTenantSearchResult](from: decoder) {
            items = legacyItems
            count = legacyItems.count
            hasMore = false
            nextCursor = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteTenantSearchResult].self, forKey: .items) ?? []
        count = c.decodeLossyIntIfPresent(forKey: .count) ?? items.count
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreCamel)
            ?? false
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .nextCursorCamel)
    }
}

private struct RemoteTenantSearchResultsByType: Decodable {
    let buckets: [String: RemoteTenantSearchBucket]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RemoteTenantSearchDynamicCodingKey.self)
        var decoded: [String: RemoteTenantSearchBucket] = [:]
        for key in c.allKeys {
            if let bucket = try? c.decode(RemoteTenantSearchBucket.self, forKey: key) {
                decoded[key.stringValue] = bucket
            }
        }
        buckets = decoded
    }
}

private struct RemoteTenantSearchDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct RemoteTenantSearchResult: Decodable, Identifiable, Sendable {
    let resultID: String
    let type: String
    let title: String
    let subtitle: String?
    let snippet: String?
    let highlightRanges: [RemoteTenantSearchHighlightRange]
    let rank: Double?
    let sort: [String: JSONValue]
    let jumpTarget: RemoteTenantSearchJumpTarget?
    let sourceName: String?
    let source: [String: JSONValue]

    var id: String {
        "\(type):\(resultID)"
    }

    enum CodingKeys: String, CodingKey {
        case resultID = "result_id"
        case resultIDCamel = "resultId"
        case type
        case title
        case subtitle
        case snippet
        case highlightRanges = "highlight_ranges"
        case highlightRangesCamel = "highlightRanges"
        case rank
        case sort
        case jumpTarget = "jump_target"
        case jumpTargetCamel = "jumpTarget"
        case source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resultID = try c.decodeIfPresent(String.self, forKey: .resultID)
            ?? c.decodeIfPresent(String.self, forKey: .resultIDCamel)
            ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
        highlightRanges = try c.decodeIfPresent([RemoteTenantSearchHighlightRange].self, forKey: .highlightRanges)
            ?? c.decodeIfPresent([RemoteTenantSearchHighlightRange].self, forKey: .highlightRangesCamel)
            ?? []
        rank = c.decodeLossyDoubleIfPresent(forKey: .rank)
        sort = try c.decodeIfPresent([String: JSONValue].self, forKey: .sort) ?? [:]
        jumpTarget = try c.decodeIfPresent(RemoteTenantSearchJumpTarget.self, forKey: .jumpTarget)
            ?? c.decodeIfPresent(RemoteTenantSearchJumpTarget.self, forKey: .jumpTargetCamel)
        let decodedSource = try c.decodeIfPresent(JSONValue.self, forKey: .source)
        switch decodedSource {
        case .object(let object)?:
            source = object
            sourceName = object["name"]?.stringValue
                ?? object["source"]?.stringValue
                ?? object["type"]?.stringValue
        case .string(let name)?:
            sourceName = name
            source = ["name": .string(name)]
        default:
            sourceName = nil
            source = [:]
        }
    }
}

extension RemoteTenantSearchResult {
    var displayModel: TenantSearchResultDisplayModel {
        TenantSearchResultDisplayModel(item: self)
    }

    var isBlockedFromChatSearchDisplay: Bool {
        TenantSearchResultGuard.isBlockedFromChatSearchDisplay(self)
    }

    func matchesSearchInvalidation(_ invalidation: SearchInvalidationEvent) -> Bool {
        guard !invalidation.isTenantScopeReset else { return true }
        let target = jumpTarget
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedKind = target?.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let fileID = invalidation.normalizedFileID {
            let resultFileID = target?.fileID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackFileID = resultID.hasPrefix("file:") ? String(resultID.dropFirst(5)) : resultID
            if resultFileID == fileID || fallbackFileID.trimmingCharacters(in: .whitespacesAndNewlines) == fileID {
                return true
            }
        }
        if let messageID = invalidation.normalizedMessageID {
            if target?.messageID?.trimmingCharacters(in: .whitespacesAndNewlines) == messageID {
                return true
            }
            if normalizedType == "messages" || normalizedKind == "message" || normalizedKind == "message_file" {
                if resultID.trimmingCharacters(in: .whitespacesAndNewlines) == messageID {
                    return true
                }
            }
        }
        if let channelID = invalidation.normalizedChannelID {
            let targetChannelID = target?.channelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let channelMatches = targetChannelID == channelID
            let typeMatches = invalidation.normalizedChannelType == nil
                || invalidation.normalizedChannelType == target?.channelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if channelMatches && typeMatches {
                if invalidation.isConversationRemoval {
                    return true
                }
                if let channelSeq = invalidation.channelSeq, channelSeq > 0 {
                    return target?.channelSeq == channelSeq
                }
            }
        }
        return false
    }
}

struct TenantSearchResultDisplayModel: Equatable, Sendable {
    let primaryText: String
    let primaryField: String
    let secondaryText: String?
    let secondaryField: String

    private struct DisplayCandidate {
        let text: String
        let field: String
    }

    init(item: RemoteTenantSearchResult) {
        let normalizedType = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = Self.trimmed(item.title)
        let snippet = Self.trimmed(item.snippet)
        let subtitle = Self.trimmed(item.subtitle)
        let fallback = Self.fallbackTitle(for: normalizedType)
        if normalizedType == "message" || normalizedType == "messages" {
            let primary = snippet ?? title ?? fallback
            primaryText = primary
            primaryField = snippet == nil && title != nil ? "title" : "snippet"
            let candidate = Self.firstDistinctCandidate(from: [
                Self.friendlySourceCandidate(for: item),
                Self.candidate(subtitle, field: "subtitle"),
                Self.candidate(title, field: "title")
            ], primary: primary)
            secondaryText = candidate?.text
            secondaryField = candidate?.field ?? "subtitle"
        } else if normalizedType == "file" || normalizedType == "files" {
            let primary = title ?? snippet ?? fallback
            primaryText = primary
            primaryField = title == nil && snippet != nil ? "snippet" : "title"
            let candidate = Self.firstDistinctCandidate(from: [
                Self.friendlySourceCandidate(for: item),
                Self.candidate(subtitle, field: "subtitle"),
                Self.candidate(snippet, field: "snippet")
            ], primary: primary)
            secondaryText = candidate?.text
            secondaryField = candidate?.field ?? "subtitle"
        } else {
            let primary = title ?? snippet ?? fallback
            primaryText = primary
            primaryField = title == nil && snippet != nil ? "snippet" : "title"
            let candidate = Self.firstDistinctCandidate(from: [
                Self.candidate(subtitle, field: "subtitle"),
                Self.candidate(snippet, field: "snippet")
            ], primary: primary)
            secondaryText = candidate?.text
            secondaryField = candidate?.field ?? "subtitle"
        }
    }

    static func normalizedComparableText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstDistinctCandidate(from candidates: [DisplayCandidate?], primary: String) -> DisplayCandidate? {
        let normalizedPrimary = normalizedComparableText(primary)
        for candidate in candidates {
            guard let candidate else { continue }
            let normalized = normalizedComparableText(candidate.text)
            if !normalized.isEmpty && normalized != normalizedPrimary {
                return candidate
            }
        }
        return nil
    }

    private static func candidate(_ value: String?, field: String) -> DisplayCandidate? {
        guard let text = userFriendlyText(value) else { return nil }
        return DisplayCandidate(text: text, field: field)
    }

    private static func userFriendlyText(_ value: String?) -> String? {
        guard let text = trimmed(value), !isTechnicalSourceText(text) else { return nil }
        return text
    }

    private static func friendlySourceCandidate(for item: RemoteTenantSearchResult) -> DisplayCandidate? {
        guard let text = friendlySourceText(for: item) else { return nil }
        return DisplayCandidate(text: text, field: "subtitle")
    }

    private static func friendlySourceText(for item: RemoteTenantSearchResult) -> String? {
        let source = item.source
        let conversation = firstFriendlySourceValue(source, keys: [
            "conversation_title", "conversationTitle",
            "conversation_name", "conversationName",
            "channel_title", "channelTitle",
            "channel_name", "channelName",
            "group_name", "groupName",
            "source_label", "sourceLabel",
            "label"
        ]) ?? channelTypeFallback(item.jumpTarget?.channelType)
        let actor = firstFriendlySourceValue(source, keys: [
            "sender_display_name", "senderDisplayName",
            "sender_name", "senderName",
            "from_name", "fromName",
            "uploader_name", "uploaderName",
            "owner_name", "ownerName",
            "display_name", "displayName",
            "nickname"
        ])
        let time = firstFriendlySourceValue(source, keys: [
            "display_time", "displayTime",
            "time"
        ])
        let components = [conversation, actor, time].compactMap { userFriendlyText($0) }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private static func firstFriendlySourceValue(_ source: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let text = userFriendlyText(source[key]?.stringValue) {
                return text
            }
        }
        return nil
    }

    private static func channelTypeFallback(_ channelType: String?) -> String? {
        switch channelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "group": return "群聊"
        case "direct": return "单聊"
        case "system": return "系统消息"
        default: return nil
        }
    }

    private static func isTechnicalSourceText(_ value: String) -> Bool {
        let normalized = normalizedComparableText(value)
        if normalized.range(of: #"^(group|direct|system|channel|conversation)\s*#\s*\S+$"#, options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: #"^(group|direct|system|channel|conversation)[_-][a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: #"^(uid|im_uid|user|account)[\s:#_-]*[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func fallbackTitle(for type: String) -> String {
        switch type {
        case "contact", "contacts": return "联系人"
        case "group", "groups": return "群聊"
        case "conversation", "conversations": return "会话"
        case "message", "messages": return "聊天记录"
        case "file", "files": return "文件"
        default: return "搜索结果"
        }
    }
}

enum TenantSearchResultGuard {
    static func isBlockedFromChatSearchDisplay(_ item: RemoteTenantSearchResult) -> Bool {
        let normalizedType = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "message" || normalizedType == "messages" else { return false }
        let blockedTokens: Set<String> = [
            "sensitive_hit",
            "blocked_by_sensitive_word",
            "sensitive_blocked",
            "risk_notice",
            "sensitive_notice",
            "friend_sensitive_notice"
        ]
        if blockedTokens.contains(item.jumpTarget?.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") {
            return true
        }
        if stringValues(in: item.source).contains(where: { blockedTokens.contains($0) }) {
            return true
        }
        let boolKeys = ["sensitive_hit", "blocked_by_sensitive_word", "sensitive_blocked", "risk_notice", "sensitive_notice"]
        if boolKeys.contains(where: { item.source[$0]?.boolValue == true }) {
            return true
        }
        let kind = normalizedSourceString(item.source["kind"])
            ?? normalizedSourceString(item.source["message_kind"])
            ?? normalizedSourceString(item.source["event_type"])
        if let kind, blockedTokens.contains(kind) {
            return true
        }
        let contentType = normalizedSourceString(item.source["content_type"])
            ?? normalizedSourceString(item.source["contentType"])
        return contentType == "system"
    }

    private static func normalizedSourceString(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private static func stringValues(in value: JSONValue) -> [String] {
        switch value {
        case .string(let value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? [] : [normalized]
        case .object(let object):
            return stringValues(in: object)
        case .array(let values):
            return values.flatMap(stringValues)
        default:
            return []
        }
    }

    private static func stringValues(in object: [String: JSONValue]) -> [String] {
        object.flatMap { entry in
            let normalizedKey = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return [normalizedKey] + stringValues(in: entry.value)
        }
    }
}

struct RemoteTenantSearchParsedFilter: Decodable, Identifiable, Equatable, Sendable {
    let type: String
    let key: String
    let operatorName: String?
    let value: String
    let label: String?
    let raw: String?

    var id: String {
        [type, key, operatorName ?? "", value, raw ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ":")
    }

    var displayTitle: String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return normalizedValue }
        guard !normalizedValue.isEmpty else { return normalizedKey }
        return "\(normalizedKey): \(normalizedValue)"
    }

    enum CodingKeys: String, CodingKey {
        case type
        case kind
        case key
        case field
        case operatorName = "operator"
        case operatorCamel = "operatorName"
        case op
        case value
        case label
        case raw
        case token
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
            ?? c.decodeIfPresent(String.self, forKey: .kind)
            ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key)
            ?? c.decodeIfPresent(String.self, forKey: .field)
            ?? type
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
            ?? c.decodeIfPresent(String.self, forKey: .operatorCamel)
            ?? c.decodeIfPresent(String.self, forKey: .op)
        let decodedValue = try? c.decodeIfPresent(JSONValue.self, forKey: .value)
        value = (try? c.decodeIfPresent(String.self, forKey: .value))
            ?? decodedValue?.stringValue
            ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
            ?? c.decodeIfPresent(String.self, forKey: .token)
    }
}

struct RemoteTenantSearchHighlightRange: Decodable, Equatable, Sendable {
    let field: String
    let start: Int
    let length: Int

    enum CodingKeys: String, CodingKey {
        case field
        case start
        case length
    }

    init(field: String, start: Int, length: Int) {
        self.field = field
        self.start = start
        self.length = length
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decodeIfPresent(String.self, forKey: .field) ?? ""
        start = c.decodeLossyIntIfPresent(forKey: .start) ?? 0
        length = c.decodeLossyIntIfPresent(forKey: .length) ?? 0
    }
}

struct RemoteTenantSearchJumpTarget: Decodable, Equatable, Sendable {
    let kind: String
    let channelID: String?
    let channelType: String?
    let channelSeq: Int64?
    let messageID: String?
    let fileID: String?
    let detailEndpoint: String?
    let imUID: String?
    let userID: String?
    let peerIMUID: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case messageID = "message_id"
        case messageIDCamel = "messageId"
        case fileID = "file_id"
        case fileIDCamel = "fileId"
        case detailEndpoint = "detail_endpoint"
        case detailEndpointCamel = "detailEndpoint"
        case imUID = "im_uid"
        case imUIDCamel = "imUID"
        case userID = "user_id"
        case userIDCamel = "userId"
        case peerIMUID = "peer_im_uid"
        case peerIMUIDCamel = "peerIMUID"
    }

    init(
        kind: String,
        channelID: String? = nil,
        channelType: String? = nil,
        channelSeq: Int64? = nil,
        messageID: String? = nil,
        fileID: String? = nil,
        detailEndpoint: String? = nil,
        imUID: String? = nil,
        userID: String? = nil,
        peerIMUID: String? = nil
    ) {
        self.kind = kind
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.messageID = messageID
        self.fileID = fileID
        self.detailEndpoint = detailEndpoint
        self.imUID = imUID
        self.userID = userID
        self.peerIMUID = peerIMUID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
            ?? c.decodeIfPresent(String.self, forKey: .channelIDCamel)
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType)
            ?? c.decodeIfPresent(String.self, forKey: .channelTypeCamel)
        channelSeq = c.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
            ?? c.decodeIfPresent(String.self, forKey: .messageIDCamel)
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID)
            ?? c.decodeIfPresent(String.self, forKey: .fileIDCamel)
        detailEndpoint = try c.decodeIfPresent(String.self, forKey: .detailEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .detailEndpointCamel)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .imUIDCamel)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
            ?? c.decodeIfPresent(String.self, forKey: .userIDCamel)
        peerIMUID = try c.decodeIfPresent(String.self, forKey: .peerIMUID)
            ?? c.decodeIfPresent(String.self, forKey: .peerIMUIDCamel)
    }
}

struct SearchInvalidationEvent: Decodable, Sendable, Equatable {
    let tenantID: String
    let invalidationKey: String
    let eventType: String
    let reason: String
    let channelID: String?
    let channelType: String?
    let channelSeq: Int64?
    let messageID: String?
    let fileID: String?
    let version: Int64
    let updatedAt: String?
    let clientAction: String?
    let isTenantScopeReset: Bool

    var normalizedTenantID: String? {
        let value = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedChannelID: String? {
        let value = channelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var normalizedChannelType: String? {
        let value = channelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? nil : value
    }

    var normalizedMessageID: String? {
        let value = messageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var normalizedFileID: String? {
        let value = fileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var isConversationRemoval: Bool {
        let normalizedEvent = eventType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAction = clientAction?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedEvent.contains("removed_conversation")
            || normalizedEvent.contains("conversation_removed")
            || normalizedEvent.contains("permission_lost")
            || normalizedAction.contains("remove_conversation")
            || normalizedReason.contains("removed_conversation")
            || normalizedReason.contains("permission_lost")
    }

    var dedupeKey: String {
        let explicit = invalidationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return [tenantID, explicit].filter { !$0.isEmpty }.joined(separator: "|")
        }
        return [
            tenantID,
            eventType,
            channelType ?? "",
            channelID ?? "",
            channelSeq.map(String.init) ?? "",
            messageID ?? "",
            fileID ?? ""
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case invalidationKey = "invalidation_key"
        case invalidationKeyCamel = "invalidationKey"
        case eventType = "event_type"
        case eventTypeCamel = "eventType"
        case searchInvalidationType = "search_invalidation_type"
        case searchInvalidationAction = "search_invalidation_action"
        case reason
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case messageID = "message_id"
        case messageIDCamel = "messageId"
        case fileID = "file_id"
        case fileIDCamel = "fileId"
        case version
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
        case clientAction = "client_action"
        case clientActionCamel = "clientAction"
        case searchInvalidationActionCamel = "searchInvalidationAction"
        case reset
        case clear
    }

    init(
        tenantID: String = "",
        invalidationKey: String = "",
        eventType: String = "",
        reason: String = "",
        channelID: String? = nil,
        channelType: String? = nil,
        channelSeq: Int64? = nil,
        messageID: String? = nil,
        fileID: String? = nil,
        version: Int64 = 0,
        updatedAt: String? = nil,
        clientAction: String? = nil,
        isTenantScopeReset: Bool = false
    ) {
        self.tenantID = tenantID
        self.invalidationKey = invalidationKey
        self.eventType = eventType
        self.reason = reason
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.messageID = messageID
        self.fileID = fileID
        self.version = version
        self.updatedAt = updatedAt
        self.clientAction = clientAction
        self.isTenantScopeReset = isTenantScopeReset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        let eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
            ?? c.decodeIfPresent(String.self, forKey: .eventTypeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .searchInvalidationType)
            ?? ""
        let clientAction = try c.decodeIfPresent(String.self, forKey: .clientAction)
            ?? c.decodeIfPresent(String.self, forKey: .clientActionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .searchInvalidationAction)
            ?? c.decodeIfPresent(String.self, forKey: .searchInvalidationActionCamel)
        self.init(
            tenantID: tenantID,
            invalidationKey: try c.decodeIfPresent(String.self, forKey: .invalidationKey)
                ?? c.decodeIfPresent(String.self, forKey: .invalidationKeyCamel)
                ?? "",
            eventType: eventType,
            reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "",
            channelID: try c.decodeIfPresent(String.self, forKey: .channelID)
                ?? c.decodeIfPresent(String.self, forKey: .channelIDCamel),
            channelType: try c.decodeIfPresent(String.self, forKey: .channelType)
                ?? c.decodeIfPresent(String.self, forKey: .channelTypeCamel),
            channelSeq: c.decodeLossyInt64IfPresent(forKey: .channelSeq)
                ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel),
            messageID: try c.decodeIfPresent(String.self, forKey: .messageID)
                ?? c.decodeIfPresent(String.self, forKey: .messageIDCamel),
            fileID: try c.decodeIfPresent(String.self, forKey: .fileID)
                ?? c.decodeIfPresent(String.self, forKey: .fileIDCamel),
            version: c.decodeLossyInt64IfPresent(forKey: .version) ?? 0,
            updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt)
                ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel),
            clientAction: clientAction,
            isTenantScopeReset: c.decodeLossyBoolIfPresent(forKey: .reset) == true
                || c.decodeLossyBoolIfPresent(forKey: .clear) == true
        )
    }

    init?(
        payload: [String: JSONValue],
        fallbackTenantID: String = "",
        fallbackChannelID: String? = nil,
        fallbackChannelType: String? = nil,
        fallbackChannelSeq: Int64? = nil,
        fallbackMessageID: String? = nil,
        fallbackUpdatedAt: String? = nil
    ) {
        let searchInvalidation = payload["search_invalidation"]?.boolValue ?? false
        let eventType = Self.firstString(payload, keys: ["event_type", "eventType", "search_invalidation_type", "searchInvalidationType"])
        let action = Self.firstString(payload, keys: ["client_action", "clientAction", "search_invalidation_action", "searchInvalidationAction"])
        let hasCompatibilityMarker = Self.firstString(payload, keys: ["search_invalidation_type", "searchInvalidationType", "search_invalidation_action", "searchInvalidationAction"]) != nil
        guard searchInvalidation || hasCompatibilityMarker else { return nil }
        self.init(
            tenantID: Self.firstString(payload, keys: ["tenant_id", "tenantId"]) ?? fallbackTenantID,
            invalidationKey: Self.firstString(payload, keys: ["invalidation_key", "invalidationKey"]) ?? "",
            eventType: eventType ?? "",
            reason: Self.firstString(payload, keys: ["reason"]) ?? "",
            channelID: Self.firstString(payload, keys: ["channel_id", "channelId"]) ?? fallbackChannelID,
            channelType: Self.firstString(payload, keys: ["channel_type", "channelType"]) ?? fallbackChannelType,
            channelSeq: Self.firstInt64(payload, keys: ["channel_seq", "channelSeq"]) ?? fallbackChannelSeq,
            messageID: Self.firstString(payload, keys: ["message_id", "messageId", "msg_id", "msgId"]) ?? fallbackMessageID,
            fileID: Self.firstString(payload, keys: ["file_id", "fileId"]),
            version: Self.firstInt64(payload, keys: ["version"]) ?? 0,
            updatedAt: Self.firstString(payload, keys: ["updated_at", "updatedAt"]) ?? fallbackUpdatedAt,
            clientAction: action,
            isTenantScopeReset: payload["reset"]?.boolValue == true || payload["clear"]?.boolValue == true
        )
    }

    init(removedConversation: RemoteRemovedConversation, fallbackTenantID: String = "") {
        self.init(
            tenantID: removedConversation.tenantID.isEmpty ? fallbackTenantID : removedConversation.tenantID,
            invalidationKey: [
                "removed_conversation",
                removedConversation.channelType,
                removedConversation.channelID
            ].filter { !$0.isEmpty }.joined(separator: ":"),
            eventType: "removed_conversation",
            reason: removedConversation.reason,
            channelID: removedConversation.channelID,
            channelType: removedConversation.channelType,
            version: removedConversation.version,
            updatedAt: removedConversation.updatedAt,
            clientAction: "remove_conversation"
        )
    }

    static func tenantScopeReset(tenantID: String = "", reason: String) -> SearchInvalidationEvent {
        SearchInvalidationEvent(
            tenantID: tenantID,
            invalidationKey: "tenant_scope_reset:\(reason)",
            eventType: "tenant_scope_reset",
            reason: reason,
            clientAction: "clear_search_state",
            isTenantScopeReset: true
        )
    }

    private static func firstString(_ payload: [String: JSONValue], keys: [String]) -> String? {
        keys.compactMap { payload[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func firstInt64(_ payload: [String: JSONValue], keys: [String]) -> Int64? {
        for key in keys {
            guard let value = payload[key] else { continue }
            switch value {
            case .int(let raw):
                return Int64(raw)
            case .double(let raw):
                return Int64(raw)
            case .string(let raw):
                if let parsed = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            default:
                continue
            }
        }
        return nil
    }
}

struct RemoteSearchInvalidationResponse: Decodable, Sendable {
    let searchInvalidations: [SearchInvalidationEvent]

    enum CodingKeys: String, CodingKey {
        case searchInvalidations = "search_invalidations"
        case searchInvalidationsCamel = "searchInvalidations"
    }

    init(searchInvalidations: [SearchInvalidationEvent] = []) {
        self.searchInvalidations = searchInvalidations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchInvalidations = try c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidations)
            ?? c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidationsCamel)
            ?? []
    }
}

struct RemoteTenantConversationSearch: Decodable, Sendable {
    let hitChannelSeqs: [Int64]
    let total: Int
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case hitChannelSeqs = "hit_channel_seqs"
        case hitChannelSeqsCamel = "hitChannelSeqs"
        case total
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hitChannelSeqs = try c.decodeIfPresent([Int64].self, forKey: .hitChannelSeqs)
            ?? c.decodeIfPresent([Int64].self, forKey: .hitChannelSeqsCamel)
            ?? []
        total = c.decodeLossyIntIfPresent(forKey: .total) ?? hitChannelSeqs.count
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .nextCursorCamel)
    }
}

struct TenantConversationSearchPaginationState: Equatable, Sendable {
    let typeCursors: [String: String]
    let hitChannelSeqs: [Int64]
    let total: Int

    var hasMore: Bool {
        !typeCursors.isEmpty
    }

    init(response: RemoteTenantSearchResponse, items: [RemoteTenantSearchResult]) {
        let messageCursor = Self.nonEmpty(response.resultsByType["messages"]?.nextCursor)
            ?? Self.nonEmpty(response.conversationSearch?.nextCursor)
        let fileCursor = Self.nonEmpty(response.resultsByType["files"]?.nextCursor)
        var cursors: [String: String] = [:]
        if let messageCursor {
            cursors["messages"] = messageCursor
        }
        if let fileCursor {
            cursors["files"] = fileCursor
        }
        typeCursors = cursors

        let responseSeqs = response.conversationSearch?.hitChannelSeqs ?? []
        hitChannelSeqs = Self.uniqueSeqs(responseSeqs + items.compactMap { $0.jumpTarget?.channelSeq })

        let bucketTotal = ["messages", "files"].reduce(0) { total, type in
            total + (response.resultsByType[type]?.count ?? 0)
        }
        total = max(response.conversationSearch?.total ?? 0, bucketTotal, items.count)
    }

    func genericCursor(for types: [String]) -> String? {
        let normalized = types
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard normalized.count == 1 else { return nil }
        return typeCursors[normalized[0]]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func uniqueSeqs(_ values: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        var result: [Int64] = []
        for value in values where value > 0 && seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

struct RemoteTenantConversationDateAnchor: Decodable, Equatable, Sendable {
    let date: String?
    let status: String
    let channelSeq: Int64?
    let messageID: String?
    let nearestChannelSeq: Int64?
    let nearestMessageID: String?
    let direction: String?

    enum CodingKeys: String, CodingKey {
        case date
        case status
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case messageID = "message_id"
        case messageIDCamel = "messageId"
        case nearestChannelSeq = "nearest_channel_seq"
        case nearestChannelSeqCamel = "nearestChannelSeq"
        case nearestMessageID = "nearest_message_id"
        case nearestMessageIDCamel = "nearestMessageId"
        case direction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        channelSeq = c.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
            ?? c.decodeIfPresent(String.self, forKey: .messageIDCamel)
        nearestChannelSeq = c.decodeLossyInt64IfPresent(forKey: .nearestChannelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .nearestChannelSeqCamel)
        nearestMessageID = try c.decodeIfPresent(String.self, forKey: .nearestMessageID)
            ?? c.decodeIfPresent(String.self, forKey: .nearestMessageIDCamel)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
    }

    var bestJumpTarget: RemoteTenantSearchJumpTarget? {
        let seq = channelSeq ?? nearestChannelSeq
        let message = messageID ?? nearestMessageID
        guard seq != nil || message != nil else { return nil }
        return RemoteTenantSearchJumpTarget(
            kind: "message",
            channelID: nil,
            channelType: nil,
            channelSeq: seq,
            messageID: message,
            fileID: nil,
            detailEndpoint: nil,
            imUID: nil,
            userID: nil,
            peerIMUID: nil
        )
    }
}

struct TenantSearchAnalyticsEvent: Sendable {
    let searchID: String?
    let requestID: String?
    let eventType: String
    let scope: String
    let types: [String]
    let resultType: String?
    let resultID: String?
    let resultRank: Double?
    let queryLength: Int
    let elapsedMS: Int?
    let filters: [String: String]

    var body: [String: Any] {
        var payload: [String: Any] = [
            "event_type": eventType,
            "scope": scope,
            "types": types,
            "query_length": max(queryLength, 0),
            "filters": filters
        ]
        if let searchID, !searchID.isEmpty { payload["search_id"] = searchID }
        if let requestID, !requestID.isEmpty { payload["request_id"] = requestID }
        if let resultType, !resultType.isEmpty { payload["result_type"] = resultType }
        if let resultID, !resultID.isEmpty { payload["result_id"] = resultID }
        if let resultRank { payload["result_rank"] = resultRank }
        if let elapsedMS { payload["elapsed_ms"] = elapsedMS }
        return payload
    }
}

struct RemoteSendResponse: Decodable {
    let message: RemoteMessage
}

struct RemotePasswordResetResponse: Decodable, Equatable, Sendable {
    let reset: Bool
}

struct RemoteForwardMessageResponse: Decodable {
    let message: RemoteMessage

    enum CodingKeys: String, CodingKey {
        case message
        case item
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            if let message = try container.decodeIfPresent(RemoteMessage.self, forKey: .message) {
                self.message = message
                return
            }
            if let item = try container.decodeIfPresent(RemoteMessage.self, forKey: .item) {
                self.message = item
                return
            }
        }
        self.message = try RemoteMessage(from: decoder)
    }
}

struct RemoteTenantFileForwardResponse: Decodable {
    let message: RemoteMessage

    private struct NestedMessage: Decodable {
        let message: RemoteMessage
    }

    private enum CodingKeys: String, CodingKey {
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.decode(NestedMessage.self, forKey: .message),
           !nested.message.messageID.isEmpty {
            message = nested.message
            return
        }
        let direct = try container.decode(RemoteMessage.self, forKey: .message)
        guard !direct.messageID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .message,
                in: container,
                debugDescription: "Forward response message_id is required"
            )
        }
        message = direct
    }
}

struct RemoteConversationSettingsResponse: Decodable {
    let conversation: RemoteConversation?
}

struct RemoteExtraResponse: Decodable {
    let extra: RemoteMessageExtra?
	let message: RemoteMessage?
	let duplicate: Bool
    let readReceipts: [RemoteMessageReceipt]

    enum CodingKeys: String, CodingKey {
        case extra
        case messageExtra = "message_extra"
		case message
		case currentMessage = "current_message"
		case duplicate
        case readReceipts = "read_receipts"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extra = try container.decodeIfPresent(RemoteMessageExtra.self, forKey: .extra)
            ?? container.decodeIfPresent(RemoteMessageExtra.self, forKey: .messageExtra)
		message = try container.decodeIfPresent(RemoteMessage.self, forKey: .message)
			?? container.decodeIfPresent(RemoteMessage.self, forKey: .currentMessage)
		duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        readReceipts = try container.decodeIfPresent([RemoteMessageReceipt].self, forKey: .readReceipts) ?? []
    }
}

struct RemoteMessageExtra: Decodable {
    let tenantID: String
    let messageID: String
    let channelID: String
    let channelType: String
    let channelSeq: Int64
	let version: Int64
    let operatorUID: String
    let extraType: String?
    let emoji: String
    let action: String
    let payload: [String: JSONValue]
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case messageID = "message_id"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
		case version
        case operatorUID = "operator_uid"
        case extraType = "extra_type"
        case emoji
        case action
        case payload
        case createdAt = "created_at"
    }

    var normalizedExtraType: String {
        (extraType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isReaction: Bool {
        normalizedExtraType == "reaction" || !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var operatorName: String {
        payload["nickname"]?.stringValue
            ?? payload["display_name"]?.stringValue
            ?? payload["operator_name"]?.stringValue
            ?? payload["actor_name"]?.stringValue
            ?? payload["name"]?.stringValue
            ?? ""
    }

    var dedupeKey: String {
		[messageID, String(version), operatorUID, emoji, action, createdAt ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    var editRevision: Int64 {
        if let value = payload["edit_revision"]?.stringValue,
           let revision = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           revision > 0 {
            return revision
        }
        if let nested = payload["payload"]?.objectValue {
            let value = nested["edit_revision"]?.stringValue ?? nested["editRevision"]?.stringValue ?? ""
            if let revision = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)), revision > 0 {
                return revision
            }
        }
        return 0
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPayload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        payload = decodedPayload
        tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID)
            ?? decodedPayload["tenant_id"]?.stringValue
            ?? ""
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
            ?? decodedPayload["message_id"]?.stringValue
            ?? decodedPayload["msg_id"]?.stringValue
            ?? ""
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID)
            ?? decodedPayload["channel_id"]?.stringValue
            ?? ""
        channelType = try container.decodeIfPresent(String.self, forKey: .channelType)
            ?? decodedPayload["channel_type"]?.stringValue
            ?? ""
        channelSeq = container.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? container.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
            ?? decodedPayload["channel_seq"]?.stringValue.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? decodedPayload["channelSeq"]?.stringValue.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? 0
		version = container.decodeLossyInt64IfPresent(forKey: .version)
			?? decodedPayload["version"]?.stringValue.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
			?? 0
        operatorUID = try container.decodeIfPresent(String.self, forKey: .operatorUID)
            ?? decodedPayload["operator_uid"]?.stringValue
            ?? decodedPayload["actor_uid"]?.stringValue
            ?? decodedPayload["from_uid"]?.stringValue
            ?? decodedPayload["sender_uid"]?.stringValue
            ?? decodedPayload["user_id"]?.stringValue
            ?? ""
        extraType = try container.decodeIfPresent(String.self, forKey: .extraType)
            ?? decodedPayload["extra_type"]?.stringValue
            ?? decodedPayload["type"]?.stringValue
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
            ?? decodedPayload["emoji"]?.stringValue
            ?? decodedPayload["reaction"]?.stringValue
            ?? ""
        action = try container.decodeIfPresent(String.self, forKey: .action)
            ?? decodedPayload["action"]?.stringValue
            ?? "add"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

struct RemoteConversationReadWatermark: Decodable, Equatable {
    let eventID: String
    let tenantID: String
    let imUID: String
    let appID: String
    let channelID: String
    let channelType: String
    let lastReadSeq: Int64
    let occurredAt: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventIDCamel = "eventId"
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case imUID = "im_uid"
        case imUIDCamel = "imUID"
        case appID = "app_id"
        case appIDCamel = "appId"
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case lastReadSeq = "last_read_seq"
        case lastReadSeqCamel = "lastReadSeq"
        case occurredAt = "occurred_at"
        case occurredAtCamel = "occurredAt"
    }

    init(
        eventID: String,
        tenantID: String,
        imUID: String,
        appID: String,
        channelID: String,
        channelType: String,
        lastReadSeq: Int64,
        occurredAt: String
    ) {
        self.eventID = eventID
        self.tenantID = tenantID
        self.imUID = imUID
        self.appID = appID
        self.channelID = channelID
        self.channelType = channelType
        self.lastReadSeq = lastReadSeq
        self.occurredAt = occurredAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
            ?? c.decodeIfPresent(String.self, forKey: .eventIDCamel)
            ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .imUIDCamel)
            ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
            ?? c.decodeIfPresent(String.self, forKey: .channelIDCamel)
            ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType)
            ?? c.decodeIfPresent(String.self, forKey: .channelTypeCamel)
            ?? ""
        lastReadSeq = c.decodeLossyInt64IfPresent(forKey: .lastReadSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .lastReadSeqCamel)
            ?? 0
        occurredAt = try c.decodeIfPresent(String.self, forKey: .occurredAt)
            ?? c.decodeIfPresent(String.self, forKey: .occurredAtCamel)
            ?? ""
    }
}

struct RealtimeEnvelope: Decodable {
    // Gateway notifications are wakeups, never authority to display or end a call.
    var isRTCCallNotification: Bool {
        guard type == "notification" else { return false }
        return ["type", "kind"].contains { key in
            payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call"
        }
    }

    let type: String
    let requestID: String?
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case type
        case requestID = "request_id"
        case payload
    }

    init(type: String, requestID: String?, payload: [String: JSONValue]) {
        self.type = type
        self.requestID = requestID
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        payload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
    }
}

struct RemoteMessageReport: Decodable {
    let id: String?
    let reporterUID: String?
    let reporterName: String?
    let reporterAvatar: String?
    let messageID: String?
    let channelID: String?
    let channelType: String?
    let location: String?
    let senderUID: String?
    let senderName: String?
    let senderAvatar: String?
    let messageText: String?
    let reason: String?
    let description: String?
    let status: String?
    let createdAt: String?
    let alreadyReported: Bool
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case reporterUID = "reporter_uid"
        case reporterName = "reporter_name"
        case reporterAvatar = "reporter_avatar"
        case messageID = "message_id"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case location
        case senderUID = "sender_uid"
        case senderName = "sender_name"
        case senderAvatar = "sender_avatar"
        case messageText = "message_text"
        case reason
        case description
        case status
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case alreadyReported = "already_reported"
        case alreadyReportedCamel = "alreadyReported"
        case readOnly = "read_only"
        case readOnlyCamel = "readOnly"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        reporterUID = try c.decodeIfPresent(String.self, forKey: .reporterUID)
        reporterName = try c.decodeIfPresent(String.self, forKey: .reporterName)
        reporterAvatar = try c.decodeIfPresent(String.self, forKey: .reporterAvatar)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        senderUID = try c.decodeIfPresent(String.self, forKey: .senderUID)
        senderName = try c.decodeIfPresent(String.self, forKey: .senderName)
        senderAvatar = try c.decodeIfPresent(String.self, forKey: .senderAvatar)
        messageText = try c.decodeIfPresent(String.self, forKey: .messageText)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtCamel)
        alreadyReported = c.decodeLossyBoolIfPresent(forKey: .alreadyReported)
            ?? c.decodeLossyBoolIfPresent(forKey: .alreadyReportedCamel)
            ?? false
        readOnly = c.decodeLossyBoolIfPresent(forKey: .readOnly)
            ?? c.decodeLossyBoolIfPresent(forKey: .readOnlyCamel)
            ?? false
    }
}

struct RemoteMessageReportLookupResponse: Decodable {
    let reported: Bool
    let report: RemoteMessageReport?

    enum CodingKeys: String, CodingKey {
        case reported
        case report
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reported = c.decodeLossyBoolIfPresent(forKey: .reported) ?? false
        report = try c.decodeIfPresent(RemoteMessageReport.self, forKey: .report)
    }
}

enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes"].contains(normalized) { return true }
            if ["false", "0", "no"].contains(normalized) { return false }
            return nil
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        default:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

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

struct RemoteStickerVariant: Decodable, Equatable {
    let kind: String
    let fileID: String
    let mimeType: String
    let url: String
    let sizeBytes: Int64?
    let width: Int?
    let height: Int?
    let durationMS: Int?
    let frameCount: Int?
    let thumbnailURL: String
    let cacheKey: String

    enum CodingKeys: String, CodingKey {
        case kind
        case fileID = "file_id"
        case mimeType = "mime_type"
        case url
        case assetURL = "asset_url"
        case previewURL = "preview_url"
        case downloadURL = "download_url"
        case sizeBytes = "size_bytes"
        case width
        case height
        case durationMS = "duration_ms"
        case frameCount = "frame_count"
        case thumbnailURL = "thumbnail_url"
        case cacheKey = "cache_key"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
            ?? c.decodeIfPresent(String.self, forKey: .assetURL)
            ?? c.decodeIfPresent(String.self, forKey: .previewURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? ""
        sizeBytes = c.decodeLossyInt64IfPresent(forKey: .sizeBytes)
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        durationMS = c.decodeLossyIntIfPresent(forKey: .durationMS)
        frameCount = c.decodeLossyIntIfPresent(forKey: .frameCount)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
    }
}

struct RemoteUserSticker: Decodable, Equatable {
    let id: String
    let stickerID: String
    let fileID: String
    let status: String
    let processingStatus: String
    let sort: Int
    let mimeType: String
    let sizeBytes: Int64?
    let width: Int?
    let height: Int?
    let durationMS: Int?
    let frameCount: Int?
    let cacheKey: String
    let version: String
    let thumbnailURL: String
    let variants: [RemoteStickerVariant]
    let errorCode: String
    let errorReason: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case stickerID = "sticker_id"
        case fileID = "file_id"
        case status
        case processingStatus = "processing_status"
        case sort
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case width
        case height
        case durationMS = "duration_ms"
        case frameCount = "frame_count"
        case cacheKey = "cache_key"
        case version
        case thumbnailURL = "thumbnail_url"
        case variants
        case errorCode = "error_code"
        case errorReason = "error_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        stickerID = try c.decodeIfPresent(String.self, forKey: .stickerID) ?? ""
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        processingStatus = try c.decodeIfPresent(String.self, forKey: .processingStatus) ?? ""
        sort = c.decodeLossyIntIfPresent(forKey: .sort) ?? 0
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        sizeBytes = c.decodeLossyInt64IfPresent(forKey: .sizeBytes)
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        durationMS = c.decodeLossyIntIfPresent(forKey: .durationMS)
        frameCount = c.decodeLossyIntIfPresent(forKey: .frameCount)
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        variants = try c.decodeIfPresent([RemoteStickerVariant].self, forKey: .variants) ?? []
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? ""
        errorReason = try c.decodeIfPresent(String.self, forKey: .errorReason) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

struct RemoteStickerPack: Decodable, Equatable {
    let id: String
    let name: String
    let coverURL: String
    let sort: Int
    let status: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case coverURL = "cover_url"
        case sort
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL) ?? ""
        sort = c.decodeLossyIntIfPresent(forKey: .sort) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

struct RemoteSticker: Decodable, Equatable {
    let id: String
    let packID: String
    let imageURL: String
    let fileID: String
    let mimeType: String
    let sizeBytes: Int64?
    let width: Int?
    let height: Int?
    let durationMS: Int?
    let frameCount: Int?
    let hash: String
    let cacheKey: String
    let thumbnailURL: String
    let variants: [RemoteStickerVariant]
    let scope: String
    let status: String
    let processingStatus: String
    let sort: Int
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case packID = "pack_id"
        case imageURL = "image_url"
        case fileID = "file_id"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case width
        case height
        case durationMS = "duration_ms"
        case frameCount = "frame_count"
        case hash
        case cacheKey = "cache_key"
        case thumbnailURL = "thumbnail_url"
        case variants
        case scope
        case status
        case processingStatus = "processing_status"
        case sort
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        packID = try c.decodeIfPresent(String.self, forKey: .packID) ?? ""
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL) ?? ""
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        sizeBytes = c.decodeLossyInt64IfPresent(forKey: .sizeBytes)
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        durationMS = c.decodeLossyIntIfPresent(forKey: .durationMS)
        frameCount = c.decodeLossyIntIfPresent(forKey: .frameCount)
        hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        variants = try c.decodeIfPresent([RemoteStickerVariant].self, forKey: .variants) ?? []
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        processingStatus = try c.decodeIfPresent(String.self, forKey: .processingStatus) ?? ""
        sort = c.decodeLossyIntIfPresent(forKey: .sort) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

struct RemoteStickerProcessingTask: Decodable, Equatable {
    let id: String
    let stickerID: String
    let fileID: String
    let status: String
    let errorCode: String
    let errorReason: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case stickerID = "sticker_id"
        case fileID = "file_id"
        case status
        case errorCode = "error_code"
        case errorReason = "error_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        stickerID = try c.decodeIfPresent(String.self, forKey: .stickerID) ?? ""
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? ""
        errorReason = try c.decodeIfPresent(String.self, forKey: .errorReason) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

struct RemoteUserStickerCommitResult: Decodable, Equatable {
    let sticker: RemoteSticker
    let task: RemoteStickerProcessingTask?

    enum CodingKeys: String, CodingKey {
        case sticker
        case task
    }
}

import Foundation

@MainActor
extension IMAPIClient {
    func tenantContext(context: IMAPIContext) async throws -> RemoteTenantContext {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireActiveTenantRoute(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/context", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func tenantProfile(context: IMAPIContext) async throws -> RemoteTenantProfile {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireActiveTenantRoute(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/profile", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func meProfile(context: IMAPIContext) async throws -> RemoteMeProfile {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireActiveTenantRoute(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/me/profile", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func myInviteCode(context: IMAPIContext) async throws -> RemoteMyInviteCode {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/me/invite-code", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func updateMeProfile(context: IMAPIContext, nickname: String?, username: String?) async throws -> RemoteMeProfile {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        var body: [String: Any] = [:]
        if let nickname {
            body["nickname"] = nickname
        }
        if let username {
            body["username"] = username
        }
        return try await request(base: tenantBase(for: context), path: "/api/tenant/me/profile", method: "PATCH", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func changeMyPassword(context: IMAPIContext, currentPassword: String, newPassword: String) async throws -> RemotePasswordChangeResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/password",
            method: "POST",
            bearer: context.imToken,
            body: [
                "current_password": currentPassword,
                "old_password": currentPassword,
                "new_password": newPassword
            ],
            requestAuthority: requestAuthority
        )
    }

    func cancelAccount(context: IMAPIContext, reason: String?) async throws -> RemoteAccountCancellationResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        var body: [String: Any] = ["confirmed": true]
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedReason.isEmpty {
            body["reason"] = trimmedReason
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/account-cancellation",
            method: "POST",
            bearer: context.imToken,
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func verificationStatus(context: IMAPIContext) async throws -> RemoteVerificationStatus {
        try await verificationStatus(context: context, contactOwner: nil)
    }

    // WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112
    func verificationStatus(context: IMAPIContext, contactOwner: ContactHTTPRequestOwner?) async throws -> RemoteVerificationStatus {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/me/verification-status",
            bearer: context.imToken, requestAuthority: requestAuthority, contactOwner: contactOwner)
    }

    func sendPhoneBindingCode(context: IMAPIContext, phone: String) async throws -> RemotePhoneCodeResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let body: [String: Any] = [
            "phone": phone,
            "scene": "phone_bind"
        ]
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/phone/captcha",
            method: "POST",
            bearer: context.imToken,
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func sendPhoneBindingChallenge(context: IMAPIContext, phone: String) async throws -> RemotePhoneBindingChallenge {
        let challenge = RemotePhoneBindingChallenge(
            codeResult: try await sendPhoneBindingCode(context: context, phone: phone)
        )
        guard challenge.sent, !challenge.requestID.isEmpty else {
            throw IMAPIError.businessForbidden(
                code: "phone_binding_request_id_missing",
                message: "手机号验证请求标识缺失，请重新获取验证码",
                error: nil
            )
        }
        return challenge
    }

    func verifyPhoneBinding(context: IMAPIContext, phone: String, code: String) async throws -> RemoteIMUser {
        try await verifyPhoneBinding(context: context, phone: phone, code: code, requestID: "")
    }

    func verifyPhoneBinding(context: IMAPIContext, phone: String, code: String, requestID: String) async throws -> RemoteIMUser {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRequestID.isEmpty else {
            throw IMAPIError.businessForbidden(
                code: "phone_binding_request_id_required",
                message: "手机号验证请求标识缺失，请重新获取验证码",
                error: nil
            )
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/phone/verify",
            method: "POST",
            bearer: context.imToken,
            body: [
                "phone": phone,
                "code": code,
                "request_id": normalizedRequestID
            ],
            requestAuthority: requestAuthority
        )
    }

    func submitRealNameVerification(context: IMAPIContext, realName: String, idNumber: String) async throws -> RemoteVerificationStatus {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/real-name/submit",
            method: "POST",
            bearer: context.imToken,
            body: [
                "real_name": realName,
                "id_card_no": idNumber
            ],
            requestAuthority: requestAuthority
        )
    }

    func registerDevice(context: IMAPIContext, registration: RemoteDeviceRegistration) async throws -> RemoteUserDevice {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/devices",
            method: "POST",
            bearer: context.imToken,
            body: registration.requestBody,
            requestAuthority: requestAuthority
        )
    }

    func retireCurrentPushToken(
        context: IMAPIContext,
        provider: RemotePushTokenProvider,
        tokenFingerprint: String
    ) async throws -> RemotePushTokenRetirementResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let fingerprint = tokenFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit }) else {
            throw IMAPIError.server("推送令牌指纹无效")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/devices/current/push-token/retire",
            method: "POST",
            bearer: context.imToken,
            body: [
                "provider": provider.rawValue,
                "token_fingerprint": fingerprint
            ],
            cachePolicy: .reloadIgnoringLocalCacheData,
            requestAuthority: requestAuthority
        )
    }

    func resolveNotificationTarget(
        context: IMAPIContext,
        targetRef: String
    ) async throws -> RemoteNotificationTargetResolution {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let normalizedTargetRef = targetRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTargetRef.isEmpty else {
            throw IMAPIError.server("通知目标引用无效")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/notifications/targets/resolve",
            method: "POST",
            bearer: context.imToken,
            body: ["target_ref": normalizedTargetRef],
            cachePolicy: .reloadIgnoringLocalCacheData,
            requestAuthority: requestAuthority
        )
    }

    func listDevices(context: IMAPIContext) async throws -> [RemoteUserDevice] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let data: RemoteList<RemoteUserDevice> = try await request(base: tenantBase(for: context), path: "/api/tenant/devices", bearer: context.imToken, requestAuthority: requestAuthority)
        return data.items
    }

    func disableDevice(context: IMAPIContext, deviceID: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let normalized = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let _: RemoteUserDevice = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/devices/\(normalized.urlPathEncoded)",
            method: "DELETE",
            bearer: context.imToken,
            cachePolicy: .reloadIgnoringLocalCacheData,
            requestAuthority: requestAuthority
        )
    }

    func listMyLoginLogs(context: IMAPIContext) async throws -> [RemoteMyLoginLog] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let data: RemoteList<RemoteMyLoginLog> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/login-logs",
            bearer: context.imToken,
            cachePolicy: .reloadIgnoringLocalCacheData,
            requestAuthority: requestAuthority
        )
        return data.items
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

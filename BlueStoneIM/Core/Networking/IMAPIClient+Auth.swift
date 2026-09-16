import Foundation

@MainActor
extension IMAPIClient {
    func login(username: String, password: String) async throws -> RemoteAuthData {
        let base = try await platformAPIBase(appID: IMAPIContext.canonicalIOSAppID)
        return try await request(base: base, path: "/api/platform/auth/login", method: "POST", body: ["username": username, "password": password])
    }

    func refreshCurrentSession(context: IMAPIContext) async throws -> RemoteAuthSessionRefreshResult {
        let refreshHeaders: [String: String]
        if let requestID = context.pendingRefreshRequestID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestID.isEmpty {
            refreshHeaders = ["Idempotency-Key": requestID]
        } else {
            refreshHeaders = [:]
        }
        if let tenantSession = context.tenantAuthSession, tenantSession.isUsable {
            let tenantID = (tenantSession.tenantID.isEmpty ? context.tenantID : tenantSession.tenantID) ?? ""
            guard !tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IMAPIError.missingContext("tenant_id")
            }
            if !tenantSession.usesTenantLocalRefreshEndpoint {
                let base = try await platformAPIBase(
                    appID: tenantSession.appID.isEmpty ? context.appID : tenantSession.appID
                )
                return try await request(
                    base: base,
                    path: "/api/platform/tenants/\(tenantID.urlPathEncoded)/session/refresh",
                    method: "POST",
                    body: authSessionRefreshBody(session: tenantSession, context: context),
                    additionalHeaders: refreshHeaders
                )
            }
            return try await request(
                base: tenantBase(for: context),
                path: "/api/tenant/auth/refresh",
                method: "POST",
                body: authSessionRefreshBody(session: tenantSession, context: context),
                additionalHeaders: refreshHeaders
            )
        }
        if let platformSession = context.platformAuthSession, platformSession.isUsable {
            let base = try await platformAPIBase(appID: platformSession.appID.isEmpty ? context.appID : platformSession.appID)
            return try await request(
                base: base,
                path: "/api/platform/auth/session/refresh",
                method: "POST",
                body: authSessionRefreshBody(session: platformSession, context: context),
                additionalHeaders: refreshHeaders
            )
        }
        throw IMAPIError.missingContext("refresh session")
    }

    func refreshTenantIMSession(context: IMAPIContext, expiresInSeconds: Int? = nil) async throws -> RemoteTenantIMSessionRefreshResult {
        try requireActiveTenantRoute(context)
        let oldIMToken = context.imToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !oldIMToken.isEmpty else {
            throw IMAPIError.missingContext("im token")
        }
        var body: [String: Any] = [:]
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(context.appID)
        if !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["app_id"] = normalizedAppID
        }
        if !context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["device_id"] = context.deviceID
        }
        if let expiresInSeconds, expiresInSeconds > 0 {
            body["expires_in_seconds"] = expiresInSeconds
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/auth/session/refresh",
            method: "POST",
            bearer: oldIMToken,
            body: body
        )
    }

    func logoutAuthSessions(context: IMAPIContext) async {
        var sessions: [IMStoredAuthSession] = []
        if let tenant = context.tenantAuthSession, tenant.isUsable {
            sessions.append(tenant)
        }
        if let platform = context.platformAuthSession, platform.isUsable, !sessions.contains(platform) {
            sessions.append(platform)
        }
        for session in sessions {
            let usesTenantLocalAuthority = session.usesTenantLocalRefreshEndpoint
                && session.tokenType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "platform"
            let base: URL
            let path: String
            if usesTenantLocalAuthority {
                base = tenantBase(for: context)
                path = "/api/tenant/auth/session/logout"
            } else {
                base = (try? await platformAPIBase(
                    appID: session.appID.isEmpty ? context.appID : session.appID
                )) ?? platformBase
                path = "/api/platform/auth/session/logout"
            }
            let _: EmptyPayload? = try? await request(
                base: base,
                path: path,
                method: "POST",
                body: authSessionRefreshBody(session: session, context: context)
            )
        }
    }

    func authSessionRefreshBody(session: IMStoredAuthSession, context: IMAPIContext) -> [String: Any] {
        var body: [String: Any] = [
            "session_id": session.sessionID,
            "refresh_token": session.refreshToken,
            "client_type": session.clientType.isEmpty ? "ios" : session.clientType,
            "device_id": session.deviceID.isEmpty ? context.deviceID : session.deviceID,
            "app_id": session.appID.isEmpty ? context.appID : session.appID
        ]
        if session.authVersion > 0 {
            body["expected_auth_version"] = session.authVersion
        }
        if session.sessionGeneration > 0 {
            body["expected_session_generation"] = session.sessionGeneration
        }
        return body
    }

    func loginTenantUser(username: String, password: String, slideToken: String?, context: IMAPIContext) async throws -> RemoteTenantLoginData {
        var body: [String: Any] = [
            "username": username,
            "password": password,
            "app_id": context.appID,
            "device_id": context.deviceID
        ]
        if let slideToken, !slideToken.isEmpty {
            body["slide_token"] = slideToken
        }
#if DEBUG
#endif
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/auth/login",
            method: "POST",
            body: body
        )
    }

    func loginIMUser(username: String, password: String, slideToken: String?, tenantCode: String, enterpriseContextToken: String, context: IMAPIContext) async throws -> RemoteTenantLoginData {
        var body: [String: Any] = [
            "username": username,
            "password": password,
            "app_id": context.appID,
            "device_id": context.deviceID,
            "client_type": "ios"
        ]
        if let slideToken, !slideToken.isEmpty {
            body["slide_token"] = slideToken
            body["human_verify"] = ["slide_token": slideToken]
        }
        let normalizedTenantCode = try Self.normalizedOptionalRegistrationEntryCode(tenantCode)
        let normalizedContextToken = enterpriseContextToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedTenantCode.isEmpty {
            body["tenant_code"] = normalizedTenantCode
        }
        if !normalizedContextToken.isEmpty {
            body["enterprise_context_token"] = normalizedContextToken
        }
        let base = try await platformAPIBase(appID: context.appID)
#if DEBUG
#endif
        return try await request(
            base: base,
            path: "/api/platform/auth/im-login",
            method: "POST",
            body: body
        )
    }

    func slideCaptchaConfig(scene: String, surface: String, appID: String) async throws -> RemoteSlideCaptchaConfig {
        var query = [
            "scene=\(scene.urlQueryEncoded)",
            "surface=\(surface.urlQueryEncoded)"
        ]
        if !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.append("app_id=\(appID.urlQueryEncoded)")
        }
        if Self.usesPlatformSlideCaptcha(scene: scene) {
            return try await request(
                base: try await platformAPIBase(appID: appID),
                path: "/api/platform/captcha/slide/config?\(query.joined(separator: "&"))"
            )
        }
        return try await request(base: tenantBase, path: "/api/tenant/captcha/slide/config?\(query.joined(separator: "&"))")
    }

    func slideCaptchaChallenge(scene: String, surface: String) async throws -> RemoteSlideCaptchaChallenge {
        if Self.usesPlatformSlideCaptcha(scene: scene) {
            return try await request(
                base: try await platformAPIBase(appID: IMAPIContext.canonicalIOSAppID),
                path: "/api/platform/captcha/slide/challenge",
                method: "POST",
                body: [
                    "scene": scene,
                    "surface": surface
                ]
            )
        }
        return try await request(
            base: tenantBase,
            path: "/api/tenant/captcha/slide/challenge",
            method: "POST",
            body: [
                "scene": scene,
                "surface": surface
            ]
        )
    }

    func captchaEntryStatus(scene: String, channel: String, tenantCode: String = "", appID: String) async throws -> RemoteCaptchaEntryStatus {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        var query = [
            "app_id=\(normalizedAppID.urlQueryEncoded)",
            "scene=\(scene.urlQueryEncoded)",
            "channel=\(channel.urlQueryEncoded)"
        ]
        let normalizedTenantCode = try Self.normalizedOptionalRegistrationEntryCode(tenantCode)
        if !normalizedTenantCode.isEmpty {
            query.append("tenant_code=\(normalizedTenantCode.urlQueryEncoded)")
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        return try await request(base: base, path: "/api/platform/captcha/entry-status?\(query.joined(separator: "&"))")
    }

    func verifySlideCaptcha(_ request: SlideCaptchaVerifyRequest) async throws -> RemoteSlideCaptchaVerifyResult {
        if Self.usesPlatformSlideCaptcha(scene: request.scene) {
            return try await self.request(
                base: try await platformAPIBase(appID: IMAPIContext.canonicalIOSAppID),
                path: "/api/platform/captcha/slide/verify",
                method: "POST",
                body: request.body
            )
        }
        return try await self.request(base: tenantBase, path: "/api/tenant/captcha/slide/verify", method: "POST", body: request.body)
    }

    static func usesPlatformSlideCaptcha(scene: String) -> Bool {
        scene.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "im_user_login"
    }

    static func normalizedOptionalRegistrationEntryCode(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let entry = RegistrationFlowPolicy.normalizedEntryCode(rawValue) else {
            throw IMAPIError.businessForbidden(
                code: "entry_code_invalid",
                message: "请输入有效的企业编码或邀请码",
                error: nil
            )
        }
        return entry.normalizedValue
    }

    func resolveTenantAssetURL(_ rawValue: String) -> String {
        resolveAssetURL(rawValue, base: tenantBase)
    }

    func resolveTenantAssetURL(_ rawValue: String, context: IMAPIContext) -> String {
        resolveAssetURL(rawValue, base: tenantBase(for: context))
    }

    func resolveAssetURL(_ rawValue: String, base: URL) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let developmentURL = normalizedDevelopmentObjectURL(trimmed, base: base) {
            return developmentURL
        }
        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return trimmed
        }
        if let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return trimmed
    }

    func normalizedDevelopmentObjectURL(_ rawValue: String, base: URL) -> String? {
        let normalizedRaw = rawValue.hasPrefix("//") ? "https:\(rawValue)" : rawValue
        guard let url = URL(string: normalizedRaw), url.scheme != nil else { return nil }
        let host = url.host?.lowercased() ?? ""
        let query = url.query?.lowercased() ?? ""
        guard host == "oss.local.dev" || query.contains("development_signature=1") else {
            return nil
        }
        var objectPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for prefix in ["api/tenant/dev-objects/", "dev-objects/"] where objectPath.hasPrefix(prefix) {
            objectPath.removeFirst(prefix.count)
            break
        }
        guard !objectPath.isEmpty else { return nil }
        let baseString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(baseString)/api/tenant/dev-objects/\(objectPath)?dev_object_signature=1"
    }

    func register(username: String, phone: String, password: String, tenantCode: String?, captchaCode: String?, enterpriseContextToken: String?, appID: String, deviceID: String) async throws -> RemoteAuthData {
        try await registerWithRequestID(
            username: username,
            phone: phone,
            password: password,
            tenantCode: tenantCode,
            captchaCode: captchaCode,
            enterpriseContextToken: enterpriseContextToken,
            appID: appID,
            deviceID: deviceID,
            requestID: UUID().uuidString.lowercased()
        )
    }

    func registerWithRequestID(username: String, phone: String, password: String, tenantCode: String?, captchaCode: String?, enterpriseContextToken: String?, appID: String, deviceID: String, requestID: String, registrationSessionSecret: String? = nil) async throws -> RemoteAuthData {
        var body: [String: Any] = [
            "password": password,
            "app_id": appID,
            "device_id": deviceID,
            "client_type": "ios"
        ]
        if let registrationSessionSecret {
            guard RegistrationSessionRecovery.isValidSecret(registrationSessionSecret) else {
                throw IMAPIError.missingContext("registration recovery credential")
            }
            body["registration_session_secret"] = registrationSessionSecret
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUsername.isEmpty {
            body["username"] = trimmedUsername
        }
        if !trimmedPhone.isEmpty {
            body["phone"] = trimmedPhone
        }
        if let tenantCode {
            let normalizedTenantCode = try Self.normalizedOptionalRegistrationEntryCode(tenantCode)
            if !normalizedTenantCode.isEmpty {
                body["tenant_code"] = normalizedTenantCode
            }
        }
        if let captchaCode, !captchaCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["captcha_code"] = captchaCode.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let enterpriseContextToken,
           !enterpriseContextToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["enterprise_context_token"] = enterpriseContextToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = try await platformAPIBase(appID: appID)
        return try await request(
            base: base,
            path: "/api/platform/auth/register",
            method: "POST",
            body: body,
            additionalHeaders: ["Idempotency-Key": requestID],
            preserveHTTPStatusErrors: true,
            classifyUncertainRegistrationOutcome: true
        )
    }

    func registrationSession(appID: String, deviceID: String, requestID: String, secret: String) async throws -> RemoteRegistrationSessionResult {
        guard RegistrationSessionRecovery.isValidSecret(secret), UUID(uuidString: requestID) != nil,
              !appID.isEmpty, !deviceID.isEmpty else {
            throw IMAPIError.missingContext("registration recovery credential")
        }
        return try await request(
            base: try await platformAPIBase(appID: appID),
            path: "/api/platform/auth/register/session", method: "POST",
            body: ["registration_request_id": requestID, "registration_session_secret": secret,
                   "app_id": appID, "device_id": deviceID, "client_type": "ios"],
            cachePolicy: .reloadIgnoringLocalCacheData, preserveHTTPStatusErrors: true,
            propagateTaskCancellation: true
        )
    }

    func registrationStatus(appID: String, deviceID: String, requestID: String) async throws -> RemoteRegistrationStatus {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        let normalizedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedAppID.isEmpty, !normalizedDeviceID.isEmpty,
              UUID(uuidString: normalizedRequestID) != nil else {
            throw IMAPIError.missingContext("registration confirmation")
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        let path = "/api/platform/auth/register/status?app_id=\(normalizedAppID.urlQueryEncoded)&device_id=\(normalizedDeviceID.urlQueryEncoded)"
        let confirmation: RemoteRegistrationConfirmation = try await request(
            base: base,
            path: path,
            additionalHeaders: ["Idempotency-Key": normalizedRequestID],
            cachePolicy: .reloadIgnoringLocalCacheData,
            preserveHTTPStatusErrors: true,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .readOnly
        )
        return confirmation.status
    }

    func sendPlatformCaptcha(phone: String, scene: String, tenantCode: String = "") async throws -> RemotePhoneCodeResult {
        var body: [String: Any] = [
            "phone": phone,
            "scene": scene,
            "channel": "sms"
        ]
        let normalizedTenantCode = try Self.normalizedOptionalRegistrationEntryCode(tenantCode)
        if !normalizedTenantCode.isEmpty {
            body["tenant_code"] = normalizedTenantCode
        }
        let base = try await platformAPIBase(appID: IMAPIContext.canonicalIOSAppID)
        return try await request(
            base: base,
            path: "/api/platform/captcha/send",
            method: "POST",
            body: body
        )
    }

    func resetPassword(phone: String, code: String, newPassword: String) async throws -> RemotePasswordResetResponse {
        let base = try await platformAPIBase(appID: IMAPIContext.canonicalIOSAppID)
        return try await request(
            base: base,
            path: "/api/platform/auth/password/reset",
            method: "POST",
            body: [
                "phone": phone.trimmingCharacters(in: .whitespacesAndNewlines),
                "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
                "new_password": newPassword
            ]
        )
    }

    func sendTenantCaptcha(
        phone: String,
        scene: String,
        tenantCode: String = "",
        context: IMAPIContext
    ) async throws -> RemotePhoneCodeResult {
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
        let deviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        guard !deviceID.isEmpty else {
            throw IMAPIError.missingContext("device_id")
        }
        let base = try await publicTenantRouteBase(appID: appID)
        let proof = try await preauthDeviceProof(
            base: base,
            appID: appID,
            deviceID: deviceID,
            forceRefresh: false,
            allowsObserveFallback: true
        )
        do {
            return try await sendTenantCaptchaRequest(
                base: base,
                phone: phone,
                scene: scene,
                tenantCode: tenantCode,
                appID: appID,
                deviceID: deviceID,
                deviceProof: proof
            )
        } catch {
            guard Self.isCaptchaDeviceProofRequired(error) else { throw error }
            invalidatePreauthDeviceProof(base: base, appID: appID, deviceID: deviceID)
            // A missing proof means the compatibility endpoint already failed in
            // observe mode. Do not multiply traffic during a partial rollout.
            guard proof != nil else { throw error }
            guard let refreshedProof = try await preauthDeviceProof(
                base: base,
                appID: appID,
                deviceID: deviceID,
                forceRefresh: true,
                allowsObserveFallback: false
            ) else {
                throw error
            }
            return try await sendTenantCaptchaRequest(
                base: base,
                phone: phone,
                scene: scene,
                tenantCode: tenantCode,
                appID: appID,
                deviceID: deviceID,
                deviceProof: refreshedProof
            )
        }
    }

    func sendTenantCaptchaRequest(
        base: URL,
        phone: String,
        scene: String,
        tenantCode: String,
        appID: String,
        deviceID: String,
        deviceProof: String?
    ) async throws -> RemotePhoneCodeResult {
        var body: [String: Any] = [
            "phone": phone,
            "scene": scene,
            "channel": "sms",
            "app_id": appID,
            "device_id": deviceID
        ]
        let normalizedTenantCode = try Self.normalizedOptionalRegistrationEntryCode(tenantCode)
        if !normalizedTenantCode.isEmpty {
            body["tenant_code"] = normalizedTenantCode
        }
        if let deviceProof, !deviceProof.isEmpty {
            body["device_proof"] = deviceProof
        }
        return try await request(
            base: base,
            path: "/api/tenant/captcha/send",
            method: "POST",
            body: body
        )
    }

    func preauthDeviceProof(
        base: URL,
        appID: String,
        deviceID: String,
        forceRefresh: Bool,
        allowsObserveFallback: Bool
    ) async throws -> String? {
        let key = PreauthDeviceProofCacheKey(
            tenantBase: base.absoluteString,
            appID: appID,
            deviceID: deviceID
        )
        let now = preauthDeviceProofNow()
        if !forceRefresh,
           let cached = preauthDeviceProofCache[key],
           cached.expiresAt.timeIntervalSince(now) > Self.preauthDeviceProofRefreshSkew {
            return cached.proof
        }
        if !forceRefresh,
           let unavailableUntil = preauthDeviceProofUnavailableUntil[key],
           unavailableUntil > now {
            return nil
        }
        if let existing = preauthDeviceProofFetchTasks[key] {
            do {
                let entry = try await existing.value
                return entry.proof
            } catch {
                if allowsObserveFallback && Self.canSendCaptchaWithoutPreauthProof(after: error) {
                    preauthDeviceProofUnavailableUntil[key] = now.addingTimeInterval(Self.preauthDeviceProofFailureBackoff(error))
                    return nil
                }
                throw error
            }
        }

        let task = Task { @MainActor [weak self] () throws -> PreauthDeviceProofCacheEntry in
            guard let self else { throw CancellationError() }
            return try await self.fetchPreauthDeviceProof(base: base, appID: appID, deviceID: deviceID)
        }
        preauthDeviceProofFetchTasks[key] = task
        do {
            let entry = try await task.value
            preauthDeviceProofFetchTasks[key] = nil
            preauthDeviceProofCache[key] = entry
            preauthDeviceProofUnavailableUntil[key] = nil
            return entry.proof
        } catch {
            preauthDeviceProofFetchTasks[key] = nil
            guard allowsObserveFallback && Self.canSendCaptchaWithoutPreauthProof(after: error) else {
                throw error
            }
            preauthDeviceProofUnavailableUntil[key] = now.addingTimeInterval(Self.preauthDeviceProofFailureBackoff(error))
            return nil
        }
    }

    func fetchPreauthDeviceProof(
        base: URL,
        appID: String,
        deviceID: String
    ) async throws -> PreauthDeviceProofCacheEntry {
        let payload: PreauthDeviceProofPayload = try await request(
            base: base,
            path: "/api/tenant/security/preauth-device",
            method: "POST",
            body: [
                "app_id": appID,
                "device_id": deviceID,
                "platform": "ios"
            ],
            cachePolicy: .reloadIgnoringLocalCacheData,
            preserveHTTPStatusErrors: true
        )
        let proof = payload.deviceProof.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proof.isEmpty,
              proof.utf8.count <= 2_048,
              let expiresAt = Self.preauthDeviceProofDate(payload.expiresAt),
              expiresAt.timeIntervalSince(preauthDeviceProofNow()) > Self.preauthDeviceProofRefreshSkew else {
            throw IMAPIError.server("设备验证暂不可用，请稍后重试")
        }
        return PreauthDeviceProofCacheEntry(proof: proof, expiresAt: expiresAt)
    }

    func invalidatePreauthDeviceProof(base: URL, appID: String, deviceID: String) {
        let key = PreauthDeviceProofCacheKey(
            tenantBase: base.absoluteString,
            appID: appID,
            deviceID: deviceID
        )
        preauthDeviceProofCache[key] = nil
    }

    private static let preauthDeviceProofRefreshSkew: TimeInterval = 30
    private static let preauthDeviceProofDefaultFailureBackoff: TimeInterval = 30
    private static let preauthDeviceProofMaximumFailureBackoff: TimeInterval = 300

    static func preauthDeviceProofDate(_ rawValue: String) -> Date? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func canSendCaptchaWithoutPreauthProof(after error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .httpStatus(let statusCode, _):
            return statusCode == 404 || statusCode == 503
        case .businessForbidden(let code, _, _):
            let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "preauth_device_app_untrusted" || normalized == "forbidden"
        case .forbidden, .rateLimited:
            return true
        default:
            return false
        }
    }

    static func preauthDeviceProofFailureBackoff(_ error: Error) -> TimeInterval {
        if let apiError = error as? IMAPIError,
           case .rateLimited(_, _, let retryAfterSeconds, _) = apiError,
           let retryAfterSeconds {
            return min(
                preauthDeviceProofMaximumFailureBackoff,
                TimeInterval(max(1, retryAfterSeconds))
            )
        }
        return preauthDeviceProofDefaultFailureBackoff
    }

    static func isCaptchaDeviceProofRequired(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError,
              case .businessForbidden(let code, _, _) = apiError else {
            return false
        }
        return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "captcha_device_proof_required"
    }

    #if DEBUG
    func preauthDeviceProofCacheCountForTesting() -> Int {
        preauthDeviceProofCache.count
    }
    #endif
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

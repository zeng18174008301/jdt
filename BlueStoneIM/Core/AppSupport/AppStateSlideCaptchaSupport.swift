import Foundation

/// iOS slide captcha flow for IM login:
/// tenant config(scene: im_user_login, surface: ios) -> tenant challenge -> native drag overlay -> verify(ticket) -> one-time slide_token -> login.
///
/// MainActor partition: this service remains MainActor-isolated because it
/// calls back into AppState to present the native slide captcha prompt. The
/// network awaits inside the flow must keep AppState's generation and prompt
/// state checks serialized with the login UI.
@MainActor
final class SlideCaptchaService {
    func tokenIfNeeded(
        scene: String,
        tenantCode: String,
        appID: String,
        api: IMAPIProtocol,
        presentSelfHosted: (RemoteSlideCaptchaChallenge) async throws -> SlideCaptchaTicket
    ) async throws -> String? {
        let surface = slideSurface(scene: scene, appID: appID)
        let config = try await api.slideCaptchaConfig(scene: scene, surface: surface, appID: appID)
        guard config.required && config.enabled else { return nil }
        guard config.available else {
            throw IMAPIError.forbidden(config.unavailableMessage)
        }
        let ticket = try await makeProviderTicket(
            config: config,
            scene: scene,
            surface: surface,
            api: api,
            presentSelfHosted: presentSelfHosted
        )
        let result = try await api.verifySlideCaptcha(SlideCaptchaVerifyRequest(scene: scene, config: config, ticket: ticket))
        guard !result.slideToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.emptyResponse
        }
        return result.slideToken
    }

    private func slideSurface(scene: String, appID: String) -> String {
        let normalizedScene = scene.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedScene == "im_user_login" { return "ios" }
        if normalizedScene == "tenant_admin_login" { return "tenant_admin" }
        if normalizedScene == "web_chat_login" { return "web" }
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedAppID.contains("android") { return "android" }
        return "ios"
    }

    private func makeProviderTicket(
        config: RemoteSlideCaptchaConfig,
        scene: String,
        surface: String,
        api: IMAPIProtocol,
        presentSelfHosted: (RemoteSlideCaptchaChallenge) async throws -> SlideCaptchaTicket
    ) async throws -> SlideCaptchaTicket {
        let provider = config.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case "self_hosted_slide", "self_hosted", "local_slide":
            let challenge = try await api.slideCaptchaChallenge(scene: scene, surface: surface)
            return try await presentSelfHosted(challenge)
        case "", "mock", "development", "dev", "local":
            let nonce = UUID().uuidString
            return SlideCaptchaTicket(
                ticket: "ios-development-ticket-\(nonce)",
                randstr: "ios-\(nonce.prefix(8))",
                challengeID: "ios-development-challenge",
                lotNumber: "ios-development-lot",
                captchaOutput: "ios-development-output",
                passToken: "ios-development-pass",
                genTime: String(Int(Date().timeIntervalSince1970)),
                extra: [
                    "client": "ios",
                    "mode": "development",
                    "surface": surface,
                    "provider": provider.isEmpty ? "development" : provider
                ]
            )
        default:
            throw IMAPIError.forbidden(captchaUserMessage(code: "captcha_channel_unavailable", reason: nil, fallback: "滑动验证暂不可用"))
        }
    }
}

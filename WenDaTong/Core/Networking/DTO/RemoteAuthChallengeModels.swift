import Foundation
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
typealias RemoteLoginSecurityInfo = IM4Data.RemoteLoginSecurityInfo
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
typealias RemoteCaptchaEntryStatus = IM4Data.RemoteCaptchaEntryStatus

extension RemoteCaptchaEntryStatus {
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
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
typealias RemoteCaptchaEntry = IM4Data.RemoteCaptchaEntry

extension RemoteCaptchaEntry {
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
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
typealias RemoteSlideCaptchaConfig = IM4Data.RemoteSlideCaptchaConfig

extension RemoteSlideCaptchaConfig {
    var unavailableMessage: String {
        captchaUserMessage(code: reasonCode, reason: reason, fallback: "滑动验证暂不可用")
    }
}
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
typealias RemoteSlideCaptchaChallenge = IM4Data.RemoteSlideCaptchaChallenge
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

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

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
typealias RemoteSlideCaptchaVerifyResult = IM4Data.RemoteSlideCaptchaVerifyResult
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
typealias RemoteVerificationStatus = IM4Data.RemoteVerificationStatus
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
typealias RemotePhoneCodeResult = IM4Data.RemotePhoneCodeResult
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
import Foundation

public struct RemoteLoginSecurityInfo: Decodable, Equatable, Sendable { // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110
    public let surface: String
    public let day: String
    public let failedAttempts: Int?
    public let remainingAttempts: Int?
    public let maxAttempts: Int?
    public let locked: Bool
    public let banUntil: String
    public let lockedAccountCount: Int?
    public let threshold: Int?

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

    public init(from decoder: Decoder) throws {
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

public struct RemoteCaptchaEntryStatus: Decodable, Sendable {
    public let entries: [RemoteCaptchaEntry]

    enum CodingKeys: String, CodingKey {
        case entries
        case items
        case entry
    }

    public init(from decoder: Decoder) throws {
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


}

public struct RemoteCaptchaEntry: Decodable, Sendable {
    public let enabled: Bool
    public let available: Bool
    public let required: Bool
    public let source: String
    public let provider: String
    public let scene: String
    public let channel: String
    public let templateConfigured: Bool?
    public let secretConfigured: Bool?
    public let ttlSeconds: Int?
    public let rateLimit: Int?
    public let resource: String
    public let configSummary: String
    public let reasonCode: String
    public let reason: String

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

    public init(from decoder: Decoder) throws {
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






}

public struct RemoteSlideCaptchaConfig: Decodable, Sendable {
    public let enabled: Bool
    public let available: Bool
    public let required: Bool
    public let provider: String
    public let surface: String
    public let appID: String
    public let clientKey: String
    public let scene: String
    public let tokenTTLSeconds: Int
    public let sdkURL: String
    public let reasonCode: String
    public let reason: String
    public let extra: [String: JSONValue]

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

    public init(from decoder: Decoder) throws {
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


}

public struct RemoteSlideCaptchaChallenge: Decodable, Sendable, Equatable { // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
    public let provider: String
    public let challengeID: String
    public let backgroundImage: String
    public let pieceImage: String
    public let pieceY: Int
    public let width: Int
    public let height: Int
    public let pieceSize: Int
    public let challengeTTLSeconds: Int
    public let expiresAt: String

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

    public init(from decoder: Decoder) throws {
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

public struct RemoteSlideCaptchaVerifyResult: Decodable, Sendable {
    public let slideToken: String

    enum CodingKeys: String, CodingKey {
        case slideToken = "slide_token"
        case camelSlideToken = "slideToken"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slideToken = try c.decodeIfPresent(String.self, forKey: .slideToken)
            ?? c.decodeIfPresent(String.self, forKey: .camelSlideToken)
            ?? ""
    }
}

public struct RemoteVerificationStatus: Decodable, Sendable {
    public let imUID: String
    public let userID: String
    public let accountID: String
    public let phoneRequirementSatisfied: Bool?
    public let realNameRequirementSatisfied: Bool?
    public let phoneBound: Bool
    public let phoneBindingKnown: Bool
    public let phoneMasked: String
    public let realNameVerified: Bool
    public let realNameMasked: String
    public let idCardMasked: String
    public let realNameStatus: String
    public let realNameRejectReason: String

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

    public init(from decoder: Decoder) throws {
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

public struct RemotePhoneCodeResult: Decodable, Sendable {
    public let sent: Bool
    public let requestID: String
    public let phoneMasked: String
    public let expiresInSeconds: Int
    public let cooldownSeconds: Int

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

    public init(from decoder: Decoder) throws {
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
// WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END

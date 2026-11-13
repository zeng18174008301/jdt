// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
import Foundation

public struct RemoteAccountCancellationResponse: Decodable, Sendable {
    public let cancelled: Bool
    public let profile: RemoteMeProfile?

    enum CodingKeys: String, CodingKey {
        case cancelled
        case profile
        case user
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cancelled = c.decodeLossyBoolIfPresent(forKey: .cancelled) ?? false
        profile = try c.decodeIfPresent(RemoteMeProfile.self, forKey: .profile)
            ?? c.decodeIfPresent(RemoteMeProfile.self, forKey: .user)
    }
}

public struct RemotePasswordChangeResponse: Decodable, Sendable {
    public let updated: Bool
    public let requiresRelogin: Bool
    public let sessionRemainsActive: Bool
    public let profile: RemoteMeProfile?

    enum CodingKeys: String, CodingKey {
        case updated
        case requiresRelogin = "requires_relogin"
        case requiresReloginCamel = "requiresRelogin"
        case sessionRemainsActive = "session_remains_active"
        case sessionRemainsActiveCamel = "sessionRemainsActive"
        case profile
        case user
    }

    public init(from decoder: Decoder) throws {
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

public struct RemotePasswordResetResponse: Decodable, Equatable, Sendable {
    public let reset: Bool
}
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

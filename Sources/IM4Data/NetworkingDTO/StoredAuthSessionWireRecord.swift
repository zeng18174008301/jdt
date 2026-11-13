// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation
import IM4Domain

public struct IMStoredAuthSession: Codable, Sendable, Equatable {
    public let sessionID: String
    public let refreshToken: String
    public let refreshExpiresAt: Int64
    public let tokenType: String
    public let tenantID: String
    public let accountID: String
    public let appID: String
    public let deviceID: String
    public let clientType: String
    public let authVersion: Int64
    public let sessionGeneration: Int64
    public let accessExpiresAt: Int64
    public let lifetimeMode: IMSessionLifetimeMode







    public init(
        sessionID: String,
        refreshToken: String,
        refreshExpiresAt: Int64 = 0,
        tokenType: String,
        tenantID: String = "",
        accountID: String = "",
        appID: String = "",
        deviceID: String = "",
        clientType: String = "ios",
        authVersion: Int64 = 0,
        sessionGeneration: Int64 = 0,
        accessExpiresAt: Int64 = 0,
        lifetimeMode: IMSessionLifetimeMode = .absolute
    ) {
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.refreshExpiresAt = refreshExpiresAt
        self.tokenType = tokenType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientType = clientType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ios" : clientType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authVersion = max(0, authVersion)
        self.sessionGeneration = max(0, sessionGeneration)
        self.accessExpiresAt = max(0, accessExpiresAt)
        self.lifetimeMode = lifetimeMode
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case refreshToken
        case refreshExpiresAt
        case tokenType
        case tenantID
        case accountID
        case appID
        case deviceID
        case clientType
        case authVersion
        case sessionGeneration
        case accessExpiresAt
        case lifetimeMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID) ?? "",
            refreshToken: try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? "",
            refreshExpiresAt: try c.decodeIfPresent(Int64.self, forKey: .refreshExpiresAt) ?? 0,
            tokenType: try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "",
            tenantID: try c.decodeIfPresent(String.self, forKey: .tenantID) ?? "",
            accountID: try c.decodeIfPresent(String.self, forKey: .accountID) ?? "",
            appID: try c.decodeIfPresent(String.self, forKey: .appID) ?? "",
            deviceID: try c.decodeIfPresent(String.self, forKey: .deviceID) ?? "",
            clientType: try c.decodeIfPresent(String.self, forKey: .clientType) ?? "ios",
            authVersion: try c.decodeIfPresent(Int64.self, forKey: .authVersion) ?? 0,
            sessionGeneration: try c.decodeIfPresent(Int64.self, forKey: .sessionGeneration) ?? 0,
            accessExpiresAt: try c.decodeIfPresent(Int64.self, forKey: .accessExpiresAt) ?? 0,
            lifetimeMode: try c.decodeIfPresent(IMSessionLifetimeMode.self, forKey: .lifetimeMode) ?? .absolute
        )
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

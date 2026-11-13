// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation
import IM4Domain

public struct RemoteAuthSession: Decodable, Sendable {
    public let sessionID: String
    public let refreshToken: String
    public let refreshExpiresAt: Int64
    public let clientType: String
    public let deviceID: String
    public let appID: String
    public let tokenType: String
    public let tenantID: String
    public let rotated: Bool
    public let requiresKeychain: Bool
    public let authVersion: Int64
    public let sessionGeneration: Int64
    public let accessExpiresAt: Int64
    public let lifetimeMode: IMSessionLifetimeMode

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





    public init(from decoder: Decoder) throws {
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

public struct RemoteTenantIMSessionRefreshResult: Decodable, Sendable, Equatable {
    public let imToken: String
    public let expiresAt: Int64
    public let imUID: String
    public let tenantID: String
    public let appID: String
    public let deviceID: String
    public let tokenType: String
    public let authVersion: Int64
    public let sessionGeneration: Int64

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

    public init(from decoder: Decoder) throws {
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

public struct RemoteAuthSessionRefreshResult: Sendable {
    public let platformToken: String
    public let imToken: String
    public let expiresAt: Int64
    public let authSession: RemoteAuthSession
    public let tenant: RemoteTenant?
    public let member: RemoteTenantMember?
    public let workspaces: [RemoteWorkspaceTenant]
    public let authVersion: Int64
    public let sessionGeneration: Int64

    public init(platformToken: String, imToken: String, expiresAt: Int64, authSession: RemoteAuthSession, tenant: RemoteTenant?, member: RemoteTenantMember?, workspaces: [RemoteWorkspaceTenant], authVersion: Int64, sessionGeneration: Int64) {
        self.platformToken = platformToken
        self.imToken = imToken
        self.expiresAt = expiresAt
        self.authSession = authSession
        self.tenant = tenant
        self.member = member
        self.workspaces = workspaces
        self.authVersion = authVersion
        self.sessionGeneration = sessionGeneration
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

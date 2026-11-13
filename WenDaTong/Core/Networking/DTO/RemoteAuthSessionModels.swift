// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation
import IM4Data
import IM4Domain

typealias IMSessionLifetimeMode = IM4Domain.IMSessionLifetimeMode

typealias RemoteAuthSession = IM4Data.RemoteAuthSession

extension RemoteAuthSession {
    var isUsable: Bool {
        !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedTokenType: String {
        tokenType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

typealias RemoteTenantIMSessionRefreshResult = IM4Data.RemoteTenantIMSessionRefreshResult

typealias RemoteAuthSessionRefreshResult = IM4Data.RemoteAuthSessionRefreshResult

extension RemoteAuthSessionRefreshResult: @retroactive Decodable {

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

    public init(from decoder: Decoder) throws {
        let platformToken: String
        let imToken: String
        let expiresAt: Int64
        let authSession: RemoteAuthSession
        let tenant: RemoteTenant?
        let member: RemoteTenantMember?
        let workspaces: [RemoteWorkspaceTenant]
        let authVersion: Int64
        let sessionGeneration: Int64
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
        self.init(platformToken: platformToken, imToken: imToken, expiresAt: expiresAt, authSession: authSession, tenant: tenant, member: member, workspaces: workspaces, authVersion: authVersion, sessionGeneration: sessionGeneration)
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

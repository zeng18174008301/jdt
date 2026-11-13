// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation
import IM4Domain

public struct RemoteTenantMember: Decodable, Sendable {
    public let id: String
    public let tenantID: String
    public let accountID: String
    public let imUID: String
    public let userID: String
    public let username: String
    public let nickname: String
    public let status: String
    public let role: String
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String

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

    public init(from decoder: Decoder) throws {
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

public struct RemoteTenantEnterRuntimeConfig: Decodable, Sendable, Equatable {
    public let tenantAPIBaseURL: String
    public let tenantAPIBaseURLSource: String
    public let tenantAPIBaseURLConfigured: Bool
    public let imAPIBaseURL: String
    public let configStatus: String
    public let missingFields: [String]
	public let contractVersion: Int
	public let appID: String
	public let tenantID: String
	public let routeRevision: UInt64
	public let routeSource: String
	public let routeStatus: String
	public let routeHash: String
	public let routes: [String: IMRuntimeRouteEndpointSet]
	public let routingPolicy: IMRuntimeRoutePolicy
    public var environment: String? = nil
    public var publicationID: String? = nil
    public var publicationRevision: UInt64? = nil
    public var profileFingerprint: String? = nil
    public var lifetimeMode: IMSessionLifetimeMode? = nil
    public var publicationStatus: String? = nil
    public var keysetRevision: UInt64? = nil

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



    public init(from decoder: Decoder) throws {
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


}

public struct RemoteEnterpriseContextResult: Decodable, Sendable, Equatable {
    public let appID: String
    public let tenantID: String
    public let contextToken: String
    public let expiresAt: Int64
    public let ttlSeconds: Int
    public let routeRevision: UInt64
    public let runtimeConfig: RemoteTenantEnterRuntimeConfig
    public let tenant: RemoteEnterpriseContextTenantPresentation?
    public let entryType: String
    public let scheme: String
    public let canonical: String
    public let tenantCode: String

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

    public init(from decoder: Decoder) throws {
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

public struct RemoteTenantServerRoute: Decodable, Sendable {
    public let apiHost: String
    public let gatewayHost: String

    enum CodingKeys: String, CodingKey {
        case apiHost = "api_host"
        case apiHostCamel = "apiHost"
        case gatewayHost = "gateway_host"
        case gatewayHostCamel = "gatewayHost"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiHost = try c.decodeIfPresent(String.self, forKey: .apiHost)
            ?? c.decodeIfPresent(String.self, forKey: .apiHostCamel)
            ?? ""
        gatewayHost = try c.decodeIfPresent(String.self, forKey: .gatewayHost)
            ?? c.decodeIfPresent(String.self, forKey: .gatewayHostCamel)
            ?? ""
    }
}

public struct RemoteTenantEnterResult: Equatable, Sendable {
    public let entryTicket: String
    public let runtimeConfig: RemoteTenantEnterRuntimeConfig

    public init(entryTicket: String, runtimeConfig: RemoteTenantEnterRuntimeConfig) {
        self.entryTicket = entryTicket
        self.runtimeConfig = runtimeConfig
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation

public struct RemoteTenantLoginData: Sendable {
    public let account: RemoteAccount?
    public let userID: String
    public let accountID: String
    public let platformToken: String
    public let authSession: RemoteAuthSession?
    public let tenant: RemoteTenantProfile?
    public let user: RemoteIMUser?
    public let role: String
    public let session: RemoteIMSession?
    public let requiresWorkspaceSelection: Bool
    public let canDirectEnter: Bool
    public let autoEnteredWorkspaceID: String
    public let workspaces: [RemoteWorkspaceTenant]
    public let defaultWorkspaceID: String
    public let defaultWorkspace: RemoteWorkspaceTenant?
    public let autoEnterDefaultWorkspace: Bool
    public let defaultWorkspaceValid: Bool?
    public let defaultWorkspaceUnavailable: Bool
    public let defaultWorkspaceReason: String
    public let entryStatus: String
    public let pendingEntryTenantID: String
    public let pendingApprovalCount: Int
    public let runtimeConfig: RemoteTenantEnterRuntimeConfig?

    public init(account: RemoteAccount?, userID: String, accountID: String, platformToken: String, authSession: RemoteAuthSession?, tenant: RemoteTenantProfile?, user: RemoteIMUser?, role: String, session: RemoteIMSession?, requiresWorkspaceSelection: Bool, canDirectEnter: Bool, autoEnteredWorkspaceID: String, workspaces: [RemoteWorkspaceTenant], defaultWorkspaceID: String, defaultWorkspace: RemoteWorkspaceTenant?, autoEnterDefaultWorkspace: Bool, defaultWorkspaceValid: Bool?, defaultWorkspaceUnavailable: Bool, defaultWorkspaceReason: String, entryStatus: String, pendingEntryTenantID: String, pendingApprovalCount: Int, runtimeConfig: RemoteTenantEnterRuntimeConfig?) {
        self.account = account
        self.userID = userID
        self.accountID = accountID
        self.platformToken = platformToken
        self.authSession = authSession
        self.tenant = tenant
        self.user = user
        self.role = role
        self.session = session
        self.requiresWorkspaceSelection = requiresWorkspaceSelection
        self.canDirectEnter = canDirectEnter
        self.autoEnteredWorkspaceID = autoEnteredWorkspaceID
        self.workspaces = workspaces
        self.defaultWorkspaceID = defaultWorkspaceID
        self.defaultWorkspace = defaultWorkspace
        self.autoEnterDefaultWorkspace = autoEnterDefaultWorkspace
        self.defaultWorkspaceValid = defaultWorkspaceValid
        self.defaultWorkspaceUnavailable = defaultWorkspaceUnavailable
        self.defaultWorkspaceReason = defaultWorkspaceReason
        self.entryStatus = entryStatus
        self.pendingEntryTenantID = pendingEntryTenantID
        self.pendingApprovalCount = pendingApprovalCount
        self.runtimeConfig = runtimeConfig
    }
}

public struct RemoteTenantLoginSessionPayload: Sendable {
    public let session: RemoteIMSession
    public let tenant: RemoteTenantProfile?
    public let user: RemoteIMUser?

    public init(session: RemoteIMSession, tenant: RemoteTenantProfile?, user: RemoteIMUser?) {
        self.session = session
        self.tenant = tenant
        self.user = user
    }
}

public struct RemoteIMSession: Sendable {
    public let imUID: String
    public let appID: String
    public let deviceID: String
    public let imToken: String
    public let expiresAt: Int64
    public let authSession: RemoteAuthSession?

    public init(imUID: String, appID: String, deviceID: String, imToken: String, expiresAt: Int64, authSession: RemoteAuthSession?) {
        self.imUID = imUID
        self.appID = appID
        self.deviceID = deviceID
        self.imToken = imToken
        self.expiresAt = expiresAt
        self.authSession = authSession
    }
}

public struct RemoteAuthData: Sendable {
    public let account: RemoteAccount
    public let platformToken: String
    public let authSession: RemoteAuthSession?
    public let registrationSession: RemoteTenantSwitchResult?
    public let registrationRuntimeConfig: RemoteTenantEnterRuntimeConfig?
    public let requiresApproval: Bool
    public let canDirectEnter: Bool?
    public let entryStatus: String
    public let entryType: String
    public let entryScheme: String
    public let entryCanonical: String
    public let requiresWorkspaceSelection: Bool?
    public let tenant: RemoteTenant?
    public let tenantMember: RemoteTenantMember?
    public let memberships: [RemoteTenantMembership]?
    public let fallbackToDefaultTenant: Bool
    public let fallbackReason: String
    public let requestedTenantCode: String
    public let defaultTenantCode: String

    public init(account: RemoteAccount, platformToken: String, authSession: RemoteAuthSession?, registrationSession: RemoteTenantSwitchResult?, registrationRuntimeConfig: RemoteTenantEnterRuntimeConfig?, requiresApproval: Bool, canDirectEnter: Bool?, entryStatus: String, entryType: String, entryScheme: String, entryCanonical: String, requiresWorkspaceSelection: Bool?, tenant: RemoteTenant?, tenantMember: RemoteTenantMember?, memberships: [RemoteTenantMembership]?, fallbackToDefaultTenant: Bool, fallbackReason: String, requestedTenantCode: String, defaultTenantCode: String) {
        self.account = account
        self.platformToken = platformToken
        self.authSession = authSession
        self.registrationSession = registrationSession
        self.registrationRuntimeConfig = registrationRuntimeConfig
        self.requiresApproval = requiresApproval
        self.canDirectEnter = canDirectEnter
        self.entryStatus = entryStatus
        self.entryType = entryType
        self.entryScheme = entryScheme
        self.entryCanonical = entryCanonical
        self.requiresWorkspaceSelection = requiresWorkspaceSelection
        self.tenant = tenant
        self.tenantMember = tenantMember
        self.memberships = memberships
        self.fallbackToDefaultTenant = fallbackToDefaultTenant
        self.fallbackReason = fallbackReason
        self.requestedTenantCode = requestedTenantCode
        self.defaultTenantCode = defaultTenantCode
    }
}

public struct RemoteEnterpriseContextTenantPresentation: Decodable, Sendable, Equatable {
    public let id: String
    public let tenantCode: String
    public let name: String
    public let logoURL: String
    public let logoCacheKey: String

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case tenantCode = "tenant_code"
        case name
        case tenantName = "tenant_name"
        case logoURL = "logo_url"
        case logoURLCamel = "logoUrl"
        case logoCacheKey = "logo_cache_key"
        case logoCacheKeyCamel = "logoCacheKey"
    }

    public init(id: String, tenantCode: String, name: String, logoURL: String, logoCacheKey: String) {
        self.id = id
        self.tenantCode = tenantCode
        self.name = name
        self.logoURL = logoURL
        self.logoCacheKey = logoCacheKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? ""
        logoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            ?? c.decodeIfPresent(String.self, forKey: .logoURLCamel)
            ?? ""
        logoCacheKey = try c.decodeIfPresent(String.self, forKey: .logoCacheKey)
            ?? c.decodeIfPresent(String.self, forKey: .logoCacheKeyCamel)
            ?? ""
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

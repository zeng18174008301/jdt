// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation

public struct RemoteTenantPlatformEntryResult: Sendable {
    public let tenant: RemoteTenant
    public let member: RemoteTenantMember
    public let user: RemoteIMUser?
    public let imUID: String
    public let imToken: String
    public let apiToken: String
    public let session: RemoteIMSession?
    public let authSession: RemoteAuthSession?
    public let accountID: String
    public let appID: String
    public let deviceID: String

    public init(tenant: RemoteTenant, member: RemoteTenantMember, user: RemoteIMUser?, imUID: String, imToken: String, apiToken: String, session: RemoteIMSession?, authSession: RemoteAuthSession?, accountID: String, appID: String, deviceID: String) {
        self.tenant = tenant
        self.member = member
        self.user = user
        self.imUID = imUID
        self.imToken = imToken
        self.apiToken = apiToken
        self.session = session
        self.authSession = authSession
        self.accountID = accountID
        self.appID = appID
        self.deviceID = deviceID
    }
}

public struct RemoteTenantSwitchResult: Sendable {
    public let tenant: RemoteTenant
    public let server: RemoteTenantServerRoute?
    public let app: RemoteApp
    public let member: RemoteTenantMember
    public let user: RemoteIMUser?
    public let imUID: String
    public let imToken: String
    public let session: RemoteIMSession?
    public let authSession: RemoteAuthSession?

    public init(tenant: RemoteTenant, server: RemoteTenantServerRoute?, app: RemoteApp, member: RemoteTenantMember, user: RemoteIMUser?, imUID: String, imToken: String, session: RemoteIMSession?, authSession: RemoteAuthSession?) {
        self.tenant = tenant
        self.server = server
        self.app = app
        self.member = member
        self.user = user
        self.imUID = imUID
        self.imToken = imToken
        self.session = session
        self.authSession = authSession
    }
}

public struct RemoteWorkspaceJoinApplication: Decodable, Sendable {
    public let id: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case applicationID = "application_id"
        case status
        case applicationStatus = "application_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .applicationID)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .applicationStatus)
            ?? ""
    }
}

public struct RemoteWorkspaceJoinResult: Sendable {
    public let tenant: RemoteWorkspaceTenant?
    public let member: RemoteTenantMember?
    public let application: RemoteWorkspaceJoinApplication?
    public let status: String
    public let joinType: String
    public let requiresApproval: Bool

    public init(tenant: RemoteWorkspaceTenant?, member: RemoteTenantMember?, application: RemoteWorkspaceJoinApplication?, status: String, joinType: String, requiresApproval: Bool) {
        self.tenant = tenant
        self.member = member
        self.application = application
        self.status = status
        self.joinType = joinType
        self.requiresApproval = requiresApproval
    }
}

public struct RemoteWorkspaceSwitchResult: Sendable {
    public let tenant: RemoteWorkspaceTenant
    public let member: RemoteTenantMember
    public let user: RemoteIMUser?
    public let session: RemoteIMSession
    public let authSession: RemoteAuthSession?

    public init(tenant: RemoteWorkspaceTenant, member: RemoteTenantMember, user: RemoteIMUser?, session: RemoteIMSession, authSession: RemoteAuthSession?) {
        self.tenant = tenant
        self.member = member
        self.user = user
        self.session = session
        self.authSession = authSession
    }
}

public struct RemoteDefaultWorkspaceResult: Sendable {
    public let defaultWorkspaceID: String
    public let defaultWorkspace: RemoteWorkspaceTenant?
    public let defaultWorkspaceValid: Bool?
    public let defaultWorkspaceReason: String

    public init(defaultWorkspaceID: String, defaultWorkspace: RemoteWorkspaceTenant?, defaultWorkspaceValid: Bool?, defaultWorkspaceReason: String) {
        self.defaultWorkspaceID = defaultWorkspaceID
        self.defaultWorkspace = defaultWorkspace
        self.defaultWorkspaceValid = defaultWorkspaceValid
        self.defaultWorkspaceReason = defaultWorkspaceReason
    }
}

public struct RemoteWorkspaceEntryState: Sendable {
    public let status: String
    public let tenantID: String
    public let tenantName: String
    public let tenantCode: String
    public let pendingEntryTenantID: String
    public let entrySource: String
    public let canSwitch: Bool
    public let pollAfterMS: Int
    public let lastErrorCode: String
    public let lastError: String
    public let workspace: RemoteWorkspaceTenant?

    public init(status: String, tenantID: String, tenantName: String, tenantCode: String, pendingEntryTenantID: String, entrySource: String, canSwitch: Bool, pollAfterMS: Int, lastErrorCode: String, lastError: String, workspace: RemoteWorkspaceTenant?) {
        self.status = status
        self.tenantID = tenantID
        self.tenantName = tenantName
        self.tenantCode = tenantCode
        self.pendingEntryTenantID = pendingEntryTenantID
        self.entrySource = entrySource
        self.canSwitch = canSwitch
        self.pollAfterMS = pollAfterMS
        self.lastErrorCode = lastErrorCode
        self.lastError = lastError
        self.workspace = workspace
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

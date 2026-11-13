// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation

public struct RemoteTenant: Sendable {
    public let id: String
    public let tenantCode: String
    public let name: String
    public let status: String
    public let logoURL: String
    public let logoStatus: String
    public let logoVersion: String
    public let logoUpdatedAt: String
    public let logoCacheKey: String
    public let logoMime: String
    public let logoWidth: Int?
    public let logoHeight: Int?
    public let entryType: String
    public let entryScheme: String
    public let entryCanonical: String
    public let inviterNickname: String
    public let inviterDisplayName: String

    public init(id: String, tenantCode: String, name: String, status: String, logoURL: String, logoStatus: String, logoVersion: String, logoUpdatedAt: String, logoCacheKey: String, logoMime: String, logoWidth: Int?, logoHeight: Int?, entryType: String, entryScheme: String, entryCanonical: String, inviterNickname: String, inviterDisplayName: String) {
        self.id = id
        self.tenantCode = tenantCode
        self.name = name
        self.status = status
        self.logoURL = logoURL
        self.logoStatus = logoStatus
        self.logoVersion = logoVersion
        self.logoUpdatedAt = logoUpdatedAt
        self.logoCacheKey = logoCacheKey
        self.logoMime = logoMime
        self.logoWidth = logoWidth
        self.logoHeight = logoHeight
        self.entryType = entryType
        self.entryScheme = entryScheme
        self.entryCanonical = entryCanonical
        self.inviterNickname = inviterNickname
        self.inviterDisplayName = inviterDisplayName
    }
}

public struct RemoteTenantMembership: Sendable {
    public let tenant: RemoteTenant
    public let member: RemoteTenantMember
    public let joinStatus: String
    public let applicationID: String
    public let applicationStatus: String
    public let approvalRequired: Bool
    public let canSwitch: Bool?
    public let enterable: Bool?
    public let disabledReason: String
    public let appID: String
    public let appTenantBound: Bool?
    public let appBindingStatus: String

    public init(tenant: RemoteTenant, member: RemoteTenantMember, joinStatus: String, applicationID: String, applicationStatus: String, approvalRequired: Bool, canSwitch: Bool?, enterable: Bool?, disabledReason: String, appID: String, appTenantBound: Bool?, appBindingStatus: String) {
        self.tenant = tenant
        self.member = member
        self.joinStatus = joinStatus
        self.applicationID = applicationID
        self.applicationStatus = applicationStatus
        self.approvalRequired = approvalRequired
        self.canSwitch = canSwitch
        self.enterable = enterable
        self.disabledReason = disabledReason
        self.appID = appID
        self.appTenantBound = appTenantBound
        self.appBindingStatus = appBindingStatus
    }
}

public struct RemoteWorkspaceTenant: Sendable {
    public let id: String
    public let tenantCode: String
    public let name: String
    public let status: String
    public let logoURL: String
    public let logoStatus: String
    public let logoVersion: String
    public let logoUpdatedAt: String
    public let logoCacheKey: String
    public let logoMime: String
    public let logoWidth: Int?
    public let logoHeight: Int?
    public let joinStatus: String
    public let memberRole: String
    public let applicationID: String
    public let applicationStatus: String
    public let approvalRequired: Bool
    public let current: Bool
    public let canSwitch: Bool
    public let accountStatus: String
    public let tenantStatus: String
    public let memberStatus: String
    public let enterable: Bool?
    public let disabledReason: String

    public init(id: String, tenantCode: String, name: String, status: String, logoURL: String, logoStatus: String, logoVersion: String, logoUpdatedAt: String, logoCacheKey: String, logoMime: String, logoWidth: Int?, logoHeight: Int?, joinStatus: String, memberRole: String, applicationID: String, applicationStatus: String, approvalRequired: Bool, current: Bool, canSwitch: Bool, accountStatus: String, tenantStatus: String, memberStatus: String, enterable: Bool?, disabledReason: String) {
        self.id = id
        self.tenantCode = tenantCode
        self.name = name
        self.status = status
        self.logoURL = logoURL
        self.logoStatus = logoStatus
        self.logoVersion = logoVersion
        self.logoUpdatedAt = logoUpdatedAt
        self.logoCacheKey = logoCacheKey
        self.logoMime = logoMime
        self.logoWidth = logoWidth
        self.logoHeight = logoHeight
        self.joinStatus = joinStatus
        self.memberRole = memberRole
        self.applicationID = applicationID
        self.applicationStatus = applicationStatus
        self.approvalRequired = approvalRequired
        self.current = current
        self.canSwitch = canSwitch
        self.accountStatus = accountStatus
        self.tenantStatus = tenantStatus
        self.memberStatus = memberStatus
        self.enterable = enterable
        self.disabledReason = disabledReason
    }
}

public struct RemoteApp: Decodable, Sendable {
    public let appID: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
    }
    public init(appID: String) { self.appID = appID }
}

public struct RemoteTenantProfile: Sendable {
    public let tenantID: String
    public let tenantCode: String
    public let name: String
    public let status: String
    public let logoURL: String
    public let logoStatus: String
    public let logoVersion: String
    public let logoUpdatedAt: String
    public let logoCacheKey: String
    public let logoMime: String
    public let logoWidth: Int?
    public let logoHeight: Int?

    public init(tenantID: String, tenantCode: String, name: String, status: String, logoURL: String, logoStatus: String, logoVersion: String, logoUpdatedAt: String, logoCacheKey: String, logoMime: String, logoWidth: Int?, logoHeight: Int?) {
        self.tenantID = tenantID
        self.tenantCode = tenantCode
        self.name = name
        self.status = status
        self.logoURL = logoURL
        self.logoStatus = logoStatus
        self.logoVersion = logoVersion
        self.logoUpdatedAt = logoUpdatedAt
        self.logoCacheKey = logoCacheKey
        self.logoMime = logoMime
        self.logoWidth = logoWidth
        self.logoHeight = logoHeight
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

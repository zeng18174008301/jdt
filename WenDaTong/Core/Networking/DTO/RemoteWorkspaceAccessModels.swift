// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation
import IM4Data

typealias RemoteTenantMember = IM4Data.RemoteTenantMember

typealias RemoteTenantEnterRuntimeConfig = IM4Data.RemoteTenantEnterRuntimeConfig

extension RemoteTenantEnterRuntimeConfig {
    var hasTenantAPIBaseURL: Bool {
        !tenantAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

	var runtimeRouteSnapshot: IMRuntimeRouteSnapshot {
		.init(
			contractVersion: contractVersion,
			appID: appID,
			tenantID: tenantID,
			revision: routeRevision,
			source: routeSource,
			status: routeStatus,
			configHash: routeHash,
			services: routes,
			policy: routingPolicy,
			hashScope: .tenantEntry,
            environment: environment,
            publicationID: publicationID,
            publicationRevision: publicationRevision,
            profileFingerprint: profileFingerprint,
            lifetimeMode: lifetimeMode,
            publicationStatus: publicationStatus,
            keysetRevision: keysetRevision
		)
	}
}

typealias RemoteEnterpriseContextResult = IM4Data.RemoteEnterpriseContextResult

typealias RemoteTenantServerRoute = IM4Data.RemoteTenantServerRoute

typealias RemoteTenantEnterResult = IM4Data.RemoteTenantEnterResult

extension RemoteTenantEnterResult: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case entryTicket = "entry_ticket"
        case entryTicketCamel = "entryTicket"
        case ticket
        case entry
        case runtimeConfig = "runtime_config"
        case runtimeConfigCamel = "runtimeConfig"
    }

    private enum EntryCodingKeys: String, CodingKey {
        case ticket
        case entryTicket = "entry_ticket"
        case entryTicketCamel = "entryTicket"
    }

    public init(from decoder: Decoder) throws {
        let entryTicket: String
        let runtimeConfig: RemoteTenantEnterRuntimeConfig
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entry = try? c.nestedContainer(keyedBy: EntryCodingKeys.self, forKey: .entry)
        entryTicket = try c.decodeIfPresent(String.self, forKey: .entryTicket)
            ?? c.decodeIfPresent(String.self, forKey: .entryTicketCamel)
            ?? c.decodeIfPresent(String.self, forKey: .ticket)
            ?? entry?.decodeIfPresent(String.self, forKey: .ticket)
            ?? entry?.decodeIfPresent(String.self, forKey: .entryTicket)
            ?? entry?.decodeIfPresent(String.self, forKey: .entryTicketCamel)
            ?? ""
        let nestedRuntime = try c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfig)
            ?? c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfigCamel)
        let topLevelRuntime = try RemoteTenantEnterRuntimeConfig(from: decoder)
        runtimeConfig = nestedRuntime?.hasTenantAPIBaseURL == true ? nestedRuntime! : topLevelRuntime
        self.init(entryTicket: entryTicket, runtimeConfig: runtimeConfig)
    }
}

typealias RemoteTenantPlatformEntryResult = IM4Data.RemoteTenantPlatformEntryResult

extension RemoteTenantPlatformEntryResult: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case tenant
        case member
        case user
        case imUID = "im_uid"
        case imUIDCamel = "imUid"
        case uid
        case imToken = "im_token"
        case imTokenCamel = "imToken"
        case apiToken = "api_token"
        case apiTokenCamel = "apiToken"
        case token
        case session
        case authSession = "auth_session"
        case authSessionCamel = "authSession"
        case refreshSession = "refresh_session"
        case refreshSessionCamel = "refreshSession"
        case accountID = "account_id"
        case accountIDCamel = "accountId"
        case platformAccountID = "platform_account_id"
        case platformAccountIDCamel = "platformAccountId"
        case appID = "app_id"
        case appIDCamel = "appId"
        case deviceID = "device_id"
        case deviceIDCamel = "deviceId"
    }

    public init(from decoder: Decoder) throws {
        let tenant: RemoteTenant
        let member: RemoteTenantMember
        let user: RemoteIMUser?
        let imUID: String
        let imToken: String
        let apiToken: String
        let __stored_session: RemoteIMSession?
        let authSession: RemoteAuthSession?
        let accountID: String
        let appID: String
        let deviceID: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decodeIfPresent(RemoteTenant.self, forKey: .tenant)
            ?? RemoteTenant(from: decoder)
        member = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .member)
            ?? RemoteTenantMember(from: decoder)
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? c.decodeIfPresent(RemoteIMUser.self, forKey: .member)
        let sessionPayload = try c.decodeIfPresent(RemoteTenantLoginSessionPayload.self, forKey: .session)
        let decodedSession: RemoteIMSession?
        if let session = sessionPayload?.session {
            decodedSession = session
        } else {
            decodedSession = try c.decodeIfPresent(RemoteIMSession.self, forKey: .session)
        }
        __stored_session = decodedSession
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
            ?? c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSessionCamel)
        let refreshSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .refreshSession)
            ?? c.decodeIfPresent(RemoteAuthSession.self, forKey: .refreshSessionCamel)
        authSession = refreshSession?.isUsable == true
            ? refreshSession
            : (nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : decodedSession?.authSession))
        apiToken = try c.decodeIfPresent(String.self, forKey: .apiToken)
            ?? c.decodeIfPresent(String.self, forKey: .apiTokenCamel)
            ?? ""
        imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
            ?? c.decodeIfPresent(String.self, forKey: .imTokenCamel)
            ?? c.decodeIfPresent(String.self, forKey: .token)
            ?? decodedSession?.imToken
            ?? apiToken
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .imUIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .uid)
            ?? decodedSession?.imUID
            ?? user?.imUID
            ?? member.imUID
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
            ?? c.decodeIfPresent(String.self, forKey: .accountIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .platformAccountID)
            ?? c.decodeIfPresent(String.self, forKey: .platformAccountIDCamel)
            ?? user?.accountID
            ?? member.accountID
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? decodedSession?.appID
            ?? authSession?.appID
            ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
            ?? c.decodeIfPresent(String.self, forKey: .deviceIDCamel)
            ?? decodedSession?.deviceID
            ?? authSession?.deviceID
            ?? ""
        self.init(tenant: tenant, member: member, user: user, imUID: imUID, imToken: imToken, apiToken: apiToken, session: __stored_session, authSession: authSession, accountID: accountID, appID: appID, deviceID: deviceID)
    }
}

typealias RemoteTenantSwitchResult = IM4Data.RemoteTenantSwitchResult

extension RemoteTenantSwitchResult: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case tenant
        case server
        case app
        case member
        case user
        case imUID = "im_uid"
        case imToken = "im_token"
        case session
        case authSession = "auth_session"
    }

    public init(from decoder: Decoder) throws {
        let tenant: RemoteTenant
        let server: RemoteTenantServerRoute?
        let app: RemoteApp
        let member: RemoteTenantMember
        let user: RemoteIMUser?
        let imUID: String
        let imToken: String
        let session: RemoteIMSession?
        let authSession: RemoteAuthSession?
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decode(RemoteTenant.self, forKey: .tenant)
        server = try c.decodeIfPresent(RemoteTenantServerRoute.self, forKey: .server)
        app = try c.decodeIfPresent(RemoteApp.self, forKey: .app) ?? RemoteApp(appID: "")
        member = try c.decode(RemoteTenantMember.self, forKey: .member)
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? c.decodeIfPresent(RemoteIMUser.self, forKey: .member)
        session = try c.decodeIfPresent(RemoteIMSession.self, forKey: .session)
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : session?.authSession)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? session?.imUID
            ?? member.imUID
        imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
            ?? session?.imToken
            ?? ""
        self.init(tenant: tenant, server: server, app: app, member: member, user: user, imUID: imUID, imToken: imToken, session: session, authSession: authSession)
    }
}

typealias RemoteWorkspaceJoinApplication = IM4Data.RemoteWorkspaceJoinApplication

typealias RemoteWorkspaceJoinResult = IM4Data.RemoteWorkspaceJoinResult

extension RemoteWorkspaceJoinResult: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case tenant
        case workspace
        case member
        case application
        case status
        case joinStatus = "join_status"
        case membershipStatus = "membership_status"
        case applicationStatus = "application_status"
        case joinType = "join_type"
        case approvalRequired = "approval_required"
        case requiresApproval = "requires_approval"
    }

    public init(from decoder: Decoder) throws {
        let tenant: RemoteWorkspaceTenant?
        let member: RemoteTenantMember?
        let application: RemoteWorkspaceJoinApplication?
        let status: String
        let joinType: String
        let requiresApproval: Bool
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .tenant)
            ?? c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .workspace)
        member = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .member)
        application = try c.decodeIfPresent(RemoteWorkspaceJoinApplication.self, forKey: .application)
        requiresApproval = c.decodeLossyBoolIfPresent(forKey: .approvalRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresApproval)
            ?? false
        let decodedStatus = try c.decodeIfPresent(String.self, forKey: .status)
        let decodedJoinStatus = try c.decodeIfPresent(String.self, forKey: .joinStatus)
        let decodedMembershipStatus = try c.decodeIfPresent(String.self, forKey: .membershipStatus)
        let decodedApplicationStatus = try c.decodeIfPresent(String.self, forKey: .applicationStatus)
        status = decodedStatus
            ?? decodedJoinStatus
            ?? decodedMembershipStatus
            ?? decodedApplicationStatus
            ?? application?.status
            ?? tenant?.joinStatus
            ?? (requiresApproval ? "pending" : nil)
            ?? ""
        joinType = (try c.decodeIfPresent(String.self, forKey: .joinType) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.init(tenant: tenant, member: member, application: application, status: status, joinType: joinType, requiresApproval: requiresApproval)
    }
}

typealias RemoteWorkspaceSwitchResult = IM4Data.RemoteWorkspaceSwitchResult

extension RemoteWorkspaceSwitchResult: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case tenant
        case member
        case user
        case session
        case authSession = "auth_session"
    }

    public init(from decoder: Decoder) throws {
        let tenant: RemoteWorkspaceTenant
        let member: RemoteTenantMember
        let user: RemoteIMUser?
        let session: RemoteIMSession
        let authSession: RemoteAuthSession?
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decode(RemoteWorkspaceTenant.self, forKey: .tenant)
        member = try c.decode(RemoteTenantMember.self, forKey: .member)
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? c.decodeIfPresent(RemoteIMUser.self, forKey: .member)
        session = try c.decode(RemoteIMSession.self, forKey: .session)
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : session.authSession)
        self.init(tenant: tenant, member: member, user: user, session: session, authSession: authSession)
    }
}

typealias RemoteDefaultWorkspaceResult = IM4Data.RemoteDefaultWorkspaceResult

extension RemoteDefaultWorkspaceResult: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case defaultWorkspaceID = "default_workspace_id"
        case defaultWorkspaceIDCamel = "defaultWorkspaceId"
        case defaultCompanyID = "default_company_id"
        case defaultCompanyIDCamel = "defaultCompanyId"
        case defaultTenantID = "default_tenant_id"
        case defaultTenantIDCamel = "defaultTenantId"
        case defaultWorkspace = "default_workspace"
        case defaultCompany = "default_company"
        case defaultTenant = "default_tenant"
        case defaultCompanyValid = "default_company_valid"
        case defaultCompanyValidCamel = "defaultCompanyValid"
        case defaultWorkspaceValid = "default_workspace_valid"
        case defaultWorkspaceValidCamel = "defaultWorkspaceValid"
        case defaultTenantValid = "default_tenant_valid"
        case defaultTenantValidCamel = "defaultTenantValid"
        case defaultCompanyInvalidReason = "default_company_invalid_reason"
        case defaultCompanyInvalidReasonCamel = "defaultCompanyInvalidReason"
        case defaultWorkspaceInvalidReason = "default_workspace_invalid_reason"
        case defaultWorkspaceInvalidReasonCamel = "defaultWorkspaceInvalidReason"
        case defaultTenantInvalidReason = "default_tenant_invalid_reason"
        case defaultTenantInvalidReasonCamel = "defaultTenantInvalidReason"
        case defaultWorkspaceReason = "default_workspace_reason"
        case defaultWorkspaceReasonCamel = "defaultWorkspaceReason"
    }

    public init(from decoder: Decoder) throws {
        let defaultWorkspaceID: String
        let defaultWorkspace: RemoteWorkspaceTenant?
        let defaultWorkspaceValid: Bool?
        let defaultWorkspaceReason: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultWorkspaceID = try c.decodeIfPresent(String.self, forKey: .defaultWorkspaceID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantIDCamel)
            ?? ""
        defaultWorkspace = try c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultWorkspace)
            ?? c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultCompany)
            ?? c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .defaultTenant)
        defaultWorkspaceValid = c.decodeLossyBoolIfPresent(forKey: .defaultCompanyValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultCompanyValidCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceValidCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantValidCamel)
        defaultWorkspaceReason = try c.decodeIfPresent(String.self, forKey: .defaultWorkspaceReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantInvalidReasonCamel)
            ?? ""
        self.init(defaultWorkspaceID: defaultWorkspaceID, defaultWorkspace: defaultWorkspace, defaultWorkspaceValid: defaultWorkspaceValid, defaultWorkspaceReason: defaultWorkspaceReason)
    }
}

typealias RemoteWorkspaceEntryState = IM4Data.RemoteWorkspaceEntryState

extension RemoteWorkspaceEntryState: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case status
        case entryStatus = "entry_status"
        case entryStatusCamel = "entryStatus"
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case pendingEntryTenantID = "pending_entry_tenant_id"
        case pendingEntryTenantIDCamel = "pendingEntryTenantId"
        case entrySource = "entry_source"
        case entrySourceCamel = "entrySource"
        case canSwitch = "can_switch"
        case canSwitchCamel = "canSwitch"
        case pollAfterMS = "poll_after_ms"
        case pollAfterMSCamel = "pollAfterMs"
        case pollAfterMSUpperCamel = "pollAfterMS"
        case lastErrorCode = "last_error_code"
        case lastErrorCodeCamel = "lastErrorCode"
        case lastError = "last_error"
        case lastErrorCamel = "lastError"
        case workspace
    }

    public init(from decoder: Decoder) throws {
        let status: String
        let tenantID: String
        let tenantName: String
        let tenantCode: String
        let pendingEntryTenantID: String
        let entrySource: String
        let canSwitch: Bool
        let pollAfterMS: Int
        let lastErrorCode: String
        let lastError: String
        let workspace: RemoteWorkspaceTenant?
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try c.decodeIfPresent(RemoteWorkspaceTenant.self, forKey: .workspace)
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .entryStatus)
            ?? c.decodeIfPresent(String.self, forKey: .entryStatusCamel)
            ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? workspace?.id
            ?? ""
        tenantName = try c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
            ?? workspace?.name
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? workspace?.tenantCode
            ?? ""
        pendingEntryTenantID = try c.decodeIfPresent(String.self, forKey: .pendingEntryTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .pendingEntryTenantIDCamel)
            ?? ""
        entrySource = try c.decodeIfPresent(String.self, forKey: .entrySource)
            ?? c.decodeIfPresent(String.self, forKey: .entrySourceCamel)
            ?? ""
        canSwitch = c.decodeLossyBoolIfPresent(forKey: .canSwitch)
            ?? c.decodeLossyBoolIfPresent(forKey: .canSwitchCamel)
            ?? true
        pollAfterMS = c.decodeLossyIntIfPresent(forKey: .pollAfterMS)
            ?? c.decodeLossyIntIfPresent(forKey: .pollAfterMSCamel)
            ?? c.decodeLossyIntIfPresent(forKey: .pollAfterMSUpperCamel)
            ?? 0
        lastErrorCode = try c.decodeIfPresent(String.self, forKey: .lastErrorCode)
            ?? c.decodeIfPresent(String.self, forKey: .lastErrorCodeCamel)
            ?? ""
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
            ?? c.decodeIfPresent(String.self, forKey: .lastErrorCamel)
            ?? ""
        self.init(status: status, tenantID: tenantID, tenantName: tenantName, tenantCode: tenantCode, pendingEntryTenantID: pendingEntryTenantID, entrySource: entrySource, canSwitch: canSwitch, pollAfterMS: pollAfterMS, lastErrorCode: lastErrorCode, lastError: lastError, workspace: workspace)
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var effectiveTenantID: String {
        [
            tenantID,
            pendingEntryTenantID,
            workspace?.id ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

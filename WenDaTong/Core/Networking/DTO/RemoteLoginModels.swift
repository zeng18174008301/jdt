// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation
import IM4Data
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

typealias RemoteTenantLoginData = IM4Data.RemoteTenantLoginData

extension RemoteTenantLoginData: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case account
        case userID = "user_id"
        case accountID = "account_id"
        case platformToken = "platform_token"
        case authSession = "auth_session"
        case tenant
        case user
        case role
        case session
        case requiresWorkspaceSelection = "requires_workspace_selection"
        case canDirectEnter = "can_direct_enter"
        case autoEnteredWorkspaceID = "auto_entered_workspace_id"
        case workspaces
        case defaultWorkspaceID = "default_workspace_id"
        case defaultWorkspaceIDCamel = "defaultWorkspaceId"
        case defaultCompanyID = "default_company_id"
        case defaultCompanyIDCamel = "defaultCompanyId"
        case defaultTenantID = "default_tenant_id"
        case defaultTenantIDCamel = "defaultTenantId"
        case defaultWorkspace = "default_workspace"
        case defaultCompany = "default_company"
        case defaultTenant = "default_tenant"
        case autoEnterDefaultCompany = "auto_enter_default_company"
        case autoEnterDefaultCompanyCamel = "autoEnterDefaultCompany"
        case autoEnterDefaultWorkspace = "auto_enter_default_workspace"
        case autoEnterDefaultWorkspaceCamel = "autoEnterDefaultWorkspace"
        case autoEnterDefaultTenant = "auto_enter_default_tenant"
        case autoEnterDefaultTenantCamel = "autoEnterDefaultTenant"
        case defaultCompanyValid = "default_company_valid"
        case defaultCompanyValidCamel = "defaultCompanyValid"
        case defaultWorkspaceValid = "default_workspace_valid"
        case defaultWorkspaceValidCamel = "defaultWorkspaceValid"
        case defaultTenantValid = "default_tenant_valid"
        case defaultTenantValidCamel = "defaultTenantValid"
        case defaultWorkspaceUnavailable = "default_workspace_unavailable"
        case defaultCompanyUnavailable = "default_company_unavailable"
        case defaultTenantUnavailable = "default_tenant_unavailable"
        case defaultWorkspaceReason = "default_workspace_reason"
        case defaultWorkspaceReasonCamel = "defaultWorkspaceReason"
        case defaultCompanyInvalidReason = "default_company_invalid_reason"
        case defaultCompanyInvalidReasonCamel = "defaultCompanyInvalidReason"
        case defaultWorkspaceInvalidReason = "default_workspace_invalid_reason"
        case defaultWorkspaceInvalidReasonCamel = "defaultWorkspaceInvalidReason"
        case defaultTenantInvalidReason = "default_tenant_invalid_reason"
        case defaultTenantInvalidReasonCamel = "defaultTenantInvalidReason"
        case defaultCompanyReason = "default_company_reason"
        case defaultCompanyReasonCamel = "defaultCompanyReason"
        case defaultTenantReason = "default_tenant_reason"
        case defaultTenantReasonCamel = "defaultTenantReason"
        case entryStatus = "entry_status"
        case entryStatusCamel = "entryStatus"
        case pendingEntryTenantID = "pending_entry_tenant_id"
        case pendingEntryTenantIDCamel = "pendingEntryTenantId"
        case pendingApprovalCount = "pending_approval_count"
        case pendingApprovalCountCamel = "pendingApprovalCount"
        case runtimeConfig = "runtime_config"
        case runtimeConfigCamel = "runtimeConfig"
    }

    public init(from decoder: Decoder) throws {
        let account: RemoteAccount?
        let userID: String
        let accountID: String
        let platformToken: String
        let authSession: RemoteAuthSession?
        let tenant: RemoteTenantProfile?
        let user: RemoteIMUser?
        let role: String
        let session: RemoteIMSession?
        let requiresWorkspaceSelection: Bool
        let canDirectEnter: Bool
        let autoEnteredWorkspaceID: String
        let workspaces: [RemoteWorkspaceTenant]
        let defaultWorkspaceID: String
        let defaultWorkspace: RemoteWorkspaceTenant?
        let autoEnterDefaultWorkspace: Bool
        let defaultWorkspaceValid: Bool?
        let defaultWorkspaceUnavailable: Bool
        let defaultWorkspaceReason: String
        let entryStatus: String
        let pendingEntryTenantID: String
        let pendingApprovalCount: Int
        let runtimeConfig: RemoteTenantEnterRuntimeConfig?
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decodeIfPresent(RemoteAccount.self, forKey: .account)
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        platformToken = try c.decodeIfPresent(String.self, forKey: .platformToken) ?? ""
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : nil)
        let sessionPayload = try c.decodeIfPresent(RemoteTenantLoginSessionPayload.self, forKey: .session)
        tenant = try c.decodeIfPresent(RemoteTenantProfile.self, forKey: .tenant)
            ?? sessionPayload?.tenant
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? sessionPayload?.user
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        session = sessionPayload?.session
        requiresWorkspaceSelection = c.decodeLossyBoolIfPresent(forKey: .requiresWorkspaceSelection) ?? false
        canDirectEnter = c.decodeLossyBoolIfPresent(forKey: .canDirectEnter) ?? true
        autoEnteredWorkspaceID = try c.decodeIfPresent(String.self, forKey: .autoEnteredWorkspaceID) ?? ""
        workspaces = try c.decodeIfPresent([RemoteWorkspaceTenant].self, forKey: .workspaces) ?? []
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
        autoEnterDefaultWorkspace = c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultCompany)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultCompanyCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultWorkspace)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultWorkspaceCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultTenant)
            ?? c.decodeLossyBoolIfPresent(forKey: .autoEnterDefaultTenantCamel)
            ?? false
        defaultWorkspaceValid = c.decodeLossyBoolIfPresent(forKey: .defaultCompanyValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultCompanyValidCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceValidCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantValid)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantValidCamel)
        let explicitUnavailable = c.decodeLossyBoolIfPresent(forKey: .defaultWorkspaceUnavailable)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultCompanyUnavailable)
            ?? c.decodeLossyBoolIfPresent(forKey: .defaultTenantUnavailable)
        defaultWorkspaceUnavailable = explicitUnavailable ?? (defaultWorkspaceValid == false)
        defaultWorkspaceReason = try c.decodeIfPresent(String.self, forKey: .defaultWorkspaceReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultWorkspaceInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantInvalidReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantInvalidReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultCompanyReasonCamel)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantReason)
            ?? c.decodeIfPresent(String.self, forKey: .defaultTenantReasonCamel)
            ?? ""
        entryStatus = try c.decodeIfPresent(String.self, forKey: .entryStatus)
            ?? c.decodeIfPresent(String.self, forKey: .entryStatusCamel)
            ?? ""
        pendingEntryTenantID = try c.decodeIfPresent(String.self, forKey: .pendingEntryTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .pendingEntryTenantIDCamel)
            ?? ""
        pendingApprovalCount = c.decodeLossyIntIfPresent(forKey: .pendingApprovalCount)
            ?? c.decodeLossyIntIfPresent(forKey: .pendingApprovalCountCamel)
            ?? 0
        runtimeConfig = try c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfig)
            ?? c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .runtimeConfigCamel)
        self.init(account: account, userID: userID, accountID: accountID, platformToken: platformToken, authSession: authSession, tenant: tenant, user: user, role: role, session: session, requiresWorkspaceSelection: requiresWorkspaceSelection, canDirectEnter: canDirectEnter, autoEnteredWorkspaceID: autoEnteredWorkspaceID, workspaces: workspaces, defaultWorkspaceID: defaultWorkspaceID, defaultWorkspace: defaultWorkspace, autoEnterDefaultWorkspace: autoEnterDefaultWorkspace, defaultWorkspaceValid: defaultWorkspaceValid, defaultWorkspaceUnavailable: defaultWorkspaceUnavailable, defaultWorkspaceReason: defaultWorkspaceReason, entryStatus: entryStatus, pendingEntryTenantID: pendingEntryTenantID, pendingApprovalCount: pendingApprovalCount, runtimeConfig: runtimeConfig)
    }
}

typealias RemoteTenantLoginSessionPayload = IM4Data.RemoteTenantLoginSessionPayload

extension RemoteTenantLoginSessionPayload: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case tenant
        case user
        case member
    }

    public init(from decoder: Decoder) throws {
        let session: RemoteIMSession
        let tenant: RemoteTenantProfile?
        let user: RemoteIMUser?
        session = try RemoteIMSession(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decodeIfPresent(RemoteTenantProfile.self, forKey: .tenant)
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
            ?? c.decodeIfPresent(RemoteIMUser.self, forKey: .member)
        self.init(session: session, tenant: tenant, user: user)
    }
}

// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
typealias RemoteIMUser = IM4Data.RemoteIMUser
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

struct RemoteIMSessionIdentity: Equatable {
    let appID: String
    let deviceID: String
    let tenantID: String
}

typealias RemoteIMSession = IM4Data.RemoteIMSession

extension RemoteIMSession: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case uid
        case appID = "app_id"
        case deviceID = "device_id"
        case imToken = "im_token"
        case token
        case expiresAt = "expires_at"
        case authSession = "auth_session"
    }

    public init(from decoder: Decoder) throws {
        let imUID: String
        let appID: String
        let deviceID: String
        let imToken: String
        let expiresAt: Int64
        let authSession: RemoteAuthSession?
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .uid)
            ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
            ?? c.decodeIfPresent(String.self, forKey: .token)
            ?? ""
        expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? 0
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : nil)
        self.init(imUID: imUID, appID: appID, deviceID: deviceID, imToken: imToken, expiresAt: expiresAt, authSession: authSession)
    }

    func effectiveIdentity(tenantID: String) -> RemoteIMSessionIdentity? {
        let topLevelTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let effectiveAppID = Self.resolveIdentityField(
            topLevel: appID,
            nested: authSession?.appID
        ),
        let effectiveDeviceID = Self.resolveIdentityField(
            topLevel: deviceID,
            nested: authSession?.deviceID
        ),
        let effectiveTenantID = Self.resolveIdentityField(
            topLevel: topLevelTenantID,
            nested: authSession?.tenantID
        ) else {
            return nil
        }
        return RemoteIMSessionIdentity(
            appID: effectiveAppID,
            deviceID: effectiveDeviceID,
            tenantID: effectiveTenantID
        )
    }

    private static func resolveIdentityField(topLevel: String, nested: String?) -> String? {
        let topLevelValue = topLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        let nestedValue = (nested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !topLevelValue.isEmpty, !nestedValue.isEmpty, topLevelValue != nestedValue {
            return nil
        }
        let effectiveValue = topLevelValue.isEmpty ? nestedValue : topLevelValue
        return effectiveValue.isEmpty ? nil : effectiveValue
    }
}

typealias RemoteAuthData = IM4Data.RemoteAuthData

extension RemoteAuthData: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case account
        case platformToken = "platform_token"
        case authSession = "auth_session"
        case registrationSession = "session"
        case registrationRuntimeConfig = "runtime_config"
        case requiresApproval = "requires_approval"
        case canDirectEnter = "can_direct_enter"
        case entryStatus = "entry_status"
        case entryType = "entry_type"
        case entryScheme = "scheme"
        case entryCanonical = "canonical"
        case requiresWorkspaceSelection = "requires_workspace_selection"
        case tenant
        case tenantMember = "tenant_member"
        case memberships
        case fallbackToDefaultTenant = "fallback_to_default_tenant"
        case fallbackReason = "fallback_reason"
        case requestedTenantCode = "requested_tenant_code"
        case defaultTenantCode = "default_tenant_code"
    }

    public init(from decoder: Decoder) throws {
        let account: RemoteAccount
        let platformToken: String
        let authSession: RemoteAuthSession?
        let registrationSession: RemoteTenantSwitchResult?
        let registrationRuntimeConfig: RemoteTenantEnterRuntimeConfig?
        let requiresApproval: Bool
        let canDirectEnter: Bool?
        let entryStatus: String
        let entryType: String
        let entryScheme: String
        let entryCanonical: String
        let requiresWorkspaceSelection: Bool?
        let tenant: RemoteTenant?
        let tenantMember: RemoteTenantMember?
        let memberships: [RemoteTenantMembership]?
        let fallbackToDefaultTenant: Bool
        let fallbackReason: String
        let requestedTenantCode: String
        let defaultTenantCode: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(RemoteAccount.self, forKey: .account)
        platformToken = try c.decodeIfPresent(String.self, forKey: .platformToken) ?? ""
        let topLevelAuthSession = try RemoteAuthSession(from: decoder)
        let nestedAuthSession = try c.decodeIfPresent(RemoteAuthSession.self, forKey: .authSession)
        authSession = nestedAuthSession?.isUsable == true ? nestedAuthSession : (topLevelAuthSession.isUsable ? topLevelAuthSession : nil)
        registrationSession = try c.decodeIfPresent(RemoteTenantSwitchResult.self, forKey: .registrationSession)
        registrationRuntimeConfig = try c.decodeIfPresent(RemoteTenantEnterRuntimeConfig.self, forKey: .registrationRuntimeConfig)
        requiresApproval = c.decodeLossyBoolIfPresent(forKey: .requiresApproval) ?? false
        canDirectEnter = c.decodeLossyBoolIfPresent(forKey: .canDirectEnter)
        entryStatus = try c.decodeIfPresent(String.self, forKey: .entryStatus) ?? ""
        entryType = try c.decodeIfPresent(String.self, forKey: .entryType) ?? ""
        entryScheme = try c.decodeIfPresent(String.self, forKey: .entryScheme) ?? ""
        entryCanonical = try c.decodeIfPresent(String.self, forKey: .entryCanonical) ?? ""
        requiresWorkspaceSelection = c.decodeLossyBoolIfPresent(forKey: .requiresWorkspaceSelection)
        tenant = try c.decodeIfPresent(RemoteTenant.self, forKey: .tenant)
        tenantMember = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .tenantMember)
        memberships = try c.decodeIfPresent([RemoteTenantMembership].self, forKey: .memberships)
        fallbackToDefaultTenant = c.decodeLossyBoolIfPresent(forKey: .fallbackToDefaultTenant) ?? false
        fallbackReason = try c.decodeIfPresent(String.self, forKey: .fallbackReason) ?? ""
        requestedTenantCode = try c.decodeIfPresent(String.self, forKey: .requestedTenantCode) ?? ""
        defaultTenantCode = try c.decodeIfPresent(String.self, forKey: .defaultTenantCode) ?? ""
        self.init(account: account, platformToken: platformToken, authSession: authSession, registrationSession: registrationSession, registrationRuntimeConfig: registrationRuntimeConfig, requiresApproval: requiresApproval, canDirectEnter: canDirectEnter, entryStatus: entryStatus, entryType: entryType, entryScheme: entryScheme, entryCanonical: entryCanonical, requiresWorkspaceSelection: requiresWorkspaceSelection, tenant: tenant, tenantMember: tenantMember, memberships: memberships, fallbackToDefaultTenant: fallbackToDefaultTenant, fallbackReason: fallbackReason, requestedTenantCode: requestedTenantCode, defaultTenantCode: defaultTenantCode)
    }

    var hasPendingWorkspaceApplication: Bool {
        if Self.isPendingWorkspaceStatus(entryStatus) { return true }
        if requiresApproval { return true }
        if let memberships, memberships.contains(where: { membership in
            let statuses = [
                membership.joinStatus,
                membership.applicationStatus,
                membership.member.status
            ]
            if statuses.contains(where: Self.isPendingWorkspaceStatus) {
                return true
            }
            let hasResolvedStatus = statuses.contains(where: Self.isApprovedOrJoinedWorkspaceStatus)
                || statuses.contains(where: Self.isRejectedWorkspaceStatus)
            return membership.approvalRequired && !hasResolvedStatus
        }) {
            return true
        }
        if let tenantMember, Self.isPendingWorkspaceStatus(tenantMember.status) {
            return true
        }
        return false
    }

    var hasTypedEntryAuthority: Bool {
        !entryScheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !entryCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var requiresRegistrationWorkspaceJoinRetry: Bool {
        guard registrationSession == nil, !hasPendingWorkspaceApplication else { return false }
        if memberships?.isEmpty == false { return true }
        return [
            "accountcreated", "joined", "alreadyjoined", "approved", "workspacejoinapproved"
        ].contains(Self.normalizedWorkspaceStatus(entryStatus))
    }

    private static func isPendingWorkspaceStatus(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        return [
            "pending", "pendingapproval", "pendingreview", "waiting", "waitingapproval", "submitted",
            "reviewing", "approvalrequired", "requiresapproval", "requiresreview", "workspacejoinpending"
        ].contains(normalized)
    }

    private static func isApprovedOrJoinedWorkspaceStatus(_ value: String) -> Bool {
        let normalized = normalizedWorkspaceStatus(value)
        return [
            "approved", "approve", "accepted", "pass", "passed", "through", "autoapproved", "autoaccepted",
            "autopassed", "workspacejoinapproved", "joined", "alreadyjoined", "workspacealreadyjoined",
            "active", "enabled", "normal"
        ].contains(normalized)
    }

    private static func isRejectedWorkspaceStatus(_ value: String) -> Bool {
        let normalized = normalizedWorkspaceStatus(value)
        return [
            "rejected", "reject", "denied", "declined", "refused", "workspacejoinrejected"
        ].contains(normalized)
    }

    private static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }
}

typealias RemoteEnterpriseContextTenantPresentation = IM4Data.RemoteEnterpriseContextTenantPresentation

// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
typealias RemoteAccount = IM4Data.RemoteAccount
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

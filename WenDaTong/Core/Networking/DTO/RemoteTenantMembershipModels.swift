// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation
import IM4Data

private func displayableTenantLogoURL(primary: String, fallback: String) -> String {
    let normalizedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedPrimary.isEmpty {
        return normalizedPrimary
    }
    let normalizedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedFallback.isEmpty else { return "" }
    if normalizedFallback.hasPrefix("/api/tenant/avatar/") || normalizedFallback.hasPrefix("//") {
        return normalizedFallback
    }
    guard let url = URL(string: normalizedFallback),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "data"].contains(scheme) else {
        return ""
    }
    return normalizedFallback
}

typealias RemoteTenant = IM4Data.RemoteTenant

extension RemoteTenant: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case code
        case name
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case status
        case logoURL = "logo_url"
        case logoUrl = "logoUrl"
        case logoStatus = "logo_status"
        case logoStatusCamel = "logoStatus"
        case logoVersion = "logo_version"
        case logoVersionCamel = "logoVersion"
        case logoUpdatedAt = "logo_updated_at"
        case logoUpdatedAtCamel = "logoUpdatedAt"
        case logoCacheKey = "logo_cache_key"
        case logoCacheKeyCamel = "logoCacheKey"
        case logoObjectKey = "logo_object_key"
        case logoMime = "logo_mime"
        case logoMimeCamel = "logoMime"
        case logoWidth = "logo_width"
        case logoWidthCamel = "logoWidth"
        case logoHeight = "logo_height"
        case logoHeightCamel = "logoHeight"
        case entryType = "entry_type"
        case entryTypeCamel = "entryType"
        case entryScheme = "scheme"
        case entryCanonical = "canonical"
        case inviterNickname = "inviter_nickname"
        case inviterNicknameCamel = "inviterNickname"
        case inviterDisplayName = "inviter_display_name"
        case inviterDisplayNameCamel = "inviterDisplayName"
    }

    init(profile: RemoteTenantProfile) {
        let id: String
        let tenantCode: String
        let name: String
        let status: String
        let logoURL: String
        let logoStatus: String
        let logoVersion: String
        let logoUpdatedAt: String
        let logoCacheKey: String
        let logoMime: String
        let logoWidth: Int?
        let logoHeight: Int?
        let entryType: String
        let entryScheme: String
        let entryCanonical: String
        let inviterNickname: String
        let inviterDisplayName: String
        id = profile.tenantID
        tenantCode = profile.tenantCode
        name = profile.name
        status = profile.status
        logoURL = profile.logoURL
        logoStatus = profile.logoStatus
        logoVersion = profile.logoVersion
        logoUpdatedAt = profile.logoUpdatedAt
        logoCacheKey = profile.logoCacheKey
        logoMime = profile.logoMime
        logoWidth = profile.logoWidth
        logoHeight = profile.logoHeight
        entryType = ""
        entryScheme = ""
        entryCanonical = ""
        inviterNickname = ""
        inviterDisplayName = ""
        self.init(id: id, tenantCode: tenantCode, name: name, status: status, logoURL: logoURL, logoStatus: logoStatus, logoVersion: logoVersion, logoUpdatedAt: logoUpdatedAt, logoCacheKey: logoCacheKey, logoMime: logoMime, logoWidth: logoWidth, logoHeight: logoHeight, entryType: entryType, entryScheme: entryScheme, entryCanonical: entryCanonical, inviterNickname: inviterNickname, inviterDisplayName: inviterDisplayName)
    }

    public init(from decoder: Decoder) throws {
        let id: String
        let tenantCode: String
        let name: String
        let status: String
        let logoURL: String
        let logoStatus: String
        let logoVersion: String
        let logoUpdatedAt: String
        let logoCacheKey: String
        let logoMime: String
        let logoWidth: Int?
        let logoHeight: Int?
        let entryType: String
        let entryScheme: String
        let entryCanonical: String
        let inviterNickname: String
        let inviterDisplayName: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .code)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        let decodedLogoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            ?? c.decodeIfPresent(String.self, forKey: .logoUrl)
            ?? ""
        let decodedLogoObjectKey = try c.decodeIfPresent(String.self, forKey: .logoObjectKey) ?? ""
        logoURL = displayableTenantLogoURL(primary: decodedLogoURL, fallback: decodedLogoObjectKey)
        logoStatus = try c.decodeIfPresent(String.self, forKey: .logoStatus)
            ?? c.decodeIfPresent(String.self, forKey: .logoStatusCamel)
            ?? ""
        logoVersion = try c.decodeIfPresent(String.self, forKey: .logoVersion)
            ?? c.decodeIfPresent(String.self, forKey: .logoVersionCamel)
            ?? ""
        logoUpdatedAt = try c.decodeIfPresent(String.self, forKey: .logoUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .logoUpdatedAtCamel)
            ?? ""
        logoCacheKey = try c.decodeIfPresent(String.self, forKey: .logoCacheKey)
            ?? c.decodeIfPresent(String.self, forKey: .logoCacheKeyCamel)
            ?? decodedLogoObjectKey
        logoMime = try c.decodeIfPresent(String.self, forKey: .logoMime)
            ?? c.decodeIfPresent(String.self, forKey: .logoMimeCamel)
            ?? ""
        logoWidth = c.decodeLossyIntIfPresent(forKey: .logoWidth)
            ?? c.decodeLossyIntIfPresent(forKey: .logoWidthCamel)
        logoHeight = c.decodeLossyIntIfPresent(forKey: .logoHeight)
            ?? c.decodeLossyIntIfPresent(forKey: .logoHeightCamel)
        entryType = try c.decodeIfPresent(String.self, forKey: .entryType)
            ?? c.decodeIfPresent(String.self, forKey: .entryTypeCamel)
            ?? ""
        entryScheme = try c.decodeIfPresent(String.self, forKey: .entryScheme) ?? ""
        entryCanonical = try c.decodeIfPresent(String.self, forKey: .entryCanonical) ?? ""
        inviterNickname = try c.decodeIfPresent(String.self, forKey: .inviterNickname)
            ?? c.decodeIfPresent(String.self, forKey: .inviterNicknameCamel)
            ?? ""
        inviterDisplayName = try c.decodeIfPresent(String.self, forKey: .inviterDisplayName)
            ?? c.decodeIfPresent(String.self, forKey: .inviterDisplayNameCamel)
            ?? ""
        self.init(id: id, tenantCode: tenantCode, name: name, status: status, logoURL: logoURL, logoStatus: logoStatus, logoVersion: logoVersion, logoUpdatedAt: logoUpdatedAt, logoCacheKey: logoCacheKey, logoMime: logoMime, logoWidth: logoWidth, logoHeight: logoHeight, entryType: entryType, entryScheme: entryScheme, entryCanonical: entryCanonical, inviterNickname: inviterNickname, inviterDisplayName: inviterDisplayName)
    }
}

private enum RemoteWorkspaceAdmissionReconciliation {
    static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    static func projectionReasonCode(status: String) -> String {
        let normalized = normalizedWorkspaceStatus(status)
        if ["missing", "pending", "queued", "syncing", "inprogress", "stale"].contains(normalized) {
            return "member_projection_syncing"
        }
        if ["failed", "failure", "error", "conflict", "rejected", "reject"].contains(normalized) {
            return "member_projection_failed"
        }
        return ""
    }

    static func isStaleMemberProjectionSyncingReady(
        reason: String,
        projectionStatus: String,
        joinStatus: String,
        applicationStatus: String,
        accountStatus: String = "",
        tenantStatus: String,
        memberStatus: String,
        role: String
    ) -> Bool {
        guard isMemberProjectionSyncingReason(reason),
              isProjectionReady(projectionStatus),
              !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard joinedStatusAllowsEntry(joinStatus),
              applicationStatusAllowsEntry(applicationStatus),
              accountStatusAllowsEntry(accountStatus),
              tenantStatusAllowsEntry(tenantStatus),
              memberStatusAllowsEntry(memberStatus) else {
            return false
        }
        return true
    }

    private static func isMemberProjectionSyncingReason(_ reason: String) -> Bool {
        switch normalizedWorkspaceStatus(reason) {
        case "memberprojectionsyncing", "memberprojectionpending", "memberprojectionmissing", "memberprojectionstale", "memberprojectionsync":
            return true
        default:
            return false
        }
    }

    private static func isProjectionReady(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "applied", "ready", "current", "synced", "synchronized", "complete", "completed", "success", "succeeded", "ok":
            return true
        default:
            return false
        }
    }

    private static func joinedStatusAllowsEntry(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "joined", "alreadyjoined", "workspacealreadyjoined", "active", "enabled", "normal", "approved", "accepted", "passed", "workspacejoinapproved":
            return true
        default:
            return false
        }
    }

    private static func applicationStatusAllowsEntry(_ status: String) -> Bool {
        let normalized = normalizedWorkspaceStatus(status)
        guard !normalized.isEmpty else { return true }
        switch normalized {
        case "approved", "accepted", "passed", "active", "enabled", "normal", "joined", "workspacejoinapproved":
            return true
        default:
            return false
        }
    }

    private static func accountStatusAllowsEntry(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "", "normal", "active", "enabled", "unlocked":
            return true
        default:
            return false
        }
    }

    private static func tenantStatusAllowsEntry(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "", "normal", "active", "enabled":
            return true
        default:
            return false
        }
    }

    private static func memberStatusAllowsEntry(_ status: String) -> Bool {
        switch normalizedWorkspaceStatus(status) {
        case "normal", "active", "enabled", "joined":
            return true
        default:
            return false
        }
    }
}

typealias RemoteTenantMembership = IM4Data.RemoteTenantMembership

extension RemoteTenantMembership: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case tenant
        case member
        case joinStatus = "join_status"
        case membershipStatus = "membership_status"
        case applicationID = "application_id"
        case applicationStatus = "application_status"
        case approvalRequired = "approval_required"
        case requiresApproval = "requires_approval"
        case canSwitch = "can_switch"
        case canEnter = "can_enter"
        case enterable
        case disabledReason = "disabled_reason"
        case reasonCode = "reason_code"
        case reasonText = "reason_text"
        case reasonMessage = "reason_message"
        case memberProjectionStatus = "member_projection_status"
        case memberProjectionStatusCamel = "memberProjectionStatus"
        case memberProjectionReasonCode = "member_projection_reason_code"
        case memberProjectionReasonCodeCamel = "memberProjectionReasonCode"
        case application
        case appID = "app_id"
        case appIDCamel = "appId"
        case appTenantBound = "app_tenant_bound"
        case appTenantBoundCamel = "appTenantBound"
        case appBindingStatus = "app_binding_status"
        case appBindingStatusCamel = "appBindingStatus"
    }

    enum ApplicationCodingKeys: String, CodingKey {
        case id
        case applicationID = "application_id"
        case status
        case applicationStatus = "application_status"
    }

    init(tenant: RemoteTenant, member: RemoteTenantMember) {
        let joinStatus: String
        let applicationID: String
        let applicationStatus: String
        let approvalRequired: Bool
        let canSwitch: Bool?
        let enterable: Bool?
        let disabledReason: String
        let appID: String
        let appTenantBound: Bool?
        let appBindingStatus: String
        joinStatus = member.status
        applicationID = ""
        applicationStatus = ""
        approvalRequired = false
        canSwitch = nil
        enterable = nil
        disabledReason = ""
        appID = ""
        appTenantBound = nil
        appBindingStatus = ""
        self.init(tenant: tenant, member: member, joinStatus: joinStatus, applicationID: applicationID, applicationStatus: applicationStatus, approvalRequired: approvalRequired, canSwitch: canSwitch, enterable: enterable, disabledReason: disabledReason, appID: appID, appTenantBound: appTenantBound, appBindingStatus: appBindingStatus)
    }

    public init(from decoder: Decoder) throws {
        let tenant: RemoteTenant
        let member: RemoteTenantMember
        let joinStatus: String
        let applicationID: String
        let applicationStatus: String
        let approvalRequired: Bool
        let canSwitch: Bool?
        let enterable: Bool?
        let disabledReason: String
        let appID: String
        let appTenantBound: Bool?
        let appBindingStatus: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try c.decodeIfPresent(RemoteTenant.self, forKey: .tenant)
            ?? RemoteTenant(from: decoder)
        member = try c.decodeIfPresent(RemoteTenantMember.self, forKey: .member)
            ?? RemoteTenantMember(from: decoder)
        let application = try? c.nestedContainer(keyedBy: ApplicationCodingKeys.self, forKey: .application)
        applicationID = try c.decodeIfPresent(String.self, forKey: .applicationID)
            ?? application?.decodeIfPresent(String.self, forKey: .id)
            ?? application?.decodeIfPresent(String.self, forKey: .applicationID)
            ?? ""
        applicationStatus = try c.decodeIfPresent(String.self, forKey: .applicationStatus)
            ?? application?.decodeIfPresent(String.self, forKey: .applicationStatus)
            ?? application?.decodeIfPresent(String.self, forKey: .status)
            ?? ""
        approvalRequired = c.decodeLossyBoolIfPresent(forKey: .approvalRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresApproval)
            ?? false
        let decodedJoinStatus = try c.decodeIfPresent(String.self, forKey: .joinStatus)
            ?? c.decodeIfPresent(String.self, forKey: .membershipStatus)
            ?? (applicationStatus.isEmpty ? member.status : applicationStatus)
        joinStatus = decodedJoinStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && approvalRequired
            ? "pending"
            : decodedJoinStatus
        let decodedCanSwitch = c.decodeLossyBoolIfPresent(forKey: .canSwitch)
        let decodedEnterable = c.decodeLossyBoolIfPresent(forKey: .enterable)
            ?? c.decodeLossyBoolIfPresent(forKey: .canEnter)
        let decodedDisabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason) ?? ""
        let decodedReasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode) ?? ""
        let decodedReasonText = try c.decodeIfPresent(String.self, forKey: .reasonText) ?? ""
        let decodedReasonMessage = try c.decodeIfPresent(String.self, forKey: .reasonMessage) ?? ""
        let decodedProjectionStatus = try c.decodeIfPresent(String.self, forKey: .memberProjectionStatus)
            ?? c.decodeIfPresent(String.self, forKey: .memberProjectionStatusCamel)
            ?? ""
        let projectionReason = try c.decodeIfPresent(String.self, forKey: .memberProjectionReasonCode)
            ?? c.decodeIfPresent(String.self, forKey: .memberProjectionReasonCodeCamel)
            ?? RemoteWorkspaceAdmissionReconciliation.projectionReasonCode(status: decodedProjectionStatus)
        let rawDisabledReason = [
            decodedDisabledReason,
            decodedReasonCode,
            projectionReason,
            decodedReasonText,
            decodedReasonMessage
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let projectionSyncingReasonIsStale = RemoteWorkspaceAdmissionReconciliation.isStaleMemberProjectionSyncingReady(
            reason: rawDisabledReason,
            projectionStatus: decodedProjectionStatus,
            joinStatus: joinStatus,
            applicationStatus: applicationStatus,
            tenantStatus: tenant.status,
            memberStatus: member.status,
            role: member.role
        )
        canSwitch = projectionSyncingReasonIsStale && decodedCanSwitch == false ? true : decodedCanSwitch
        enterable = projectionSyncingReasonIsStale && decodedEnterable == false ? true : decodedEnterable
        disabledReason = projectionSyncingReasonIsStale ? "" : rawDisabledReason
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        appTenantBound = c.decodeLossyBoolIfPresent(forKey: .appTenantBound)
            ?? c.decodeLossyBoolIfPresent(forKey: .appTenantBoundCamel)
        appBindingStatus = try c.decodeIfPresent(String.self, forKey: .appBindingStatus)
            ?? c.decodeIfPresent(String.self, forKey: .appBindingStatusCamel)
            ?? ""
        self.init(tenant: tenant, member: member, joinStatus: joinStatus, applicationID: applicationID, applicationStatus: applicationStatus, approvalRequired: approvalRequired, canSwitch: canSwitch, enterable: enterable, disabledReason: disabledReason, appID: appID, appTenantBound: appTenantBound, appBindingStatus: appBindingStatus)
    }

    private static func projectionReasonCode(status: String) -> String {
        let normalized = normalizedWorkspaceStatus(status)
        if ["missing", "pending", "queued", "syncing", "inprogress", "stale"].contains(normalized) {
            return "member_projection_syncing"
        }
        if ["failed", "failure", "error", "conflict", "rejected", "reject"].contains(normalized) {
            return "member_projection_failed"
        }
        return ""
    }

    private static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }
}

extension RemoteTenantMembership {
    var explicitlyNotBoundToApp: Bool {
        if appTenantBound == false {
            return true
        }
        let normalizedStatus = appBindingStatus
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        guard !normalizedStatus.isEmpty else { return false }
        return !["bound", "active", "enabled", "available", "ok"].contains(normalizedStatus)
    }

    func isVisibleInAppScope(_ expectedAppID: String) -> Bool {
        if explicitlyNotBoundToApp {
            return false
        }
        let normalizedExpected = IMAPIContext.normalizedIOSAppID(expectedAppID)
        let normalizedMembershipAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : IMAPIContext.normalizedIOSAppID(appID)
        if !normalizedMembershipAppID.isEmpty,
           normalizedMembershipAppID != normalizedExpected {
            return false
        }
        return true
    }
}

typealias RemoteWorkspaceTenant = IM4Data.RemoteWorkspaceTenant

extension RemoteWorkspaceTenant: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case code
        case name
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case status
        case logoURL = "logo_url"
        case logoUrl = "logoUrl"
        case logoStatus = "logo_status"
        case logoStatusCamel = "logoStatus"
        case logoVersion = "logo_version"
        case logoVersionCamel = "logoVersion"
        case logoUpdatedAt = "logo_updated_at"
        case logoUpdatedAtCamel = "logoUpdatedAt"
        case logoCacheKey = "logo_cache_key"
        case logoCacheKeyCamel = "logoCacheKey"
        case logoObjectKey = "logo_object_key"
        case logoMime = "logo_mime"
        case logoMimeCamel = "logoMime"
        case logoWidth = "logo_width"
        case logoWidthCamel = "logoWidth"
        case logoHeight = "logo_height"
        case logoHeightCamel = "logoHeight"
        case joinStatus = "join_status"
        case membershipStatus = "membership_status"
        case memberRole = "member_role"
        case applicationID = "application_id"
        case applicationStatus = "application_status"
        case approvalRequired = "approval_required"
        case requiresApproval = "requires_approval"
        case current
        case canSwitch = "can_switch"
        case canEnter = "can_enter"
        case accountStatus = "account_status"
        case tenantStatus = "tenant_status"
        case memberStatus = "member_status"
        case enterable
        case disabledReason = "disabled_reason"
        case reasonCode = "reason_code"
        case reasonText = "reason_text"
        case reasonMessage = "reason_message"
        case memberProjectionStatus = "member_projection_status"
        case memberProjectionStatusCamel = "memberProjectionStatus"
        case memberProjectionReasonCode = "member_projection_reason_code"
        case memberProjectionReasonCodeCamel = "memberProjectionReasonCode"
    }

    public init(from decoder: Decoder) throws {
        let id: String
        let tenantCode: String
        let name: String
        let status: String
        let logoURL: String
        let logoStatus: String
        let logoVersion: String
        let logoUpdatedAt: String
        let logoCacheKey: String
        let logoMime: String
        let logoWidth: Int?
        let logoHeight: Int?
        let joinStatus: String
        let memberRole: String
        let applicationID: String
        let applicationStatus: String
        let approvalRequired: Bool
        let current: Bool
        let canSwitch: Bool
        let accountStatus: String
        let tenantStatus: String
        let memberStatus: String
        let enterable: Bool?
        let disabledReason: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .code)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        let decodedLogoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            ?? c.decodeIfPresent(String.self, forKey: .logoUrl)
            ?? ""
        let decodedLogoObjectKey = try c.decodeIfPresent(String.self, forKey: .logoObjectKey) ?? ""
        logoURL = displayableTenantLogoURL(primary: decodedLogoURL, fallback: decodedLogoObjectKey)
        logoStatus = try c.decodeIfPresent(String.self, forKey: .logoStatus)
            ?? c.decodeIfPresent(String.self, forKey: .logoStatusCamel)
            ?? ""
        logoVersion = try c.decodeIfPresent(String.self, forKey: .logoVersion)
            ?? c.decodeIfPresent(String.self, forKey: .logoVersionCamel)
            ?? ""
        logoUpdatedAt = try c.decodeIfPresent(String.self, forKey: .logoUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .logoUpdatedAtCamel)
            ?? ""
        logoCacheKey = try c.decodeIfPresent(String.self, forKey: .logoCacheKey)
            ?? c.decodeIfPresent(String.self, forKey: .logoCacheKeyCamel)
            ?? decodedLogoObjectKey
        logoMime = try c.decodeIfPresent(String.self, forKey: .logoMime)
            ?? c.decodeIfPresent(String.self, forKey: .logoMimeCamel)
            ?? ""
        logoWidth = c.decodeLossyIntIfPresent(forKey: .logoWidth)
            ?? c.decodeLossyIntIfPresent(forKey: .logoWidthCamel)
        logoHeight = c.decodeLossyIntIfPresent(forKey: .logoHeight)
            ?? c.decodeLossyIntIfPresent(forKey: .logoHeightCamel)
        let decodedJoinStatus = try c.decodeIfPresent(String.self, forKey: .joinStatus)
            ?? c.decodeIfPresent(String.self, forKey: .membershipStatus)
            ?? ""
        memberRole = try c.decodeIfPresent(String.self, forKey: .memberRole) ?? ""
        applicationID = try c.decodeIfPresent(String.self, forKey: .applicationID) ?? ""
        applicationStatus = try c.decodeIfPresent(String.self, forKey: .applicationStatus) ?? ""
        approvalRequired = c.decodeLossyBoolIfPresent(forKey: .approvalRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresApproval)
            ?? false
        joinStatus = decodedJoinStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && approvalRequired
            ? "pending"
            : decodedJoinStatus
        current = c.decodeLossyBoolIfPresent(forKey: .current) ?? false
        accountStatus = try c.decodeIfPresent(String.self, forKey: .accountStatus) ?? ""
        tenantStatus = try c.decodeIfPresent(String.self, forKey: .tenantStatus) ?? status
        memberStatus = try c.decodeIfPresent(String.self, forKey: .memberStatus) ?? joinStatus
        let decodedEnterable = c.decodeLossyBoolIfPresent(forKey: .enterable)
            ?? c.decodeLossyBoolIfPresent(forKey: .canEnter)
        let decodedDisabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason) ?? ""
        let decodedReasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode) ?? ""
        let decodedReasonText = try c.decodeIfPresent(String.self, forKey: .reasonText) ?? ""
        let decodedReasonMessage = try c.decodeIfPresent(String.self, forKey: .reasonMessage) ?? ""
        let decodedProjectionStatus = try c.decodeIfPresent(String.self, forKey: .memberProjectionStatus)
            ?? c.decodeIfPresent(String.self, forKey: .memberProjectionStatusCamel)
            ?? ""
        let projectionReason = try c.decodeIfPresent(String.self, forKey: .memberProjectionReasonCode)
            ?? c.decodeIfPresent(String.self, forKey: .memberProjectionReasonCodeCamel)
            ?? RemoteWorkspaceAdmissionReconciliation.projectionReasonCode(status: decodedProjectionStatus)
        let rawDisabledReason = [
            decodedDisabledReason,
            decodedReasonCode,
            projectionReason,
            decodedReasonText,
            decodedReasonMessage
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let decodedCanSwitch = c.decodeLossyBoolIfPresent(forKey: .canSwitch)
        let normalizedJoinStatus = Self.normalizedWorkspaceStatus(joinStatus)
        let normalizedAccountStatus = Self.normalizedWorkspaceStatus(accountStatus)
        let normalizedTenantStatus = Self.normalizedWorkspaceStatus(tenantStatus)
        let normalizedMemberStatus = Self.normalizedWorkspaceStatus(memberStatus)
        let activeAccountStatuses = ["", "normal", "active", "enabled"]
        let activeTenantStatuses = ["", "normal", "active", "enabled"]
        let activeMemberStatuses = ["", "normal", "active", "enabled", "joined"]
        let statusAllowsEntry = activeAccountStatuses.contains(normalizedAccountStatus)
            && activeTenantStatuses.contains(normalizedTenantStatus)
            && activeMemberStatuses.contains(normalizedMemberStatus)
        let fallbackCanSwitch = decodedCanSwitch ?? ["joined", "alreadyjoined", "approved", "autoapproved", "accepted", "passed", "active", "enabled", "normal"].contains(normalizedJoinStatus)
        let projectionSyncingReasonIsStale = RemoteWorkspaceAdmissionReconciliation.isStaleMemberProjectionSyncingReady(
            reason: rawDisabledReason,
            projectionStatus: decodedProjectionStatus,
            joinStatus: joinStatus,
            applicationStatus: applicationStatus,
            accountStatus: accountStatus,
            tenantStatus: tenantStatus,
            memberStatus: memberStatus,
            role: memberRole
        )
        disabledReason = projectionSyncingReasonIsStale ? "" : rawDisabledReason
        enterable = projectionSyncingReasonIsStale && decodedEnterable == false ? true : decodedEnterable
        canSwitch = projectionSyncingReasonIsStale && decodedCanSwitch == false
            ? true
            : (decodedCanSwitch ?? (enterable ?? (fallbackCanSwitch && statusAllowsEntry)))
        self.init(id: id, tenantCode: tenantCode, name: name, status: status, logoURL: logoURL, logoStatus: logoStatus, logoVersion: logoVersion, logoUpdatedAt: logoUpdatedAt, logoCacheKey: logoCacheKey, logoMime: logoMime, logoWidth: logoWidth, logoHeight: logoHeight, joinStatus: joinStatus, memberRole: memberRole, applicationID: applicationID, applicationStatus: applicationStatus, approvalRequired: approvalRequired, current: current, canSwitch: canSwitch, accountStatus: accountStatus, tenantStatus: tenantStatus, memberStatus: memberStatus, enterable: enterable, disabledReason: disabledReason)
    }

    private static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    private static func projectionReasonCode(status: String) -> String {
        let normalized = normalizedWorkspaceStatus(status)
        if ["missing", "pending", "queued", "syncing", "inprogress", "stale"].contains(normalized) {
            return "member_projection_syncing"
        }
        if ["failed", "failure", "error", "conflict", "rejected", "reject"].contains(normalized) {
            return "member_projection_failed"
        }
        return ""
    }
}

typealias RemoteApp = IM4Data.RemoteApp

typealias RemoteTenantProfile = IM4Data.RemoteTenantProfile

extension RemoteTenantProfile: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case id
        case tenantCode = "tenant_code"
        case tenantCodeCamel = "tenantCode"
        case code
        case name
        case tenantName = "tenant_name"
        case tenantNameCamel = "tenantName"
        case status
        case logoURL = "logo_url"
        case logoUrl = "logoUrl"
        case logoStatus = "logo_status"
        case logoStatusCamel = "logoStatus"
        case logoVersion = "logo_version"
        case logoVersionCamel = "logoVersion"
        case logoUpdatedAt = "logo_updated_at"
        case logoUpdatedAtCamel = "logoUpdatedAt"
        case logoCacheKey = "logo_cache_key"
        case logoCacheKeyCamel = "logoCacheKey"
        case logoObjectKey = "logo_object_key"
        case logoMime = "logo_mime"
        case logoMimeCamel = "logoMime"
        case logoWidth = "logo_width"
        case logoWidthCamel = "logoWidth"
        case logoHeight = "logo_height"
        case logoHeightCamel = "logoHeight"
    }

    public init(from decoder: Decoder) throws {
        let tenantID: String
        let tenantCode: String
        let name: String
        let status: String
        let logoURL: String
        let logoStatus: String
        let logoVersion: String
        let logoUpdatedAt: String
        let logoCacheKey: String
        let logoMime: String
        let logoWidth: Int?
        let logoHeight: Int?
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        tenantCode = try c.decodeIfPresent(String.self, forKey: .tenantCode)
            ?? c.decodeIfPresent(String.self, forKey: .tenantCodeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .code)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .tenantName)
            ?? c.decodeIfPresent(String.self, forKey: .tenantNameCamel)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        let decodedLogoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
            ?? c.decodeIfPresent(String.self, forKey: .logoUrl)
            ?? ""
        let decodedLogoObjectKey = try c.decodeIfPresent(String.self, forKey: .logoObjectKey) ?? ""
        logoURL = displayableTenantLogoURL(primary: decodedLogoURL, fallback: decodedLogoObjectKey)
        logoStatus = try c.decodeIfPresent(String.self, forKey: .logoStatus)
            ?? c.decodeIfPresent(String.self, forKey: .logoStatusCamel)
            ?? ""
        logoVersion = try c.decodeIfPresent(String.self, forKey: .logoVersion)
            ?? c.decodeIfPresent(String.self, forKey: .logoVersionCamel)
            ?? ""
        logoUpdatedAt = try c.decodeIfPresent(String.self, forKey: .logoUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .logoUpdatedAtCamel)
            ?? ""
        logoCacheKey = try c.decodeIfPresent(String.self, forKey: .logoCacheKey)
            ?? c.decodeIfPresent(String.self, forKey: .logoCacheKeyCamel)
            ?? decodedLogoObjectKey
        logoMime = try c.decodeIfPresent(String.self, forKey: .logoMime)
            ?? c.decodeIfPresent(String.self, forKey: .logoMimeCamel)
            ?? ""
        logoWidth = c.decodeLossyIntIfPresent(forKey: .logoWidth)
            ?? c.decodeLossyIntIfPresent(forKey: .logoWidthCamel)
        logoHeight = c.decodeLossyIntIfPresent(forKey: .logoHeight)
            ?? c.decodeLossyIntIfPresent(forKey: .logoHeightCamel)
        self.init(tenantID: tenantID, tenantCode: tenantCode, name: name, status: status, logoURL: logoURL, logoStatus: logoStatus, logoVersion: logoVersion, logoUpdatedAt: logoUpdatedAt, logoCacheKey: logoCacheKey, logoMime: logoMime, logoWidth: logoWidth, logoHeight: logoHeight)
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

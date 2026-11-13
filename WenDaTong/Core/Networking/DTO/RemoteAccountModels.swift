import Foundation
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
typealias RemoteMeProfile = IM4Data.RemoteMeProfile
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
typealias RemoteAccountCancellationResponse = IM4Data.RemoteAccountCancellationResponse
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
typealias RemotePasswordChangeResponse = IM4Data.RemotePasswordChangeResponse
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteTenantContext = IM4Data.RemoteTenantContext

extension RemoteTenantContext: @retroactive Decodable {
    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case id
        case imUID = "im_uid"
        case appID = "app_id"
        case deviceID = "device_id"
        case tenant
        case user
        case tenantPolicy = "tenant_policy"
        case tenantPolicyCamel = "tenantPolicy"
        case organization
    }

    enum TenantPolicyCodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
        case organization
    }

    enum OrganizationCodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
    }

    public init(from decoder: Decoder) throws {
        let tenantID: String
        let imUID: String
        let appID: String
        let deviceID: String
        let tenant: RemoteTenantProfile
        let user: RemoteIMUser?
        let departmentEnabled: Bool?
        let clientPolicy: RemoteTenantClientPolicy?
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        if let nestedTenant = try c.decodeIfPresent(RemoteTenantProfile.self, forKey: .tenant) {
            tenant = nestedTenant
        } else {
            tenant = try RemoteTenantProfile(from: decoder)
        }
        user = try c.decodeIfPresent(RemoteIMUser.self, forKey: .user)
        clientPolicy = try c.decodeIfPresent(RemoteTenantClientPolicy.self, forKey: .tenantPolicy)
            ?? c.decodeIfPresent(RemoteTenantClientPolicy.self, forKey: .tenantPolicyCamel)
        let policy = (try? c.nestedContainer(keyedBy: TenantPolicyCodingKeys.self, forKey: .tenantPolicy))
            ?? (try? c.nestedContainer(keyedBy: TenantPolicyCodingKeys.self, forKey: .tenantPolicyCamel))
        let policyOrganization = policy.flatMap {
            try? $0.nestedContainer(keyedBy: OrganizationCodingKeys.self, forKey: .organization)
        }
        let rootOrganization = try? c.nestedContainer(keyedBy: OrganizationCodingKeys.self, forKey: .organization)
        departmentEnabled = policy?.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? policy?.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? policyOrganization?.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? policyOrganization?.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? rootOrganization?.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? rootOrganization?.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
        self.init(
            wireTenantID: tenantID,
            imUID: imUID,
            appID: appID,
            deviceID: deviceID,
            tenant: tenant,
            user: user,
            departmentEnabled: departmentEnabled,
            clientPolicy: clientPolicy
        )
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteTenantClientPolicy = IM4Data.RemoteTenantClientPolicy
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
typealias RemotePasswordResetResponse = IM4Data.RemotePasswordResetResponse
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

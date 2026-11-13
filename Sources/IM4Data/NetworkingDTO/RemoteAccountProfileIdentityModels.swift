// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
import Foundation

public struct RemoteAccount: Decodable, Sendable {
    public let id: String
    public let username: String
    public let nickname: String
    public let phone: String
    public let phoneVerified: Bool
    public let phoneBindingKnown: Bool
    public let realNameVerified: Bool
    public let realNameStatus: String
    public let role: String
    public let status: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
            ?? c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
            ?? c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? ""
        let verifiedAt = try c.decodeIfPresent(String.self, forKey: .phoneVerifiedAt) ?? ""
        let explicitPhoneVerified = decodeFlexibleBoolIfPresent(c, keys: [.phoneVerified, .phoneBound, .mobileVerified])
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        phoneVerified = explicitPhoneVerified
            ?? (!verifiedAt.isEmpty || !normalizedPhone.isEmpty)
        phoneBindingKnown = explicitPhoneVerified != nil || !verifiedAt.isEmpty || !normalizedPhone.isEmpty
        realNameStatus = try c.decodeIfPresent(String.self, forKey: .realNameStatus)
            ?? c.decodeIfPresent(String.self, forKey: .kycStatus)
            ?? c.decodeIfPresent(String.self, forKey: .kyc)
            ?? ""
        realNameVerified = decodeFlexibleBool(c, keys: [.realNameVerified])
            || ["verified", "approved", "passed", "success", "认证通过", "已认证"].contains(realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, username, nickname, phone, role, status
        case phoneMasked = "phone_masked"
        case displayName = "display_name"
        case name
        case phoneVerified = "phone_verified"
        case phoneVerifiedAt = "phone_verified_at"
        case phoneBound = "phone_bound"
        case mobileVerified = "mobile_verified"
        case realNameVerified = "real_name_verified"
        case realNameStatus = "real_name_status"
        case kycStatus = "kyc_status"
        case kyc
    }
}

public struct RemoteIMUser: Decodable, Sendable {
    public let tenantID: String
    public let imUID: String
    public let userID: String
    public let username: String
    public let accountID: String
    public let nickname: String
    public let userRevision: Int64?
    public let identityGeneration: Int64?
    public let phone: String
    public let phoneVerified: Bool
    public let phoneBindingKnown: Bool
    public let realNameVerified: Bool
    public let realNameStatus: String
    public let status: String
    public let presenceStatus: String
    public let online: Bool
    public let onlineKnown: Bool
    public let lastSeenAt: String
    public let role: String
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let departmentName: String
    public let departmentPath: [String]
    public let departmentPathNames: [String]

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantID"
        case imUID = "im_uid"
        case userID = "user_id"
        case username
        case accountID = "account_id"
        case nickname
        case userRevision = "user_revision"
        case userRevisionCamel = "userRevision"
        case identityGeneration = "identity_generation"
        case identityGenerationCamel = "identityGeneration"
        case phone
        case phoneMasked = "phone_masked"
        case phoneVerified = "phone_verified"
        case phoneVerifiedAt = "phone_verified_at"
        case phoneBound = "phone_bound"
        case mobileVerified = "mobile_verified"
        case realNameVerified = "real_name_verified"
        case realNameStatus = "real_name_status"
        case kycStatus = "kyc_status"
        case kyc
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case role
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        userRevision = c.decodeLossyInt64IfPresent(forKey: .userRevision)
            ?? c.decodeLossyInt64IfPresent(forKey: .userRevisionCamel)
        identityGeneration = c.decodeLossyInt64IfPresent(forKey: .identityGeneration)
            ?? c.decodeLossyInt64IfPresent(forKey: .identityGenerationCamel)
        phone = try c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? c.decodeIfPresent(String.self, forKey: .phone)
            ?? ""
        let verifiedAt = try c.decodeIfPresent(String.self, forKey: .phoneVerifiedAt) ?? ""
        let explicitPhoneVerified = decodeFlexibleBoolIfPresent(c, keys: [.phoneVerified, .phoneBound, .mobileVerified])
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        phoneVerified = explicitPhoneVerified
            ?? (!verifiedAt.isEmpty || !normalizedPhone.isEmpty)
        phoneBindingKnown = explicitPhoneVerified != nil || !verifiedAt.isEmpty || !normalizedPhone.isEmpty
        realNameStatus = try c.decodeIfPresent(String.self, forKey: .realNameStatus)
            ?? c.decodeIfPresent(String.self, forKey: .kycStatus)
            ?? c.decodeIfPresent(String.self, forKey: .kyc)
            ?? ""
        realNameVerified = decodeFlexibleBool(c, keys: [.realNameVerified])
            || ["verified", "approved", "passed", "success", "认证通过", "已认证"].contains(realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        presenceStatus = try c.decodeIfPresent(String.self, forKey: .presenceStatus) ?? ""
        let decodedOnline = c.decodeLossyBoolIfPresent(forKey: .online)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
        online = decodedOnline ?? false
        onlineKnown = decodedOnline != nil
        lastSeenAt = [
            try c.decodeIfPresent(String.self, forKey: .lastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAt),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAtCamel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
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
        departmentName = try c.decodeIfPresent(String.self, forKey: .departmentName)
            ?? c.decodeIfPresent(String.self, forKey: .departmentNameCamel)
            ?? ""
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
    }
}

public struct RemoteMeProfile: Decodable, Sendable {
    public let tenantID: String
    public let imUID: String
    public let userID: String
    public let username: String
    public let nickname: String
    public let userRevision: Int64?
    public let identityGeneration: Int64?
    public let phone: String
    public let phoneVerified: Bool
    public let phoneBindingKnown: Bool
    public let status: String
    public let presenceStatus: String
    public let online: Bool
    public let onlineKnown: Bool
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let departmentName: String
    public let departmentPath: [String]
    public let departmentPathNames: [String]

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantID"
        case imUID = "im_uid"
        case userID = "user_id"
        case username
        case nickname
        case userRevision = "user_revision"
        case userRevisionCamel = "userRevision"
        case identityGeneration = "identity_generation"
        case identityGenerationCamel = "identityGeneration"
        case phone
        case phoneMasked = "phone_masked"
        case phoneVerified = "phone_verified"
        case phoneVerifiedAt = "phone_verified_at"
        case phoneBound = "phone_bound"
        case mobileVerified = "mobile_verified"
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        userRevision = c.decodeLossyInt64IfPresent(forKey: .userRevision)
            ?? c.decodeLossyInt64IfPresent(forKey: .userRevisionCamel)
        identityGeneration = c.decodeLossyInt64IfPresent(forKey: .identityGeneration)
            ?? c.decodeLossyInt64IfPresent(forKey: .identityGenerationCamel)
        phone = try c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? c.decodeIfPresent(String.self, forKey: .phone)
            ?? ""
        let phoneVerifiedAt = try c.decodeIfPresent(String.self, forKey: .phoneVerifiedAt) ?? ""
        let explicitPhoneVerified = decodeFlexibleBoolIfPresent(c, keys: [.phoneVerified, .phoneBound, .mobileVerified])
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        phoneVerified = explicitPhoneVerified
            ?? (!phoneVerifiedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !normalizedPhone.isEmpty)
        phoneBindingKnown = explicitPhoneVerified != nil
            || !phoneVerifiedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !normalizedPhone.isEmpty
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        presenceStatus = try c.decodeIfPresent(String.self, forKey: .presenceStatus) ?? ""
        let decodedOnline = c.decodeLossyBoolIfPresent(forKey: .online)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
        online = decodedOnline ?? false
        onlineKnown = decodedOnline != nil
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
        departmentName = try c.decodeIfPresent(String.self, forKey: .departmentName)
            ?? c.decodeIfPresent(String.self, forKey: .departmentNameCamel)
            ?? ""
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
    }
}
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END

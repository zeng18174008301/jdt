// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
import Foundation

public struct RemoteDepartmentNode: Decodable, Identifiable, Hashable, Sendable { // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
    public let departmentID: String
    public let parentDepartmentID: String
    public let name: String
    public let status: String
    public let isVirtual: Bool
    public let departmentPath: [String]
    public let departmentPathNames: [String]
    public let depth: Int
    public let memberCount: Int
    public let children: [RemoteDepartmentNode]

    public var id: String { departmentID }

    enum CodingKeys: String, CodingKey {
        case departmentID = "department_id"
        case departmentIDCamel = "departmentId"
        case id
        case parentDepartmentID = "parent_department_id"
        case parentDepartmentIDCamel = "parentDepartmentId"
        case parentID = "parent_id"
        case name
        case status
        case isVirtual = "is_virtual"
        case isVirtualCamel = "isVirtual"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
        case depth
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        departmentID = try c.decodeIfPresent(String.self, forKey: .departmentID)
            ?? c.decodeIfPresent(String.self, forKey: .departmentIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        parentDepartmentID = try c.decodeIfPresent(String.self, forKey: .parentDepartmentID)
            ?? c.decodeIfPresent(String.self, forKey: .parentDepartmentIDCamel)
            ?? c.decodeIfPresent(String.self, forKey: .parentID)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        isVirtual = c.decodeLossyBoolIfPresent(forKey: .isVirtual)
            ?? c.decodeLossyBoolIfPresent(forKey: .isVirtualCamel)
            ?? false
        departmentPath = try c.decodeIfPresent([String].self, forKey: .departmentPath)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathCamel)
            ?? []
        departmentPathNames = try c.decodeIfPresent([String].self, forKey: .departmentPathNames)
            ?? c.decodeIfPresent([String].self, forKey: .departmentPathNamesCamel)
            ?? []
        depth = c.decodeLossyIntIfPresent(forKey: .depth) ?? 0
        memberCount = c.decodeLossyIntIfPresent(forKey: .memberCount)
            ?? c.decodeLossyIntIfPresent(forKey: .memberCountCamel)
            ?? 0
        children = try c.decodeIfPresent([RemoteDepartmentNode].self, forKey: .children) ?? []
    }
}

public struct RemoteOrganizationTree: Decodable, Equatable, Sendable { // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110 · WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
    public let departmentEnabled: Bool
    public let canManage: Bool
    public let canManageDepartment: Bool
    public let root: RemoteDepartmentNode?
    public let items: [RemoteDepartmentNode]

    enum CodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
        case canManage = "can_manage"
        case canManageCamel = "canManage"
        case canManageDepartment = "can_manage_department"
        case canManageDepartmentCamel = "canManageDepartment"
        case root
        case items
    }

    public init(departmentEnabled: Bool, canManage: Bool = false, canManageDepartment: Bool = false, root: RemoteDepartmentNode?, items: [RemoteDepartmentNode]) {
        self.departmentEnabled = departmentEnabled
        self.canManage = canManage
        self.canManageDepartment = canManageDepartment
        self.root = root
        self.items = items
    }

    public static func disabledFallback(root: RemoteDepartmentNode?) -> RemoteOrganizationTree {
        RemoteOrganizationTree(departmentEnabled: false, root: root, items: [])
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        departmentEnabled = c.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? false
        canManage = c.decodeLossyBoolIfPresent(forKey: .canManage)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageCamel)
            ?? false
        canManageDepartment = c.decodeLossyBoolIfPresent(forKey: .canManageDepartment)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageDepartmentCamel)
            ?? canManage
        root = try c.decodeIfPresent(RemoteDepartmentNode.self, forKey: .root)
        items = try c.decodeIfPresent([RemoteDepartmentNode].self, forKey: .items) ?? []
    }
}

public struct RemoteOrganizationMemberView: Decodable, Identifiable, Hashable, Sendable { // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
    public let imUID: String
    public let userID: String
    public let nickname: String
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let role: String
    public let status: String
    public let presenceStatus: String
    public let online: Bool
    public let onlineKnown: Bool
    public let lastSeenAt: String
    public let departmentID: String
    public let departmentName: String
    public let departmentPath: [String]
    public let departmentPathNames: [String]
    public let positionName: String
    public let isPrimary: Bool
    public let sortOrder: Int
    public let createdAt: String

    public var id: String { imUID.isEmpty ? userID : imUID }

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case nickname
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case role
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case departmentID = "department_id"
        case departmentIDCamel = "departmentId"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
        case positionName = "position_name"
        case positionNameCamel = "positionName"
        case isPrimary = "is_primary"
        case isPrimaryCamel = "isPrimary"
        case sortOrder = "sort_order"
        case sortOrderCamel = "sortOrder"
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
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
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
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
        departmentID = try c.decodeIfPresent(String.self, forKey: .departmentID)
            ?? c.decodeIfPresent(String.self, forKey: .departmentIDCamel)
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
        positionName = try c.decodeIfPresent(String.self, forKey: .positionName)
            ?? c.decodeIfPresent(String.self, forKey: .positionNameCamel)
            ?? ""
        isPrimary = c.decodeLossyBoolIfPresent(forKey: .isPrimary)
            ?? c.decodeLossyBoolIfPresent(forKey: .isPrimaryCamel)
            ?? false
        sortOrder = c.decodeLossyIntIfPresent(forKey: .sortOrder)
            ?? c.decodeLossyIntIfPresent(forKey: .sortOrderCamel)
            ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtCamel)
            ?? ""
    }
}

public struct RemoteOrganizationMemberList: Decodable, Sendable { // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
    public let departmentEnabled: Bool
    public let canManage: Bool
    public let canManageDepartment: Bool
    public let departmentID: String
    public let items: [RemoteOrganizationMemberView]

    enum CodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
        case canManage = "can_manage"
        case canManageCamel = "canManage"
        case canManageDepartment = "can_manage_department"
        case canManageDepartmentCamel = "canManageDepartment"
        case departmentID = "department_id"
        case departmentIDCamel = "departmentId"
        case items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        departmentEnabled = c.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? false
        canManage = c.decodeLossyBoolIfPresent(forKey: .canManage)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageCamel)
            ?? false
        canManageDepartment = c.decodeLossyBoolIfPresent(forKey: .canManageDepartment)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageDepartmentCamel)
            ?? canManage
        departmentID = try c.decodeIfPresent(String.self, forKey: .departmentID)
            ?? c.decodeIfPresent(String.self, forKey: .departmentIDCamel)
            ?? "company"
        items = try c.decodeIfPresent([RemoteOrganizationMemberView].self, forKey: .items) ?? []
    }
}
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_BEGIN
import Foundation

public struct RemoteGroupMemberProfile: Decodable, Sendable {
    public let contractVersion: Int
    public let groupID: String
    public let imUID: String
    public let groupNickname: String
    public let rawNickname: String
    public let displayName: String
    public let displayNameSource: String
    public let revision: Int64
    public let groupMembershipGeneration: Int64
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case groupID = "group_id"
        case imUID = "im_uid"
        case groupNickname = "group_nickname"
        case rawNickname = "raw_nickname"
        case displayName = "display_name"
        case displayNameSource = "display_name_source"
        case revision
        case groupMembershipGeneration = "group_membership_generation"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = c.decodeLossyIntIfPresent(forKey: .contractVersion) ?? 0
        groupID = (try c.decodeIfPresent(String.self, forKey: .groupID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        imUID = (try c.decodeIfPresent(String.self, forKey: .imUID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        groupNickname = (try c.decodeIfPresent(String.self, forKey: .groupNickname) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        rawNickname = (try c.decodeIfPresent(String.self, forKey: .rawNickname) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = (try c.decodeIfPresent(String.self, forKey: .displayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayNameSource = (try c.decodeIfPresent(String.self, forKey: .displayNameSource) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        revision = c.decodeLossyInt64IfPresent(forKey: .revision) ?? 0
        groupMembershipGeneration = c.decodeLossyInt64IfPresent(forKey: .groupMembershipGeneration) ?? revision
        updatedAt = (try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RemoteUserGroupMember: Decodable, Sendable {
    public let memberID: String
    public let imUID: String
    public let userID: String
    public let accountID: String
    public let nickname: String
    public let displayName: String
    public let rawNickname: String
    public let displayNameSource: String
    public let remark: String
    public let groupNickname: String
    public let revision: Int64
    public let groupMembershipGeneration: Int64
    public let phone: String
    public let phoneMasked: String
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let status: String
    public let presenceStatus: String
    public let online: Bool
    public let onlineKnown: Bool
    public let lastSeenAt: String
    public let role: String
    public let isOwner: Bool
    public let isAdmin: Bool
    public let joinedAt: String?
    public let departmentName: String
    public let departmentPath: [String]
    public let departmentPathNames: [String]

    public var visiblePhone: String {
        phoneMasked.isEmpty ? phone : phoneMasked
    }

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case imUID = "im_uid"
        case userID = "user_id"
        case accountID = "account_id"
        case memberUID = "member_uid"
        case uid
        case nickname
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case rawNickname = "raw_nickname"
        case rawNicknameCamel = "rawNickname"
        case displayNameSource = "display_name_source"
        case displayNameSourceCamel = "displayNameSource"
        case remark
        case groupNickname = "group_nickname"
        case revision
        case groupMembershipGeneration = "group_membership_generation"
        case phone
        case phoneMasked = "phone_masked"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
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
        case isOwner = "is_owner"
        case isAdmin = "is_admin"
        case joinedAt = "joined_at"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberID = (try c.decodeIfPresent(String.self, forKey: .memberID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedIMUID = [
            try c.decodeIfPresent(String.self, forKey: .imUID),
            try c.decodeIfPresent(String.self, forKey: .userID),
            try c.decodeIfPresent(String.self, forKey: .memberUID),
            try c.decodeIfPresent(String.self, forKey: .uid)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        imUID = decodedIMUID
        userID = [
            try c.decodeIfPresent(String.self, forKey: .userID),
            decodedIMUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        accountID = (try c.decodeIfPresent(String.self, forKey: .accountID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        nickname = (try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .nickname)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rawNickname = (try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? nickname).trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = (try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        displayNameSource = (try c.decodeIfPresent(String.self, forKey: .displayNameSource)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameSourceCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        remark = (try c.decodeIfPresent(String.self, forKey: .remark) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        groupNickname = (try c.decodeIfPresent(String.self, forKey: .groupNickname) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        revision = c.decodeLossyInt64IfPresent(forKey: .revision) ?? 0
        groupMembershipGeneration = c.decodeLossyInt64IfPresent(forKey: .groupMembershipGeneration) ?? revision
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        phoneMasked = try c.decodeIfPresent(String.self, forKey: .phoneMasked) ?? ""
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
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "member"
        isOwner = (try c.decodeIfPresent(Bool.self, forKey: .isOwner)) ?? (role == "owner")
        isAdmin = (try c.decodeIfPresent(Bool.self, forKey: .isAdmin)) ?? (role == "admin" || role == "owner")
        joinedAt = try c.decodeIfPresent(String.self, forKey: .joinedAt)
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

public struct RemoteGroupAnnouncementList: Decodable, Sendable {
    public let items: [RemoteGroupAnnouncement]
    public let current: RemoteGroupAnnouncement?
    public let topBanner: RemoteGroupAnnouncement?

    enum CodingKeys: String, CodingKey {
        case items
        case current
        case topBanner = "top_banner"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteGroupAnnouncement].self, forKey: .items) ?? []
        current = try c.decodeIfPresent(RemoteGroupAnnouncement.self, forKey: .current)
        topBanner = try c.decodeIfPresent(RemoteGroupAnnouncement.self, forKey: .topBanner)
    }
}

public struct RemoteGroupAnnouncement: Decodable, Sendable {
    public let id: String
    public let groupID: String
    public let title: String
    public let content: String
    public let createdBy: String
    public let status: String
    public let summary: String
    public let createdAt: String?
    public let updatedAt: String?
    public let publishedAt: String?
    public let unread: Bool
    public let readAt: String?
    public let displayPosition: String
    public let readAction: String
    public let readCount: Int?
    public let unreadCount: Int?
    public let recipientCount: Int?
    public let canViewReadCounts: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case announcementID = "announcement_id"
        case groupID = "group_id"
        case title
        case content
        case createdBy = "created_by"
        case status
        case summary
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case publishedAt = "published_at"
        case unread
        case readAt = "read_at"
        case displayPosition = "display_position"
        case readAction = "read_action"
        case readCount = "read_count"
        case unreadCount = "unread_count"
        case recipientCount = "recipient_count"
        case canViewReadCounts = "can_view_read_counts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .announcementID)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        readAt = try c.decodeIfPresent(String.self, forKey: .readAt)
        displayPosition = try c.decodeIfPresent(String.self, forKey: .displayPosition) ?? ""
        readAction = try c.decodeIfPresent(String.self, forKey: .readAction) ?? ""
        readCount = c.decodeLossyIntIfPresent(forKey: .readCount)
        unreadCount = c.decodeLossyIntIfPresent(forKey: .unreadCount)
        recipientCount = c.decodeLossyIntIfPresent(forKey: .recipientCount)
        canViewReadCounts = c.decodeLossyBoolIfPresent(forKey: .canViewReadCounts) ?? false
    }
}

public struct RemoteGroupSettingsMutationResult: Decodable, Sendable {
    public let groupID: String
    public let settings: RemoteGroupSettings

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        settings = try c.decodeIfPresent(RemoteGroupSettings.self, forKey: .settings) ?? .empty
    }
}

public struct RemoteGroupOwnerTransferResult: Decodable, Sendable {
    public let group: RemoteUserGroup
    public let previousOwnerUID: String
    public let newOwnerUID: String
    public let oldOwnerRole: String
    public let previousOwner: RemoteUserGroupMember?
    public let newOwner: RemoteUserGroupMember?
    public let transferredAt: String
    public let idempotent: Bool

    enum CodingKeys: String, CodingKey {
        case group
        case previousOwnerUID = "previous_owner_uid"
        case newOwnerUID = "new_owner_uid"
        case oldOwnerRole = "old_owner_role"
        case previousOwner = "previous_owner"
        case newOwner = "new_owner"
        case transferredAt = "transferred_at"
        case idempotent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .group) ?? .empty
        previousOwnerUID = try c.decodeIfPresent(String.self, forKey: .previousOwnerUID) ?? ""
        newOwnerUID = try c.decodeIfPresent(String.self, forKey: .newOwnerUID) ?? ""
        oldOwnerRole = try c.decodeIfPresent(String.self, forKey: .oldOwnerRole) ?? ""
        previousOwner = try c.decodeIfPresent(RemoteUserGroupMember.self, forKey: .previousOwner)
        newOwner = try c.decodeIfPresent(RemoteUserGroupMember.self, forKey: .newOwner)
        transferredAt = try c.decodeIfPresent(String.self, forKey: .transferredAt) ?? ""
        idempotent = c.decodeLossyBoolIfPresent(forKey: .idempotent) ?? false
    }
}
// WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_END

import Foundation

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
public struct RemoteGroupJoinRequest: Decodable, Sendable {
    public let id: String
    public let groupID: String
    public let applicantUID: String
    public let applicantName: String
    public let applicantAvatar: String
    public let inviterAvatar: String
    public let inviterName: String
    public let status: String
    public let message: String
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case applicantUID = "applicant_uid"
        case targetUID = "target_uid"
        case inviterUID = "inviter_uid"
        case applicantName = "applicant_name"
        case targetName = "target_name"
        case inviteeName = "invitee_name"
        case applicantAvatar = "applicant_avatar"
        case inviterAvatar = "inviter_avatar"
        case inviterName = "inviter_name"
        case status
        case message
        case reason
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        applicantUID = try c.decodeIfPresent(String.self, forKey: .applicantUID)
            ?? c.decodeIfPresent(String.self, forKey: .targetUID)
            ?? c.decodeIfPresent(String.self, forKey: .inviterUID)
            ?? ""
        applicantName = try c.decodeIfPresent(String.self, forKey: .applicantName)
            ?? c.decodeIfPresent(String.self, forKey: .targetName)
            ?? c.decodeIfPresent(String.self, forKey: .inviteeName)
            ?? ""
        applicantAvatar = try c.decodeIfPresent(String.self, forKey: .applicantAvatar) ?? ""
        inviterAvatar = try c.decodeIfPresent(String.self, forKey: .inviterAvatar) ?? ""
        inviterName = try c.decodeIfPresent(String.self, forKey: .inviterName) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        message = try c.decodeIfPresent(String.self, forKey: .message)
            ?? c.decodeIfPresent(String.self, forKey: .reason)
            ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

public struct RemoteGroupDNDResult: Decodable, Sendable {
    public let muted: Bool
}

public struct RemoteRawGroup: Decodable, Sendable {
    public let groupID: String
    public let groupRevision: Int64
    public let name: String
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case groupRevision = "group_revision"
        case name
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    public init(groupID: String, groupRevision: Int64 = 0, name: String = "", avatar: String = "", avatarVersion: String = "", avatarUpdatedAt: String = "") {
        self.groupID = groupID
        self.groupRevision = groupRevision
        self.name = name
        self.avatar = avatar
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        groupRevision = max(0, c.decodeLossyInt64IfPresent(forKey: .groupRevision) ?? 0)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
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
    }
}

public struct RemoteGroupProfileUpdateResponse: Decodable, Sendable {
    public let group: RemoteUserGroup?
    public let summary: RemoteUserGroup?
    public let avatarURL: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case group
        case summary
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatar
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = try container.decodeIfPresent(RemoteUserGroup.self, forKey: .group)
        summary = try container.decodeIfPresent(RemoteUserGroup.self, forKey: .summary)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? container.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? container.decodeIfPresent(String.self, forKey: .avatar)
            ?? summary?.avatar
            ?? group?.avatar
            ?? ""
        avatarVersion = try container.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? container.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? container.decodeIfPresent(String.self, forKey: .version)
            ?? summary?.avatarVersion
            ?? group?.avatarVersion
            ?? ""
        avatarUpdatedAt = try container.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? container.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? summary?.avatarUpdatedAt
            ?? group?.avatarUpdatedAt
            ?? ""
    }

    public var effectiveGroup: RemoteUserGroup {
        summary ?? group ?? .empty
    }
}

public struct RemoteGroup: Decodable, Sendable {
    public let groupID: String
    enum CodingKeys: String, CodingKey { case groupID = "group_id" }
}

public struct RemoteGroupMember: Decodable, Sendable {
    public let imUID: String
    public let role: String
    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = [
            try c.decodeIfPresent(String.self, forKey: .imUID),
            try c.decodeIfPresent(String.self, forKey: .userID)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "member"
    }
}
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

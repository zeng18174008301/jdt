// WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_BEGIN
import Foundation

public struct RemoteGroupSettings: Decodable, Sendable {
    public let memberFriendApplyEnabled: Bool
    public let groupRevision: Int64
    public let groupDescription: String?
    public let muted: Bool
    public let inviteConfirmRequired: Bool
    public let allMuted: Bool
    public let allMutedMode: String
    public let allMutedActive: Bool?
    public let allMutedStartAt: String?
    public let allMutedEndAt: String?
    public let allMutedUpdatedAt: String?
    public let allMutedRepairRequired: Bool
    public let serverTime: String?
    public let nextBoundaryAt: String?
    public let pendingJoinRequestCount: Int
    public let fileCount: Int
    public let blacklistCount: Int
    public let historyVisible: Bool
    public let canManageMuteList: Bool?
    public let muteListCount: Int?

    enum CodingKeys: String, CodingKey {
        case groupRevision = "group_revision"
        case groupDescription = "description"
        case memberFriendApplyEnabled = "web_member_friend_apply_enabled"
        case muted
        case historyVisible = "history_visible"
        case historyVisibleCamel = "historyVisible"
        case inviteConfirmRequired = "invite_confirm_required"
        case inviteConfirmRequiredCamel = "inviteConfirmRequired"
        case inviteConfirm = "invite_confirm"
        case inviteConfirmCamel = "inviteConfirm"
        case approval
        case allMuted = "all_muted"
        case allMutedMode = "all_muted_mode"
        case allMutedActive = "all_muted_active"
        case allMutedStartAt = "all_muted_start_at"
        case allMutedEndAt = "all_muted_end_at"
        case allMutedUpdatedAt = "all_muted_updated_at"
        case allMutedRepairRequired = "all_muted_repair_required"
        case serverTime = "server_time"
        case nextBoundaryAt = "next_boundary_at"
        case pendingJoinRequestCount = "pending_join_request_count"
        case fileCount = "file_count"
        case blacklistCount = "blacklist_count"
        case canManageMuteList = "can_manage_mute_list"
        case canManageMuteListCamel = "canManageMuteList"
        case muteListCount = "mute_list_count"
        case muteListCountCamel = "muteListCount"
    }

    public static let empty = RemoteGroupSettings()

    public init() {
        memberFriendApplyEnabled = true
        groupRevision = 0
        groupDescription = nil
        muted = false
        inviteConfirmRequired = false
        allMuted = false
        allMutedMode = ""
        allMutedActive = nil
        allMutedStartAt = nil
        allMutedEndAt = nil
        allMutedUpdatedAt = nil
        allMutedRepairRequired = false
        serverTime = nil
        nextBoundaryAt = nil
        pendingJoinRequestCount = 0
        fileCount = 0
        blacklistCount = 0
        historyVisible = true
        canManageMuteList = nil
        muteListCount = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupRevision = max(0, c.decodeLossyInt64IfPresent(forKey: .groupRevision) ?? 0)
        groupDescription = try c.decodeIfPresent(String.self, forKey: .groupDescription)
        memberFriendApplyEnabled = c.contains(.memberFriendApplyEnabled)
            ? (c.decodeStrictBoolIfPresent(forKey: .memberFriendApplyEnabled) ?? false) : true
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        inviteConfirmRequired = c.decodeLossyBoolIfPresent(forKey: .inviteConfirmRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirmRequiredCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirm)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirmCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .approval)
            ?? false
        allMuted = try c.decodeIfPresent(Bool.self, forKey: .allMuted) ?? false
        allMutedMode = try c.decodeIfPresent(String.self, forKey: .allMutedMode) ?? ""
        allMutedActive = c.decodeStrictBoolIfPresent(forKey: .allMutedActive)
        allMutedStartAt = try c.decodeIfPresent(String.self, forKey: .allMutedStartAt)
        allMutedEndAt = try c.decodeIfPresent(String.self, forKey: .allMutedEndAt)
        allMutedUpdatedAt = try c.decodeIfPresent(String.self, forKey: .allMutedUpdatedAt)
        allMutedRepairRequired = c.decodeStrictBoolIfPresent(forKey: .allMutedRepairRequired) ?? false
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime)
        nextBoundaryAt = try c.decodeIfPresent(String.self, forKey: .nextBoundaryAt)
        pendingJoinRequestCount = try c.decodeIfPresent(Int.self, forKey: .pendingJoinRequestCount) ?? 0
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        blacklistCount = try c.decodeIfPresent(Int.self, forKey: .blacklistCount) ?? 0
        historyVisible = c.decodeLossyBoolIfPresent(forKey: .historyVisible)
            ?? c.decodeLossyBoolIfPresent(forKey: .historyVisibleCamel)
            ?? true
        canManageMuteList = c.decodeLossyBoolIfPresent(forKey: .canManageMuteList)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageMuteListCamel)
        muteListCount = c.decodeLossyIntIfPresent(forKey: .muteListCount)
            ?? c.decodeLossyIntIfPresent(forKey: .muteListCountCamel)
    }
}
// WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
public struct RemoteGroupLeaveResult: Decodable, Sendable {
    public let left: Bool
    public let groupID: String
    public let leftAt: String
    public let conversationRemoved: Bool
    public let notificationAudience: String
    public let notificationCount: Int
    public let searchInvalidations: [SearchInvalidationEvent]

    enum CodingKeys: String, CodingKey {
        case left
        case groupID = "group_id"
        case groupIDCamel = "groupId"
        case leftAt = "left_at"
        case leftAtCamel = "leftAt"
        case conversationRemoved = "conversation_removed"
        case conversationRemovedCamel = "conversationRemoved"
        case notificationAudience = "notification_audience"
        case notificationAudienceCamel = "notificationAudience"
        case notificationCount = "notification_count"
        case notificationCountCamel = "notificationCount"
        case searchInvalidations = "search_invalidations"
        case searchInvalidationsCamel = "searchInvalidations"
    }

    public init(
        left: Bool = false,
        groupID: String = "",
        leftAt: String = "",
        conversationRemoved: Bool = false,
        notificationAudience: String = "",
        notificationCount: Int = 0,
        searchInvalidations: [SearchInvalidationEvent] = []
    ) {
        self.left = left
        self.groupID = groupID
        self.leftAt = leftAt
        self.conversationRemoved = conversationRemoved
        self.notificationAudience = notificationAudience
        self.notificationCount = notificationCount
        self.searchInvalidations = searchInvalidations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decodeIfPresent(Bool.self, forKey: .left) ?? false
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
            ?? c.decodeIfPresent(String.self, forKey: .groupIDCamel)
            ?? ""
        leftAt = try c.decodeIfPresent(String.self, forKey: .leftAt)
            ?? c.decodeIfPresent(String.self, forKey: .leftAtCamel)
            ?? ""
        conversationRemoved = try c.decodeIfPresent(Bool.self, forKey: .conversationRemoved)
            ?? c.decodeIfPresent(Bool.self, forKey: .conversationRemovedCamel)
            ?? false
        notificationAudience = try c.decodeIfPresent(String.self, forKey: .notificationAudience)
            ?? c.decodeIfPresent(String.self, forKey: .notificationAudienceCamel)
            ?? ""
        notificationCount = try c.decodeIfPresent(Int.self, forKey: .notificationCount)
            ?? c.decodeIfPresent(Int.self, forKey: .notificationCountCamel)
            ?? 0
        searchInvalidations = try c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidations)
            ?? c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidationsCamel)
            ?? []
    }
}

public struct RemoteGroupDissolvePreview: Decodable, Sendable {
    public let groupID: String
    public let memberCount: Int?
    public let affectedMembers: Int?
    public let confirmationRequired: Bool
    public let confirmationText: String
    public let confirmationMode: String
    public let effects: [String]

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case groupIDCamel = "groupId"
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case affectedMembers = "affected_members"
        case affectedMembersCamel = "affectedMembers"
        case confirmationRequired = "confirmation_required"
        case confirmationRequiredCamel = "confirmationRequired"
        case confirmationText = "confirmation_text"
        case confirmationTextCamel = "confirmationText"
        case confirmationMode = "confirmation_mode"
        case confirmationModeCamel = "confirmationMode"
        case effects
    }

    public init(
        groupID: String = "",
        memberCount: Int? = nil,
        affectedMembers: Int? = nil,
        confirmationRequired: Bool = true,
        confirmationText: String = "",
        confirmationMode: String = "button",
        effects: [String] = []
    ) {
        self.groupID = groupID
        self.memberCount = memberCount
        self.affectedMembers = affectedMembers
        self.confirmationRequired = confirmationRequired
        self.confirmationText = confirmationText
        self.confirmationMode = confirmationMode
        self.effects = effects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
            ?? c.decodeIfPresent(String.self, forKey: .groupIDCamel)
            ?? ""
        memberCount = Self.decodeFlexibleInt(from: c, keys: [.memberCount, .memberCountCamel])
        affectedMembers = Self.decodeFlexibleInt(from: c, keys: [.affectedMembers, .affectedMembersCamel]) ?? memberCount
        confirmationRequired = try c.decodeIfPresent(Bool.self, forKey: .confirmationRequired)
            ?? c.decodeIfPresent(Bool.self, forKey: .confirmationRequiredCamel)
            ?? true
        confirmationText = try c.decodeIfPresent(String.self, forKey: .confirmationText)
            ?? c.decodeIfPresent(String.self, forKey: .confirmationTextCamel)
            ?? ""
        confirmationMode = try c.decodeIfPresent(String.self, forKey: .confirmationMode)
            ?? c.decodeIfPresent(String.self, forKey: .confirmationModeCamel)
            ?? "button"
        effects = try c.decodeIfPresent([String].self, forKey: .effects) ?? []
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

public struct RemoteGroupDissolveResult: Decodable, Sendable {
    public let dissolved: Bool
    public let groupID: String
    public let status: String
    public let dissolvedAt: String
    public let removedMembers: Int
    public let removedConversations: Int
    public let notificationCount: Int
    public let searchInvalidations: [SearchInvalidationEvent]

    enum CodingKeys: String, CodingKey {
        case dissolved
        case groupID = "group_id"
        case groupIDCamel = "groupId"
        case status
        case dissolvedAt = "dissolved_at"
        case dissolvedAtCamel = "dissolvedAt"
        case removedMembers = "removed_members"
        case removedMembersCamel = "removedMembers"
        case removedConversations = "removed_conversations"
        case removedConversationsCamel = "removedConversations"
        case notificationCount = "notification_count"
        case notificationCountCamel = "notificationCount"
        case searchInvalidations = "search_invalidations"
        case searchInvalidationsCamel = "searchInvalidations"
    }

    public init(
        dissolved: Bool = false,
        groupID: String = "",
        status: String = "",
        dissolvedAt: String = "",
        removedMembers: Int = 0,
        removedConversations: Int = 0,
        notificationCount: Int = 0,
        searchInvalidations: [SearchInvalidationEvent] = []
    ) {
        self.dissolved = dissolved
        self.groupID = groupID
        self.status = status
        self.dissolvedAt = dissolvedAt
        self.removedMembers = removedMembers
        self.removedConversations = removedConversations
        self.notificationCount = notificationCount
        self.searchInvalidations = searchInvalidations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dissolved = try c.decodeIfPresent(Bool.self, forKey: .dissolved) ?? false
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
            ?? c.decodeIfPresent(String.self, forKey: .groupIDCamel)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        dissolvedAt = try c.decodeIfPresent(String.self, forKey: .dissolvedAt)
            ?? c.decodeIfPresent(String.self, forKey: .dissolvedAtCamel)
            ?? ""
        removedMembers = Self.decodeFlexibleInt(from: c, keys: [.removedMembers, .removedMembersCamel]) ?? 0
        removedConversations = Self.decodeFlexibleInt(from: c, keys: [.removedConversations, .removedConversationsCamel]) ?? 0
        notificationCount = Self.decodeFlexibleInt(from: c, keys: [.notificationCount, .notificationCountCamel]) ?? 0
        searchInvalidations = try c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidations)
            ?? c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidationsCamel)
            ?? []
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

public struct RemoteGroupMuteListItem: Decodable, Sendable {
    public let groupID: String
    public let targetUID: String
    public let targetUserID: String
    public let targetUsername: String
    public let targetNickname: String
    public let targetAvatar: String
    public let targetRole: String
    public let operatorUID: String
    public let operatorName: String
    public let reason: String
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case groupIDCamel = "groupId"
        case targetUID = "target_uid"
        case targetUIDCamel = "targetUID"
        case imUID = "im_uid"
        case uid
        case targetUserID = "target_user_id"
        case targetUserIDCamel = "targetUserID"
        case userID = "user_id"
        case targetUsername = "target_username"
        case targetUsernameCamel = "targetUsername"
        case username
        case targetNickname = "target_nickname"
        case targetNicknameCamel = "targetNickname"
        case nickname
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case targetAvatar = "target_avatar"
        case targetAvatarCamel = "targetAvatar"
        case avatar
        case avatarURL = "avatar_url"
        case targetRole = "target_role"
        case targetRoleCamel = "targetRole"
        case role
        case operatorUID = "operator_uid"
        case operatorUIDCamel = "operatorUID"
        case operatorName = "operator_name"
        case operatorNameCamel = "operatorName"
        case reason
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = (try c.decodeIfPresent(String.self, forKey: .groupID)
            ?? c.decodeIfPresent(String.self, forKey: .groupIDCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedTargetUID = try c.decodeIfPresent(String.self, forKey: .targetUID)
        let decodedTargetUIDCamel = try c.decodeIfPresent(String.self, forKey: .targetUIDCamel)
        let decodedIMUID = try c.decodeIfPresent(String.self, forKey: .imUID)
        let decodedUID = try c.decodeIfPresent(String.self, forKey: .uid)
        let decodedTargetUserID = try c.decodeIfPresent(String.self, forKey: .targetUserID)
        let decodedUserID = try c.decodeIfPresent(String.self, forKey: .userID)
        targetUID = [
            decodedTargetUID,
            decodedTargetUIDCamel,
            decodedIMUID,
            decodedUID,
            decodedTargetUserID,
            decodedUserID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        targetUserID = [
            decodedTargetUserID,
            try c.decodeIfPresent(String.self, forKey: .targetUserIDCamel),
            decodedUserID,
            targetUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        targetUsername = (try c.decodeIfPresent(String.self, forKey: .targetUsername)
            ?? c.decodeIfPresent(String.self, forKey: .targetUsernameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .username)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        targetNickname = [
            try c.decodeIfPresent(String.self, forKey: .targetNickname),
            try c.decodeIfPresent(String.self, forKey: .targetNicknameCamel),
            try c.decodeIfPresent(String.self, forKey: .displayName),
            try c.decodeIfPresent(String.self, forKey: .displayNameCamel),
            try c.decodeIfPresent(String.self, forKey: .nickname)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        targetAvatar = (try c.decodeIfPresent(String.self, forKey: .targetAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatarCamel)
            ?? c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        targetRole = (try c.decodeIfPresent(String.self, forKey: .targetRole)
            ?? c.decodeIfPresent(String.self, forKey: .targetRoleCamel)
            ?? c.decodeIfPresent(String.self, forKey: .role)
            ?? "member").trimmingCharacters(in: .whitespacesAndNewlines)
        operatorUID = (try c.decodeIfPresent(String.self, forKey: .operatorUID)
            ?? c.decodeIfPresent(String.self, forKey: .operatorUIDCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        operatorName = (try c.decodeIfPresent(String.self, forKey: .operatorName)
            ?? c.decodeIfPresent(String.self, forKey: .operatorNameCamel)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        reason = (try c.decodeIfPresent(String.self, forKey: .reason) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtCamel)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel)
    }
}
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

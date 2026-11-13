// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
import Foundation

public struct RemoteFriendRelation: Decodable, Sendable { // WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111
    public let ownerUID: String
    public let friendUID: String
    public let authoritativeFriendUID: String?
    public let friendUserID: String
    public let authoritativeFriendUserID: String?
    public let ownerAvatar: String
    public let friendAvatar: String
    public let friendAvatarVersion: String
    public let friendAvatarUpdatedAt: String
    public let friendNickname: String
    public let displayName: String
    public let rawNickname: String
    public let displayNameSource: String
    public let friendStatus: String
    public let friendOnline: Bool
    public let friendOnlineKnown: Bool
    public let friendLastSeenAt: String
    public let friendPhone: String
    public let friendPhoneMasked: String
    public let remark: String?
    public let departmentName: String
    public let departmentPath: [String]
    public let departmentPathNames: [String]

    public var visiblePhone: String {
        friendPhoneMasked.isEmpty ? friendPhone : friendPhoneMasked
    }

    enum CodingKeys: String, CodingKey {
        case ownerUID = "owner_uid"
        case ownerIMUID = "owner_im_uid"
        case friendUID = "friend_uid"
        case friendIMUID = "friend_im_uid"
        case friendUserID = "friend_user_id"
        case imUID = "im_uid"
        case userID = "user_id"
        case peerUID = "peer_uid"
        case targetUID = "target_uid"
        case ownerAvatar = "owner_avatar"
        case friendAvatar = "friend_avatar"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case friendAvatarVersion = "friend_avatar_version"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case friendAvatarUpdatedAt = "friend_avatar_updated_at"
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case friendNickname = "friend_nickname"
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case rawNickname = "raw_nickname"
        case rawNicknameCamel = "rawNickname"
        case displayNameSource = "display_name_source"
        case displayNameSourceCamel = "displayNameSource"
        case friendPhone = "friend_phone"
        case friendPhoneMasked = "friend_phone_masked"
        case phone
        case phoneMasked = "phone_masked"
        case nickname
        case name
        case status
        case presenceStatus = "presence_status"
        case friendStatus = "friend_status"
        case friendStatusCamel = "friendStatus"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case friendOnline = "friend_online"
        case friendOnlineCamel = "friendOnline"
        case friendLastSeenAt = "friend_last_seen_at"
        case friendLastSeenAtCamel = "friendLastSeenAt"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case remark
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerUID = [
            try c.decodeIfPresent(String.self, forKey: .ownerUID),
            try c.decodeIfPresent(String.self, forKey: .ownerIMUID)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let canonicalFriendUID = try c.decodeIfPresent(String.self, forKey: .friendUID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        authoritativeFriendUID = canonicalFriendUID.isEmpty ? nil : canonicalFriendUID
        let canonicalFriendUserID = try c.decodeIfPresent(String.self, forKey: .friendUserID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        authoritativeFriendUserID = canonicalFriendUserID.isEmpty ? nil : canonicalFriendUserID
        friendUID = [
            try c.decodeIfPresent(String.self, forKey: .friendUID),
            try c.decodeIfPresent(String.self, forKey: .friendIMUID),
            try c.decodeIfPresent(String.self, forKey: .friendUserID),
            try c.decodeIfPresent(String.self, forKey: .imUID),
            try c.decodeIfPresent(String.self, forKey: .userID),
            try c.decodeIfPresent(String.self, forKey: .peerUID),
            try c.decodeIfPresent(String.self, forKey: .targetUID)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        friendUserID = [
            try c.decodeIfPresent(String.self, forKey: .friendUserID),
            try c.decodeIfPresent(String.self, forKey: .userID),
            friendUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        ownerAvatar = try c.decodeIfPresent(String.self, forKey: .ownerAvatar) ?? ""
        friendAvatar = try c.decodeIfPresent(String.self, forKey: .friendAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        friendAvatarVersion = try c.decodeIfPresent(String.self, forKey: .friendAvatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        friendAvatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .friendAvatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        friendNickname = try c.decodeIfPresent(String.self, forKey: .friendNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .nickname)
            ?? ""
        rawNickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? friendNickname
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? friendNickname
        displayNameSource = try c.decodeIfPresent(String.self, forKey: .displayNameSource)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameSourceCamel)
            ?? ""
        friendStatus = [
            try c.decodeIfPresent(String.self, forKey: .presenceStatus),
            try c.decodeIfPresent(String.self, forKey: .friendStatus),
            try c.decodeIfPresent(String.self, forKey: .friendStatusCamel),
            try c.decodeIfPresent(String.self, forKey: .status)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let decodedFriendOnline = c.decodeLossyBoolIfPresent(forKey: .friendOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .friendOnlineCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnline)
            ?? c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .online)
            ?? false
        friendOnline = decodedFriendOnline
        friendOnlineKnown = c.decodeLossyBoolIfPresent(forKey: .friendOnline) != nil
            || c.decodeLossyBoolIfPresent(forKey: .friendOnlineCamel) != nil
            || c.decodeLossyBoolIfPresent(forKey: .isOnline) != nil
            || c.decodeLossyBoolIfPresent(forKey: .isOnlineCamel) != nil
            || c.decodeLossyBoolIfPresent(forKey: .online) != nil
        friendLastSeenAt = [
            try c.decodeIfPresent(String.self, forKey: .friendLastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .friendLastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAt),
            try c.decodeIfPresent(String.self, forKey: .lastSeenAtCamel),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAt),
            try c.decodeIfPresent(String.self, forKey: .lastLoginAtCamel)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        friendPhone = try c.decodeIfPresent(String.self, forKey: .friendPhone)
            ?? c.decodeIfPresent(String.self, forKey: .phone)
            ?? ""
        friendPhoneMasked = try c.decodeIfPresent(String.self, forKey: .friendPhoneMasked)
            ?? c.decodeIfPresent(String.self, forKey: .phoneMasked)
            ?? ""
        remark = try c.decodeIfPresent(String.self, forKey: .remark)
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

public struct RemoteFriendProfile: Decodable {
    public let imUID: String
    public let userID: String
    public let nickname: String
    public let displayName: String
    public let rawNickname: String
    public let displayNameSource: String
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let phone: String
    public let phoneMasked: String
    public let remark: String
    public let departmentName: String
    public let departmentPath: [String]
    public let departmentPathNames: [String]

    public var visiblePhone: String {
        phoneMasked.isEmpty ? phone : phoneMasked
    }

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case nickname
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case rawNickname = "raw_nickname"
        case rawNicknameCamel = "rawNickname"
        case displayNameSource = "display_name_source"
        case displayNameSourceCamel = "displayNameSource"
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case phone
        case phoneMasked = "phone_masked"
        case remark
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        nickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .nickname)
            ?? ""
        rawNickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? nickname
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? nickname
        displayNameSource = try c.decodeIfPresent(String.self, forKey: .displayNameSource)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameSourceCamel)
            ?? ""
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
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        phoneMasked = try c.decodeIfPresent(String.self, forKey: .phoneMasked) ?? ""
        remark = try c.decodeIfPresent(String.self, forKey: .remark) ?? ""
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

public struct RemoteBlacklistRelation: Decodable {
    public let ownerUID: String
    public let blockedUID: String
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case ownerUID = "owner_uid"
        case blockedUID = "blocked_uid"
        case reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerUID = try c.decodeIfPresent(String.self, forKey: .ownerUID) ?? ""
        blockedUID = try c.decodeIfPresent(String.self, forKey: .blockedUID) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

public struct RemoteFriendApplication: Decodable {
    public let id: String
    public let applicantUID: String
    public let applicantName: String
    public let applicantAvatar: String
    public let targetUID: String
    public let targetName: String
    public let targetAvatar: String
    public let sourceGroupName: String?
    public let source: String
    public let status: String
    public let tenantReviewStatus: String
    public let direction: String
    public let actionableByCurrentUser: Bool?
    public let peerReviewStatus: String
    public let message: String?
    public let outcome: String
    public let relationStatus: String
    public let friendAction: String
    public let friendFlow: String
    public let directlyEstablished: Bool
    public let requiresTenantReview: Bool?
    public let requiresTargetApproval: Bool?
    public let resolutionMode: String

    enum CodingKeys: String, CodingKey {
        case id
        case applicantUID = "applicant_uid"
        case applicantName = "applicant_name"
        case applicantNickname = "applicant_nickname"
        case applicantAvatar = "applicant_avatar"
        case targetUID = "target_uid"
        case targetName = "target_name"
        case targetNickname = "target_nickname"
        case targetAvatar = "target_avatar"
        case sourceGroupName = "source_group_name"
        case source
        case status
        case tenantReviewStatus = "tenant_review_status"
        case direction
        case actionableByCurrentUser = "actionable_by_current_user"
        case peerReviewStatus = "peer_review_status"
        case message
        case outcome
        case relationStatus = "relation_status"
        case friendAction = "friend_action"
        case friendFlow = "friend_flow"
        case directlyEstablished = "directly_established"
        case requiresTenantReview = "requires_tenant_review"
        case requiresTargetApproval = "requires_target_approval"
        case resolutionMode = "resolution_mode"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        applicantUID = try c.decodeIfPresent(String.self, forKey: .applicantUID) ?? ""
        applicantName = try c.decodeIfPresent(String.self, forKey: .applicantName)
            ?? c.decodeIfPresent(String.self, forKey: .applicantNickname)
            ?? ""
        applicantAvatar = try c.decodeIfPresent(String.self, forKey: .applicantAvatar) ?? ""
        targetUID = try c.decodeIfPresent(String.self, forKey: .targetUID) ?? ""
        targetName = try c.decodeIfPresent(String.self, forKey: .targetName)
            ?? c.decodeIfPresent(String.self, forKey: .targetNickname)
            ?? ""
        targetAvatar = try c.decodeIfPresent(String.self, forKey: .targetAvatar) ?? ""
        sourceGroupName = try c.decodeIfPresent(String.self, forKey: .sourceGroupName)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        tenantReviewStatus = try c.decodeIfPresent(String.self, forKey: .tenantReviewStatus) ?? ""
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        actionableByCurrentUser = try c.decodeIfPresent(Bool.self, forKey: .actionableByCurrentUser)
        peerReviewStatus = try c.decodeIfPresent(String.self, forKey: .peerReviewStatus) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        relationStatus = try c.decodeIfPresent(String.self, forKey: .relationStatus) ?? ""
        friendAction = try c.decodeIfPresent(String.self, forKey: .friendAction) ?? ""
        friendFlow = try c.decodeIfPresent(String.self, forKey: .friendFlow) ?? ""
        directlyEstablished = c.decodeLossyBoolIfPresent(forKey: .directlyEstablished) ?? false
        requiresTenantReview = c.decodeLossyBoolIfPresent(forKey: .requiresTenantReview)
        requiresTargetApproval = c.decodeLossyBoolIfPresent(forKey: .requiresTargetApproval)
        resolutionMode = try c.decodeIfPresent(String.self, forKey: .resolutionMode) ?? ""
    }
}

public struct RemoteUserSearchItem: Decodable {
    public let imUID: String
    public let userID: String
    public let nickname: String
    public let displayName: String
    public let rawNickname: String
    public let displayNameSource: String
    public let remark: String
    public let phone: String
    public let phoneMasked: String
    public let avatar: String
    public let status: String
    public let presenceStatus: String
    public let online: Bool
    public let onlineKnown: Bool
    public let lastSeenAt: String
    public let relationStatus: String
    public let canApplyFriend: Bool
    public let reason: String
    public let friendAction: String
    public let friendFlow: String
    public let requiresTenantReview: Bool?
    public let requiresTargetApproval: Bool?

    public var visiblePhone: String {
        phoneMasked.isEmpty ? phone : phoneMasked
    }

    enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case nickname
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case rawNickname = "raw_nickname"
        case rawNicknameCamel = "rawNickname"
        case displayNameSource = "display_name_source"
        case displayNameSourceCamel = "displayNameSource"
        case remark
        case phone
        case phoneMasked = "phone_masked"
        case avatar
        case status
        case presenceStatus = "presence_status"
        case online
        case isOnline = "is_online"
        case isOnlineCamel = "isOnline"
        case lastSeenAt = "last_seen_at"
        case lastSeenAtCamel = "lastSeenAt"
        case lastLoginAt = "last_login_at"
        case lastLoginAtCamel = "lastLoginAt"
        case relationStatus = "relation_status"
        case canApplyFriend = "can_apply_friend"
        case reason
        case friendAction = "friend_action"
        case friendFlow = "friend_flow"
        case requiresTenantReview = "requires_tenant_review"
        case requiresTargetApproval = "requires_target_approval"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? imUID
        nickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .nickname)
            ?? userID
        rawNickname = try c.decodeIfPresent(String.self, forKey: .rawNickname)
            ?? c.decodeIfPresent(String.self, forKey: .rawNicknameCamel)
            ?? nickname
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? nickname
        displayNameSource = try c.decodeIfPresent(String.self, forKey: .displayNameSource)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameSourceCamel)
            ?? ""
        remark = try c.decodeIfPresent(String.self, forKey: .remark) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        phoneMasked = try c.decodeIfPresent(String.self, forKey: .phoneMasked) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
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
        relationStatus = try c.decodeIfPresent(String.self, forKey: .relationStatus) ?? "none"
        canApplyFriend = try c.decodeIfPresent(Bool.self, forKey: .canApplyFriend) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        friendAction = try c.decodeIfPresent(String.self, forKey: .friendAction)
            ?? (canApplyFriend ? "request" : "none")
        friendFlow = try c.decodeIfPresent(String.self, forKey: .friendFlow) ?? ""
        requiresTenantReview = c.decodeLossyBoolIfPresent(forKey: .requiresTenantReview)
        requiresTargetApproval = c.decodeLossyBoolIfPresent(forKey: .requiresTargetApproval)
    }
}

public struct RemoteFriendApplyResult: Decodable {
    public let id: String
    public let status: String
    public let outcome: String
    public let relationStatus: String
    public let friendAction: String
    public let friendFlow: String
    public let directlyEstablished: Bool
    public let requiresTenantReview: Bool?
    public let requiresTargetApproval: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case applicationID = "application_id"
        case requestID = "request_id"
        case status
        case outcome
        case relationStatus = "relation_status"
        case friendAction = "friend_action"
        case friendFlow = "friend_flow"
        case directlyEstablished = "directly_established"
        case requiresTenantReview = "requires_tenant_review"
        case requiresTargetApproval = "requires_target_approval"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .applicationID)
            ?? c.decodeIfPresent(String.self, forKey: .requestID)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        relationStatus = try c.decodeIfPresent(String.self, forKey: .relationStatus) ?? ""
        friendAction = try c.decodeIfPresent(String.self, forKey: .friendAction) ?? ""
        friendFlow = try c.decodeIfPresent(String.self, forKey: .friendFlow) ?? ""
        directlyEstablished = c.decodeLossyBoolIfPresent(forKey: .directlyEstablished) ?? false
        requiresTenantReview = c.decodeLossyBoolIfPresent(forKey: .requiresTenantReview)
        requiresTargetApproval = c.decodeLossyBoolIfPresent(forKey: .requiresTargetApproval)
    }
}
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

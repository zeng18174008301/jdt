// WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_BEGIN
import Foundation

public struct RemoteUserGroup: Decodable, Sendable {
    public let explicitMyRole: String?
    public let memberFriendApplyEnabled: Bool?
    public let groupID: String
    public let groupRevision: Int64
    public let name: String
    public let avatar: String
    public let avatarSource: String
    public let avatarProvided: Bool
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let notice: String
    public let groupDescription: String?
    public let ownerUID: String
    public let ownerName: String
    public let memberCount: Int?
    public let myRole: String
    public let muted: Bool
    public let allMuted: Bool
    public let allMutedMode: String
    public let allMutedActive: Bool?
    public let allMutedStartAt: String?
    public let allMutedEndAt: String?
    public let allMutedUpdatedAt: String?
    public let allMutedRepairRequired: Bool
    public let serverTime: String?
    public let nextBoundaryAt: String?
    public let inviteConfirmRequired: Bool
    public let historyVisibleFromSeq: Int64
    public let historyLimited: Bool
    public let groupMuted: Bool
    public let canManageMuteList: Bool?
    public let muteListCount: Int?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case groupRevision = "group_revision"
        case name
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarSource = "avatar_source"
        case avatarSourceCamel = "avatarSource"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case notice
        case groupDescription = "description"
        case ownerUID = "owner_uid"
        case ownerName = "owner_name"
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case membersCount = "members_count"
        case membersCountCamel = "membersCount"
        case memberTotal = "member_total"
        case memberNum = "member_num"
        case memberNumCamel = "memberNum"
        case totalMembers = "total_members"
        case totalMembersCamel = "totalMembers"
        case membersTotal = "members_total"
        case membersTotalCamel = "membersTotal"
        case total
        case myRole = "my_role"
        case muted
        case allMuted = "all_muted"
        case allMutedMode = "all_muted_mode"
        case allMutedActive = "all_muted_active"
        case allMutedStartAt = "all_muted_start_at"
        case allMutedEndAt = "all_muted_end_at"
        case allMutedUpdatedAt = "all_muted_updated_at"
        case allMutedRepairRequired = "all_muted_repair_required"
        case serverTime = "server_time"
        case nextBoundaryAt = "next_boundary_at"
        case inviteConfirmRequired = "invite_confirm_required"
        case inviteConfirmRequiredCamel = "inviteConfirmRequired"
        case inviteConfirm = "invite_confirm"
        case inviteConfirmCamel = "inviteConfirm"
        case approval
        case historyVisibleFromSeq = "history_visible_from_seq"
        case historyVisibleFromSeqCamel = "historyVisibleFromSeq"
        case historyLimited = "history_limited"
        case historyLimitedCamel = "historyLimited"
        case groupMuted = "group_muted"
        case groupMutedCamel = "groupMuted"
        case canManageMuteList = "can_manage_mute_list"
        case canManageMuteListCamel = "canManageMuteList"
        case muteListCount = "mute_list_count"
        case muteListCountCamel = "muteListCount"
        case createdAt = "created_at"
        case settings
        case memberFriendApplyEnabled = "web_member_friend_apply_enabled"
    }

    public static let empty = RemoteUserGroup()

    public init() {
        memberFriendApplyEnabled = nil
        explicitMyRole = nil
        groupID = ""
        groupRevision = 0
        name = ""
        avatar = ""
        avatarSource = ""
        avatarProvided = false
        avatarVersion = ""
        avatarUpdatedAt = ""
        notice = ""
        groupDescription = nil
        ownerUID = ""
        ownerName = ""
        memberCount = nil
        myRole = "member"
        muted = false
        allMuted = false
        allMutedMode = ""
        allMutedActive = nil
        allMutedStartAt = nil
        allMutedEndAt = nil
        allMutedUpdatedAt = nil
        allMutedRepairRequired = false
        serverTime = nil
        nextBoundaryAt = nil
        inviteConfirmRequired = false
        historyVisibleFromSeq = 1
        historyLimited = false
        groupMuted = false
        canManageMuteList = nil
        muteListCount = nil
        createdAt = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        groupRevision = max(0, c.decodeLossyInt64IfPresent(forKey: .groupRevision) ?? 0)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        avatarProvided = c.contains(.avatar) || c.contains(.avatarURL) || c.contains(.avatarURLCamel)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarSource = try c.decodeIfPresent(String.self, forKey: .avatarSource)
            ?? c.decodeIfPresent(String.self, forKey: .avatarSourceCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? ""
        groupDescription = try c.decodeIfPresent(String.self, forKey: .groupDescription)
        ownerUID = try c.decodeIfPresent(String.self, forKey: .ownerUID) ?? ""
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName) ?? ""
        memberCount = Self.decodeFlexibleInt(
            from: c,
            keys: [
                .memberCount,
                .memberCountCamel,
                .membersCount,
                .membersCountCamel,
                .memberTotal,
                .memberNum,
                .memberNumCamel,
                .totalMembers,
                .totalMembersCamel,
                .membersTotal,
                .membersTotalCamel,
                .total
            ]
        )
        let groupSettings = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .settings)
        memberFriendApplyEnabled = groupSettings.map {
            $0.contains(.memberFriendApplyEnabled)
                ? ($0.decodeStrictBoolIfPresent(forKey: .memberFriendApplyEnabled) ?? false) : true
        }
        explicitMyRole = try c.decodeIfPresent(String.self, forKey: .myRole)
        myRole = explicitMyRole ?? "member"
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        allMuted = try c.decodeIfPresent(Bool.self, forKey: .allMuted) ?? false
        allMutedMode = try c.decodeIfPresent(String.self, forKey: .allMutedMode) ?? ""
        allMutedActive = c.decodeStrictBoolIfPresent(forKey: .allMutedActive)
        allMutedStartAt = try c.decodeIfPresent(String.self, forKey: .allMutedStartAt)
        allMutedEndAt = try c.decodeIfPresent(String.self, forKey: .allMutedEndAt)
        allMutedUpdatedAt = try c.decodeIfPresent(String.self, forKey: .allMutedUpdatedAt)
        allMutedRepairRequired = c.decodeStrictBoolIfPresent(forKey: .allMutedRepairRequired) ?? false
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime)
        nextBoundaryAt = try c.decodeIfPresent(String.self, forKey: .nextBoundaryAt)
        inviteConfirmRequired = c.decodeLossyBoolIfPresent(forKey: .inviteConfirmRequired)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirmRequiredCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirm)
            ?? c.decodeLossyBoolIfPresent(forKey: .inviteConfirmCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .approval)
            ?? false
        historyVisibleFromSeq = max(
            1,
            c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeq)
                ?? c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeqCamel)
                ?? 1
        )
        historyLimited = c.decodeLossyBoolIfPresent(forKey: .historyLimited)
            ?? c.decodeLossyBoolIfPresent(forKey: .historyLimitedCamel)
            ?? false
        groupMuted = c.decodeLossyBoolIfPresent(forKey: .groupMuted)
            ?? c.decodeLossyBoolIfPresent(forKey: .groupMutedCamel)
            ?? false
        canManageMuteList = c.decodeLossyBoolIfPresent(forKey: .canManageMuteList)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageMuteListCamel)
        muteListCount = Self.decodeFlexibleInt(from: c, keys: [.muteListCount, .muteListCountCamel])
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

public struct RemoteGroupDetail: Decodable, Sendable {
    public let explicitMyRole: String?
    public let memberFriendApplyEnabled: Bool
    public let summary: RemoteUserGroup
    public let myRole: String
    public let owner: RemoteUserGroupMember?
    public let admins: [RemoteUserGroupMember]
    public let memberCount: Int?
    public let currentAnnouncement: RemoteGroupAnnouncement?
    public let settings: RemoteGroupSettings
    public let groupMuted: Bool
    public let canManageMuteList: Bool?
    public let muteListCount: Int?

    public var historyVisibleFromSeq: Int64 { summary.historyVisibleFromSeq }
    public var historyLimited: Bool { summary.historyLimited }

    enum CodingKeys: String, CodingKey {
        case group
        case summary
        case myRole = "my_role"
        case owner
        case admins
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case membersCount = "members_count"
        case membersCountCamel = "membersCount"
        case memberTotal = "member_total"
        case memberNum = "member_num"
        case memberNumCamel = "memberNum"
        case totalMembers = "total_members"
        case totalMembersCamel = "totalMembers"
        case membersTotal = "members_total"
        case membersTotalCamel = "membersTotal"
        case total
        case currentAnnouncement = "current_announcement"
        case settings
        case groupMuted = "group_muted"
        case groupMutedCamel = "groupMuted"
        case canManageMuteList = "can_manage_mute_list"
        case canManageMuteListCamel = "canManageMuteList"
        case muteListCount = "mute_list_count"
        case muteListCountCamel = "muteListCount"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let summaryCandidate = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .summary)
        let groupCandidate = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .group)
        let decodedSummary = summaryCandidate ?? groupCandidate ?? .empty
        summary = decodedSummary
        explicitMyRole = try c.decodeIfPresent(String.self, forKey: .myRole) ?? decodedSummary.explicitMyRole
        myRole = explicitMyRole ?? decodedSummary.myRole
        owner = try c.decodeIfPresent(RemoteUserGroupMember.self, forKey: .owner)
        admins = try c.decodeIfPresent([RemoteUserGroupMember].self, forKey: .admins) ?? []
        memberCount = Self.decodeFlexibleInt(
            from: c,
            keys: [
                .memberCount,
                .memberCountCamel,
                .membersCount,
                .membersCountCamel,
                .memberTotal,
                .memberNum,
                .memberNumCamel,
                .totalMembers,
                .totalMembersCamel,
                .membersTotal,
                .membersTotalCamel,
                .total
            ]
        ) ?? decodedSummary.memberCount
        currentAnnouncement = try c.decodeIfPresent(RemoteGroupAnnouncement.self, forKey: .currentAnnouncement)
        let decodedSettings = try c.decodeIfPresent(RemoteGroupSettings.self, forKey: .settings)
        settings = decodedSettings ?? .empty
        memberFriendApplyEnabled = decodedSettings?.memberFriendApplyEnabled ?? decodedSummary.memberFriendApplyEnabled ?? true
        groupMuted = c.decodeLossyBoolIfPresent(forKey: .groupMuted)
            ?? c.decodeLossyBoolIfPresent(forKey: .groupMutedCamel)
            ?? decodedSummary.groupMuted
        canManageMuteList = c.decodeLossyBoolIfPresent(forKey: .canManageMuteList)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageMuteListCamel)
            ?? decodedSummary.canManageMuteList
            ?? settings.canManageMuteList
        muteListCount = Self.decodeFlexibleInt(from: c, keys: [.muteListCount, .muteListCountCamel])
            ?? decodedSummary.muteListCount
            ?? settings.muteListCount
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

public struct RemoteGroupSummaryCounts: Decodable, Sendable {
    public let memberCount: Int?
    public let adminCount: Int?
    public let pendingJoinRequestCount: Int
    public let fileCount: Int

    enum CodingKeys: String, CodingKey {
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case adminCount = "admin_count"
        case adminCountCamel = "adminCount"
        case pendingJoinRequestCount = "pending_join_request_count"
        case pendingJoinRequestCountCamel = "pendingJoinRequestCount"
        case fileCount = "file_count"
        case fileCountCamel = "fileCount"
    }

    public init() {
        memberCount = nil
        adminCount = nil
        pendingJoinRequestCount = 0
        fileCount = 0
    }

    public init(memberCount: Int?, adminCount: Int?, pendingJoinRequestCount: Int, fileCount: Int) {
        self.memberCount = memberCount
        self.adminCount = adminCount
        self.pendingJoinRequestCount = pendingJoinRequestCount
        self.fileCount = fileCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberCount = c.decodeLossyIntIfPresent(forKey: .memberCount)
            ?? c.decodeLossyIntIfPresent(forKey: .memberCountCamel)
        adminCount = c.decodeLossyIntIfPresent(forKey: .adminCount)
            ?? c.decodeLossyIntIfPresent(forKey: .adminCountCamel)
        pendingJoinRequestCount = c.decodeLossyIntIfPresent(forKey: .pendingJoinRequestCount)
            ?? c.decodeLossyIntIfPresent(forKey: .pendingJoinRequestCountCamel)
            ?? 0
        fileCount = c.decodeLossyIntIfPresent(forKey: .fileCount)
            ?? c.decodeLossyIntIfPresent(forKey: .fileCountCamel)
            ?? 0
    }
}

public struct RemoteGroupSummary: Decodable, Sendable {
    public let explicitMyRole: String?
    public let memberFriendApplyEnabled: Bool
    public let summary: RemoteUserGroup
    public let myRole: String
    public let memberCount: Int?
    public let owner: RemoteUserGroupMember?
    public let memberPreview: [RemoteUserGroupMember]
    public let counts: RemoteGroupSummaryCounts
    public let currentAnnouncement: RemoteGroupAnnouncement?
    public let settings: RemoteGroupSettings
    public let historyVisibleFromSeq: Int64
    public let historyLimited: Bool
    public let groupMuted: Bool
    public let canManageMuteList: Bool?
    public let muteListCount: Int?

    enum CodingKeys: String, CodingKey {
        case group
        case summary
        case myRole = "my_role"
        case memberCount = "member_count"
        case memberCountCamel = "memberCount"
        case membersCount = "members_count"
        case membersCountCamel = "membersCount"
        case total
        case owner
        case memberPreview = "member_preview"
        case memberPreviewCamel = "memberPreview"
        case counts
        case currentAnnouncement = "current_announcement"
        case settings
        case historyVisibleFromSeq = "history_visible_from_seq"
        case historyVisibleFromSeqCamel = "historyVisibleFromSeq"
        case historyLimited = "history_limited"
        case historyLimitedCamel = "historyLimited"
        case groupMuted = "group_muted"
        case groupMutedCamel = "groupMuted"
        case canManageMuteList = "can_manage_mute_list"
        case canManageMuteListCamel = "canManageMuteList"
        case muteListCount = "mute_list_count"
        case muteListCountCamel = "muteListCount"
    }

    public var isMemberPreviewComplete: Bool {
        guard let memberCount else { return false }
        return memberCount > 0 && memberPreview.count >= memberCount
    }

    public init(
        summary: RemoteUserGroup,
        myRole: String,
        memberCount: Int?,
        owner: RemoteUserGroupMember?,
        memberPreview: [RemoteUserGroupMember],
        counts: RemoteGroupSummaryCounts,
        currentAnnouncement: RemoteGroupAnnouncement?,
        settings: RemoteGroupSettings,
        explicitMyRole: String? = nil,
        memberFriendApplyEnabled: Bool? = nil,
        historyVisibleFromSeq: Int64 = 1,
        historyLimited: Bool = false,
        groupMuted: Bool = false,
        canManageMuteList: Bool? = nil,
        muteListCount: Int? = nil
    ) {
        self.summary = summary
        self.myRole = myRole
        self.explicitMyRole = explicitMyRole
        self.memberFriendApplyEnabled = memberFriendApplyEnabled ?? settings.memberFriendApplyEnabled
        self.memberCount = memberCount
        self.owner = owner
        self.memberPreview = memberPreview
        self.counts = counts
        self.currentAnnouncement = currentAnnouncement
        self.settings = settings
        self.historyVisibleFromSeq = max(1, historyVisibleFromSeq)
        self.historyLimited = historyLimited
        self.groupMuted = groupMuted
        self.canManageMuteList = canManageMuteList
        self.muteListCount = muteListCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let summaryCandidate = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .summary)
        let groupCandidate = try c.decodeIfPresent(RemoteUserGroup.self, forKey: .group)
        let decodedSummary = summaryCandidate ?? groupCandidate ?? .empty
        summary = decodedSummary
        explicitMyRole = try c.decodeIfPresent(String.self, forKey: .myRole) ?? decodedSummary.explicitMyRole
        myRole = explicitMyRole ?? decodedSummary.myRole
        let decodedCounts = try c.decodeIfPresent(RemoteGroupSummaryCounts.self, forKey: .counts) ?? RemoteGroupSummaryCounts()
        counts = decodedCounts
        let decodedMemberCount = Self.decodeFlexibleInt(
            from: c,
            keys: [.memberCount, .memberCountCamel, .membersCount, .membersCountCamel, .total]
        ) ?? decodedCounts.memberCount
        memberCount = (decodedMemberCount ?? 0) > 0 ? decodedMemberCount : decodedSummary.memberCount
        owner = try c.decodeIfPresent(RemoteUserGroupMember.self, forKey: .owner)
        memberPreview = try c.decodeIfPresent([RemoteUserGroupMember].self, forKey: .memberPreview)
            ?? c.decodeIfPresent([RemoteUserGroupMember].self, forKey: .memberPreviewCamel)
            ?? []
        currentAnnouncement = try c.decodeIfPresent(RemoteGroupAnnouncement.self, forKey: .currentAnnouncement)
        let decodedSettings = try c.decodeIfPresent(RemoteGroupSettings.self, forKey: .settings)
        settings = decodedSettings ?? .empty
        memberFriendApplyEnabled = decodedSettings?.memberFriendApplyEnabled ?? decodedSummary.memberFriendApplyEnabled ?? true
        historyVisibleFromSeq = max(
            1,
            c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeq)
                ?? c.decodeLossyInt64IfPresent(forKey: .historyVisibleFromSeqCamel)
                ?? decodedSummary.historyVisibleFromSeq
        )
        historyLimited = c.decodeLossyBoolIfPresent(forKey: .historyLimited)
            ?? c.decodeLossyBoolIfPresent(forKey: .historyLimitedCamel)
            ?? decodedSummary.historyLimited
        groupMuted = c.decodeLossyBoolIfPresent(forKey: .groupMuted)
            ?? c.decodeLossyBoolIfPresent(forKey: .groupMutedCamel)
            ?? decodedSummary.groupMuted
        canManageMuteList = c.decodeLossyBoolIfPresent(forKey: .canManageMuteList)
            ?? c.decodeLossyBoolIfPresent(forKey: .canManageMuteListCamel)
            ?? decodedSummary.canManageMuteList
            ?? settings.canManageMuteList
        muteListCount = Self.decodeFlexibleInt(from: c, keys: [.muteListCount, .muteListCountCamel])
            ?? decodedSummary.muteListCount
            ?? settings.muteListCount
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}
// WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_END

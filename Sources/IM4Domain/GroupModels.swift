// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：群邀请审批消息载荷允许安全跨异步任务传递
public struct GroupInviteApproval: Identifiable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        requestID: String,
        requestType: String,
        groupID: String,
        groupName: String,
        inviterName: String,
        inviterAccountID: String,
        inviteeName: String,
        inviteeAccountID: String,
        status: String,
        resultText: String,
        processed: Bool,
        approverName: String,
        approverAccountID: String,
        decidedAt: String,
        canApprove: Bool,
        canReject: Bool,
        approveEndpoint: String,
        rejectEndpoint: String,
        actionEndpoint: String,
        kind: String
    ) {
        self.requestID = requestID
        self.requestType = requestType
        self.groupID = groupID
        self.groupName = groupName
        self.inviterName = inviterName
        self.inviterAccountID = inviterAccountID
        self.inviteeName = inviteeName
        self.inviteeAccountID = inviteeAccountID
        self.status = status
        self.resultText = resultText
        self.processed = processed
        self.approverName = approverName
        self.approverAccountID = approverAccountID
        self.decidedAt = decidedAt
        self.canApprove = canApprove
        self.canReject = canReject
        self.approveEndpoint = approveEndpoint
        self.rejectEndpoint = rejectEndpoint
        self.actionEndpoint = actionEndpoint
        self.kind = kind
    }
    public let requestID: String
    public let requestType: String
    public let groupID: String
    public let groupName: String
    public let inviterName: String
    public let inviterAccountID: String
    public let inviteeName: String
    public let inviteeAccountID: String
    public var status: String
    public var resultText: String
    public var processed: Bool
    public var approverName: String
    public var approverAccountID: String
    public var decidedAt: String
    public let canApprove: Bool
    public let canReject: Bool
    public let approveEndpoint: String
    public let rejectEndpoint: String
    public let actionEndpoint: String
    public let kind: String

    public var id: String { requestID }

    public var normalizedRequestType: String {
        requestType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isPending: Bool {
        if processed { return false }
        return normalizedStatus.isEmpty || ["pending", "pending_approval", "waiting", "waiting_approval", "submitted", "reviewing"].contains(normalizedStatus)
    }

    public var isApproved: Bool {
        ["approved", "approve", "accepted", "pass", "passed"].contains(normalizedStatus)
    }

    public var isRejected: Bool {
        ["rejected", "reject", "denied", "declined", "refused"].contains(normalizedStatus)
    }

    public var isCanceled: Bool {
        ["canceled", "cancelled", "cancel"].contains(normalizedStatus)
    }

    public var isExpired: Bool {
        ["expired", "expire", "timed_out", "timeout"].contains(normalizedStatus)
    }

    public var isJoinRequest: Bool {
        normalizedRequestType == "join_request"
            || normalizedRequestType == "join"
            || (!inviteeAccountID.isEmpty && inviterAccountID == inviteeAccountID)
    }

    public var isActionable: Bool {
        kind == "group_invite_approval"
            && !processed
            && isPending
            && ((canApprove && !approveEndpoint.isEmpty) || (canReject && !rejectEndpoint.isEmpty))
    }

    public var statusText: String {
        let trimmedResult = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isPending && !trimmedResult.isEmpty {
            return trimmedResult
        }
        if isApproved {
            return "已通过"
        }
        if isRejected {
            return "已拒绝"
        }
        if isCanceled {
            return "已取消"
        }
        if isExpired {
            return "已过期"
        }
        if processed {
            return trimmedResult.isEmpty ? "已处理" : trimmedResult
        }
        return kind == "group_invite_receipt" ? "等待审核" : "待处理"
    }

    public var actedSummary: String {
        guard !isPending else { return "" }
        let actor = approverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = decidedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !actor.isEmpty && !time.isEmpty { return "\(actor) · \(time)" }
        if !actor.isEmpty { return actor }
        if !time.isEmpty { return time }
        return ""
    }

    public func resolved(status: String, approverName: String = "", approverAccountID: String = "", decidedAt: String = "", resultText: String = "") -> GroupInviteApproval {
        GroupInviteApproval(
            requestID: requestID,
            requestType: requestType,
            groupID: groupID,
            groupName: groupName,
            inviterName: inviterName,
            inviterAccountID: inviterAccountID,
            inviteeName: inviteeName,
            inviteeAccountID: inviteeAccountID,
            status: status,
            resultText: resultText.isEmpty ? self.resultText : resultText,
            processed: true,
            approverName: approverName.isEmpty ? self.approverName : approverName,
            approverAccountID: approverAccountID.isEmpty ? self.approverAccountID : approverAccountID,
            decidedAt: decidedAt.isEmpty ? self.decidedAt : decidedAt,
            canApprove: false,
            canReject: false,
            approveEndpoint: approveEndpoint,
            rejectEndpoint: rejectEndpoint,
            actionEndpoint: actionEndpoint,
            kind: kind
        )
    }
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

public struct GroupInfo: Identifiable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        name: String,
        groupRevision: Int64 = 0,
        avatarURL: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = "",
        notice: String,
        groupDescription: String = "",
        owner: String,
        ownerID: String = "",
        members: [IMUser],
        admins: [IMUser],
        membersPartial: Bool = false,
        membersLoadedCount: Int = 0,
        membersNextOffset: Int? = nil,
        membersNextCursor: String? = nil,
        muted: Bool,
        allMuted: Bool,
        allMuteStart: Date? = nil,
        allMuteEnd: Date? = nil,
        allMuteMode: GroupMuteMode? = nil,
        allMuteActive: Bool? = nil,
        allMuteServerTime: Date? = nil,
        allMuteNextBoundary: Date? = nil,
        allMuteRepairRequired: Bool = false,
        allMuteUpdatedAt: String = "",
        myRole: String = "member",
        memberCount: Int? = nil,
        adminCount: Int? = nil,
        memberFriendApplyEnabled: Bool? = nil,
        memberPreview: [IMUser] = [],
        presentedRole: String? = nil,
        inviteConfirmRequired: Bool = false,
        pendingJoinRequestCount: Int = 0,
        fileCount: Int = 0,
        blacklistCount: Int = 0,
        historyVisible: Bool = true,
        historyVisibleFromSeq: Int64 = 1,
        historyLimited: Bool = false,
        groupMuted: Bool = false,
        canManageMuteList: Bool = false,
        muteListCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.groupRevision = groupRevision
        self.avatarURL = avatarURL
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
        self.notice = notice
        self.groupDescription = groupDescription
        self.owner = owner
        self.ownerID = ownerID
        self.members = members
        self.admins = admins
        self.membersPartial = membersPartial
        self.membersLoadedCount = membersLoadedCount
        self.membersNextOffset = membersNextOffset
        self.membersNextCursor = membersNextCursor
        self.muted = muted
        self.allMuted = allMuted
        self.allMuteStart = allMuteStart
        self.allMuteEnd = allMuteEnd
        self.allMuteMode = allMuteMode
        self.allMuteActive = allMuteActive
        self.allMuteServerTime = allMuteServerTime
        self.allMuteNextBoundary = allMuteNextBoundary
        self.allMuteRepairRequired = allMuteRepairRequired
        self.allMuteUpdatedAt = allMuteUpdatedAt
        self.myRole = myRole
        self.memberCount = memberCount
        self.adminCount = adminCount
        self.memberFriendApplyEnabled = memberFriendApplyEnabled
        self.memberPreview = memberPreview
        self.presentedRole = presentedRole
        self.inviteConfirmRequired = inviteConfirmRequired
        self.pendingJoinRequestCount = pendingJoinRequestCount
        self.fileCount = fileCount
        self.blacklistCount = blacklistCount
        self.historyVisible = historyVisible
        self.historyVisibleFromSeq = historyVisibleFromSeq
        self.historyLimited = historyLimited
        self.groupMuted = groupMuted
        self.canManageMuteList = canManageMuteList
        self.muteListCount = muteListCount
    }
    public let id: String
    public let name: String
    public var groupRevision: Int64 = 0
    public var avatarURL: String = ""
    public var avatarVersion: String = ""
    public var avatarUpdatedAt: String = ""
    public let notice: String
    public var groupDescription: String = ""
    public var owner: String
    public var ownerID: String = ""
    public var members: [IMUser]
    public var admins: [IMUser]
    public var membersPartial: Bool = false
    public var membersLoadedCount: Int = 0
    public var membersNextOffset: Int? = nil
    public var membersNextCursor: String? = nil
    public var muted: Bool
    public var allMuted: Bool
    public var allMuteStart: Date?
    public var allMuteEnd: Date?
    public var allMuteMode: GroupMuteMode? = nil
    public var allMuteActive: Bool? = nil
    public var allMuteServerTime: Date? = nil
    public var allMuteNextBoundary: Date? = nil
    public var allMuteRepairRequired: Bool = false
    public var allMuteUpdatedAt: String = ""
    public var myRole: String = "member"
    public var memberCount: Int? = nil
    public var adminCount: Int? = nil
    public var memberFriendApplyEnabled: Bool? = nil
    public var memberPreview: [IMUser] = []
    public var presentedRole: String? = nil
    public var inviteConfirmRequired: Bool = false
    public var pendingJoinRequestCount: Int = 0
    public var fileCount: Int = 0
    public var blacklistCount: Int = 0
    public var historyVisible: Bool = true
    public var historyVisibleFromSeq: Int64 = 1
    public var historyLimited: Bool = false
    public var groupMuted: Bool = false
    public var canManageMuteList: Bool = false
    public var muteListCount: Int? = nil

    public var effectiveMemberCount: Int {
        (memberCount ?? 0) > 0 ? (memberCount ?? 0) : members.count
    }

    public var visibleMemberCount: Int? {
        memberCount.flatMap { $0 > 0 ? $0 : nil }
    }

    public var memberCountDisplayText: String {
        visibleMemberCount.map { "\($0) 人" } ?? "人数待同步"
    }


    public var canCurrentUserManage: Bool {
        myRole == "owner" || myRole == "admin"
    }

    public var muteListStatusText: String {
        guard canManageMuteList else { return "仅群主或管理员可查看" }
        guard let muteListCount else { return "查看、添加或移除成员" }
        return muteListCount > 0 ? "\(muteListCount) 人已禁言" : "暂无禁言成员"
    }

    public var historyVisibilityStatusText: String {
        historyVisible ? "全部可见" : "仅入群后"
    }

    public var isCurrentUserOwner: Bool {
        myRole == "owner"
    }

    public func isAllMuteActive(at date: Date = Date()) -> Bool {
        if let allMuteActive {
            return allMuteActive
        }
        guard allMuted else { return false }
        guard let allMuteStart, let allMuteEnd else { return true }
        return date >= allMuteStart && date < allMuteEnd
    }

    public func allMuteTimeRangeText() -> String {
        guard let allMuteStart, let allMuteEnd else { return "当前立即生效" }
        let suffix = Calendar.current.isDate(allMuteStart, inSameDayAs: allMuteEnd) ? "" : "次日 "
        return "\(GroupInfo.shortTimeFormatter.string(from: allMuteStart)) - \(suffix)\(GroupInfo.shortTimeFormatter.string(from: allMuteEnd))"
    }

    public func allMuteStatusText(at date: Date = Date()) -> String {
        if allMuteRepairRequired {
            return isAllMuteActive(at: date) ? "禁言中（状态待修复）" : "状态待修复"
        }
        guard allMuteMode != .off, allMuted else { return "未开启" }
        if allMuteMode == .always || (allMuteMode == nil && allMuteStart == nil && allMuteEnd == nil) {
            return "一直禁言中"
        }
        guard let allMuteStart, let allMuteEnd else { return isAllMuteActive(at: date) ? "禁言中" : "未开启" }
        let serverNow = allMuteServerTime ?? date
        if serverNow < allMuteStart {
            return "待生效 \(allMuteTimeRangeText())"
        }
        if serverNow >= allMuteEnd {
            return "已结束 \(allMuteTimeRangeText())"
        }
        return "固定时段禁言中 \(allMuteTimeRangeText())"
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

public struct GroupAnnouncement: Identifiable, Hashable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        groupID: String,
        title: String,
        content: String,
        summary: String,
        createdBy: String,
        status: String,
        createdAt: String,
        updatedAt: String,
        publishedAt: String,
        unread: Bool,
        readAt: String?,
        displayPosition: String,
        readAction: String,
        readCount: Int?,
        unreadCount: Int?,
        recipientCount: Int?,
        canViewReadCounts: Bool
    ) {
        self.id = id
        self.groupID = groupID
        self.title = title
        self.content = content
        self.summary = summary
        self.createdBy = createdBy
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.publishedAt = publishedAt
        self.unread = unread
        self.readAt = readAt
        self.displayPosition = displayPosition
        self.readAction = readAction
        self.readCount = readCount
        self.unreadCount = unreadCount
        self.recipientCount = recipientCount
        self.canViewReadCounts = canViewReadCounts
    }
    public let id: String
    public let groupID: String
    public let title: String
    public let content: String
    public let summary: String
    public let createdBy: String
    public let status: String
    public let createdAt: String
    public let updatedAt: String
    public let publishedAt: String
    public let unread: Bool
    public let readAt: String?
    public let displayPosition: String
    public let readAction: String
    public let readCount: Int?
    public let unreadCount: Int?
    public let recipientCount: Int?
    public let canViewReadCounts: Bool

    public var readCountSummary: String? {
        guard canViewReadCounts,
              let readCount,
              let unreadCount,
              let recipientCount else { return nil }
        return "\(readCount) 人已读 · \(unreadCount) 人未读 · 共 \(recipientCount) 人"
    }

    public func scrubbingReadCounts() -> GroupAnnouncement {
        GroupAnnouncement(
            id: id,
            groupID: groupID,
            title: title,
            content: content,
            summary: summary,
            createdBy: createdBy,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            publishedAt: publishedAt,
            unread: unread,
            readAt: readAt,
            displayPosition: displayPosition,
            readAction: readAction,
            readCount: nil,
            unreadCount: nil,
            recipientCount: nil,
            canViewReadCounts: false
        )
    }
}

public enum GroupAnnouncementPrivacyProjection {
    public static func sanitize(
        _ announcement: GroupAnnouncement,
        requestEpoch: UInt64,
        currentEpoch: UInt64
    ) -> GroupAnnouncement {
        requestEpoch == currentEpoch ? announcement : announcement.scrubbingReadCounts()
    }
}

public enum GroupAnnouncementRevisionProjection {
    public static func preferred(
        existing: GroupAnnouncement,
        incoming: GroupAnnouncement,
        existingRevision: Date?,
        incomingRevision: Date?
    ) -> GroupAnnouncement {
        if let existingRevision, let incomingRevision {
            if incomingRevision < existingRevision { return existing }
            if incomingRevision == existingRevision, !existing.unread, incoming.unread { return existing }
        } else if !existing.updatedAt.isEmpty, incoming.updatedAt.isEmpty {
            return existing
        }
        return incoming
    }
}




public struct GroupJoinRequest: Identifiable, Hashable {
    public let id: String
    public let groupID: String
    public let applicantUID: String
    public let applicantName: String
    public let applicantAvatarURL: String
    public let inviterAvatarURL: String
    public let inviterName: String
    public var status: String
    public let message: String
    public let createdAt: String

    public init(
        id: String,
        groupID: String,
        applicantUID: String,
        applicantName: String,
        applicantAvatarURL: String = "",
        inviterAvatarURL: String = "",
        inviterName: String,
        status: String,
        message: String,
        createdAt: String
    ) {
        self.id = id
        self.groupID = groupID
        self.applicantUID = applicantUID
        self.applicantName = applicantName
        self.applicantAvatarURL = applicantAvatarURL
        self.inviterAvatarURL = inviterAvatarURL
        self.inviterName = inviterName
        self.status = status
        self.message = message
        self.createdAt = createdAt
    }
}

public struct GroupMuteListItem: Identifiable, Hashable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        groupID: String,
        targetUID: String,
        targetUserID: String,
        targetUsername: String,
        targetNickname: String,
        targetAvatarURL: String,
        targetRole: String,
        operatorUID: String,
        operatorName: String,
        reason: String,
        createdAt: String,
        updatedAt: String,
        createdAtText: String,
        updatedAtText: String
    ) {
        self.groupID = groupID
        self.targetUID = targetUID
        self.targetUserID = targetUserID
        self.targetUsername = targetUsername
        self.targetNickname = targetNickname
        self.targetAvatarURL = targetAvatarURL
        self.targetRole = targetRole
        self.operatorUID = operatorUID
        self.operatorName = operatorName
        self.reason = reason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdAtText = createdAtText
        self.updatedAtText = updatedAtText
    }
    public let groupID: String
    public let targetUID: String
    public let targetUserID: String
    public let targetUsername: String
    public let targetNickname: String
    public let targetAvatarURL: String
    public let targetRole: String
    public let operatorUID: String
    public let operatorName: String
    public let reason: String
    public let createdAt: String
    public let updatedAt: String
    public let createdAtText: String
    public let updatedAtText: String

    public var id: String {
        "\(groupID)|\(targetUID)"
    }

    public var targetDisplayName: String {
        [targetNickname, targetUsername, targetUserID, targetUID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名成员"
    }

    public var targetDisplayID: String {
        [targetUserID, targetUID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? targetUsername
    }

    public var reasonText: String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未填写原因" : trimmed
    }

    public var operatorText: String {
        let name = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "管理员" : name
    }
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END

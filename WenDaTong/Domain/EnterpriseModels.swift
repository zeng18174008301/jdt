import Foundation

struct Enterprise: Identifiable, Hashable {
    let id: String
    let name: String
    let code: String
    let role: String
    let status: String
    let memberCount: Int
    let isDefault: Bool
    let accentHex: UInt
    var logoURL: String = ""
    var logoStatus: String = ""
    var logoVersion: String = ""
    var logoUpdatedAt: String = ""
    var logoCacheKey: String = ""
    var logoMime: String = ""
    var logoWidth: Int? = nil
    var logoHeight: Int? = nil
    var joinStatus: String = "joined"
    var applicationID: String = ""
    var applicationStatus: String = ""
    var approvalRequired: Bool = false
    var canSwitch: Bool = true
    var enterable: Bool? = nil
    var isCurrent: Bool = false
    var accountStatus: String = ""
    var tenantStatus: String = ""
    var memberStatus: String = ""
    var disabledReason: String = ""
    var searchEntryType: String = ""
    var searchInviterName: String = ""

    var displayCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchInviteDisplayLine: String {
        let normalizedEntryType = Self.normalizedWorkspaceStatus(searchEntryType)
        guard normalizedEntryType == "memberinvitecode" else { return "" }
        let inviter = searchInviterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inviter.isEmpty else { return "" }
        return "邀请人：\(inviter)"
    }

    private var normalizedJoinStatus: String {
        Self.normalizedWorkspaceStatus(joinStatus)
    }

    private var normalizedApplicationStatus: String {
        Self.normalizedWorkspaceStatus(applicationStatus)
    }

    var isWorkspaceJoinPending: Bool {
        Self.pendingWorkspaceStatuses.contains(normalizedJoinStatus)
            || Self.pendingWorkspaceStatuses.contains(normalizedApplicationStatus)
    }

    var isWorkspaceJoinRejected: Bool {
        Self.rejectedWorkspaceStatuses.contains(normalizedJoinStatus)
            || Self.rejectedWorkspaceStatuses.contains(normalizedApplicationStatus)
    }

    var isWorkspaceJoinApproved: Bool {
        Self.approvedWorkspaceStatuses.contains(normalizedJoinStatus)
            || Self.approvedWorkspaceStatuses.contains(normalizedApplicationStatus)
    }

    var isWorkspaceJoined: Bool {
        Self.joinedWorkspaceStatuses.contains(normalizedJoinStatus) || isWorkspaceJoinApproved
    }

    var isWorkspaceEnterable: Bool {
        enterable ?? canSwitch
    }

    var isLogoRenderable: Bool {
        let normalizedStatus = Self.normalizedWorkspaceStatus(logoStatus)
        guard !Self.unrenderableLogoStatuses.contains(normalizedStatus) else { return false }
        return !logoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func logoImageCacheKey(scope: String) -> String {
        [
            "enterprise-logo",
            scope,
            id,
            logoCacheKey,
            logoVersion,
            logoUpdatedAt,
            logoMime,
            logoWidth.map(String.init) ?? "",
            logoHeight.map(String.init) ?? "",
            logoURL
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    var workspaceDisabledDescription: String {
        let rawReason = disabledReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = Self.normalizedWorkspaceStatus(rawReason)
        let normalizedAccountStatus = Self.normalizedWorkspaceStatus(accountStatus)
        let normalizedTenantStatus = Self.normalizedWorkspaceStatus(tenantStatus)
        let normalizedMemberStatus = Self.normalizedWorkspaceStatus(memberStatus)
        switch reason {
        case "accountlocked", "locked":
            return "账号已锁定"
        case "accountdisabled":
            return "账号已停用"
        case "iploginblocked":
            return "当前网络已被禁止登录"
        case "tenantdisabled", "tenantservicestopped":
            return "企业已停用"
        case "workspacesessionunavailable", "tenantserviceunavailable":
            return "企业服务暂不可用"
        case "defaultworkspaceunavailable":
            return "默认企业暂不可进入"
        case "defaultworkspacenotfound":
            return "默认企业不存在"
        case "appnotfound":
            return "企业应用不可用"
        case "memberdisabled", "tenantmemberdisabled":
            return "成员已停用"
        case "tenantmembernotfound", "membernotfound":
            return "企业成员不存在"
        case "workspacenotfound", "tenantnotfound":
            return "企业不存在"
        case "workspaceidentityunlinked":
            return "企业身份未同步"
        case "memberprojectionsyncing", "memberprojectionmissing", "memberprojectionstale":
            return "成员数据正在同步"
        case "memberprojectionfailed":
            return "成员数据同步失败"
        case "pending":
            return "等待审批"
        case "rejected":
            return "已拒绝"
        case "forbidden":
            return "无权限进入"
        case "joinstatus", "notjoined", "unjoined":
            return isWorkspaceJoinPending ? "等待审批" : isWorkspaceJoinRejected ? "已拒绝" : ""
        default:
            if !reason.isEmpty, reason.hasPrefix("member") {
                return "成员已停用"
            }
            let disabledTenantStatuses = ["disabled", "suspended", "stopped", "tenantdisabled", "tenantservicestopped"]
            if disabledTenantStatuses.contains(normalizedTenantStatus) {
                return "企业已停用"
            }
            if isWorkspaceJoinPending {
                return "等待审批"
            }
            if isWorkspaceJoinRejected {
                return "已拒绝"
            }
            let lockedAccountStatuses = ["accountlocked", "locked"]
            if lockedAccountStatuses.contains(normalizedAccountStatus) {
                return "账号已锁定"
            }
            if normalizedAccountStatus == "ipblocked" {
                return "当前网络已被禁止登录"
            }
            let activeAccountStatuses = ["", "normal", "active", "enabled"]
            if !activeAccountStatuses.contains(normalizedAccountStatus) {
                return "账号已停用"
            }
            let activeTenantStatuses = ["", "normal", "active", "enabled"]
            if !activeTenantStatuses.contains(normalizedTenantStatus) {
                return "企业已停用"
            }
            let activeMemberStatuses = ["", "normal", "active", "enabled", "joined"]
            if !activeMemberStatuses.contains(normalizedMemberStatus), isWorkspaceJoined {
                return "成员已停用"
            }
            if let humanReason = Self.humanReadableWorkspaceReason(rawReason) {
                return humanReason
            }
            if !isWorkspaceEnterable, isWorkspaceJoined {
                return "不可进入"
            }
            return ""
        }
    }

    private static let pendingWorkspaceStatuses: Set<String> = [
        "pending", "pendingapproval", "pendingreview", "waiting", "waitingapproval", "submitted", "reviewing",
        "approvalrequired", "requiresapproval", "requiresreview", "workspacejoinpending"
    ]

    private static let rejectedWorkspaceStatuses: Set<String> = [
        "rejected", "reject", "denied", "declined", "refused", "workspacejoinrejected"
    ]

    private static let approvedWorkspaceStatuses: Set<String> = [
        "approved", "approve", "accepted", "pass", "passed", "through", "autoapproved", "autoaccepted", "autopassed",
        "workspacejoinapproved"
    ]

    private static let joinedWorkspaceStatuses: Set<String> = [
        "joined", "alreadyjoined", "workspacealreadyjoined", "active", "enabled", "normal"
    ]

    private static let unrenderableLogoStatuses: Set<String> = [
        "unsafe", "missing", "deleted", "blocked", "rejected", "unavailable", "disabled", "invalid", "forbidden"
    ]

    private static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    private static func humanReadableWorkspaceReason(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.unicodeScalars.contains(where: { $0.value > 127 }) {
            return trimmed
        }
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return trimmed
        }
        return nil
    }
}

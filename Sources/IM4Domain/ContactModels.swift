// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

public let cancelledUserDisplayName = "用户已注销"
public let cancelledUserAvatarPath = "/avatars/user-cancelled-gray.svg"

public func isCancelledUserStatus(_ rawValue: String) -> Bool {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["cancelled", "canceled", "cancel", "account_cancelled", "account_canceled"].contains(normalized)
}

public func isCancelledUserAvatarURL(_ rawValue: String) -> Bool {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return false }
    if let url = URL(string: normalized), url.path.lowercased() == cancelledUserAvatarPath {
        return true
    }
    return normalized == cancelledUserAvatarPath || normalized.hasSuffix(cancelledUserAvatarPath)
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：会话参与人模型允许安全跨异步任务传递
public struct IMUser: Identifiable, Hashable, Sendable {
    public let id: String
    public let userID: String
    public let username: String
    public let name: String
    public let title: String
    public let department: String
    public let departmentPathNames: [String]
    public let phone: String
    public let phoneVerified: Bool
    public let realNameVerified: Bool
    public let realNameStatus: String
    public let email: String
    public let status: String
    public let lastLoginAt: String
    public let enterprise: String
    public let avatarSeed: UInt
    public let avatarURL: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let badges: [String]

    public init(
        id: String,
        userID: String = "",
        username: String = "",
        name: String,
        title: String,
        department: String,
        departmentPathNames: [String] = [],
        phone: String,
        phoneVerified: Bool = false,
        realNameVerified: Bool = false,
        realNameStatus: String = "",
        email: String,
        status: String,
        lastLoginAt: String = "",
        enterprise: String,
        avatarSeed: UInt,
        avatarURL: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = "",
        badges: [String]
    ) {
        self.id = id
        self.userID = userID.isEmpty ? id : userID
        self.username = username
        self.name = name
        self.title = title
        self.department = department
        self.departmentPathNames = departmentPathNames
        self.phone = phone
        self.phoneVerified = phoneVerified
        self.realNameVerified = realNameVerified
        self.realNameStatus = realNameStatus
        self.email = email
        self.status = status
        self.lastLoginAt = lastLoginAt
        self.enterprise = enterprise
        self.avatarSeed = avatarSeed
        self.avatarURL = avatarURL
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
        self.badges = badges
    }


    public var isCancelledUser: Bool {
        isCancelledUserStatus(status) || isCancelledUserAvatarURL(avatarURL)
    }

    public var displayName: String {
        isCancelledUser ? cancelledUserDisplayName : name
    }

    public var displayAvatarURL: String {
        isCancelledUser ? cancelledUserAvatarPath : avatarURL
    }

    public func withDepartment(_ department: String, pathNames: [String] = []) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            username: username,
            name: name,
            title: title,
            department: department,
            departmentPathNames: pathNames,
            phone: phone,
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameStatus,
            email: email,
            status: status,
            lastLoginAt: lastLoginAt,
            enterprise: enterprise,
            avatarSeed: avatarSeed,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            badges: badges
        )
    }

    public func withName(_ name: String) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            username: username,
            name: name,
            title: title,
            department: department,
            departmentPathNames: departmentPathNames,
            phone: phone,
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameStatus,
            email: email,
            status: status,
            lastLoginAt: lastLoginAt,
            enterprise: enterprise,
            avatarSeed: avatarSeed,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            badges: badges
        )
    }
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

public enum IMUserSearchMatcher {
    public static func matches(user: IMUser, role: String = "", query: String) -> Bool {
        matchScore(user: user, role: role, query: query) != nil
    }

    public static func matchScore(user: IMUser, role: String = "", query: String) -> Int? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return 0 }

        var bestScore: Int?
        for (index, key) in searchableKeys(for: user, role: role).enumerated() {
            guard key.contains(needle) else { continue }
            let matchRank: Int
            if key == needle {
                matchRank = 0
            } else if key.hasPrefix(needle) {
                matchRank = 10
            } else {
                matchRank = 30
            }
            let score = matchRank + min(index, 12)
            bestScore = min(bestScore ?? score, score)
        }
        return bestScore
    }

    public static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'’")))
            .joined()
            .lowercased()
    }

    private static func isLatinLetterQuery(_ value: String) -> Bool {
        let needle = normalized(value)
        guard !needle.isEmpty else { return false }
        var hasLetter = false
        for scalar in needle.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                hasLetter = true
                continue
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                continue
            }
            return false
        }
        return hasLetter
    }

    private static func searchableKeys(for user: IMUser, role: String = "") -> [String] {
        let fields = [
            user.name,
            user.id,
            user.userID,
            user.username,
            user.title,
            user.phone,
            user.email,
            user.enterprise,
            role
        ] + user.badges

        return fields.flatMap { searchVariants(for: $0) }.deduplicated()
    }

    public static func sortedMatches(users: [IMUser], role: String = "", query: String) -> [IMUser] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return users }
        return users
            .compactMap { user -> (IMUser, Int)? in
                guard let score = matchScore(user: user, role: role, query: query) else { return nil }
                return (user, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let lhsName = sortNameKey(for: lhs.0)
                let rhsName = sortNameKey(for: rhs.0)
                if lhsName != rhsName { return lhsName < rhsName }
                return mentionStableKey(for: lhs.0) < mentionStableKey(for: rhs.0)
            }
            .map(\.0)
    }

    private static func sortNameKey(for user: IMUser) -> String {
        let name = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinyin = normalized(name.applyingTransform(.toLatin, reverse: false) ?? name)
        return pinyin.isEmpty ? normalized(name) : pinyin
    }

    private static func mentionStableKey(for user: IMUser) -> String {
        let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { return id }
        let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userID.isEmpty { return userID }
        return user.username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchVariants(for value: String) -> [String] {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        let normalizedRaw = normalized(raw)
        let latin = raw.applyingTransform(.toLatin, reverse: false) ?? raw
        let pinyin = normalized(latin)
        let phraseInitials = pinyinInitials(fromLatin: latin)
        let characterInitials = pinyinInitials(for: raw)

        return [normalizedRaw, pinyin, phraseInitials, characterInitials].filter { !$0.isEmpty }
    }

    private static func pinyinInitials(fromLatin value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func pinyinInitials(for value: String) -> String {
        value.reduce(into: "") { result, character in
            let text = String(character)
            let latin = normalized(text.applyingTransform(.toLatin, reverse: false) ?? text)
            if let first = latin.first {
                result.append(first)
            }
        }
    }
}

private extension Array where Element == String {
    func deduplicated() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

public struct UserSearchResult: Identifiable, Hashable {
    public let imUID: String
    public let userID: String
    public let nickname: String
    public let phone: String
    public let avatarURL: String
    public let status: String
    public let presenceStatus: String
    public var relationStatus: String
    public var canApplyFriend: Bool
    public var reason: String
    public var friendAction: String
    public var friendFlow: String
    public var requiresTenantReview: Bool?
    public var requiresTargetApproval: Bool?

    public var id: String { imUID.isEmpty ? userID : imUID }
    public var isCancelledUser: Bool {
        isCancelledUserStatus(status) || isCancelledUserAvatarURL(avatarURL)
    }
    public var displayName: String { isCancelledUser ? cancelledUserDisplayName : (nickname.isEmpty ? id : nickname) }
    public var displayAvatarURL: String { isCancelledUser ? cancelledUserAvatarPath : avatarURL }

    public init(
        imUID: String,
        userID: String,
        nickname: String,
        phone: String,
        avatarURL: String,
        status: String,
        presenceStatus: String = "",
        relationStatus: String,
        canApplyFriend: Bool,
        reason: String,
        friendAction: String = "",
        friendFlow: String = "",
        requiresTenantReview: Bool? = nil,
        requiresTargetApproval: Bool? = nil
    ) {
        self.imUID = imUID
        self.userID = userID
        self.nickname = nickname
        self.phone = phone
        self.avatarURL = avatarURL
        self.status = status
        self.presenceStatus = presenceStatus
        self.relationStatus = relationStatus
        self.canApplyFriend = canApplyFriend
        self.reason = reason
        self.friendAction = friendAction
        self.friendFlow = friendFlow
        self.requiresTenantReview = requiresTenantReview
        self.requiresTargetApproval = requiresTargetApproval
    }
}

public enum FriendApplyResolution: Equatable {
    case pending
    case established
    case terminal
}

public enum FriendAddPresentation {
    public static let actionTitle = "添加好友"
    public static let waitingTitle = "等待对方通过"
    public static let sentMessage = "申请已发送，等待对方通过"
    public static let establishedMessage = "已添加为好友"
    public static let suppressedMessage = "申请未投递，当前策略不允许添加好友"
    public static let terminalMessage = "申请未生效，请查看最新状态"
    public static let relationChangedMessage = "好友关系已更新，请查看最新状态"
}

public struct FriendRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let userID: String
    public let avatarURL: String
    public let source: String
    public let message: String
    public let status: String
    public let direction: String
    public let tenantReviewStatus: String
    public let peerReviewStatus: String
    public let canRespond: Bool
    public let outcome: String
    public let relationStatus: String
    public let friendAction: String
    public let friendFlow: String
    public let directlyEstablished: Bool
    public let requiresTenantReview: Bool?
    public let requiresTargetApproval: Bool?
    public let resolutionMode: String
    public var accepted: Bool

    public var isPendingIncoming: Bool {
        direction == "incoming" && status == "pending" && canRespond
    }

    public var isPendingOutgoing: Bool {
        direction == "outgoing" && status == "pending"
    }

    public var isSuppressed: Bool {
        status.lowercased() == "suppressed"
            || outcome.lowercased() == "application_suppressed"
            || resolutionMode.lowercased() == "suppressed_by_policy"
    }

    public var isExpired: Bool {
        status.lowercased() == "expired" || outcome.lowercased() == "application_expired"
    }

    public var canCancel: Bool {
        isPendingOutgoing && !isSuppressed
    }

    public var isCancelled: Bool {
        ["cancelled", "canceled"].contains(status.lowercased())
            || outcome.lowercased() == "application_cancelled"
            || resolutionMode.lowercased() == "requester_cancel"
    }

    public var statusLabel: String {
        if accepted || status == "accepted" { return "已通过" }
        if status == "rejected" { return "已拒绝" }
        if isCancelled { return "已取消" }
        if isSuppressed { return "未投递" }
        if isExpired { return "已过期" }
        // Tenant review is an internal admission stage. The requester-facing
        // contract stays "waiting for the peer" until the relation reaches a
        // terminal state, so an outgoing row must never leak that stage.
        if direction == "outgoing" { return FriendAddPresentation.waitingTitle }
        if peerReviewStatus == "tenant_review_pending" || tenantReviewStatus == "pending" {
            return "等待企业审核"
        }
        if canRespond { return "待处理" }
        return "处理中"
    }

    public init(
        id: String,
        name: String,
        userID: String = "",
        avatarURL: String = "",
        source: String,
        message: String,
        status: String = "pending",
        direction: String = "incoming",
        tenantReviewStatus: String = "",
        peerReviewStatus: String = "",
        canRespond: Bool = true,
        outcome: String = "",
        relationStatus: String = "",
        friendAction: String = "",
        friendFlow: String = "",
        directlyEstablished: Bool = false,
        requiresTenantReview: Bool? = nil,
        requiresTargetApproval: Bool? = nil,
        resolutionMode: String = "",
        accepted: Bool
    ) {
        self.id = id
        self.name = name
        self.userID = userID
        self.avatarURL = avatarURL
        self.source = source
        self.message = message
        self.status = status
        self.direction = direction
        self.tenantReviewStatus = tenantReviewStatus
        self.peerReviewStatus = peerReviewStatus
        self.canRespond = canRespond
        self.outcome = outcome
        self.relationStatus = relationStatus
        self.friendAction = friendAction
        self.friendFlow = friendFlow
        self.directlyEstablished = directlyEstablished
        self.requiresTenantReview = requiresTenantReview
        self.requiresTargetApproval = requiresTargetApproval
        self.resolutionMode = resolutionMode
        self.accepted = accepted
    }
}

// JHT_MOD_BEGIN PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改开始：黑名单投影模型允许安全跨后台任务传递
public struct BlacklistItem: Identifiable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        name: String,
        reason: String
    ) {
        self.id = id
        self.name = name
        self.reason = reason
    }
    public let id: String
    public let name: String
    public let reason: String
}
// JHT_MOD_END PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改结束
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END

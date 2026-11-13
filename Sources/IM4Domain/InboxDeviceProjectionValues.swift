import Foundation

// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_BEGIN
public struct InboxItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let time: String
    public let category: String
    public var isRead: Bool
    public let accentHex: UInt
    public let avatarURL: String
    public let groupInviteApproval: GroupInviteApproval?
    public let sortTimestamp: TimeInterval

    public init(
        id: String,
        title: String,
        subtitle: String,
        time: String,
        category: String,
        isRead: Bool,
        accentHex: UInt,
        avatarURL: String = "",
        groupInviteApproval: GroupInviteApproval? = nil,
        sortTimestamp: TimeInterval = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.time = time
        self.category = category
        self.isRead = isRead
        self.accentHex = accentHex
        self.avatarURL = avatarURL
        self.groupInviteApproval = groupInviteApproval
        self.sortTimestamp = sortTimestamp
    }

    public var normalizedCategory: String {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if InboxItem.isAnnouncementCategory(normalized) {
            return "公告"
        }
        return "系统通知"
    }

    public var isAnnouncement: Bool {
        normalizedCategory == "公告"
    }

    private static func isAnnouncementCategory(_ normalizedCategory: String) -> Bool {
        let exactAnnouncementKinds: Set<String> = [
            "announcement",
            "announcements",
            "tenant_announcement",
            "enterprise_announcement",
            "company_announcement",
            "org_announcement",
            "public_announcement",
            "bulletin",
            "bulletins",
            "公告",
            "企业公告",
            "全员公告"
        ]
        return exactAnnouncementKinds.contains(normalizedCategory)
    }

    public func withGroupInviteApproval(_ approval: GroupInviteApproval) -> InboxItem {
        InboxItem(
            id: id,
            title: title,
            subtitle: subtitle,
            time: time,
            category: category,
            isRead: isRead,
            accentHex: accentHex,
            avatarURL: avatarURL,
            groupInviteApproval: approval
        )
    }
}

public struct DeviceSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let platform: String
    public let lastSeen: String
    public var status: String
    public var isBound: Bool
    public var isBlocked: Bool
    public init(id: String, name: String, platform: String, lastSeen: String, status: String, isBound: Bool, isBlocked: Bool) {
        self.id = id; self.name = name; self.platform = platform; self.lastSeen = lastSeen
        self.status = status; self.isBound = isBound; self.isBlocked = isBlocked
    }
}
// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_END

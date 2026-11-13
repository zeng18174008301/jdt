// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import IM4Domain

public struct PersistedContactUser: Codable, Equatable, Sendable {
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

    public init(_ user: IMUser) {
        id = user.id
        userID = user.userID
        username = user.username
        name = user.name
        title = user.title
        department = user.department
        departmentPathNames = user.departmentPathNames
        phone = user.phone
        phoneVerified = user.phoneVerified
        realNameVerified = user.realNameVerified
        realNameStatus = user.realNameStatus
        email = user.email
        status = user.status
        lastLoginAt = user.lastLoginAt
        enterprise = user.enterprise
        avatarSeed = user.avatarSeed
        avatarURL = user.avatarURL
        avatarVersion = user.avatarVersion
        avatarUpdatedAt = user.avatarUpdatedAt
        badges = user.badges
    }

    public var model: IMUser {
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

public struct PersistedBlacklistItem: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let reason: String



    public init(id: String, name: String, reason: String) {
        self.id = id
        self.name = name
        self.reason = reason
    }
}

public struct LocalProfileContactProjection: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let contacts: [PersistedContactUser]
    public let remarks: [String: String]
    public let blacklist: [PersistedBlacklistItem]
    public let originalNames: [String: String]

    public init(
        revision: UInt64,
        contacts: [PersistedContactUser],
        remarks: [String: String],
        blacklist: [PersistedBlacklistItem],
        originalNames: [String: String] = [:]
    ) {
        self.revision = revision
        self.contacts = contacts
        self.remarks = remarks
        self.blacklist = blacklist
        self.originalNames = originalNames
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case contacts
        case remarks
        case blacklist
        case originalNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        contacts = try container.decode([PersistedContactUser].self, forKey: .contacts)
        remarks = try container.decode([String: String].self, forKey: .remarks)
        blacklist = try container.decode([PersistedBlacklistItem].self, forKey: .blacklist)
        originalNames = try container.decodeIfPresent([String: String].self, forKey: .originalNames) ?? [:]
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

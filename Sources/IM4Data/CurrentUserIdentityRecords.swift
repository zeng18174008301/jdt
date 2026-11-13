// WDT_IOS1_DATA_CURRENT_USER_IDENTITY_CACHE_20261111_BEGIN
import Foundation

public struct IMStoredCurrentUserIdentity: Codable, Equatable {
    public let scope: String
    public let tenantID: String
    public let imUID: String
    public let accountID: String
    public let id: String
    public let userID: String
    public let username: String
    public let name: String
    public let title: String
    public let department: String
    public let phone: String
    public let phoneVerified: Bool
    public let realNameVerified: Bool
    public let realNameStatus: String
    public let email: String
    public let status: String
    public let enterprise: String
    public let avatarSeed: UInt
    public let avatarURL: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let badges: [String]
    public let profileAuthorityCheckpoint: IMStoredCurrentProfileAuthorityCheckpoint?
    public let savedAt: TimeInterval

    public init(
        scope: String,
        tenantID: String,
        imUID: String,
        accountID: String,
        id: String,
        userID: String,
        username: String,
        name: String,
        title: String,
        department: String,
        phone: String,
        phoneVerified: Bool,
        realNameVerified: Bool,
        realNameStatus: String,
        email: String,
        status: String,
        enterprise: String,
        avatarSeed: UInt,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String,
        badges: [String],
        profileAuthorityCheckpoint: IMStoredCurrentProfileAuthorityCheckpoint?,
        savedAt: TimeInterval
    ) {
        self.scope = scope
        self.tenantID = tenantID
        self.imUID = imUID
        self.accountID = accountID
        self.id = id
        self.userID = userID
        self.username = username
        self.name = name
        self.title = title
        self.department = department
        self.phone = phone
        self.phoneVerified = phoneVerified
        self.realNameVerified = realNameVerified
        self.realNameStatus = realNameStatus
        self.email = email
        self.status = status
        self.enterprise = enterprise
        self.avatarSeed = avatarSeed
        self.avatarURL = avatarURL
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
        self.badges = badges
        self.profileAuthorityCheckpoint = profileAuthorityCheckpoint
        self.savedAt = savedAt
    }
}

public struct IMStoredCurrentProfileAuthorityCheckpoint: Codable, Equatable {
    public let tenantID: String
    public let actorIMUID: String
    public let appID: String
    public let userRevision: Int64
    public let identityGeneration: Int64
    public let nickname: String
    public let avatar: String

    public init(
        tenantID: String,
        actorIMUID: String,
        appID: String,
        userRevision: Int64,
        identityGeneration: Int64,
        nickname: String,
        avatar: String
    ) {
        self.tenantID = tenantID
        self.actorIMUID = actorIMUID
        self.appID = appID
        self.userRevision = userRevision
        self.identityGeneration = identityGeneration
        self.nickname = nickname
        self.avatar = avatar
    }
}
// WDT_IOS1_DATA_CURRENT_USER_IDENTITY_CACHE_20261111_END

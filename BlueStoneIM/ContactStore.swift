import Foundation

struct ProfileContactReadStamp: Equatable, Sendable {
    let scopeHash: String
    let revision: UInt64
}

struct ProfileContactMutationTicket: Equatable, Sendable {
    let scopeHash: String
    let operationID: UInt64
    let revision: UInt64
    let keys: Set<String>
}

struct ProfileContactRevisionFence: Equatable, Sendable {
    private(set) var scopeHash = ""
    private(set) var revision: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var latestMutationRevisionByKey: [String: UInt64] = [:]
    private var latestOperationByKey: [String: UInt64] = [:]

    mutating func rebind(scopeHash: String) {
        let normalized = scopeHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != self.scopeHash else { return }
        self.scopeHash = normalized
        revision = 0
        nextOperationID = 0
        latestMutationRevisionByKey.removeAll()
        latestOperationByKey.removeAll()
    }

    func beginRead(scopeHash: String) -> ProfileContactReadStamp? {
        let normalized = scopeHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == self.scopeHash else { return nil }
        return ProfileContactReadStamp(scopeHash: normalized, revision: revision)
    }

    mutating func beginMutation(
        scopeHash: String,
        keys: Set<String>
    ) -> ProfileContactMutationTicket? {
        let normalizedScope = scopeHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKeys = Set(keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !normalizedScope.isEmpty,
              normalizedScope == self.scopeHash,
              !normalizedKeys.isEmpty else { return nil }
        revision &+= 1
        nextOperationID &+= 1
        for key in normalizedKeys {
            latestMutationRevisionByKey[key] = revision
            latestOperationByKey[key] = nextOperationID
        }
        return ProfileContactMutationTicket(
            scopeHash: normalizedScope,
            operationID: nextOperationID,
            revision: revision,
            keys: normalizedKeys
        )
    }

    func isCurrent(_ ticket: ProfileContactMutationTicket) -> Bool {
        guard ticket.scopeHash == scopeHash else { return false }
        return ticket.keys.allSatisfy { latestOperationByKey[$0] == ticket.operationID }
    }

    func wasMutated(_ key: String, after stamp: ProfileContactReadStamp?) -> Bool {
        guard let stamp, stamp.scopeHash == scopeHash else { return true }
        return (latestMutationRevisionByKey[key] ?? 0) > stamp.revision
    }

    @discardableResult
    mutating func acceptAuthoritativeProjection(scopeHash: String) -> UInt64? {
        let normalized = scopeHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == self.scopeHash else { return nil }
        revision &+= 1
        return revision
    }

    mutating func acceptPersistedProjection(
        scopeHash: String,
        readStamp: ProfileContactReadStamp?,
        revision persistedRevision: UInt64
    ) -> Bool {
        let normalized = scopeHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let readStamp,
              !normalized.isEmpty,
              normalized == self.scopeHash,
              readStamp.scopeHash == normalized else { return false }
        let canApplyPayload = readStamp.revision == revision
        revision = max(revision, persistedRevision)
        return canApplyPayload
    }
}

struct PersistedContactUser: Codable, Equatable, Sendable {
    let id: String
    let userID: String
    let username: String
    let name: String
    let title: String
    let department: String
    let departmentPathNames: [String]
    let phone: String
    let phoneVerified: Bool
    let realNameVerified: Bool
    let realNameStatus: String
    let email: String
    let status: String
    let lastLoginAt: String
    let enterprise: String
    let avatarSeed: UInt
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let badges: [String]

    init(_ user: IMUser) {
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

    var model: IMUser {
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

struct PersistedBlacklistItem: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let reason: String

    init(_ item: BlacklistItem) {
        id = item.id
        name = item.name
        reason = item.reason
    }

    var model: BlacklistItem {
        BlacklistItem(id: id, name: name, reason: reason)
    }
}

struct LocalProfileContactProjection: Codable, Equatable, Sendable {
    let revision: UInt64
    let contacts: [PersistedContactUser]
    let remarks: [String: String]
    let blacklist: [PersistedBlacklistItem]
    let originalNames: [String: String]

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        contacts = try container.decode([PersistedContactUser].self, forKey: .contacts)
        remarks = try container.decode([String: String].self, forKey: .remarks)
        blacklist = try container.decode([PersistedBlacklistItem].self, forKey: .blacklist)
        originalNames = try container.decodeIfPresent([String: String].self, forKey: .originalNames) ?? [:]
    }
}

@MainActor
final class ContactStore: ObservableObject {
    @Published var contacts: [IMUser] = []
    @Published private var isSyncing = false
    @Published private var syncErrorMessage: String?
    @Published var friendRequests: [FriendRequest] = []
    @Published var blacklist: [BlacklistItem] = []
    @Published var remarks: [String: String] = [:]
    @Published var inboxItems: [InboxItem] = []
    @Published var deviceSessions: [DeviceSession] = []
    @Published var groups: [GroupInfo] = []
    @Published var groupAnnouncements: [String: [GroupAnnouncement]] = [:]
    @Published var currentGroupAnnouncements: [String: GroupAnnouncement] = [:]
    @Published var groupJoinRequests: [String: [GroupJoinRequest]] = [:]
    @Published private var groupInviteApprovalProcessingIDs: Set<String> = []

    private var hasLoadedFriendRelations = false
    private var knownInboxItemIDs: Set<String> = []
    private var locallyReadSystemInboxIDs: Set<String> = []
    private var announcementDetailLoadingKeys: Set<String> = []
    private var groupBundleRefreshModesByKey: [String: Bool] = [:]
    private var groupBundlePendingFullRefreshKeys: Set<String> = []

    static func projectedGroupDirectory(
        authoritativeGroups: [GroupInfo],
        conversations: [Conversation]
    ) -> [GroupInfo] {
        var projected = authoritativeGroups
        var knownIDs = Set(authoritativeGroups.map { normalizedGroupDirectoryKey($0.id) }.filter { !$0.isEmpty })
        var knownNames = Set(authoritativeGroups.map { normalizedGroupDirectoryKey($0.name) }.filter { !$0.isEmpty })

        for conversation in conversations where conversation.kind == .group {
            let id = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedID = normalizedGroupDirectoryKey(id)
            let normalizedName = normalizedGroupDirectoryKey(name)
            guard !id.isEmpty,
                  !knownIDs.contains(normalizedID),
                  normalizedName.isEmpty || !knownNames.contains(normalizedName) else {
                continue
            }

            projected.append(
                GroupInfo(
                    id: id,
                    name: name.isEmpty ? "群聊" : name,
                    avatarURL: conversation.avatarURL,
                    avatarVersion: conversation.avatarVersion,
                    avatarUpdatedAt: conversation.avatarUpdatedAt,
                    notice: conversation.lastMessage,
                    owner: "",
                    members: conversation.participants,
                    admins: [],
                    membersPartial: true,
                    membersLoadedCount: conversation.participants.count,
                    muted: conversation.isMuted,
                    allMuted: false,
                    myRole: "member",
                    memberCount: conversation.memberCount,
                    historyVisibleFromSeq: conversation.historyVisibleFromSeq,
                    historyLimited: conversation.historyLimited
                )
            )
            knownIDs.insert(normalizedID)
            if !normalizedName.isEmpty {
                knownNames.insert(normalizedName)
            }
        }
        return projected
    }

    private static func normalizedGroupDirectoryKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    struct GroupAnnouncementDetailLoadingKeyContext: Equatable {
        let groupID: String
        let announcementID: String

        init(groupID: String, announcementID: String) {
            self.groupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.announcementID = announcementID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var loadingKey: String {
            [groupID, announcementID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    struct GroupBundleRefreshKeyContext: Equatable {
        let tenantID: String
        let imUID: String
        let groupID: String

        init(tenantID: String, imUID: String, groupID: String) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.groupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var refreshKey: String {
            [tenantID, imUID, groupID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    func groupAnnouncementDetailLoadingKeyContext(
        groupID: String,
        announcementID: String
    ) -> GroupAnnouncementDetailLoadingKeyContext {
        GroupAnnouncementDetailLoadingKeyContext(groupID: groupID, announcementID: announcementID)
    }

    func beginGroupAnnouncementDetailLoading(loadingKey: String) -> Bool {
        let normalizedKey = loadingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, !announcementDetailLoadingKeys.contains(normalizedKey) else { return false }
        announcementDetailLoadingKeys.insert(normalizedKey)
        return true
    }

    func finishGroupAnnouncementDetailLoading(loadingKey: String) {
        let normalizedKey = loadingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return }
        announcementDetailLoadingKeys.remove(normalizedKey)
    }

    func isGroupAnnouncementDetailLoading(loadingKey: String) -> Bool {
        let normalizedKey = loadingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return announcementDetailLoadingKeys.contains(normalizedKey)
    }

    func hasAnnouncementDetailLoadingKeys() -> Bool {
        !announcementDetailLoadingKeys.isEmpty
    }

    func groupBundleRefreshKeyContext(
        tenantID: String?,
        imUID: String?,
        groupID: String
    ) -> GroupBundleRefreshKeyContext {
        GroupBundleRefreshKeyContext(tenantID: tenantID ?? "", imUID: imUID ?? "", groupID: groupID)
    }

    func isContactsSyncing() -> Bool {
        isSyncing
    }

    func contactsSyncError() -> String? {
        syncErrorMessage
    }

    func beginContactsSync() -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        syncErrorMessage = nil
        return true
    }

    func finishContactsSync() {
        isSyncing = false
    }

    func setContactsSyncError(_ message: String?) {
        syncErrorMessage = message
    }

    func processingGroupInviteApprovalIDs() -> Set<String> {
        groupInviteApprovalProcessingIDs
    }

    func hasGroupInviteApprovalProcessingIDs() -> Bool {
        !groupInviteApprovalProcessingIDs.isEmpty
    }

    func isGroupInviteApprovalProcessing(requestID: String) -> Bool {
        let normalizedID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        return groupInviteApprovalProcessingIDs.contains(normalizedID)
    }

    func beginGroupInviteApprovalProcessing(requestID: String) -> Bool {
        let normalizedID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, !groupInviteApprovalProcessingIDs.contains(normalizedID) else { return false }
        groupInviteApprovalProcessingIDs.insert(normalizedID)
        return true
    }

    func finishGroupInviteApprovalProcessing(requestID: String) {
        let normalizedID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        groupInviteApprovalProcessingIDs.remove(normalizedID)
    }

    func friendRelationsLoaded() -> Bool {
        hasLoadedFriendRelations
    }

    func markFriendRelationsLoaded() {
        hasLoadedFriendRelations = true
    }

    func knownInboxIDs() -> Set<String> {
        knownInboxItemIDs
    }

    func replaceKnownInboxIDs(_ ids: Set<String>) {
        knownInboxItemIDs = ids
    }

    func mergeKnownInboxIDs(_ ids: Set<String>) {
        knownInboxItemIDs.formUnion(ids)
    }

    func rememberSystemInboxReadLocally(id: String) {
        guard !id.isEmpty else { return }
        locallyReadSystemInboxIDs.insert(id)
    }

    func isSystemInboxReadLocally(id: String) -> Bool {
        locallyReadSystemInboxIDs.contains(id)
    }

    func hasKnownInboxIDs() -> Bool {
        !knownInboxItemIDs.isEmpty
    }

    func hasLocallyReadSystemInboxIDs() -> Bool {
        !locallyReadSystemInboxIDs.isEmpty
    }

    func beginGroupBundleRefresh(
        refreshKey: String,
        includeSecondaryData: Bool,
        queueIfAlreadyRunning: Bool = false
    ) -> Bool {
        let normalizedKey = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return false }
        if let runningIncludesSecondaryData = groupBundleRefreshModesByKey[normalizedKey] {
            if queueIfAlreadyRunning || (includeSecondaryData && !runningIncludesSecondaryData) {
                groupBundlePendingFullRefreshKeys.insert(normalizedKey)
            }
            return false
        }
        groupBundleRefreshModesByKey[normalizedKey] = includeSecondaryData
        return true
    }

    func finishGroupBundleRefresh(refreshKey: String) -> Bool {
        let normalizedKey = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return false }
        groupBundleRefreshModesByKey.removeValue(forKey: normalizedKey)
        return groupBundlePendingFullRefreshKeys.remove(normalizedKey) != nil
    }

    func isGroupBundleRefreshInFlight(refreshKey: String) -> Bool {
        let normalizedKey = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return groupBundleRefreshModesByKey[normalizedKey] != nil
    }

    func groupBundleRefreshIncludesSecondaryData(refreshKey: String) -> Bool? {
        let normalizedKey = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return groupBundleRefreshModesByKey[normalizedKey]
    }

    func isGroupBundlePendingFullRefresh(refreshKey: String) -> Bool {
        let normalizedKey = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return groupBundlePendingFullRefreshKeys.contains(normalizedKey)
    }

    func hasGroupBundleRefreshModes() -> Bool {
        !groupBundleRefreshModesByKey.isEmpty
    }

    func hasGroupBundlePendingFullRefreshKeys() -> Bool {
        !groupBundlePendingFullRefreshKeys.isEmpty
    }

    func reset() {
        contacts = []
        isSyncing = false
        syncErrorMessage = nil
        friendRequests = []
        blacklist = []
        remarks = [:]
        inboxItems = []
        deviceSessions = []
        groups = []
        groupAnnouncements = [:]
        currentGroupAnnouncements = [:]
        groupJoinRequests = [:]
        groupInviteApprovalProcessingIDs = []
        hasLoadedFriendRelations = false
        knownInboxItemIDs.removeAll()
        locallyReadSystemInboxIDs.removeAll()
        announcementDetailLoadingKeys.removeAll()
        groupBundleRefreshModesByKey.removeAll()
        groupBundlePendingFullRefreshKeys.removeAll()
    }
}

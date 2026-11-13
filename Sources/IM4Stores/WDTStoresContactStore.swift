// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_BEGIN
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import IM4Domain

public struct ProfileContactReadStamp: Equatable, Sendable {
    let scopeHash: String
    let revision: UInt64
}

public struct ProfileContactMutationTicket: Equatable, Sendable {
    let scopeHash: String
    let operationID: UInt64
    public let revision: UInt64
    let keys: Set<String>
}

public struct ProfileContactRevisionFence: Equatable, Sendable {
    public init() {}
    public private(set) var scopeHash = ""
    private(set) var revision: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var latestMutationRevisionByKey: [String: UInt64] = [:]
    private var latestOperationByKey: [String: UInt64] = [:]

    public mutating func rebind(scopeHash: String) {
        let normalized = scopeHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != self.scopeHash else { return }
        self.scopeHash = normalized
        revision = 0
        nextOperationID = 0
        latestMutationRevisionByKey.removeAll()
        latestOperationByKey.removeAll()
    }

    public func beginRead(scopeHash: String) -> ProfileContactReadStamp? {
        let normalized = scopeHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == self.scopeHash else { return nil }
        return ProfileContactReadStamp(scopeHash: normalized, revision: revision)
    }

    public mutating func beginMutation(
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

    public func isCurrent(_ ticket: ProfileContactMutationTicket) -> Bool {
        guard ticket.scopeHash == scopeHash else { return false }
        return ticket.keys.allSatisfy { latestOperationByKey[$0] == ticket.operationID }
    }

    public func wasMutated(_ key: String, after stamp: ProfileContactReadStamp?) -> Bool {
        guard let stamp, stamp.scopeHash == scopeHash else { return true }
        return (latestMutationRevisionByKey[key] ?? 0) > stamp.revision
    }

    @discardableResult
    public mutating func acceptAuthoritativeProjection(scopeHash: String) -> UInt64? {
        let normalized = scopeHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == self.scopeHash else { return nil }
        revision &+= 1
        return revision
    }

    public mutating func acceptPersistedProjection(
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




@MainActor
public final class ContactStore: ObservableObject {
    public init() {}
    @Published public var contacts: [IMUser] = []
    @Published private var isSyncing = false
    @Published private var syncErrorMessage: String?
    @Published public var friendRequests: [FriendRequest] = []
    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110
    @Published public var cancellingFriendRequestIDs: Set<String> = []
    @Published public var blacklist: [BlacklistItem] = []
    @Published public var remarks: [String: String] = [:]
    @Published public var inboxItems: [InboxItem] = []
    @Published public var deviceSessions: [DeviceSession] = []
    public let groupSelfProfiles = GroupSelfProfileStore() // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
    @Published public var groups: [GroupInfo] = []
    @Published public var groupAnnouncements: [String: [GroupAnnouncement]] = [:]
    @Published public var currentGroupAnnouncements: [String: GroupAnnouncement] = [:]
    @Published public var groupJoinRequests: [String: [GroupJoinRequest]] = [:]
    @Published private var groupInviteApprovalProcessingIDs: Set<String> = []

    // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
    public enum FriendIdentityKey: Hashable {
        case imUID(String)
        case userID(String)
        case username(String)
    }

    private var contactCardOriginalNamesByScope: [String: [String: String]] = [:]
    private var canonicalFriendUIDsByIdentity: [FriendIdentityKey: Set<String>] = [:]
    private var canonicalFriendUIDIdentityScope = ""

    public func contactCardOriginalNames(in scope: String) -> [String: String] {
        contactCardOriginalNamesByScope[scope] ?? [:]
    }

    public func replaceFriendIdentityProjection(originalNames: [String: String],
        canonicalUIDs: [FriendIdentityKey: Set<String>], in scope: String) {
        contactCardOriginalNamesByScope[scope] = originalNames
        canonicalFriendUIDsByIdentity = canonicalUIDs
        canonicalFriendUIDIdentityScope = scope
    }

    public func restoreContactCardOriginalNames(_ persistedNames: [String: String], in scope: String) {
        var restored: [String: String] = [:]
        for (identifier, name) in persistedNames {
            Self.cacheContactCardOriginalName(name, identifiers: [identifier], in: &restored)
        }
        contactCardOriginalNamesByScope[scope] = restored
    }

    public static func cacheContactCardOriginalName(_ name: String, identifiers: [String?],
        in names: inout [String: String]) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        for identifier in identifiers {
            let key = (identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { names[key] = normalizedName }
        }
    }

    public func cacheContactCardOriginalName(_ name: String, identifiers: [String?], in scope: String) {
        Self.cacheContactCardOriginalName(name, identifiers: identifiers, in: &contactCardOriginalNamesByScope[scope, default: [:]])
    }

    public func contactCardOriginalName(matching identifiers: [String], in scope: String) -> String? {
        guard let names = contactCardOriginalNamesByScope[scope] else { return nil }
        for identifier in identifiers {
            let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, let name = names[key] { return name }
        }
        return nil
    }

    public func canonicalFriendUIDForRemark(for user: IMUser, in scope: String) -> String? {
        guard canonicalFriendUIDIdentityScope == scope else { return nil }
        let keys = friendRemarkIdentityKeys(for: user)
        let matches = Set(keys.flatMap { canonicalFriendUIDsByIdentity[$0] ?? [] })
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private func friendRemarkIdentityKeys(for user: IMUser) -> [FriendIdentityKey] {
        var keys: [FriendIdentityKey] = []
        let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userID.isEmpty {
            keys.append(.userID(userID))
        }
        let username = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            keys.append(.username(username))
        }
        let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty,
           canonicalFriendUIDsByIdentity[.imUID(id)] == Set([id]),
           contacts.contains(where: { contact in
               let contactID = contact.id.trimmingCharacters(in: .whitespacesAndNewlines)
               let contactUserID = contact.userID.trimmingCharacters(in: .whitespacesAndNewlines)
               let contactUsername = contact.username.trimmingCharacters(in: .whitespacesAndNewlines)
               return contactID == id
                   && (
                       (!userID.isEmpty && contactUserID == userID)
                       || (!username.isEmpty && contactUsername == username)
                   )
           }) {
            keys.append(.imUID(id))
        }
        var seen = Set<FriendIdentityKey>()
        return keys.filter { seen.insert($0).inserted }
    }
    // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END

    // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110_BEGIN
    // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110: directory surfaces subscribe directly to their ContactStore projection.
    public func groupInviteApprovalProcessingUpdates(requestID: String) -> AnyPublisher<Bool, Never> {
        $groupInviteApprovalProcessingIDs
            .map { $0.contains(requestID) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_BEGIN
    public struct DirectoryPresentationSnapshot: Equatable, Sendable {
        public let contacts: [IMUser]
        public let remarks: [String: String]
    }

    public var directoryPresentationSnapshot: DirectoryPresentationSnapshot {
        DirectoryPresentationSnapshot(contacts: contacts, remarks: remarks)
    }

    public var directoryPresentationUpdates: AnyPublisher<DirectoryPresentationSnapshot, Never> {
        $contacts.combineLatest($remarks)
            .map { DirectoryPresentationSnapshot(contacts: $0, remarks: $1) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    public var announcements: [InboxItem] {
        inboxItems.filter(\.isAnnouncement)
    }

    public var announcementUpdates: AnyPublisher<[InboxItem], Never> {
        $inboxItems.map { $0.filter(\.isAnnouncement) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_BEGIN
    public struct FriendRequestsSnapshot: Equatable {
        public let requests: [FriendRequest]
        public let cancellingIDs: Set<String>

        public func isCancelling(_ requestID: String) -> Bool {
            cancellingIDs.contains(requestID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public var friendRequestsSnapshot: FriendRequestsSnapshot {
        FriendRequestsSnapshot(requests: friendRequests, cancellingIDs: cancellingFriendRequestIDs)
    }

    public var friendRequestsUpdates: AnyPublisher<FriendRequestsSnapshot, Never> {
        $friendRequests.combineLatest($cancellingFriendRequestIDs)
            .map { FriendRequestsSnapshot(requests: $0, cancellingIDs: $1) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public func hasPendingOutgoingFriendRequest(identities: Set<String>) -> Bool {
        Self.containsPendingOutgoingRequest(in: friendRequests, identities: identities)
    }

    public func pendingOutgoingFriendRequestUpdates(identities: Set<String>) -> AnyPublisher<Bool, Never> {
        $friendRequests
            .map { Self.containsPendingOutgoingRequest(in: $0, identities: identities) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func containsPendingOutgoingRequest(in requests: [FriendRequest], identities: Set<String>) -> Bool {
        guard !identities.isEmpty else { return false }
        return requests.contains { request in
            let peerID = request.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = request.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let direction = request.direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return direction == "outgoing" && status == "pending" && identities.contains(peerID)
        }
    }
    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
    public var blacklistUpdates: AnyPublisher<[BlacklistItem], Never> {
        $blacklist.removeDuplicates().eraseToAnyPublisher()
    }

    public func blacklistIDs(matching identities: Set<String>) -> Set<String> {
        Self.blacklistIDs(in: blacklist, matching: identities)
    }

    public func blacklistIDUpdates(matching identities: Set<String>) -> AnyPublisher<Set<String>, Never> {
        $blacklist.map { Self.blacklistIDs(in: $0, matching: identities) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func blacklistIDs(in items: [BlacklistItem], matching identities: Set<String>) -> Set<String> {
        Set(items.lazy.map(\.id).filter { identities.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }
    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    public func currentGroupAnnouncementUpdates(groupID: String) -> AnyPublisher<GroupAnnouncement?, Never> {
        $currentGroupAnnouncements.map { $0[groupID] }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public func groupAnnouncement(groupID: String, announcementID: String?) -> GroupAnnouncement? {
        Self.selectAnnouncement(groupAnnouncements[groupID] ?? [], id: announcementID)
    }

    public func groupAnnouncementUpdates(groupID: String, announcementID: String?) -> AnyPublisher<GroupAnnouncement?, Never> {
        $groupAnnouncements
            .map { Self.selectAnnouncement($0[groupID] ?? [], id: announcementID) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func selectAnnouncement(_ announcements: [GroupAnnouncement], id: String?) -> GroupAnnouncement? {
        if let id { return announcements.first { $0.id == id } }
        return announcements.first
    }
    // WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110
    @Published private var hasLoadedFriendRelations = false
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    public struct GroupSelector {
        let id: String
        var channelID: String? = nil
        var title: String? = nil

        public init(id: String, channelID: String? = nil, title: String? = nil) {
            self.id = id; self.channelID = channelID; self.title = title
        }

        public func matches(_ group: GroupInfo) -> Bool {
            group.id == id || group.id == channelID || group.name == title
        }
    }

    public var groupDirectoryUpdates: AnyPublisher<[GroupInfo], Never> {
        $groups.removeDuplicates().eraseToAnyPublisher()
    }

    public func groupSnapshots(matching selectors: [GroupSelector]) -> [GroupInfo?] {
        Self.groupSnapshots(in: groups, matching: selectors)
    }

    public func groupUpdates(matching selectors: [GroupSelector]) -> AnyPublisher<[GroupInfo?], Never> {
        $groups.map { Self.groupSnapshots(in: $0, matching: selectors) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func groupSnapshots(in groups: [GroupInfo], matching selectors: [GroupSelector]) -> [GroupInfo?] {
        selectors.map { groups.first(where: $0.matches) }
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    private var knownInboxItemIDs: Set<String> = []
    private var locallyReadSystemInboxIDs: Set<String> = []
    private var announcementDetailLoadingKeys: Set<String> = []
    private var groupBundleRefreshModesByKey: [String: Bool] = [:]
    private var groupBundlePendingFullRefreshKeys: Set<String> = []

    public static func projectedGroupDirectory(
        authoritativeGroups: [GroupInfo],
        conversations: [ConversationMessageSnapshot]
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

    public struct GroupAnnouncementDetailLoadingKeyContext: Equatable {
        let groupID: String
        let announcementID: String

        init(groupID: String, announcementID: String) {
            self.groupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.announcementID = announcementID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var loadingKey: String {
            [groupID, announcementID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    public struct GroupBundleRefreshKeyContext: Equatable {
        let tenantID: String
        let imUID: String
        let groupID: String

        init(tenantID: String, imUID: String, groupID: String) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.groupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var refreshKey: String {
            [tenantID, imUID, groupID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    public func groupAnnouncementDetailLoadingKeyContext(
        groupID: String,
        announcementID: String
    ) -> GroupAnnouncementDetailLoadingKeyContext {
        GroupAnnouncementDetailLoadingKeyContext(groupID: groupID, announcementID: announcementID)
    }

    public func beginGroupAnnouncementDetailLoading(loadingKey: String) -> Bool {
        let normalizedKey = loadingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, !announcementDetailLoadingKeys.contains(normalizedKey) else { return false }
        announcementDetailLoadingKeys.insert(normalizedKey)
        return true
    }

    public func finishGroupAnnouncementDetailLoading(loadingKey: String) {
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

    public func groupBundleRefreshKeyContext(
        tenantID: String?,
        imUID: String?,
        groupID: String
    ) -> GroupBundleRefreshKeyContext {
        GroupBundleRefreshKeyContext(tenantID: tenantID ?? "", imUID: imUID ?? "", groupID: groupID)
    }

    // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110_BEGIN
    public struct ContactsSyncStatus: Equatable {
        public let isSyncing: Bool
        public let errorMessage: String?
    }

    public var contactsSyncStatus: ContactsSyncStatus {
        ContactsSyncStatus(isSyncing: isSyncing, errorMessage: syncErrorMessage)
    }

    public var contactsSyncUpdates: AnyPublisher<ContactsSyncStatus, Never> {
        $isSyncing.combineLatest($syncErrorMessage)
            .map { ContactsSyncStatus(isSyncing: $0, errorMessage: $1) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public struct CallRelationshipSnapshot: Equatable {
        public let blacklistIDs: Set<String>
        public let friendRelationsPending: Bool
    }

    public var friendRelationsPending: Bool {
        isSyncing || (!hasLoadedFriendRelations && contacts.isEmpty)
    }

    public func callRelationshipSnapshot(matching identities: Set<String>) -> CallRelationshipSnapshot {
        CallRelationshipSnapshot(
            blacklistIDs: blacklistIDs(matching: identities),
            friendRelationsPending: friendRelationsPending
        )
    }

    public func callRelationshipUpdates(matching identities: Set<String>) -> AnyPublisher<CallRelationshipSnapshot, Never> {
        let pending = Publishers.CombineLatest3(
            $isSyncing, $hasLoadedFriendRelations, $contacts.map(\.isEmpty).removeDuplicates()
        )
        .map { syncing, loaded, empty in syncing || (!loaded && empty) }
        .removeDuplicates()
        return blacklistIDUpdates(matching: identities).combineLatest(pending)
            .map { CallRelationshipSnapshot(blacklistIDs: $0, friendRelationsPending: $1) }
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110_END

    public func isContactsSyncing() -> Bool {
        isSyncing
    }

    public func contactsSyncError() -> String? {
        syncErrorMessage
    }

    public func beginContactsSync() -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        syncErrorMessage = nil
        return true
    }

    public func finishContactsSync() {
        isSyncing = false
    }

    public func setContactsSyncError(_ message: String?) {
        syncErrorMessage = message
    }

    public func processingGroupInviteApprovalIDs() -> Set<String> {
        groupInviteApprovalProcessingIDs
    }

    func hasGroupInviteApprovalProcessingIDs() -> Bool {
        !groupInviteApprovalProcessingIDs.isEmpty
    }

    func isGroupInviteApprovalProcessing(requestID: String) -> Bool {
        let normalizedID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        return groupInviteApprovalProcessingIDs.contains(normalizedID)
    }

    public func beginGroupInviteApprovalProcessing(requestID: String) -> Bool {
        let normalizedID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, !groupInviteApprovalProcessingIDs.contains(normalizedID) else { return false }
        groupInviteApprovalProcessingIDs.insert(normalizedID)
        return true
    }

    public func finishGroupInviteApprovalProcessing(requestID: String) {
        let normalizedID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        groupInviteApprovalProcessingIDs.remove(normalizedID)
    }

    public func friendRelationsLoaded() -> Bool {
        hasLoadedFriendRelations
    }

    public func markFriendRelationsLoaded() {
        hasLoadedFriendRelations = true
    }

    public func knownInboxIDs() -> Set<String> {
        knownInboxItemIDs
    }

    public func replaceKnownInboxIDs(_ ids: Set<String>) {
        knownInboxItemIDs = ids
    }

    public func mergeKnownInboxIDs(_ ids: Set<String>) {
        knownInboxItemIDs.formUnion(ids)
    }

    public func rememberSystemInboxReadLocally(id: String) {
        guard !id.isEmpty else { return }
        locallyReadSystemInboxIDs.insert(id)
    }

    public func isSystemInboxReadLocally(id: String) -> Bool {
        locallyReadSystemInboxIDs.contains(id)
    }

    func hasKnownInboxIDs() -> Bool {
        !knownInboxItemIDs.isEmpty
    }

    func hasLocallyReadSystemInboxIDs() -> Bool {
        !locallyReadSystemInboxIDs.isEmpty
    }

    public func beginGroupBundleRefresh(
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

    public func finishGroupBundleRefresh(refreshKey: String) -> Bool {
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

    public func reset() {
        // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
        contactCardOriginalNamesByScope.removeAll()
        canonicalFriendUIDsByIdentity.removeAll()
        canonicalFriendUIDIdentityScope = ""
        // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
        contacts = []
        isSyncing = false
        syncErrorMessage = nil
        friendRequests = []
        // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110
        cancellingFriendRequestIDs = []
        blacklist = []
        remarks = [:]
        inboxItems = []
        deviceSessions = []
        groupSelfProfiles.reset() // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
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

// WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
@MainActor
public final class GroupSelfProfileStore {
    public struct Snapshot: Equatable {
        public var nickname = ""
        public var member: IMUser?
    }

    @Published private var profiles: [String: Snapshot] = [:]

    public func snapshot(for key: String?) -> Snapshot {
        key.flatMap { profiles[$0] } ?? Snapshot()
    }

    public func updates<Value: Equatable>(for key: String?, _ field: KeyPath<Snapshot, Value>) -> AnyPublisher<Value, Never> {
        $profiles.map { profiles in
            (key.flatMap { profiles[$0] } ?? Snapshot())[keyPath: field]
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    public func set(nickname: String, member: IMUser, for key: String) {
        let next = Snapshot(nickname: nickname, member: member)
        guard next != profiles[key] else { return }
        profiles[key] = next
    }

    public func remove(for key: String) {
        guard profiles[key] != nil else { return }
        profiles[key] = nil
    }

    public func reset() {
        profiles = [:]
    }

    public func projectMembers(_ transform: (IMUser) -> IMUser) -> Bool {
        let updated = profiles.mapValues { snapshot in
            Snapshot(nickname: snapshot.nickname, member: snapshot.member.map(transform))
        }
        guard updated != profiles else { return false }
        profiles = updated
        return true
    }
}
// WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_END

// WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_BEGIN
import Combine
import Foundation
import IM4Domain

// WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
@MainActor
public final class GroupModerationStore {
    public init() {}
    private var ownerTransferIdempotencyState = GroupOwnerTransferIdempotencyState()
    private var muteMutationSequence: UInt64 = 0
    private var muteMutationTokensByScope: [String: UInt64] = [:]
    private var muteRealtimeGenerationByScope: [String: Int64] = [:]
    private var muteBoundaryRefreshTasks: [String: Task<Void, Never>] = [:]

    public func ownerTransferIdempotencyKey(scope: String, groupID: String, targetUID: String) -> String {
        ownerTransferIdempotencyState.key(scope: scope, groupID: groupID, targetUID: targetUID)
    }

    public func clearOwnerTransferIdempotencyKey(scope: String, groupID: String, targetUID: String) {
        ownerTransferIdempotencyState.clear(scope: scope, groupID: groupID, targetUID: targetUID)
    }

    public func beginMuteMutation(scopeKey: String) -> UInt64 {
        muteMutationSequence &+= 1
        let token = muteMutationSequence
        muteMutationTokensByScope[scopeKey] = token
        return token
    }

    public func ownsMuteMutation(_ token: UInt64, scopeKey: String) -> Bool {
        muteMutationTokensByScope[scopeKey] == token
    }

    public func retireMuteMutation(scopeKey: String) {
        muteMutationTokensByScope[scopeKey] = nil
    }

    public func muteRealtimeGeneration(scopeKey: String) -> Int64 {
        muteRealtimeGenerationByScope[scopeKey] ?? 0
    }

    public func recordMuteRealtimeGeneration(_ generation: Int64, scopeKey: String) {
        muteRealtimeGenerationByScope[scopeKey] = generation
    }

    public func cancelMuteBoundaryRefresh(scopeKey: String) {
        muteBoundaryRefreshTasks[scopeKey]?.cancel()
        muteBoundaryRefreshTasks[scopeKey] = nil
    }

    public func installMuteBoundaryRefreshTask(_ task: Task<Void, Never>, scopeKey: String) {
        muteBoundaryRefreshTasks[scopeKey] = task
    }

    public func finishMuteBoundaryRefresh(scopeKey: String) {
        muteBoundaryRefreshTasks[scopeKey] = nil
    }

    public struct ListSnapshot: Equatable {
        public internal(set) var items: [GroupMuteListItem]?
        public internal(set) var errorMessage: String?
        fileprivate var loadID: UUID?
        fileprivate var memberOperationIDs: [String: UUID] = [:]

        public var isLoading: Bool { loadID != nil }

        public func isMutating(targetUID: String) -> Bool {
            memberOperationIDs[targetUID.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
        }
    }

    public struct SettingsSnapshot: Equatable {
        public internal(set) var isMutating = false
        public internal(set) var errorMessage: String?

    }

    @Published private var lists: [String: ListSnapshot] = [:]
    @Published private var settings: [String: SettingsSnapshot] = [:]

    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_BEGIN
    public enum AdministrationOperation: Hashable {
        case description
        case ownerTransfer
    }

    @Published private var administrationOperations: [String: [AdministrationOperation: UUID]] = [:]

    public func isTransferringOwner(groupID: String) -> Bool {
        administrationOperations[groupID]?[.ownerTransfer] != nil
    }

    public func ownerTransferPublisher(for groupID: String) -> AnyPublisher<Bool, Never> {
        $administrationOperations.map { $0[groupID]?[.ownerTransfer] != nil }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public func beginAdministration(_ operation: AdministrationOperation, groupID: String) -> UUID? {
        guard administrationOperations[groupID]?[operation] == nil else { return nil }
        let id = UUID()
        administrationOperations[groupID, default: [:]][operation] = id
        return id
    }

    public func ownsAdministration(_ operation: AdministrationOperation, id: UUID, groupID: String) -> Bool {
        administrationOperations[groupID]?[operation] == id
    }

    public func finishAdministration(_ operation: AdministrationOperation, id: UUID, groupID: String) {
        guard ownsAdministration(operation, id: id, groupID: groupID),
              var operations = administrationOperations[groupID] else { return }
        operations[operation] = nil
        administrationOperations[groupID] = operations.isEmpty ? nil : operations
    }
    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_END

    public var cachedListItems: [String: [GroupMuteListItem]] { lists.compactMapValues(\.items) }

    public func listSnapshot(for groupID: String) -> ListSnapshot {
        lists[groupID] ?? ListSnapshot()
    }

    public func listPublisher(for groupID: String) -> AnyPublisher<ListSnapshot, Never> {
        $lists.map { $0[groupID] ?? ListSnapshot() }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public func beginListLoad(groupID: String) -> UUID {
        let id = UUID()
        updateList(groupID: groupID) {
            $0.loadID = id
            $0.errorMessage = nil
        }
        return id
    }

    public func ownsListLoad(_ id: UUID, groupID: String) -> Bool {
        lists[groupID]?.loadID == id
    }

    public func finishListLoad(_ id: UUID, groupID: String) {
        guard ownsListLoad(id, groupID: groupID) else { return }
        updateList(groupID: groupID) { $0.loadID = nil }
    }

    public func setListItems(_ items: [GroupMuteListItem], groupID: String) {
        updateList(groupID: groupID) { $0.items = items }
    }

    public func setListError(_ message: String, groupID: String) {
        updateList(groupID: groupID) { $0.errorMessage = message }
    }

    public func beginMemberMutation(groupID: String, targetUID: String) -> UUID? {
        guard lists[groupID]?.memberOperationIDs[targetUID] == nil else { return nil }
        let id = UUID()
        updateList(groupID: groupID) { $0.memberOperationIDs[targetUID] = id }
        return id
    }

    public func ownsMemberMutation(_ id: UUID, groupID: String, targetUID: String) -> Bool {
        lists[groupID]?.memberOperationIDs[targetUID] == id
    }

    public func finishMemberMutation(_ id: UUID, groupID: String, targetUID: String) {
        guard ownsMemberMutation(id, groupID: groupID, targetUID: targetUID) else { return }
        updateList(groupID: groupID) { $0.memberOperationIDs[targetUID] = nil }
    }

    @discardableResult
    public func projectListItems(_ transform: (GroupMuteListItem) -> GroupMuteListItem) -> Bool {
        let projected = lists.mapValues { snapshot in
            var projected = snapshot
            projected.items = snapshot.items?.map(transform)
            return projected
        }
        guard projected != lists else { return false }
        lists = projected
        return true
    }

    public func settingsSnapshot(for groupID: String) -> SettingsSnapshot {
        settings[groupID] ?? SettingsSnapshot()
    }

    public func settingsPublisher(for groupID: String) -> AnyPublisher<SettingsSnapshot, Never> {
        $settings.map { $0[groupID] ?? SettingsSnapshot() }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public func setSettingsMutation(groupID: String, isMutating: Bool, errorMessage: String? = nil) {
        let snapshot = SettingsSnapshot(isMutating: isMutating, errorMessage: errorMessage)
        guard snapshot != settingsSnapshot(for: groupID) else { return }
        settings[groupID] = snapshot == SettingsSnapshot() ? nil : snapshot
    }

    public func reset() {
        lists = [:]
        settings = [:]
        administrationOperations = [:] // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110
        ownerTransferIdempotencyState.reset()
        muteMutationTokensByScope.removeAll()
        muteRealtimeGenerationByScope.removeAll()
        for task in muteBoundaryRefreshTasks.values {
            task.cancel()
        }
        muteBoundaryRefreshTasks.removeAll()
        // The original auth retirement never reset the monotonic sequence.
    }

    private func updateList(groupID: String, _ update: (inout ListSnapshot) -> Void) {
        let previous = listSnapshot(for: groupID)
        var next = previous
        update(&next)
        guard next != previous else { return }
        lists[groupID] = next == ListSnapshot() ? nil : next
    }
}
// WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END
struct GroupOwnerTransferIdempotencyState {
    private var keysByIntent: [String: String] = [:]

    mutating func key(
        scope: String,
        groupID: String,
        targetUID: String,
        makeKey: () -> String = { UUID().uuidString.lowercased() }
    ) -> String {
        let intent = [scope, groupID, targetUID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
        if let existing = keysByIntent[intent] {
            return existing
        }
        let created = makeKey()
        keysByIntent[intent] = created
        return created
    }

    mutating func clear(scope: String, groupID: String, targetUID: String) {
        let intent = [scope, groupID, targetUID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
        keysByIntent[intent] = nil
    }

    mutating func reset() {
        keysByIntent.removeAll()
    }
}
// WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_END

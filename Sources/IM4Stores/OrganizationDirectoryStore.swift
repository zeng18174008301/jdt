// WDT_IOS1_STORES_ORGANIZATION_DIRECTORY_OWNER_20261111_BEGIN
import Combine
import Foundation
import IM4Data
import IM4Domain

// WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
@MainActor
public final class OrganizationDirectoryStore {
    public struct Snapshot: Equatable {
        public fileprivate(set) var isSyncing = false
        public fileprivate(set) var errorMessage: String?
        public fileprivate(set) var tree: RemoteOrganizationTree?
        public fileprivate(set) var tenantDepartmentEnabled = false
        public fileprivate(set) var membersByDepartment: [String: [IMUser]] = [:]
        public fileprivate(set) var memberIndex: [String: IMUser] = [:]

        public func departmentEnabled(appPolicyEnabled: Bool) -> Bool {
            tree?.departmentEnabled ?? (appPolicyEnabled || tenantDepartmentEnabled)
        }

        public func members(for departmentID: String) -> [IMUser] {
            membersByDepartment[departmentID] ?? []
        }
    }

    @Published public private(set) var snapshot = Snapshot()
    private var refreshID: UUID?

    public init() {}

    // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_BEGIN
    @Published public private(set) var isManagementSaving = false
    private var managementMutationID: UUID?

    public func beginManagementMutation() -> UUID? {
        guard managementMutationID == nil else { return nil }
        let id = UUID()
        managementMutationID = id
        isManagementSaving = true
        return id
    }

    public func ownsManagementMutation(_ id: UUID) -> Bool {
        managementMutationID == id
    }

    public func finishManagementMutation(_ id: UUID) {
        guard ownsManagementMutation(id) else { return }
        managementMutationID = nil
        isManagementSaving = false
    }

    public func reset() {
        if let managementMutationID {
            finishManagementMutation(managementMutationID)
        }
        clear(disabled: true)
    }
    // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_END

    public func updates<Value: Equatable>(_ project: @escaping (Snapshot) -> Value) -> AnyPublisher<Value, Never> {
        $snapshot.map(project).removeDuplicates().eraseToAnyPublisher()
    }

    public func setTenantDepartmentEnabled(_ enabled: Bool) {
        if enabled {
            update { $0.tenantDepartmentEnabled = true }
        } else {
            clear(disabled: true)
        }
    }

    public func beginRefresh() -> UUID {
        let id = UUID()
        refreshID = id
        update {
            $0.isSyncing = true
            $0.errorMessage = nil
        }
        return id
    }

    public func ownsRefresh(_ id: UUID) -> Bool {
        refreshID == id
    }

    public func finishRefresh(_ id: UUID) {
        guard ownsRefresh(id) else { return }
        refreshID = nil
        update { $0.isSyncing = false }
    }

    public func applyTree(_ tree: RemoteOrganizationTree) {
        update {
            $0.tree = tree
            $0.tenantDepartmentEnabled = tree.departmentEnabled
            if !tree.departmentEnabled {
                $0.membersByDepartment = [:]
                $0.memberIndex = [:]
            }
        }
    }

    public func setMembers(_ members: [String: [IMUser]], index: [String: IMUser]) {
        update {
            $0.membersByDepartment = members
            $0.memberIndex = index
        }
    }

    public func setRefreshError(_ message: String) {
        update { $0.errorMessage = message }
    }

    public func projectMembers(_ transform: (IMUser) -> IMUser) -> Bool {
        let members = snapshot.membersByDepartment.mapValues { $0.map(transform) }
        let index = snapshot.memberIndex.mapValues(transform)
        guard members != snapshot.membersByDepartment || index != snapshot.memberIndex else { return false }
        setMembers(members, index: index)
        return true
    }

    public func clear(disabled: Bool) {
        refreshID = nil
        let enabled = !disabled && snapshot.tenantDepartmentEnabled
        update { $0 = Snapshot(tenantDepartmentEnabled: enabled) }
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        var next = snapshot
        change(&next)
        if next != snapshot {
            snapshot = next
        }
    }
}
// WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
// WDT_IOS1_STORES_ORGANIZATION_DIRECTORY_OWNER_20261111_END

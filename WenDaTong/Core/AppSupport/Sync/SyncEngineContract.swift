import IM4Domain
import Foundation

// A page is presentation only. Preserve mutations made after the request began,
// including deletion; only a completed snapshot may remove unchanged absent rows.
struct ConversationSnapshotPresentation<Value: Equatable> {
    let baseline: [String: Value]
    private var expected: [String: Value]
    private(set) var seen = Set<String>()
    private var protected = Set<String>()

    init(current: [String: Value]) {
        baseline = current
        expected = current
    }

    mutating func observe(current: [String: Value]) {
        for key in Set(expected.keys).union(current.keys) where current[key] != expected[key] {
            protected.insert(key)
        }
    }

    mutating func accept(_ key: String, current: [String: Value]) -> Bool {
        guard seen.insert(key).inserted else { return false }
        if current[key] != expected[key] { protected.insert(key) }
        return !protected.contains(key)
    }

    // WDT_IOS1_REFACTOR_PAGED_COMMIT_EXPECTATIONS_20261110_BEGIN
    mutating func didApply(_ keys: [String], current: [String: Value], previous: [String: Value]) {
        for key in keys { expected[key] = current[key] }
        // Applying a page can also normalize derived metadata on other rows.
        // Only changes made by this synchronous page belong to its expectation;
        // previously observed local mutations remain protected.
        for key in Set(previous.keys).union(current.keys)
            where previous[key] != current[key] && !protected.contains(key) {
            expected[key] = current[key]
        }
    }
    // WDT_IOS1_REFACTOR_PAGED_COMMIT_EXPECTATIONS_20261110_END

    func completing(current: [String: Value]) -> [String: Value] {
        current.filter { key, value in
            seen.contains(key) || protected.contains(key) || expected[key] != value
        }
    }

    // WDT_IOS1_REFACTOR_PAGED_COMMIT_EXPECTATIONS_20261110_BEGIN
    mutating func restarting(current: [String: Value]) -> [String: Value] {
        // Preserve even unseen local changes before advancing the expectation.
        observe(current: current)
        var restored = current
        for key in seen where !protected.contains(key) {
            restored[key] = baseline[key]
        }
        // Unseen rows can retain valid page-derived normalization across restart.
        // Track the restored presentation, while keeping the local-mutation fence.
        expected = restored
        seen.removeAll()
        return restored
    }
    // WDT_IOS1_REFACTOR_PAGED_COMMIT_EXPECTATIONS_20261110_END
}

typealias SyncEngineOperation = IM4Domain.SyncEngineOperation

typealias SyncEngineRequest = IM4Domain.SyncEngineRequest

typealias SyncEngineResult = IM4Domain.SyncEngineResult

struct RemoteSnapshotSyncCommand: Sendable, Equatable {
    let scope: String
    let force: Bool

    init(scope: String, force: Bool = false) {
        self.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        self.force = force
    }

    var request: SyncEngineRequest {
        SyncEngineRequest(
            operation: .remoteSnapshot,
            historyKey: scope,
            reason: force ? "force" : "normal"
        )
    }
}

enum RemoteSnapshotSyncPlan: Sendable, Equatable {
    case remoteSnapshot(RemoteSnapshotSyncCommand)
    case skip(RemoteSnapshotSyncCommand, reason: String)
}

struct RemoteSnapshotRefreshSession: Sendable, Equatable, Hashable {
    let id: UUID
    let generation: Int

    init(id: UUID = UUID(), generation: Int) {
        self.id = id
        self.generation = generation
    }
}

struct RemoteConversationSyncCommand: Sendable, Equatable {
    let requestedVersion: Int64
    let forceFull: Bool

    var replacesLocalSnapshot: Bool {
        requestedVersion == 0
    }
}

struct RealtimeRecoveryRefreshCommand: Sendable, Equatable {
    let reason: String

    var request: SyncEngineRequest {
        SyncEngineRequest(operation: .realtimeRecovery, reason: reason)
    }
}

enum RealtimeRecoveryRefreshPlan: Sendable, Equatable {
    case refresh(RealtimeRecoveryRefreshCommand)
    case flushOnly(RealtimeRecoveryRefreshCommand, reason: String)
}

enum RealtimeRecoveryTaskKind: String, Sendable, Equatable, Hashable {
    case refresh
    case conversationFlush
}

enum RealtimeReconnectNoticePlan: Sendable, Equatable {
    case show
    case skip(reason: String)
}

enum RemoteErrorToastPlan: Sendable, Equatable {
    case show(message: String)
    case skip(message: String, reason: String)
}

struct InboxRefreshTaskToken: Sendable, Equatable, Hashable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct AuthSessionRefreshTaskToken: Sendable, Equatable, Hashable {
    let id: UUID
    let fence: IMAuthSessionFence?

    init(id: UUID = UUID(), fence: IMAuthSessionFence? = nil) {
        self.id = id
        self.fence = fence
    }
}

enum SecondarySnapshotOperation: String, Sendable, Equatable, Hashable, CaseIterable {
    case groups
    case contacts
    case profileDevice = "profile_device"
}

struct SecondarySnapshotSyncCommand: Sendable, Equatable {
    let operation: SecondarySnapshotOperation
    let delayNs: UInt64

    var name: String {
        operation.rawValue
    }
}

protocol SyncEngine: ConversationMessageSyncEngine {
    func begin(_ request: SyncEngineRequest) -> SyncEngineResult
    func finish(_ request: SyncEngineRequest)
    func isInFlight(_ request: SyncEngineRequest) -> Bool
    func remoteSnapshotSyncPlan(scope: String, force: Bool) -> RemoteSnapshotSyncPlan
    func beginRemoteSnapshotSync(_ command: RemoteSnapshotSyncCommand) -> SyncEngineResult
    func finishRemoteSnapshotSync(_ command: RemoteSnapshotSyncCommand)
    func beginRemoteSnapshotRefresh() -> RemoteSnapshotRefreshSession
    func finishRemoteSnapshotRefresh(_ session: RemoteSnapshotRefreshSession) -> Bool
    func currentRemoteSnapshotRefreshSession() -> RemoteSnapshotRefreshSession?
    func isCurrentRemoteSnapshotRefresh(_ session: RemoteSnapshotRefreshSession) -> Bool
    func isCurrentRemoteSnapshotGeneration(_ generation: Int) -> Bool
    func currentRemoteSnapshotGeneration() -> Int
    func remoteConversationSyncCommand(forceFull: Bool) -> RemoteConversationSyncCommand
    func finishRemoteConversationSync(_ command: RemoteConversationSyncCommand, responseVersion: Int64)
    func requestedRemoteConversationSyncVersion(forceFull: Bool) -> Int64
    func rememberRemoteConversationSyncVersion(_ version: Int64)
    func currentRemoteConversationSyncVersion() -> Int64
    func secondarySnapshotCommands(
        groupsDelayNs: UInt64,
        contactsDelayNs: UInt64,
        profileDeviceDelayNs: UInt64
    ) -> [SecondarySnapshotSyncCommand]
    func claimSecondarySnapshotTask(_ operation: SecondarySnapshotOperation) -> Bool
    func attachSecondarySnapshotTask(_ operation: SecondarySnapshotOperation, task: Task<Void, Never>)
    func finishSecondarySnapshotTask(_ operation: SecondarySnapshotOperation)
    func hasSecondarySnapshotTask(_ operation: SecondarySnapshotOperation) -> Bool
    func cancelSecondarySnapshotTasks()
    func claimInboxRefreshTask() -> InboxRefreshTaskToken?
    func attachInboxRefreshTask(_ token: InboxRefreshTaskToken, task: Task<Void, Never>)
    func finishInboxRefreshTask(_ token: InboxRefreshTaskToken)
    func hasInboxRefreshTask() -> Bool
    func cancelInboxRefreshTask()
    func currentAuthSessionRefreshTask() -> Task<Bool, Never>?
    func currentAuthSessionRefreshTask(for fence: IMAuthSessionFence) -> Task<Bool, Never>?
    func claimAuthSessionRefreshTask() -> AuthSessionRefreshTaskToken?
    func claimAuthSessionRefreshTask(for fence: IMAuthSessionFence) -> AuthSessionRefreshTaskToken?
    func attachAuthSessionRefreshTask(_ token: AuthSessionRefreshTaskToken, task: Task<Bool, Never>)
    func finishAuthSessionRefreshTask(_ token: AuthSessionRefreshTaskToken)
    func hasAuthSessionRefreshTask() -> Bool
    func cancelAuthSessionRefreshTask()
    func updateRealtimeConnectionState(isConnected: Bool)
    func isRealtimeConnectionActive() -> Bool
    func shouldPollActiveConversation() -> Bool
    func updateActiveRealtimeConversationID(_ conversationID: String?)
    func clearActiveRealtimeConversationID(_ conversationID: String)
    func currentActiveRealtimeConversationID() -> String?
    func enqueueRealtimeRecoveryConversation(_ conversationID: String?) -> Bool
    func drainRealtimeRecoveryConversations() -> [String]
    func realtimeRecoveryRefreshPlan(
        reason: String,
        now: Date,
        throttleInterval: TimeInterval
    ) -> RealtimeRecoveryRefreshPlan
    func beginRealtimeRecoveryRefresh(_ command: RealtimeRecoveryRefreshCommand) -> SyncEngineResult
    func finishRealtimeRecoveryRefresh(_ command: RealtimeRecoveryRefreshCommand)
    func rememberRealtimeRecoveryRefresh(at date: Date)
    func claimRealtimeRecoveryTask(_ kind: RealtimeRecoveryTaskKind) -> Bool
    func attachRealtimeRecoveryTask(_ kind: RealtimeRecoveryTaskKind, task: Task<Void, Never>)
    func finishRealtimeRecoveryTask(_ kind: RealtimeRecoveryTaskKind)
    func hasRealtimeRecoveryTask(_ kind: RealtimeRecoveryTaskKind) -> Bool
    func cancelRealtimeRecoveryTasks()
    func realtimeReconnectNoticePlan(now: Date, throttleInterval: TimeInterval) -> RealtimeReconnectNoticePlan
    func rememberRealtimeReconnectNoticeShown(at date: Date)
    func clearRealtimeReconnectNotice()
    func remoteErrorToastPlan(message: String, now: Date, throttleInterval: TimeInterval) -> RemoteErrorToastPlan
    func rememberRemoteErrorToastShown(message: String, at date: Date)
    func clearRemoteErrorToastThrottle()
    func reset()
}

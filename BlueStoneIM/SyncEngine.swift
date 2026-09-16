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

    mutating func didApply(_ keys: [String], current: [String: Value]) {
        for key in keys { expected[key] = current[key] }
    }

    func completing(current: [String: Value]) -> [String: Value] {
        current.filter { key, value in
            seen.contains(key) || protected.contains(key) || expected[key] != value
        }
    }

    mutating func restarting(current: [String: Value]) -> [String: Value] {
        var restored = current
        for key in seen {
            if current[key] != expected[key] { protected.insert(key) }
            if !protected.contains(key) { restored[key] = baseline[key] }
        }
        expected = baseline
        seen.removeAll()
        return restored
    }
}

enum SyncEngineOperation: String, Sendable, Equatable {
    case conversationMessages
    case olderMessages
    case remoteSnapshot
    case realtimeRecovery
    case messageExtra
    case readReceipt
    case readAck
    case pinnedMessages
}

struct SyncEngineRequest: Sendable, Equatable {
    let operation: SyncEngineOperation
    let conversationID: String?
    let historyKey: String?
    let reason: String

    init(
        operation: SyncEngineOperation,
        conversationID: String? = nil,
        historyKey: String? = nil,
        reason: String
    ) {
        self.operation = operation
        self.conversationID = conversationID
        self.historyKey = historyKey
        self.reason = reason
    }

    var inFlightKey: String {
        if let historyKey {
            return "\(operation.rawValue):history:\(historyKey)"
        }
        if let conversationID, !conversationID.isEmpty {
            return "\(operation.rawValue):conversation:\(conversationID)"
        }
        return "\(operation.rawValue):global"
    }
}

struct SyncEngineResult: Sendable, Equatable {
    let request: SyncEngineRequest
    let started: Bool
    let skippedReason: String?

    static func started(_ request: SyncEngineRequest) -> SyncEngineResult {
        SyncEngineResult(request: request, started: true, skippedReason: nil)
    }

    static func skipped(_ request: SyncEngineRequest, reason: String) -> SyncEngineResult {
        SyncEngineResult(request: request, started: false, skippedReason: reason)
    }
}

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

protocol SyncEngine: AnyObject, Sendable {
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

final class DefaultSyncEngine: SyncEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightKeys: Set<String> = []
    private var remoteSnapshotRefreshGeneration = 0
    private var remoteSnapshotRefreshID: UUID?
    private var isRemoteSnapshotRefreshing = false
    private var remoteConversationSyncVersion: Int64 = 0
    private var secondarySnapshotTaskClaims: Set<SecondarySnapshotOperation> = []
    private var secondarySnapshotTasks: [SecondarySnapshotOperation: Task<Void, Never>] = [:]
    private var inboxRefreshTaskToken: InboxRefreshTaskToken?
    private var inboxRefreshTask: Task<Void, Never>?
    private var authSessionRefreshTaskToken: AuthSessionRefreshTaskToken?
    private var authSessionRefreshTask: Task<Bool, Never>?
    private var realtimeConnectionActive = false
    private var activeRealtimeConversationID: String?
    private var realtimeRecoveryConversationIDs: [String] = []
    private var realtimeRecoveryConversationIDSet: Set<String> = []
    private var lastRealtimeRecoveryRefreshAt: Date?
    private var realtimeRecoveryTaskClaims: Set<RealtimeRecoveryTaskKind> = []
    private var realtimeRecoveryTasks: [RealtimeRecoveryTaskKind: Task<Void, Never>] = [:]
    private var realtimeReconnectNoticeActive = false
    private var lastRealtimeReconnectNoticeAt: Date?
    private var lastRemoteErrorToastKey = ""
    private var lastRemoteErrorToastAt: Date?

    func begin(_ request: SyncEngineRequest) -> SyncEngineResult {
        let key = request.inFlightKey
        lock.lock()
        defer { lock.unlock() }

        guard !inFlightKeys.contains(key) else {
            return .skipped(request, reason: "sync request already in flight")
        }

        inFlightKeys.insert(key)
        return .started(request)
    }

    func finish(_ request: SyncEngineRequest) {
        lock.lock()
        defer { lock.unlock() }

        inFlightKeys.remove(request.inFlightKey)
    }

    func isInFlight(_ request: SyncEngineRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return inFlightKeys.contains(request.inFlightKey)
    }

    func remoteSnapshotSyncPlan(scope: String, force: Bool) -> RemoteSnapshotSyncPlan {
        let command = RemoteSnapshotSyncCommand(scope: scope, force: force)
        guard !command.scope.isEmpty else {
            return .skip(command, reason: "empty remote snapshot scope")
        }
        guard !isInFlight(command.request) else {
            return .skip(command, reason: "remote snapshot already in flight")
        }
        return .remoteSnapshot(command)
    }

    func beginRemoteSnapshotSync(_ command: RemoteSnapshotSyncCommand) -> SyncEngineResult {
        begin(command.request)
    }

    func finishRemoteSnapshotSync(_ command: RemoteSnapshotSyncCommand) {
        finish(command.request)
    }

    func beginRemoteSnapshotRefresh() -> RemoteSnapshotRefreshSession {
        lock.lock()
        defer { lock.unlock() }

        let session = RemoteSnapshotRefreshSession(generation: remoteSnapshotRefreshGeneration)
        remoteSnapshotRefreshID = session.id
        isRemoteSnapshotRefreshing = true
        return session
    }

    func finishRemoteSnapshotRefresh(_ session: RemoteSnapshotRefreshSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard remoteSnapshotRefreshID == session.id,
              remoteSnapshotRefreshGeneration == session.generation,
              isRemoteSnapshotRefreshing else {
            return false
        }
        isRemoteSnapshotRefreshing = false
        return true
    }

    func currentRemoteSnapshotRefreshSession() -> RemoteSnapshotRefreshSession? {
        lock.lock()
        defer { lock.unlock() }

        guard let remoteSnapshotRefreshID else { return nil }
        return RemoteSnapshotRefreshSession(
            id: remoteSnapshotRefreshID,
            generation: remoteSnapshotRefreshGeneration
        )
    }

    func isCurrentRemoteSnapshotRefresh(_ session: RemoteSnapshotRefreshSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return remoteSnapshotRefreshID == session.id
            && remoteSnapshotRefreshGeneration == session.generation
    }

    func isCurrentRemoteSnapshotGeneration(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return remoteSnapshotRefreshGeneration == generation
    }

    func currentRemoteSnapshotGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }

        return remoteSnapshotRefreshGeneration
    }

    func remoteConversationSyncCommand(forceFull: Bool) -> RemoteConversationSyncCommand {
        RemoteConversationSyncCommand(
            requestedVersion: requestedRemoteConversationSyncVersion(forceFull: forceFull),
            forceFull: forceFull
        )
    }

    func finishRemoteConversationSync(_ command: RemoteConversationSyncCommand, responseVersion: Int64) {
        rememberRemoteConversationSyncVersion(responseVersion)
    }

    func requestedRemoteConversationSyncVersion(forceFull: Bool) -> Int64 {
        guard !forceFull else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        return remoteConversationSyncVersion
    }

    func rememberRemoteConversationSyncVersion(_ version: Int64) {
        lock.lock()
        defer { lock.unlock() }

        remoteConversationSyncVersion = max(remoteConversationSyncVersion, version)
    }

    func currentRemoteConversationSyncVersion() -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        return remoteConversationSyncVersion
    }

    func secondarySnapshotCommands(
        groupsDelayNs: UInt64,
        contactsDelayNs: UInt64,
        profileDeviceDelayNs: UInt64
    ) -> [SecondarySnapshotSyncCommand] {
        [
            SecondarySnapshotSyncCommand(operation: .groups, delayNs: groupsDelayNs),
            SecondarySnapshotSyncCommand(operation: .contacts, delayNs: contactsDelayNs),
            SecondarySnapshotSyncCommand(operation: .profileDevice, delayNs: profileDeviceDelayNs)
        ]
    }

    func claimSecondarySnapshotTask(_ operation: SecondarySnapshotOperation) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !secondarySnapshotTaskClaims.contains(operation) else { return false }
        secondarySnapshotTaskClaims.insert(operation)
        return true
    }

    func attachSecondarySnapshotTask(_ operation: SecondarySnapshotOperation, task: Task<Void, Never>) {
        var replacedTask: Task<Void, Never>?
        var shouldCancelIncoming = false
        lock.lock()
        if secondarySnapshotTaskClaims.contains(operation) {
            replacedTask = secondarySnapshotTasks.updateValue(task, forKey: operation)
        } else {
            shouldCancelIncoming = true
        }
        lock.unlock()

        replacedTask?.cancel()
        if shouldCancelIncoming {
            task.cancel()
        }
    }

    func finishSecondarySnapshotTask(_ operation: SecondarySnapshotOperation) {
        lock.lock()
        defer { lock.unlock() }

        secondarySnapshotTasks.removeValue(forKey: operation)
        secondarySnapshotTaskClaims.remove(operation)
    }

    func hasSecondarySnapshotTask(_ operation: SecondarySnapshotOperation) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return secondarySnapshotTaskClaims.contains(operation)
    }

    func cancelSecondarySnapshotTasks() {
        lock.lock()
        let tasks = Array(secondarySnapshotTasks.values)
        secondarySnapshotTasks.removeAll()
        secondarySnapshotTaskClaims.removeAll()
        lock.unlock()

        tasks.forEach { $0.cancel() }
    }

    func claimInboxRefreshTask() -> InboxRefreshTaskToken? {
        lock.lock()
        defer { lock.unlock() }

        guard inboxRefreshTaskToken == nil else { return nil }
        let token = InboxRefreshTaskToken()
        inboxRefreshTaskToken = token
        return token
    }

    func attachInboxRefreshTask(_ token: InboxRefreshTaskToken, task: Task<Void, Never>) {
        var replacedTask: Task<Void, Never>?
        var shouldCancelIncoming = false
        lock.lock()
        if inboxRefreshTaskToken == token {
            replacedTask = inboxRefreshTask
            inboxRefreshTask = task
        } else {
            shouldCancelIncoming = true
        }
        lock.unlock()

        replacedTask?.cancel()
        if shouldCancelIncoming {
            task.cancel()
        }
    }

    func finishInboxRefreshTask(_ token: InboxRefreshTaskToken) {
        lock.lock()
        defer { lock.unlock() }

        guard inboxRefreshTaskToken == token else { return }
        inboxRefreshTask = nil
        inboxRefreshTaskToken = nil
    }

    func hasInboxRefreshTask() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return inboxRefreshTaskToken != nil
    }

    func cancelInboxRefreshTask() {
        lock.lock()
        let task = inboxRefreshTask
        inboxRefreshTask = nil
        inboxRefreshTaskToken = nil
        lock.unlock()

        task?.cancel()
    }

    func currentAuthSessionRefreshTask() -> Task<Bool, Never>? {
        lock.lock()
        defer { lock.unlock() }

        return authSessionRefreshTask
    }

    func currentAuthSessionRefreshTask(for fence: IMAuthSessionFence) -> Task<Bool, Never>? {
        lock.lock()
        defer { lock.unlock() }

        guard authSessionRefreshTaskToken?.fence == fence else { return nil }
        return authSessionRefreshTask
    }

    func claimAuthSessionRefreshTask() -> AuthSessionRefreshTaskToken? {
        lock.lock()
        defer { lock.unlock() }

        guard authSessionRefreshTaskToken == nil else { return nil }
        let token = AuthSessionRefreshTaskToken()
        authSessionRefreshTaskToken = token
        return token
    }

    func claimAuthSessionRefreshTask(for fence: IMAuthSessionFence) -> AuthSessionRefreshTaskToken? {
        lock.lock()
        defer { lock.unlock() }

        guard authSessionRefreshTaskToken == nil else { return nil }
        let token = AuthSessionRefreshTaskToken(fence: fence)
        authSessionRefreshTaskToken = token
        return token
    }

    func attachAuthSessionRefreshTask(_ token: AuthSessionRefreshTaskToken, task: Task<Bool, Never>) {
        var replacedTask: Task<Bool, Never>?
        var shouldCancelIncoming = false
        lock.lock()
        if authSessionRefreshTaskToken == token {
            replacedTask = authSessionRefreshTask
            authSessionRefreshTask = task
        } else {
            shouldCancelIncoming = true
        }
        lock.unlock()

        replacedTask?.cancel()
        if shouldCancelIncoming {
            task.cancel()
        }
    }

    func finishAuthSessionRefreshTask(_ token: AuthSessionRefreshTaskToken) {
        lock.lock()
        defer { lock.unlock() }

        guard authSessionRefreshTaskToken == token else { return }
        authSessionRefreshTask = nil
        authSessionRefreshTaskToken = nil
    }

    func hasAuthSessionRefreshTask() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return authSessionRefreshTaskToken != nil
    }

    func cancelAuthSessionRefreshTask() {
        lock.lock()
        let task = authSessionRefreshTask
        authSessionRefreshTask = nil
        authSessionRefreshTaskToken = nil
        lock.unlock()

        task?.cancel()
    }

    func updateRealtimeConnectionState(isConnected: Bool) {
        lock.lock()
        defer { lock.unlock() }

        realtimeConnectionActive = isConnected
    }

    func isRealtimeConnectionActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return realtimeConnectionActive
    }

    func shouldPollActiveConversation() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return !realtimeConnectionActive
    }

    func updateActiveRealtimeConversationID(_ conversationID: String?) {
        let normalizedID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        defer { lock.unlock() }

        activeRealtimeConversationID = normalizedID.isEmpty ? nil : normalizedID
    }

    func clearActiveRealtimeConversationID(_ conversationID: String) {
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }

        guard activeRealtimeConversationID == normalizedID else { return }
        activeRealtimeConversationID = nil
    }

    func currentActiveRealtimeConversationID() -> String? {
        lock.lock()
        defer { lock.unlock() }

        return activeRealtimeConversationID
    }

    func enqueueRealtimeRecoveryConversation(_ conversationID: String?) -> Bool {
        let normalizedID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedID.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }

        guard !realtimeRecoveryConversationIDSet.contains(normalizedID) else { return false }
        realtimeRecoveryConversationIDSet.insert(normalizedID)
        realtimeRecoveryConversationIDs.append(normalizedID)
        return true
    }

    func drainRealtimeRecoveryConversations() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let conversationIDs = realtimeRecoveryConversationIDs
        realtimeRecoveryConversationIDs.removeAll()
        realtimeRecoveryConversationIDSet.removeAll()
        return conversationIDs
    }

    func realtimeRecoveryRefreshPlan(
        reason: String,
        now: Date = Date(),
        throttleInterval: TimeInterval
    ) -> RealtimeRecoveryRefreshPlan {
        let command = RealtimeRecoveryRefreshCommand(reason: reason)
        lock.lock()
        defer { lock.unlock() }

        if throttleInterval > 0,
           let lastRealtimeRecoveryRefreshAt,
           now.timeIntervalSince(lastRealtimeRecoveryRefreshAt) < throttleInterval {
            return .flushOnly(command, reason: "realtime recovery refresh throttled")
        }
        guard !inFlightKeys.contains(command.request.inFlightKey) else {
            return .flushOnly(command, reason: "realtime recovery refresh already in flight")
        }
        return .refresh(command)
    }

    func beginRealtimeRecoveryRefresh(_ command: RealtimeRecoveryRefreshCommand) -> SyncEngineResult {
        begin(command.request)
    }

    func finishRealtimeRecoveryRefresh(_ command: RealtimeRecoveryRefreshCommand) {
        finish(command.request)
    }

    func rememberRealtimeRecoveryRefresh(at date: Date) {
        lock.lock()
        defer { lock.unlock() }

        lastRealtimeRecoveryRefreshAt = date
    }

    func claimRealtimeRecoveryTask(_ kind: RealtimeRecoveryTaskKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !realtimeRecoveryTaskClaims.contains(kind) else { return false }
        realtimeRecoveryTaskClaims.insert(kind)
        return true
    }

    func attachRealtimeRecoveryTask(_ kind: RealtimeRecoveryTaskKind, task: Task<Void, Never>) {
        var replacedTask: Task<Void, Never>?
        var shouldCancelIncoming = false
        lock.lock()
        if realtimeRecoveryTaskClaims.contains(kind) {
            replacedTask = realtimeRecoveryTasks.updateValue(task, forKey: kind)
        } else {
            shouldCancelIncoming = true
        }
        lock.unlock()

        replacedTask?.cancel()
        if shouldCancelIncoming {
            task.cancel()
        }
    }

    func finishRealtimeRecoveryTask(_ kind: RealtimeRecoveryTaskKind) {
        lock.lock()
        defer { lock.unlock() }

        realtimeRecoveryTasks.removeValue(forKey: kind)
        realtimeRecoveryTaskClaims.remove(kind)
    }

    func hasRealtimeRecoveryTask(_ kind: RealtimeRecoveryTaskKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return realtimeRecoveryTaskClaims.contains(kind)
    }

    func cancelRealtimeRecoveryTasks() {
        lock.lock()
        let tasks = Array(realtimeRecoveryTasks.values)
        realtimeRecoveryTasks.removeAll()
        realtimeRecoveryTaskClaims.removeAll()
        lock.unlock()

        tasks.forEach { $0.cancel() }
    }

    func realtimeReconnectNoticePlan(
        now: Date = Date(),
        throttleInterval: TimeInterval
    ) -> RealtimeReconnectNoticePlan {
        lock.lock()
        defer { lock.unlock() }

        if throttleInterval > 0,
           realtimeReconnectNoticeActive,
           let lastRealtimeReconnectNoticeAt,
           now.timeIntervalSince(lastRealtimeReconnectNoticeAt) < throttleInterval {
            return .skip(reason: "realtime reconnect notice throttled")
        }
        return .show
    }

    func rememberRealtimeReconnectNoticeShown(at date: Date) {
        lock.lock()
        defer { lock.unlock() }

        realtimeReconnectNoticeActive = true
        lastRealtimeReconnectNoticeAt = date
    }

    func clearRealtimeReconnectNotice() {
        lock.lock()
        defer { lock.unlock() }

        realtimeReconnectNoticeActive = false
    }

    func remoteErrorToastPlan(
        message: String,
        now: Date = Date(),
        throttleInterval: TimeInterval
    ) -> RemoteErrorToastPlan {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .skip(message: normalized, reason: "empty remote error toast")
        }

        lock.lock()
        defer { lock.unlock() }

        if throttleInterval > 0,
           normalized == lastRemoteErrorToastKey,
           let lastRemoteErrorToastAt,
           now.timeIntervalSince(lastRemoteErrorToastAt) < throttleInterval {
            return .skip(message: normalized, reason: "remote error toast throttled")
        }
        return .show(message: normalized)
    }

    func rememberRemoteErrorToastShown(message: String, at date: Date) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        lastRemoteErrorToastKey = normalized
        lastRemoteErrorToastAt = date
    }

    func clearRemoteErrorToastThrottle() {
        lock.lock()
        defer { lock.unlock() }

        lastRemoteErrorToastKey = ""
        lastRemoteErrorToastAt = nil
    }

    func reset() {
        lock.lock()
        let voidTasks = Array(secondarySnapshotTasks.values)
            + Array(realtimeRecoveryTasks.values)
            + [inboxRefreshTask].compactMap { $0 }
        let authTask = authSessionRefreshTask

        inFlightKeys.removeAll()
        remoteSnapshotRefreshGeneration += 1
        remoteSnapshotRefreshID = nil
        isRemoteSnapshotRefreshing = false
        remoteConversationSyncVersion = 0
        secondarySnapshotTasks.removeAll()
        secondarySnapshotTaskClaims.removeAll()
        inboxRefreshTask = nil
        inboxRefreshTaskToken = nil
        authSessionRefreshTask = nil
        authSessionRefreshTaskToken = nil
        realtimeConnectionActive = false
        activeRealtimeConversationID = nil
        realtimeRecoveryConversationIDs.removeAll()
        realtimeRecoveryConversationIDSet.removeAll()
        lastRealtimeRecoveryRefreshAt = nil
        realtimeRecoveryTasks.removeAll()
        realtimeRecoveryTaskClaims.removeAll()
        realtimeReconnectNoticeActive = false
        lastRealtimeReconnectNoticeAt = nil
        lastRemoteErrorToastKey = ""
        lastRemoteErrorToastAt = nil
        lock.unlock()

        voidTasks.forEach { $0.cancel() }
        authTask?.cancel()
    }
}

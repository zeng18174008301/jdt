// WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
import Combine
import Foundation
import IM4Data
import IM4Domain

public protocol CallRecordPersisting: AnyObject {
    func load(scope: String) -> [CallRecord]
    func save(_ records: [CallRecord], scope: String)
}

@MainActor
public final class CallStore: ObservableObject {
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_BEGIN
    public struct RootPresentation: Equatable {
        public let incoming: IncomingVoiceCall?
        public let activeCallID: String?
        public let activeCallIsVideo: Bool
        public let minimizedVideoCall: VoiceCallSession?
        public let preview: VideoCallPreview?
        public let terminalResult: VideoCallTerminalResult?

        init(
            incoming: IncomingVoiceCall?, active: VoiceCallSession?,
            preview: VideoCallPreview?, terminalResult: VideoCallTerminalResult?
        ) {
            self.incoming = incoming
            activeCallID = active?.id
            activeCallIsVideo = active?.isVideoCall == true
            minimizedVideoCall = activeCallIsVideo && active?.isMinimized == true ? active : nil
            self.preview = preview
            self.terminalResult = terminalResult
        }
    }

    public var rootPresentation: RootPresentation {
        RootPresentation(
            incoming: incomingVoiceCall, active: activeVoiceCall,
            preview: videoCallPreview, terminalResult: videoCallTerminalResult
        )
    }

    public var rootPresentationUpdates: AnyPublisher<RootPresentation, Never> {
        Publishers.CombineLatest4($incomingVoiceCall, $activeVoiceCall, $videoCallPreview, $videoCallTerminalResult)
            .map { incoming, active, preview, terminal in
                RootPresentation(incoming: incoming, active: active, preview: preview, terminalResult: terminal)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_END

    @Published public var incomingVoiceCall: IncomingVoiceCall?
    @Published public var activeVoiceCall: VoiceCallSession?
    @Published public var videoCallPreview: VideoCallPreview?
    @Published public var videoCallTerminalResult: VideoCallTerminalResult?
    @Published public var calls: [CallRecord] = [] {
        didSet {
            persistCallRecordsIfNeeded()
        }
    }
    @Published public var incomingCallAnswerMode: String?
    public var incomingCallAnswerOperationID: UUID?
    @Published public var isStartingVoiceCall = false
    @Published public var isStartingVideoCall = false
    @Published public var isEndingActiveCall = false
    @Published public var activeCallEndError: String?
    public var videoCallStartGeneration: UUID?

    private var watchdogTask: Task<Void, Never>?
    public private(set) var lifecycle = CallLifecycleStateMachine()
    public private(set) var promptCoordinator = CallPromptCoordinator()
    private var nextLifecycleEpoch: UInt64 = 0
    // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_BEGIN
    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
    private struct RecordBinding: Sendable {
        let scope: String
        let fallbackScopes: [String]
        let runtimeScope: LocalMessageScope?
        let admission = CallRecordRestoreAdmission()
        var isLoading = true
        var shadowedRecords: [String: CallRecord] = [:]
    }

    private let recordArchive: CallRecordArchiveWork
    private var recordBinding: RecordBinding?
    private var isReplacingCallRecordsWithoutPersistence = false

    public init(callRecordStore: any CallRecordPersisting) {
        recordArchive = CallRecordArchiveWork(store: callRecordStore)
    }

    deinit {
        recordBinding?.admission.retire()
    }

    public var hasCallRecordPersistenceBinding: Bool {
        recordBinding != nil
    }

    public func hasCallRecordPersistenceBinding(for runtimeScope: LocalMessageScope) -> Bool {
        recordBinding?.runtimeScope == runtimeScope
    }
    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END
    // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_END

    public var hasTruthfulCall: Bool {
        lifecycle.hasActiveCall
    }

    public var activeLifecycleSnapshot: CallLifecycleSnapshot? {
        lifecycle.activeSnapshot
    }

    @discardableResult
    public func claimLifecycle(
        scopeID: String,
        callID: String,
        direction: CallLifecycleDirection,
        stateVersion: Int64 = 0,
        reason: String = ""
    ) -> CallLifecycleTransition? {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return nil }
        nextLifecycleEpoch &+= 1
        let identity = CallLifecycleSessionIdentity(
            scopeID: scopeID,
            callID: normalizedCallID,
            epoch: nextLifecycleEpoch
        )
        return lifecycle.claim(
            identity,
            direction: direction,
            revision: max(-1, stateVersion - 1),
            reason: reason
        )
    }

    @discardableResult
    public func advanceLifecycle(
        callID: String,
        to phase: CallLifecyclePhase,
        stateVersion: Int64? = nil,
        reason: String = ""
    ) -> CallLifecycleTransition? {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot = lifecycle.activeSnapshot,
              !normalizedCallID.isEmpty,
              snapshot.identity.callID == normalizedCallID else {
            return nil
        }
        return lifecycle.apply(
            CallLifecycleEvent(
                identity: snapshot.identity,
                phase: phase,
                revision: stateVersion,
                reason: reason
            )
        )
    }

    @discardableResult
    public func reconcileLifecycle(
        observedSnapshot: CallLifecycleSnapshot?,
        remoteCalls: [CallLifecycleReconciliationItem]
    ) -> CallLifecycleTransition? {
        guard let observedSnapshot else { return nil }
        return lifecycle.reconcile(
            CallLifecycleReconciliationEvent(
                scopeID: observedSnapshot.identity.scopeID,
                observedOwnerEpoch: observedSnapshot.identity.epoch,
                observedOwnerRevision: observedSnapshot.revision,
                observedOwnerLocalVersion: observedSnapshot.localVersion,
                calls: remoteCalls
            )
        )
    }

    @discardableResult
    public func releaseLifecycle(
        as phase: CallLifecyclePhase = .ended,
        reason: String
    ) -> CallLifecycleTransition {
        lifecycle.releaseActive(as: phase, reason: reason)
    }

    public func promptCommands(for transition: CallLifecycleTransition) -> [CallPromptCommand] {
        promptCoordinator.commands(for: transition)
    }

    public func promptCommands(for event: CallPromptEnvironmentEvent) -> [CallPromptCommand] {
        promptCoordinator.commands(for: event, activeSnapshot: lifecycle.activeSnapshot)
    }

    public var hasVoiceCallWatchdogTask: Bool {
        watchdogTask != nil
    }

    public func replaceVoiceCallWatchdogTask(_ task: Task<Void, Never>) {
        watchdogTask?.cancel()
        watchdogTask = task
    }

    public func cancelVoiceCallWatchdogTask() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_BEGIN
    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
    public func bindCallRecordPersistence(
        scope: String,
        fallbackScopes: [String] = []
    ) {
        bindCallRecordPersistence(scope: scope, fallbackScopes: fallbackScopes, runtimeScope: nil)
    }

    public func bindCallRecordPersistence(
        scope: String,
        fallbackScopes: [String] = [],
        runtimeScope: LocalMessageScope?
    ) {
        let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty else {
            clearCallRecordPersistenceBinding()
            return
        }
        if let recordBinding, recordBinding.scope == scope, recordBinding.runtimeScope == runtimeScope { return }
        clearCallRecordPersistenceBinding()

        let binding = RecordBinding(scope: scope, fallbackScopes: fallbackScopes, runtimeScope: runtimeScope)
        recordBinding = binding
        recordArchive.restore(scope: scope, fallbackScopes: fallbackScopes, admission: binding.admission) { [weak self] records in
            guard let self, self.recordBinding?.admission === binding.admission else { return }
            let pending = self.calls
            let combined = CallRecordArchiveWork.prepending(pending, to: records)
            self.recordBinding?.isLoading = false
            if !pending.isEmpty {
                // An optimistic call may have shadowed its archived row before this
                // read returned. Keep that row available for the original rollback.
                let pendingIDs = Set(pending.compactMap(\.callID))
                for record in records.reversed() {
                    if let callID = record.callID, pendingIDs.contains(callID) {
                        self.recordBinding?.shadowedRecords[callID] = record
                    }
                }
                self.recordArchive.save(combined, scope: scope)
            }
            self.replaceCallRecordsWithoutPersistence(combined)
        }
    }

    public func makeCallRecordRollback(callID: String) -> @MainActor () -> Void {
        let position = calls.firstIndex { $0.callID == callID }
        let original = position.map { calls[$0] }
        let admission = recordBinding?.admission
        let wasLoading = recordBinding?.isLoading == true
        return { [weak self] in
            guard let self, self.recordBinding?.admission === admission else { return }
            var rows = self.calls
            let current = rows.firstIndex { $0.callID == callID }
            if let current { rows.remove(at: current) }
            let archived = wasLoading ? self.recordBinding?.shadowedRecords[callID] : nil
            if let previous = original ?? archived {
                rows.insert(previous, at: min(position ?? current ?? rows.endIndex, rows.endIndex))
            }
            if rows != self.calls { self.calls = rows }
        }
    }

    public func clearCallRecordPersistenceBinding() {
        recordBinding?.admission.retire()
        if let binding = recordBinding, binding.isLoading, !calls.isEmpty {
            // The restore is already in the queue. Preserve accepted changes for the
            // retiring scope even when its result can no longer publish to the UI.
            recordArchive.savePending(calls, scope: binding.scope, fallbackScopes: binding.fallbackScopes)
        }
        recordBinding = nil
        replaceCallRecordsWithoutPersistence([])
    }
    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END
    // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_END

    public func reset() {
        cancelVoiceCallWatchdogTask()
        clearCallRecordPersistenceBinding() // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111: also clears the visible history.
        activeVoiceCall = nil
        incomingVoiceCall = nil
        incomingCallAnswerMode = nil
        incomingCallAnswerOperationID = nil
        videoCallPreview = nil
        videoCallTerminalResult = nil
        isStartingVoiceCall = false
        isStartingVideoCall = false
        isEndingActiveCall = false
        activeCallEndError = nil
        videoCallStartGeneration = nil
        lifecycle = CallLifecycleStateMachine()
        promptCoordinator = CallPromptCoordinator()
    }

    private func replaceCallRecordsWithoutPersistence(_ records: [CallRecord]) {
        isReplacingCallRecordsWithoutPersistence = true
        calls = records
        isReplacingCallRecordsWithoutPersistence = false
    }

    // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_BEGIN
    private func persistCallRecordsIfNeeded() {
        guard !isReplacingCallRecordsWithoutPersistence,
              let binding = recordBinding, !binding.isLoading else { return }
        recordArchive.save(calls, scope: binding.scope)
    }
    // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_END
}

// WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_BEGIN
// WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
private final class CallRecordRestoreAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool { lock.withLock { active } }
    func retire() { lock.withLock { active = false } }
}

/// All CallStore instances submit to one FIFO, including a new store using the same archive.
/// The non-Sendable backend stays confined to this queue for the lifetime of the worker.
private final class CallRecordArchiveWork: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "ios.call-record-archive", qos: .utility)
    private let store: any CallRecordPersisting

    init(store: any CallRecordPersisting) {
        self.store = store
    }

    func restore(scope: String, fallbackScopes: [String], admission: CallRecordRestoreAdmission,
                 completion: @escaping @MainActor @Sendable ([CallRecord]) -> Void) {
        Self.queue.async {
            guard admission.isActive else { return }
            let (records, fromFallback) = self.restoreRecords(scope: scope, fallbackScopes: fallbackScopes)
            // A fallback read alone does not authorize a write after its binding retires.
            guard admission.isActive else { return }
            if fromFallback { self.store.save(records, scope: scope) }
            DispatchQueue.main.async { completion(records) }
        }
    }

    func save(_ records: [CallRecord], scope: String) {
        Self.queue.async { self.store.save(records, scope: scope) }
    }

    func savePending(_ records: [CallRecord], scope: String, fallbackScopes: [String]) {
        Self.queue.async {
            let restored = self.restoreRecords(scope: scope, fallbackScopes: fallbackScopes).records
            self.store.save(Self.prepending(records, to: restored), scope: scope)
        }
    }

    private func restoreRecords(scope: String, fallbackScopes: [String]) -> (records: [CallRecord], fromFallback: Bool) {
        let current = store.load(scope: scope)
        if !current.isEmpty { return (current, false) }

        var visited: Set<String> = [scope]
        for candidate in fallbackScopes {
            let fallback = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty, visited.insert(fallback).inserted else { continue }
            let records = store.load(scope: fallback)
            guard !records.isEmpty else { continue }
            return (records, true)
        }
        return ([], false)
    }

    static func prepending(_ pending: [CallRecord], to restored: [CallRecord]) -> [CallRecord] {
        guard !pending.isEmpty else { return restored }
        let rowIDs = Set(pending.map(\.id))
        let callIDs = Set(pending.compactMap(\.callID).filter { !$0.isEmpty })
        let remaining = restored.filter {
            !rowIDs.contains($0.id) && !($0.callID.map(callIDs.contains) ?? false)
        }
        return Array((pending + remaining).prefix(20))
    }
}
// WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END
// WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_END

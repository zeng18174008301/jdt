import Foundation

protocol CallRecordPersisting: AnyObject {
    func load(scope: String) -> [CallRecord]
    func save(_ records: [CallRecord], scope: String)
}

final class UserDefaultsCallRecordStore: CallRecordPersisting {
    private struct Archive: Codable {
        var schemaVersion: Int
        var recordsByScope: [String: [CallRecord]]
    }

    private static let currentSchemaVersion = 1
    private static let defaultStorageKey = "im2.ios.callRecords"
    private let defaults: UserDefaults
    private let storageKey: String
    private let archiveURL: URL?
    private let maxStoredRecords: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = UserDefaultsCallRecordStore.defaultStorageKey,
        archiveURL: URL? = nil,
        maxStoredRecords: Int = 20
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.archiveURL = archiveURL ?? (storageKey == Self.defaultStorageKey ? Self.defaultArchiveURL() : nil)
        self.maxStoredRecords = max(1, maxStoredRecords)
    }

    func load(scope: String) -> [CallRecord] {
        let normalizedScope = normalized(scope)
        guard !normalizedScope.isEmpty else { return [] }
        let records = Array(loadArchive().recordsByScope[normalizedScope, default: []].prefix(maxStoredRecords))
        debugLog("load", scope: normalizedScope, count: records.count)
        return records
    }

    func save(_ records: [CallRecord], scope: String) {
        let normalizedScope = normalized(scope)
        guard !normalizedScope.isEmpty else { return }
        var archive = loadArchive()
        let limitedRecords = Array(records.prefix(maxStoredRecords))
        if limitedRecords.isEmpty {
            archive.recordsByScope.removeValue(forKey: normalizedScope)
        } else {
            archive.recordsByScope[normalizedScope] = limitedRecords
        }
        persist(archive)
        debugLog("save", scope: normalizedScope, count: limitedRecords.count)
    }

    private func normalized(_ scope: String) -> String {
        scope.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadArchive() -> Archive {
        if let diskArchive = loadDiskArchive() {
            return diskArchive
        }
        if let defaultsArchive = loadDefaultsArchive() {
            writeDiskArchive(defaultsArchive)
            return defaultsArchive
        }
        return Archive(schemaVersion: Self.currentSchemaVersion, recordsByScope: [:])
    }

    private func persist(_ archive: Archive) {
        guard !archive.recordsByScope.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            defaults.synchronize()
            removeDiskArchive()
            return
        }
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
        writeDiskData(data)
    }

    private func loadDiskArchive() -> Archive? {
        guard let archiveURL,
              let data = try? Data(contentsOf: archiveURL),
              let decoded = try? JSONDecoder().decode(Archive.self, from: data),
              decoded.schemaVersion == Self.currentSchemaVersion else {
            return nil
        }
        return decoded
    }

    private func loadDefaultsArchive() -> Archive? {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Archive.self, from: data),
              decoded.schemaVersion == Self.currentSchemaVersion else {
            return nil
        }
        return decoded
    }

    private func writeDiskArchive(_ archive: Archive) {
        guard !archive.recordsByScope.isEmpty,
              let data = try? JSONEncoder().encode(archive) else { return }
        writeDiskData(data)
    }

    private func writeDiskData(_ data: Data) {
        guard let archiveURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: archiveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: archiveURL, options: [.atomic])
        } catch {
            #if DEBUG
            print("[JHT CallRecord] disk_write_failed \(error.localizedDescription)")
            #endif
        }
    }

    private func removeDiskArchive() {
        guard let archiveURL else { return }
        try? FileManager.default.removeItem(at: archiveURL)
    }

    private static func defaultArchiveURL() -> URL? {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        guard let base else { return nil }
        return base
            .appendingPathComponent("BlueStoneIM", isDirectory: true)
            .appendingPathComponent("CallRecords", isDirectory: true)
            .appendingPathComponent("call-records.json", isDirectory: false)
    }

    private func debugLog(_ action: String, scope: String, count: Int) {
        #if DEBUG
        print("[JHT CallRecord] \(action) scope=\(Self.scopeLogToken(scope)) count=\(count)")
        #endif
    }

    private static func scopeLogToken(_ scope: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in scope.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

@MainActor
final class CallStore: ObservableObject {
    @Published var incomingVoiceCall: IncomingVoiceCall?
    @Published var activeVoiceCall: VoiceCallSession?
    @Published var videoCallPreview: VideoCallPreview?
    @Published var videoCallTerminalResult: VideoCallTerminalResult?
    @Published var calls: [CallRecord] = [] {
        didSet {
            persistCallRecordsIfNeeded()
        }
    }
    @Published var incomingCallAnswerMode: String?
    var incomingCallAnswerOperationID: UUID?
    @Published var isStartingVoiceCall = false
    @Published var isStartingVideoCall = false
    @Published var isEndingActiveCall = false
    @Published var activeCallEndError: String?
    var videoCallStartGeneration: UUID?

    private var watchdogTask: Task<Void, Never>?
    private(set) var lifecycle = CallLifecycleStateMachine()
    private(set) var promptCoordinator = CallPromptCoordinator()
    private var nextLifecycleEpoch: UInt64 = 0
    private let callRecordStore: any CallRecordPersisting
    private var callRecordPersistenceScope: String?
    private var isReplacingCallRecordsWithoutPersistence = false

    init(callRecordStore: any CallRecordPersisting = UserDefaultsCallRecordStore()) {
        self.callRecordStore = callRecordStore
    }

    var hasCallRecordPersistenceBinding: Bool {
        !(callRecordPersistenceScope?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasTruthfulCall: Bool {
        lifecycle.hasActiveCall
    }

    var activeLifecycleSnapshot: CallLifecycleSnapshot? {
        lifecycle.activeSnapshot
    }

    @discardableResult
    func claimLifecycle(
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
    func advanceLifecycle(
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
    func reconcileLifecycle(
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
    func releaseLifecycle(
        as phase: CallLifecyclePhase = .ended,
        reason: String
    ) -> CallLifecycleTransition {
        lifecycle.releaseActive(as: phase, reason: reason)
    }

    func promptCommands(for transition: CallLifecycleTransition) -> [CallPromptCommand] {
        promptCoordinator.commands(for: transition)
    }

    func promptCommands(for event: CallPromptEnvironmentEvent) -> [CallPromptCommand] {
        promptCoordinator.commands(for: event, activeSnapshot: lifecycle.activeSnapshot)
    }

    var hasVoiceCallWatchdogTask: Bool {
        watchdogTask != nil
    }

    func replaceVoiceCallWatchdogTask(_ task: Task<Void, Never>) {
        watchdogTask?.cancel()
        watchdogTask = task
    }

    func cancelVoiceCallWatchdogTask() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    func bindCallRecordPersistence(
        scope: String,
        fallbackScopes: [String] = []
    ) {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else {
            clearCallRecordPersistenceBinding()
            replaceCallRecordsWithoutPersistence([])
            return
        }
        callRecordPersistenceScope = normalizedScope
        let records = callRecordStore.load(scope: normalizedScope)
        if !records.isEmpty {
            replaceCallRecordsWithoutPersistence(records)
            return
        }
        for fallbackScope in Self.normalizedUniqueScopes(fallbackScopes)
        where fallbackScope != normalizedScope {
            let migratedRecords = callRecordStore.load(scope: fallbackScope)
            guard !migratedRecords.isEmpty else { continue }
            replaceCallRecordsWithoutPersistence(migratedRecords)
            callRecordStore.save(migratedRecords, scope: normalizedScope)
            return
        }
        replaceCallRecordsWithoutPersistence([])
    }

    func clearCallRecordPersistenceBinding() {
        callRecordPersistenceScope = nil
        replaceCallRecordsWithoutPersistence([])
    }

    func reset() {
        cancelVoiceCallWatchdogTask()
        clearCallRecordPersistenceBinding()
        replaceCallRecordsWithoutPersistence([])
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

    private func persistCallRecordsIfNeeded() {
        guard !isReplacingCallRecordsWithoutPersistence,
              let scope = callRecordPersistenceScope,
              !scope.isEmpty else {
            return
        }
        callRecordStore.save(calls, scope: scope)
    }

    private static func normalizedUniqueScopes(_ scopes: [String]) -> [String] {
        var seen = Set<String>()
        return scopes.compactMap { rawScope in
            let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !scope.isEmpty, seen.insert(scope).inserted else { return nil }
            return scope
        }
    }
}

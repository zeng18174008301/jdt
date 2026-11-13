import Foundation

enum SplashSnapshotStore {
    private static let snapshotsKey = "im2.ios.splash.snapshots.v1"
    private static let displayStatesKey = "im2.ios.splash.displayStates.v1"
    private static let scopedSnapshotsKey = "im2.ios.splash.snapshots.v2"
    private static let scopedDisplayStatesKey = "im2.ios.splash.displayStates.v2"

    static func snapshot(scope: SplashTenantScope, defaults: UserDefaults = .standard) -> SplashConfigSnapshot? {
        guard scope.isValid else { return nil }
        return scopedSnapshots(defaults: defaults)[scope.storageKey]
    }

    static func displayableSnapshot(
        scope: SplashTenantScope,
        now: Date = Date(),
        cache: SplashImageDiskCache = .shared,
        defaults: UserDefaults = .standard
    ) -> SplashConfigSnapshot? {
        guard let snapshot = snapshot(scope: scope, defaults: defaults),
              snapshot.isDisplayable(scope: scope, now: now, cache: cache) else {
            return nil
        }
        return snapshot
    }

    static func saveSnapshot(
        _ snapshot: SplashConfigSnapshot,
        scope: SplashTenantScope,
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid,
              normalizedTenantID(snapshot.tenantID) == scope.tenantID else {
            return
        }
        var values = scopedSnapshots(defaults: defaults)
        values[scope.storageKey] = snapshot
        persist(values, key: scopedSnapshotsKey, defaults: defaults)
        ensureDisplayState(scope: scope, defaults: defaults)
    }

    @discardableResult
    static func updatePrefetchStatus(
        candidate: SplashRefreshCandidate,
        status: SplashImagePrefetchStatus,
        error: String = "",
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard var snapshot = snapshot(scope: candidate.scope, defaults: defaults),
              snapshot.normalizedVersion == candidate.version,
              snapshot.cacheKey(scope: candidate.scope) == candidate.cacheKey else {
            return false
        }
        snapshot = snapshot.withPrefetch(status: status, error: error)
        saveSnapshot(snapshot, scope: candidate.scope, defaults: defaults)
        return true
    }

    static func disableSnapshot(
        scope: SplashTenantScope,
        reason: String,
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid else { return }
        var values = scopedSnapshots(defaults: defaults)
        if let snapshot = values[scope.storageKey] {
            values[scope.storageKey] = snapshot.disabled(reason: reason)
        } else {
            values.removeValue(forKey: scope.storageKey)
        }
        persist(values, key: scopedSnapshotsKey, defaults: defaults)
    }

    static func clearScope(_ scope: SplashTenantScope, defaults: UserDefaults = .standard) {
        guard scope.isValid else { return }
        var values = scopedSnapshots(defaults: defaults)
        values.removeValue(forKey: scope.storageKey)
        persist(values, key: scopedSnapshotsKey, defaults: defaults)
        var states = scopedDisplayStates(defaults: defaults)
        states.removeValue(forKey: scope.storageKey)
        persist(states, key: scopedDisplayStatesKey, defaults: defaults)
    }

    static func scopedSnapshots(defaults: UserDefaults = .standard) -> [String: SplashConfigSnapshot] {
        dictionary(forKey: scopedSnapshotsKey, defaults: defaults)
    }

    static func scopedDisplayStates(defaults: UserDefaults = .standard) -> [String: SplashDisplayState] {
        dictionary(forKey: scopedDisplayStatesKey, defaults: defaults)
    }

    static func displayState(scope: SplashTenantScope, defaults: UserDefaults = .standard) -> SplashDisplayState {
        guard scope.isValid else { return .empty }
        return scopedDisplayStates(defaults: defaults)[scope.storageKey] ?? .empty
    }

    static func saveDisplayState(
        _ state: SplashDisplayState,
        scope: SplashTenantScope,
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid else { return }
        var states = scopedDisplayStates(defaults: defaults)
        states[scope.storageKey] = state
        persist(states, key: scopedDisplayStatesKey, defaults: defaults)
    }

    static func recordShown(
        snapshot: SplashConfigSnapshot,
        scope: SplashTenantScope,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid,
              normalizedTenantID(snapshot.tenantID) == scope.tenantID else {
            return
        }
        let state = displayState(scope: scope, defaults: defaults)
            .recordingShown(snapshot: snapshot, at: date)
        saveDisplayState(state, scope: scope, defaults: defaults)
    }

    static func recordBackgrounded(
        scope: SplashTenantScope,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid else { return }
        let state = displayState(scope: scope, defaults: defaults)
            .recordingBackgrounded(at: date)
        saveDisplayState(state, scope: scope, defaults: defaults)
    }

    static func snapshot(tenantID: String, defaults: UserDefaults = .standard) -> SplashConfigSnapshot? {
        snapshots(defaults: defaults)[normalizedTenantID(tenantID)]
    }

    static func displayableSnapshot(
        tenantID: String,
        now: Date = Date(),
        cache: SplashImageDiskCache = .shared,
        defaults: UserDefaults = .standard
    ) -> SplashConfigSnapshot? {
        guard let snapshot = snapshot(tenantID: tenantID, defaults: defaults),
              snapshot.isDisplayable(now: now, cache: cache) else {
            return nil
        }
        return snapshot
    }

    static func saveSnapshot(_ snapshot: SplashConfigSnapshot, defaults: UserDefaults = .standard) {
        let tenantID = normalizedTenantID(snapshot.tenantID)
        guard !tenantID.isEmpty else { return }
        var values = snapshots(defaults: defaults)
        values[tenantID] = snapshot
        persist(values, key: snapshotsKey, defaults: defaults)
        ensureDisplayState(tenantID: tenantID, defaults: defaults)
    }

    static func updatePrefetchStatus(
        tenantID: String,
        status: SplashImagePrefetchStatus,
        error: String = "",
        defaults: UserDefaults = .standard
    ) {
        let tenantID = normalizedTenantID(tenantID)
        guard var snapshot = snapshots(defaults: defaults)[tenantID] else { return }
        snapshot = snapshot.withPrefetch(status: status, error: error)
        saveSnapshot(snapshot, defaults: defaults)
    }

    static func disableSnapshot(tenantID: String, reason: String, defaults: UserDefaults = .standard) {
        let tenantID = normalizedTenantID(tenantID)
        guard !tenantID.isEmpty else { return }
        var values = snapshots(defaults: defaults)
        if let snapshot = values[tenantID] {
            values[tenantID] = snapshot.disabled(reason: reason)
        } else {
            values.removeValue(forKey: tenantID)
        }
        persist(values, key: snapshotsKey, defaults: defaults)
    }

    static func clearTenant(_ tenantID: String, defaults: UserDefaults = .standard) {
        let tenantID = normalizedTenantID(tenantID)
        guard !tenantID.isEmpty else { return }
        var values = snapshots(defaults: defaults)
        values.removeValue(forKey: tenantID)
        persist(values, key: snapshotsKey, defaults: defaults)
        var states = displayStates(defaults: defaults)
        states.removeValue(forKey: tenantID)
        persist(states, key: displayStatesKey, defaults: defaults)

        var scopedValues = scopedSnapshots(defaults: defaults)
        let removedScopeKeys = scopedValues.compactMap { key, snapshot in
            normalizedTenantID(snapshot.tenantID) == tenantID ? key : nil
        }
        for key in removedScopeKeys {
            scopedValues.removeValue(forKey: key)
        }
        persist(scopedValues, key: scopedSnapshotsKey, defaults: defaults)
        var scopedStates = scopedDisplayStates(defaults: defaults)
        for key in removedScopeKeys {
            scopedStates.removeValue(forKey: key)
        }
        persist(scopedStates, key: scopedDisplayStatesKey, defaults: defaults)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: snapshotsKey)
        defaults.removeObject(forKey: displayStatesKey)
        defaults.removeObject(forKey: scopedSnapshotsKey)
        defaults.removeObject(forKey: scopedDisplayStatesKey)
    }

    static func snapshots(defaults: UserDefaults = .standard) -> [String: SplashConfigSnapshot] {
        dictionary(forKey: snapshotsKey, defaults: defaults)
    }

    static func displayStates(defaults: UserDefaults = .standard) -> [String: SplashDisplayState] {
        dictionary(forKey: displayStatesKey, defaults: defaults)
    }

    static func displayState(tenantID: String, defaults: UserDefaults = .standard) -> SplashDisplayState {
        displayStates(defaults: defaults)[normalizedTenantID(tenantID)] ?? .empty
    }

    static func saveDisplayState(
        _ state: SplashDisplayState,
        tenantID: String,
        defaults: UserDefaults = .standard
    ) {
        let tenantID = normalizedTenantID(tenantID)
        guard !tenantID.isEmpty else { return }
        var states = displayStates(defaults: defaults)
        states[tenantID] = state
        persist(states, key: displayStatesKey, defaults: defaults)
    }

    static func recordShown(
        snapshot: SplashConfigSnapshot,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let tenantID = normalizedTenantID(snapshot.tenantID)
        guard !tenantID.isEmpty else { return }
        let state = displayState(tenantID: tenantID, defaults: defaults)
            .recordingShown(snapshot: snapshot, at: date)
        saveDisplayState(state, tenantID: tenantID, defaults: defaults)
    }

    static func recordBackgrounded(
        tenantID: String,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let tenantID = normalizedTenantID(tenantID)
        guard !tenantID.isEmpty else { return }
        let state = displayState(tenantID: tenantID, defaults: defaults)
            .recordingBackgrounded(at: date)
        saveDisplayState(state, tenantID: tenantID, defaults: defaults)
    }

    private static func ensureDisplayState(tenantID: String, defaults: UserDefaults) {
        var states = displayStates(defaults: defaults)
        if states[tenantID] == nil {
            states[tenantID] = .empty
            persist(states, key: displayStatesKey, defaults: defaults)
        }
    }

    private static func ensureDisplayState(scope: SplashTenantScope, defaults: UserDefaults) {
        var states = scopedDisplayStates(defaults: defaults)
        if states[scope.storageKey] == nil {
            states[scope.storageKey] = .empty
            persist(states, key: scopedDisplayStatesKey, defaults: defaults)
        }
    }

    private static func dictionary<T: Decodable>(forKey key: String, defaults: UserDefaults) -> [String: T] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: T].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persist<T: Encodable>(_ value: [String: T], key: String, defaults: UserDefaults) {
        if value.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func normalizedTenantID(_ tenantID: String) -> String {
        tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

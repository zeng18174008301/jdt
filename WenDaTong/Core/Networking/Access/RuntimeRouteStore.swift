// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_BEGIN
import Foundation
import IM4Data

typealias IMRuntimeRouteRecoveryState = IM4Data.IMRuntimeRouteRecoveryState

typealias IMRuntimeRoutePublicationWatermark = IM4Data.IMRuntimeRoutePublicationWatermark

extension IMRuntimeRoutePublicationWatermark {
    init?(snapshot: IMRuntimeRouteSnapshot) {
        guard let environment = snapshot.environment,
              let revision = snapshot.publicationRevision,
              let publicationID = snapshot.publicationID,
              let profileFingerprint = snapshot.profileFingerprint,
              let status = snapshot.publicationStatus,
              let keysetRevision = snapshot.keysetRevision else { return nil }
        self.init(environment: environment, revision: revision, publicationID: publicationID,
                  profileFingerprint: profileFingerprint, status: status, keysetRevision: keysetRevision)
    }
}

typealias IMRuntimeRouteAtomicRecord = IM4Data.IMRuntimeRouteAtomicRecord

extension IMRuntimeRouteAtomicRecord {
	init(
		current: IMRuntimeRouteSnapshot?,
		previous: IMRuntimeRouteSnapshot?,
		recoveryByService: [String: IMRuntimeRouteRecoveryState],
        publicationWatermark: IMRuntimeRoutePublicationWatermark? = nil
	) {
        self.init(storedCurrent: current, previous: previous, recoveryByService: recoveryByService,
                  publicationWatermark: publicationWatermark ?? current.flatMap(IMRuntimeRoutePublicationWatermark.init))
    }
}

enum IMRuntimeRouteApplyResult: Equatable { case applied, revoked, idempotent, rollback, conflict, identity, persistence }

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
struct IMPublicBootstrapReceipt: Codable {
    let servingHost: String
    let revision: UInt64
    let configHash: String
    let downloadedDomains: [String]
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

final class IMRuntimeRouteStore: @unchecked Sendable {
    private static let processLock = NSLock()
    private let storage: IM4Data.RuntimeRouteRecordStorage
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    private static let processRouteV5 = routeV5Services(
        buildDefaults: Bundle.main.object(forInfoDictionaryKey: "WXTHTTPRouteV5Defaults") as? [String: String] ?? [:],
        arguments: ProcessInfo.processInfo.arguments
    )

    private static func routeV5Services(buildDefaults: [String: String], arguments: [String]) -> Set<String> {
        let services = ["public_bootstrap", "platform_api", "tenant_api", "im_api"]
        let prefix = "-WXT.RouteV5."
        let enabled = ["yes", "true", "1"]
        let disabled = ["no", "false", "0"]
        var result = Set(services.filter { enabled.contains(buildDefaults[$0]?.lowercased() ?? "") })
        for (key, rawValue) in zip(arguments, arguments.dropFirst()) where key.hasPrefix(prefix) {
            let service = String(key.dropFirst(prefix.count))
            guard services.contains(service) else { continue }
            let value = rawValue.lowercased()
            if enabled.contains(value) { result.insert(service) }
            if disabled.contains(value) { result.remove(service) }
        }
        return result
    }

    private let defaults: UserDefaults
    private let enabledRouteV5Services: Set<String>

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, enabledRouteV5Services: Self.processRouteV5)
    }

    private init(defaults: UserDefaults, enabledRouteV5Services: Set<String>) {
        self.defaults = defaults
        self.enabledRouteV5Services = enabledRouteV5Services
        storage = .init(defaults: defaults)
    }

#if DEBUG
    convenience init(defaults: UserDefaults, launchArgumentsForTesting: [String], buildDefaultsForTesting: [String: String] = [:]) {
        self.init(defaults: defaults, enabledRouteV5Services: Self.routeV5Services(
            buildDefaults: buildDefaultsForTesting, arguments: launchArgumentsForTesting
        ))
    }
#endif

    func routeV5Enabled(_ service: String) -> Bool {
        enabledRouteV5Services.contains(service)
    }

    func publicBootstrapReceipt(scope: IMRouteV5Scope) -> IMPublicBootstrapReceipt? {
        guard let bytes = defaults.data(forKey: scope.preferenceKey + ".bootstrap-authority") else { return nil }
        return try? JSONDecoder().decode(IMPublicBootstrapReceipt.self, from: bytes)
    }

    func savePublicBootstrapReceipt(_ receipt: IMPublicBootstrapReceipt, scope: IMRouteV5Scope) {
        guard let bytes = try? JSONEncoder().encode(receipt) else { return }
        defaults.set(bytes, forKey: scope.preferenceKey + ".bootstrap-authority")
    }

    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    private var outgoingConfirmationPermit = LocalMessageConfirmationPermit()

    func currentOutgoingConfirmationPermit() -> LocalMessageConfirmationPermit {
        Self.processLock.withLock { outgoingConfirmationPermit }
    }

    func invalidateOutgoingConfirmation() {
        Self.processLock.withLock { invalidateOutgoingConfirmationUnlocked() }
    }

    private func invalidateOutgoingConfirmationUnlocked() {
        outgoingConfirmationPermit.revoke()
        outgoingConfirmationPermit = LocalMessageConfirmationPermit()
    }

    func outgoingConfirmationCursors(scope: IMRouteV5Scope) -> [String: Int64] {
        let values = defaults.dictionary(forKey: scope.preferenceKey + ".outbox-before") ?? [:]
        return values.compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    func saveOutgoingConfirmationCursors(_ cursors: [String: Int64], scope: IMRouteV5Scope) {
        let key = scope.preferenceKey + ".outbox-before"
        if cursors.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(cursors, forKey: key)
        }
    }

    func outgoingConfirmationRotation(scope: IMRouteV5Scope) -> String {
        defaults.string(forKey: scope.preferenceKey + ".outbox-rotation") ?? ""
    }

    func saveOutgoingConfirmationRotation(_ position: String, scope: IMRouteV5Scope) {
        defaults.set(position, forKey: scope.preferenceKey + ".outbox-rotation")
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

    func lastSuccessfulRoute(_ scope: IMRouteV5Scope, in authorized: [URL]) -> URL? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let value = defaults.string(forKey: scope.preferenceKey) else { return nil }
        guard let match = authorized.first(where: { $0.absoluteString == value }) else {
            defaults.removeObject(forKey: scope.preferenceKey)
            return nil
        }
        return match
    }

    func recordSuccessfulRoute(_ endpoint: URL, in scope: IMRouteV5Scope) {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        if scope.service == IMRuntimeRouteService.imAPI.rawValue,
           defaults.string(forKey: scope.preferenceKey) != endpoint.absoluteString {
            invalidateOutgoingConfirmationUnlocked() // WDT_IOS1_HTTP_ROUTE_V5_20261113
        }
        defaults.set(endpoint.absoluteString, forKey: scope.preferenceKey)
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

    func record(appID: String, tenantID: String?) -> IMRuntimeRouteAtomicRecord {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return recordUnlocked(appID: appID, tenantID: tenantID)
    }

	func restore(appID: String, tenantID: String?) -> IMRuntimeRouteSnapshot? {
		Self.processLock.lock()
		defer { Self.processLock.unlock() }
		let normalized = normalizedRecordUnlocked(appID: appID, tenantID: tenantID)
		if normalized.changed,
		   !persist(normalized.record, appID: appID, tenantID: tenantID) {
			return nil
		}
		return normalized.record.current
	}

    private func recordUnlocked(appID: String, tenantID: String?) -> IMRuntimeRouteAtomicRecord {
        storage.record(appID: appID, tenantID: tenantID)
    }

	private func normalizedRecordUnlocked(
		appID: String,
		tenantID: String?
	) -> (record: IMRuntimeRouteAtomicRecord, changed: Bool) {
		let stored = recordUnlocked(appID: appID, tenantID: tenantID)
		if let watermark = stored.publicationWatermark,
           ["disabled", "tombstone"].contains(watermark.status) {
            var revoked = stored
            revoked.current = nil
            revoked.previous = nil
            revoked.recoveryByService = [:]
            return (revoked, revoked != stored)
        }
		if let current = stored.current?.validated(appID: appID, tenantID: tenantID) {
			var normalized = stored
			normalized.current = current
			return (normalized, normalized != stored)
		}

		// Only a generation that still satisfies the current integrity and route
		// authority contract may participate in the revision/hash fence. Promote a
		// valid previous generation when available; otherwise discard the invalid
		// generation before considering a fresh authoritative candidate.
		var normalized = stored
		normalized.current = stored.previous?.validated(appID: appID, tenantID: tenantID)
		normalized.previous = nil
		// Recovery counters are scoped to the rejected generation and cannot be
		// inherited by a promoted or newly authoritative route.
		normalized.recoveryByService = [:]
		return (normalized, normalized != stored)
	}

    @discardableResult func apply(_ candidate: IMRuntimeRouteSnapshot, appID: String, tenantID: String?) -> IMRuntimeRouteApplyResult {
        apply(candidate, appID: appID, tenantID: tenantID, restorePreviousOnPersistenceFailure: false)
    }

    // The process lock spans validation, publication and exact-byte restoration.
    // A concurrent authoritative revocation therefore cannot be overwritten by rollback.
    @discardableResult
    func applyAuthenticationCandidate(_ candidate: IMRuntimeRouteSnapshot, appID: String, tenantID: String?) -> IMRuntimeRouteApplyResult {
        apply(candidate, appID: appID, tenantID: tenantID, restorePreviousOnPersistenceFailure: true)
    }

    private func apply(_ candidate: IMRuntimeRouteSnapshot, appID: String, tenantID: String?, restorePreviousOnPersistenceFailure: Bool) -> IMRuntimeRouteApplyResult {
        guard let clean = candidate.validated(appID: appID, tenantID: tenantID) else { return .identity }
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let originalBytes = storage.originalBytes(appID: appID, tenantID: tenantID)
        func persistCandidate(_ record: IMRuntimeRouteAtomicRecord) -> Bool {
            guard !persist(record, appID: appID, tenantID: tenantID) else { return true }
            if restorePreviousOnPersistenceFailure {
                storage.restoreBytes(originalBytes, appID: appID, tenantID: tenantID)
            }
            // Persistence was not confirmed; never install the candidate in memory.
            return false
        }
		let normalized = normalizedRecordUnlocked(appID: appID, tenantID: tenantID)
		var value = normalized.record
		func resultAfterPersistingRepair(_ result: IMRuntimeRouteApplyResult) -> IMRuntimeRouteApplyResult {
			guard normalized.changed else { return result }
			guard !restorePreviousOnPersistenceFailure else { return result }
			return persistCandidate(value) ? result : .persistence
		}
        if let current = value.current {
			if clean.revision < current.revision { return resultAfterPersistingRepair(.rollback) }
			if clean.revision == current.revision {
				return resultAfterPersistingRepair(clean == current ? .idempotent : .conflict)
			}
        }
        if let candidateWatermark = IMRuntimeRoutePublicationWatermark(snapshot: clean) {
            if let currentWatermark = value.publicationWatermark {
                guard candidateWatermark.environment == currentWatermark.environment else {
                    return resultAfterPersistingRepair(.identity)
                }
                if candidateWatermark.revision < currentWatermark.revision {
                    return resultAfterPersistingRepair(.rollback)
                }
                if candidateWatermark.revision == currentWatermark.revision {
                    return resultAfterPersistingRepair(
                        candidateWatermark == currentWatermark && clean == value.current
                            ? .idempotent
                            : .conflict
                    )
                }
            }
            value.publicationWatermark = candidateWatermark
        } else if value.publicationWatermark != nil {
            return resultAfterPersistingRepair(.rollback)
        }
        value.previous = value.current
        value.current = clean
        // Recovery is an observation about one exact route generation. A newly
        // validated generation must start from its declared preferred tier;
        // otherwise a stale backup-first decision can override fresh authority.
        value.recoveryByService = [:]
        return persistCandidate(value) ? .applied : .persistence
    }

    @discardableResult
    func applyRevocation(
        environment: String,
        appID: String,
        tenantID: String?,
        revision: UInt64,
        publicationID: String,
        profileFingerprint: String,
        status: String,
        keysetRevision: UInt64
    ) -> IMRuntimeRouteApplyResult {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanEnvironment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPublicationID = publicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFingerprint = profileFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["disabled", "tombstone"].contains(normalizedStatus),
              !cleanEnvironment.isEmpty, !appID.isEmpty, revision > 0,
              !cleanPublicationID.isEmpty, !cleanFingerprint.isEmpty,
              keysetRevision > 0 else { return .identity }
        let candidate = IMRuntimeRoutePublicationWatermark(
            environment: cleanEnvironment,
            revision: revision,
            publicationID: cleanPublicationID,
            profileFingerprint: cleanFingerprint,
            status: normalizedStatus,
            keysetRevision: keysetRevision
        )
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        var value = recordUnlocked(appID: appID, tenantID: tenantID)
        if let current = value.publicationWatermark {
            guard current.environment == candidate.environment else { return .identity }
            if candidate.revision < current.revision { return .rollback }
            if candidate.revision == current.revision {
                return candidate == current ? .idempotent : .conflict
            }
        } else if let currentRevision = value.current?.revision, revision <= currentRevision {
            return revision < currentRevision ? .rollback : .conflict
        }
        value.publicationWatermark = candidate
        value.previous = nil
        value.current = nil
        value.recoveryByService = [:]
        return persist(value, appID: appID, tenantID: tenantID) ? .revoked : .persistence
    }

    @discardableResult func updateRecovery(_ state: IMRuntimeRouteRecoveryState, service: IMRuntimeRouteService,
                                            snapshot: IMRuntimeRouteSnapshot) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        var value = recordUnlocked(appID: snapshot.appID, tenantID: snapshot.tenantID)
        guard value.current?.revision == snapshot.revision else { return false }
        value.recoveryByService[service.rawValue] = state
        return persist(value, appID: snapshot.appID, tenantID: snapshot.tenantID)
    }

    @discardableResult func mutateRecovery(
        service: IMRuntimeRouteService,
        snapshot: IMRuntimeRouteSnapshot,
        _ mutation: (inout IMRuntimeRouteRecoveryState) -> Void
    ) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        var value = recordUnlocked(appID: snapshot.appID, tenantID: snapshot.tenantID)
        guard value.current?.revision == snapshot.revision else { return false }
        var state = value.recoveryByService[service.rawValue] ?? .init()
        mutation(&state)
        value.recoveryByService[service.rawValue] = state
        return persist(value, appID: snapshot.appID, tenantID: snapshot.tenantID)
    }

    private func persist(_ value: IMRuntimeRouteAtomicRecord, appID: String, tenantID: String?) -> Bool {
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if tenantID != nil {
            let previous = recordUnlocked(appID: appID, tenantID: tenantID)
            let service = IMRuntimeRouteService.imAPI.rawValue
            let wasRecovering = previous.recoveryByService[service]?.recovery == true
            let isRecovering = value.recoveryByService[service]?.recovery == true
            if previous.current != value.current || previous.publicationWatermark != value.publicationWatermark
                || wasRecovering != isRecovering {
                invalidateOutgoingConfirmationUnlocked()
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        return storage.persist(value, appID: appID, tenantID: tenantID)
    }

}
// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_END

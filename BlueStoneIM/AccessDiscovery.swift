import CryptoKit
import Foundation
import Network

enum IMRuntimeRouteService: String, Codable, CaseIterable, Sendable {
    case platformAPI = "platform_api"
    case tenantAPI = "tenant_api"
    case imAPI = "im_api"
    case imRealtime = "im_realtime"
}

struct IMRuntimeRouteEndpointSet: Codable, Equatable, Sendable {
    let preferred: [String]
    let backups: [String]
    let status: String
    let preferredSource: String
    let backupSource: String

    enum CodingKeys: String, CodingKey {
        case preferred
        case backups
        case status
        case preferredSource = "preferred_source"
        case backupSource = "backup_source"
    }

    init(
        preferred: [String],
        backups: [String],
        status: String = "ready",
        preferredSource: String = "",
        backupSource: String = ""
    ) {
        self.preferred = preferred
        self.backups = backups
        self.status = status
        self.preferredSource = preferredSource
        self.backupSource = backupSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferred = try container.decodeIfPresent([String].self, forKey: .preferred) ?? []
        backups = try container.decodeIfPresent([String].self, forKey: .backups) ?? []
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        preferredSource = try container.decodeIfPresent(String.self, forKey: .preferredSource) ?? ""
        backupSource = try container.decodeIfPresent(String.self, forKey: .backupSource) ?? ""
    }

    func validated(for service: IMRuntimeRouteService) -> IMRuntimeRouteEndpointSet? {
        guard !preferred.isEmpty, preferred.count + backups.count <= 16,
              status == "ready" else { return nil }
        let primary = preferred.compactMap { IMRuntimeRouteSnapshot.normalizedEndpoint($0, service: service) }
        let fallback = backups.compactMap { IMRuntimeRouteSnapshot.normalizedEndpoint($0, service: service) }
        guard primary.count == preferred.count, fallback.count == backups.count,
              Set(primary).count == primary.count,
              Set(fallback).count == fallback.count,
              Set(primary).isDisjoint(with: Set(fallback)) else { return nil }
        return .init(
            preferred: primary,
            backups: fallback,
            status: status,
            preferredSource: preferredSource,
            backupSource: backupSource
        )
    }

    var canonicalJSONObject: [String: Any] {
        [
            "backup_source": backupSource,
            "backups": backups,
            "preferred": preferred,
            "preferred_source": preferredSource,
            "status": status,
        ]
    }
}

struct IMRuntimeRoutePolicy: Codable, Equatable, Sendable {
	let contractVersion: Int
    let preferredFailureBudgetMS: UInt64
    let recoveryColdLaunchFailures: Int
    let preferredProbeSuccesses: Int
    let preferredProbeStableMS: UInt64
    let preferredProbeIntervalMS: UInt64
    let automaticExpiry: Bool
    let businessSigningRequired: Bool

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case preferredFailureBudgetMS = "preferred_failure_budget_ms"
        case recoveryColdLaunchFailures = "recovery_cold_start_failures"
        case preferredProbeSuccesses = "preferred_probe_successes"
        case preferredProbeStableMS = "preferred_probe_stable_ms"
        case preferredProbeIntervalMS = "preferred_probe_interval_ms"
        case automaticExpiry = "automatic_expiry"
        case businessSigningRequired = "business_signing_required"
    }

	init(contractVersion: Int = 2, preferredFailureBudgetMS: UInt64 = 5_000, recoveryColdLaunchFailures: Int = 3,
         preferredProbeSuccesses: Int = 2, preferredProbeStableMS: UInt64 = 30_000,
         preferredProbeIntervalMS: UInt64 = 30_000, automaticExpiry: Bool = false,
         businessSigningRequired: Bool = false) {
        self.contractVersion = contractVersion
        self.preferredFailureBudgetMS = preferredFailureBudgetMS
        self.recoveryColdLaunchFailures = recoveryColdLaunchFailures
        self.preferredProbeSuccesses = preferredProbeSuccesses
        self.preferredProbeStableMS = preferredProbeStableMS
        self.preferredProbeIntervalMS = preferredProbeIntervalMS
        self.automaticExpiry = automaticExpiry
        self.businessSigningRequired = businessSigningRequired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
		contractVersion = try container.decodeIfPresent(Int.self, forKey: .contractVersion) ?? 0
        preferredFailureBudgetMS = try container.decodeIfPresent(UInt64.self, forKey: .preferredFailureBudgetMS) ?? 5_000
        recoveryColdLaunchFailures = try container.decodeIfPresent(Int.self, forKey: .recoveryColdLaunchFailures) ?? 3
        preferredProbeSuccesses = try container.decodeIfPresent(Int.self, forKey: .preferredProbeSuccesses) ?? 2
        preferredProbeStableMS = try container.decodeIfPresent(UInt64.self, forKey: .preferredProbeStableMS) ?? 30_000
        preferredProbeIntervalMS = try container.decodeIfPresent(UInt64.self, forKey: .preferredProbeIntervalMS) ?? 30_000
        automaticExpiry = try container.decodeIfPresent(Bool.self, forKey: .automaticExpiry) ?? false
        businessSigningRequired = try container.decodeIfPresent(Bool.self, forKey: .businessSigningRequired) ?? false
    }

    var canonicalJSONObject: [String: Any] {
		[
			"contract_version": contractVersion,
			"automatic_expiry": automaticExpiry,
            "business_signing_required": businessSigningRequired,
            "preferred_failure_budget_ms": NSNumber(value: preferredFailureBudgetMS),
            "preferred_probe_interval_ms": NSNumber(value: preferredProbeIntervalMS),
            "preferred_probe_stable_ms": NSNumber(value: preferredProbeStableMS),
            "preferred_probe_successes": preferredProbeSuccesses,
            "recovery_cold_start_failures": recoveryColdLaunchFailures,
		]
    }
}

enum IMRuntimeRouteHashScope: String, Codable, Sendable {
    case appBootstrap = "app_bootstrap"
    case tenantEntry = "tenant_entry"
}

struct IMRuntimeRouteSnapshot: Codable, Equatable, Sendable {
    let contractVersion: Int
    let appID: String
    let tenantID: String?
    let revision: UInt64
    let source: String
    let status: String
    let configHash: String
    let services: [String: IMRuntimeRouteEndpointSet]
    let policy: IMRuntimeRoutePolicy
    let hashScope: IMRuntimeRouteHashScope
    let bootstrapHost: String?
    let preferredEndpoints: [String: [String]]
    var environment: String? = nil
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var publicationStatus: String? = nil
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"; case appID = "app_id"; case tenantID = "tenant_id"
        case revision; case source; case status; case configHash = "config_hash"; case services; case policy
        case hashScope = "hash_scope"; case bootstrapHost = "bootstrap_host"; case preferredEndpoints = "preferred_endpoints"
        case environment; case publicationID = "publication_id"; case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"; case lifetimeMode = "lifetime_mode"
        case publicationStatus = "publication_status"; case keysetRevision = "keyset_revision"
    }

    init(
        contractVersion: Int,
        appID: String,
        tenantID: String?,
        revision: UInt64,
        source: String,
        status: String,
        configHash: String,
        services: [String: IMRuntimeRouteEndpointSet],
        policy: IMRuntimeRoutePolicy,
        hashScope: IMRuntimeRouteHashScope = .tenantEntry,
        bootstrapHost: String? = nil,
        preferredEndpoints: [String: [String]] = [:],
        environment: String? = nil,
        publicationID: String? = nil,
        publicationRevision: UInt64? = nil,
        profileFingerprint: String? = nil,
        lifetimeMode: IMSessionLifetimeMode? = nil,
        publicationStatus: String? = nil,
        keysetRevision: UInt64? = nil
    ) {
        self.contractVersion = contractVersion
        self.appID = appID
        self.tenantID = tenantID
        self.revision = revision
        self.source = source
        self.status = status
        self.configHash = configHash
        self.services = services
        self.policy = policy
        self.hashScope = hashScope
        self.bootstrapHost = bootstrapHost
        self.preferredEndpoints = preferredEndpoints
        self.environment = environment
        self.publicationID = publicationID
        self.publicationRevision = publicationRevision
        self.profileFingerprint = profileFingerprint
        self.lifetimeMode = lifetimeMode
        self.publicationStatus = publicationStatus
        self.keysetRevision = keysetRevision
    }

    func validated(appID expectedAppID: String, tenantID expectedTenantID: String?) -> IMRuntimeRouteSnapshot? {
        let exactServices = Set(IMRuntimeRouteService.allCases.map(\.rawValue))
        let hasPublicationMetadata = publicationID != nil || publicationRevision != nil
            || profileFingerprint != nil || lifetimeMode != nil || publicationStatus != nil
            || environment != nil || keysetRevision != nil
        let normalizedFingerprint = profileFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
        let publicationMetadataIsValid = !hasPublicationMetadata || (
            environment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && publicationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && publicationRevision == revision
                && normalizedFingerprint == configHash
                && lifetimeMode == .untilRevoked
                && publicationStatus == "active"
                && (keysetRevision ?? 0) > 0
        )
        guard contractVersion == 2, revision > 0, revision <= 9_007_199_254_740_991,
              appID == expectedAppID, tenantID == expectedTenantID,
              !source.isEmpty,
              source == source.trimmingCharacters(in: .whitespacesAndNewlines),
              status == "ready",
              configHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              Set(services.keys) == exactServices,
		      policy.contractVersion == 2,
		      policy.preferredFailureBudgetMS == 5_000, policy.recoveryColdLaunchFailures == 3,
              policy.preferredProbeSuccesses == 2, policy.preferredProbeStableMS >= 30_000,
              policy.preferredProbeIntervalMS >= 30_000,
              !policy.automaticExpiry, !policy.businessSigningRequired,
              publicationMetadataIsValid else { return nil }
        var clean: [String: IMRuntimeRouteEndpointSet] = [:]
        for (key, route) in services {
            guard let service = IMRuntimeRouteService(rawValue: key), let validated = route.validated(for: service) else { return nil }
            clean[key] = validated
        }
		guard Self.hasFrozenRouteAuthorityTopology(clean, hashScope: hashScope) else { return nil }
		var cleanPreferredEndpoints: [String: [String]] = [:]
		if hashScope == .appBootstrap {
			guard Set(preferredEndpoints.keys) == exactServices else { return nil }
			for (key, endpoints) in preferredEndpoints {
				guard let service = IMRuntimeRouteService(rawValue: key), !endpoints.isEmpty else { return nil }
				let normalized = endpoints.compactMap { Self.normalizedEndpoint($0, service: service) }
				guard normalized.count == endpoints.count,
				      normalized == clean[key]?.preferred else { return nil }
				cleanPreferredEndpoints[key] = normalized
			}
		}
		let candidate = IMRuntimeRouteSnapshot(
            contractVersion: contractVersion,
            appID: appID,
            tenantID: tenantID,
            revision: revision,
            source: source,
            status: status,
            configHash: configHash,
            services: clean,
            policy: policy,
            hashScope: hashScope,
			bootstrapHost: bootstrapHost,
			preferredEndpoints: cleanPreferredEndpoints,
            environment: environment,
            publicationID: publicationID,
            publicationRevision: publicationRevision,
            profileFingerprint: profileFingerprint,
            lifetimeMode: lifetimeMode,
            publicationStatus: publicationStatus,
            keysetRevision: keysetRevision
        )
        guard candidate.recomputedConfigHash == configHash else { return nil }
        return candidate
    }

	private static func hasFrozenRouteAuthorityTopology(
		_ routes: [String: IMRuntimeRouteEndpointSet],
		hashScope: IMRuntimeRouteHashScope
	) -> Bool {
		for service in IMRuntimeRouteService.allCases {
			guard let route = routes[service.rawValue] else { return false }
			switch (hashScope, service) {
			case (_, .platformAPI):
				guard route.preferredSource == "app_preferred",
				      route.backupSource == "common_platform_backup" else { return false }
			case (.appBootstrap, _):
				guard route.preferredSource == "app_preferred",
				      route.backups.isEmpty,
				      route.backupSource == "common_platform_backup" else { return false }
			case (.tenantEntry, _):
				guard route.preferredSource == "tenant_deployment_authority",
				      route.backupSource == "tenant_deployment_backup" else { return false }
			}
		}
		return true
	}

    var recomputedConfigHash: String? {
        let payload: [String: Any]
        switch hashScope {
		case .appBootstrap:
			guard tenantID == nil,
			      let bootstrapHost else { return nil }
			payload = [
				"app_id": appID,
				"bootstrap_host": bootstrapHost,
				"contract_version": contractVersion,
				"preferred_endpoints": preferredEndpoints,
				"revision": NSNumber(value: revision),
				"routes": services.mapValues(\.canonicalJSONObject),
				"routing_policy": policy.canonicalJSONObject,
			]
        case .tenantEntry:
            guard let tenantID, !tenantID.isEmpty else { return nil }
            payload = [
                "app_id": appID,
                "contract_version": contractVersion,
                "revision": NSNumber(value: revision),
                "routes": services.mapValues(\.canonicalJSONObject),
                "routing_policy": policy.canonicalJSONObject,
                "tenant_id": tenantID,
            ]
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

	static func normalizedEndpoint(
		_ raw: String,
		service: IMRuntimeRouteService,
		allowDevelopmentEndpoints: Bool = Self.allowsDevelopmentRouteEndpoints
	) -> String? {
		let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !candidate.isEmpty, candidate.utf8.count <= 2_048,
		      var components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased(),
		      let host = components.host?.lowercased(), components.user == nil, components.password == nil,
		      components.query == nil, components.fragment == nil else { return nil }
		let secureScheme = service == .imRealtime ? "wss" : "https"
		let developmentScheme = service == .imRealtime ? "ws" : "http"
		if scheme == secureScheme {
			guard components.port == nil || components.port == 443,
			      isProductionRouteFQDN(host, allowReservedTestDomains: allowDevelopmentEndpoints) else { return nil }
		} else {
			guard allowDevelopmentEndpoints,
			      scheme == developmentScheme,
			      isLoopbackDevelopmentHost(host) else { return nil }
		}
		if service != .imRealtime {
			guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else { return nil }
		}
		components.scheme = scheme; components.host = host
		guard let normalized = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
		      normalized.utf8.count <= 2_048 else { return nil }
		return normalized
	}

	private static var allowsDevelopmentRouteEndpoints: Bool {
		#if DEBUG
		IMRuntimeBuildPolicy.allowsRuntimeAPIBaseOverride(debugBuild: true)
		#else
		false
		#endif
	}

	private static func isLoopbackDevelopmentHost(_ host: String) -> Bool {
		host == "localhost" || IPv4Address(host)?.isLoopback == true || IPv6Address(host)?.isLoopback == true
	}

	private static func isProductionRouteFQDN(_ host: String, allowReservedTestDomains: Bool) -> Bool {
		guard host == host.trimmingCharacters(in: .whitespacesAndNewlines),
		      !host.hasSuffix("."), host.utf8.count <= 253,
		      IPv4Address(host) == nil, IPv6Address(host) == nil else { return false }
		let labels = host.split(separator: ".", omittingEmptySubsequences: false)
		guard labels.count >= 2 else { return false }
		for label in labels {
			guard !label.isEmpty, label.utf8.count <= 63,
			      label.first?.isASCII == true, label.last?.isASCII == true,
			      label.first?.isLetter == true || label.first?.isNumber == true,
			      label.last?.isLetter == true || label.last?.isNumber == true,
			      label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
		}
		let normalized = host.lowercased()
		guard !["placeholder", "unconfigured", "changeme"].contains(where: normalized.contains) else {
			return false
		}
		if !allowReservedTestDomains {
			let reservedExact = Set(["example.com", "example.net", "example.org", "localhost"])
			let reservedSuffixes = [
				".example", ".test", ".invalid", ".localhost", ".local",
				".example.com", ".example.net", ".example.org",
			]
			guard !reservedExact.contains(normalized),
			      !reservedSuffixes.contains(where: normalized.hasSuffix) else { return false }
		}
		return true
	}
}

extension RemoteAppBootstrap {
    var runtimeRouteSnapshot: IMRuntimeRouteSnapshot {
        .init(
            contractVersion: contractVersion,
            appID: appID,
            tenantID: nil,
            revision: routeRevision,
            source: routeSource,
            status: routeStatus,
            configHash: configHash,
            services: routes,
            policy: routingPolicy,
            hashScope: .appBootstrap,
            bootstrapHost: bootstrapHost,
            preferredEndpoints: preferredEndpoints,
            environment: environment,
            publicationID: publicationID,
            publicationRevision: publicationRevision,
            profileFingerprint: profileFingerprint,
            lifetimeMode: lifetimeMode,
            publicationStatus: publicationStatus,
            keysetRevision: keysetRevision
        )
    }

	var hasValidV2ConfigHash: Bool {
		runtimeRouteSnapshot.recomputedConfigHash == configHash
	}
}

struct IMRuntimeRouteRecoveryState: Codable, Equatable, Sendable {
    var consecutiveQualifiedColdLaunchFailures = 0
    var recovery = false
    var consecutiveStablePreferredProbes = 0
    var lastStableProbeAtMS: UInt64?
}

struct IMRuntimeRoutePublicationWatermark: Codable, Equatable, Sendable {
    let environment: String
    let revision: UInt64
    let publicationID: String
    let profileFingerprint: String
    let status: String
    let keysetRevision: UInt64

    init?(snapshot: IMRuntimeRouteSnapshot) {
        guard let environment = snapshot.environment,
              let revision = snapshot.publicationRevision,
              let publicationID = snapshot.publicationID,
              let profileFingerprint = snapshot.profileFingerprint,
              let status = snapshot.publicationStatus,
              let keysetRevision = snapshot.keysetRevision else { return nil }
        self.environment = environment
        self.revision = revision
        self.publicationID = publicationID
        self.profileFingerprint = profileFingerprint
        self.status = status
        self.keysetRevision = keysetRevision
    }

    init(
        environment: String,
        revision: UInt64,
        publicationID: String,
        profileFingerprint: String,
        status: String,
        keysetRevision: UInt64
    ) {
        self.environment = environment
        self.revision = revision
        self.publicationID = publicationID
        self.profileFingerprint = profileFingerprint
        self.status = status
        self.keysetRevision = keysetRevision
    }
}

struct IMRuntimeRouteAtomicRecord: Codable, Equatable, Sendable {
    var current: IMRuntimeRouteSnapshot?
    var previous: IMRuntimeRouteSnapshot?
    var recoveryByService: [String: IMRuntimeRouteRecoveryState]
    var publicationWatermark: IMRuntimeRoutePublicationWatermark?

	private enum CodingKeys: String, CodingKey { case current, previous, recoveryByService, publicationWatermark }

	init(
		current: IMRuntimeRouteSnapshot?,
		previous: IMRuntimeRouteSnapshot?,
		recoveryByService: [String: IMRuntimeRouteRecoveryState],
        publicationWatermark: IMRuntimeRoutePublicationWatermark? = nil
	) {
		self.current = current
		self.previous = previous
		self.recoveryByService = recoveryByService
        self.publicationWatermark = publicationWatermark ?? current.flatMap(IMRuntimeRoutePublicationWatermark.init)
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// Decode both generations independently so a malformed current snapshot does
		// not make a still-valid previous snapshot unreadable.
		current = try? container.decode(IMRuntimeRouteSnapshot.self, forKey: .current)
		previous = try? container.decode(IMRuntimeRouteSnapshot.self, forKey: .previous)
		recoveryByService = (try? container.decode([String: IMRuntimeRouteRecoveryState].self, forKey: .recoveryByService)) ?? [:]
        publicationWatermark = try? container.decode(IMRuntimeRoutePublicationWatermark.self, forKey: .publicationWatermark)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encodeIfPresent(current, forKey: .current)
		try container.encodeIfPresent(previous, forKey: .previous)
		try container.encode(recoveryByService, forKey: .recoveryByService)
        try container.encodeIfPresent(publicationWatermark, forKey: .publicationWatermark)
	}
}

enum IMRuntimeRouteApplyResult: Equatable { case applied, revoked, idempotent, rollback, conflict, identity, persistence }

final class IMRuntimeRouteStore: @unchecked Sendable {
    private static let processLock = NSLock()
    private let defaults: UserDefaults
    private let prefix = "wxt.runtime.routes.v2."
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

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
        guard let data = defaults.data(forKey: key(appID: appID, tenantID: tenantID)),
              let value = try? JSONDecoder().decode(IMRuntimeRouteAtomicRecord.self, from: data) else {
            return .init(current: nil, previous: nil, recoveryByService: [:])
        }
        return value
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

        let storageKey = key(appID: appID, tenantID: tenantID)
        let originalBytes = defaults.data(forKey: storageKey)
        func persistCandidate(_ record: IMRuntimeRouteAtomicRecord) -> Bool {
            guard !persist(record, appID: appID, tenantID: tenantID) else { return true }
            if restorePreviousOnPersistenceFailure {
                if let originalBytes { defaults.set(originalBytes, forKey: storageKey) }
                else { defaults.removeObject(forKey: storageKey) }
                _ = defaults.synchronize()
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
        guard let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: key(appID: appID, tenantID: tenantID)); return defaults.synchronize()
    }
    private func key(appID: String, tenantID: String?) -> String {
        let digest = SHA256.hash(data: Data("\(appID)\u{0}\(tenantID ?? "")".utf8))
        return prefix + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

enum IMRuntimeRouteFailureDecision: Equatable { case qualifiedNetwork, noFailover, failClosed }
enum IMRuntimeRouteFailure: Equatable {
    case dns, connect, timeout, reset, websocketHeartbeat, http(Int)
    case offline, captivePortal, authentication, business, license, cancelled, backgrounded, websocketAuth, websocketPreAckBusiness, crash
    case tlsCertificate, hostMismatch, appIDMismatch, tenantMismatch, configHashMismatch, revisionRejected, contractMismatch
    var decision: IMRuntimeRouteFailureDecision {
        switch self {
        case .dns, .connect, .timeout, .reset, .websocketHeartbeat: return .qualifiedNetwork
        case let .http(status): return [502, 503, 504].contains(status) ? .qualifiedNetwork : .noFailover
        case .tlsCertificate, .hostMismatch, .appIDMismatch, .tenantMismatch,
             .configHashMismatch, .revisionRejected, .contractMismatch: return .failClosed
        default: return .noFailover
        }
    }
}

enum IMAppBootstrapFailoverPolicy {
	static let maximumOriginCount = 9
	static let perOriginFailureBudgetMS: UInt64 = 3_000
	static let maximumTotalFailureBudgetMS = UInt64(maximumOriginCount) * perOriginFailureBudgetMS

	static func decision(for failure: IMRuntimeRouteFailure) -> IMRuntimeRouteFailureDecision {
		switch failure {
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		case .dns, .connect, .timeout, .reset, .tlsCertificate,
		     .hostMismatch, .appIDMismatch, .configHashMismatch, .contractMismatch:
			return .qualifiedNetwork
		case .revisionRejected:
			return .failClosed
		case .http:
			return .qualifiedNetwork
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		default:
			// Only non-authoritative candidate failures may move to the next
			// pinned Bootstrap origin. Business terminal states still stop here.
			return .noFailover
		}
	}

	static func elapsedMS(startedAtMS: UInt64, nowMS: UInt64) -> UInt64 {
		nowMS >= startedAtMS ? nowMS - startedAtMS : 0
	}

	static func totalFailureBudgetMS(originCount: Int) -> UInt64 {
		guard originCount > 0 else { return 0 }
		return min(UInt64(originCount) * perOriginFailureBudgetMS, maximumTotalFailureBudgetMS)
	}

	static func remainingBudgetMS(
		startedAtMS: UInt64,
		nowMS: UInt64,
		budgetMS: UInt64
	) -> UInt64 {
		let elapsed = elapsedMS(startedAtMS: startedAtMS, nowMS: nowMS)
		return elapsed >= budgetMS ? 0 : budgetMS - elapsed
	}

	static func deadlineMS(startedAtMS: UInt64, budgetMS: UInt64) -> UInt64 {
		startedAtMS > UInt64.max - budgetMS ? UInt64.max : startedAtMS + budgetMS
	}
}

struct IMRuntimeTenantBinaryRouteContext: Equatable, Sendable {
	let appID: String
	let tenantID: String
	let revision: UInt64
	let activeBases: [URL]
	let standbyBases: [URL]
	let recovery: Bool
}

struct IMRuntimeTenantBinaryFetchResult: Sendable {
	let data: Data
	let statusCode: Int
	let resolvedURL: URL
}

enum IMRuntimeTenantBinaryFetchError: Error, Equatable {
	case invalidRelativePath
	case routeUnavailable
	case invalidResponse
	case httpStatus(Int)
}

enum IMRuntimeRouteTier: Equatable { case preferred, backup, failClosed }
struct IMRuntimeRouteRequestWindow: Equatable {
    let firstQualifiedFailureAtMS: UInt64?
    let tier: IMRuntimeRouteTier
    init(firstQualifiedFailureAtMS: UInt64? = nil, tier: IMRuntimeRouteTier = .preferred) {
        self.firstQualifiedFailureAtMS = firstQualifiedFailureAtMS; self.tier = tier
    }
    func recording(_ failure: IMRuntimeRouteFailure, nowMS: UInt64) -> IMRuntimeRouteRequestWindow {
        switch failure.decision {
        case .failClosed: return .init(firstQualifiedFailureAtMS: firstQualifiedFailureAtMS, tier: .failClosed)
        case .noFailover: return self
        case .qualifiedNetwork:
            let first = firstQualifiedFailureAtMS ?? nowMS
            return .init(firstQualifiedFailureAtMS: first, tier: nowMS - first >= 5_000 ? .backup : tier)
        }
    }
}

struct IMRuntimeColdLaunchAttempt: Sendable {
    let processWasNotRunning: Bool; let foregroundLaunch: Bool; let networkReachable: Bool
    let backgroundedOrCancelled: Bool; let qualifiedFailureDurationMS: UInt64
    var qualifies: Bool { processWasNotRunning && foregroundLaunch && networkReachable && !backgroundedOrCancelled && qualifiedFailureDurationMS >= 5_000 }
}

@MainActor
final class IMRuntimeColdLaunchLifecycle {
	static let shared = IMRuntimeColdLaunchLifecycle()

	private let monitor: NWPathMonitor?
	private let monitorQueue = DispatchQueue(label: "wenxintong.runtime-cold-launch.network")
	private(set) var processLaunchBegan = false
	private(set) var foregroundLaunch = false
	private(set) var networkReachable = false
	private(set) var backgroundedOrCancelled = false
	private(set) var finished = false

	init(monitorsNetwork: Bool = true) {
		monitor = monitorsNetwork ? NWPathMonitor() : nil
	}

	func beginProcessLaunch() {
		guard !processLaunchBegan else { return }
		processLaunchBegan = true
		monitor?.pathUpdateHandler = { [weak self] path in
			Task { @MainActor [weak self] in
				self?.setNetworkReachable(path.status == .satisfied)
			}
		}
		monitor?.start(queue: monitorQueue)
	}

	func sceneDidBecomeActive() {
		guard processLaunchBegan, !finished, !backgroundedOrCancelled else { return }
		foregroundLaunch = true
	}

	func sceneDidBecomeInactive() {
		guard processLaunchBegan, !finished else { return }
		foregroundLaunch = false
	}

	func sceneDidEnterBackground() {
		guard processLaunchBegan, !finished else { return }
		foregroundLaunch = false
		backgroundedOrCancelled = true
	}

	func setNetworkReachable(_ reachable: Bool) {
		networkReachable = reachable
	}

	func finish() {
		guard processLaunchBegan, !finished else { return }
		finished = true
		monitor?.cancel()
	}

	var isTracking: Bool { processLaunchBegan && !finished }

	func attempt(qualifiedFailureDurationMS: UInt64, cancelled: Bool = false) -> IMRuntimeColdLaunchAttempt {
		.init(
			processWasNotRunning: processLaunchBegan,
			foregroundLaunch: foregroundLaunch,
			networkReachable: networkReachable,
			backgroundedOrCancelled: backgroundedOrCancelled || cancelled,
			qualifiedFailureDurationMS: qualifiedFailureDurationMS
		)
	}
}

enum IMRuntimePreferredProbeKind: Equatable { case http, realtime }

final class IMRuntimeRouteSelector: @unchecked Sendable {
    private let store: IMRuntimeRouteStore
    init(store: IMRuntimeRouteStore) { self.store = store }
    func endpoints(_ snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) -> [String] {
        guard let route = snapshot.services[service.rawValue] else { return [] }
        return recovery(snapshot, service: service).recovery ? route.backups + route.preferred : route.preferred + route.backups
    }
    func endpointTiers(_ snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) -> (preferred: [String], backups: [String]) {
        guard let route = snapshot.services[service.rawValue] else { return ([], []) }
        return recovery(snapshot, service: service).recovery
            ? (route.backups, route.preferred)
            : (route.preferred, route.backups)
    }
    func recordColdLaunch(_ attempt: IMRuntimeColdLaunchAttempt, snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) {
        store.mutateRecovery(service: service, snapshot: snapshot) { state in
			guard attempt.qualifies else {
				state.consecutiveQualifiedColdLaunchFailures = 0
				return
			}
			state.consecutiveQualifiedColdLaunchFailures += 1
			state.recovery = state.recovery || state.consecutiveQualifiedColdLaunchFailures >= snapshot.policy.recoveryColdLaunchFailures
			state.consecutiveStablePreferredProbes = 0; state.lastStableProbeAtMS = nil
        }
    }
	func recordColdLaunchSuccess(snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) {
		store.mutateRecovery(service: service, snapshot: snapshot) { state in
			state.consecutiveQualifiedColdLaunchFailures = 0
		}
	}
    func recordPreferredProbe(snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, kind: IMRuntimePreferredProbeKind,
                              succeeded: Bool, stableMS: UInt64, nowMS: UInt64, connectAcknowledged: Bool = false) {
        store.mutateRecovery(service: service, snapshot: snapshot) { state in
            guard state.recovery else { return }
            guard succeeded, stableMS >= snapshot.policy.preferredProbeStableMS, kind != .realtime || connectAcknowledged else {
                state.consecutiveStablePreferredProbes = 0; state.lastStableProbeAtMS = nil
                return
            }
            if kind == .realtime { state = .init(); return }
            guard state.lastStableProbeAtMS == nil || nowMS - state.lastStableProbeAtMS! >= snapshot.policy.preferredProbeIntervalMS else { return }
            state.consecutiveStablePreferredProbes += 1; state.lastStableProbeAtMS = nowMS
            if state.consecutiveStablePreferredProbes >= snapshot.policy.preferredProbeSuccesses { state = .init() }
        }
    }
    func recovery(_ snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) -> IMRuntimeRouteRecoveryState {
        store.record(appID: snapshot.appID, tenantID: snapshot.tenantID).recoveryByService[service.rawValue] ?? .init()
    }
}

final class IMRuntimeWebSocketContinuity: @unchecked Sendable {
	static let shared = IMRuntimeWebSocketContinuity()
    private let lock = NSLock()
	private var owner: String?; private var delivered = Set<String>(); private var deliveryOrder: [String] = []
    func acquire(_ candidate: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if owner != nil && owner != candidate { return false }; owner = candidate; return true
    }
	func release(_ candidate: String) {
		lock.lock(); defer { lock.unlock() }
		guard owner == candidate else { return }
		owner = nil
		delivered.removeAll(keepingCapacity: false)
		deliveryOrder.removeAll(keepingCapacity: false)
	}
    func accept(messageID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard delivered.insert(messageID).inserted else { return false }
        deliveryOrder.append(messageID)
        if deliveryOrder.count > 4_096 {
            let overflow = deliveryOrder.count - 4_096
            let removed = deliveryOrder.prefix(overflow)
            deliveryOrder.removeFirst(overflow)
            delivered.subtract(removed)
        }
        return true
    }
}

@MainActor
protocol AccessDiscoveryFetching: AnyObject, Sendable {
    func accessDiscoveryEndpoints(context: IMAPIContext) async throws -> RemoteAccessDiscoveryResponse
    func accessDiscoveryEndpoints(
        context: IMAPIContext,
        endpointURL: URL?,
        timeoutInterval: TimeInterval
    ) async throws -> RemoteAccessDiscoveryResponse
}

extension AccessDiscoveryFetching {
    func accessDiscoveryEndpoints(
        context: IMAPIContext,
        endpointURL: URL?,
        timeoutInterval: TimeInterval
    ) async throws -> RemoteAccessDiscoveryResponse {
        guard endpointURL == nil else {
            throw AccessDiscoveryTrustError.endpointInvalid
        }
        return try await accessDiscoveryEndpoints(context: context)
    }
}

protocol AccessDiscoveryManaging: AnyObject, Sendable {
    @discardableResult
    func refresh(context: IMAPIContext, fetcher: AccessDiscoveryFetching, force: Bool) async -> AccessDiscoveryRefreshOutcome
    func realtimeConnectionRequest(
        context: IMAPIContext,
        token: String,
        fallbackURL: URL?,
        quicConfiguration: RealtimeQUICConfiguration
    ) -> RealtimeConnectionRequest?
    func markActiveRealtimeEndpointFailed()
    func markActiveRealtimeEndpointConnected()
    func markActiveRealtimeEndpointSucceeded()
}

enum AccessDiscoveryRefreshOutcome: Equatable {
    case memory(configVersion: String)
    case network(configVersion: String)
    case cache(configVersion: String)
    case unavailable
}

func accessDiscoveryTrustedTransitionAllowed(
    previous: RemoteAccessDiscoveryResponse?,
    candidate: RemoteAccessDiscoveryResponse
) -> Bool {
    guard let candidateTrust = candidate.trust else { return false }
    guard let previousTrust = previous?.trust else { return true }
    if candidate.contractVersion == 2 {
        guard let candidateRevision = candidate.publicationRevision,
              let candidatePublicationID = candidate.publicationID,
              let candidateFingerprint = candidate.profileFingerprint,
              let candidateStatus = candidate.publicationStatus,
              let candidateKeysetRevision = candidate.keysetRevision else {
            return false
        }
        if previous?.contractVersion == 2 {
            guard let previousRevision = previous?.publicationRevision,
                  let previousPublicationID = previous?.publicationID,
                  let previousFingerprint = previous?.profileFingerprint,
                  let previousStatus = previous?.publicationStatus,
                  let previousKeysetRevision = previous?.keysetRevision,
                  candidateRevision >= previousRevision,
                  candidateKeysetRevision >= previousKeysetRevision,
                  candidateTrust.recoveryGeneration >= previousTrust.recoveryGeneration,
                  candidateTrust.fencingGeneration >= previousTrust.fencingGeneration else {
                return false
            }
            if candidateTrust.recoveryGeneration == previousTrust.recoveryGeneration,
               candidateTrust.keyStateHash != previousTrust.keyStateHash {
                return false
            }
            if candidateTrust.recoveryGeneration > previousTrust.recoveryGeneration,
               candidateTrust.keyStateHash == previousTrust.keyStateHash {
                return false
            }
            if candidateRevision == previousRevision {
                return candidatePublicationID == previousPublicationID
                    && candidateFingerprint == previousFingerprint
                    && candidateStatus == previousStatus
                    && candidateTrust.contentHash == previousTrust.contentHash
                    && candidateKeysetRevision == previousKeysetRevision
            }
            return true
        }
        return true
    }
    if previous?.contractVersion == 2 { return false }
    if candidateTrust.recoveryGeneration < previousTrust.recoveryGeneration ||
        candidateTrust.fencingGeneration < previousTrust.fencingGeneration ||
        candidateTrust.generation < previousTrust.generation {
        return false
    }
    if candidateTrust.recoveryGeneration == previousTrust.recoveryGeneration,
       candidateTrust.keyStateHash != previousTrust.keyStateHash {
        return false
    }
    if candidateTrust.recoveryGeneration > previousTrust.recoveryGeneration,
       candidateTrust.keyStateHash == previousTrust.keyStateHash {
        return false
    }
    if candidateTrust.fencingGeneration > previousTrust.fencingGeneration {
        return true
    }
    if candidateTrust.generation == previousTrust.generation,
       (candidateTrust.contentHash != previousTrust.contentHash ||
        candidate.configVersion != previous?.configVersion) {
        return false
    }
    if candidate.configVersion == previous?.configVersion,
       candidateTrust.contentHash != previousTrust.contentHash {
        return false
    }
    return true
}

struct RemoteAccessDiscoveryResponse: Codable, Equatable, Sendable {
    let contractVersion: Int
    let configVersion: String
    let serverTime: Int
    let ttlSeconds: Int
    let refreshJitterSeconds: Int
    let source: String
    let stale: Bool
    let degraded: Bool
    let endpoints: [RemoteAccessDiscoveryEndpoint]
    let discoveryFallbacks: [RemoteAccessDiscoveryEndpoint]
    let signatureAlg: String?
    let signature: String?
    let trust: AccessDiscoveryTrustProof?
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var publicationStatus: String? = nil
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion = "contract_version"
        case configVersion = "config_version"
        case serverTime = "server_time"
        case ttlSeconds = "ttl_seconds"
        case refreshJitterSeconds = "refresh_jitter_seconds"
        case source
        case stale
        case degraded
        case endpoints
        case discoveryFallbacks = "discovery_fallbacks"
        case signatureAlg = "signature_alg"
        case signature
        case trust
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case publicationStatus = "status"
        case keysetRevision = "keyset_revision"
    }

    init(
        contractVersion: Int,
        configVersion: String,
        serverTime: Int,
        ttlSeconds: Int,
        refreshJitterSeconds: Int,
        source: String,
        stale: Bool,
        degraded: Bool,
        endpoints: [RemoteAccessDiscoveryEndpoint],
        discoveryFallbacks: [RemoteAccessDiscoveryEndpoint],
        signatureAlg: String?,
        signature: String?,
        trust: AccessDiscoveryTrustProof? = nil,
        publicationID: String? = nil,
        publicationRevision: UInt64? = nil,
        profileFingerprint: String? = nil,
        lifetimeMode: IMSessionLifetimeMode? = nil,
        publicationStatus: String? = nil,
        keysetRevision: UInt64? = nil
    ) {
        self.contractVersion = contractVersion
        self.configVersion = configVersion
        self.serverTime = serverTime
        self.ttlSeconds = ttlSeconds
        self.refreshJitterSeconds = refreshJitterSeconds
        self.source = source
        self.stale = stale
        self.degraded = degraded
        self.endpoints = endpoints
        self.discoveryFallbacks = discoveryFallbacks
        self.signatureAlg = signatureAlg
        self.signature = signature
        self.trust = trust
        self.publicationID = publicationID
        self.publicationRevision = publicationRevision
        self.profileFingerprint = profileFingerprint
        self.lifetimeMode = lifetimeMode
        self.publicationStatus = publicationStatus
        self.keysetRevision = keysetRevision
    }
}

struct AccessDiscoveryTrustProof: Codable, Equatable, Sendable {
    let payloadB64: String
    let keyID: String
    let signatureAlg: String
    let signature: String
    let keyState: SignedAccessDiscoveryKeyState
    let generation: UInt64
    let fencingGeneration: UInt64
    let recoveryGeneration: UInt64
    let keyStateHash: String
    let keyStateExpiresAt: String
    let contentHash: String
    let issuedAt: String
    let expiresAt: String
    let environment: String
    let productID: String
    let appID: String
    let channel: String
    let clientIdentifier: String
    let tenantID: String
    let platform: String
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var publicationStatus: String? = nil
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case payloadB64 = "payload_b64"
        case keyID = "key_id"
        case signatureAlg = "signature_alg"
        case signature
        case keyState = "key_state"
        case generation
        case fencingGeneration = "fencing_generation"
        case recoveryGeneration = "recovery_generation"
        case keyStateHash = "key_state_hash"
        case keyStateExpiresAt = "key_state_expires_at"
        case contentHash = "content_hash"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case environment
        case productID = "product_id"
        case channel
        case clientIdentifier = "client_identifier"
        case tenantID = "tenant_id"
        case appID = "app_id"
        case platform
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case publicationStatus = "status"
        case keysetRevision = "keyset_revision"
    }
}

struct SignedAccessDiscoveryEnvelope: Codable, Sendable {
    let payloadB64: String
    let keyID: String
    let signatureAlg: String
    let signature: String
    let keyState: SignedAccessDiscoveryKeyState

    enum CodingKeys: String, CodingKey, CaseIterable {
        case payloadB64 = "payload_b64"
        case keyID = "key_id"
        case signatureAlg = "signature_alg"
        case signature
        case keyState = "key_state"
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AccessDiscoveryDynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadB64 = try container.decode(String.self, forKey: .payloadB64)
        keyID = try container.decode(String.self, forKey: .keyID)
        signatureAlg = try container.decode(String.self, forKey: .signatureAlg)
        signature = try container.decode(String.self, forKey: .signature)
        keyState = try container.decode(SignedAccessDiscoveryKeyState.self, forKey: .keyState)
    }
}

struct SignedAccessDiscoveryKeyState: Codable, Equatable, Sendable {
    let payloadB64: String
    let rootKeyID: String
    let signatureAlg: String
    let signature: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case payloadB64 = "payload_b64"
        case rootKeyID = "root_key_id"
        case signatureAlg = "signature_alg"
        case signature
    }

    init(payloadB64: String, rootKeyID: String, signatureAlg: String, signature: String) {
        self.payloadB64 = payloadB64
        self.rootKeyID = rootKeyID
        self.signatureAlg = signatureAlg
        self.signature = signature
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AccessDiscoveryDynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadB64 = try container.decode(String.self, forKey: .payloadB64)
        rootKeyID = try container.decode(String.self, forKey: .rootKeyID)
        signatureAlg = try container.decode(String.self, forKey: .signatureAlg)
        signature = try container.decode(String.self, forKey: .signature)
    }
}

struct AccessDiscoveryKeyAuthorization: Codable, Equatable, Sendable {
    let keyID: String
    let algorithm: String
    let role: String
    let status: String
    let environment: String
    let productID: String
    let appID: String
    let platform: String
    let channel: String
    let clientIdentifier: String
    let notBefore: String
    let notAfter: String
    let minFencingGeneration: UInt64
    let maxFencingGeneration: UInt64?

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case algorithm, role, status, environment
        case productID = "product_id"
        case appID = "app_id"
        case platform, channel
        case clientIdentifier = "client_identifier"
        case notBefore = "not_before"
        case notAfter = "not_after"
        case minFencingGeneration = "min_fencing_generation"
        case maxFencingGeneration = "max_fencing_generation"
    }
}

struct AccessDiscoveryKeyStatePayload: Codable, Equatable, Sendable {
    let purpose: String
    let contractVersion: Int
    let recoveryGeneration: UInt64
    let currentFencingGeneration: UInt64
    let issuedAt: String
    let expiresAt: String
    let keys: [AccessDiscoveryKeyAuthorization]
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case purpose, keys
        case contractVersion = "contract_version"
        case recoveryGeneration = "recovery_generation"
        case currentFencingGeneration = "current_fencing_generation"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case keysetRevision = "keyset_revision"
    }
}

private struct AccessDiscoveryDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

struct SignedAccessDiscoveryPayload: Codable, Equatable, Sendable {
    let purpose: String
    let contractVersion: Int
    let canonicalizationVersion: Int
    let tenantID: String
    let appID: String
    let platform: String
    let environment: String
    let productID: String
    let channel: String
    let clientIdentifier: String
    let fencingGeneration: UInt64
    let generation: UInt64
    let configVersion: String
    let issuedAt: String
    let expiresAt: String
    let serverTime: Int
    let ttlSeconds: Int
    let refreshJitterSeconds: Int
    let source: String
    let stale: Bool
    let degraded: Bool
    let contentHash: String
    let endpoints: [RemoteAccessDiscoveryEndpoint]
    let discoveryFallbacks: [RemoteAccessDiscoveryEndpoint]
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var status: String? = nil
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case purpose
        case contractVersion = "contract_version"
        case canonicalizationVersion = "canonicalization_version"
        case tenantID = "tenant_id"
        case appID = "app_id"
        case platform
        case environment
        case productID = "product_id"
        case channel
        case clientIdentifier = "client_identifier"
        case fencingGeneration = "fencing_generation"
        case generation
        case configVersion = "config_version"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case serverTime = "server_time"
        case ttlSeconds = "ttl_seconds"
        case refreshJitterSeconds = "refresh_jitter_seconds"
        case source
        case stale
        case degraded
        case contentHash = "content_hash"
        case endpoints
        case discoveryFallbacks = "discovery_fallbacks"
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case status
        case keysetRevision = "keyset_revision"
    }
}

enum AccessDiscoveryTrustError: String, Error {
    case configurationBlocked = "access_discovery_trust_configuration_blocked"
    case invalidEnvelope = "access_discovery_signature_invalid_envelope"
    case unknownKey = "access_discovery_signature_unknown_key"
    case signatureInvalid = "access_discovery_signature_invalid"
    case audienceMismatch = "access_discovery_signature_audience_mismatch"
    case expired = "access_discovery_signature_expired"
    case endpointInvalid = "access_discovery_signed_endpoint_invalid"
    case rollback = "access_discovery_signature_rollback"
    case conflict = "access_discovery_signature_conflict"
}

struct AccessDiscoveryTrustConfiguration: Sendable {
    static let signingDomain = Data("wenxintong.tenant-access-discovery.v1\u{0}".utf8)
    static let keyStateSigningDomain = Data("wenxintong.tenant-access-discovery-key-state.v1\u{0}".utf8)
    let required: Bool
    let environment: String
    let productID: String
    let appID: String
    let channel: String
    let clientIdentifier: String
    let publicKeys: [String: Data]
    let recoveryRootKeyID: String
    let recoveryRootPublicKey: Data

    init(
        required: Bool,
        environment: String,
        productID: String,
        appID: String,
        channel: String,
        clientIdentifier: String,
        publicKeys: [String: Data],
        recoveryRootKeyID: String = "",
        recoveryRootPublicKey: Data = Data()
    ) {
        self.required = required
        self.environment = environment
        self.productID = productID
        self.appID = appID
        self.channel = channel
        self.clientIdentifier = clientIdentifier
        self.publicKeys = publicKeys
        self.recoveryRootKeyID = recoveryRootKeyID
        self.recoveryRootPublicKey = recoveryRootPublicKey
    }

    static func load(bundle: Bundle = .main) -> AccessDiscoveryTrustConfiguration {
        let info = bundle.infoDictionary ?? [:]
        let requiredValue = info["WXTAccessDiscoverySigningRequired"]
        let required = (requiredValue as? Bool) == true ||
            ["1", "true", "yes", "on"].contains((requiredValue as? String ?? "").lowercased())
        var configuredKeys = info["WXTAccessDiscoveryPublicKeys"] as? [String: String] ?? [:]
        if configuredKeys.isEmpty,
           let raw = (info["WXTAccessDiscoveryPublicKeysJSON"] as? String)?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: raw) {
            configuredKeys = decoded
        }
        let keys = configuredKeys.reduce(into: [String: Data]()) {
            if let decoded = Data(base64Encoded: $1.value), decoded.count == 32 {
                $0[$1.key] = decoded
            }
        }
        return AccessDiscoveryTrustConfiguration(
            required: required,
            environment: (info["WXTAccessDiscoveryEnvironment"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            productID: (info["WXTAccessDiscoveryProductID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            appID: (info["WXTAccessDiscoveryAppID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            channel: (info["WXTAccessDiscoveryChannel"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            clientIdentifier: bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            publicKeys: keys,
            recoveryRootKeyID: (info["WXTAccessDiscoveryRecoveryRootKeyID"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            recoveryRootPublicKey: Data(
                base64Encoded: (info["WXTAccessDiscoveryRecoveryRootPublicKeyB64"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? Data()
        )
    }

    func verify(
        _ envelope: SignedAccessDiscoveryEnvelope,
        context: IMAPIContext,
        now: Date = Date()
    ) throws -> RemoteAccessDiscoveryResponse {
        try verifyEnvelope(envelope, context: context, now: now, persistedLastGood: false)
    }

    private func verifyEnvelope(
        _ envelope: SignedAccessDiscoveryEnvelope,
        context: IMAPIContext,
        now: Date,
        persistedLastGood: Bool
    ) throws -> RemoteAccessDiscoveryResponse {
        guard required,
              !environment.isEmpty, !productID.isEmpty, !appID.isEmpty, !channel.isEmpty,
              !clientIdentifier.isEmpty, !publicKeys.isEmpty,
              !recoveryRootKeyID.isEmpty, recoveryRootPublicKey.count == 32 else {
            throw AccessDiscoveryTrustError.configurationBlocked
        }
        guard envelope.signatureAlg == "Ed25519",
              let canonicalPayload = Data(base64Encoded: envelope.payloadB64),
              canonicalPayload.count <= 64 * 1024,
              let signature = Data(base64Encoded: envelope.signature),
              signature.count == 64 else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        let payload = try PreloginStrictJSON.decodeAccessDiscoveryPayload(canonicalPayload)
        let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
        let isV2 = payload.contractVersion == 2
        let normalizedStatus = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedFingerprint = payload.profileFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
        let v2MetadataIsValid = !isV2 || (
            payload.publicationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && (payload.publicationRevision ?? 0) > 0
                && normalizedFingerprint == payload.contentHash
                && payload.lifetimeMode == .untilRevoked
                && ["active", "disabled", "tombstone"].contains(normalizedStatus ?? "")
                && (payload.keysetRevision ?? 0) > 0
        )
        let v1MetadataIsExact = isV2 || (
            payload.contractVersion == 1
                && payload.publicationID == nil
                && payload.publicationRevision == nil
                && payload.profileFingerprint == nil
                && payload.lifetimeMode == nil
                && payload.status == nil
                && payload.keysetRevision == nil
        )
        guard payload.purpose == "tenant_access_discovery",
              [1, 2].contains(payload.contractVersion),
              payload.canonicalizationVersion == 1,
              v2MetadataIsValid,
              v1MetadataIsExact,
              payload.tenantID == tenantID,
              appID == self.appID,
              payload.appID == self.appID,
              payload.platform == "ios",
              payload.environment == environment,
              payload.productID == productID,
              payload.channel == channel,
              payload.clientIdentifier == clientIdentifier else {
            throw AccessDiscoveryTrustError.audienceMismatch
        }
        let verifiedKeyState = try verifyKeyState(
            envelope.keyState,
            payload: payload,
            signingKeyID: envelope.keyID,
            now: now,
            allowsHistoricalAuthorization: persistedLastGood && isV2
        )
        if isV2, verifiedKeyState.payload.keysetRevision != payload.keysetRevision {
            throw AccessDiscoveryTrustError.conflict
        }
        guard let publicKeyData = publicKeys[envelope.keyID],
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw AccessDiscoveryTrustError.unknownKey
        }
        var domainMessage = Self.signingDomain
        domainMessage.append(canonicalPayload)
        let signingDigest = Data(SHA512.hash(data: domainMessage))
        guard publicKey.isValidSignature(signature, for: signingDigest) else {
            throw AccessDiscoveryTrustError.signatureInvalid
        }
        let formatter = ISO8601DateFormatter()
        guard let issuedAt = formatter.date(from: payload.issuedAt),
              let expiresAt = formatter.date(from: payload.expiresAt),
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 3_600,
              (persistedLastGood && isV2 || (
                issuedAt <= now.addingTimeInterval(300) && expiresAt > now
              )) else {
            throw AccessDiscoveryTrustError.expired
        }
        guard payload.generation > 0,
              !payload.configVersion.isEmpty,
              payload.contentHash == (try PreloginStrictJSON.accessDiscoveryExecutableHash(canonicalPayload)),
              (normalizedStatus != "active" || payload.endpoints.contains(where: {
                $0.normalizedStatus == "ready" && $0.isRealtimeWebSocketCandidate
              })) else {
            throw AccessDiscoveryTrustError.endpointInvalid
        }
        if payload.environment == "production" {
            guard Self.productionDomainOnlyPayloadIsExact(canonicalPayload, payload: payload),
                  Self.productionDomainOnlyPoolIsValid(payload.endpoints + payload.discoveryFallbacks) else {
                throw AccessDiscoveryTrustError.endpointInvalid
            }
        }
        let endpointValidationTime = persistedLastGood && isV2 ? issuedAt : now
        for endpoint in payload.endpoints + payload.discoveryFallbacks {
            guard endpoint.isSignedProtectedEndpointValid(at: endpointValidationTime, validUntil: expiresAt) else {
                throw AccessDiscoveryTrustError.endpointInvalid
            }
        }
        return RemoteAccessDiscoveryResponse(
            contractVersion: payload.contractVersion,
            configVersion: payload.configVersion,
            serverTime: payload.serverTime,
            ttlSeconds: payload.ttlSeconds,
            refreshJitterSeconds: payload.refreshJitterSeconds,
            source: payload.source,
            stale: payload.stale,
            degraded: payload.degraded,
            endpoints: payload.endpoints,
            discoveryFallbacks: payload.discoveryFallbacks,
            signatureAlg: envelope.signatureAlg,
            signature: envelope.signature,
            trust: AccessDiscoveryTrustProof(
                payloadB64: envelope.payloadB64, keyID: envelope.keyID,
                signatureAlg: envelope.signatureAlg, signature: envelope.signature,
                keyState: envelope.keyState,
                generation: payload.generation,
                fencingGeneration: payload.fencingGeneration,
                recoveryGeneration: verifiedKeyState.payload.recoveryGeneration,
                keyStateHash: verifiedKeyState.payloadHash,
                keyStateExpiresAt: verifiedKeyState.payload.expiresAt,
                contentHash: payload.contentHash,
                issuedAt: payload.issuedAt, expiresAt: payload.expiresAt,
                environment: payload.environment, productID: payload.productID,
                appID: payload.appID, channel: payload.channel,
                clientIdentifier: payload.clientIdentifier,
                tenantID: payload.tenantID, platform: payload.platform,
                publicationID: payload.publicationID,
                publicationRevision: payload.publicationRevision,
                profileFingerprint: payload.profileFingerprint,
                lifetimeMode: payload.lifetimeMode,
                publicationStatus: normalizedStatus,
                keysetRevision: payload.keysetRevision
            ),
            publicationID: payload.publicationID,
            publicationRevision: payload.publicationRevision,
            profileFingerprint: payload.profileFingerprint,
            lifetimeMode: payload.lifetimeMode,
            publicationStatus: normalizedStatus,
            keysetRevision: payload.keysetRevision
        )
    }

    static func productionDomainOnlyPoolIsValid(_ endpoints: [RemoteAccessDiscoveryEndpoint]) -> Bool {
        var ids = Set<String>()
        var candidates = Set<String>()
        for endpoint in endpoints {
            guard endpoint.isProductionDomainOnlyEndpoint,
                  ids.insert(endpoint.id).inserted,
                  let identity = endpoint.productionCandidateIdentity,
                  candidates.insert(identity).inserted else {
                return false
            }
        }
        return true
    }

    private static func productionDomainOnlyPayloadIsExact(
        _ canonicalPayload: Data,
        payload: SignedAccessDiscoveryPayload
    ) -> Bool {
        guard let document = try? JSONSerialization.jsonObject(with: canonicalPayload) as? [String: Any] else {
            return false
        }
        let collections: [(String, [RemoteAccessDiscoveryEndpoint])] = [
            ("endpoints", payload.endpoints),
            ("discovery_fallbacks", payload.discoveryFallbacks)
        ]
        for (name, decoded) in collections {
            guard let raw = document[name] as? [[String: Any]], raw.count == decoded.count else {
                return false
            }
            for endpoint in raw {
                guard let resolved = endpoint["resolved_ips"] as? [Any], resolved.isEmpty,
                      endpoint["dial_mode"] as? String == "domain_only" else {
                    return false
                }
            }
        }
        return true
    }

    private func verifyKeyState(
        _ state: SignedAccessDiscoveryKeyState,
        payload: SignedAccessDiscoveryPayload,
        signingKeyID: String,
        now: Date,
        allowsHistoricalAuthorization: Bool
    ) throws -> (payload: AccessDiscoveryKeyStatePayload, payloadHash: String) {
        guard state.rootKeyID == recoveryRootKeyID,
              state.signatureAlg == "Ed25519",
              let canonicalPayload = Data(base64Encoded: state.payloadB64),
              canonicalPayload.count <= 64 * 1024,
              let signature = Data(base64Encoded: state.signature),
              signature.count == 64,
              let rootPublicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: recoveryRootPublicKey) else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        let keyState = try PreloginStrictJSON.decodeAccessDiscoveryKeyStatePayload(canonicalPayload)
        let formatter = ISO8601DateFormatter()
        guard keyState.purpose == "tenant_access_discovery_key_state",
              keyState.contractVersion == payload.contractVersion,
              (keyState.contractVersion == 1
                ? keyState.keysetRevision == nil
                : (keyState.keysetRevision ?? 0) > 0),
              keyState.recoveryGeneration > 0,
              keyState.currentFencingGeneration > 0,
              !keyState.keys.isEmpty,
              keyState.keys.count <= 64,
              let issuedAt = formatter.date(from: keyState.issuedAt),
              let expiresAt = formatter.date(from: keyState.expiresAt),
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 8 * 24 * 3_600,
              (allowsHistoricalAuthorization || (
                issuedAt <= now.addingTimeInterval(300) && expiresAt > now
              )) else {
            throw AccessDiscoveryTrustError.expired
        }
        var domainMessage = Self.keyStateSigningDomain
        domainMessage.append(canonicalPayload)
        let digest = Data(SHA512.hash(data: domainMessage))
        guard rootPublicKey.isValidSignature(signature, for: digest) else {
            throw AccessDiscoveryTrustError.signatureInvalid
        }
        var seen = Set<String>()
        var activeAtCurrentFence: [String: Int] = [:]
        var authorized = false
        for key in keyState.keys {
            let scope = [
                key.keyID, key.environment, key.productID, key.appID,
                key.platform, key.channel, key.clientIdentifier
            ].joined(separator: "\u{0}")
            guard seen.insert(scope).inserted,
                  key.algorithm == "Ed25519",
                  ["primary", "standby"].contains(key.role),
                  (keyState.contractVersion == 1
                    ? ["active", "revoked"].contains(key.status)
                    : ["active", "retired", "revoked"].contains(key.status)),
                  key.minFencingGeneration > 0,
                  key.maxFencingGeneration.map({ $0 >= key.minFencingGeneration }) ?? true,
                  let notBefore = formatter.date(from: key.notBefore),
                  let notAfter = formatter.date(from: key.notAfter),
                  notAfter > notBefore,
                  notAfter > issuedAt else {
                throw AccessDiscoveryTrustError.invalidEnvelope
            }
            if key.role == "standby", key.status == "active" {
                guard key.minFencingGeneration >= keyState.currentFencingGeneration else {
                    throw AccessDiscoveryTrustError.invalidEnvelope
                }
                if key.minFencingGeneration == keyState.currentFencingGeneration {
                    guard keyState.recoveryGeneration > 1,
                          key.maxFencingGeneration == keyState.currentFencingGeneration else {
                        throw AccessDiscoveryTrustError.invalidEnvelope
                    }
                }
            }
            if key.status == "active",
               keyState.currentFencingGeneration >= key.minFencingGeneration,
               key.maxFencingGeneration.map({ keyState.currentFencingGeneration <= $0 }) ?? true {
                let audience = [
                    key.environment, key.productID, key.appID, key.platform,
                    key.channel, key.clientIdentifier
                ].joined(separator: "\u{0}")
                activeAtCurrentFence[audience, default: 0] += 1
                guard activeAtCurrentFence[audience] == 1 else {
                    throw AccessDiscoveryTrustError.invalidEnvelope
                }
            }
            if key.keyID == signingKeyID,
               (key.status == "active" || (allowsHistoricalAuthorization && key.status == "retired")),
               key.environment == environment,
               key.productID == productID,
               key.appID == appID,
               key.platform == "ios",
               key.channel == channel,
               key.clientIdentifier == clientIdentifier,
               payload.fencingGeneration == keyState.currentFencingGeneration,
               payload.fencingGeneration >= key.minFencingGeneration,
               key.maxFencingGeneration.map({ payload.fencingGeneration <= $0 }) ?? true,
               key.role != "standby" || (
                keyState.recoveryGeneration > 1 &&
                    key.minFencingGeneration == keyState.currentFencingGeneration &&
                    key.maxFencingGeneration == keyState.currentFencingGeneration
               ),
               (allowsHistoricalAuthorization || (
                now >= notBefore.addingTimeInterval(-300) && now < notAfter
               )) {
                authorized = true
            }
        }
        guard authorized else { throw AccessDiscoveryTrustError.unknownKey }
        return (keyState, PreloginTrust.sha256(canonicalPayload))
    }

    func verifyStored(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext,
        now: Date = Date()
    ) throws -> RemoteAccessDiscoveryResponse {
        guard let proof = response.trust else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        return try verifyEnvelope(
            SignedAccessDiscoveryEnvelope(
                payloadB64: proof.payloadB64,
                keyID: proof.keyID,
                signatureAlg: proof.signatureAlg,
                signature: proof.signature,
                keyState: proof.keyState
            ),
            context: context,
            now: now,
            persistedLastGood: true
        )
    }

    func verifyNetworkResponse(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext,
        now: Date = Date()
    ) throws -> RemoteAccessDiscoveryResponse {
        guard let proof = response.trust else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        return try verifyEnvelope(
            SignedAccessDiscoveryEnvelope(
                payloadB64: proof.payloadB64,
                keyID: proof.keyID,
                signatureAlg: proof.signatureAlg,
                signature: proof.signature,
                keyState: proof.keyState
            ),
            context: context,
            now: now,
            persistedLastGood: false
        )
    }
}

private extension SignedAccessDiscoveryEnvelope {
    init(
        payloadB64: String,
        keyID: String,
        signatureAlg: String,
        signature: String,
        keyState: SignedAccessDiscoveryKeyState
    ) {
        self.payloadB64 = payloadB64
        self.keyID = keyID
        self.signatureAlg = signatureAlg
        self.signature = signature
        self.keyState = keyState
    }
}

struct RemoteAccessDiscoveryEndpoint: Codable, Equatable, Sendable {
    let id: String
    let usage: String
    let protocolValue: String
    let url: String
    let host: String
    let port: Int
    let path: String?
    let resolvedIPs: [String]
    let tlsServerName: String?
    let httpHost: String?
    let dialMode: String?
    let priority: Int
    let weight: Int
    let region: String?
    let provider: String?
    let network: String
    let tls: Bool?
    let auth: String?
    let connectTimeoutMs: Int?
    let heartbeatSeconds: Int?
    let minStableSeconds: Int?
    let failbackAfterSeconds: Int?
    let cooldownSeconds: Int?
    let maxParallelRace: Int?
    let status: String
    let protectedResourceID: String?
    let protectedResourceType: String?
    let protectionEvidenceHash: String?
    let protectionExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case usage
        case protocolValue = "protocol"
        case url
        case host
        case port
        case path
        case resolvedIPs = "resolved_ips"
        case tlsServerName = "tls_server_name"
        case httpHost = "http_host"
        case dialMode = "dial_mode"
        case priority
        case weight
        case region
        case provider
        case network
        case tls
        case auth
        case connectTimeoutMs = "connect_timeout_ms"
        case heartbeatSeconds = "heartbeat_seconds"
        case minStableSeconds = "min_stable_seconds"
        case failbackAfterSeconds = "failback_after_seconds"
        case cooldownSeconds = "cooldown_seconds"
        case maxParallelRace = "max_parallel_race"
        case status
        case protectedResourceID = "protected_resource_id"
        case protectedResourceType = "protected_resource_type"
        case protectionEvidenceHash = "protection_evidence_hash"
        case protectionExpiresAt = "protection_expires_at"
    }

    init(
        id: String,
        usage: String,
        protocolValue: String,
        url: String,
        host: String,
        port: Int,
        path: String? = nil,
        resolvedIPs: [String] = [],
        tlsServerName: String? = nil,
        httpHost: String? = nil,
        dialMode: String? = nil,
        priority: Int,
        weight: Int,
        region: String? = nil,
        provider: String? = nil,
        network: String,
        tls: Bool? = nil,
        auth: String? = nil,
        connectTimeoutMs: Int? = nil,
        heartbeatSeconds: Int? = nil,
        minStableSeconds: Int? = nil,
        failbackAfterSeconds: Int? = nil,
        cooldownSeconds: Int? = nil,
        maxParallelRace: Int? = nil,
        status: String,
        protectedResourceID: String? = nil,
        protectedResourceType: String? = nil,
        protectionEvidenceHash: String? = nil,
        protectionExpiresAt: String? = nil
    ) {
        self.id = id
        self.usage = usage
        self.protocolValue = protocolValue
        self.url = url
        self.host = host
        self.port = port
        self.path = path
        self.resolvedIPs = resolvedIPs
        self.tlsServerName = tlsServerName
        self.httpHost = httpHost
        self.dialMode = dialMode
        self.priority = priority
        self.weight = weight
        self.region = region
        self.provider = provider
        self.network = network
        self.tls = tls
        self.auth = auth
        self.connectTimeoutMs = connectTimeoutMs
        self.heartbeatSeconds = heartbeatSeconds
        self.minStableSeconds = minStableSeconds
        self.failbackAfterSeconds = failbackAfterSeconds
        self.cooldownSeconds = cooldownSeconds
        self.maxParallelRace = maxParallelRace
        self.status = status
        self.protectedResourceID = protectedResourceID
        self.protectedResourceType = protectedResourceType
        self.protectionEvidenceHash = protectionEvidenceHash
        self.protectionExpiresAt = protectionExpiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        usage = try c.decode(String.self, forKey: .usage)
        protocolValue = try c.decode(String.self, forKey: .protocolValue)
        url = try c.decode(String.self, forKey: .url)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        resolvedIPs = try c.decodeIfPresent([String].self, forKey: .resolvedIPs) ?? []
        tlsServerName = try c.decodeIfPresent(String.self, forKey: .tlsServerName)
        httpHost = try c.decodeIfPresent(String.self, forKey: .httpHost)
        dialMode = try c.decodeIfPresent(String.self, forKey: .dialMode)
        priority = try c.decode(Int.self, forKey: .priority)
        weight = try c.decode(Int.self, forKey: .weight)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        network = try c.decode(String.self, forKey: .network)
        tls = try c.decodeIfPresent(Bool.self, forKey: .tls)
        auth = try c.decodeIfPresent(String.self, forKey: .auth)
        connectTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .connectTimeoutMs)
        heartbeatSeconds = try c.decodeIfPresent(Int.self, forKey: .heartbeatSeconds)
        minStableSeconds = try c.decodeIfPresent(Int.self, forKey: .minStableSeconds)
        failbackAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .failbackAfterSeconds)
        cooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .cooldownSeconds)
        maxParallelRace = try c.decodeIfPresent(Int.self, forKey: .maxParallelRace)
        status = try c.decode(String.self, forKey: .status)
        protectedResourceID = try c.decodeIfPresent(String.self, forKey: .protectedResourceID)
        protectedResourceType = try c.decodeIfPresent(String.self, forKey: .protectedResourceType)
        protectionEvidenceHash = try c.decodeIfPresent(String.self, forKey: .protectionEvidenceHash)
        protectionExpiresAt = try c.decodeIfPresent(String.self, forKey: .protectionExpiresAt)
    }

    var normalizedID: String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedNetwork: String {
        network.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isRealtimeWebSocketCandidate: Bool {
        guard usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "im_realtime" else { return false }
        guard protocolValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "wss" else { return false }
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "wss",
              let urlHost = components.host,
              RealtimeEndpointAddressValidator.isDomainName(urlHost),
              RealtimeEndpointAddressValidator.isDomainName(host) else {
            return false
        }
        return !normalizedID.isEmpty
    }

    func isSignedProtectedEndpointValid(at now: Date, validUntil: Date) -> Bool {
        let protocolName = protocolValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let usageName = usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedNetwork != "direct",
              normalizedStatus == "ready" || normalizedStatus == "degraded" || normalizedStatus == "draining",
              tls == true,
              let components = URLComponents(string: url),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.host?.lowercased() == host.lowercased(),
              RealtimeEndpointAddressValidator.isDomainName(host),
              (components.port ?? ((protocolName == "wss" || protocolName == "https") ? 443 : 0)) == port,
              (protocolName == "wss" || protocolName == "quic"
                  ? usageName == "im_realtime" && auth == "im_token"
                  : protocolName == "https" && usageName == "access_discovery" && auth == "none"),
              !(protectedResourceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              !(protectedResourceType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              let evidenceHash = protectionEvidenceHash?.lowercased(),
              evidenceHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let expiresText = protectionExpiresAt,
              let protectionExpiry = ISO8601DateFormatter().date(from: expiresText),
              protectionExpiry > now, protectionExpiry >= validUntil else {
            return false
        }
        return resolvedIPs.allSatisfy(RealtimeEndpointAddressValidator.isIPAddress)
    }

    var isProductionDomainOnlyEndpoint: Bool {
        if provider == "alibaba_cloud_ga" {
            guard port == 443,
                  protocolValue != "https" || path == "/api/tenant/access/v1/endpoints" else {
                return false
            }
        }
        let exactHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host == exactHost,
              RealtimeEndpointAddressValidator.isDomainName(exactHost),
              let components = URLComponents(string: url),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.host == exactHost,
              components.percentEncodedPath == components.path,
              path == components.path,
              (components.port ?? 443) == port,
              tlsServerName == exactHost, httpHost == exactHost,
              resolvedIPs.isEmpty, dialMode == "domain_only",
              network == normalizedNetwork, normalizedNetwork != "direct",
              Self.hasProductionEndpointRole(usage: usage, protocolName: protocolValue, auth: auth),
              !Self.isProductionOriginAddress(exactHost),
              Self.hasProductionProtectedEntryBinding(
                provider: provider,
                resourceType: protectedResourceType,
                resourceID: protectedResourceID,
                host: exactHost,
                network: normalizedNetwork
              ) else {
            return false
        }
        let protocolName = protocolValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return protocolValue == protocolName.lowercased() && components.scheme == protocolName
    }

    var productionCandidateIdentity: String? {
        guard let components = URLComponents(string: url),
              components.percentEncodedPath == components.path,
              let candidateHost = components.host else {
            return nil
        }
        return [usage, protocolValue, candidateHost, String(port), components.path].joined(separator: "\u{0}")
    }

    private static func isProductionOriginAddress(_ host: String) -> Bool {
        let suffixes = [
            ".amazonaws.com", ".amazonaws.com.cn", ".compute.internal", ".internal", ".local", ".localhost"
        ]
        guard !suffixes.contains(where: host.hasSuffix) else { return true }
        let firstLabel = host.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return firstLabel.hasPrefix("internal-") || firstLabel.hasPrefix("ip-")
    }

    private static func hasProductionProtectedEntryBinding(
        provider: String?,
        resourceType: String?,
        resourceID: String?,
        host: String,
        network: String
    ) -> Bool {
        let rawProvider = provider ?? ""
        let rawResourceType = resourceType ?? ""
        let rawResourceID = resourceID ?? ""
        let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resourceType = rawResourceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resourceID = rawResourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawProvider == provider, rawResourceType == resourceType, rawResourceID == resourceID else {
            return false
        }
        if provider == "alibaba_cloud_ga", resourceType == "controlled_load_balancer" {
            let prefix = "brand-entry:"
            let digest = resourceID.dropFirst(prefix.count)
            return network == "accelerated" && !host.hasSuffix(".cloudfront.net") &&
                resourceID.hasPrefix(prefix) && digest.count == 64 &&
                digest.unicodeScalars.allSatisfy {
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                }
        }
        let loweredID = resourceID.lowercased()
        guard !["private", "origin", "alb", "elb", "ec2", "target-group", "target_group"]
            .contains(where: loweredID.contains) else {
            return false
        }
        if provider == "aws_cloudfront", resourceType == "controlled_load_balancer" {
            return network == "fallback" && host.hasSuffix(".cloudfront.net") && isCloudFrontDistributionID(resourceID)
        }
        if provider == "alibaba_cloud_esa", resourceType == "professional_high_defense" {
            return network == "accelerated" && !host.hasSuffix(".cloudfront.net") && isSafeEdgeResourceID(resourceID)
        }
        return false
    }

    private static func hasProductionEndpointRole(
        usage: String,
        protocolName: String,
        auth: String?
    ) -> Bool {
        (protocolName == "wss" && usage == "im_realtime" && auth == "im_token") ||
            (protocolName == "https" && usage == "access_discovery" && auth == "none")
    }

    private static func isCloudFrontDistributionID(_ value: String) -> Bool {
        guard (5...32).contains(value.count), value.first == "E" else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57)
        }
    }

    private static func isSafeEdgeResourceID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122) || ($0.value >= 65 && $0.value <= 90) ||
                ($0.value >= 48 && $0.value <= 57) || "-_.:/".unicodeScalars.contains($0)
        }
    }

    var isRealtimeQUICCandidate: Bool {
        guard usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "im_realtime" else { return false }
        guard protocolValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "quic" else { return false }
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "quic",
              let urlHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlHost.isEmpty,
              RealtimeEndpointAddressValidator.isDomainName(urlHost),
              RealtimeEndpointAddressValidator.isDomainName(host) else {
            return false
        }
        if let tlsServerName = tlsServerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tlsServerName.isEmpty,
           !RealtimeEndpointAddressValidator.isDomainName(tlsServerName) {
            return false
        }
        if let httpHost = httpHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !httpHost.isEmpty,
           !RealtimeEndpointAddressValidator.isDomainName(httpHost) {
            return false
        }
        return !normalizedID.isEmpty
    }

    func runtimeWebSocketURL() -> URL? {
        guard isRealtimeWebSocketCandidate,
              var components = URLComponents(string: url) else {
            return nil
        }
        if (components.path.isEmpty || components.path == "/"),
           let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty {
            components.path = path.hasPrefix("/") ? path : "/\(path)"
        }
        guard let endpointURL = components.url else { return nil }
        return RealtimeEndpointURLSanitizer.canonicalIMWebSocketURLRemovingCredentials(from: endpointURL)
    }

    func runtimeWebSocketDialMetadata() -> RealtimeWebSocketDialMetadata? {
        guard isRealtimeWebSocketCandidate,
              let components = URLComponents(string: url),
              let urlHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              RealtimeEndpointAddressValidator.isDomainName(urlHost),
              host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == urlHost,
              dialMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "domain_or_ip_hint" else {
            return nil
        }
        let tlsName = tlsServerName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hostHeader = httpHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard tlsName == urlHost,
              hostHeader == urlHost,
              RealtimeEndpointAddressValidator.isDomainName(tlsName),
              RealtimeEndpointAddressValidator.isDomainName(hostHeader),
              let dialHost = resolvedIPs
                  .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                  .first(where: { RealtimeEndpointAddressValidator.isIPAddress($0) }) else {
            return nil
        }
        return RealtimeWebSocketDialMetadata(
            dialHost: dialHost,
            port: components.port ?? port,
            tlsServerName: tlsName,
            httpHost: hostHeader
        )
    }

    func runtimeQUICConnectionRequest(
        token: String,
        configuration: RealtimeQUICConfiguration
    ) -> RealtimeQUICConnectionRequest? {
        guard isRealtimeQUICCandidate,
              let rawEndpointURL = URL(string: url) else {
            return nil
        }
        let endpointURL = RealtimeEndpointURLSanitizer.removingCredentials(from: rawEndpointURL)
        let defaultPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutNanoseconds = connectTimeoutMs.map {
            RealtimeQUICConfiguration.clampedConnectTimeoutNanoseconds(milliseconds: $0)
        }
        let resolvedDefaultPath = defaultPath.flatMap { $0.isEmpty ? nil : $0 } ?? "/im/quic"
        let dialHost = resolvedIPs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && RealtimeEndpointAddressValidator.isIPAddress($0) }
        return configuration.connectionRequest(
            endpointURL: endpointURL,
            token: token,
            tlsServerName: tlsServerName,
            dialHost: dialHost,
            defaultPort: port,
            defaultPath: resolvedDefaultPath,
            connectTimeoutNanoseconds: timeoutNanoseconds
        )
    }
}

struct AccessDiscoveryEndpointHealth: Codable, Equatable, Sendable {
    var failureCount: Int = 0
    var quickDisconnectCount: Int = 0
    var cooldownUntil: TimeInterval?
    var lastConnectedAt: TimeInterval?
    var lastStableAt: TimeInterval?

    func isCoolingDown(at now: TimeInterval) -> Bool {
        guard let cooldownUntil else { return false }
        return cooldownUntil > now
    }
}

struct AccessDiscoveryCachedSnapshot: Codable, Equatable, Sendable {
    var response: RemoteAccessDiscoveryResponse
    var fetchedAt: TimeInterval
    var expiresAt: TimeInterval
    var staleUntil: TimeInterval
    var health: [String: AccessDiscoveryEndpointHealth]
}

struct AccessDiscoveryTrustWatermark: Codable, Equatable, Sendable {
    let recoveryGeneration: UInt64
    let currentFencingGeneration: UInt64
    let keyStateHash: String
    let configGeneration: UInt64
    let contentHash: String
    let configVersion: String
    var publicationRevision: UInt64? = nil
    var publicationID: String? = nil
    var profileFingerprint: String? = nil
    var publicationStatus: String? = nil
    var signingKeyID: String? = nil
    var keysetRevision: UInt64? = nil

    init(
        recoveryGeneration: UInt64,
        currentFencingGeneration: UInt64,
        keyStateHash: String,
        configGeneration: UInt64,
        contentHash: String,
        configVersion: String,
        publicationRevision: UInt64? = nil,
        publicationID: String? = nil,
        profileFingerprint: String? = nil,
        publicationStatus: String? = nil,
        signingKeyID: String? = nil,
        keysetRevision: UInt64? = nil
    ) {
        self.recoveryGeneration = recoveryGeneration
        self.currentFencingGeneration = currentFencingGeneration
        self.keyStateHash = keyStateHash
        self.configGeneration = configGeneration
        self.contentHash = contentHash
        self.configVersion = configVersion
        self.publicationRevision = publicationRevision
        self.publicationID = publicationID
        self.profileFingerprint = profileFingerprint
        self.publicationStatus = publicationStatus
        self.signingKeyID = signingKeyID
        self.keysetRevision = keysetRevision
    }

    init?(response: RemoteAccessDiscoveryResponse) {
        guard let trust = response.trust,
              trust.recoveryGeneration > 0,
              trust.fencingGeneration > 0,
              trust.generation > 0,
              trust.keyStateHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              trust.contentHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !response.configVersion.isEmpty else {
            return nil
        }
        self.init(
            recoveryGeneration: trust.recoveryGeneration,
            currentFencingGeneration: trust.fencingGeneration,
            keyStateHash: trust.keyStateHash,
            configGeneration: trust.generation,
            contentHash: trust.contentHash,
            configVersion: response.configVersion,
            publicationRevision: response.publicationRevision,
            publicationID: response.publicationID,
            profileFingerprint: response.profileFingerprint,
            publicationStatus: response.publicationStatus,
            signingKeyID: trust.keyID,
            keysetRevision: response.keysetRevision
        )
    }

}

func accessDiscoveryTrustWatermarkTransitionAllowed(
    previous: AccessDiscoveryTrustWatermark?,
    candidate: AccessDiscoveryTrustWatermark
) -> Bool {
    guard let previous else { return true }
    if let candidateRevision = candidate.publicationRevision {
        guard let previousRevision = previous.publicationRevision,
              let candidateKeysetRevision = candidate.keysetRevision,
              let previousKeysetRevision = previous.keysetRevision,
              candidateRevision >= previousRevision,
              candidateKeysetRevision >= previousKeysetRevision,
              candidate.recoveryGeneration >= previous.recoveryGeneration,
              candidate.currentFencingGeneration >= previous.currentFencingGeneration else {
            return false
        }
        if candidate.recoveryGeneration == previous.recoveryGeneration,
           candidate.keyStateHash != previous.keyStateHash {
            return false
        }
        if candidate.recoveryGeneration > previous.recoveryGeneration,
           candidate.keyStateHash == previous.keyStateHash {
            return false
        }
        if candidateRevision == previousRevision {
            return candidate.publicationID == previous.publicationID
                && candidate.profileFingerprint == previous.profileFingerprint
                && candidate.publicationStatus == previous.publicationStatus
                && candidate.contentHash == previous.contentHash
                && candidateKeysetRevision == previousKeysetRevision
        }
        return true
    }
    if previous.publicationRevision != nil { return false }
    if candidate.recoveryGeneration < previous.recoveryGeneration ||
        candidate.currentFencingGeneration < previous.currentFencingGeneration ||
        candidate.configGeneration < previous.configGeneration {
        return false
    }
    if candidate.recoveryGeneration == previous.recoveryGeneration,
       candidate.keyStateHash != previous.keyStateHash {
        return false
    }
    if candidate.recoveryGeneration > previous.recoveryGeneration,
       candidate.keyStateHash == previous.keyStateHash {
        return false
    }
    if candidate.configGeneration == previous.configGeneration,
       (candidate.contentHash != previous.contentHash ||
        candidate.configVersion != previous.configVersion) {
        return false
    }
    return true
}

struct AccessDiscoveryKnownKeyset: Codable, Equatable, Sendable {
    let revision: UInt64
    let retiredKeyIDs: Set<String>
    let revokedKeyIDs: Set<String>

    init(revision: UInt64, retiredKeyIDs: Set<String>, revokedKeyIDs: Set<String>) {
        self.revision = revision
        self.retiredKeyIDs = retiredKeyIDs
        self.revokedKeyIDs = revokedKeyIDs
    }

    init?(response: RemoteAccessDiscoveryResponse) {
        guard response.contractVersion == 2,
              let revision = response.keysetRevision,
              revision > 0,
              let proof = response.trust,
              let raw = Data(base64Encoded: proof.keyState.payloadB64),
              let payload = try? PreloginStrictJSON.decodeAccessDiscoveryKeyStatePayload(raw),
              payload.keysetRevision == revision else {
            return nil
        }
        self.revision = revision
        retiredKeyIDs = Set(payload.keys.filter { $0.status == "retired" }.map(\.keyID))
        revokedKeyIDs = Set(payload.keys.filter { $0.status == "revoked" }.map(\.keyID))
    }

    func permitsHistoricalLastGood(signedBy keyID: String) -> Bool {
        !revokedKeyIDs.contains(keyID)
    }
}

func accessDiscoveryKnownKeysetTransitionAllowed(
    previous: AccessDiscoveryKnownKeyset?,
    candidate: AccessDiscoveryKnownKeyset
) -> Bool {
    guard let previous else { return true }
    if candidate.revision < previous.revision { return false }
    if candidate.revision == previous.revision { return candidate == previous }
    return true
}

final class AccessDiscoveryStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let watermarkDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private let watermarkWriter: (Data, URL) throws -> Void

    init(
        baseDirectory: URL = AccessDiscoveryStore.defaultBaseDirectory(),
        watermarkDirectory: URL? = nil,
        fileManager: FileManager = .default,
        watermarkWriter: @escaping (Data, URL) throws -> Void = { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    ) {
        self.baseDirectory = baseDirectory
        self.watermarkDirectory = watermarkDirectory ?? baseDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AccessDiscoveryTrustWatermark", isDirectory: true)
        self.fileManager = fileManager
        self.watermarkWriter = watermarkWriter
        encoder.outputFormatting = [.sortedKeys]
    }

    static func defaultBaseDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("BlueStoneIM", isDirectory: true)
            .appendingPathComponent("AccessDiscoveryLastGood", isDirectory: true)
    }

    static func clearDefaultStore(fileManager: FileManager = .default) {
        let directory = defaultBaseDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }

    func load(key: String) throws -> AccessDiscoveryCachedSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(AccessDiscoveryCachedSnapshot.self, from: data)
    }

    func save(_ snapshot: AccessDiscoveryCachedSnapshot, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let destination = fileURL(for: key)
        let temporary = baseDirectory.appendingPathComponent("\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        let data = try encoder.encode(snapshot)
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    func remove(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func fileURL(for key: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.cacheFileName(for: key)).json")
    }

    func loadTrustWatermark(key: String) throws -> AccessDiscoveryTrustWatermark? {
        lock.lock()
        defer { lock.unlock() }
        return try loadTrustWatermarkLocked(key: key)
    }

    func advanceTrustWatermark(_ candidate: AccessDiscoveryTrustWatermark, key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let previous = try loadTrustWatermarkLocked(key: key) {
            guard accessDiscoveryTrustWatermarkTransitionAllowed(
                previous: previous,
                candidate: candidate
            ) else {
                return false
            }
            if previous == candidate {
                return true
            }
        }
        try fileManager.createDirectory(at: watermarkDirectory, withIntermediateDirectories: true)
        let destination = watermarkFileURL(for: key)
        let data = try encoder.encode(candidate)
        try watermarkWriter(data, destination)
        return true
    }

    func loadKnownKeyset(key: String) throws -> AccessDiscoveryKnownKeyset? {
        lock.lock()
        defer { lock.unlock() }
        let url = knownKeysetFileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(AccessDiscoveryKnownKeyset.self, from: Data(contentsOf: url))
    }

    func advanceKnownKeyset(_ candidate: AccessDiscoveryKnownKeyset, key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let destination = knownKeysetFileURL(for: key)
        let previous: AccessDiscoveryKnownKeyset?
        if fileManager.fileExists(atPath: destination.path) {
            previous = try decoder.decode(
                AccessDiscoveryKnownKeyset.self,
                from: Data(contentsOf: destination)
            )
        } else {
            previous = nil
        }
        guard accessDiscoveryKnownKeysetTransitionAllowed(previous: previous, candidate: candidate) else {
            return false
        }
        if previous == candidate { return true }
        try fileManager.createDirectory(at: watermarkDirectory, withIntermediateDirectories: true)
        try encoder.encode(candidate).write(to: destination, options: .atomic)
        return true
    }

    private func loadTrustWatermarkLocked(key: String) throws -> AccessDiscoveryTrustWatermark? {
        let url = watermarkFileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(AccessDiscoveryTrustWatermark.self, from: data)
    }

    private func watermarkFileURL(for key: String) -> URL {
        watermarkDirectory.appendingPathComponent("\(Self.cacheFileName(for: key)).json")
    }

    private func knownKeysetFileURL(for key: String) -> URL {
        watermarkDirectory.appendingPathComponent("keyset-\(Self.cacheFileName(for: key)).json")
    }

    private static func cacheFileName(for key: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

final class AccessDiscoveryManager: AccessDiscoveryManaging, @unchecked Sendable {
    private static let totalDiscoveryDeadlineSeconds: TimeInterval = 8
    private static let requestDeadlineSeconds: TimeInterval = 2.5
    private static let maximumDiscoveryFallbacks = 3
    private let store: AccessDiscoveryStore
    private let nowProvider: () -> Date
    private let monotonicNowProvider: () -> TimeInterval
    private let randomProvider: () -> Double
    private let trustConfiguration: AccessDiscoveryTrustConfiguration
    private let verifiedResponseProvider: ((RemoteAccessDiscoveryResponse, IMAPIContext, Date) throws -> RemoteAccessDiscoveryResponse)?
    private let lock = NSRecursiveLock()
    private var snapshots: [String: AccessDiscoveryCachedSnapshot] = [:]
    private var activeCacheKey: String?
    private var activeEndpointID: String?
    private var activeStartedAt: TimeInterval?
    private var directFailbackUntilByKey: [String: TimeInterval] = [:]
    private var terminallyUnavailableKeys: Set<String> = []

    init(
        store: AccessDiscoveryStore = AccessDiscoveryStore(),
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        trustConfiguration: AccessDiscoveryTrustConfiguration = .load(),
        verifiedResponseProvider: ((RemoteAccessDiscoveryResponse, IMAPIContext, Date) throws -> RemoteAccessDiscoveryResponse)? = nil
    ) {
        self.store = store
        self.nowProvider = now
        self.monotonicNowProvider = monotonicNow
        self.randomProvider = random
        self.trustConfiguration = trustConfiguration
        self.verifiedResponseProvider = verifiedResponseProvider
    }

    @discardableResult
    func refresh(context: IMAPIContext, fetcher: AccessDiscoveryFetching, force: Bool = false) async -> AccessDiscoveryRefreshOutcome {
        let key = cacheKey(for: context)
        let now = nowProvider().timeIntervalSince1970
        if !force,
           let cached = usableSnapshot(for: key, context: context),
           cached.expiresAt > now {
            return .memory(configVersion: cached.response.configVersion)
        }
        if !force,
           let persisted = loadPersistedSnapshot(for: key, context: context),
           persisted.expiresAt > now {
            return .cache(configVersion: persisted.response.configVersion)
        }

        let trustedPrevious = usableSnapshot(for: key, context: context) ??
            loadPersistedSnapshot(for: key, context: context)
        let fallbackURLs = trustConfiguration.required
            ? Self.trustedDiscoveryFallbackURLs(from: trustedPrevious?.response)
            : []
        let deadline = monotonicNowProvider() + Self.totalDiscoveryDeadlineSeconds
        var lastError: Error?
        for endpointURL in [URL?.none] + fallbackURLs.map(Optional.some) {
            if Task.isCancelled { return .unavailable }
            let remaining = deadline - monotonicNowProvider()
            if remaining <= 0 { break }
            do {
                let fetched = try await fetcher.accessDiscoveryEndpoints(
                    context: context,
                    endpointURL: endpointURL,
                    timeoutInterval: min(Self.requestDeadlineSeconds, remaining)
                )
                let response = try validatedFetchedResponse(fetched, context: context)
                guard transitionAllowed(from: trustedPrevious, to: response),
                      advanceKnownKeyset(response, context: context),
                      advanceTrustWatermark(response, context: context) else {
                    throw AccessDiscoveryTrustError.rollback
                }
                if response.contractVersion == 2,
                   ["disabled", "tombstone"].contains(response.publicationStatus ?? "") {
                    markTerminallyUnavailable(key: key)
                    return .unavailable
                }
                guard Self.isPersistable(response) else {
                    throw AccessDiscoveryTrustError.endpointInvalid
                }
                var cached = makeCachedSnapshot(response: response, key: key, now: now)
                lock.withLock {
                    let previous = snapshots[key]
                    let versionChanged = previous.map { $0.response.configVersion != response.configVersion } ?? false
                    if versionChanged {
                        directFailbackUntilByKey[key] = nil
                    } else if let previousHealth = previous?.health {
                        cached.health = previousHealth
                    }
                    snapshots[key] = cached
                    terminallyUnavailableKeys.remove(key)
                }
                do {
                    try store.save(cached, key: key)
                } catch {
                    markTerminallyUnavailable(key: key)
                    return .unavailable
                }
                return .network(configVersion: response.configVersion)
            } catch {
                if Task.isCancelled { return .unavailable }
                if Self.isTerminalDiscoveryError(error), !trustConfiguration.required {
                    markTerminallyUnavailable(key: key)
                    return .unavailable
                }
                lastError = error
                guard Self.shouldAttemptTrustedDiscoveryFallback(after: error) else {
                    break
                }
            }
        }
        _ = lastError
        return loadPersistedOutcome(for: key, context: context)
    }

    func realtimeConnectionRequest(
        context: IMAPIContext,
        token: String,
        fallbackURL: URL?,
        quicConfiguration: RealtimeQUICConfiguration = RealtimeQUICConfiguration.load()
    ) -> RealtimeConnectionRequest? {
        let key = cacheKey(for: context)
        let now = nowProvider().timeIntervalSince1970
        let fallbackURL = fallbackURL.map {
            RealtimeEndpointURLSanitizer.canonicalIMWebSocketURLRemovingCredentials(from: $0)
        }
#if DEBUG
        if !trustConfiguration.required,
           let fallbackURL,
           Self.isDevelopmentLoopbackFallbackURL(fallbackURL) {
            clearActiveRealtimeEndpoint()
            return RealtimeConnectionRequest(url: fallbackURL, token: token)
        }
#endif
        guard !isTerminallyUnavailable(key: key) else {
            if trustConfiguration.required { return nil }
            guard let fallbackURL else { return nil }
            clearActiveRealtimeEndpoint()
            return RealtimeConnectionRequest(url: fallbackURL, token: token)
        }
        if let snapshot = usableSnapshot(for: key, context: context) ??
            loadPersistedSnapshot(for: key, context: context) {
            let webSocketEndpoint = selectRealtimeEndpoint(
                from: snapshot,
                key: key,
                now: now,
                isCandidate: { $0.isRealtimeWebSocketCandidate }
            )
            let quicEndpoint = quicConfiguration.isEnabled
                ? selectRealtimeEndpoint(
                    from: snapshot,
                    key: key,
                    now: now,
                    isCandidate: { $0.isRealtimeQUICCandidate }
                )
                : nil
            let url = webSocketEndpoint?.runtimeWebSocketURL() ??
                (trustConfiguration.required ? nil : fallbackURL)
            guard let url else { return nil }
            let webSocketDialMetadata = webSocketEndpoint?.runtimeWebSocketDialMetadata()
            let quicRequest = quicEndpoint?.runtimeQUICConnectionRequest(token: token, configuration: quicConfiguration)
            lock.lock()
            activeCacheKey = key
            activeEndpointID = quicRequest == nil ? webSocketEndpoint?.normalizedID : quicEndpoint?.normalizedID
            activeStartedAt = now
            lock.unlock()
            return RealtimeConnectionRequest(
                url: url,
                token: token,
                webSocketDialMetadata: webSocketDialMetadata,
                quicRequest: quicRequest
            )
        }
        guard !trustConfiguration.required, let fallbackURL else { return nil }
        lock.lock()
        activeCacheKey = nil
        activeEndpointID = nil
        activeStartedAt = nil
        lock.unlock()
        return RealtimeConnectionRequest(url: fallbackURL, token: token)
    }

    private func clearActiveRealtimeEndpoint() {
        lock.lock()
        activeCacheKey = nil
        activeEndpointID = nil
        activeStartedAt = nil
        lock.unlock()
    }

    func markActiveRealtimeEndpointFailed() {
        let now = nowProvider().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard let key = activeCacheKey,
              let endpointID = activeEndpointID,
              var snapshot = snapshots[key],
              let endpoint = snapshot.response.endpoints.first(where: { $0.normalizedID == endpointID }) else {
            activeCacheKey = nil
            activeEndpointID = nil
            activeStartedAt = nil
            return
        }
        var health = snapshot.health[endpointID] ?? AccessDiscoveryEndpointHealth()
        health.failureCount += 1
        let connectedAt = health.lastConnectedAt ?? activeStartedAt ?? now
        if now - connectedAt < 30 {
            health.quickDisconnectCount += 1
        }
        let cooldownSeconds = cooldownDurationSeconds(for: endpoint, health: health)
        if cooldownSeconds > 0 {
            health.cooldownUntil = now + cooldownSeconds
        }
        snapshot.health[endpointID] = health
        snapshots[key] = snapshot
        try? store.save(snapshot, key: key)
        activeCacheKey = nil
        activeEndpointID = nil
        activeStartedAt = nil
    }

    func markActiveRealtimeEndpointConnected() {
        let now = nowProvider().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard let key = activeCacheKey,
              let endpointID = activeEndpointID,
              var snapshot = snapshots[key] else {
            return
        }
        var health = snapshot.health[endpointID] ?? AccessDiscoveryEndpointHealth()
        health.lastConnectedAt = now
        snapshot.health[endpointID] = health
        snapshots[key] = snapshot
        try? store.save(snapshot, key: key)
    }

    func markActiveRealtimeEndpointSucceeded() {
        let now = nowProvider().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard let key = activeCacheKey,
              let endpointID = activeEndpointID,
              var snapshot = snapshots[key],
              let endpoint = snapshot.response.endpoints.first(where: { $0.normalizedID == endpointID }) else {
            return
        }
        var health = snapshot.health[endpointID] ?? AccessDiscoveryEndpointHealth()
        health.lastConnectedAt = health.lastConnectedAt ?? now
        health.lastStableAt = now
        health.failureCount = 0
        health.quickDisconnectCount = 0
        health.cooldownUntil = nil
        if endpoint.normalizedNetwork == "direct" {
            let failback = TimeInterval(endpoint.failbackAfterSeconds ?? 300)
            let jitter = TimeInterval(max(snapshot.response.refreshJitterSeconds, 0)) * clampedRandom()
            directFailbackUntilByKey[key] = now + failback + jitter
        } else {
            directFailbackUntilByKey[key] = nil
        }
        snapshot.health[endpointID] = health
        snapshots[key] = snapshot
        try? store.save(snapshot, key: key)
    }

    private func snapshot(for key: String) -> AccessDiscoveryCachedSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[key]
    }

    private func usableSnapshot(
        for key: String,
        context: IMAPIContext
    ) -> AccessDiscoveryCachedSnapshot? {
        guard var snapshot = snapshot(for: key) else { return nil }
        do {
            guard knownKeysetPermits(snapshot.response, context: context) else {
                throw AccessDiscoveryTrustError.unknownKey
            }
            snapshot.response = try validatedResponse(snapshot.response, context: context)
            guard advanceTrustWatermark(snapshot.response, context: context) else {
                throw AccessDiscoveryTrustError.rollback
            }
            lock.withLock {
                snapshots[key] = snapshot
            }
            return snapshot
        } catch {
            markTerminallyUnavailable(key: key)
            return nil
        }
    }

    private func loadPersistedOutcome(for key: String, context: IMAPIContext) -> AccessDiscoveryRefreshOutcome {
        if let snapshot = loadPersistedSnapshot(for: key, context: context) {
            return .cache(configVersion: snapshot.response.configVersion)
        }
        return .unavailable
    }

    private func markTerminallyUnavailable(key: String) {
        lock.lock()
        snapshots[key] = nil
        directFailbackUntilByKey[key] = nil
        terminallyUnavailableKeys.insert(key)
        if activeCacheKey == key {
            activeCacheKey = nil
            activeEndpointID = nil
            activeStartedAt = nil
        }
        lock.unlock()
        try? store.remove(key: key)
    }

    private func isTerminallyUnavailable(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminallyUnavailableKeys.contains(key)
    }

    private func loadPersistedSnapshot(for key: String, context: IMAPIContext) -> AccessDiscoveryCachedSnapshot? {
        guard var snapshot = try? store.load(key: key),
              knownKeysetPermits(snapshot.response, context: context),
              let validated = try? validatedResponse(snapshot.response, context: context),
              Self.isPersistable(validated),
              advanceTrustWatermark(validated, context: context) else {
            if trustConfiguration.required {
                try? store.remove(key: key)
            }
            return nil
        }
        snapshot.response = validated
        lock.lock()
        snapshots[key] = snapshot
        lock.unlock()
        return snapshot
    }

    private func validatedResponse(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) throws -> RemoteAccessDiscoveryResponse {
        if !trustConfiguration.required {
            return response
        }
        if let verifiedResponseProvider {
            return try verifiedResponseProvider(response, context, nowProvider())
        }
        return try trustConfiguration.verifyStored(response, context: context, now: nowProvider())
    }

    private func validatedFetchedResponse(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) throws -> RemoteAccessDiscoveryResponse {
        if !trustConfiguration.required { return response }
        if let verifiedResponseProvider {
            return try verifiedResponseProvider(response, context, nowProvider())
        }
        return try trustConfiguration.verifyNetworkResponse(
            response,
            context: context,
            now: nowProvider()
        )
    }

    private func transitionAllowed(
        from previous: AccessDiscoveryCachedSnapshot?,
        to candidate: RemoteAccessDiscoveryResponse
    ) -> Bool {
        guard trustConfiguration.required else { return true }
        return accessDiscoveryTrustedTransitionAllowed(previous: previous?.response, candidate: candidate)
    }

    private func advanceTrustWatermark(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) -> Bool {
        guard trustConfiguration.required else { return true }
        guard let watermark = AccessDiscoveryTrustWatermark(response: response) else { return false }
        do {
            return try store.advanceTrustWatermark(
                watermark,
                key: trustWatermarkKey(for: context)
            )
        } catch {
            return false
        }
    }

    private func advanceKnownKeyset(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) -> Bool {
        guard trustConfiguration.required else { return true }
        guard response.contractVersion == 2 else { return true }
        guard let keyset = AccessDiscoveryKnownKeyset(response: response) else { return false }
        do {
            return try store.advanceKnownKeyset(keyset, key: trustWatermarkKey(for: context))
        } catch {
            return false
        }
    }

    private func knownKeysetPermits(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) -> Bool {
        guard trustConfiguration.required,
              response.contractVersion == 2,
              let signingKeyID = response.trust?.keyID else {
            return !trustConfiguration.required || response.contractVersion != 2
        }
        guard let keyset = try? store.loadKnownKeyset(key: trustWatermarkKey(for: context)) else {
            return true
        }
        return keyset.permitsHistoricalLastGood(signedBy: signingKeyID)
    }

    private func trustWatermarkKey(for context: IMAPIContext) -> String {
        [
            "v2",
            trustConfiguration.environment,
            trustConfiguration.appID,
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "|")
    }

    private func makeCachedSnapshot(response: RemoteAccessDiscoveryResponse, key: String, now: TimeInterval) -> AccessDiscoveryCachedSnapshot {
        let ttl = TimeInterval(max(response.ttlSeconds, 30))
        let staleWindow = max(ttl, 86_400)
        return AccessDiscoveryCachedSnapshot(
            response: response,
            fetchedAt: now,
            expiresAt: now + ttl,
            staleUntil: now + staleWindow,
            health: [:]
        )
    }

    private func selectRealtimeEndpoint(
        from snapshot: AccessDiscoveryCachedSnapshot,
        key: String,
        now: TimeInterval,
        isCandidate: (RemoteAccessDiscoveryEndpoint) -> Bool
    ) -> RemoteAccessDiscoveryEndpoint? {
        let candidates = snapshot.response.endpoints.filter {
            isCandidate($0) && ($0.normalizedStatus == "ready" || $0.normalizedStatus == "degraded")
        }
        guard !candidates.isEmpty else { return nil }

        if let holdUntil = directFailbackUntilByKey[key],
           holdUntil > now,
           let activeID = activeEndpointID,
           let direct = candidates.first(where: {
               $0.normalizedID == activeID
                   && $0.normalizedNetwork == "direct"
                   && !isCooling($0, snapshot: snapshot, now: now)
           }) {
            return direct
        }

        let ready = candidates.filter { $0.normalizedStatus == "ready" }
        let preferredStatusCandidates = ready.isEmpty ? candidates : ready
        let notCooling = preferredStatusCandidates.filter { !isCooling($0, snapshot: snapshot, now: now) }
        guard !notCooling.isEmpty else { return nil }
        let selectable = notCooling
        let sorted = selectable.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.normalizedID < rhs.normalizedID
        }
        guard let first = sorted.first else { return nil }
        let topPriority = first.priority
        let weightedGroup = sorted.filter { $0.priority == topPriority }
        return weightedPick(from: weightedGroup) ?? first
    }

    private func weightedPick(from endpoints: [RemoteAccessDiscoveryEndpoint]) -> RemoteAccessDiscoveryEndpoint? {
        guard !endpoints.isEmpty else { return nil }
        let totalWeight = endpoints.reduce(0) { $0 + max($1.weight, 0) }
        guard totalWeight > 0 else { return endpoints.first }
        var threshold = clampedRandom() * Double(totalWeight)
        for endpoint in endpoints {
            threshold -= Double(max(endpoint.weight, 0))
            if threshold <= 0 {
                return endpoint
            }
        }
        return endpoints.last
    }

    private func isCooling(
        _ endpoint: RemoteAccessDiscoveryEndpoint,
        snapshot: AccessDiscoveryCachedSnapshot,
        now: TimeInterval
    ) -> Bool {
        snapshot.health[endpoint.normalizedID]?.isCoolingDown(at: now) == true
    }

    private func cooldownDurationSeconds(
        for endpoint: RemoteAccessDiscoveryEndpoint,
        health: AccessDiscoveryEndpointHealth
    ) -> TimeInterval {
        if let cooldownSeconds = endpoint.cooldownSeconds, cooldownSeconds > 0 {
            return TimeInterval(cooldownSeconds)
        }
        let escalation: [TimeInterval] = [300, 900, 1_800]
        let index = min(max(health.failureCount - 1, 0), escalation.count - 1)
        return escalation[index]
    }

    private func clampedRandom() -> Double {
        min(max(randomProvider(), 0), 0.999_999)
    }

    private static func isPersistable(_ response: RemoteAccessDiscoveryResponse) -> Bool {
        guard [1, 2].contains(response.contractVersion),
              (response.contractVersion != 2 || response.publicationStatus == "active"),
              !response.configVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return response.endpoints.contains {
            $0.normalizedStatus == "ready" && $0.isRealtimeWebSocketCandidate
        }
    }

    static func trustedDiscoveryFallbackURLs(
        from response: RemoteAccessDiscoveryResponse?
    ) -> [URL] {
        guard let response else { return [] }
        var seen = Set<String>()
        return response.discoveryFallbacks
            .filter { endpoint in
                endpoint.protocolValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https" &&
                    endpoint.usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "access_discovery"
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.normalizedID < $1.normalizedID
            }
            .compactMap { endpoint -> URL? in
                guard let components = URLComponents(string: endpoint.url),
                      components.scheme?.lowercased() == "https",
                      components.user == nil,
                      components.password == nil,
                      components.query == nil,
                      components.fragment == nil,
                      let host = components.host,
                      RealtimeEndpointAddressValidator.isDomainName(host),
                      host.lowercased() == endpoint.host.lowercased(),
                      let url = components.url else {
                    return nil
                }
                guard seen.insert(url.absoluteString).inserted else { return nil }
                return url
            }
            .prefix(maximumDiscoveryFallbacks)
            .map { $0 }
    }

    private static func isDevelopmentLoopbackFallbackURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else { return false }
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.") else {
            return false
        }
        return url.path == "/im/ws" || url.port == 8083
    }

    private static func shouldAttemptTrustedDiscoveryFallback(after error: Error) -> Bool {
        IMAPIClient.runtimeRouteFailure(for: error).decision == .qualifiedNetwork
    }

    private static func isTerminalDiscoveryError(_ error: Error) -> Bool {
        switch error {
        case let IMAPIError.businessForbidden(code, message, apiError):
            return containsTerminalDiscoveryErrorCode(in: [code, message, apiError?.code, apiError?.reasonCode, apiError?.reason, apiError?.message])
        case let IMAPIError.conflict(code, message):
            return containsTerminalDiscoveryErrorCode(in: [code, message])
        case let IMAPIError.forbidden(message),
             let IMAPIError.server(message),
             let IMAPIError.unauthorized(message),
             let IMAPIError.badURL(message),
             let IMAPIError.missingContext(message):
            return containsTerminalDiscoveryErrorCode(in: [message])
        default:
            return false
        }
    }

    private static func containsTerminalDiscoveryErrorCode(in values: [String?]) -> Bool {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { value in
                value.contains("access_discovery_disabled")
                    || value.contains("access_discovery_tenant_mismatch")
                    || value.contains("access_discovery_app_unavailable")
            }
    }

    private func cacheKey(for context: IMAPIContext) -> String {
        [
            "v3",
            trustConfiguration.environment,
            IMAPIContext.normalizedIOSAppID(context.appID),
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ].joined(separator: "|")
    }
}

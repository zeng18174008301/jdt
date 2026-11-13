// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_BEGIN
import Foundation
import IM4Domain

public enum IMRuntimeRouteHashScope: String, Codable, Sendable {
    case appBootstrap = "app_bootstrap"
    case tenantEntry = "tenant_entry"
}

public struct IMRuntimeRouteSnapshot: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let appID: String
    public let tenantID: String?
    public let revision: UInt64
    public let source: String
    public let status: String
    public let configHash: String
    public let services: [String: IMRuntimeRouteEndpointSet]
    public let policy: IMRuntimeRoutePolicy
    public let hashScope: IMRuntimeRouteHashScope
    public let bootstrapHost: String?
    public let preferredEndpoints: [String: [String]]
    public var environment: String? = nil
    public var publicationID: String? = nil
    public var publicationRevision: UInt64? = nil
    public var profileFingerprint: String? = nil
    public var lifetimeMode: IMSessionLifetimeMode? = nil
    public var publicationStatus: String? = nil
    public var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"; case appID = "app_id"; case tenantID = "tenant_id"
        case revision; case source; case status; case configHash = "config_hash"; case services; case policy
        case hashScope = "hash_scope"; case bootstrapHost = "bootstrap_host"; case preferredEndpoints = "preferred_endpoints"
        case environment; case publicationID = "publication_id"; case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"; case lifetimeMode = "lifetime_mode"
        case publicationStatus = "publication_status"; case keysetRevision = "keyset_revision"
    }

    public init(
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
}

public struct IMRuntimeRouteRecoveryState: Codable, Equatable, Sendable {
    public var consecutiveQualifiedColdLaunchFailures = 0
    public var recovery = false
    public var consecutiveStablePreferredProbes = 0
    public var lastStableProbeAtMS: UInt64?
    public init(
        consecutiveQualifiedColdLaunchFailures: Int = 0,
        recovery: Bool = false,
        consecutiveStablePreferredProbes: Int = 0,
        lastStableProbeAtMS: UInt64? = nil
    ) {
        self.consecutiveQualifiedColdLaunchFailures = consecutiveQualifiedColdLaunchFailures
        self.recovery = recovery
        self.consecutiveStablePreferredProbes = consecutiveStablePreferredProbes
        self.lastStableProbeAtMS = lastStableProbeAtMS
    }
}

public struct IMRuntimeRoutePublicationWatermark: Codable, Equatable, Sendable {
    public let environment: String
    public let revision: UInt64
    public let publicationID: String
    public let profileFingerprint: String
    public let status: String
    public let keysetRevision: UInt64



    public init(
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

public struct IMRuntimeRouteAtomicRecord: Codable, Equatable, Sendable {
    public var current: IMRuntimeRouteSnapshot?
    public var previous: IMRuntimeRouteSnapshot?
    public var recoveryByService: [String: IMRuntimeRouteRecoveryState]
    public var publicationWatermark: IMRuntimeRoutePublicationWatermark?

	private enum CodingKeys: String, CodingKey { case current, previous, recoveryByService, publicationWatermark }



    public init(
        storedCurrent: IMRuntimeRouteSnapshot?,
        previous: IMRuntimeRouteSnapshot?,
        recoveryByService: [String: IMRuntimeRouteRecoveryState],
        publicationWatermark: IMRuntimeRoutePublicationWatermark? = nil
    ) {
        self.current = storedCurrent
        self.previous = previous
        self.recoveryByService = recoveryByService
        self.publicationWatermark = publicationWatermark
    }

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// Decode both generations independently so a malformed current snapshot does
		// not make a still-valid previous snapshot unreadable.
		current = try? container.decode(IMRuntimeRouteSnapshot.self, forKey: .current)
		previous = try? container.decode(IMRuntimeRouteSnapshot.self, forKey: .previous)
		recoveryByService = (try? container.decode([String: IMRuntimeRouteRecoveryState].self, forKey: .recoveryByService)) ?? [:]
        publicationWatermark = try? container.decode(IMRuntimeRoutePublicationWatermark.self, forKey: .publicationWatermark)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encodeIfPresent(current, forKey: .current)
		try container.encodeIfPresent(previous, forKey: .previous)
		try container.encode(recoveryByService, forKey: .recoveryByService)
        try container.encodeIfPresent(publicationWatermark, forKey: .publicationWatermark)
	}
}
// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_END

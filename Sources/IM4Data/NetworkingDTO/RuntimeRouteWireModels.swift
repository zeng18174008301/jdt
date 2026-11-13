// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation

public struct IMRuntimeRouteEndpointSet: Codable, Equatable, Sendable {
    public let preferred: [String]
    public let backups: [String]
    public let status: String
    public let preferredSource: String
    public let backupSource: String

    enum CodingKeys: String, CodingKey {
        case preferred
        case backups
        case status
        case preferredSource = "preferred_source"
        case backupSource = "backup_source"
    }

    public init(
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferred = try container.decodeIfPresent([String].self, forKey: .preferred) ?? []
        backups = try container.decodeIfPresent([String].self, forKey: .backups) ?? []
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        preferredSource = try container.decodeIfPresent(String.self, forKey: .preferredSource) ?? ""
        backupSource = try container.decodeIfPresent(String.self, forKey: .backupSource) ?? ""
    }




}

public struct IMRuntimeRoutePolicy: Codable, Equatable, Sendable {
	public let contractVersion: Int
    public let preferredFailureBudgetMS: UInt64
    public let recoveryColdLaunchFailures: Int
    public let preferredProbeSuccesses: Int
    public let preferredProbeStableMS: UInt64
    public let preferredProbeIntervalMS: UInt64
    public let automaticExpiry: Bool
    public let businessSigningRequired: Bool

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

	public init(contractVersion: Int = 2, preferredFailureBudgetMS: UInt64 = 5_000, recoveryColdLaunchFailures: Int = 3,
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

    public init(from decoder: Decoder) throws {
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


}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

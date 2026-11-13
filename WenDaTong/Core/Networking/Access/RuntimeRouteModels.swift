// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_BEGIN
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import CryptoKit
import Foundation
import IM4Data
import Network

enum IMRuntimeRouteService: String, Codable, CaseIterable, Sendable {
    case platformAPI = "platform_api"
    case tenantAPI = "tenant_api"
    case imAPI = "im_api"
    case imRealtime = "im_realtime"
}

typealias IMRuntimeRouteEndpointSet = IM4Data.IMRuntimeRouteEndpointSet

extension IMRuntimeRouteEndpointSet {
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

typealias IMRuntimeRoutePolicy = IM4Data.IMRuntimeRoutePolicy

extension IMRuntimeRoutePolicy {
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

typealias IMRuntimeRouteHashScope = IM4Data.IMRuntimeRouteHashScope

typealias IMRuntimeRouteSnapshot = IM4Data.IMRuntimeRouteSnapshot

extension IMRuntimeRouteSnapshot {
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
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END
// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_END

import Foundation
import CryptoKit
import XCTest
@testable import WenDaTong

private final class RuntimeRoutesDefaultsBox: @unchecked Sendable {
	let value: UserDefaults
	init(_ value: UserDefaults) { self.value = value }
}

@MainActor
final class RuntimeRoutesP0Tests: XCTestCase {
    func testAliyunGAHTTPAndWSSUseSameBrandAndKeepIndependentCloudFrontRecovery() throws {
        let gaHost = "im.brand-a.example.com"
        let cfHost = "d111111abcdef8.cloudfront.net"
        var services: [String: IMRuntimeRouteEndpointSet] = Dictionary(uniqueKeysWithValues:
            [IMRuntimeRouteService.tenantAPI, .imAPI, .imRealtime].map { service in
                let realtime = service == .imRealtime
                let scheme = realtime ? "wss" : "https"
                let path = realtime ? "/im/ws" : ""
                return (service.rawValue, .init(
                    preferred: ["\(scheme)://\(gaHost)\(path)"],
                    backups: ["\(scheme)://\(cfHost)\(path)"],
                    preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
                ))
            })
        services[IMRuntimeRouteService.platformAPI.rawValue] = .init(
            preferred: ["https://platform.example.com"],
            backups: ["https://platform-backup.example.com"],
            preferredSource: "app_preferred", backupSource: "common_platform_backup"
        )
        let unsigned = IMRuntimeRouteSnapshot(contractVersion: 2, appID: "app-one", tenantID: "tenant-a",
            revision: 1, source: "bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
            services: services, policy: IMRuntimeRoutePolicy())
        let routes = IMRuntimeRouteSnapshot(contractVersion: 2, appID: "app-one", tenantID: "tenant-a",
            revision: 1, source: "bootstrap", status: "ready", configHash: try XCTUnwrap(unsigned.recomputedConfigHash),
            services: services, policy: IMRuntimeRoutePolicy())
        let validated = try XCTUnwrap(routes.validated(appID: "app-one", tenantID: "tenant-a"))
        XCTAssertEqual(validated.services[IMRuntimeRouteService.platformAPI.rawValue]?.preferred,
            ["https://platform.example.com"])
        XCTAssertEqual(validated.services[IMRuntimeRouteService.platformAPI.rawValue]?.backups,
            ["https://platform-backup.example.com"])
        let client = IMAPIClient(platformBase: URL(string: "https://platform.example.com")!,
            tenantBase: URL(string: "https://old-tenant.example.com")!,
            imBase: URL(string: "https://old-im.example.com")!, runtimeRouteStore: store)
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
        let context = IMAPIContext(platformToken: "platform-token", accountID: "account-a", tenantID: "tenant-a",
            imUID: "uid-a", imToken: "im-token", platformAuthSession: nil, tenantAuthSession: nil,
            appID: "app-one", deviceID: "fixture-device")
        for service in [IMRuntimeRouteService.tenantAPI, .imAPI, .imRealtime] {
            XCTAssertEqual(client.activeRuntimeBase(service: service, appID: "app-one", tenantID: "tenant-a")?.host, gaHost)
            XCTAssertNil(client.activeRuntimeBase(service: service, appID: "app-one", tenantID: "tenant-b"))
        }
        XCTAssertEqual(client.webSocketURL(context: context)?.absoluteString, "wss://\(gaHost)/im/ws")
        let selector = IMRuntimeRouteSelector(store: store)
        let qualified = IMRuntimeColdLaunchAttempt(processWasNotRunning: true, foregroundLaunch: true,
            networkReachable: true, backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000)
        for service in [IMRuntimeRouteService.tenantAPI, .imAPI, .imRealtime] {
            for _ in 0..<routes.policy.recoveryColdLaunchFailures {
                selector.recordColdLaunch(qualified, snapshot: routes, service: service)
            }
            XCTAssertEqual(client.activeRuntimeBase(service: service, appID: "app-one", tenantID: "tenant-a")?.host, cfHost)
            XCTAssertEqual(selector.endpoints(routes, service: service).count, 2)
        }
        XCTAssertEqual(client.webSocketURL(context: context)?.absoluteString, "wss://\(cfHost)/im/ws")
    }

    private(set) var defaults: UserDefaults!
    private var store: IMRuntimeRouteStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "RuntimeRoutesP0Tests.\(UUID().uuidString)")!
        store = IMRuntimeRouteStore(defaults: defaults)
    }

    private func snapshot(
		revision: UInt64 = 1,
		appID: String = "app-one",
		tenantID: String? = "tenant-a",
		hash: String? = nil,
		tenantPreferred: String = "https://tenant-primary.example.com"
	) -> IMRuntimeRouteSnapshot {
		let services: [String: IMRuntimeRouteEndpointSet] = [
			"platform_api": .init(
				preferred: ["https://platform-primary.example.com"], backups: ["https://platform-backup.example.net"],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"tenant_api": .init(
				preferred: [tenantPreferred], backups: ["https://tenant-backup.example.net"],
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
			"im_api": .init(
				preferred: ["https://im-primary.example.com"], backups: ["https://im-backup.example.net"],
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
			"im_realtime": .init(
				preferred: ["wss://ws-primary.example.com"], backups: ["wss://ws-backup.example.net"],
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
		]
		let policy = IMRuntimeRoutePolicy()
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: appID, tenantID: tenantID, revision: revision,
			source: "bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
			services: services, policy: policy
		)
		return .init(
			contractVersion: 2, appID: appID, tenantID: tenantID, revision: revision,
			source: "bootstrap", status: "ready", configHash: hash ?? unsigned.recomputedConfigHash!,
			services: services, policy: policy
		)
    }

	private func invalidatePersistedCurrentRouteAuthority() throws {
		let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("wxt.runtime.routes.v2.") })
		let encoded = try XCTUnwrap(defaults.data(forKey: key))
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		var current = try XCTUnwrap(object["current"] as? [String: Any])
		var services = try XCTUnwrap(current["services"] as? [String: Any])
		var tenantAPI = try XCTUnwrap(services["tenant_api"] as? [String: Any])
		tenantAPI["preferred_source"] = "app_preferred"
		services["tenant_api"] = tenantAPI
		current["services"] = services
		object["current"] = current
		defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
	}

    private func publishedSnapshot(
        revision: UInt64,
        publicationID: String,
        environment: String = "production"
    ) -> IMRuntimeRouteSnapshot {
        let base = snapshot(revision: revision)
        return IMRuntimeRouteSnapshot(
            contractVersion: base.contractVersion,
            appID: base.appID,
            tenantID: base.tenantID,
            revision: base.revision,
            source: base.source,
            status: base.status,
            configHash: base.configHash,
            services: base.services,
            policy: base.policy,
            environment: environment,
            publicationID: publicationID,
            publicationRevision: revision,
            profileFingerprint: "sha256:\(base.configHash)",
            lifetimeMode: .untilRevoked,
            publicationStatus: "active",
            keysetRevision: 7
        )
    }

	func appBootstrapServices() -> [String: IMRuntimeRouteEndpointSet] {
		[
			"platform_api": .init(
				preferred: ["https://platform-primary.example.com"], backups: ["https://platform-backup.example.net"],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"tenant_api": .init(
				preferred: ["https://tenant-primary.example.com"], backups: [],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"im_api": .init(
				preferred: ["https://im-primary.example.com"], backups: [],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"im_realtime": .init(
				preferred: ["wss://ws-primary.example.com"], backups: [],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
		]
	}

    func testAtomicCurrentPreviousUInt64RevisionRestartAndIsolation() {
        XCTAssertEqual(store.apply(snapshot(), appID: "app-one", tenantID: "tenant-a"), .applied)
		let jsSafeMax: UInt64 = 9_007_199_254_740_991
        XCTAssertEqual(store.apply(snapshot(revision: jsSafeMax), appID: "app-one", tenantID: "tenant-a"), .applied)
        let restarted = IMRuntimeRouteStore(defaults: defaults)
		XCTAssertEqual(restarted.record(appID: "app-one", tenantID: "tenant-a").current?.revision, jsSafeMax)
        XCTAssertEqual(restarted.record(appID: "app-one", tenantID: "tenant-a").previous?.revision, 1)
        XCTAssertNil(restarted.record(appID: "app-one", tenantID: "tenant-b").current)
        XCTAssertEqual(restarted.apply(snapshot(revision: 2), appID: "app-one", tenantID: "tenant-a"), .rollback)
		let current = snapshot(revision: jsSafeMax)
		let equalDifferent = IMRuntimeRouteSnapshot(
			contractVersion: current.contractVersion, appID: current.appID, tenantID: current.tenantID,
			revision: current.revision, source: "different-source", status: current.status,
			configHash: current.configHash, services: current.services, policy: current.policy
		)
		XCTAssertEqual(restarted.apply(equalDifferent, appID: "app-one", tenantID: "tenant-a"), .conflict)
        XCTAssertEqual(restarted.apply(snapshot(revision: .max), appID: "app-one", tenantID: "tenant-a"), .identity)
    }

    func testPublicationTombstoneKeepsHighWatermarkAndHigherRevisionCanRepublishPriorContent() {
        let active = publishedSnapshot(revision: 20, publicationID: "publication-20")
        XCTAssertEqual(store.apply(active, appID: active.appID, tenantID: active.tenantID), .applied)
        XCTAssertEqual(
            store.applyRevocation(
                environment: "production",
                appID: active.appID,
                tenantID: active.tenantID,
                revision: 21,
                publicationID: "publication-21",
                profileFingerprint: active.profileFingerprint ?? "",
                status: "tombstone",
                keysetRevision: 7
            ),
            .revoked
        )
        XCTAssertNil(store.restore(appID: active.appID, tenantID: active.tenantID))
        XCTAssertEqual(store.record(appID: active.appID, tenantID: active.tenantID).publicationWatermark?.revision, 21)
        XCTAssertEqual(store.apply(active, appID: active.appID, tenantID: active.tenantID), .rollback)

        let rollbackContent = publishedSnapshot(revision: 22, publicationID: "publication-22")
        XCTAssertEqual(store.apply(rollbackContent, appID: active.appID, tenantID: active.tenantID), .applied)
        XCTAssertEqual(store.restore(appID: active.appID, tenantID: active.tenantID)?.revision, 22)

        let sameRevisionDifferentPublication = publishedSnapshot(revision: 22, publicationID: "publication-22-conflict")
        XCTAssertEqual(
            store.apply(sameRevisionDifferentPublication, appID: active.appID, tenantID: active.tenantID),
            .conflict
        )
    }

	func testApplyReplacesInvalidPersistedCurrentAtSameRevision() throws {
		let authoritative = snapshot(revision: 7)
		XCTAssertEqual(store.apply(authoritative, appID: authoritative.appID, tenantID: authoritative.tenantID), .applied)
		var recovery = IMRuntimeRouteRecoveryState()
		recovery.recovery = true
		XCTAssertTrue(store.updateRecovery(recovery, service: .tenantAPI, snapshot: authoritative))
		try invalidatePersistedCurrentRouteAuthority()

		let restarted = IMRuntimeRouteStore(defaults: defaults)
		XCTAssertEqual(
			restarted.apply(authoritative, appID: authoritative.appID, tenantID: authoritative.tenantID),
			.applied
		)
		let record = restarted.record(appID: authoritative.appID, tenantID: authoritative.tenantID)
		XCTAssertEqual(record.current, authoritative)
		XCTAssertNil(record.previous)
		XCTAssertTrue(record.recoveryByService.isEmpty)
	}

	func testApplyRejectsDifferentValidRouteAtSameRevision() {
		let current = snapshot(revision: 8)
		XCTAssertEqual(store.apply(current, appID: current.appID, tenantID: current.tenantID), .applied)
		let different = snapshot(
			revision: current.revision,
			tenantPreferred: "https://tenant-alternate.example.com"
		)
		XCTAssertNotEqual(different.configHash, current.configHash)

		XCTAssertEqual(store.apply(different, appID: current.appID, tenantID: current.tenantID), .conflict)
		XCTAssertEqual(store.record(appID: current.appID, tenantID: current.tenantID).current, current)
	}

	func testApplyRejectsLowerRevisionAgainstValidPersistedCurrent() {
		let current = snapshot(revision: 9)
		XCTAssertEqual(store.apply(current, appID: current.appID, tenantID: current.tenantID), .applied)

		XCTAssertEqual(
			store.apply(snapshot(revision: 8), appID: current.appID, tenantID: current.tenantID),
			.rollback
		)
		XCTAssertEqual(store.record(appID: current.appID, tenantID: current.tenantID).current, current)
	}

	func testRestorePromotesPreviousWhenCurrentGenerationIsStructurallyCorrupted() throws {
		let first = snapshot(revision: 1)
		let second = snapshot(revision: 2)
		XCTAssertEqual(store.apply(first, appID: first.appID, tenantID: first.tenantID), .applied)
		XCTAssertEqual(store.apply(second, appID: second.appID, tenantID: second.tenantID), .applied)
		let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("wxt.runtime.routes.v2.") })
		let encoded = try XCTUnwrap(defaults.data(forKey: key))
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		var current = try XCTUnwrap(object["current"] as? [String: Any])
		current["revision"] = "corrupted-current-revision"
		object["current"] = current
		defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)

		let restarted = IMRuntimeRouteStore(defaults: defaults)
		let restored = restarted.restore(appID: first.appID, tenantID: first.tenantID)

		XCTAssertEqual(restored, first)
		XCTAssertEqual(restarted.record(appID: first.appID, tenantID: first.tenantID).current, first)
		XCTAssertNil(restarted.record(appID: first.appID, tenantID: first.tenantID).previous)
	}

	@MainActor
	func testIMAPIClientColdInitRestoresPromotedPreviousAppRouteFromAtomicStore() throws {
		let appID = IMAPIContext.canonicalIOSAppID
		func appSnapshot(revision: UInt64) -> IMRuntimeRouteSnapshot {
			let services = appBootstrapServices()
			let unsigned = IMRuntimeRouteSnapshot(
				contractVersion: 2, appID: appID, tenantID: nil, revision: revision,
				source: "app_bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
				services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
				bootstrapHost: "bootstrap.wenxintongim.com",
				preferredEndpoints: services.mapValues(\.preferred)
			)
			return IMRuntimeRouteSnapshot(
				contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: nil,
				revision: revision, source: unsigned.source, status: unsigned.status,
				configHash: unsigned.recomputedConfigHash!, services: unsigned.services,
				policy: unsigned.policy, hashScope: .appBootstrap,
				bootstrapHost: unsigned.bootstrapHost, preferredEndpoints: unsigned.preferredEndpoints
			)
		}
		let first = appSnapshot(revision: 1)
		let second = appSnapshot(revision: 2)
		XCTAssertEqual(store.apply(first, appID: appID, tenantID: nil), .applied)
		XCTAssertEqual(store.apply(second, appID: appID, tenantID: nil), .applied)
		let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("wxt.runtime.routes.v2.") })
		let encoded = try XCTUnwrap(defaults.data(forKey: key))
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		var current = try XCTUnwrap(object["current"] as? [String: Any])
		current["revision"] = ["not": "a-number"]
		object["current"] = current
		defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)

		let client = IMAPIClient(
			platformBase: IMAPIClient.releasePlaceholderPlatformBase,
			bootstrapBases: [URL(string: "https://bootstrap.wenxintongim.com")!],
			httpTransport: AccessDiscoveryHTTPTransport(
				result: .init(data: Data(), isHTTPResponse: true, statusCode: 500)
			),
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)
		)

		XCTAssertEqual(
			client.activeRuntimeBase(service: .platformAPI, appID: appID, tenantID: nil)?.host,
			"platform-primary.example.com"
		)
		XCTAssertEqual(store.record(appID: appID, tenantID: nil).current?.revision, 1)
	}

	func testProductionEndpointValidationRequiresSecureFQDNPort443WithoutPlaceholders() {
		let validHTTP = "https://tenant-api.customer-owned.net:443"
		let validWS = "wss://realtime.customer-owned.net:443/im/ws"
		XCTAssertEqual(
			IMRuntimeRouteSnapshot.normalizedEndpoint(validHTTP, service: .tenantAPI, allowDevelopmentEndpoints: false),
			validHTTP
		)
		XCTAssertEqual(
			IMRuntimeRouteSnapshot.normalizedEndpoint(validWS, service: .imRealtime, allowDevelopmentEndpoints: false),
			validWS
		)
		for raw in [
			"http://tenant.customer.net", "https://tenant.customer.net:444", "https://tenant",
			"https://127.0.0.1", "https://[::1]", "https://placeholder.customer.net",
			"https://tenant.example.com", "https://tenant.invalid",
		] {
			XCTAssertNil(
				IMRuntimeRouteSnapshot.normalizedEndpoint(raw, service: .tenantAPI, allowDevelopmentEndpoints: false),
				raw
			)
		}
		XCTAssertNil(
			IMRuntimeRouteSnapshot.normalizedEndpoint(
				"https://realtime.customer.net", service: .imRealtime, allowDevelopmentEndpoints: false
			)
		)
		XCTAssertEqual(
			IMRuntimeRouteSnapshot.normalizedEndpoint(
				"https://TENANT-API.Customer-Owned.NET:443/", service: .tenantAPI,
				allowDevelopmentEndpoints: false
			),
			"https://tenant-api.customer-owned.net:443"
		)
	}

	func testSnapshotRequiresExactReadyFourServiceRoutesAndBoundedCanonicalEndpoints() throws {
		let base = snapshot()
		func signed(
			services: [String: IMRuntimeRouteEndpointSet],
			status: String = "ready",
			source: String = "bootstrap"
		) throws -> IMRuntimeRouteSnapshot {
			let unsigned = IMRuntimeRouteSnapshot(
				contractVersion: 2, appID: base.appID, tenantID: base.tenantID, revision: 2,
				source: source, status: status, configHash: String(repeating: "0", count: 64),
				services: services, policy: base.policy
			)
			return IMRuntimeRouteSnapshot(
				contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: unsigned.tenantID,
				revision: unsigned.revision, source: source, status: status,
				configHash: try XCTUnwrap(unsigned.recomputedConfigHash), services: services, policy: unsigned.policy
			)
		}

		for routeStatus in ["missing", "backup_only", "READY"] {
			var services = base.services
			services["tenant_api"] = .init(
				preferred: ["https://tenant-primary.example.com"], backups: ["https://tenant-backup.example.net"],
				status: routeStatus, preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			)
			XCTAssertNil(try signed(services: services).validated(appID: base.appID, tenantID: base.tenantID))
		}
		XCTAssertNil(
			try signed(services: base.services, status: "missing").validated(appID: base.appID, tenantID: base.tenantID)
		)
		XCTAssertNil(
			try signed(services: base.services, source: " bootstrap ").validated(appID: base.appID, tenantID: base.tenantID)
		)

		var tooMany = base.services
		tooMany["tenant_api"] = .init(
			preferred: (0..<17).map { "https://tenant-\($0).example.com" }, backups: [],
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(try signed(services: tooMany).validated(appID: base.appID, tenantID: base.tenantID))
		var tooManyCombined = base.services
		tooManyCombined["tenant_api"] = .init(
			preferred: (0..<8).map { "https://tenant-\($0).example.com" },
			backups: (0..<9).map { "https://tenant-backup-\($0).example.net" },
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(
			try signed(services: tooManyCombined).validated(appID: base.appID, tenantID: base.tenantID)
		)

		var tooLong = base.services
		tooLong["tenant_api"] = .init(
			preferred: ["https://tenant.example.com/\(String(repeating: "a", count: 2_049))"], backups: [],
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(try signed(services: tooLong).validated(appID: base.appID, tenantID: base.tenantID))

		var nonRootHTTP = base.services
		nonRootHTTP["tenant_api"] = .init(
			preferred: ["https://tenant.example.com/api"], backups: [],
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(try signed(services: nonRootHTTP).validated(appID: base.appID, tenantID: base.tenantID))

		var duplicate = base.services
		duplicate["tenant_api"] = .init(
			preferred: ["https://tenant-primary.example.com"],
			backups: ["https://tenant-backup.example.net", "https://TENANT-BACKUP.example.net"],
			preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(try signed(services: duplicate).validated(appID: base.appID, tenantID: base.tenantID))

		var wrongPreferredSource = base.services
		wrongPreferredSource["im_api"] = .init(
			preferred: ["https://im-primary.example.com"], backups: ["https://im-backup.example.net"],
			preferredSource: "app_preferred", backupSource: "tenant_deployment_backup"
		)
		XCTAssertNil(
			try signed(services: wrongPreferredSource).validated(appID: base.appID, tenantID: base.tenantID)
		)

		var wrongEmptyBackupSource = base.services
		wrongEmptyBackupSource["im_api"] = .init(
			preferred: ["https://im-primary.example.com"], backups: [],
			preferredSource: "tenant_deployment_authority", backupSource: ""
		)
		XCTAssertNil(
			try signed(services: wrongEmptyBackupSource).validated(appID: base.appID, tenantID: base.tenantID)
		)
	}

	func testServerSourceTopologyCanonicalGoldenHash() throws {
		func route(_ preferred: String, _ backup: String, preferredSource: String, backupSource: String) -> [String: Any] {
			[
				"preferred": [preferred], "backups": [backup], "status": "ready",
				"preferred_source": preferredSource, "backup_source": backupSource,
			]
		}
		let payload: [String: Any] = [
			"route_source": "tenant.deployment.a3108a06-6077-4056-a346-f5e9aa58be95",
			"route_status": "ready",
			"routes": [
				"platform_api": route(
					"https://pingtai.wenxintongim.com", "https://dplatform123.cloudfront.net",
					preferredSource: "app_preferred",
					backupSource: "common_platform_backup"
				),
				"tenant_api": route(
					"https://api.wenxintongim.com", "https://dtenant123.cloudfront.net",
					preferredSource: "tenant_deployment_authority",
					backupSource: "tenant_deployment_backup"
				),
				"im_api": route(
					"https://api.wenxintongim.com", "https://dtenant123.cloudfront.net",
					preferredSource: "tenant_deployment_authority",
					backupSource: "tenant_deployment_backup"
				),
				"im_realtime": route(
					"wss://api.wenxintongim.com/im/ws", "wss://dtenant123.cloudfront.net/im/ws",
					preferredSource: "tenant_deployment_authority",
					backupSource: "tenant_deployment_backup"
				),
			],
		]
		let canonical = try JSONSerialization.data(
			withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
		)
		let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
		XCTAssertEqual(digest, "9547ac154e9d8c11dc3b029d954f5b867ab72aaa6d70bd495f374103d7acfadf")
	}

	func testFrozenRouteAuthorityRejectsCommonBackupForTenantDataPlane() throws {
		let base = snapshot()
		var invalidServices = base.services
		invalidServices["tenant_api"] = .init(
			preferred: ["https://tenant-primary.example.com"],
			backups: ["https://common-cf.example.net"],
			preferredSource: "tenant_deployment_authority",
			backupSource: "common_platform_backup"
		)
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: base.appID, tenantID: base.tenantID, revision: 2,
			source: base.source, status: base.status, configHash: String(repeating: "0", count: 64),
			services: invalidServices, policy: base.policy
		)
		let signed = IMRuntimeRouteSnapshot(
			contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: unsigned.tenantID,
			revision: unsigned.revision, source: unsigned.source, status: unsigned.status,
			configHash: try XCTUnwrap(unsigned.recomputedConfigHash), services: invalidServices, policy: unsigned.policy
		)
		XCTAssertNil(signed.validated(appID: base.appID, tenantID: base.tenantID))
	}

	func testAppBootstrapCanonicalHashCoversExactFourRoutesPreferredEndpointsAndPolicyV2() throws {
		let tenant = snapshot()
		XCTAssertEqual(tenant.configHash, "515ea2b77e827ce127654bbaeda39ce3ebdf1d110f89f4702ed496bb11e5549e")
		let services = appBootstrapServices()
		let preferred = services.mapValues(\.preferred)
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
			services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: preferred
		)
		let digest = try XCTUnwrap(unsigned.recomputedConfigHash)
		XCTAssertEqual(digest, "5f2d757ab208b16c49f00ab5949c25e9a0158caeb6bfd2779cfb2fd4f0bdce2f")
		let signed = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: digest,
			services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: preferred
		)
		XCTAssertNotNil(signed.validated(appID: "app-one", tenantID: nil))
		let incompletePreferred = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: digest,
			services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: ["platform_api": preferred["platform_api"]!]
		)
		XCTAssertNil(incompletePreferred.validated(appID: "app-one", tenantID: nil))
		let missingPolicyVersion = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: digest,
			services: services, policy: IMRuntimeRoutePolicy(contractVersion: 0), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: preferred
		)
		XCTAssertNil(missingPolicyVersion.validated(appID: "app-one", tenantID: nil))
		var invalidCommonTenantBackup = services
		invalidCommonTenantBackup["tenant_api"] = .init(
			preferred: ["https://tenant-primary.example.com"], backups: ["https://common-cf.example.net"],
			preferredSource: "app_preferred", backupSource: "common_platform_backup"
		)
		let invalidCommonUnsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
			services: invalidCommonTenantBackup, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com",
			preferredEndpoints: invalidCommonTenantBackup.mapValues(\.preferred)
		)
		let invalidCommon = IMRuntimeRouteSnapshot(
			contractVersion: invalidCommonUnsigned.contractVersion, appID: invalidCommonUnsigned.appID,
			tenantID: nil, revision: invalidCommonUnsigned.revision, source: invalidCommonUnsigned.source,
			status: invalidCommonUnsigned.status,
			configHash: try XCTUnwrap(invalidCommonUnsigned.recomputedConfigHash),
			services: invalidCommonTenantBackup, policy: invalidCommonUnsigned.policy,
			hashScope: .appBootstrap, bootstrapHost: invalidCommonUnsigned.bootstrapHost,
			preferredEndpoints: invalidCommonUnsigned.preferredEndpoints
		)
		XCTAssertNil(invalidCommon.validated(appID: "app-one", tenantID: nil))
		var changedRoutes = services
		changedRoutes["tenant_api"] = .init(
			preferred: ["https://changed.example.com"], backups: [],
			preferredSource: "app_preferred", backupSource: "common_platform_backup"
		)
		let changed = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: "app-one", tenantID: nil, revision: 1,
			source: "app_bootstrap", status: "ready", configHash: digest,
			services: changedRoutes, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: "bootstrap-one.example.com", preferredEndpoints: changedRoutes.mapValues(\.preferred)
		)
		XCTAssertNotEqual(changed.recomputedConfigHash, digest)
	}

	func testPackedRevisionLayoutFitsExactlyInJavaScriptSafeInteger() {
		let commonMax: UInt64 = (1 << 16) - 1
		let appMax: UInt64 = (1 << 18) - 1
		let tenantMax: UInt64 = (1 << 19) - 1
		let appPrelogin = ((commonMax << 18) | appMax) << 19
		let tenantPublished = appPrelogin | tenantMax
		XCTAssertEqual(appPrelogin & tenantMax, 0)
		XCTAssertEqual(tenantPublished, 9_007_199_254_740_991)
		XCTAssertNotNil(snapshot(revision: tenantPublished).validated(appID: "app-one", tenantID: "tenant-a"))
	}

    func testFiveSecondNetworkOnlyBoundaryAndFailClosedIdentityTLS() {
        let first = IMRuntimeRouteRequestWindow().recording(.connect, nowMS: 1_000)
        XCTAssertEqual(first.recording(.timeout, nowMS: 5_999).tier, .preferred)
        XCTAssertEqual(first.recording(.timeout, nowMS: 6_000).tier, .backup)
        for failure in [IMRuntimeRouteFailure.offline, .captivePortal, .authentication, .business, .cancelled,
                        .backgrounded, .websocketAuth, .websocketPreAckBusiness, .http(401), .http(403)] {
            XCTAssertEqual(failure.decision, .noFailover)
        }
		for failure in [IMRuntimeRouteFailure.tlsCertificate, .hostMismatch, .appIDMismatch, .tenantMismatch,
		                .configHashMismatch, .revisionRejected, .contractMismatch] {
            XCTAssertEqual(failure.decision, .failClosed)
        }
        for status in [502, 503, 504] { XCTAssertEqual(IMRuntimeRouteFailure.http(status).decision, .qualifiedNetwork) }
    }

	func testSelectorPreservesTenantDeploymentAuthorityThenBackupOrderAndSources() throws {
		let base = snapshot()
		var services = base.services
		services[IMRuntimeRouteService.tenantAPI.rawValue] = .init(
			preferred: ["https://app-fixture-api.wenxintongim.com"],
			backups: ["https://cf-backup.fixture.example"],
			status: "ready",
			preferredSource: "tenant_deployment_authority",
			backupSource: "tenant_deployment_backup"
		)
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: base.appID, tenantID: base.tenantID, revision: 2,
			source: base.source, status: base.status, configHash: String(repeating: "0", count: 64),
			services: services, policy: base.policy
		)
		let routes = IMRuntimeRouteSnapshot(
			contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: unsigned.tenantID,
			revision: unsigned.revision, source: unsigned.source, status: unsigned.status,
			configHash: try XCTUnwrap(unsigned.recomputedConfigHash), services: services, policy: unsigned.policy
		)
		XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
		let selector = IMRuntimeRouteSelector(store: store)
		XCTAssertEqual(selector.endpoints(routes, service: .tenantAPI), [
			"https://app-fixture-api.wenxintongim.com", "https://cf-backup.fixture.example"
		])
		let tenantRoute = try XCTUnwrap(routes.services[IMRuntimeRouteService.tenantAPI.rawValue])
		XCTAssertEqual(tenantRoute.preferredSource, "tenant_deployment_authority")
		XCTAssertEqual(tenantRoute.backupSource, "tenant_deployment_backup")
	}

	func testOnlyThreeConsecutiveQualifiedColdLaunchesEnterRecovery() {
        let routes = snapshot(); XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
        let selector = IMRuntimeRouteSelector(store: store)
        let qualified = IMRuntimeColdLaunchAttempt(processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
                                                   backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000)
        selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
        selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
		selector.recordColdLaunch(.init(processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
		                                backgroundedOrCancelled: false, qualifiedFailureDurationMS: 4_999), snapshot: routes, service: .tenantAPI)
		XCTAssertEqual(selector.endpoints(routes, service: .tenantAPI).first, "https://tenant-primary.example.com")
		selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
		XCTAssertEqual(selector.endpoints(routes, service: .tenantAPI).first, "https://tenant-primary.example.com")
		selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
		selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI)
        XCTAssertEqual(IMRuntimeRouteSelector(store: IMRuntimeRouteStore(defaults: defaults)).endpoints(routes, service: .tenantAPI).first,
                       "https://tenant-backup.example.net")
        XCTAssertFalse(selector.recovery(routes, service: .imAPI).recovery)
    }

    func testStableSpacedHTTPAndAcknowledgedRealtimeFailback() {
        let routes = snapshot(); _ = store.apply(routes, appID: routes.appID, tenantID: routes.tenantID)
        let selector = IMRuntimeRouteSelector(store: store)
        let qualified = IMRuntimeColdLaunchAttempt(processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
                                                   backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000)
        for _ in 0..<3 { selector.recordColdLaunch(qualified, snapshot: routes, service: .tenantAPI) }
        selector.recordPreferredProbe(snapshot: routes, service: .tenantAPI, kind: .http, succeeded: true, stableMS: 30_000, nowMS: 100_000)
        selector.recordPreferredProbe(snapshot: routes, service: .tenantAPI, kind: .http, succeeded: true, stableMS: 30_000, nowMS: 129_999)
        XCTAssertTrue(selector.recovery(routes, service: .tenantAPI).recovery)
        selector.recordPreferredProbe(snapshot: routes, service: .tenantAPI, kind: .http, succeeded: true, stableMS: 30_000, nowMS: 130_000)
        XCTAssertFalse(selector.recovery(routes, service: .tenantAPI).recovery)
        for _ in 0..<3 { selector.recordColdLaunch(qualified, snapshot: routes, service: .imRealtime) }
        selector.recordPreferredProbe(snapshot: routes, service: .imRealtime, kind: .realtime, succeeded: true, stableMS: 30_000, nowMS: 200_000)
        XCTAssertTrue(selector.recovery(routes, service: .imRealtime).recovery)
        selector.recordPreferredProbe(snapshot: routes, service: .imRealtime, kind: .realtime, succeeded: true, stableMS: 30_000, nowMS: 230_000, connectAcknowledged: true)
        XCTAssertFalse(selector.recovery(routes, service: .imRealtime).recovery)
    }

	func testOnlyFourSelectorServicesAndAppLevelWebSocketOwnershipDedupe() {
        XCTAssertEqual(Set(snapshot().services.keys), Set(["platform_api", "tenant_api", "im_api", "im_realtime"]))
		XCTAssertFalse(snapshot().services.keys.contains("oss")); XCTAssertFalse(snapshot().services.keys.contains("turn"))
		let continuity = IMRuntimeWebSocketContinuity(); XCTAssertTrue(continuity.acquire("owner-a")); XCTAssertFalse(continuity.acquire("owner-b"))
		XCTAssertTrue(continuity.accept(messageID: "message-1")); XCTAssertFalse(continuity.accept(messageID: "message-1"))
		continuity.release("owner-a")
		XCTAssertTrue(continuity.acquire("owner-b"))
	}

	func testConcurrentStoresDoNotLoseRecoveryCountersAndLogoutDoesNotClearRoutes() async {
		let routes = snapshot()
		XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
		let attempt = IMRuntimeColdLaunchAttempt(
			processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
			backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000
		)
		let defaultsBox = RuntimeRoutesDefaultsBox(defaults)
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<24 {
				group.addTask {
					let selector = IMRuntimeRouteSelector(store: IMRuntimeRouteStore(defaults: defaultsBox.value))
					selector.recordColdLaunch(attempt, snapshot: routes, service: .tenantAPI)
				}
			}
		}
		let restarted = IMRuntimeRouteStore(defaults: defaults)
		XCTAssertEqual(
			restarted.record(appID: routes.appID, tenantID: routes.tenantID)
				.recoveryByService[IMRuntimeRouteService.tenantAPI.rawValue]?.consecutiveQualifiedColdLaunchFailures,
			24
		)
		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		XCTAssertEqual(restarted.record(appID: routes.appID, tenantID: routes.tenantID).current?.revision, 1)
	}
}

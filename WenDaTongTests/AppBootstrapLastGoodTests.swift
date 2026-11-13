import Foundation
import CryptoKit
import XCTest
@testable import WenDaTong

extension RuntimeRoutesP0Tests {
	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	func testLastGoodCacheIsIsolatedByServingHostAndAppID() throws { // WDT_IOS1_WIRE83_FIXTURE_ISOLATION_20261111_BEGIN
		let suite = "AppBootstrapServingHost.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		defer { IMAppBootstrapLastGoodStore.clearAll(defaults: defaults) }
		let first = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: "active.example.com", revision: 30
		)
		let second = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: "active.example.com", revision: 31
		)
		IMAppBootstrapLastGoodStore.save(
			first, appID: "app-one", servingHost: "carrier-one.example.com", defaults: defaults
		)
		IMAppBootstrapLastGoodStore.save(
			second, appID: "app-one", servingHost: "carrier-two.example.com", defaults: defaults
		)

		XCTAssertEqual(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", servingHosts: ["carrier-one.example.com"], defaults: defaults
			).map(\.bootstrap.routeRevision),
			[30]
		)
		XCTAssertEqual(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", servingHosts: ["carrier-two.example.com"], defaults: defaults
			).map(\.bootstrap.routeRevision),
			[31]
		)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "other-app", servingHosts: ["carrier-one.example.com", "carrier-two.example.com"], defaults: defaults
			).isEmpty
		)
	} // WDT_IOS1_WIRE83_FIXTURE_ISOLATION_20261111_END

	func testLastGoodCacheRequiresExactEnvironmentIncludingEmptyScopeAndLegacyV2() throws {
		let defaults = UserDefaults(suiteName: "AppBootstrapEnvironment.\(UUID().uuidString)")!
		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		defer { IMAppBootstrapLastGoodStore.clearAll(defaults: defaults) }
		let host = "carrier-one.example.com"
		let scoped: [(environment: String, revision: UInt64)] = [
			("", 41), ("production", 42), ("staging", 43),
		]
		for item in scoped {
			let bootstrap = try appBootstrapFixture(
				appID: "app-one",
				bootstrapHost: host,
				revision: item.revision,
				environment: item.environment.isEmpty ? nil : item.environment
			)
			IMAppBootstrapLastGoodStore.save(
				bootstrap,
				appID: "app-one",
				environment: item.environment,
				servingHost: host,
				defaults: defaults
			)
		}

		for item in scoped {
			XCTAssertEqual(
				IMAppBootstrapLastGoodStore.snapshots(
					appID: "app-one",
					environment: item.environment,
					servingHosts: [host],
					defaults: defaults
				).map(\.bootstrap.routeRevision),
				[item.revision]
			)
		}

		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		let legacy = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: host, revision: 44, environment: "production"
		)
		try writeLegacyV2AppBootstrapCache(
			legacy, environment: "production", defaults: defaults
		)
		XCTAssertEqual(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "production", defaults: defaults
			).map(\.bootstrap.routeRevision),
			[44]
		)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "", defaults: defaults
			).isEmpty
		)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "staging", defaults: defaults
			).isEmpty
		)

		let mismatched = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: host, revision: 45, environment: "production"
		)
		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		IMAppBootstrapLastGoodStore.save(
			mismatched,
			appID: "app-one",
			environment: "",
			servingHost: host,
			defaults: defaults
		)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "production", defaults: defaults
			).isEmpty,
			"an explicit empty v3 scope must not be replaced by the payload environment"
		)

		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		try writeLegacyV2AppBootstrapCache(mismatched, environment: "", defaults: defaults)
		XCTAssertTrue(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "production", defaults: defaults
			).isEmpty,
			"an explicit empty v2 scope must not be replaced by the payload environment"
		)

		IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
		try writeLegacyV1AppBootstrapCache(mismatched, defaults: defaults)
		XCTAssertEqual(
			IMAppBootstrapLastGoodStore.snapshots(
				appID: "app-one", environment: "production", defaults: defaults
			).map(\.bootstrap.routeRevision),
			[45],
			"v1 has no environment field and may use its payload environment for migration"
		)
	}

	func testExplicitEmptyCacheScopeWithProductionPayloadCannotRestoreAfterLiveFailure() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let base = URL(string: "https://carrier-one.example.com")!
		let mismatched = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: base.host!, revision: 46, environment: "production"
		)
		IMAppBootstrapLastGoodStore.save(
			mismatched,
			appID: "app-one",
			environment: "",
			servingHost: base.host
		)
		try writeLegacyV2AppBootstrapCache(mismatched, environment: "", defaults: .standard)
		let clock = AppBootstrapTestClock(nowMS: 48_500)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [.failure(.dnsLookupFailed, advanceMS: 1)]
		)
		let client = makeAppBootstrapClient(
			bases: [base], transport: transport, clock: clock, networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one")
			XCTFail("scope/payload environment mismatch must not restore last-good")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), [base.host])
	}

	func testSameHostSameRevisionLegacyHashConflictBlocksLastGoodFallback() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let base = URL(string: "https://carrier-one.example.com")!
		let current = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: base.host!, revision: 50
		)
		let conflicting = try appBootstrapFixture(
			appID: "app-one",
			bootstrapHost: base.host!,
			revision: 50,
			platformEndpoint: "https://platform-conflict.example.com"
		)
		IMAppBootstrapLastGoodStore.save(
			current, appID: "app-one", servingHost: base.host
		)
		try writeLegacyV2AppBootstrapCache(conflicting, environment: "", defaults: .standard)
		let clock = AppBootstrapTestClock(nowMS: 49_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [.failure(.dnsLookupFailed, advanceMS: 1)]
		)
		let client = makeAppBootstrapClient(
			bases: [base],
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one")
			XCTFail("same revision with different hashes must fail closed")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), [base.host])
	}

	func testSameHostSameRevisionSameHashAcrossV3AndLegacyV2CanFallback() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let base = URL(string: "https://carrier-one.example.com")!
		let cached = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: base.host!, revision: 51
		)
		IMAppBootstrapLastGoodStore.save(
			cached, appID: "app-one", servingHost: base.host
		)
		try writeLegacyV2AppBootstrapCache(cached, environment: "", defaults: .standard)
		let clock = AppBootstrapTestClock(nowMS: 50_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [.failure(.dnsLookupFailed, advanceMS: 1)]
		)
		let client = makeAppBootstrapClient(
			bases: [base],
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one")

		XCTAssertEqual(resolved.routeRevision, 51)
		XCTAssertEqual(resolved.configHash, cached.configHash)
	}

	func testExpiredHigherRevisionPreventsFallbackToFreshLowerRevision() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let now = Date()
		let lower = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: bases[0].host!, revision: 30, ttlSeconds: 300
		)
		let higher = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: bases[0].host!, revision: 31, ttlSeconds: 30
		)
		IMAppBootstrapLastGoodStore.save(
			lower, appID: "app-one", servingHost: bases[0].host, now: now
		)
		IMAppBootstrapLastGoodStore.save(
			higher, appID: "app-one", servingHost: bases[1].host,
			now: now.addingTimeInterval(-60)
		)
		let clock = AppBootstrapTestClock(nowMS: 46_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.dnsLookupFailed, advanceMS: 1),
			.failure(.cannotConnectToHost, advanceMS: 1),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one")
			XCTFail("an expired higher high-water revision must block a fresh lower fallback")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
	}

	func testColdStartRestoresActiveOriginsAheadOfPackagedCarriers() throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let packaged = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let active = ["active-one.example.com", "active-two.example.com"]
		let appID = IMAPIContext.canonicalIOSAppID
		let cached = try appBootstrapFixture(
			appID: appID,
			bootstrapHost: active[0],
			domains: active,
			revision: 40
		)
		IMAppBootstrapLastGoodStore.save(
			cached,
			appID: appID,
			environment: IMAPIClient.configuredAppBootstrapEnvironment(),
			servingHost: packaged[0].host
		)
		let clock = AppBootstrapTestClock(nowMS: 48_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [])

		let client = makeAppBootstrapClient(
			bases: packaged,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		XCTAssertEqual(
			client.configuredAppBootstrapBases.map(\.host),
			active + packaged.compactMap(\.host)
		)
		XCTAssertTrue(transport.requests.isEmpty)
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

	func testNetworkFailureWithInvalidLastGoodAndNoBackupFailsClosed() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let valid = try appBootstrapFixture(appID: "app-one", bootstrapHost: primary.host!)
		let invalid = RemoteAppBootstrap(
			appID: valid.appID, displayName: valid.displayName, platform: valid.platform, status: valid.status,
			bootstrapHost: valid.bootstrapHost, appDomain: valid.appDomain, configVersion: valid.configVersion,
			ttlSeconds: valid.ttlSeconds, directory: valid.directory, legal: valid.legal,
			configHash: String(repeating: "f", count: 64), contractVersion: valid.contractVersion,
			routeRevision: valid.routeRevision, routeSource: valid.routeSource, routeStatus: valid.routeStatus,
			routes: valid.routes, preferredEndpoints: valid.preferredEndpoints, routingPolicy: valid.routingPolicy
		)
		IMAppBootstrapLastGoodStore.save(invalid, appID: "app-one")
		let clock = AppBootstrapTestClock(nowMS: 50_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.cannotFindHost, advanceMS: 5),
		])
		let client = makeAppBootstrapClient(
			primary: primary, backup: nil, transport: transport, clock: clock,
			networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one")
			XCTFail("an invalid last-good Bootstrap contract must fail closed")
		} catch {}
		XCTAssertEqual(transport.requests.map(\.host), [primary.host])
	}

	func makeAppBootstrapClient(
		primary: URL,
		backup: URL?,
		transport: HTTPTransport,
		clock: AppBootstrapTestClock,
		networkReachable: @escaping @MainActor @Sendable () -> Bool
	) -> IMAPIClient {
		makeAppBootstrapClient(
			bases: [primary] + (backup.map { [$0] } ?? []),
			transport: transport,
			clock: clock,
			networkReachable: networkReachable
		)
	}

	func makeAppBootstrapClient(
		bases: [URL],
		transport: HTTPTransport,
		clock: AppBootstrapTestClock,
		networkReachable: @escaping @MainActor @Sendable () -> Bool,
		runtimeRouteStore: IMRuntimeRouteStore? = nil
	) -> IMAPIClient {
		let defaults = UserDefaults(suiteName: "AppBootstrapRuntimeRoutes.\(UUID().uuidString)")!
		return IMAPIClient(
			platformBase: IMAPIClient.releasePlaceholderPlatformBase,
			tenantBase: URL(string: "https://tenant-seed.example.test")!,
			imBase: URL(string: "https://im-seed.example.test")!,
			bootstrapBases: bases,
			httpTransport: transport,
			runtimeRouteStore: runtimeRouteStore ?? IMRuntimeRouteStore(defaults: defaults),
			runtimeMonotonicNowMS: { clock.now() },
			runtimeSleep: { clock.advance(by: $0) },
			bootstrapNetworkReachable: networkReachable
		)
	}

	private func writeLegacyV2AppBootstrapCache(
		_ bootstrap: RemoteAppBootstrap,
		environment: String,
		defaults: UserDefaults,
		savedAt: Date = Date()
	) throws {
		let bootstrapObject = try JSONSerialization.jsonObject(
			with: JSONEncoder().encode(bootstrap)
		)
		let scopeKey = "\(environment)\u{0}\(bootstrap.appID)"
		let payload: [String: Any] = [
			scopeKey: [
				"bootstrap": bootstrapObject,
				"savedAt": savedAt.timeIntervalSince1970,
			],
		]
		defaults.set(
			try JSONSerialization.data(withJSONObject: payload),
			forKey: "im2.appBootstrap.lastGood.v2"
		)
	}

	private func writeLegacyV1AppBootstrapCache(
		_ bootstrap: RemoteAppBootstrap,
		defaults: UserDefaults,
		savedAt: Date = Date()
	) throws {
		let bootstrapObject = try JSONSerialization.jsonObject(
			with: JSONEncoder().encode(bootstrap)
		)
		let payload: [String: Any] = [
			bootstrap.appID: [
				"bootstrap": bootstrapObject,
				"savedAt": savedAt.timeIntervalSince1970,
			],
		]
		defaults.set(
			try JSONSerialization.data(withJSONObject: payload),
			forKey: "im2.appBootstrap.lastGood.v1"
		)
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	func appBootstrapEnvelopeData(
		appID: String,
		bootstrapHost: String,
		domains: [String]? = nil,
		revision: UInt64 = 7,
		platformEndpoint: String = "https://platform-primary.example.com",
		environment: String? = nil
	) throws -> Data {
		let bootstrap = try appBootstrapFixture(
			appID: appID,
			bootstrapHost: bootstrapHost,
			domains: domains,
			revision: revision,
			platformEndpoint: platformEndpoint,
			environment: environment
		)
		let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bootstrap))
		return try JSONSerialization.data(withJSONObject: ["ok": true, "data": object])
	}

	func appBootstrapFixture(
		appID: String,
		bootstrapHost: String,
		domains: [String]? = nil,
		revision: UInt64 = 7,
		platformEndpoint: String = "https://platform-primary.example.com",
		ttlSeconds: Int = 300,
		environment: String? = nil
	) throws -> RemoteAppBootstrap {
		var services = appBootstrapServices()
		services[IMRuntimeRouteService.platformAPI.rawValue] = .init(
			preferred: [platformEndpoint],
			backups: ["https://platform-backup.example.com"],
			status: "ready",
			preferredSource: "app_preferred",
			backupSource: "common_platform_backup"
		)
		let preferred = services.mapValues(\.preferred)
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: appID, tenantID: nil, revision: revision,
			source: "app_bootstrap", status: "ready", configHash: String(repeating: "0", count: 64),
			services: services, policy: IMRuntimeRoutePolicy(), hashScope: .appBootstrap,
			bootstrapHost: bootstrapHost, preferredEndpoints: preferred
		)
		let configHash = try XCTUnwrap(unsigned.recomputedConfigHash)
		return RemoteAppBootstrap(
			appID: appID, displayName: "App One", platform: "ios", status: "enabled",
			domains: domains ?? (bootstrapHost.isEmpty ? [] : [bootstrapHost]),
			bootstrapHost: bootstrapHost, appDomain: bootstrapHost, configVersion: "\(revision)",
			ttlSeconds: ttlSeconds,
			directory: .init(apiBaseURL: platformEndpoint), configHash: configHash,
			contractVersion: 2, routeRevision: revision, routeSource: "app_bootstrap", routeStatus: "ready",
			routes: services, preferredEndpoints: preferred, routingPolicy: IMRuntimeRoutePolicy(),
			environment: environment
		)
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
}

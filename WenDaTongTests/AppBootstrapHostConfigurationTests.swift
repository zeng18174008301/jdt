import Foundation
import CryptoKit
import XCTest
@testable import WenDaTong

extension RuntimeRoutesP0Tests {
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    func testRouteV5LaunchOverrideWinsOverPackagedDefaultsPerService() throws {
        let suite = "RouteV5BuildDefaults.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "WXTHTTPRouteV5Defaults") as? [String: String])
        let services = ["public_bootstrap", "platform_api", "tenant_api", "im_api"]
        XCTAssertEqual(Set(flags.keys), Set(services))
        XCTAssertTrue(flags.values.allSatisfy { ["YES", "NO"].contains($0) })
        let packaged = ["public_bootstrap": "YES", "platform_api": "YES", "tenant_api": "NO", "im_api": "NO"]
        let store = IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: [
            "-WXT.RouteV5.im_api", "YES", "-WXT.RouteV5.im_api", "invalid",
            "-WXT.RouteV5.public_bootstrap", "NO", "-WXT.RouteV5.other", "YES",
            "-WXT.RouteV5.tenant_api"
        ], buildDefaultsForTesting: packaged)
        XCTAssertEqual(Set(services.filter(store.routeV5Enabled)), ["platform_api", "im_api"])
        XCTAssertFalse(store.routeV5Enabled("other"))
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

	func testAppBootstrapHostConfigurationKeepsLegacyPairCompatibilityAndLeavesApp2Unconfigured() throws {
		let app1 = IMAppBootstrapHostConfigurationLoader.load(
			info: [
				"WXTAppBootstrapBaseURL": "https://bootstrap.wdatongcf.com",
				"WXTAppBootstrapBackupBaseURL": "",
			],
			appID: "jianhuitong-ios"
		)
		guard case .configured(let app1Configuration) = app1 else {
			return XCTFail("App1 must have a configured ordered Bootstrap candidate set")
		}
		XCTAssertEqual(app1Configuration.primary.host, "bootstrap.wdatongcf.com")
		XCTAssertNil(app1Configuration.backup)

		XCTAssertEqual(
			IMAppBootstrapHostConfigurationLoader.load(
				info: ["WXTAppBootstrapBaseURL": "", "WXTAppBootstrapBackupBaseURL": ""],
				appID: "WXT_UNCONFIGURED_APP2"
			),
			.unconfigured
		)
		XCTAssertEqual(
			IMAppBootstrapHostConfigurationLoader.load(
				info: [
					"WXTAppBootstrapBaseURL": "",
					"WXTAppBootstrapBackupBaseURL": "https://backup.example.test",
				],
				appID: "app-one"
			),
			.blocked
		)
		XCTAssertEqual(
			IMAppBootstrapHostConfigurationLoader.load(
				info: [
					"WXTAppBootstrapBaseURL": "https://same.example.test",
					"WXTAppBootstrapBackupBaseURL": "https://same.example.test",
				],
				appID: "app-one"
			),
			.blocked
		)
	}

	func testAppBootstrapHostConfigurationAcceptsUpToFivePackagedOrigins() throws {
		let frozen = [
				"https://bootstrap.wdatong.com",
				"https://bootstrap.wdatongcf.com",
		]
		for values in [
			[frozen[0]],
			frozen,
			frozen + ["https://third.example.com"],
			frozen + ["https://third.example.com", "https://fourth.example.com"],
            // WDT_IOS1_HTTP_ROUTE_V5_20261113: fifth build slot for public Bootstrap only.
            frozen + ["https://third.example.com", "https://fourth.example.com", "https://fifth.example.com"],
		] {
			let plan = IMAppBootstrapHostConfigurationLoader.load(
				info: ["WXTAppBootstrapBaseURLs": values],
				appID: "jianhuitong-ios"
			)
			guard case .configured(let configuration) = plan else {
				return XCTFail("ordered configuration with \(values.count) entries must be accepted")
			}
			XCTAssertEqual(configuration.orderedBases.map(\.absoluteString), values)
		}

		let formal = IMAppBootstrapHostConfigurationLoader.load(
			info: [
				"WXTAppBootstrapBaseURLs": frozen,
				"WXTAppBootstrapBaseURL": frozen[0],
				"WXTAppBootstrapBackupBaseURL": frozen[1],
			],
			appID: "jianhuitong-ios"
		)
		guard case .configured(let formalConfiguration) = formal else {
			return XCTFail("formal App1 bootstrap list must be configured")
		}
		XCTAssertEqual(formalConfiguration.orderedBases.map(\.absoluteString), frozen)

		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		let backendDefaultThird = [
			"https://bootstrap-one.example.com",
			"https://bootstrap-two.example.com",
			"https://bootstrap-three.example.com",
		]
		let relaxedLegacyOrder = IMAppBootstrapHostConfigurationLoader.load(
			info: [
				"WXTAppBootstrapBaseURLs": backendDefaultThird,
				"WXTAppBootstrapBaseURL": backendDefaultThird[2],
				"WXTAppBootstrapBackupBaseURL": backendDefaultThird[0],
			],
			appID: "jianhuitong-ios"
		)
		guard case .configured(let relaxedConfiguration) = relaxedLegacyOrder else {
			return XCTFail("legacy primary/backup must not force the ordered candidate positions")
		}
		XCTAssertEqual(relaxedConfiguration.orderedBases.map(\.absoluteString), backendDefaultThird)
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

		for invalid in [
			frozen + [
				"https://third.example.com", "https://fourth.example.com", "https://fifth.example.com", "https://sixth.example.com",
			],
			[frozen[0], "HTTPS://BOOTSTRAP.WDATONG.COM:443/"],
			["https://127.0.0.1"],
			["https://single-label"],
			["https://placeholder.example.com"],
			["https://bootstrap.example.invalid"],
			["https://bootstrap.example.com:8443"],
			["https://bootstrap.example.com/path"],
			["https://bootstrap.example.com/%2e%2e/escape"],
			["https://bootstrap.example.com?query=value"],
			["https://bootstrap.example.com#fragment"],
			["https://user@bootstrap.example.com"],
		] {
			XCTAssertEqual(
				IMAppBootstrapHostConfigurationLoader.load(
					info: ["WXTAppBootstrapBaseURLs": invalid],
					appID: "jianhuitong-ios"
				),
				.blocked,
				"invalid=\(invalid)"
			)
		}
	}

	func testPackagedApp1BootstrapOrderMatchesTheFrozenTwoOrigins() throws {
		let expected = [
				"https://bootstrap.wdatong.com",
				"https://bootstrap.wdatongcf.com",
			]
		let plan = IMAppBootstrapHostConfigurationLoader.load(
			info: try XCTUnwrap(Bundle.main.infoDictionary),
			appID: "jianhuitong-ios"
		)
		guard case .configured(let configuration) = plan else {
			return XCTFail("packaged App1 bootstrap list must be configured")
		}
		XCTAssertEqual(configuration.orderedBases.map(\.absoluteString), expected)
	}

	func testAppBootstrapAnyOriginPolicyUsesThreeSecondPerOriginAndThirtySecondMaximumBudget() {
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.perOriginFailureBudgetMS, 3_000)
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(
			[
				IMRuntimeRouteFailure.dns, .connect, .timeout, .reset, .tlsCertificate,
				.hostMismatch, .appIDMismatch, .configHashMismatch, .contractMismatch,
			].map(IMAppBootstrapFailoverPolicy.decision),
			Array(repeating: .qualifiedNetwork, count: 9)
		)
		for status in [100, 200, 301, 400, 401, 403, 404, 408, 429, 500, 502, 503, 504] {
			XCTAssertEqual(IMAppBootstrapFailoverPolicy.decision(for: .http(status)), .qualifiedNetwork)
		}
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		for failure in [
			IMRuntimeRouteFailure.offline, .captivePortal, .authentication, .business, .cancelled,
			.backgrounded, .websocketAuth, .websocketPreAckBusiness,
		] {
			XCTAssertEqual(IMAppBootstrapFailoverPolicy.decision(for: failure), .noFailover)
		}
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.decision(for: .revisionRejected), .failClosed)
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 1), 3_000)
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 4), 12_000)
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 5), 15_000)
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 9), 27_000)
		XCTAssertEqual(IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(originCount: 10), 30_000) // WDT_IOS1_HTTP_ROUTE_V5_20261113
	}

	func testAppBootstrapQuickQualifiedFailureImmediatelyTriesSecondOriginExactlyOnce() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let clock = AppBootstrapTestClock(nowMS: 10_000)
		let response = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!),
			isHTTPResponse: true,
			statusCode: 200
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.cannotFindHost, advanceMS: 5),
			.response(response, advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			primary: primary, backup: backup, transport: transport, clock: clock,
			networkReachable: { true }
		)

		let bootstrap = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(bootstrap.bootstrapHost, primary.host)
		XCTAssertEqual(client.configuredAppBootstrapPrimaryBase, primary)
		XCTAssertEqual(client.configuredAppBootstrapBackupBase, backup)
		XCTAssertEqual(client.configuredAppBootstrapBases, [primary, backup])
		XCTAssertEqual(transport.requests.map(\.host), [primary.host, backup.host])
		XCTAssertEqual(transport.requests.map(\.atMS), [10_000, 10_005])
		XCTAssertEqual(
			transport.requests.map(\.path),
			Array(
				repeating: "/.well-known/wenxintong-app.json?app_id=app-one",
				count: 2
			)
		)
	}

	func testAppBootstrapCandidateOneTwo404ThenCandidateThreeSelfHostSucceeds() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...4).map { URL(string: "https://bootstrap-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 60_000)
		let response = HTTPTransportResult(
			// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: bases[2].host!),
			// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
			isHTTPResponse: true,
			statusCode: 200
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
			.response(.init(data: Data(), isHTTPResponse: true, statusCode: 404), advanceMS: 3_000),
			.response(.init(data: Data(), isHTTPResponse: true, statusCode: 404), advanceMS: 3_000),
			.response(response, advanceMS: 0),
			// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let bootstrap = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(
			client.configuredAppBootstrapBases,
			[bases[2], bases[0], bases[1], bases[3]]
		)
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(bootstrap.bootstrapHost, bases[2].host)
		XCTAssertEqual(transport.requests.map(\.host), Array(bases.prefix(3)).map(\.host))
		XCTAssertEqual(transport.requests.map(\.atMS), [60_000, 63_000, 66_000])
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		XCTAssertEqual(
			transport.requests.map(\.path),
			Array(repeating: "/.well-known/wenxintong-app.json?app_id=app-one", count: 3)
		)
	}

	func testAppBootstrapRequiresExactHTTP200AndAdvancesPast201And206() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...3).map { URL(string: "https://bootstrap-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 60_000)
		let data = try appBootstrapEnvelopeData(
			appID: "app-one",
			bootstrapHost: bases[0].host!,
			domains: [bases[0].host!]
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.response(.init(data: data, isHTTPResponse: true, statusCode: 201), advanceMS: 1),
			.response(.init(data: data, isHTTPResponse: true, statusCode: 206), advanceMS: 1),
			.response(.init(data: data, isHTTPResponse: true, statusCode: 200), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.bootstrapHost, bases[0].host)
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	func testPackagedCarrierAcceptsActiveDomainsThatExcludeItsServingHostAndMergesStableOrder() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let packaged = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let active = ["active-one.example.com", "active-two.example.com"]
		let clock = AppBootstrapTestClock(nowMS: 62_000)
		let response = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(
				appID: "app-one", bootstrapHost: active[0], domains: active
			),
			isHTTPResponse: true,
			statusCode: 200
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [.response(response, advanceMS: 0)])
		let client = makeAppBootstrapClient(
			bases: packaged,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let bootstrap = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(bootstrap.bootstrapHost, active[0])
		XCTAssertEqual(transport.requests.map(\.host), [packaged[0].host])
		XCTAssertEqual(
			client.configuredAppBootstrapBases.map(\.host),
			active + packaged.compactMap(\.host)
		)
	}

	func testLegacyPayloadWithoutDomainsStillAcceptsAnyPackagedBootstrapHost() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let packaged = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 63_000)
		let data = try appBootstrapEnvelopeData(
			appID: "app-one",
			bootstrapHost: packaged[1].host!,
			domains: []
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.response(.init(data: Data(), isHTTPResponse: true, statusCode: 404), advanceMS: 1),
			.response(.init(data: data, isHTTPResponse: true, statusCode: 200), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: packaged,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.bootstrapHost, packaged[1].host)
		XCTAssertEqual(client.configuredAppBootstrapBases, [packaged[1], packaged[0]])
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
}

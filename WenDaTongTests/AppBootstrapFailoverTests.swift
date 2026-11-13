import Foundation
import IM4Core // WDT_IOS1_HTTP_ROUTE_V5_20261113
import CryptoKit
import XCTest
@testable import WenDaTong

extension RuntimeRoutesP0Tests {
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    func testFivePackagedFailuresUseFifteenSecondsAndSixOriginsAreRejected() async throws {
        IMAppBootstrapLastGoodStore.clearAll()
        defer { IMAppBootstrapLastGoodStore.clearAll() }
        let bases = (1...6).map { URL(string: "https://bootstrap-\($0).example.com")! }
        let clock = AppBootstrapTestClock(nowMS: 70_000)
        let transport = AppBootstrapFailoverTransport(
            clock: clock, outcomes: Array(repeating: .failure(.timedOut, advanceMS: 3_000), count: 5)
        )
        let five = Array(bases.prefix(5))
        let client = makeAppBootstrapClient(bases: five, transport: transport, clock: clock, networkReachable: { true })
        do {
            _ = try await client.appBootstrap(appID: "app-one", forceRefresh: true)
            XCTFail("expected the five unreachable origins to fail")
        } catch {}
        XCTAssertEqual(transport.requests.map(\.host), five.map(\.host))
        XCTAssertEqual(clock.now(), 85_000)
        XCTAssertNil(IMAppBootstrapHostConfiguration(packagedOrderedBases: bases))

        let downloaded = (1...5).map { URL(string: "https://active-\($0).example.com")! }
        XCTAssertEqual(IMAPIClient.mergedBootstrapHostConfiguration(platformBases: downloaded,
            packaged: try XCTUnwrap(IMAppBootstrapHostConfiguration(packagedOrderedBases: five)))?.orderedBases.count, 10)
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

	func testAppBootstrapContinuesAfterCandidateFailureEvenWhenReachabilityTurnsOffline() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let clock = AppBootstrapTestClock(nowMS: 20_000)
		let success = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!),
			isHTTPResponse: true,
			statusCode: 200
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.cannotConnectToHost, advanceMS: 3_000),
			.response(success, advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			primary: primary, backup: backup, transport: transport, clock: clock,
			networkReachable: { clock.now() < 23_000 }
		)

		_ = try await client.appBootstrap(appID: "app-one", forceRefresh: true)
		XCTAssertEqual(transport.requests.map(\.host), [primary.host, backup.host])
		XCTAssertEqual(clock.now(), 23_000)
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	func testAppBootstrapCandidateLevelFailuresTryNextPinnedOrigin() async throws {
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let validData = try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!)
		let backupSuccess = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!),
			isHTTPResponse: true,
			statusCode: 200
		)
		let cases: [[AppBootstrapFailoverTransport.Outcome]] = [
			[.response(.init(data: Data(), isHTTPResponse: true, statusCode: 404), advanceMS: 1)],
			[.response(.init(data: Data(), isHTTPResponse: true, statusCode: 503), advanceMS: 3_000)],
			[.failure(.serverCertificateUntrusted, advanceMS: 3_000)],
			[.failure(.notConnectedToInternet, advanceMS: 3_000)],
			[.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one",
					bootstrapHost: "wrong-bootstrap.example.test",
					domains: [primary.host!]
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 3_000)],
			[.response(.init(
				data: try appBootstrapEnvelopeData(appID: "other-app", bootstrapHost: primary.host!),
				isHTTPResponse: true,
				statusCode: 200
			), advanceMS: 3_000)],
			[.response(.init(
				data: validData, isHTTPResponse: true, statusCode: 200,
				responseURL: URL(string: "https://redirected.example.test/.well-known/wenxintong-app.json")!
			), advanceMS: 3_000)],
		]
		for outcomes in cases {
			IMAppBootstrapLastGoodStore.clearAll()
			let clock = AppBootstrapTestClock(nowMS: 30_000)
			let transport = AppBootstrapFailoverTransport(
				clock: clock,
				outcomes: outcomes + [.response(backupSuccess, advanceMS: 0)]
			)
			let client = makeAppBootstrapClient(
				primary: primary, backup: backup, transport: transport, clock: clock,
				networkReachable: { true }
			)

			let bootstrap = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

			XCTAssertEqual(bootstrap.bootstrapHost, primary.host)
			XCTAssertEqual(transport.requests.map(\.host), [primary.host, backup.host])
		}
		IMAppBootstrapLastGoodStore.clearAll()
	}

	func testAppBootstrapBusinessFailuresAdvanceToNextOrigin() async throws {
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let success = HTTPTransportResult(
			data: try appBootstrapEnvelopeData(appID: "app-one", bootstrapHost: primary.host!),
			isHTTPResponse: true,
			statusCode: 200
		)
		let cases: [AppBootstrapFailoverTransport.Outcome] = [
			.response(.init(
				data: Data(#"{"ok":false,"error":{"code":"app_disabled","message":"disabled"}}"#.utf8),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 3_000),
			.response(.init(
				data: Data(#"{"ok":false,"error":{"code":"prelogin_bootstrap_signature_invalid","message":"signature rejected"}}"#.utf8),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 3_000),
		]
		for failure in cases {
			IMAppBootstrapLastGoodStore.clearAll()
			let clock = AppBootstrapTestClock(nowMS: 30_000)
			let transport = AppBootstrapFailoverTransport(
				clock: clock,
				outcomes: [failure, .response(success, advanceMS: 0)]
			)
			let client = makeAppBootstrapClient(
				primary: primary, backup: backup, transport: transport, clock: clock,
				networkReachable: { true }
			)
			_ = try await client.appBootstrap(appID: "app-one", forceRefresh: true)
			XCTAssertEqual(transport.requests.map(\.host), [primary.host, backup.host])
		}
		IMAppBootstrapLastGoodStore.clearAll()
	}

	func testCrossHostRevisionRollbackAdvancesUntilNewerRevisionSucceeds() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...3).map { URL(string: "https://carrier-\($0).example.com")! }
		let storeDefaults = UserDefaults(suiteName: "AppBootstrapRevision.\(UUID().uuidString)")!
		let routeStore = IMRuntimeRouteStore(defaults: storeDefaults)
		let seed = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: bases[0].host!, revision: 10
		)
		XCTAssertEqual(routeStore.apply(seed.runtimeRouteSnapshot, appID: "app-one", tenantID: nil), .applied)
		let clock = AppBootstrapTestClock(nowMS: 32_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.dnsLookupFailed, advanceMS: 1),
			.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one", bootstrapHost: bases[0].host!, revision: 9
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 1),
			.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one", bootstrapHost: bases[0].host!, revision: 11
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true },
			runtimeRouteStore: routeStore
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.routeRevision, 11)
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
	}

	func testCrossHostEqualRevisionHashConflictAdvancesUntilNewerRevisionSucceeds() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...3).map { URL(string: "https://carrier-\($0).example.com")! }
		let storeDefaults = UserDefaults(suiteName: "AppBootstrapConflict.\(UUID().uuidString)")!
		let routeStore = IMRuntimeRouteStore(defaults: storeDefaults)
		let seed = try appBootstrapFixture(
			appID: "app-one", bootstrapHost: bases[0].host!, revision: 20
		)
		XCTAssertEqual(routeStore.apply(seed.runtimeRouteSnapshot, appID: "app-one", tenantID: nil), .applied)
		let clock = AppBootstrapTestClock(nowMS: 34_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.cannotConnectToHost, advanceMS: 1),
			.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one",
					bootstrapHost: bases[0].host!,
					revision: 20,
					platformEndpoint: "https://platform-conflict.example.com"
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 1),
			.response(.init(
				data: try appBootstrapEnvelopeData(
					appID: "app-one", bootstrapHost: bases[0].host!, revision: 21
				),
				isHTTPResponse: true, statusCode: 200
			), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true },
			runtimeRouteStore: routeStore
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.routeRevision, 21)
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
	}

	func testEmptyActiveDomainListKeepsOnlyPackagedCandidates() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...2).map { URL(string: "https://carrier-\($0).example.com")! }
		let clock = AppBootstrapTestClock(nowMS: 36_000)
		let data = try appBootstrapEnvelopeData(
			appID: "app-one", bootstrapHost: "", domains: []
		)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.response(.init(data: data, isHTTPResponse: true, statusCode: 200), advanceMS: 0),
		])
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one", forceRefresh: true)

		XCTAssertEqual(resolved.domains, [])
		XCTAssertEqual(client.configuredAppBootstrapBases, bases)
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

	func testAppBootstrapCancellationPropagatesWithoutTryingAnotherOrigin() async throws {
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let backup = URL(string: "https://bootstrap-backup.example.test")!
		let clock = AppBootstrapTestClock(nowMS: 35_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [.failure(.cancelled, advanceMS: 0)]
		)
		let client = makeAppBootstrapClient(
			primary: primary,
			backup: backup,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		do {
			_ = try await client.appBootstrap(appID: "app-one", forceRefresh: true)
			XCTFail("cancellation must propagate")
		} catch let error as URLError {
			XCTAssertEqual(error.code, .cancelled)
		}
		XCTAssertEqual(transport.requests.map(\.host), [primary.host])
	}

	func testColdLaunchAlwaysTriesPrimaryBeforeUsingVerifiedLastGoodWithoutBackup() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let primary = URL(string: "https://bootstrap-primary.example.test")!
		let lastGood = try appBootstrapFixture(appID: "app-one", bootstrapHost: primary.host!)
		IMAppBootstrapLastGoodStore.save(lastGood, appID: "app-one")
		let clock = AppBootstrapTestClock(nowMS: 40_000)
		let transport = AppBootstrapFailoverTransport(clock: clock, outcomes: [
			.failure(.dnsLookupFailed, advanceMS: 5),
		])
		let client = makeAppBootstrapClient(
			primary: primary, backup: nil, transport: transport, clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one")

		XCTAssertEqual(resolved.configHash, lastGood.configHash)
		XCTAssertEqual(transport.requests.map(\.host), [primary.host])
	}

	func testAllQualifiedOriginsFailThenValidatedLastGoodIsRestored() async throws {
		IMAppBootstrapLastGoodStore.clearAll()
		defer { IMAppBootstrapLastGoodStore.clearAll() }
		let bases = (1...4).map { URL(string: "https://bootstrap-\($0).example.com")! }
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		let lastGood = try appBootstrapFixture(appID: "app-one", bootstrapHost: bases[2].host!)
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		IMAppBootstrapLastGoodStore.save(lastGood, appID: "app-one")
		let clock = AppBootstrapTestClock(nowMS: 45_000)
		let transport = AppBootstrapFailoverTransport(
			clock: clock,
			outcomes: [
				.failure(.dnsLookupFailed, advanceMS: 3_000),
				.failure(.cannotConnectToHost, advanceMS: 3_000),
				.failure(.networkConnectionLost, advanceMS: 3_000),
				.failure(.timedOut, advanceMS: 3_000),
			]
		)
		let client = makeAppBootstrapClient(
			bases: bases,
			transport: transport,
			clock: clock,
			networkReachable: { true }
		)

		let resolved = try await client.appBootstrap(appID: "app-one")

		XCTAssertEqual(resolved.configHash, lastGood.configHash)
		XCTAssertEqual(transport.requests.map(\.host), bases.map(\.host))
		XCTAssertEqual(clock.now(), 57_000)
	}
}

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
extension RuntimeRoutesP0Tests {
    func testRouteV5PublicBootstrapReachesTenthCandidateAndKeepsItOnNextClient() async throws {
        let appID = "v5-bootstrap-fixture"
        defer { IMAppBootstrapLastGoodStore.clear(appID: appID) }
        let suite = "RouteV5Public.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: ["-WXT.RouteV5.public_bootstrap", "YES"])
        let packaged = (1...5).map { URL(string: "https://packaged-\($0).example.com")! }
        let downloaded = (1...5).map { URL(string: "https://downloaded-\($0).example.com")! }
        let first = try XCTUnwrap(packaged.first?.host)
        let winner = try XCTUnwrap(downloaded.last?.host)
        let environment = IMAPIClient.configuredAppBootstrapEnvironment()
        let body = try appBootstrapEnvelopeData(
            appID: appID, bootstrapHost: downloaded[0].host!, domains: downloaded.compactMap(\.host),
            environment: environment.isEmpty ? nil : environment
        )
        let transport = RouteV5TestTransport { request, timing in
            let host = request.url?.host
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if host == first { throw URLError(.cannotConnectToHost) }
            timing?.receivedHeaders(host == winner ? 200 : 503)
            return HTTPTransportResult(data: host == winner ? body : Data(), isHTTPResponse: true,
                statusCode: host == winner ? 200 : 503)
        }
        let clock = AppBootstrapTestClock(nowMS: 0)
        let hosts = try XCTUnwrap(IMAppBootstrapHostConfiguration(effectiveOrderedBases: packaged + downloaded))
        let client = makeAppBootstrapClient(bases: packaged, transport: transport, clock: clock,
                                           networkReachable: { true }, runtimeRouteStore: store)
        client.bootstrapHostConfiguration = hosts
        _ = try await client.appBootstrap(appID: appID, forceRefresh: true)
        let firstRound = await transport.events
        XCTAssertEqual(firstRound.map(\.host), (packaged + downloaded).map(\.host))
        XCTAssertGreaterThanOrEqual(firstRound[1].start - firstRound[0].start, IMRouteV5Attempt.interval)
        XCTAssertEqual(client.bootstrapPublicBase?.host, winner)

        let reopened = makeAppBootstrapClient(bases: packaged, transport: transport, clock: clock,
                                             networkReachable: { true }, runtimeRouteStore: store)
        reopened.bootstrapHostConfiguration = hosts
        _ = try await reopened.appBootstrap(appID: appID, forceRefresh: true)
        let reopenedEvents = await transport.events
        XCTAssertEqual(reopenedEvents.count, 11)
        XCTAssertEqual(reopenedEvents.last?.host, winner)
    }
    func testRouteV5ColdStartRestoresOnlyFreshOnlineAuthorizedDownloadedHost() async throws {
        let appID = IMAPIContext.canonicalIOSAppID
        let environment = IMAPIClient.configuredAppBootstrapEnvironment()
        IMAppBootstrapLastGoodStore.clear(appID: appID)
        defer { IMAppBootstrapLastGoodStore.clear(appID: appID) }
        let suite = "RouteV5Cold.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: ["-WXT.RouteV5.public_bootstrap", "YES"])
        let packaged = try XCTUnwrap(URL(string: "https://cold-packaged.example.com"))
        let downloaded = try XCTUnwrap(URL(string: "https://cold-downloaded.example.com"))
        let packagedHost = try XCTUnwrap(packaged.host)
        let downloadedHost = try XCTUnwrap(downloaded.host)
        let seed = try appBootstrapFixture(appID: appID, bootstrapHost: downloadedHost,
            domains: [downloadedHost], revision: 7, environment: environment.isEmpty ? nil : environment)
        let renewed = try appBootstrapFixture(appID: appID, bootstrapHost: downloadedHost,
            domains: [downloadedHost], revision: 8, environment: environment.isEmpty ? nil : environment)
        let removed = try appBootstrapFixture(appID: appID, bootstrapHost: packagedHost,
            domains: [packagedHost], revision: 9, environment: environment.isEmpty ? nil : environment)
        func encode(_ value: RemoteAppBootstrap) throws -> Data {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            return try JSONSerialization.data(withJSONObject: ["ok": true, "data": object])
        }
        let seedData = try encode(seed)
        let renewedData = try encode(renewed)
        let removedData = try encode(removed)
        let clock = AppBootstrapTestClock(nowMS: 0)
        let first = makeAppBootstrapClient(bases: [packaged], transport: RouteV5TestTransport { _, timing in
            timing?.receivedHeaders(200)
            return .init(data: seedData, isHTTPResponse: true, statusCode: 200)
        }, clock: clock, networkReachable: { true }, runtimeRouteStore: store)
        _ = try await first.appBootstrap(appID: appID, forceRefresh: true)

        let refreshTransport = RouteV5TestTransport { request, timing in
            if request.url?.host == packagedHost { throw URLError(.cannotConnectToHost) }
            timing?.receivedHeaders(200)
            return .init(data: renewedData, isHTTPResponse: true, statusCode: 200)
        }
        _ = try await makeAppBootstrapClient(bases: [packaged], transport: refreshTransport,
            clock: clock, networkReachable: { true }, runtimeRouteStore: store).appBootstrap(appID: appID, forceRefresh: true)
        IMAppBootstrapLastGoodStore.save(seed, appID: appID, environment: environment,
            servingHost: packagedHost, now: Date().addingTimeInterval(-1_000))

        let removalTransport = RouteV5TestTransport { _, timing in
            timing?.receivedHeaders(200)
            return .init(data: removedData, isHTTPResponse: true, statusCode: 200)
        }
        func newClient(store: IMRuntimeRouteStore) -> IMAPIClient {
            makeAppBootstrapClient(bases: [packaged], transport: removalTransport,
                clock: clock, networkReachable: { true }, runtimeRouteStore: store)
        }
        IMAppBootstrapLastGoodStore.save(renewed, appID: appID, environment: environment,
            servingHost: downloadedHost, now: Date().addingTimeInterval(-1_000))
        XCTAssertFalse(newClient(store: store).bootstrapHostConfiguration?.containsBase(downloaded) == true)
        IMAppBootstrapLastGoodStore.save(renewed, appID: appID, environment: environment, servingHost: downloadedHost)

        let separateSuite = suite + ".separate"
        let separateDefaults = try XCTUnwrap(UserDefaults(suiteName: separateSuite))
        defer { separateDefaults.removePersistentDomain(forName: separateSuite) }
        let separateStore = IMRuntimeRouteStore(defaults: separateDefaults, launchArgumentsForTesting: ["-WXT.RouteV5.public_bootstrap", "YES"])
        let scope = IMRouteV5Scope(appID: appID, environment: environment, tenantID: nil, service: "public_bootstrap")
        let wrongScope = IMRouteV5Scope(appID: appID, environment: "wrong-environment", tenantID: nil, service: "public_bootstrap")
        let receipt = try XCTUnwrap(store.publicBootstrapReceipt(scope: scope))
        let accepted = try XCTUnwrap(store.record(appID: appID, tenantID: nil).current)
        XCTAssertEqual(separateStore.apply(accepted, appID: appID, tenantID: nil), .applied)
        separateStore.savePublicBootstrapReceipt(receipt, scope: wrongScope)
        XCTAssertFalse(newClient(store: separateStore).bootstrapHostConfiguration?.containsBase(downloaded) == true)
        separateStore.savePublicBootstrapReceipt(receipt, scope: scope)
        XCTAssertEqual(separateStore.applyRevocation(environment: environment.isEmpty ? "production" : environment,
            appID: appID, tenantID: nil, revision: 9, publicationID: "revoked-fixture",
            profileFingerprint: String(repeating: "a", count: 64), status: "disabled", keysetRevision: 1), .revoked)
        XCTAssertFalse(newClient(store: separateStore).bootstrapHostConfiguration?.containsBase(downloaded) == true)

        let cold = makeAppBootstrapClient(bases: [packaged], transport: removalTransport,
            clock: clock, networkReachable: { true }, runtimeRouteStore: store)
        XCTAssertEqual(cold.bootstrapMemory?.routeRevision, 8)
        XCTAssertEqual(cold.bootstrapPublicBase, downloaded)
        XCTAssertTrue(cold.bootstrapHostConfiguration?.containsBase(downloaded) == true)
        _ = try await cold.appBootstrap(appID: appID, forceRefresh: true)
        let events = await removalTransport.events
        XCTAssertEqual(events.map(\.host), [downloadedHost])

        let next = makeAppBootstrapClient(bases: [packaged], transport: removalTransport,
            clock: clock, networkReachable: { true }, runtimeRouteStore: store)
        XCTAssertFalse(next.bootstrapHostConfiguration?.containsBase(downloaded) == true)
        XCTAssertNil(next.bootstrapPublicBase)
    }

    func testRouteV5LateBootstrapSuccessHeadersDoNotBlockFullyValidatedStandby() async throws {
        let appID = "v5-public-late-200"
        let environment = IMAPIClient.configuredAppBootstrapEnvironment()
        defer { IMAppBootstrapLastGoodStore.clear(appID: appID) }
        let suite = "RouteV5PublicLateSuccess.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = try XCTUnwrap(URL(string: "https://late-200-public-primary.example.com"))
        let backup = try XCTUnwrap(URL(string: "https://late-200-public-backup.example.com"))
        let firstHost = try XCTUnwrap(primary.host)
        let secondHost = try XCTUnwrap(backup.host)
        let first = try appBootstrapEnvelopeData(appID: appID, bootstrapHost: firstHost, revision: 7,
            environment: environment.isEmpty ? nil : environment)
        let second = try appBootstrapEnvelopeData(appID: appID, bootstrapHost: firstHost, revision: 8,
            environment: environment.isEmpty ? nil : environment)
        let session = RouteV5InterleavedHTTP.session { host in
            host == firstHost
                ? .init(headersAfter: 3_130_000_000, bodyAfterHeaders: 650_000_000, status: 200, body: first)
                : .init(headersAfter: 280_000_000, bodyAfterHeaders: 100_000_000, status: 200, body: second)
        }
        defer { session.invalidateAndCancel(); RouteV5InterleavedHTTP.reset() }
        let client = makeAppBootstrapClient(bases: [primary, backup], transport: URLSessionHTTPTransport(session: session),
            clock: AppBootstrapTestClock(nowMS: 0), networkReachable: { true },
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: ["-WXT.RouteV5.public_bootstrap", "YES"]))
        let result = try await client.appBootstrap(appID: appID, forceRefresh: true)
        XCTAssertEqual(result.routeRevision, 8)
        XCTAssertEqual(client.bootstrapPublicBase, backup)
        let events = RouteV5InterleavedHTTP.events()
        let firstHeaders = try XCTUnwrap(events.firstIndex(of: "headers:\(firstHost)"))
        let secondBody = try XCTUnwrap(events.firstIndex(of: "body:\(secondHost)"))
        XCTAssertLessThan(firstHeaders, secondBody)
        XCTAssertFalse(events.contains("body:\(firstHost)"))
    }

    func testRouteV5LatePublicHTTPStatusStopsCandidateCommit() async throws {
        let appID = "v5-public-late-status"
        let environment = IMAPIClient.configuredAppBootstrapEnvironment()
        defer { IMAppBootstrapLastGoodStore.clear(appID: appID) }
        let suite = "RouteV5PublicLate.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = try XCTUnwrap(URL(string: "https://late-public-primary.example.com"))
        let backup = try XCTUnwrap(URL(string: "https://late-public-backup.example.com"))
        let body = try appBootstrapEnvelopeData(appID: appID, bootstrapHost: primary.host!,
            environment: environment.isEmpty ? nil : environment)
        let transport = RouteV5TestTransport { request, timing in
            if request.url?.host == primary.host {
                try await Task.sleep(nanoseconds: 3_150_000_000)
                timing?.receivedHeaders(503)
                return .init(data: Data(), isHTTPResponse: true, statusCode: 503)
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            timing?.receivedHeaders(200)
            return .init(data: body, isHTTPResponse: true, statusCode: 200)
        }
        let client = makeAppBootstrapClient(bases: [primary, backup], transport: transport,
            clock: AppBootstrapTestClock(nowMS: 0), networkReachable: { true },
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: ["-WXT.RouteV5.public_bootstrap", "YES"]))
        do {
            _ = try await client.appBootstrap(appID: appID, forceRefresh: true)
            XCTFail("the backup masked the primary's 503")
        } catch IMAPIError.httpStatus(let status, _) {
            XCTAssertEqual(status, 503)
        }
        XCTAssertNil(client.bootstrapPublicBase)
    }

}

actor RouteV5TestTransport: HTTPTransport {
    struct Event: Sendable {
        let host: String?
        let path: String
        let method: String?
        let start: UInt64
        let body: Data?
    }

    private let beforeDispatch: @Sendable (URLRequest) async throws -> Void
    private let perform: @Sendable (URLRequest, HTTPRouteTiming?) async throws -> HTTPTransportResult
    private(set) var events: [Event] = []

    init(beforeDispatch: @escaping @Sendable (URLRequest) async throws -> Void = { _ in },
         perform: @escaping @Sendable (URLRequest, HTTPRouteTiming?) async throws -> HTTPTransportResult) {
        self.beforeDispatch = beforeDispatch
        self.perform = perform
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        try await performRecorded(request, timing: nil)
    }

    func data(for request: URLRequest, expectedOrigin: URL, routeTiming: HTTPRouteTiming) async throws -> HTTPTransportResult {
        XCTAssertEqual(request.url?.host, expectedOrigin.host)
        return try await performRecorded(request, timing: routeTiming)
    }

    private func performRecorded(_ request: URLRequest, timing: HTTPRouteTiming?) async throws -> HTTPTransportResult {
        try await beforeDispatch(request)
        guard timing?.mayStart() != false else { throw CancellationError() }
        let start = DispatchTime.now().uptimeNanoseconds
        events.append(Event(host: request.url?.host, path: request.url?.path ?? "", method: request.httpMethod,
                            start: start, body: request.httpBody))
        timing?.started(start)
        return try await perform(request, timing).resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
final class RouteV5InterleavedHTTP: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let headersAfter: UInt64
        let bodyAfterHeaders: UInt64
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: (@Sendable (String) -> Response)?
    nonisolated(unsafe) private static var timeline: [String] = []
    private let workLock = NSLock()
    private var work: Task<Void, Never>?

    static func session(_ respond: @escaping @Sendable (String) -> Response) -> URLSession {
        lock.withLock { responder = respond; timeline = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouteV5InterleavedHTTP.self]
        return URLSession(configuration: configuration)
    }

    static func events() -> [String] { lock.withLock { timeline } }

    static func reset() {
        lock.withLock { responder = nil; timeline = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let respond = Self.lock.withLock({ Self.responder }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let script = respond(host)
        let task = Task.detached { @Sendable [weak self, script, url, host] in
            do {
                try await Task.sleep(nanoseconds: script.headersAfter)
                guard let self, let response = HTTPURLResponse(url: url, statusCode: script.status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
                Self.lock.withLock { Self.timeline.append("headers:\(host)") }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                try await Task.sleep(nanoseconds: script.bodyAfterHeaders)
                Self.lock.withLock { Self.timeline.append("body:\(host)") }
                client?.urlProtocol(self, didLoad: script.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {}
        }
        workLock.withLock { work = task }
    }

    override func stopLoading() {
        workLock.withLock { work?.cancel(); work = nil }
    }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

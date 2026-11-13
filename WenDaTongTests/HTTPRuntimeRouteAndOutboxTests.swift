@testable import IM4Domain
import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
	func testUserProfilesReadOnlyPostDoesNotReplayOnIdentityOrTLSFailure() async throws {
		let suiteName = "RuntimeUserProfilesFailClosed.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		RuntimeRouteURLProtocol.reset()
		defer { RuntimeRouteURLProtocol.reset() }
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.example.test")!,
			tenantBase: URL(string: "https://seed-tenant.example.test")!,
			imBase: URL(string: "https://seed-im.example.test")!,
			httpTransport: URLSessionHTTPTransport(session: session),
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)
		)
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)

		RuntimeRouteURLProtocol.install { _ in (401, Data()) }
		do {
			_ = try await client.userProfiles(context: makeContext(), exactUIDs: ["uid-1"])
			XCTFail("401 unexpectedly replayed")
		} catch IMAPIError.unauthorized {
			// Authentication failures are terminal for the selected endpoint.
		} catch {
			XCTFail("unexpected identity error: \(error)")
		}
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), ["tenant-primary.example.com"])

		RuntimeRouteURLProtocol.install { _ in throw URLError(.serverCertificateUntrusted) }
		do {
			_ = try await client.userProfiles(context: makeContext(), exactUIDs: ["uid-1"])
			XCTFail("TLS identity failure unexpectedly replayed")
		} catch {
			XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted)
		}
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), ["tenant-primary.example.com"])
	}

	func testRuntimePreferredEndpointsShareOneMonotonicFiveSecondBudget() async throws {
		let suiteName = "RuntimeRouteBudget.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let clock = RuntimeRouteTestClock(nowMS: 10_000)
		let transport = RuntimeRouteBudgetTransport(clock: clock, actions: [
			.failure(.timedOut, advanceMS: 3_000),
			.failure(.cannotConnectToHost, advanceMS: 2_000),
			.response(
				status: 200,
				data: Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8),
				advanceMS: 0
			),
		])
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.customer.net")!,
			tenantBase: URL(string: "https://seed-tenant.customer.net")!,
			imBase: URL(string: "https://seed-im.customer.net")!,
			httpTransport: transport,
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
			runtimeMonotonicNowMS: { clock.now() },
			runtimeSleep: { milliseconds in clock.advance(by: milliseconds) }
		)
		let routes = runtimeRouteSnapshotForHTTPWiring(tenantPreferred: [
			"https://tenant-primary-a.example.com", "https://tenant-primary-b.example.com",
		])
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)

		let devices = try await client.listDevices(context: makeContext())

		XCTAssertTrue(devices.isEmpty)
		XCTAssertEqual(transport.requestHosts(), [
			"tenant-primary-a.example.com", "tenant-primary-b.example.com", "tenant-backup.example.net",
		])
		let timeouts = transport.requestTimeouts()
		XCTAssertEqual(timeouts[0], 5, accuracy: 0.001)
		XCTAssertEqual(timeouts[1], 2, accuracy: 0.001)
		XCTAssertEqual(clock.now(), 15_000)
	}

    func testRegistrationPostKeepsEightSecondTimeoutAndNeverReplaysUncertainSubmission() async throws {
        let accepted = Data(#"{"ok":true,"data":{"account":{"id":"fixture-account","username":"fixture-user","status":"normal"},"platform_token":"fixture-token"}}"#.utf8)
        for elapsedMS: UInt64 in [5_900, 7_900, 8_100] {
            let suiteName = "RuntimeRegistrationBudget.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let clock = RuntimeRouteTestClock(nowMS: 0)
            let transport = RuntimeRouteBudgetTransport(clock: clock, actions: [
                .responseWithinTimeout(status: 200, data: accepted, advanceMS: elapsedMS),
                .response(status: 200, data: accepted, advanceMS: 0)
            ])
            let client = IMAPIClient(
                platformBase: URL(string: "https://platform.customer.net")!,
                tenantBase: URL(string: "https://seed-tenant.customer.net")!,
                imBase: URL(string: "https://seed-im.customer.net")!, httpTransport: transport,
                runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
                runtimeMonotonicNowMS: { clock.now() }, runtimeSleep: { clock.advance(by: $0) }
            )
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(appBootstrapForHTTPWiring(
                platformBase: "https://platform-primary.example.com",
                platformBackups: ["https://platform-backup.example.net"]
            ).runtimeRouteSnapshot), .applied)
            let requestID = UUID().uuidString.lowercased()
            do {
                let result = try await client.registerWithRequestID(
                    username: "fixture-user", phone: "", password: "fixture-password", tenantCode: nil,
                    captchaCode: nil, enterpriseContextToken: nil, appID: "jianhuitong-ios",
                    deviceID: "device-1", requestID: requestID
                )
                XCTAssertLessThan(elapsedMS, 8_000)
                XCTAssertEqual(result.platformToken, "fixture-token")
            } catch {
                XCTAssertEqual(elapsedMS, 8_100)
                XCTAssertTrue(error is RegistrationOutcomeUncertainError)
            }
            let request = try XCTUnwrap(transport.requests().first)
            XCTAssertEqual(transport.requests().count, 1)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "platform-primary.example.com")
            XCTAssertEqual(request.timeoutInterval, 8, accuracy: 0.001)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), requestID)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
            XCTAssertEqual(body["device_id"] as? String, "device-1")
        }
    }

    func testRegistrationStatusKeepsFiveSecondPreferredAndEightSecondBackupTimeouts() async throws {
        let suiteName = "RuntimeRegistrationStatusBudget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = RuntimeRouteTestClock(nowMS: 0)
        let transport = RuntimeRouteBudgetTransport(clock: clock, actions: [
            .failure(.timedOut, advanceMS: 5_000),
            .responseWithinTimeout(status: 200, data: Data(#"{"ok":true,"data":{"status":"PENDING"}}"#.utf8), advanceMS: 7_900)
        ])
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.customer.net")!,
            tenantBase: URL(string: "https://seed-tenant.customer.net")!,
            imBase: URL(string: "https://seed-im.customer.net")!, httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
            runtimeMonotonicNowMS: { clock.now() }, runtimeSleep: { clock.advance(by: $0) }
        )
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(appBootstrapForHTTPWiring(
                platformBase: "https://platform-primary.example.com",
                platformBackups: ["https://platform-backup.example.net"]
            ).runtimeRouteSnapshot), .applied)
        let requestID = UUID().uuidString.lowercased()
        let result = try await client.registrationStatus(appID: "jianhuitong-ios", deviceID: "device-1", requestID: requestID)
        XCTAssertEqual(result, .pending)
        XCTAssertEqual(transport.requestHosts(), ["platform-primary.example.com", "platform-backup.example.net"])
        XCTAssertEqual(transport.requestTimeouts(), [5, 8])
        for request in transport.requests() {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), requestID)
        }
    }

	func testRuntimeHTTPProtocolEmptyDataDoesNotFailOver() async throws {
		let suiteName = "RuntimeRouteEmptyData.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let transport = RuntimeRouteBudgetTransport(clock: RuntimeRouteTestClock(nowMS: 18_000), actions: [
			.response(status: 200, data: Data(#"{"ok":true}"#.utf8), advanceMS: 0),
			.response(
				status: 200,
				data: Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8),
				advanceMS: 0
			),
		])
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.customer.net")!,
			tenantBase: URL(string: "https://seed-tenant.customer.net")!,
			imBase: URL(string: "https://seed-im.customer.net")!,
			httpTransport: transport,
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)
		)
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)

		do {
			_ = try await client.listDevices(context: makeContext())
			XCTFail("2xx response without data unexpectedly failed over")
		} catch IMAPIError.emptyResponse {
			// Protocol/business failure is terminal for the logical request.
		} catch {
			XCTFail("unexpected error: \(error)")
		}
		XCTAssertEqual(transport.requestHosts(), ["tenant-primary.example.com"])
	}

	func testRuntimeNonIdempotentWriteNeverReplaysAcrossEndpointsWithoutKey() async throws {
		let suiteName = "RuntimeRouteWriteReplay.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let clock = RuntimeRouteTestClock(nowMS: 20_000)
		let transport = RuntimeRouteBudgetTransport(clock: clock, actions: [
			.failure(.timedOut, advanceMS: 5_000),
		])
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.customer.net")!,
			tenantBase: URL(string: "https://seed-tenant.customer.net")!,
			imBase: URL(string: "https://seed-im.customer.net")!,
			httpTransport: transport,
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
			runtimeMonotonicNowMS: { clock.now() },
			runtimeSleep: { milliseconds in clock.advance(by: milliseconds) }
		)
		let routes = runtimeRouteSnapshotForHTTPWiring(tenantPreferred: [
			"https://tenant-primary-a.example.com", "https://tenant-primary-b.example.com",
		])
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)

		do {
			_ = try await client.createGroup(context: makeContext(), name: "no-replay", memberUIDs: [])
			XCTFail("non-idempotent write unexpectedly succeeded")
		} catch {
			XCTAssertEqual((error as? URLError)?.code, .timedOut)
		}
		XCTAssertEqual(transport.requestHosts(), ["tenant-primary-a.example.com"])
	}

	func testThreeRealColdProcessLaunchesWireNetworkFailureIntoRecovery() async throws {
		let suiteName = "RuntimeColdProcess.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = IMRuntimeRouteStore(defaults: defaults)
		let routes = runtimeRouteSnapshotForHTTPWiring()
		XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)

		for ordinal in 0..<3 {
			let clock = RuntimeRouteTestClock(nowMS: UInt64(ordinal) * 10_000)
			let lifecycle = IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
			lifecycle.beginProcessLaunch()
			lifecycle.sceneDidBecomeActive()
			lifecycle.setNetworkReachable(true)
			let transport = RuntimeRouteBudgetTransport(clock: clock, actions: [
				.failure(.timedOut, advanceMS: 5_000),
				.response(
					status: 200,
					data: Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8),
					advanceMS: 0
				),
			])
			let client = IMAPIClient(
				platformBase: URL(string: "https://platform.customer.net")!,
				tenantBase: URL(string: "https://seed-tenant.customer.net")!,
				imBase: URL(string: "https://seed-im.customer.net")!,
				httpTransport: transport,
				runtimeRouteStore: store,
				runtimeColdLaunchLifecycle: lifecycle,
				runtimeMonotonicNowMS: { clock.now() },
				runtimeSleep: { milliseconds in clock.advance(by: milliseconds) }
			)
			XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .idempotent)
			let devices = try await client.listDevices(context: makeContext())
			XCTAssertTrue(devices.isEmpty)
			lifecycle.finish()
		}

		let recovery = IMRuntimeRouteSelector(store: store).recovery(routes, service: .tenantAPI)
		XCTAssertTrue(recovery.recovery)
		XCTAssertEqual(recovery.consecutiveQualifiedColdLaunchFailures, 3)
	}

	func testTenantBinaryFetcherUsesRuntimeRoutesButPreservesAbsoluteOSSURL() async throws {
		let suiteName = "RuntimeTenantBinary.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		RuntimeRouteURLProtocol.reset()
		defer { RuntimeRouteURLProtocol.reset() }
		let clock = RuntimeRouteTestClock(nowMS: 30_000)
		RuntimeRouteURLProtocol.install { request in
			switch request.url?.host {
			case "tenant-primary.example.com":
				if request.url?.path == "/api/tenant/avatar/users/uid-2" {
					return (200, Data([0x04]))
				}
				throw URLError(.timedOut)
			case "tenant-backup.example.net": return (200, Data([0x01, 0x02]))
			case "assets.customer-cdn.net": return (200, Data([0x03]))
			default: throw URLError(.badURL)
			}
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.customer.net")!,
			tenantBase: URL(string: "https://seed-tenant.customer.net")!,
			imBase: URL(string: "https://seed-im.customer.net")!,
			httpTransport: URLSessionHTTPTransport(session: session),
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
			runtimeMonotonicNowMS: { clock.now() },
			runtimeSleep: { milliseconds in clock.advance(by: milliseconds) }
		)
		let routes = runtimeRouteSnapshotForHTTPWiring(
			tenantPreferred: ["https://tenant-primary.example.com:443"]
		)
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
		XCTAssertEqual(client.runtimeTenantBinaryRouteContext(context: makeContext())?.revision, routes.revision)

		let routed = try await client.fetchRuntimeTenantBinary(
			"/api/tenant/avatar/users/uid-1", context: makeContext()
		)
		XCTAssertEqual(routed.data, Data([0x01, 0x02]))
		XCTAssertEqual(routed.resolvedURL.host, "tenant-backup.example.net")
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), [
			"tenant-primary.example.com", "tenant-backup.example.net",
		])

		let sameOriginURL = "https://tenant-primary.example.com/api/tenant/avatar/users/uid-2?signature=preserved"
		let sameOrigin = try await client.fetchRuntimeTenantBinary(
			sameOriginURL,
			context: makeContext()
		)
		XCTAssertEqual(sameOrigin.data, Data([0x04]))
		XCTAssertEqual(sameOrigin.resolvedURL.absoluteString, sameOriginURL)
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), [
			"tenant-primary.example.com", "tenant-backup.example.net",
			"tenant-primary.example.com",
		])

		let absolute = "https://assets.customer-cdn.net/avatar.png?signature=preserved"
		let direct = try await client.fetchRuntimeTenantBinary(absolute, context: makeContext())
		XCTAssertEqual(direct.data, Data([0x03]))
		XCTAssertEqual(direct.resolvedURL.absoluteString, absolute)
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts().last, "assets.customer-cdn.net")
	}

	func testTenantBinaryFetcherDoesNotFailOverOnHTTP401OrTLSIdentityFailure() async throws {
		let suiteName = "RuntimeTenantBinaryFailClosed.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		RuntimeRouteURLProtocol.reset()
		defer { RuntimeRouteURLProtocol.reset() }
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		let clock = RuntimeRouteTestClock(nowMS: 40_000)
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.customer.net")!,
			tenantBase: URL(string: "https://seed-tenant.customer.net")!,
			imBase: URL(string: "https://seed-im.customer.net")!,
			httpTransport: URLSessionHTTPTransport(session: session),
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
			runtimeMonotonicNowMS: { clock.now() },
			runtimeSleep: { milliseconds in clock.advance(by: milliseconds) }
		)
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)

		RuntimeRouteURLProtocol.install { _ in (401, Data()) }
		do {
			_ = try await client.fetchRuntimeTenantBinary("/api/tenant/avatar/users/uid-1", context: makeContext())
			XCTFail("401 unexpectedly failed over")
		} catch {
			XCTAssertEqual(error as? IMRuntimeTenantBinaryFetchError, .httpStatus(401))
		}
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), ["tenant-primary.example.com"])

		RuntimeRouteURLProtocol.install { _ in throw URLError(.serverCertificateUntrusted) }
		do {
			_ = try await client.fetchRuntimeTenantBinary("/api/tenant/avatar/users/uid-1", context: makeContext())
			XCTFail("TLS identity failure unexpectedly failed over")
		} catch {
			XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted)
		}
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), ["tenant-primary.example.com"])
	}

	func testRuntimeRealtimeRecoveryRequiresBackupAndPreferredStableWindows() throws {
		let suiteName = "RuntimeRealtimeProbe.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let routes = runtimeRouteSnapshotForHTTPWiring()
		let store = IMRuntimeRouteStore(defaults: defaults)
		XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
		let selector = IMRuntimeRouteSelector(store: store)
		let attempt = IMRuntimeColdLaunchAttempt(
			processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
			backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000
		)
		for _ in 0..<3 { selector.recordColdLaunch(attempt, snapshot: routes, service: .imRealtime) }
		let clock = RuntimeRouteTestClock(nowMS: 100_000)
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.example.test")!,
			tenantBase: URL(string: "https://seed-tenant.example.test")!,
			imBase: URL(string: "https://seed-im.example.test")!,
			httpTransport: FakeHTTPTransport(results: []), runtimeRouteStore: store,
			runtimeMonotonicNowMS: { clock.now() },
			runtimeSleep: { milliseconds in clock.advance(by: milliseconds) }
		)
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .idempotent)
		let context = makeContext()
		XCTAssertEqual(client.runtimeRealtimeConnectionRequest(context: context)?.url.host, "ws-backup.example.net")
		client.recordRuntimeRealtimeConnected(context: context)
		XCTAssertFalse(client.prepareRuntimeRealtimePreferredProbe(context: context))
		clock.advance(by: 30_000)
		XCTAssertTrue(client.prepareRuntimeRealtimePreferredProbe(context: context))
		XCTAssertEqual(client.runtimeRealtimeConnectionRequest(context: context)?.url.host, "ws-primary.example.com")
		client.recordRuntimeRealtimeConnected(context: context)
		XCTAssertFalse(client.completeRuntimeRealtimePreferredProbe(context: context))
		clock.advance(by: 29_999)
		XCTAssertFalse(client.completeRuntimeRealtimePreferredProbe(context: context))
		XCTAssertTrue(selector.recovery(routes, service: .imRealtime).recovery)
		clock.advance(by: 1)
		XCTAssertTrue(client.completeRuntimeRealtimePreferredProbe(context: context))
		XCTAssertFalse(selector.recovery(routes, service: .imRealtime).recovery)
		XCTAssertEqual(client.runtimeRealtimeConnectionRequest(context: context)?.url.host, "ws-primary.example.com")
	}

	func testRuntimeNewGenerationClearsPriorRecoveryAndStartsFromFreshPreferred() throws {
		let suiteName = "RuntimeFreshGeneration.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = IMRuntimeRouteStore(defaults: defaults)
		let oldRoutes = runtimeRouteSnapshotForHTTPWiring(revision: 1)
		XCTAssertEqual(store.apply(oldRoutes, appID: oldRoutes.appID, tenantID: oldRoutes.tenantID), .applied)
		let selector = IMRuntimeRouteSelector(store: store)
		let failedLaunch = IMRuntimeColdLaunchAttempt(
			processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
			backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000
		)
		for _ in 0..<3 {
			selector.recordColdLaunch(failedLaunch, snapshot: oldRoutes, service: .tenantAPI)
		}
		XCTAssertTrue(selector.recovery(oldRoutes, service: .tenantAPI).recovery)
		XCTAssertEqual(selector.endpoints(oldRoutes, service: .tenantAPI).first, "https://tenant-backup.example.net")

		let freshRoutes = runtimeRouteSnapshotForHTTPWiring(
			tenantPreferred: ["https://tenant-fresh.example.com"],
			revision: 2
		)
		XCTAssertEqual(store.apply(freshRoutes, appID: freshRoutes.appID, tenantID: freshRoutes.tenantID), .applied)
		XCTAssertFalse(selector.recovery(freshRoutes, service: .tenantAPI).recovery)
		XCTAssertEqual(selector.endpoints(freshRoutes, service: .tenantAPI).first, "https://tenant-fresh.example.com")
	}

	func testValidatedTenantScopeChangeResetsRealtimeTransientWindowAndFailClosedState() throws {
		let suiteName = "RuntimeRealtimeScopeReset.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let clock = RuntimeRouteTestClock(nowMS: 200_000)
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.example.test")!,
			tenantBase: URL(string: "https://seed-tenant.example.test")!,
			imBase: URL(string: "https://seed-im.example.test")!,
			httpTransport: FakeHTTPTransport(results: []),
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
			runtimeMonotonicNowMS: { clock.now() },
			runtimeSleep: { milliseconds in clock.advance(by: milliseconds) }
		)

		let tenantA = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-a")
		let contextA = makeContext(tenantID: "tenant-a")
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(tenantA), .applied)
		XCTAssertEqual(client.runtimeRealtimeConnectionRequest(context: contextA)?.url.host, "ws-primary.example.com")
		clock.advance(by: 5_000)
		client.recordRuntimeRealtimeFailure(URLError(.timedOut), context: contextA)
		XCTAssertEqual(client.runtimeRealtimeConnectionRequest(context: contextA)?.url.host, "ws-backup.example.net")

		let tenantB = runtimeRouteSnapshotForHTTPWiring(
			tenantID: "tenant-b",
			realtimePreferred: "wss://ws-b-primary.example.com",
			realtimeBackup: "wss://ws-b-backup.example.net"
		)
		let contextB = makeContext(tenantID: "tenant-b")
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(tenantB), .applied)
		XCTAssertEqual(client.runtimeRealtimeConnectionRequest(context: contextB)?.url.host, "ws-b-primary.example.com")
		client.recordRuntimeRealtimeFailure(URLError(.serverCertificateUntrusted), context: contextB)
		XCTAssertNil(client.runtimeRealtimeConnectionRequest(context: contextB))

		let tenantC = runtimeRouteSnapshotForHTTPWiring(
			tenantID: "tenant-c",
			realtimePreferred: "wss://ws-c-primary.example.com",
			realtimeBackup: "wss://ws-c-backup.example.net"
		)
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(tenantC), .applied)
		XCTAssertEqual(
			client.runtimeRealtimeConnectionRequest(context: makeContext(tenantID: "tenant-c"))?.url.host,
			"ws-c-primary.example.com"
		)
	}

    func testFriendPresenceRefreshUsesFriendsEndpointAndAppliesLatestRelation() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"friend_uid":"peer-32","friend_user_id":"WXTNS000032","friend_nickname":"Android 测试用户","friend_online":true,"friend_status":"online"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = makeIsolatedAuthenticatedHTTPState(transport: transport, context: makeContext())
        // WDT_IOS1_WIRE83_FRIEND_PRESENCE_POLICY_FIXTURE_20261111_BEGIN
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
        ).data)
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        // WDT_IOS1_WIRE83_FRIEND_PRESENCE_POLICY_FIXTURE_20261111_END

        await state.refreshFriendPresenceForTesting()

        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/friends"])
        XCTAssertEqual(state.contacts.map(\.id), ["peer-32"])
        XCTAssertEqual(state.contacts.first?.name, "Android 测试用户")
        XCTAssertEqual(
            AppState.presenceStatusText(
                rawStatus: "online",
                online: true,
                policy: RemoteTenantClientPolicy(showOnlineStatus: true)
            ),
            ""
        )
    }

    func testForwardBatchUsesOnePostWithExactBodyAndIdempotencyHeader() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("""
                {
                  "ok": true,
                  "data": {
                    "contract_version": 1,
                    "batch_id": "batch-server-1",
                    "client_batch_id": "batch-client-1",
                    "source_count": 2,
                    "target_count": 2,
                    "created_count": 4,
                    "state": "committed",
                    "idempotent_replay": false,
                    "authoritative_source_message_ids": ["message-1", "message-2"],
                    "targets": [
                      {
                        "target_ordinal": 0,
                        "channel_id": "friend-1:uid-1",
                        "channel_type": "direct",
                        "messages": [
                          {"source_ordinal": 0, "source_message_id": "message-1", "message_id": "created-1"},
                          {"source_ordinal": 1, "source_message_id": "message-2", "message_id": "created-2"}
                        ]
                      },
                      {
                        "target_ordinal": 1,
                        "channel_id": "group-2",
                        "channel_type": "group",
                        "messages": [
                          {"source_ordinal": 0, "source_message_id": "message-1", "message_id": "created-3"},
                          {"source_ordinal": 1, "source_message_id": "message-2", "message_id": "created-4"}
                        ]
                      }
                    ]
                  }
                }
                """.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let command = BatchForwardSubmitCommand(
            request: BatchForwardRequest(
                clientBatchID: "batch-client-1",
                sourceChannelID: "group-source",
                sourceChannelType: "group",
                sourceMessageIDs: ["message-1", "message-2"],
                targets: [
                    BatchForwardTargetRequest(
                        channelID: "friend-1:uid-1",
                        channelType: "direct"
                    ),
                    BatchForwardTargetRequest(
                        channelID: "group-2",
                        channelType: "group"
                    )
                ],
                mode: .separate
            ),
            headers: [
                "Idempotency-Key": "batch-client-1",
                "X-Untrusted-Header": "must-not-forward"
            ]
        )

        let result = try await client.forwardBatch(
            context: makeContext(),
            command: command
        )

        XCTAssertEqual(result.batchID, "batch-server-1")
        XCTAssertEqual(result.clientBatchID, "batch-client-1")
        XCTAssertEqual(result.authoritativeSourceMessageIDs, ["message-1", "message-2"])
        XCTAssertEqual(result.serverCreatedMessageIDs, ["created-1", "created-2", "created-3", "created-4"])
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://im.example.test/api/im/messages/forward-batch")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "batch-client-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Untrusted-Header"))
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(
            Set(body.keys),
            Set([
                "client_batch_id",
                "source_channel_id",
                "source_channel_type",
                "source_message_ids",
                "targets",
                "mode"
            ])
        )
        XCTAssertEqual(body["client_batch_id"] as? String, "batch-client-1")
        XCTAssertEqual(body["source_channel_id"] as? String, "group-source")
        XCTAssertEqual(body["source_channel_type"] as? String, "group")
        XCTAssertEqual(body["source_message_ids"] as? [String], ["message-1", "message-2"])
        XCTAssertEqual(body["mode"] as? String, "separate")
        let targets = try XCTUnwrap(body["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(Set(targets[0].keys), Set(["channel_id", "channel_type"]))
        XCTAssertEqual(targets[0]["channel_id"] as? String, "friend-1:uid-1")
        XCTAssertEqual(targets[0]["channel_type"] as? String, "direct")
        XCTAssertEqual(Set(targets[1].keys), Set(["channel_id", "channel_type"]))
        XCTAssertEqual(targets[1]["channel_id"] as? String, "group-2")
        XCTAssertEqual(targets[1]["channel_type"] as? String, "group")
    }

    func testReleaseGuardIgnoresLocalAPIBaseResidueAndDiagnosticsEntryIsGloballyCompiled() throws {
        let suiteName = "im3.ios.release-guard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set("http://localhost:8081", forKey: "im2.api.platformBase")
        defaults.set("http://127.0.0.1:8082", forKey: "im2.api.tenantBase")
        defaults.set("http://localhost:8083", forKey: "im2.api.imBase")

        let guarded = IMAPIClient.configuredAPIBases(defaults: defaults, allowLocalOverride: false)

        XCTAssertEqual(guarded.platformBase, IMAPIClient.releasePlaceholderPlatformBase)
        XCTAssertEqual(guarded.tenantBase, IMAPIClient.releasePlaceholderTenantBase)
        XCTAssertEqual(guarded.imBase, IMAPIClient.releasePlaceholderIMBase)
        XCTAssertEqual(guarded.platformBase.absoluteString, "about:blank")
        XCTAssertEqual(guarded.tenantBase.absoluteString, "about:blank")
        XCTAssertEqual(guarded.imBase.absoluteString, "about:blank")
        [guarded.platformBase, guarded.tenantBase, guarded.imBase].forEach { base in
            let value = base.absoluteString.lowercased()
            XCTAssertFalse(value.contains("wenxintong-test.com"))
            XCTAssertFalse(value.contains("localhost"))
            XCTAssertFalse(value.contains(".invalid"))
        }
        XCTAssertNil(IMAPIClient.normalizedTenantAPIBaseURL("http://localhost:8082", allowLocalOrInsecure: false))
        XCTAssertNil(IMAPIClient.normalizedIMAPIBaseURL("http://127.0.0.1:8083", allowLocalOrInsecure: false))
        XCTAssertNotNil(IMAPIClient.normalizedTenantAPIBaseURL("https://tenant.example.test", allowLocalOrInsecure: false))

        let debugLocal = IMAPIClient.configuredAPIBases(defaults: defaults, allowLocalOverride: true)
        XCTAssertEqual(debugLocal.platformBase.absoluteString, "http://localhost:8081")
        XCTAssertEqual(debugLocal.tenantBase.absoluteString, "http://127.0.0.1:8082")
        XCTAssertEqual(debugLocal.imBase.absoluteString, "http://localhost:8083")
        XCTAssertTrue(IMRuntimeBuildPolicy.allowsRuntimeAPIBaseOverride(
            debugBuild: true,
            info: [IMRuntimeBuildPolicy.formalBuildInfoKey: "NO"]
        ))
        XCTAssertFalse(IMRuntimeBuildPolicy.allowsRuntimeAPIBaseOverride(
            debugBuild: true,
            info: [IMRuntimeBuildPolicy.formalBuildInfoKey: "YES"]
        ))
        XCTAssertFalse(IMRuntimeBuildPolicy.allowsRuntimeAPIBaseOverride(
            debugBuild: false,
            info: [IMRuntimeBuildPolicy.formalBuildInfoKey: "NO"]
        ))
        let formalDebugAllowsOverride = IMRuntimeBuildPolicy.allowsRuntimeAPIBaseOverride(
            debugBuild: true,
            info: [IMRuntimeBuildPolicy.formalBuildInfoKey: "YES"]
        )
        XCTAssertEqual(
            IMAPIContext.normalizedIOSAppID(
                "attacker-controlled-app-id",
                allowCustomAppID: formalDebugAllowsOverride
            ),
            IMAPIContext.canonicalIOSAppID
        )
        XCTAssertNil(
            IMRuntimeRouteSnapshot.normalizedEndpoint(
                "http://127.0.0.1:8082",
                service: .tenantAPI,
                allowDevelopmentEndpoints: formalDebugAllowsOverride
            )
        )

        XCTAssertTrue(AccessDiagnosticsOverlayCapability.isEntryCompiled(debugBuild: false, internalCapabilityEnabled: false))
        XCTAssertTrue(AccessDiagnosticsOverlayCapability.isEntryCompiled(debugBuild: true, internalCapabilityEnabled: false))
        XCTAssertTrue(AccessDiagnosticsOverlayCapability.isEntryCompiled(debugBuild: false, internalCapabilityEnabled: true))
    }

    func testOutgoingSendingBubblesAreNotProjectedBeforeDurableOutboxAuthority() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WenDaTong/AppState.swift")
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN
        let appRoot = sourceURL.deletingLastPathComponent()
        let producerFiles = ["AppState.swift", "Core/AppSupport/AppState+TextSending.swift",
            "Core/AppSupport/AppState+MediaSending.swift", "Core/AppSupport/AppState+OutgoingAttachmentRecovery.swift",
            "Core/AppSupport/AppState+MessageSendingAttachments.swift"]
        let source = try producerFiles.map { try String(contentsOf: appRoot.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END

        func functionBody(start: String, end: String) throws -> Substring {
            let startRange = try XCTUnwrap(source.range(of: start))
            let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
            return source[startRange.lowerBound..<endRange.lowerBound]
        }

        let textSend = try functionBody(
            start: "    func sendText(\n",
            end: "    func sendAttachment(\n"
        )
        let attachmentSend = try functionBody(
            start: "    func sendAttachment(\n",
            end: "    func sendVoiceMessage(\n"
        )
        let voiceSend = try functionBody(
            start: "    func sendVoiceMessage(\n",
            end: "    func canRetryAttachmentUpload("
        )

        XCTAssertTrue(textSend.contains("enqueueDurableOutgoing("))
        for body in [textSend, attachmentSend, voiceSend] {
            XCTAssertFalse(body.contains("scheduleConversationSnapshotCacheWrite("))
        }
        XCTAssertTrue(source.contains("messagePersistence.enqueueOutgoing("))
    }
}

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
extension HTTPTransportTests {
    private func makeRouteV5Client(transport: HTTPTransport, context: IMAPIContext, defaults: UserDefaults,
                                   enabledService: IMRuntimeRouteService? = .imAPI) -> IMAPIClient {
        let arguments = enabledService.map { ["-WXT.RouteV5." + $0.rawValue, "YES"] } ?? []
        return makeRouteV5Client(transport: transport, context: context,
            routeStore: IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: arguments))
    }

    private func makeRouteV5Client(transport: HTTPTransport, context: IMAPIContext, routeStore: IMRuntimeRouteStore) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform-primary.example.com")!,
            tenantBase: URL(string: "https://tenant-primary.example.com")!,
            imBase: URL(string: "https://im-primary.example.com")!,
            httpTransport: transport, runtimeRouteStore: routeStore,
            startupContext: context, bootstrapNetworkReachable: { true }
        )
    }

    func testRouteV5TenantHeadersBeforeThreeSecondsStopFailoverWithSlowBody() async throws {
        let suite = "RouteV5Headers.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        let transport = RouteV5TestTransport { request, timing in
            if request.url?.host == "tenant-primary.example.com" {
                try await Task.sleep(nanoseconds: 2_900_000_000)
                timing?.receivedHeaders(200)
                try await Task.sleep(nanoseconds: 650_000_000)
            }
            return HTTPTransportResult(data: Data(#"{"ok":true,"data":{"tenant_id":"tenant-1","app_id":"\#(context.appID)","im_uid":"uid-1","device_id":"device-1","tenant":{"id":"tenant-1","name":"Test"}}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        }
        let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults, enabledService: .tenantAPI)
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
        let result = try await client.tenantContext(context: context)
        XCTAssertEqual(result.tenantID, "tenant-1")
        let events = await transport.events
        XCTAssertEqual(events.map(\.host), ["tenant-primary.example.com"])
    }

    func testRouteV5HTTPAndTLSFailuresDoNotTryAnotherIMOrigin() async throws {
        let suite = "RouteV5Status.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        for status in [401, 403, 429, 502, 503, 504, 0] {
            let transport = RouteV5TestTransport { _, timing in
                if status == 0 { throw URLError(.serverCertificateUntrusted) }
                timing?.receivedHeaders(status)
                return HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: status)
            }
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
            _ = client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring())
            do {
                _ = try await client.syncMessages(context: context, channelID: "g1", channelType: "group",
                                                  afterSeq: 0, beforeSeq: nil, limit: 1)
                XCTFail("expected the selected origin's failure")
            } catch {
                if status == 0 { XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted) }
            }
            let events = await transport.events
            XCTAssertEqual(events.map(\.host), ["im-primary.example.com"], "status=\(status)")
        }
    }

    func testRouteV5IMValidatesBackupThenUsesItForFutureCallsAndRollbackRestoresOldRoute() async throws {
        let suite = "RouteV5IM.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        let transport = RouteV5TestTransport { request, timing in
            if request.url?.host == "im-primary.example.com", timing != nil {
                throw URLError(.networkConnectionLost)
            }
            timing?.receivedHeaders(200)
            return HTTPTransportResult(data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        }
        let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
        do {
            _ = try await client.syncMessages(context: context, channelID: "g1", channelType: "group",
                                              afterSeq: 0, beforeSeq: nil, limit: 1)
            XCTFail("the original single-send request should retain its transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        _ = try await client.syncMessages(context: context, channelID: "g1", channelType: "group",
                                          afterSeq: 0, beforeSeq: nil, limit: 1)
        defaults.set(false, forKey: "WXT.RouteV5.im_api")
        _ = try await client.syncMessages(context: context, channelID: "g1", channelType: "group",
                                          afterSeq: 0, beforeSeq: nil, limit: 1)
        let rollback = makeRouteV5Client(transport: transport, context: context, defaults: defaults, enabledService: nil)
        _ = try await rollback.syncMessages(context: context, channelID: "g1", channelType: "group",
                                            afterSeq: 0, beforeSeq: nil, limit: 1)
        let events = await transport.events
        XCTAssertEqual(events.map(\.host), ["im-primary.example.com", "im-backup.example.net",
                                             "im-backup.example.net", "im-backup.example.net", "im-primary.example.com"])
        XCTAssertGreaterThanOrEqual(events[1].start - events[0].start, IMRouteV5Attempt.interval)
    }

    func testRouteV5PlatformLateStatusSecurityFailureAndValidRecoveryRemainAuthoritative() async throws {
        let context = makeContext()
        let primary = "platform-primary.example.com"
        let backup = "platform-backup.example.net"
        let hosts = [URL(string: "https://\(primary)")!, URL(string: "https://\(backup)")!]
        let valid = Data(#"{"ok":true,"data":{"app_id":"\#(context.appID)","platform":"ios","status":"enabled"}}"#.utf8)
        for status in [429, 503, 0, 200] {
            let suite = "RouteV5Platform.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let transport = RouteV5TestTransport(beforeDispatch: { request in
                if status == 429, request.url?.host == backup {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }) { request, timing in
                if request.url?.host == primary {
                    try await Task.sleep(nanoseconds: 3_140_000_000)
                    if status == 0 { throw URLError(.serverCertificateUntrusted) }
                    timing?.receivedHeaders(status)
                    return .init(data: status == 200 ? valid : Data(), isHTTPResponse: true, statusCode: status)
                }
                try? await Task.sleep(nanoseconds: 420_000_000)
                timing?.receivedHeaders(200)
                return .init(data: valid, isHTTPResponse: true, statusCode: 200)
            }
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults, enabledService: .platformAPI)
            let snapshot = appBootstrapForHTTPWiring(platformBase: hosts[0].absoluteString,
                platformBackups: [hosts[1].absoluteString]).runtimeRouteSnapshot
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(snapshot), .applied)
            do {
                _ = try await client.currentAppPolicy(appID: context.appID)
                XCTAssertEqual(status, 200)
            } catch {
                XCTAssertNotEqual(status, 200)
                if status == 0 { XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted) }
            }
            let scope = IMRouteV5Scope(appID: context.appID,
                environment: snapshot.environment ?? IMAPIClient.configuredAppBootstrapEnvironment(),
                tenantID: nil, service: "platform_api")
            XCTAssertEqual(client.runtimeRouteStore.lastSuccessfulRoute(scope, in: hosts), status == 200 ? hosts[0] : nil)
            let events = await transport.events
            XCTAssertEqual(events.first?.host, primary)
            if status == 429 { XCTAssertEqual(events.map(\.host), [primary]) }
            if let standby = events.first(where: { $0.host == backup }), let first = events.first {
                XCTAssertGreaterThanOrEqual(standby.start - first.start, IMRouteV5Attempt.interval)
            }
        }
    }

    func testRouteV5LateHTTPSuccessHeadersAllowValidatedStandbyBeforePrimaryBody() async throws {
        let context = makeContext()
        let primary = "platform-primary.example.com"
        let backup = "platform-backup.example.net"
        let hosts = [URL(string: "https://\(primary)")!, URL(string: "https://\(backup)")!]
        let data = Data(#"{"ok":true,"data":{"app_id":"\#(context.appID)","platform":"ios","status":"enabled"}}"#.utf8)
        let suite = "RouteV5LateHTTPSuccess.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = RouteV5InterleavedHTTP.session { host in
            host == primary
                ? .init(headersAfter: 3_130_000_000, bodyAfterHeaders: 650_000_000, status: 200, body: data)
                : .init(headersAfter: 280_000_000, bodyAfterHeaders: 100_000_000, status: 200, body: data)
        }
        defer { session.invalidateAndCancel(); RouteV5InterleavedHTTP.reset() }
        let client = makeRouteV5Client(transport: URLSessionHTTPTransport(session: session), context: context, defaults: defaults, enabledService: .platformAPI)
        let snapshot = appBootstrapForHTTPWiring(platformBase: hosts[0].absoluteString,
            platformBackups: [hosts[1].absoluteString]).runtimeRouteSnapshot
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(snapshot), .applied)
        _ = try await client.currentAppPolicy(appID: context.appID)
        let events = RouteV5InterleavedHTTP.events()
        let primaryHeaders = try XCTUnwrap(events.firstIndex(of: "headers:\(primary)"))
        let standbyBody = try XCTUnwrap(events.firstIndex(of: "body:\(backup)"))
        let primaryBody = try XCTUnwrap(events.firstIndex(of: "body:\(primary)"))
        XCTAssertLessThan(primaryHeaders, standbyBody)
        XCTAssertLessThan(standbyBody, primaryBody)
        let scope = IMRouteV5Scope(appID: context.appID,
            environment: snapshot.environment ?? IMAPIClient.configuredAppBootstrapEnvironment(), tenantID: nil, service: "platform_api")
        XCTAssertEqual(client.runtimeRouteStore.lastSuccessfulRoute(scope, in: hosts), hosts[1])
    }

    func testRouteV5SignedPlatformDoesNotUseAnUnsignedRuntimeAlternative() async throws {
        let suite = "RouteV5Signed.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        let trusted = try XCTUnwrap(URL(string: "https://platform-primary.example.com"))
        let transport = RouteV5TestTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let client = IMAPIClient(platformBase: trusted, trustedPreloginPlatformBase: trusted, httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults, launchArgumentsForTesting: ["-WXT.RouteV5.platform_api", "YES"]), startupContext: context,
            bootstrapNetworkReachable: { true })
        let snapshot = appBootstrapForHTTPWiring(platformBase: trusted.absoluteString,
            platformBackups: ["https://platform-backup.example.net"]).runtimeRouteSnapshot
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(snapshot), .applied)
        do {
            _ = try await client.currentAppPolicy(appID: context.appID)
            XCTFail("expected the signed origin's transport error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
        let events = await transport.events
        XCTAssertEqual(events.map(\.host), [trusted.host])
    }

    func testRouteV5InvalidBackupDoesNotPersistAndServiceBackoffSuppressesNextRound() async throws {
        let suite = "RouteV5Backoff.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        let transport = RouteV5TestTransport { request, timing in
            if request.url?.host == "im-primary.example.com" { throw URLError(.cannotFindHost) }
            timing?.receivedHeaders(200)
            return HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        }
        let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
        for _ in 0..<2 {
            do {
                _ = try await client.syncMessages(context: context, channelID: "g1", channelType: "group",
                                                  afterSeq: 0, beforeSeq: nil, limit: 1)
                XCTFail("expected to keep the selected origin after an invalid backup")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cannotFindHost)
            }
        }
        let events = await transport.events
        XCTAssertEqual(events.map(\.host), ["im-primary.example.com", "im-backup.example.net", "im-primary.example.com"])
    }

    func testRouteV5SessionChangeCannotPersistALateIMBackupResult() async throws {
        let suite = "RouteV5SessionFence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        let transport = RouteV5TestTransport { request, timing in
            if request.url?.host == "im-primary.example.com" { throw URLError(.cannotConnectToHost) }
            // Deliberately return a valid response even if cancellation has reached the transport.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            timing?.receivedHeaders(200)
            return HTTPTransportResult(data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8),
                isHTTPResponse: true, statusCode: 200)
        }
        let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
        let snapshot = runtimeRouteSnapshotForHTTPWiring()
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(snapshot), .applied)
        let request = Task {
            try? await client.syncMessages(context: context, channelID: "g1", channelType: "group",
                                           afterSeq: 0, beforeSeq: nil, limit: 1)
        }
        defer { request.cancel() }
        var reachedBackup = false
        for _ in 0..<500 {
            let events = await transport.events
            if events.last?.host == "im-backup.example.net" {
                reachedBackup = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(reachedBackup)
        client.updateHTTPRouteSession(makeContext(imToken: "new-session-im-token"))
        let result = await request.value
        XCTAssertNil(result)
        let scope = IMRouteV5Scope(appID: snapshot.appID,
            environment: snapshot.environment ?? IMAPIClient.configuredAppBootstrapEnvironment(),
            tenantID: snapshot.tenantID, service: IMRuntimeRouteService.imAPI.rawValue)
        let hosts = ["https://im-primary.example.com", "https://im-backup.example.net"].compactMap(URL.init(string:))
        XCTAssertNil(client.runtimeRouteStore.lastSuccessfulRoute(scope, in: hosts))
    }

    private func makeRouteV5AppState(client: IMAPIClient, context: IMAPIContext,
                                     persistence: MessagePersistenceCoordinator? = nil) -> AppState {
        let engine = DefaultSyncEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-v5-ui-\(UUID())")
        let backing = persistence ?? MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"))
        let state = AppState(api: client, realtimeClient: PostLoginSilentRealtimeTransport(),
            messageStore: AvatarProjectionEmptyMessageStore(), messagePersistence: backing,
            remoteSyncEngine: engine, protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
        state.authenticationPresentationStore.setInitialAuthentication(true)
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        _ = engine.beginRemoteSnapshotRefresh()
        return state
    }

    func testRouteV5AvatarNormalEntryUsesTenantWinnerAndPreservesAbsoluteResource() async throws {
        let suite = "RouteV5Avatar.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        let profile = Data(#"{"ok":true,"data":{"tenant_id":"tenant-1","app_id":"\#(context.appID)","im_uid":"uid-1","device_id":"device-1","tenant":{"id":"tenant-1","name":"Test"}}}"#.utf8)
        let image = Data([1, 2, 3])
        let transport = RouteV5TestTransport { request, timing in
            if request.url?.path == "/api/tenant/context" {
                if request.url?.host == "tenant-primary.example.com" { throw URLError(.cannotConnectToHost) }
                timing?.receivedHeaders(200)
                return .init(data: profile, isHTTPResponse: true, statusCode: 200)
            }
            XCTAssertNil(timing, "binary GET must not trigger route selection")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url?.path == "/api/tenant/avatar/unavailable" {
                return .init(data: Data(), isHTTPResponse: true, statusCode: 503)
            }
            return .init(data: image, isHTTPResponse: true, statusCode: 200)
        }
        let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults, enabledService: .tenantAPI)
        let snapshot = runtimeRouteSnapshotForHTTPWiring()
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(snapshot), .applied)
        let state = makeRouteV5AppState(client: client, context: context)
        let avatar = try XCTUnwrap(state.avatarImageRouteContext)
        do { _ = try await client.tenantContext(context: context) }
        catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }

        let bytes = try await avatar.fetch("/api/tenant/avatar/fixture")
        XCTAssertEqual(bytes, image)
        do {
            _ = try await avatar.fetch("/api/tenant/avatar/unavailable")
            XCTFail("expected the selected binary origin's 503")
        } catch IMRuntimeTenantBinaryFetchError.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        }
        _ = try await client.fetchRuntimeTenantBinary("https://assets.example.org/presigned?signature=fixture", context: context)
        XCTAssertEqual(client.runtimeRouteStore.record(appID: snapshot.appID, tenantID: snapshot.tenantID).recoveryByService, [:])
        let rollback = makeRouteV5Client(transport: transport, context: context, defaults: defaults, enabledService: nil)
        _ = try await rollback.fetchRuntimeTenantBinary("/api/tenant/avatar/fixture", context: context)
        let events = await transport.events.filter { $0.path.contains("/avatar/") || $0.path == "/presigned" }
        XCTAssertEqual(events.map(\.host), ["tenant-backup.example.net", "tenant-backup.example.net", "assets.example.org", "tenant-primary.example.com"])
    }

    func testRouteV5NormalConversationOpeningKeepsSinglePageAndCoalescesIndependentLightRead() async throws {
        let context = makeContext()
        let channel = "uid-1:uid-2"
        let primary = "im-primary.example.com"
        let backup = "im-backup.example.net"
        for mode in ["light-fails", "light-timeout", "page-fails"] {
            let suite = "RouteV5Opening.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let gate = RouteV5OpeningReadGate()
            let transport = RouteV5TestTransport { request, timing in
                guard request.url?.path == "/api/im/sync" else {
                    return .init(data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
                }
                let body = try XCTUnwrap(request.httpBody)
                let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                let limit = try XCTUnwrap(payload["limit"] as? Int)
                if limit == 1 {
                    XCTAssertNotNil(timing)
                    if request.url?.host == primary {
                        if mode == "light-timeout" { try await Task.sleep(nanoseconds: 3_400_000_000); throw URLError(.timedOut) }
                        await gate.wait()
                        timing?.receivedHeaders(403)
                        return .init(data: Data(#"{"ok":false,"error":{"code":"device_revoked","message":"fixture"}}"#.utf8),
                            isHTTPResponse: true, statusCode: 403)
                    }
                    timing?.receivedHeaders(200)
                    return .init(data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
                }
                XCTAssertNil(timing, "history loads do not make routing decisions")
                if limit == 100 || mode == "page-fails" {
                    return .init(data: Data(), isHTTPResponse: true, statusCode: 503)
                }
                XCTAssertEqual(limit, 20)
                let items: [[String: Any]] = (1...20).map { seq in
                    ["message_id": "opening-\(seq)", "channel_id": channel, "channel_type": "direct",
                     "channel_seq": seq, "from_uid": "uid-2", "content_type": "text", "payload": ["text": "message"]]
                }
                let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["items": items]])
                return .init(data: data, isHTTPResponse: true, statusCode: 200)
            }
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
            let snapshot = runtimeRouteSnapshotForHTTPWiring()
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(snapshot), .applied)
            let state = makeRouteV5AppState(client: client, context: context)
            let history = ChatHistoryActions.bind(state)
            history.prepareConversationTailWindowForEntry(channel)
            history.syncConversationMessagesIfNeeded(channel, force: true, silent: true, trimToLatestWindow: true)
            if mode == "page-fails" {
                try await waitForCondition(iterations: 300) {
                    state.conversationStore.historyMessage(conversationID: channel) == "聊天记录同步失败，请稍后重试"
                }
                XCTAssertEqual(state.conversationStore.historyMessage(conversationID: channel), "聊天记录同步失败，请稍后重试")
            } else {
                try await waitForCondition(iterations: 300) {
                    state.conversationStore.conversationMessageSnapshot(id: channel)?.messages.count == 20
                }
                XCTAssertEqual(state.conversationStore.conversationMessageSnapshot(id: channel)?.messages.count, 20)
            }
            for _ in 0..<3 {
                history.prepareConversationTailWindowForEntry(channel)
            }
            await gate.release()
            XCTAssertTrue(state.hasActiveIMSession)
            let scope = IMRouteV5Scope(appID: snapshot.appID,
                environment: snapshot.environment ?? IMAPIClient.configuredAppBootstrapEnvironment(),
                tenantID: snapshot.tenantID, service: "im_api")
            let origins = [URL(string: "https://\(primary)")!, URL(string: "https://\(backup)")!]
            if mode == "light-timeout" {
                try await waitForCondition(iterations: 500) {
                    client.runtimeRouteStore.lastSuccessfulRoute(scope, in: origins) == origins[1]
                }
                _ = try await client.syncMessages(context: context, channelID: channel, channelType: "direct", afterSeq: 0, limit: 20)
            } else {
                XCTAssertNil(client.runtimeRouteStore.lastSuccessfulRoute(scope, in: origins))
            }
            let events = await transport.events.filter { $0.path == "/api/im/sync" }
            let byLimit = try Dictionary(grouping: events) { event in
                let data = try XCTUnwrap(event.body)
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                return try XCTUnwrap(body["limit"] as? Int)
            }
            XCTAssertEqual(byLimit[20]?.map(\.host), mode == "light-timeout" ? [primary, backup] : [primary])
            XCTAssertEqual(byLimit[1]?.map(\.host), mode == "light-timeout" ? [primary, backup] : [primary])
        }
    }

    func testRouteV5SingleAuthorizedIMOriginOpensWithOnlyOriginalTwenty() async throws {
        for backups in [[], ["https://im-primary.example.com:443"]] {
            let suite = "RouteV5SingleOpening.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let context = makeContext()
            let transport = RouteV5TestTransport { _, timing in
                XCTAssertNil(timing)
                return .init(data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
            }
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring(imBackups: backups)), .applied)
            let state = makeRouteV5AppState(client: client, context: context)
            let history = ChatHistoryActions.bind(state)
            let channel = "uid-1:uid-2"
            history.prepareConversationTailWindowForEntry(channel)
            history.syncConversationMessagesIfNeeded(channel, force: true, silent: true, trimToLatestWindow: true)
            try await waitForCondition { !state.conversationStore.hasHistoryLoadingIDs() }
            let events = await transport.events.filter { $0.path == "/api/im/sync" }
            let payloads = try events.map { event in
                try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(event.body)) as? [String: Any])
            }
            XCTAssertEqual(payloads.compactMap { $0["limit"] as? Int }, [20])
        }
    }

    func testRouteV5ReopenedLegacyClaimCannotSendAtSharedOutletInEnabledProcess() async throws {
        let context = makeContext()
        let channel = "uid-1:uid-2"
        for mode in ["manual", "automatic", "known-unsent"] {
            let suite = "RouteV5ClaimSwitch.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let transport = RouteV5TestTransport { request, _ in
                XCTAssertEqual(request.url?.path, "/api/im/messages")
                return .init(data: Data(#"{"ok":true,"data":{"message":{"message_id":"accepted","channel_seq":4}}}"#.utf8),
                             isHTTPResponse: true, statusCode: 201)
            }
            let legacy = makeRouteV5Client(transport: transport, context: context, defaults: defaults, enabledService: nil)
            XCTAssertEqual(legacy.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let support = root.appendingPathComponent("support")
            let caches = root.appendingPathComponent("caches")
            let oldState = makeRouteV5AppState(client: legacy, context: context, persistence: MessagePersistenceCoordinator(
                applicationSupportBase: support, cachesBase: caches
            ))
            var conversation = makeDirectConversation(id: channel)
            let id = "local-claim-\(mode)"
            conversation.messages = [LocalMessageTestFixture.message(id: id, sequence: 0, outgoing: true, status: .failed)]
            oldState.conversationStore.hydrateCachedConversations([conversation])
            let oldTicket = try await oldState.enqueueDurableOutgoing(messageID: id, conversationID: channel, operationKind: "send_text",
                context: context, scope: oldState.remoteDataScopeKey(for: context))
            let known = mode == "known-unsent"
            if known {
                try await oldState.messagePersistence.reserveOutgoingSend(ticket: oldTicket, clientMessageID: id)
                await oldState.messagePersistence.releaseUnsentOutgoing(ticket: oldTicket, clientMessageID: id)
            }
            try await oldState.messagePersistence.updateOutboxState(ticket: oldTicket, clientMessageID: id,
                state: known ? .retryWait : .uncertain, uncertain: !known, now: Date(timeIntervalSince1970: 100))
            let claimed = try await oldState.messagePersistence.claimOutboxForReplay(ticket: oldTicket,
                authorizationGeneration: oldTicket.sessionGeneration, trigger: mode == "automatic" ? .automatic : .userInitiated,
                clientMessageID: mode == "automatic" ? nil : id, holdLegacyUnconfirmedSends: oldState.usesProtectedMessageSends)
            XCTAssertEqual(claimed.map(\.clientMessageID), [id])
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
            let restarted = MessagePersistenceCoordinator(applicationSupportBase: support, cachesBase: caches)
            let state = makeRouteV5AppState(client: client, context: context, persistence: restarted)
            state.conversationStore.hydrateCachedConversations([conversation])
            let loaded = try await restarted.activateAndLoad(context: context, sessionGeneration: oldTicket.sessionGeneration + 1)
            let ticket = loaded.ticket
            state.localMessageTicket = ticket
            do {
                _ = try await state.withDurableOutgoingSend(ticket: ticket, messageID: id) {
                    try await client.sendText(context: context, conversation: conversation, channelID: channel,
                        text: "fixture", quote: nil, clientMessageID: id)
                }
                XCTFail("persisted legacy claim reached transport in an enabled process")
            } catch let error as MessageSendOutcomeUncertainError {
                XCTAssertFalse(known)
                XCTAssertTrue(error.requiresReadback)
            } catch is CancellationError {
                XCTAssertTrue(known)
            }
            let events = await transport.events
            XCTAssertTrue(events.isEmpty)
            let authority = try await state.messagePersistence.outgoingAuthority(ticket: ticket, clientMessageID: id)
            XCTAssertEqual(authority?.state, known ? "retry_wait" : "confirmation_required")
            let next = try await state.messagePersistence.claimOutboxForReplay(ticket: ticket,
                authorizationGeneration: ticket.sessionGeneration, trigger: .userInitiated,
                clientMessageID: id, holdLegacyUnconfirmedSends: true)
            XCTAssertEqual(next.map(\.clientMessageID), known ? [id] : [])
            if known {
                _ = try await state.withDurableOutgoingSend(ticket: ticket, messageID: id) {
                    try await client.sendText(context: context, conversation: conversation, channelID: channel,
                        text: "fixture", quote: nil, clientMessageID: id)
                }
                let writes = await transport.events
                XCTAssertEqual(writes.count, 1)
            }
        }
    }

    func testRouteV5ColdAndManualOutboxConfirmationResumesServerCursorBeyondFirstWindow() async throws {
        let suite = "RouteV5ConfirmationPages.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        let channel = "uid-1:uid-2"
        let early = "local-page-two"
        let deep = "local-page-five"
        let absent = "local-not-found"
        let fixture = RouteV5ConfirmationPageFixture()
        let transport = RouteV5TestTransport { request, _ in
            if request.url?.path == "/api/platform/apps/current-policy" {
                return .init(data: Data(#"{"ok":true,"data":{"app_id":"\#(context.appID)","platform":"ios","status":"enabled"}}"#.utf8),
                             isHTTPResponse: true, statusCode: 200)
            }
            XCTAssertEqual(request.url?.path, "/api/im/sync")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let before = try XCTUnwrap(body["before_seq"] as? Int64)
            XCTAssertEqual(body["limit"] as? Int, 50)
            XCTAssertEqual(body["channel_id"] as? String, channel)
            XCTAssertEqual(body["tenant_id"] as? String, context.tenantID)
            await fixture.pauseIfNeeded(before: before)
            if let status = await fixture.errorStatus(before: before) {
                return .init(data: Data(), isHTTPResponse: true, statusCode: status)
            }
            let high = min(before - 1, 205)
            let low = max(1, high - 49)
            let messages: [[String: Any]] = (low...max(low, high)).map { seq in
                let id = seq == 126 ? early : (seq == 4 || seq == 180 ? deep : "other-\(seq)")
                return ["message_id": "server-\(seq)", "client_msg_no": id, "channel_id": channel, "channel_type": "direct",
                    "channel_seq": seq, "from_uid": seq == 180 ? "uid-2" : "uid-1", "content_type": "text",
                    "payload": ["text": "fixture"]]
            }
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
                "items": messages, "has_more_before": low > 1, "next_before_seq": low
            ]])
            return .init(data: data, isHTTPResponse: true, statusCode: 200)
        }
        let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let support = root.appendingPathComponent("support")
        let caches = root.appendingPathComponent("caches")
        func newState() -> AppState {
            makeRouteV5AppState(client: client, context: context,
                persistence: MessagePersistenceCoordinator(applicationSupportBase: support, cachesBase: caches))
        }
        var conversation = makeDirectConversation(id: channel)
        conversation.messages = [early, deep, absent].map {
            LocalMessageTestFixture.message(id: $0, sequence: 0, outgoing: true, status: .failed)
        }
        let original = newState()
        original.conversationStore.hydrateCachedConversations([conversation])
        var generation: UInt64 = 0
        for id in [early, deep, absent] {
            let ticket = try await original.enqueueDurableOutgoing(messageID: id, conversationID: channel,
                operationKind: "send_text", context: context, scope: original.remoteDataScopeKey(for: context))
            try await original.messagePersistence.reserveOutgoingSend(ticket: ticket, clientMessageID: id)
            generation = ticket.sessionGeneration
        }

        let cold = newState()
        cold.conversationStore.hydrateCachedConversations([conversation])
        let loaded = try await cold.messagePersistence.activateAndLoad(context: context, sessionGeneration: generation + 1)
        cold.localMessageTicket = loaded.ticket
        await cold.recoverDurableOutbox(ticket: loaded.ticket, scope: cold.remoteDataScopeKey(for: context))
        cold.resend(messageID: deep, in: channel) // joins the cold pass
        try await waitForCondition { cold.outgoingConfirmationReads.isEmpty }
        let first = try await cold.messagePersistence.outgoingAuthority(ticket: loaded.ticket, clientMessageID: early)
        let notYet = try await cold.messagePersistence.outgoingAuthority(ticket: loaded.ticket, clientMessageID: deep)
        XCTAssertEqual(first?.authoritativeMessageID, "server-126")
        XCTAssertEqual(notYet?.state, "confirmation_required")
        let firstEvents = await transport.events.filter { $0.path == "/api/im/sync" }
        XCTAssertEqual(firstEvents.count, 3)

        let interrupted = newState()
        let interruptedDB = try await interrupted.messagePersistence.activateAndLoad(context: context, sessionGeneration: generation + 2)
        interrupted.localMessageTicket = interruptedDB.ticket
        await fixture.armPause()
        interrupted.resend(messageID: deep, in: channel)
        for _ in 0..<100 {
            if await fixture.isPaused() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didPause = await fixture.isPaused()
        XCTAssertTrue(didPause)
        var rotatedContext = context
        rotatedContext.imToken = "rotated-im-token"
        rotatedContext.credentialRevision += 1
        interrupted.overrideAPIContextForTesting(rotatedContext)
        await fixture.release()
        try await waitForCondition { interrupted.outgoingConfirmationReads.isEmpty }

        client.updateHTTPRouteSession(context)
        let manual = newState()
        manual.conversationStore.hydrateCachedConversations([conversation])
        let reopened = try await manual.messagePersistence.activateAndLoad(context: context, sessionGeneration: generation + 3)
        manual.localMessageTicket = reopened.ticket
        // An explicit permission response and an HTTP failure leave the same cursor pending.
        for status in [403, 503, 200] {
            await fixture.setError(status == 200 ? nil : status)
            manual.resend(messageID: deep, in: channel)
            let targetCount = status == 403 ? 5 : (status == 503 ? 6 : 8)
            for _ in 0..<100 {
                if await transport.events.filter({ $0.path == "/api/im/sync" }).count >= targetCount,
                   manual.outgoingConfirmationReads.isEmpty { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let second = try await manual.messagePersistence.outgoingAuthority(ticket: reopened.ticket, clientMessageID: deep)
        let unfound = try await manual.messagePersistence.outgoingAuthority(ticket: reopened.ticket, clientMessageID: absent)
        XCTAssertEqual(second?.authoritativeMessageID, "server-4")
        XCTAssertEqual(unfound?.state, "confirmation_required")
        let allEvents = await transport.events
        XCTAssertFalse(allEvents.contains { $0.path == "/api/im/messages" })
        let events = allEvents.filter { $0.path == "/api/im/sync" }
        let cursors: [Int64] = try events.map {
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap($0.body)) as? [String: Any])
            return try XCTUnwrap(body["before_seq"] as? Int64)
        }
        XCTAssertEqual(cursors, [Int64.max, 156, 106, 56, 56, 56, 56, 6])
    }

    func testRouteV5HistoryConfirmationRevokedBeforeSQLiteCommitPreservesStaging() async throws {
        for change in ["route", "winner", "session", "storage"] {
            let suite = "RouteV5ConfirmationCommit.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let context = makeContext()
            let channel = "uid-1:uid-2"
            let id = "local-held-attachment"
            let bytes = Data([2, 4, 6])
            let page = Data(#"{"ok":true,"data":{"items":[{"message_id":"stored-attachment","client_msg_no":"\#(id)","from_uid":"uid-1","channel_id":"\#(channel)","channel_type":"direct","channel_seq":9,"content_type":"text","payload":{"text":"fixture"}}],"has_more_before":true,"next_before_seq":9}}"#.utf8)
            let transport = RouteV5TestTransport { request, _ in
                if request.url?.path == "/api/platform/apps/current-policy" {
                    let policy = Data(#"{"ok":true,"data":{"app_id":"\#(context.appID)","platform":"ios","status":"enabled"}}"#.utf8)
                    return .init(data: policy, isHTTPResponse: true, statusCode: 200)
                }
                XCTAssertEqual(request.url?.path, "/api/im/sync")
                return .init(data: page, isHTTPResponse: true, statusCode: 200)
            }
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
            let state = makeRouteV5AppState(client: client, context: context)
            var conversation = makeDirectConversation(id: channel)
            conversation.messages = [LocalMessageTestFixture.attachmentMessage(id: id, sizeBytes: Int64(bytes.count))]
            state.conversationStore.hydrateCachedConversations([conversation])
            let ticket = try await seedHeldConfirmation(id: id, channel: channel, context: context, state: state, attachment: bytes)
            let initial = try await state.messagePersistence.recoverableOutbox(ticket: ticket)
            let held = try XCTUnwrap(initial.first)
            let url = try await state.messagePersistence.stagedAttachmentFileURL(ticket: ticket, item: held)
            let staged = try XCTUnwrap(url)
            XCTAssertEqual(try Data(contentsOf: staged), bytes)
            let route = try XCTUnwrap(client.outgoingConfirmationRoute(context: context))
            let read = OutgoingConfirmationRead(ticket: ticket, channelID: channel, channelType: "direct")
            let cursorScope = read.cursorScope(authority: route.cursorAuthority)
            let key = OutgoingConfirmationRead.cursorKey(id)
            client.runtimeRouteStore.saveOutgoingConfirmationCursors([key: 12], scope: cursorScope)

            let gate = RouteV5OpeningReadGate()
            await state.messagePersistence.setBeforeHistoryConfirmationWriteForTesting { await gate.wait() }
            state.resend(messageID: id, in: channel)
            for _ in 0..<200 {
                if await gate.hasWaiter { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let reachedWrite = await gate.hasWaiter
            XCTAssertTrue(reachedWrite, change)
            var currentTicket = ticket
            switch change {
            case "route":
                XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring(revision: 2)), .applied)
            case "winner":
                let snapshot = try XCTUnwrap(client.tenantRouteSnapshot)
                let scope = IMRouteV5Scope(appID: snapshot.appID,
                    environment: snapshot.environment ?? IMAPIClient.configuredAppBootstrapEnvironment(),
                    tenantID: snapshot.tenantID, service: IMRuntimeRouteService.imAPI.rawValue)
                client.httpRoutesV5.confirmed(try XCTUnwrap(URL(string: "https://im-backup.example.net")), scope: scope)
            case "session":
                var renewed = context
                renewed.credentialRevision += 1
                renewed.imToken = "renewed-fixture"
                state.overrideAPIContextForTesting(renewed)
            case "storage":
                currentTicket = try await state.messagePersistence.ensureTicket(
                    context: context, sessionGeneration: ticket.sessionGeneration + 1
                )
            default:
                XCTFail("unexpected authority change")
            }
            await state.messagePersistence.setBeforeHistoryConfirmationWriteForTesting(nil)
            await gate.release()
            try await waitForCondition { state.outgoingConfirmationReads.isEmpty }
            let stale = try await state.messagePersistence.outgoingAuthority(ticket: currentTicket, clientMessageID: id)
            XCTAssertEqual(stale?.state, "confirmation_required", change)
            XCTAssertEqual(try Data(contentsOf: staged), bytes, change)
            XCTAssertEqual(client.runtimeRouteStore.outgoingConfirmationCursors(scope: cursorScope), [key: 12], change)

            state.localMessageTicket = currentTicket
            await state.recoverDurableOutbox(ticket: currentTicket, scope: state.remoteDataScopeKey(for: state.apiContext))
            try await waitForCondition { state.outgoingConfirmationReads.isEmpty }
            let confirmed = try await state.messagePersistence.outgoingAuthority(ticket: currentTicket, clientMessageID: id)
            XCTAssertEqual(confirmed?.authoritativeMessageID, "stored-attachment", change)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), change)
            let events = await transport.events
            XCTAssertEqual(events.filter { $0.path == "/api/im/sync" }.count, 2, change)
            XCTAssertFalse(events.contains { $0.path == "/api/im/messages" }, change)
        }
    }

    func testRouteV5HistoryConfirmationRequiresActualAuthorizedOriginInBothModes() async throws {
        for enabled in [false, true] {
            let suite = "RouteV5HistoryOrigin.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let context = makeContext()
            let id = "local-origin-proof"
            let channel = "uid-1:uid-2"
            let page = Data(#"{"ok":true,"data":{"items":[{"message_id":"stored-origin","client_msg_no":"\#(id)","from_uid":"uid-1","channel_id":"\#(channel)","channel_type":"direct","channel_seq":1,"content_type":"text","payload":{"text":"fixture"}}],"has_more_before":false}}"#.utf8)
            let transport = RouteV5HistoryOriginTransport(page: page, appID: context.appID)
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults,
                                           enabledService: enabled ? .imAPI : nil)
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
            let state = makeRouteV5AppState(client: client, context: context)
            var conversation = makeDirectConversation(id: channel)
            conversation.messages = [LocalMessageTestFixture.message(id: id, sequence: 0, outgoing: true, status: .failed)]
            state.conversationStore.hydrateCachedConversations([conversation])
            let ticket = try await seedHeldConfirmation(id: id, channel: channel, context: context, state: state)
            let results = ["redirect", "cross-origin", "wrong-scheme", "wrong-port", "missing", "equivalent-port"]
            for (index, result) in results.enumerated() {
                await transport.setResult(result)
                await state.recoverDurableOutbox(ticket: ticket, scope: state.remoteDataScopeKey(for: context))
                try await waitForCondition { state.outgoingConfirmationReads.isEmpty }
                let observed = await transport.origins
                XCTAssertEqual(observed, Array(repeating: "https://im-primary.example.com", count: index + 1), result)
                let authority = try await state.messagePersistence.outgoingAuthority(ticket: ticket, clientMessageID: id)
                XCTAssertEqual(authority?.state, result == "equivalent-port" ? "acked" : "confirmation_required", result)
            }
        }
    }

    func testRouteV5ProductLaunchSnapshotControlsRouteAndHistoryCommitDespiteDefaultsWrites() async throws {
        let suite = "RouteV5ProductLaunch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "WXTHTTPRouteV5Defaults") as? [String: String])
        let expected = ProcessInfo.processInfo.environment["WXT_ROUTE_V5_TEST_EXPECTED"].map {
            Set($0.split(separator: ",").map(String.init))
        } ?? Set(flags.keys.filter { flags[$0] == "YES" })
        for service in flags.keys {
            defaults.set(!expected.contains(service), forKey: "WXT.RouteV5." + service)
        }
        let store = IMRuntimeRouteStore(defaults: defaults)
        XCTAssertEqual(Set(flags.keys.filter(store.routeV5Enabled)), expected)
        let context = makeContext()
        let id = "local-startup-held"
        let channel = "uid-1:uid-2"
        let page = Data(#"{"ok":true,"data":{"items":[{"message_id":"stored-launch","client_msg_no":"\#(id)","from_uid":"uid-1","channel_id":"\#(channel)","channel_type":"direct","channel_seq":1,"content_type":"text","payload":{"text":"fixture"}}],"has_more_before":false}}"#.utf8)
        let transport = RouteV5TestTransport { request, _ in
            if request.url?.path == "/api/platform/apps/current-policy" {
                let policy = Data(#"{"ok":true,"data":{"app_id":"\#(context.appID)","platform":"ios","status":"enabled"}}"#.utf8)
                return .init(data: policy, isHTTPResponse: true, statusCode: 200)
            }
            XCTAssertEqual(request.url?.path, "/api/im/sync")
            return .init(data: page, isHTTPResponse: true, statusCode: 200)
        }
        let client = makeRouteV5Client(transport: transport, context: context, routeStore: store)
        let snapshot = runtimeRouteSnapshotForHTTPWiring()
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(snapshot), .applied)
        let scope = IMRouteV5Scope(appID: snapshot.appID,
            environment: snapshot.environment ?? IMAPIClient.configuredAppBootstrapEnvironment(),
            tenantID: snapshot.tenantID, service: IMRuntimeRouteService.imAPI.rawValue)
        client.httpRoutesV5.confirmed(try XCTUnwrap(URL(string: "https://im-backup.example.net")), scope: scope)
        let state = makeRouteV5AppState(client: client, context: context)
        var conversation = makeDirectConversation(id: channel)
        let bytes = Data([4, 5, 6])
        conversation.messages = [LocalMessageTestFixture.attachmentMessage(id: id, sizeBytes: Int64(bytes.count))]
        state.conversationStore.hydrateCachedConversations([conversation])
        let ticket = try await seedHeldConfirmation(id: id, channel: channel, context: context, state: state, attachment: bytes)
        let rows = try await state.messagePersistence.recoverableOutbox(ticket: ticket)
        let item = try XCTUnwrap(rows.first)
        let stagedURL = try await state.messagePersistence.stagedAttachmentFileURL(ticket: ticket, item: item)
        let staged = try XCTUnwrap(stagedURL)

        _ = try await client.syncMessages(context: context, channelID: channel, channelType: "direct",
                                          afterSeq: 0, beforeSeq: nil, limit: 20)
        let gate = RouteV5OpeningReadGate()
        await state.messagePersistence.setBeforeHistoryConfirmationWriteForTesting { await gate.wait() }
        await state.recoverDurableOutbox(ticket: ticket, scope: state.remoteDataScopeKey(for: context))
        for _ in 0..<200 {
            if await gate.hasWaiter { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let reachedWrite = await gate.hasWaiter
        XCTAssertTrue(reachedWrite)
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
        for service in flags.keys {
            let key = "WXT.RouteV5." + service
            defaults.removeObject(forKey: key)
            defaults.set(expected.contains(service), forKey: key)
            defaults.set(!expected.contains(service), forKey: key)
        }
        let reopenedStore = IMRuntimeRouteStore(defaults: defaults)
        XCTAssertEqual(Set(flags.keys.filter(reopenedStore.routeV5Enabled)), expected)
        await state.messagePersistence.setBeforeHistoryConfirmationWriteForTesting(nil)
        await gate.release()
        try await waitForCondition { state.outgoingConfirmationReads.isEmpty }
        let confirmed = try await state.messagePersistence.outgoingAuthority(ticket: ticket, clientMessageID: id)
        XCTAssertEqual(confirmed?.authoritativeMessageID, "stored-launch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let events = await transport.events
        let historyHosts = events.filter { $0.path == "/api/im/sync" }.map(\.host)
        let expectedHost = expected.contains("im_api") ? "im-backup.example.net" : "im-primary.example.com"
        XCTAssertEqual(historyHosts, [expectedHost, expectedHost])
        XCTAssertFalse(events.contains { $0.path == "/api/im/messages" })
        print("route-v5-launch pid=\(ProcessInfo.processInfo.processIdentifier) services=\(expected.sorted()) history=\(historyHosts)")
    }

    func testRouteV5ColdConfirmationRotationReachesFifthConversationWithFourPending() async throws {
        let suite = "RouteV5ConfirmationRotation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        func makeState(client: IMAPIClient) -> AppState {
            makeRouteV5AppState(client: client, context: context, persistence: MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")
            ))
        }
        let fixture = RouteV5RotationFixture()
        let transport = RouteV5TestTransport { request, _ in
            if request.url?.path == "/api/platform/apps/current-policy" {
                let policy = Data(#"{"ok":true,"data":{"app_id":"\#(context.appID)","platform":"ios","status":"enabled"}}"#.utf8)
                return .init(data: policy, isHTTPResponse: true, statusCode: 200)
            }
            XCTAssertEqual(request.url?.path, "/api/im/sync")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let channel = try XCTUnwrap(body["channel_id"] as? String)
            let matches = await fixture.responseMatches(channel: channel)
            let items = matches
                ? #"{"message_id":"stored-rotation","client_msg_no":"local-\#(channel)","from_uid":"uid-1","channel_id":"\#(channel)","channel_type":"group","channel_seq":1,"content_type":"text","payload":{"text":"fixture"}}"# : ""
            let data = Data(#"{"ok":true,"data":{"items":[\#(items)],"has_more_before":false}}"#.utf8)
            return .init(data: data, isHTTPResponse: true, statusCode: 200)
        }
        let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
        let original = makeState(client: client)
        let conversations = (1...5).map { index in
            var conversation = makeGroupConversation(id: "rotation-\(index)")
            conversation.messages = [LocalMessageTestFixture.message(id: "local-\(conversation.id)", sequence: 0,
                                                                    outgoing: true, status: .failed)]
            return conversation
        }
        original.conversationStore.hydrateCachedConversations(conversations)
        var generation: UInt64 = 0
        for conversation in conversations {
            let ticket = try await seedHeldConfirmation(id: "local-\(conversation.id)", channel: conversation.id,
                                                        context: context, state: original)
            generation = ticket.sessionGeneration
        }
        let allChannels = Set(conversations.map(\.id))
        let ticket = try XCTUnwrap(original.localMessageTicket)
        let ordered = allChannels.sorted {
            OutgoingConfirmationRead(ticket: ticket, channelID: $0, channelType: "group").rotationPosition
                < OutgoingConfirmationRead(ticket: ticket, channelID: $1, channelType: "group").rotationPosition
        }
        let fifth = try XCTUnwrap(ordered.last)
        await fixture.match(fifth)
        await original.recoverDurableOutbox(ticket: ticket, scope: original.remoteDataScopeKey(for: context))
        XCTAssertEqual(original.outgoingConfirmationReads.count, 4)
        try await waitForCondition { original.outgoingConfirmationReads.isEmpty }
        let firstRound = await fixture.visited
        XCTAssertEqual(Set(firstRound), Set(ordered.prefix(4)))
        XCTAssertEqual(firstRound.count, 4)

        let reopened = makeState(client: client)
        let load = try await reopened.messagePersistence.activateAndLoad(context: context, sessionGeneration: generation + 1)
        reopened.localMessageTicket = load.ticket
        await reopened.recoverDurableOutbox(ticket: load.ticket, scope: reopened.remoteDataScopeKey(for: context))
        XCTAssertEqual(reopened.outgoingConfirmationReads.count, 4)
        try await waitForCondition { reopened.outgoingConfirmationReads.isEmpty }
        let confirmed = try await reopened.messagePersistence.outgoingAuthority(ticket: load.ticket, clientMessageID: "local-\(fifth)")
        XCTAssertEqual(confirmed?.authoritativeMessageID, "stored-rotation")
        let remaining = try await reopened.messagePersistence.recoverableOutbox(ticket: load.ticket)
        XCTAssertEqual(Set(remaining.map(\.channelID)), Set(ordered.prefix(4)))
        let events = await transport.events
        XCTAssertEqual(events.filter { $0.path == "/api/im/sync" }.count, 8)
        XCTAssertFalse(events.contains { $0.path == "/api/im/messages" })
    }

    private func seedHeldConfirmation(id: String, channel: String, context: IMAPIContext, state: AppState,
                                      attachment: Data? = nil) async throws -> LocalMessageSessionTicket {
        let ticket = try await state.enqueueDurableOutgoing(messageID: id, conversationID: channel,
            operationKind: attachment == nil ? "send_text" : "send_attachment", context: context,
            scope: state.remoteDataScopeKey(for: context), attachmentData: attachment,
            attachmentName: "fixture.bin", attachmentMimeType: "application/octet-stream")
        if attachment != nil {
            try await state.messagePersistence.updateOutboxState(ticket: ticket, clientMessageID: id,
                state: .awaitingAcknowledgement, attachmentPhase: "message_send")
        }
        try await state.messagePersistence.reserveOutgoingSend(ticket: ticket, clientMessageID: id)
        return ticket
    }

    func testRouteV5DurableWriteRetains503AndStaleResponseAfterRollbackRelaunch() async throws {
        for mode in ["coded503", "reconfigured", "unsent", "committed"] {
            let suite = "RouteV5Durable.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let context = makeContext()
            let channel = "uid-1:uid-2"
            let messageID = "local_route-v5-\(mode)"
            let ledger = RouteV5StoredMessageFixture()
            let transport = RouteV5TestTransport { request, timing in
                if request.url?.path == "/api/im/messages" {
                    if mode == "unsent" { throw URLError(.cannotFindHost) }
                    if mode == "committed" {
                        let body = try XCTUnwrap(request.httpBody)
                        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                        let identity = try XCTUnwrap(payload["client_msg_no"] as? String)
                        XCTAssertEqual(identity, messageID)
                        let sync = Data(#"{"ok":true,"data":{"items":[{"message_id":"stored-v5","client_msg_no":"\#(identity)","from_uid":"uid-1","channel_id":"uid-1:uid-2","channel_type":"direct","channel_seq":1,"content_type":"text","payload":{"text":"fixture"}}]}}"#.utf8)
                        await ledger.commit(sync)
                        throw URLError(.networkConnectionLost)
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                    if mode == "coded503" {
                        return .init(data: Data(#"{"ok":false,"error":{"code":"auth_dependency_unavailable","message":"unavailable"}}"#.utf8),
                                     isHTTPResponse: true, statusCode: 503)
                    }
                    return .init(data: Data(#"{"ok":true,"data":{"message":{"message_id":"stored","channel_seq":1}}}"#.utf8),
                                 isHTTPResponse: true, statusCode: 201)
                }
                timing?.receivedHeaders(200)
                let data = await ledger.syncResponse ?? Data(#"{"ok":true,"data":{"items":[]}}"#.utf8)
                return .init(data: data, isHTTPResponse: true, statusCode: 200)
            }
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let support = root.appendingPathComponent("support")
            let caches = root.appendingPathComponent("caches")
            let persistence = MessagePersistenceCoordinator(applicationSupportBase: support, cachesBase: caches)
            let state = makeRouteV5AppState(client: client, context: context, persistence: persistence)
            var conversation = makeDirectConversation(id: channel)
            let outgoing = LocalMessageTestFixture.message(id: messageID, sequence: 0, outgoing: true, status: .failed)
            conversation.messages = [outgoing]
            state.conversationStore.hydrateCachedConversations([conversation])
            let scope = state.remoteDataScopeKey(for: context)
            let ticket = try await state.enqueueDurableOutgoing(messageID: messageID, conversationID: channel,
                operationKind: "send_text", context: context, scope: scope)
            let send = Task {
                try await state.withDurableOutgoingSend(ticket: ticket, messageID: messageID) {
                    try await client.sendText(context: context, conversation: conversation, channelID: channel,
                        text: "fixture", quote: nil, clientMessageID: messageID)
                }
            }
            if mode == "reconfigured" {
                for _ in 0..<100 {
                    if await transport.events.contains(where: { $0.path == "/api/im/messages" }) { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring(revision: 2)), .applied)
            }
            do {
                _ = try await send.value
                XCTFail("expected the durable send to require confirmation")
            } catch let error as MessageSendOutcomeUncertainError {
                XCTAssertTrue(error.requiresReadback)
                let expected: Int? = mode == "coded503" ? 503 : (mode == "reconfigured" ? 201 : nil)
                XCTAssertEqual(error.statusCode, expected)
                if mode == "coded503" { XCTAssertEqual(error.businessCode, "auth_dependency_unavailable") }
                if mode == "committed" {
                    _ = await state.retainUnconfirmedOutgoing(error, ticket: ticket, messageID: messageID,
                        conversationID: channel, scope: scope)
                    for _ in 0..<100 {
                        if try await persistence.outgoingAuthority(ticket: ticket, clientMessageID: messageID)?.isAcknowledged == true { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
            } catch let error as URLError {
                XCTAssertEqual(mode, "unsent")
                XCTAssertEqual(error.code, .cannotFindHost)
            }
            try await persistence.updateOutboxState(ticket: ticket, clientMessageID: messageID, state: .retryWait,
                now: Date(timeIntervalSince1970: 100))
            let authority = try await persistence.outgoingAuthority(ticket: ticket, clientMessageID: messageID)
            let expectedState = mode == "committed" ? "acked" : (mode == "unsent" ? "retry_wait" : "confirmation_required")
            XCTAssertEqual(authority?.state, expectedState)
            let restarted = MessagePersistenceCoordinator(applicationSupportBase: support, cachesBase: caches)
            let next = try await restarted.activateAndLoad(context: context, sessionGeneration: ticket.sessionGeneration + 1)
            let rollback = makeRouteV5Client(transport: transport, context: context, defaults: defaults, enabledService: nil)
            let reopened = makeRouteV5AppState(client: rollback, context: context, persistence: restarted)
            reopened.localMessageTicket = next.ticket
            if mode != "unsent", mode != "committed" {
                reopened.resend(messageID: messageID, in: channel)
                try await waitForCondition { reopened.toast == "消息发送状态待确认" && reopened.outgoingConfirmationReads.isEmpty }
            }
            let claimed = try await restarted.claimOutboxForReplay(ticket: next.ticket,
                authorizationGeneration: next.ticket.sessionGeneration, trigger: .automatic, clientMessageID: nil,
                holdLegacyUnconfirmedSends: reopened.usesProtectedMessageSends)
            XCTAssertEqual(claimed.map(\.clientMessageID), mode == "unsent" ? [messageID] : [])
            let posts = await transport.events.filter { $0.path == "/api/im/messages" }
            XCTAssertEqual(posts.count, 1)
        }
    }

    func testRouteV5LostSendReceiptUsesOriginalClientMessageNumberWithoutAnotherWrite() async throws {
        let suite = "RouteV5Reconcile.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeContext()
        for committed in [true, false] {
            let transport = RouteV5TestTransport { request, timing in
                if request.url?.path == "/api/im/messages" { throw URLError(.networkConnectionLost) }
                timing?.receivedHeaders(200)
                let response = committed
                    ? #"{"ok":true,"data":{"items":[{"message_id":"remote-1","client_msg_no":"stable-client-1","from_uid":"uid-1","channel_id":"g1","channel_type":"group","channel_seq":4,"content_type":"text","payload":{"text":"test"}}]}}"#
                    : #"{"ok":true,"data":{"items":[]}}"#
                return HTTPTransportResult(data: Data(response.utf8), isHTTPResponse: true, statusCode: 200)
            }
            let client = makeRouteV5Client(transport: transport, context: context, defaults: defaults)
            _ = client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring())
            do {
                let message = try await client.sendText(context: context, conversation: makeGroupConversation(id: "g1"),
                    channelID: "g1", text: "test", quote: nil, clientMessageID: "stable-client-1")
                XCTAssertTrue(committed)
                XCTAssertEqual(message.messageID, "remote-1")
            } catch is MessageSendOutcomeUncertainError {
                XCTAssertFalse(committed)
            }
            let events = await transport.events
            XCTAssertEqual(events.map(\.path), ["/api/im/messages", "/api/im/sync"])
            let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(events.first?.body)) as? [String: Any])
            XCTAssertEqual(sent["client_msg_no"] as? String, "stable-client-1")
        }
    }
}
private actor RouteV5StoredMessageFixture {
    private(set) var syncResponse: Data?
    func commit(_ response: Data) { syncResponse = response }
}
private actor RouteV5OpeningReadGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var hasWaiter: Bool { !waiters.isEmpty }

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
private actor RouteV5ConfirmationPageFixture {
    private var error: Int?
    private var armed = false
    private var waiter: CheckedContinuation<Void, Never>?
    func setError(_ status: Int?) { error = status }
    func errorStatus(before: Int64) -> Int? { before == 56 ? error : nil }

    func armPause() { armed = true }
    func isPaused() -> Bool { waiter != nil }
    func pauseIfNeeded(before: Int64) async {
        guard before == 56, armed else { return }
        armed = false
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        armed = false
        waiter?.resume()
        waiter = nil
    }
}
private actor RouteV5RotationFixture {
    private(set) var visited: [String] = []
    private var matchChannel: String?

    func match(_ channel: String) { matchChannel = channel }

    func responseMatches(channel: String) -> Bool {
        visited.append(channel)
        return channel == matchChannel
    }
}

private actor RouteV5HistoryOriginTransport: HTTPTransport {
    let page: Data
    let appID: String
    private var result = ""
    private(set) var origins: [String] = []

    init(page: Data, appID: String) {
        self.page = page
        self.appID = appID
    }

    func setResult(_ value: String) { result = value }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        XCTAssertEqual(request.url?.path, "/api/platform/apps/current-policy")
        let policy = Data(#"{"ok":true,"data":{"app_id":"\#(appID)","platform":"ios","status":"enabled"}}"#.utf8)
        return .init(data: policy, isHTTPResponse: true, statusCode: 200, responseURL: request.url)
    }

    func data(for request: URLRequest, rejectingCrossOriginRedirectsFrom expectedOrigin: URL) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/sync" else { return try await data(for: request) }
        XCTAssertEqual(request.url?.host, expectedOrigin.host)
        origins.append(expectedOrigin.absoluteString)
        let other = "https://unapproved.example.net/api/im/sync"
        switch result {
        case "redirect":
            // The redirect-aware transport returns the 307 without following the Location.
            return .init(data: page, isHTTPResponse: true, statusCode: 307,
                         headers: ["Location": other], responseURL: request.url)
        case "cross-origin":
            return .init(data: page, isHTTPResponse: true, statusCode: 200, responseURL: URL(string: other))
        case "wrong-scheme":
            return .init(data: page, isHTTPResponse: true, statusCode: 200,
                         responseURL: URL(string: "http://im-primary.example.com:443/api/im/sync"))
        case "wrong-port":
            return .init(data: page, isHTTPResponse: true, statusCode: 200,
                         responseURL: URL(string: "https://im-primary.example.com:444/api/im/sync"))
        case "missing":
            return .init(data: page, isHTTPResponse: true, statusCode: 200)
        default:
            return .init(data: page, isHTTPResponse: true, statusCode: 200,
                         responseURL: URL(string: "https://IM-PRIMARY.example.com:443/api/im/sync"))
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

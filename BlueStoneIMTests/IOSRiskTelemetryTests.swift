import Foundation
import XCTest
@testable import BlueStoneIM

@MainActor
final class IOSRiskTelemetryTests: XCTestCase {
    func testSceneCaptureResolverUsesOnlyBoundSceneAndVersionAppropriateSignal() {
        let firstScene = FakeIOSSceneCaptureSource(
            sceneIdentifier: "scene-a",
            sceneTraitCaptureState: .inactive,
            boundScreenIsCaptured: true
        )
        let secondScene = FakeIOSSceneCaptureSource(
            sceneIdentifier: "scene-b",
            sceneTraitCaptureState: .active,
            boundScreenIsCaptured: false
        )

        XCTAssertFalse(IOSSceneCaptureResolver.isCaptured(boundSource: firstScene, supportsSceneCaptureTrait: true))
        XCTAssertTrue(IOSSceneCaptureResolver.isCaptured(boundSource: secondScene, supportsSceneCaptureTrait: true))
        XCTAssertTrue(IOSSceneCaptureResolver.isCaptured(boundSource: firstScene, supportsSceneCaptureTrait: false))
        XCTAssertFalse(IOSSceneCaptureResolver.isCaptured(boundSource: secondScene, supportsSceneCaptureTrait: false))
    }

    func testSessionGateRequiresOrdinaryBoundJWTAndRejectsExcludedOrUnknownActors() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let ordinary = makeContext(token: makeToken(expiresAt: now.addingTimeInterval(600)))

        XCTAssertTrue(IOSRiskTelemetrySessionGate.allows(context: ordinary, isAuthenticated: true, memberRole: "member", now: now))
        XCTAssertTrue(IOSRiskTelemetrySessionGate.allows(context: ordinary, isAuthenticated: true, memberRole: "成员", now: now))
        XCTAssertFalse(IOSRiskTelemetrySessionGate.allows(context: ordinary, isAuthenticated: false, memberRole: "member", now: now))
        XCTAssertFalse(IOSRiskTelemetrySessionGate.allows(context: ordinary, isAuthenticated: true, memberRole: "internal", now: now))
        XCTAssertFalse(IOSRiskTelemetrySessionGate.allows(context: ordinary, isAuthenticated: true, memberRole: "admin", now: now))
        XCTAssertFalse(IOSRiskTelemetrySessionGate.allows(context: ordinary, isAuthenticated: true, memberRole: "", now: now))

        let excluded = makeContext(token: makeToken(scopes: ["im:connect", "im:risk_collection_excluded"], expiresAt: now.addingTimeInterval(600)))
        XCTAssertFalse(IOSRiskTelemetrySessionGate.allows(context: excluded, isAuthenticated: true, memberRole: "member", now: now))

        let mismatched = makeContext(token: makeToken(deviceID: "other-device", expiresAt: now.addingTimeInterval(600)))
        XCTAssertFalse(IOSRiskTelemetrySessionGate.allows(context: mismatched, isAuthenticated: true, memberRole: "member", now: now))

        let expired = makeContext(token: makeToken(expiresAt: now.addingTimeInterval(-1)))
        XCTAssertFalse(IOSRiskTelemetrySessionGate.allows(context: expired, isAuthenticated: true, memberRole: "member", now: now))

        let malformed = makeContext(token: "not-a-jwt")
        XCTAssertFalse(IOSRiskTelemetrySessionGate.allows(context: malformed, isAuthenticated: true, memberRole: "member", now: now))
    }

    func testEventRequestBodyCannotCarryIdentityTrustSupportOrContent() throws {
        let event = IOSRiskActivityEvent(
            eventType: "clipboard_copy",
            platformVersion: "18.5",
            appVersion: "1.2.3",
            occurredAt: Date(timeIntervalSince1970: 2_000_000_000),
            resource: IOSRiskActivityResource(type: "message", id: "message-1"),
            attributes: [
                "character_count_bucket": .string("21-100"),
                "channel_type": .string("group"),
                "channel_id": .string("group-1")
            ],
            idempotencyKey: "ios:clipboard_copy:event-1"
        )

        let body = event.requestBody
        XCTAssertEqual(Set(body.keys), Set([
            "schema_version", "event_type", "source", "platform", "platform_version",
            "app_version", "occurred_at", "resource", "attributes", "idempotency_key"
        ]))
        XCTAssertNil(body["tenant_id"])
        XCTAssertNil(body["im_uid"])
        XCTAssertNil(body["device_id"])
        XCTAssertNil(body["app_id"])
        XCTAssertNil(body["support_status"])
        XCTAssertNil(body["trust_level"])
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["message_body", "clipboard_content", "search_term", "file_name", "authorization", "token="] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testQueueIsScopedPersistentBoundedAndDropsOutOfContractClockValues() throws {
        let suiteName = "im3.ios.risk-telemetry-queue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = IOSRiskTelemetryQueueStore(defaults: defaults, keyPrefix: "risk-test", maxCount: 3)
        let context = makeContext(token: makeToken(expiresAt: now.addingTimeInterval(600)))
        let scope = try XCTUnwrap(store.scopeKey(for: context))

        for index in 0..<4 {
            store.append(makeEvent(id: "event-\(index)", occurredAt: now.addingTimeInterval(TimeInterval(-index))), scope: scope, now: now)
        }
        XCTAssertEqual(store.load(scope: scope, now: now).map(\.idempotencyKey), ["event-1", "event-2", "event-3"])

        store.append(
            makeEvent(id: "too-old", occurredAt: now.addingTimeInterval(-(IOSRiskTelemetryQueueStore.acceptedClientAge + 1))),
            scope: scope,
            now: now
        )
        store.append(
            makeEvent(id: "too-future", occurredAt: now.addingTimeInterval(IOSRiskTelemetryQueueStore.acceptedFutureSkew + 1)),
            scope: scope,
            now: now
        )
        let reloaded = IOSRiskTelemetryQueueStore(defaults: defaults, keyPrefix: "risk-test", maxCount: 3)
        let retained = reloaded.load(scope: scope, now: now)
        XCTAssertFalse(retained.contains { $0.idempotencyKey == "too-old" || $0.idempotencyKey == "too-future" })
        XCTAssertLessThanOrEqual(retained.count, 3)
    }

    func testControllerMapsCapabilitiesCaptureForegroundAndExplicitCopyWithoutContent() async throws {
        let suiteName = "im3.ios.risk-telemetry-controller.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var currentTime = Date(timeIntervalSince1970: 2_000_000_000)
        var submitted: [[IOSRiskActivityEvent]] = []
        let controller = IOSRiskTelemetryController(
            queueStore: IOSRiskTelemetryQueueStore(defaults: defaults, keyPrefix: "risk-controller"),
            appVersion: "1.2.3",
            platformVersion: "18.5",
            now: { currentTime },
            submit: { _, events in
                submitted.append(events)
                return Self.accepted(events)
            }
        )
        let context = makeContext(token: makeToken(expiresAt: currentTime.addingTimeInterval(600)))

        controller.updateSession(
            context: context,
            isAuthenticated: true,
            memberRole: "member",
            sceneIsActive: true,
            captureIsActive: false
        )
        controller.recordScreenshot()
        controller.recordCaptureState(true)
        controller.recordCaptureState(true)
        controller.recordCaptureState(false)
        controller.recordClipboardCopy(
            characterCount: 42,
            resourceType: "message",
            resourceID: "message-1",
            channelType: "group",
            channelID: "group-1"
        )
        currentTime = currentTime.addingTimeInterval(10)
        controller.sceneDidEnterBackground()
        controller.recordScreenshot()
        controller.recordCaptureState(true)
        await controller.flushNowForTesting()

        let events = submitted.flatMap { $0 }
        XCTAssertEqual(events.filter { $0.eventType == "capture_capability" }.count, 2)
        XCTAssertEqual(events.filter { $0.eventType == "screenshot_detected" }.count, 1)
        XCTAssertEqual(events.filter { $0.eventType == "capture_state_started" }.count, 1)
        XCTAssertEqual(events.filter { $0.eventType == "capture_state_ended" }.count, 1)
        XCTAssertEqual(events.filter { $0.eventType == "clipboard_copy" }.count, 1)
        XCTAssertEqual(events.filter { $0.eventType == "app_foreground_interval" }.count, 1)
        XCTAssertTrue(events.allSatisfy { $0.source == "client" && $0.platform == "ios" })
        let copy = try XCTUnwrap(events.first { $0.eventType == "clipboard_copy" })
        XCTAssertEqual(copy.attributes["character_count_bucket"], .string("21-100"))
        XCTAssertEqual(copy.resource, IOSRiskActivityResource(type: "message", id: "message-1"))
        XCTAssertTrue(controller.pendingEventsForTesting().isEmpty)
    }

    func testControllerRetryPreservesIdempotencyAndTerminalStatusesDrainQueue() async throws {
        enum RetryError: Error { case offline }
        let suiteName = "im3.ios.risk-telemetry-retry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var attempts = 0
        var batches: [[IOSRiskActivityEvent]] = []
        let controller = IOSRiskTelemetryController(
            queueStore: IOSRiskTelemetryQueueStore(defaults: defaults, keyPrefix: "risk-retry"),
            now: { now },
            submit: { _, events in
                attempts += 1
                batches.append(events)
                if attempts == 1 { throw RetryError.offline }
                return IOSRiskActivityBatchResult(items: events.indices.map { index in
                    IOSRiskActivityItemResult(index: index, status: index.isMultiple(of: 2) ? "duplicate" : "not_collected")
                })
            }
        )
        let context = makeContext(token: makeToken(expiresAt: now.addingTimeInterval(600)))
        controller.updateSession(context: context, isAuthenticated: true, memberRole: "member", sceneIsActive: true, captureIsActive: false)
        controller.recordScreenshot()

        await controller.flushNowForTesting()
        let retainedKeys = controller.pendingEventsForTesting().map(\.idempotencyKey)
        XCTAssertFalse(retainedKeys.isEmpty)
        await controller.flushNowForTesting()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(batches[0].map(\.idempotencyKey), batches[1].map(\.idempotencyKey))
        XCTAssertEqual(retainedKeys, batches[1].map(\.idempotencyKey))
        XCTAssertTrue(controller.pendingEventsForTesting().isEmpty)
    }

    func testRetryAfterSameScopeTokenRefreshUsesLatestBearerAndStableIdempotency() async throws {
        enum RetryError: Error { case offline }
        let suiteName = "im3.ios.risk-telemetry-token-refresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let firstToken = makeToken(expiresAt: now.addingTimeInterval(600))
        let refreshedToken = makeToken(expiresAt: now.addingTimeInterval(1_200))
        var submittedTokens: [String] = []
        var submittedKeys: [[String]] = []
        let controller = IOSRiskTelemetryController(
            queueStore: IOSRiskTelemetryQueueStore(defaults: defaults, keyPrefix: "risk-token-refresh"),
            now: { now },
            submit: { context, events in
                submittedTokens.append(context.imToken ?? "")
                submittedKeys.append(events.map(\.idempotencyKey))
                if submittedTokens.count == 1 { throw RetryError.offline }
                return Self.accepted(events)
            }
        )

        controller.updateSession(
            context: makeContext(token: firstToken),
            isAuthenticated: true,
            memberRole: "member",
            sceneIsActive: true,
            captureIsActive: false
        )
        controller.recordScreenshot()
        await controller.flushNowForTesting()
        controller.updateSession(
            context: makeContext(token: refreshedToken),
            isAuthenticated: true,
            memberRole: "member",
            sceneIsActive: true,
            captureIsActive: false
        )
        await controller.flushNowForTesting()

        XCTAssertEqual(submittedTokens, [firstToken, refreshedToken])
        XCTAssertEqual(submittedKeys.count, 2)
        XCTAssertEqual(submittedKeys[0], submittedKeys[1])
        XCTAssertTrue(controller.pendingEventsForTesting().isEmpty)
    }

    func testInactiveEndsCaptureBeforeForegroundIntervalAndClearsState() throws {
        let harness = try makeLifecycleHarness(prefix: "inactive")
        harness.controller.updateSession(
            context: harness.context,
            isAuthenticated: true,
            memberRole: "member",
            sceneIsActive: true,
            captureIsActive: true
        )
        harness.advance(10)
        harness.controller.sceneDidBecomeInactive()
        harness.controller.sceneDidBecomeInactive()

        assertLifecycleClosedOnce(harness.events(), file: #filePath, line: #line)
    }

    func testBackgroundEndsCaptureBeforeForegroundIntervalAndClearsState() throws {
        let harness = try makeLifecycleHarness(prefix: "background")
        harness.controller.updateSession(
            context: harness.context,
            isAuthenticated: true,
            memberRole: "member",
            sceneIsActive: true,
            captureIsActive: true
        )
        harness.advance(10)
        harness.controller.sceneDidEnterBackground()

        assertLifecycleClosedOnce(harness.events(), file: #filePath, line: #line)
    }

    func testIdentityBecomingIneligibleEndsCaptureBeforeDeactivation() throws {
        let harness = try makeLifecycleHarness(prefix: "identity")
        harness.controller.updateSession(
            context: harness.context,
            isAuthenticated: true,
            memberRole: "member",
            sceneIsActive: true,
            captureIsActive: true
        )
        harness.advance(10)
        harness.controller.updateSession(
            context: harness.context,
            isAuthenticated: true,
            memberRole: "internal",
            sceneIsActive: true,
            captureIsActive: true
        )

        assertLifecycleClosedOnce(harness.events(), file: #filePath, line: #line)
    }

    func testForegroundLongIntervalIsSplitToServerDurationLimit() async throws {
        let suiteName = "im3.ios.risk-telemetry-duration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var currentTime = Date(timeIntervalSince1970: 2_000_000_000)
        var submitted: [IOSRiskActivityEvent] = []
        let controller = IOSRiskTelemetryController(
            queueStore: IOSRiskTelemetryQueueStore(defaults: defaults, keyPrefix: "risk-duration"),
            now: { currentTime },
            submit: { _, events in
                submitted.append(contentsOf: events)
                return Self.accepted(events)
            }
        )
        let context = makeContext(token: makeToken(expiresAt: currentTime.addingTimeInterval(10_000)))
        controller.updateSession(context: context, isAuthenticated: true, memberRole: "member", sceneIsActive: true, captureIsActive: false)
        await controller.flushNowForTesting()
        submitted.removeAll()

        currentTime = currentTime.addingTimeInterval(7_201)
        controller.sceneDidEnterBackground()
        await controller.flushNowForTesting()

        let foreground = submitted.filter { $0.eventType == "app_foreground_interval" }
        XCTAssertEqual(foreground.count, 3)
        XCTAssertEqual(foreground.compactMap { $0.attributes["duration_ms"] }, [.int(3_600_000), .int(3_600_000), .int(1_000)])
    }

    func testIMAPIClientUsesBatchEndpointIMBearerAndFrozenBody() async throws {
        let transport = RiskTelemetryHTTPTransport(
            result: HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"index":0,"status":"accepted","event_type":"screenshot_detected"}],"accepted_count":1,"duplicate_count":0,"rejected_count":0,"not_collected_count":0}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 202
            )
        )
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let event = makeEvent(id: "ios:screenshot_detected:test", occurredAt: Date(timeIntervalSince1970: 2_000_000_000))
        let result = try await client.postRiskActivityEvents(context: makeContext(token: "im-token"), events: [event])

        XCTAssertEqual(result.acceptedCount, 1)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/risk/events/batch")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        let sent = try XCTUnwrap(events.first)
        XCTAssertEqual(sent["platform"] as? String, "ios")
        XCTAssertNil(sent["tenant_id"])
        XCTAssertNil(sent["im_uid"])
        XCTAssertNil(sent["support_status"])
        XCTAssertNil(sent["trust_level"])
    }

    private static func accepted(_ events: [IOSRiskActivityEvent]) -> IOSRiskActivityBatchResult {
        IOSRiskActivityBatchResult(items: events.indices.map { index in
            IOSRiskActivityItemResult(index: index, status: "accepted", eventType: events[index].eventType)
        })
    }

    private func makeLifecycleHarness(prefix: String) throws -> RiskTelemetryLifecycleHarness {
        let suiteName = "im3.ios.risk-telemetry-\(prefix).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let initialTime = Date(timeIntervalSince1970: 2_000_000_000)
        let context = makeContext(token: makeToken(expiresAt: initialTime.addingTimeInterval(600)))
        return RiskTelemetryLifecycleHarness(
            defaults: defaults,
            suiteName: suiteName,
            prefix: "risk-\(prefix)",
            initialTime: initialTime,
            context: context
        )
    }

    private func assertLifecycleClosedOnce(
        _ events: [IOSRiskActivityEvent],
        file: StaticString,
        line: UInt
    ) {
        let types = events.map(\.eventType)
        XCTAssertEqual(types.filter { $0 == "capture_state_started" }.count, 1, file: file, line: line)
        XCTAssertEqual(types.filter { $0 == "capture_state_ended" }.count, 1, file: file, line: line)
        XCTAssertEqual(types.filter { $0 == "app_foreground_interval" }.count, 1, file: file, line: line)
        let endedIndex = types.firstIndex(of: "capture_state_ended")
        let foregroundIndex = types.firstIndex(of: "app_foreground_interval")
        XCTAssertNotNil(endedIndex, file: file, line: line)
        XCTAssertNotNil(foregroundIndex, file: file, line: line)
        if let endedIndex, let foregroundIndex {
            XCTAssertLessThan(endedIndex, foregroundIndex, file: file, line: line)
        }
    }

    private func makeEvent(id: String, occurredAt: Date) -> IOSRiskActivityEvent {
        IOSRiskActivityEvent(
            eventType: "screenshot_detected",
            platformVersion: "18.5",
            appVersion: "1.2.3",
            occurredAt: occurredAt,
            idempotencyKey: id
        )
    }

    private func makeContext(token: String) -> IMAPIContext {
        IMAPIContext(
            platformToken: nil,
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "im-user-1",
            imToken: token,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "ios-device-1"
        )
    }

    private func makeToken(
        tokenType: String = "im",
        scopes: [String] = ["im:connect", "im:send", "im:sync"],
        tenantID: String = "tenant-1",
        subject: String = "im-user-1",
        appID: String = IMAPIContext.canonicalIOSAppID,
        deviceID: String = "ios-device-1",
        expiresAt: Date
    ) -> String {
        let claims: [String: Any] = [
            "sub": subject,
            "tenant_id": tenantID,
            "app_id": appID,
            "device_id": deviceID,
            "token_type": tokenType,
            "scopes": scopes,
            "iat": Int64(expiresAt.timeIntervalSince1970) - 600,
            "exp": Int64(expiresAt.timeIntervalSince1970)
        ]
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }
}

@MainActor
private final class FakeIOSSceneCaptureSource: IOSSceneCaptureSource {
    let sceneIdentifier: String
    let sceneTraitCaptureState: IOSSceneCaptureTraitState
    let boundScreenIsCaptured: Bool

    init(sceneIdentifier: String, sceneTraitCaptureState: IOSSceneCaptureTraitState, boundScreenIsCaptured: Bool) {
        self.sceneIdentifier = sceneIdentifier
        self.sceneTraitCaptureState = sceneTraitCaptureState
        self.boundScreenIsCaptured = boundScreenIsCaptured
    }
}

@MainActor
private final class RiskTelemetryLifecycleHarness {
    let controller: IOSRiskTelemetryController
    let context: IMAPIContext

    private let store: IOSRiskTelemetryQueueStore
    private let scope: String
    private let clock: RiskTelemetryTestClock

    init(defaults: UserDefaults, suiteName: String, prefix: String, initialTime: Date, context: IMAPIContext) {
        self.context = context
        clock = RiskTelemetryTestClock(now: initialTime)
        store = IOSRiskTelemetryQueueStore(defaults: defaults, keyPrefix: prefix)
        scope = store.scopeKey(for: context) ?? ""
        let clock = self.clock
        controller = IOSRiskTelemetryController(
            queueStore: store,
            now: { clock.now },
            submit: { _, events in IOSRiskActivityBatchResult(items: events.indices.map {
                IOSRiskActivityItemResult(index: $0, status: "accepted")
            }) }
        )
    }

    func advance(_ seconds: TimeInterval) {
        clock.now = clock.now.addingTimeInterval(seconds)
    }

    func events() -> [IOSRiskActivityEvent] {
        store.load(scope: scope, now: clock.now)
    }
}

@MainActor
private final class RiskTelemetryTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class RiskTelemetryHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let result: HTTPTransportResult
    private var capturedRequests: [URLRequest] = []

    init(result: HTTPTransportResult) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
        }
        return result
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        result
    }

    func requests() -> [URLRequest] {
        lock.withLock { capturedRequests }
    }
}

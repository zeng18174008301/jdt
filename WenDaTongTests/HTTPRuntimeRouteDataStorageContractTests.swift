// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_BEGIN
import Foundation
import XCTest
import IM4Data
import IM4Core // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
@testable import WenDaTong

extension HTTPTransportTests {
    func testRuntimeRouteDataStoragePreservesSchemaIndependentDecodeAndRealAppRepair() throws {
        captureA43RuntimeLoadedImages()
        let suite = "route-data-schema-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = runtimeRouteStorageSnapshot()
        XCTAssertEqual(snapshot.recomputedConfigHash, "8d8c2d748fdd9bdf1cdeb03fe45f4228cee903bbb7f213f0ffb13d802aefb4bb")
        XCTAssertNotNil(snapshot.validated(appID: snapshot.appID, tenantID: snapshot.tenantID))
        let recovery = IMRuntimeRouteRecoveryState(consecutiveQualifiedColdLaunchFailures: 2, recovery: true,
            consecutiveStablePreferredProbes: 1, lastStableProbeAtMS: 30_001)
        let record = IMRuntimeRouteAtomicRecord(current: snapshot, previous: nil, recoveryByService: ["tenant_api": recovery], publicationWatermark: nil)
        let storage = IM4Data.RuntimeRouteRecordStorage(defaults: defaults)
        XCTAssertTrue(storage.persist(record, appID: snapshot.appID, tenantID: snapshot.tenantID))
        let key = "wxt.runtime.routes.v2.60b07a48db5cbd038e1bdc9a2afc10a5"
        let actualBytes = try XCTUnwrap(defaults.data(forKey: key))
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: actualBytes) as? NSDictionary)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"current":{"app_id":"data-route-app","config_hash":"8d8c2d748fdd9bdf1cdeb03fe45f4228cee903bbb7f213f0ffb13d802aefb4bb","contract_version":2,"environment":"production","hash_scope":"tenant_entry","keyset_revision":7,"lifetime_mode":"until_revoked","policy":{"automatic_expiry":false,"business_signing_required":false,"contract_version":2,"preferred_failure_budget_ms":5000,"preferred_probe_interval_ms":30000,"preferred_probe_stable_ms":30000,"preferred_probe_successes":2,"recovery_cold_start_failures":3},"preferred_endpoints":{},"profile_fingerprint":"8d8c2d748fdd9bdf1cdeb03fe45f4228cee903bbb7f213f0ffb13d802aefb4bb","publication_id":"publication-42","publication_revision":42,"publication_status":"active","revision":42,"services":{"im_api":{"backup_source":"tenant_deployment_backup","backups":["https://im-backup.example.test"],"preferred":["https://im-primary.example.test"],"preferred_source":"tenant_deployment_authority","status":"ready"},"im_realtime":{"backup_source":"tenant_deployment_backup","backups":["wss://ws-backup.example.test/im/ws"],"preferred":["wss://ws-primary.example.test/im/ws"],"preferred_source":"tenant_deployment_authority","status":"ready"},"platform_api":{"backup_source":"common_platform_backup","backups":["https://platform-backup.example.test"],"preferred":["https://platform-primary.example.test"],"preferred_source":"app_preferred","status":"ready"},"tenant_api":{"backup_source":"tenant_deployment_backup","backups":["https://tenant-backup.example.test"],"preferred":["https://tenant-primary.example.test"],"preferred_source":"tenant_deployment_authority","status":"ready"}},"source":"schema-source","status":"ready","tenant_id":"data-route-tenant"},"publicationWatermark":{"environment":"production","keysetRevision":7,"profileFingerprint":"8d8c2d748fdd9bdf1cdeb03fe45f4228cee903bbb7f213f0ffb13d802aefb4bb","publicationID":"publication-42","revision":42,"status":"active"},"recoveryByService":{"tenant_api":{"consecutiveQualifiedColdLaunchFailures":2,"consecutiveStablePreferredProbes":1,"lastStableProbeAtMS":30001,"recovery":true}}}"#.utf8)) as? NSDictionary)
        XCTAssertEqual(actual, expected)
        let app = IMRuntimeRouteStore(defaults: defaults)
        XCTAssertEqual(app.restore(appID: snapshot.appID, tenantID: snapshot.tenantID), snapshot)
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: actualBytes) as? [String: Any])
        let previous = try XCTUnwrap(malformed["current"] as? [String: Any])
        var current = previous; current["revision"] = "structurally-corrupt"
        malformed["current"] = current; malformed["previous"] = previous
        malformed["recoveryByService"] = "malformed-recovery"
        malformed["publicationWatermark"] = ["revision": "malformed-watermark"]
        defaults.set(try JSONSerialization.data(withJSONObject: malformed), forKey: key)
        let decoded = storage.record(appID: snapshot.appID, tenantID: snapshot.tenantID)
        XCTAssertNil(decoded.current); XCTAssertEqual(decoded.previous, snapshot)
        XCTAssertTrue(decoded.recoveryByService.isEmpty); XCTAssertNil(decoded.publicationWatermark)
        XCTAssertEqual(app.restore(appID: snapshot.appID, tenantID: snapshot.tenantID), snapshot)
        let repaired = storage.record(appID: snapshot.appID, tenantID: snapshot.tenantID)
        XCTAssertEqual(repaired.current, snapshot); XCTAssertNil(repaired.previous)
        XCTAssertTrue(repaired.recoveryByService.isEmpty); XCTAssertNil(repaired.publicationWatermark)
    }

    func testRuntimeRouteDataStorageSeesExternalBytesAndKeepsUTF8Namespace() throws {
        captureA43RuntimeLoadedImages()
        let suite = "route-data-key-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = IM4Data.RuntimeRouteRecordStorage(defaults: defaults)
        let other = IM4Data.RuntimeRouteRecordStorage(defaults: defaults)
        let app = IMRuntimeRouteStore(defaults: defaults)
        let composed = "rout\u{E9}", decomposed = "route\u{301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        let one = IMRuntimeRouteAtomicRecord(current: nil, previous: nil,
            recoveryByService: ["tenant_api": .init(consecutiveQualifiedColdLaunchFailures: 1)])
        let two = IMRuntimeRouteAtomicRecord(current: nil, previous: nil,
            recoveryByService: ["tenant_api": .init(consecutiveQualifiedColdLaunchFailures: 2)])
        XCTAssertTrue(first.persist(one, appID: composed, tenantID: "tenant-a"))
        XCTAssertTrue(first.persist(two, appID: decomposed, tenantID: "tenant-a"))
        let composedKey = "wxt.runtime.routes.v2.35ac07f44a781b7c0096f40660b72849", decomposedKey = "wxt.runtime.routes.v2.c21c99adab7f98b620225159b832a110"
        XCTAssertNotNil(defaults.data(forKey: composedKey)); XCTAssertNotNil(defaults.data(forKey: decomposedKey))
        XCTAssertEqual(first.record(appID: composed, tenantID: "tenant-a"), one)
        XCTAssertEqual(first.record(appID: decomposed, tenantID: "tenant-a"), two)
        XCTAssertEqual(app.record(appID: composed, tenantID: "tenant-a"), one)
        XCTAssertTrue(other.persist(two, appID: composed, tenantID: "tenant-a"))
        XCTAssertEqual(app.record(appID: composed, tenantID: "tenant-a"), two)
        let exactBytes = Data("  {\"recoveryByService\":{\"tenant_api\":{\"consecutiveQualifiedColdLaunchFailures\":5,\"recovery\":false,\"consecutiveStablePreferredProbes\":0}}}\n".utf8)
        first.restoreBytes(exactBytes, appID: composed, tenantID: "tenant-a")
        XCTAssertEqual(defaults.data(forKey: composedKey), exactBytes)
        XCTAssertEqual(other.originalBytes(appID: composed, tenantID: "tenant-a"), exactBytes)
        XCTAssertEqual(app.record(appID: composed, tenantID: "tenant-a").recoveryByService["tenant_api"]?.consecutiveQualifiedColdLaunchFailures, 5)
        defaults.set(Data("[]".utf8), forKey: composedKey)
        XCTAssertTrue(app.record(appID: composed, tenantID: "tenant-a").recoveryByService.isEmpty)
        XCTAssertEqual(first.record(appID: decomposed, tenantID: "tenant-a"), two)
        first.restoreBytes(nil, appID: composed, tenantID: "tenant-a")
        XCTAssertNil(defaults.data(forKey: composedKey))
        XCTAssertEqual(first.record(appID: composed, tenantID: "tenant-a"), IMRuntimeRouteAtomicRecord(current: nil, previous: nil, recoveryByService: [:]))
    }

    func testRuntimeRouteDataIOFailureWithoutPriorBytesRemovesCandidateAndCanRetry() throws {
        captureA43RuntimeLoadedImages()
        let suite = "route-data-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DataRouteFailingSynchronizationDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = IMRuntimeRouteStore(defaults: defaults)
        let snapshot = runtimeRouteStorageSnapshot()
        XCTAssertNotNil(snapshot.validated(appID: snapshot.appID, tenantID: snapshot.tenantID))
        let before = defaults.synchronizationCount
        defaults.failNextSynchronization()
        XCTAssertEqual(app.applyAuthenticationCandidate(snapshot, appID: snapshot.appID, tenantID: snapshot.tenantID), .persistence)
        XCTAssertNil(defaults.data(forKey: "wxt.runtime.routes.v2.60b07a48db5cbd038e1bdc9a2afc10a5"))
        XCTAssertNil(app.record(appID: snapshot.appID, tenantID: snapshot.tenantID).current)
        XCTAssertEqual(defaults.synchronizationCount - before, 2)
        XCTAssertEqual(app.applyAuthenticationCandidate(snapshot, appID: snapshot.appID, tenantID: snapshot.tenantID), .applied)
        XCTAssertEqual(app.restore(appID: snapshot.appID, tenantID: snapshot.tenantID), snapshot)
    }

    private func runtimeRouteStorageSnapshot() -> IMRuntimeRouteSnapshot {
        let services: [String: IMRuntimeRouteEndpointSet] = [
            "platform_api": .init(preferred: ["https://platform-primary.example.test"], backups: ["https://platform-backup.example.test"],
                preferredSource: "app_preferred", backupSource: "common_platform_backup"),
            "tenant_api": .init(preferred: ["https://tenant-primary.example.test"], backups: ["https://tenant-backup.example.test"],
                preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"),
            "im_api": .init(preferred: ["https://im-primary.example.test"], backups: ["https://im-backup.example.test"],
                preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"),
            "im_realtime": .init(preferred: ["wss://ws-primary.example.test/im/ws"], backups: ["wss://ws-backup.example.test/im/ws"],
                preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup")
        ]
        return IMRuntimeRouteSnapshot(contractVersion: 2, appID: "data-route-app", tenantID: "data-route-tenant", revision: 42,
            source: "schema-source", status: "ready", configHash: "8d8c2d748fdd9bdf1cdeb03fe45f4228cee903bbb7f213f0ffb13d802aefb4bb", services: services, policy: .init(),
            environment: "production", publicationID: "publication-42", publicationRevision: 42,
            profileFingerprint: "8d8c2d748fdd9bdf1cdeb03fe45f4228cee903bbb7f213f0ffb13d802aefb4bb", lifetimeMode: .untilRevoked, publicationStatus: "active", keysetRevision: 7)
    }
}

private final class DataRouteFailingSynchronizationDefaults: UserDefaults, @unchecked Sendable {
    private let synchronizationLock = NSLock()
    private var shouldFail = false
    private var count = 0
    var synchronizationCount: Int { synchronizationLock.withLock { count } }
    func failNextSynchronization() { synchronizationLock.withLock { shouldFail = true } }
    override func synchronize() -> Bool {
        let fail = synchronizationLock.withLock { () -> Bool in
            count += 1
            let fail = shouldFail; shouldFail = false; return fail
        }
        return fail ? false : super.synchronize()
    }
}
// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_END

// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
private enum GroupDirectoryRetirement: String, CaseIterable {
    case workspace, session, refresh, cancellation
}

extension HTTPTransportTests {
    func testGroupDirectoryStaleFirstPageCannotPaginateFailOverOrRecordColdLaunch() async throws {
        for retirement in GroupDirectoryRetirement.allCases {
            for status in [200, 503] {
                try await assertRetiredGroupDirectoryFirstPage(status: status, retirement: retirement)
            }
        }
        try await assertRetiredGroupDirectoryFirstPage(status: 403, retirement: .session)
    }

    private func assertRetiredGroupDirectoryFirstPage(status: Int, retirement: GroupDirectoryRetirement) async throws {
        let oldBody: String
        switch status {
        case 200:
            oldBody = #"{"ok":true,"data":{"items":[{"group_id":"old","name":"Old"}],"has_more":true,"next_offset":500}}"#
        case 403:
            oldBody = #"{"ok":false,"error":{"code":"device_revoked","message":"Old session revoked"}}"#
        default:
            oldBody = #"{"ok":false}"#
        }
        let freshBody = #"{"ok":true,"data":{"items":[{"group_id":"fresh","name":"Fresh","my_role":"member"}],"has_more":false}}"#
        let transport = FakeHTTPTransport(results: [
            .init(data: Data(oldBody.utf8), isHTTPResponse: true, statusCode: status),
            .init(data: Data(freshBody.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let store = isolatedRuntimeRouteStore()
        let lifecycle = IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
        let clock = RuntimeRouteTestClock(nowMS: 100_000)
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://seed-tenant.example.test")!,
            imBase: URL(string: "https://seed-im.example.test")!,
            httpTransport: transport, runtimeRouteStore: store, runtimeColdLaunchLifecycle: lifecycle,
            runtimeMonotonicNowMS: { clock.now() }, runtimeSleep: { clock.advance(by: $0) }
        )
        let context = makeContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-directory-" + UUID().uuidString)
        let state = AppState(
            api: client, realtimeClient: PostLoginSilentRealtimeTransport(),
            messageStore: AvatarProjectionEmptyMessageStore(),
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")),
            protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context
        )
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
        ).data)
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let routes = runtimeRouteSnapshotForHTTPWiring()
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
        lifecycle.beginProcessLaunch()
        lifecycle.sceneDidBecomeActive()
        lifecycle.setNetworkReachable(true)
        XCTAssertTrue(lifecycle.isTracking)
        XCTAssertTrue(store.updateRecovery(.init(consecutiveQualifiedColdLaunchFailures: 1),
            service: .tenantAPI, snapshot: routes))
        let firstDecode = expectation(description: "Page zero decoded for \(retirement.rawValue) \(status)")
        let release = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(forName: .imCurrentDeviceRevoked, object: nil, queue: nil) { _ in
            XCTFail("A retired group directory request emitted a device-revocation notification")
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let old = Task { @MainActor in
            await SDKHTTPTrace.$current.withValue((
                sourceCorrelation: 3, delivery: { _, _, _ in }, decode: { _, _, onMain in
                    XCTAssertFalse(onMain)
                    firstDecode.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }, linkToPhysicalSource: { _ in }
            )) { await state.refreshGroupDirectory(silent: false) }
        }
        defer { release.signal() }
        let reached = await XCTWaiter.fulfillment(of: [firstDecode], timeout: 2)
        guard reached == .completed else {
            old.cancel()
            release.signal()
            _ = await old.value
            return XCTFail("Did not suspend the first group directory decode")
        }

        switch retirement {
        case .workspace:
            var replacement = state.apiContext
            replacement.tenantID = "tenant-new"
            replacement.sessionEpoch = UUID().uuidString
            state.apiContext = replacement
            let newRoutes = runtimeRouteSnapshotForHTTPWiring(
                tenantPreferred: ["https://tenant-new.example.com"], tenantID: "tenant-new")
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(newRoutes), .applied)
        case .session:
            var replacement = state.apiContext
            replacement.sessionEpoch = UUID().uuidString
            state.apiContext = replacement
            XCTAssertEqual(state.apiContext.tenantID, context.tenantID)
            XCTAssertFalse(state.apiContext.isSameAuthAuthority(as: context.authSessionFence))
        case .refresh:
            let freshSucceeded = await state.refreshGroupDirectory()
            XCTAssertTrue(freshSucceeded)
            XCTAssertEqual(state.groups.map(\.id), ["fresh"])
        case .cancellation:
            old.cancel()
        }

        let before = store.record(appID: routes.appID, tenantID: routes.tenantID)
        let recorded = client.coldLaunchOutcomeRecordedServices
        let probes = client.preferredHTTPProbeInFlightServices
        let currentAuthority = state.apiContext.authSessionFence
        release.signal()
        let oldSucceeded = await old.value
        XCTAssertFalse(oldSucceeded)
        let requestCount = retirement == .refresh ? 2 : 1
        XCTAssertEqual(transport.requests().map { $0.url?.host },
                       Array(repeating: "tenant-primary.example.com", count: requestCount))
        XCTAssertEqual(transport.requests().map { $0.url?.query },
                       Array(repeating: "scope=all&limit=500&offset=0", count: requestCount))
        XCTAssertTrue(probes.isEmpty)
        XCTAssertEqual(client.preferredHTTPProbeInFlightServices, probes)
        XCTAssertEqual(client.coldLaunchOutcomeRecordedServices, recorded)
        XCTAssertEqual(store.record(appID: routes.appID, tenantID: routes.tenantID), before)
        XCTAssertEqual(state.groups.map(\.id), retirement == .refresh ? ["fresh"] : [])
        XCTAssertEqual(state.apiContext.authSessionFence, currentAuthority)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertNil(state.toast)
        if retirement != .refresh {
            XCTAssertTrue(recorded.isEmpty)
            XCTAssertEqual(client.runtimeRouteSelector.recovery(routes, service: .tenantAPI)
                .consecutiveQualifiedColdLaunchFailures, 1)
        }
    }

    func testGroupDirectoryPageRouteRequiresCanonicalQueryAndPreservesEncodedScope() async throws {
        let prefix = "/api/tenant/groups?"
        let value = RemoteList<RemoteUserGroup>.self
        for query in [
            "scope=all&limit=7&limit=500&offset=0", "scope=all&scope=other&limit=500&offset=0",
            "scope=all&limit=500&offset=0&offset=500", "scope=all&&limit=500&offset=0",
            "scope=all&limit=500&offset=+0", "scope=all&limit=500&offset=00",
            "scope=all&limit=500&offset=-1", "scope=all&offset=0&limit=500",
            "scope=all&limit=50&offset=0", "scope=all&limit=500&offset=0&", "scope=%Q&limit=500&offset=0",
            "scope=all#fragment&limit=500&offset=0", "scope=raw space&limit=500&offset=0"
        ] {
            XCTAssertEqual(TypedListResponseRoute.matching(method: "GET", path: prefix + query, response: value),
                           .other, query)
        }
        let canonical = prefix + "scope=all&limit=500&offset=500"
        XCTAssertEqual(TypedListResponseRoute.matching(method: "GET", path: canonical, response: value), .groupDirectory)
        XCTAssertEqual(TypedListResponseRoute.matching(method: "POST", path: canonical, response: value), .other)
        XCTAssertEqual(TypedListResponseRoute.matching(method: "GET", path: canonical, response: RemoteUserGroup.self),
                       .other)
        let transport = FakeHTTPTransport(results: [
            .init(data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
        let (threads, decode) = AsyncStream<Bool>.makeStream()
        let scope = "群 & value=%"
        _ = try await SDKHTTPTrace.$current.withValue((
            sourceCorrelation: 4, delivery: { _, _, _ in }, decode: { _, _, onMain in decode.yield(onMain) },
            linkToPhysicalSource: { _ in }
        )) { try await client.listGroups(context: makeContext(), scope: scope) }
        decode.finish()
        let observed = await threads.reduce(into: [Bool]()) { @Sendable values, onMain in values.append(onMain) }
        XCTAssertEqual(observed, [false])
        let url = try XCTUnwrap(transport.requests().first?.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "scope", value: scope), URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "offset", value: "0")
        ])
    }

    func testCurrentGroupDirectoryPagePreservesSessionAndBusinessErrors() async throws {
        let context = makeContext()
        let expectedAuthority = context.authSessionFence
        let rejected = expectation(description: "Current device rejection uses the request authority")
        let observer = NotificationCenter.default.addObserver(forName: .imCurrentDeviceRevoked, object: nil, queue: nil) { note in
            XCTAssertEqual(note.object as? IMAuthSessionFence, expectedAuthority)
            rejected.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for (status, code) in [(401, "unauthorized"), (403, "group_access_denied"), (403, "device_revoked"), (423, "account_locked")] {
            let data = try JSONSerialization.data(withJSONObject: ["ok": false, "error": ["code": code, "message": "Fixture"]])
            let transport = FakeHTTPTransport(results: [.init(data: data, isHTTPResponse: true, statusCode: status)])
            let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
            do {
                _ = try await client.listGroups(context: context, scope: "all")
                XCTFail("Expected group directory error \(code)")
            } catch let error as IMAPIError {
                switch (code, error) {
                case ("unauthorized", .unauthorized(let message)):
                    XCTAssertEqual(message, "Fixture")
                case ("device_revoked", .unauthorized(let message)):
                    XCTAssertEqual(message, DeviceRevocationDetector.logoutMessage)
                case ("group_access_denied", .businessForbidden(let actual, _, _)),
                     ("account_locked", .loginSecurity(let actual, _, _)):
                    XCTAssertEqual(actual, code)
                default:
                    XCTFail("Unexpected error \(error) for \(code)")
                }
            }
            XCTAssertEqual(transport.requests().count, 1)
        }
        await fulfillment(of: [rejected], timeout: 2)
    }
}
// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END

// WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
extension HTTPTransportTests {
    func testM9OrganizationTreeDecodeRetirementCancellationAndCurrentFailover() async throws {
        let tree = Data(#"{"ok":true,"data":{"department_enabled":false,"items":[]}}"#.utf8)
        let scenarios = [
            (status: 503, recovering: false, retire: true, cancel: false),
            (status: 200, recovering: true, retire: true, cancel: false),
            (status: 200, recovering: false, retire: false, cancel: true),
            (status: 503, recovering: false, retire: false, cancel: false)
        ]
        for scenario in scenarios {
            let first = scenario.status == 200 ? tree : Data(#"{"ok":false}"#.utf8)
            let transport = FakeHTTPTransport(results: [
                .init(data: first, isHTTPResponse: true, statusCode: scenario.status),
                .init(data: tree, isHTTPResponse: true, statusCode: 200)
            ])
            let (state, client, routes) = try makeM9ScopedListState(transport: transport,
                service: .tenantAPI, recovering: scenario.recovering)
            let store = state.organizationDirectoryStore
            let before = client.runtimeRouteSelector.recovery(routes, service: .tenantAPI)
            let decoded = expectation(description: "First tree response decoded")
            let release = DispatchSemaphore(value: 0)
            let trace = m9PausedDecode(decoded, release: release)
            let pending = Task {
                await SDKHTTPTrace.$current.withValue(trace) {
                    await state.refreshOrganizationDirectoryForCurrentSnapshot()
                }
            }
            // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112_BEGIN
            let arrived = await XCTWaiter.fulfillment(of: [decoded], timeout: 2)
            guard arrived == .completed else {
                pending.cancel()
                release.signal()
                _ = await pending.value
                XCTFail("The first background decode did not reach its gate: \(arrived)")
                return
            }
            // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112_END
            let replacement = scenario.retire ? store.beginRefresh() : nil
            if scenario.cancel { pending.cancel() }
            release.signal()
            await pending.value

            let hosts = transport.requests().map(\.url?.host)
            if scenario.retire || scenario.cancel {
                XCTAssertEqual(hosts, [scenario.recovering ? "tenant-backup.example.net" : "tenant-primary.example.com"])
                XCTAssertNil(store.snapshot.tree)
                XCTAssertNil(store.snapshot.errorMessage)
                XCTAssertFalse(client.coldLaunchOutcomeRecordedServices.contains(.tenantAPI))
                XCTAssertEqual(client.runtimeRouteSelector.recovery(routes, service: .tenantAPI), before)
                XCTAssertNil(client.accessDiagnosticsRouteHits[.tenantAPI])
                XCTAssertFalse(client.preferredHTTPProbeInFlightServices.contains(.tenantAPI))
                if let replacement {
                    XCTAssertTrue(store.ownsRefresh(replacement))
                    store.finishRefresh(replacement)
                }
            } else {
                XCTAssertEqual(hosts, ["tenant-primary.example.com", "tenant-backup.example.net"])
                XCTAssertNotNil(store.snapshot.tree)
            }
        }
    }

    func testM9OrganizationTreeDelayedProbeChecksCurrentSessionAfterRefreshEnds() async throws {
        let tree = HTTPTransportResult(data: Data(#"{"ok":true,"data":{"department_enabled":false,"items":[]}}"#.utf8),
            isHTTPResponse: true, statusCode: 200)
        for renew in [false, true] {
            let sleep = M9PreferredMembersProbePause()
            defer { sleep.close() }
            let transport = FakeHTTPTransport(results: [tree, tree])
            let (state, client, routes) = try makeM9ScopedListState(transport: transport,
                service: .tenantAPI, recovering: true, sleep: sleep)
            await state.refreshOrganizationDirectoryForCurrentSnapshot()
            XCTAssertNotNil(state.organizationDirectoryStore.snapshot.tree)
            XCTAssertFalse(state.organizationDirectoryStore.snapshot.isSyncing)
            try await waitForCondition { sleep.isWaiting }
            XCTAssertEqual(transport.requests().map(\.url?.host), ["tenant-backup.example.net"])
            let before = client.runtimeRouteSelector.recovery(routes, service: .tenantAPI)
            if renew { state.apiContext.credentialRevision += 1 }
            try sleep.release()
            if renew {
                try await waitForCondition { !client.preferredHTTPProbeInFlightServices.contains(.tenantAPI) }
                XCTAssertFalse(client.preferredHTTPProbeInFlightServices.contains(.tenantAPI)) // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112
                XCTAssertEqual(transport.requests().map(\.url?.host), ["tenant-backup.example.net"])
                XCTAssertEqual(client.runtimeRouteSelector.recovery(routes, service: .tenantAPI), before)
            } else {
                try await waitForCondition { sleep.isWaiting || !client.preferredHTTPProbeInFlightServices.contains(.tenantAPI) }
                XCTAssertEqual(transport.requests().map(\.url?.host), ["tenant-backup.example.net", "tenant-primary.example.com"])
                XCTAssertNotEqual(client.runtimeRouteSelector.recovery(routes, service: .tenantAPI), before)
                sleep.close()
                try await waitForCondition { !client.preferredHTTPProbeInFlightServices.contains(.tenantAPI) }
                XCTAssertFalse(client.preferredHTTPProbeInFlightServices.contains(.tenantAPI)) // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112
            }
        }
    }

    func testM9FavoritesDecodeFencesSecurityDenialsAndKeepsSinglePOST() async throws {
        let scenarios = [
            (status: 403, scope: "global", renew: true, cancel: false),
            (status: 403, scope: "tenant", renew: true, cancel: false),
            (status: 403, scope: "global", renew: false, cancel: false),
            (status: 403, scope: "tenant", renew: false, cancel: false),
            (status: 200, scope: "", renew: true, cancel: false),
            (status: 200, scope: "", renew: false, cancel: true),
            (status: 503, scope: "", renew: false, cancel: false)
        ]
        for scenario in scenarios {
            let body: [String: Any]
            if scenario.status == 403 {
                body = ["ok": false, "error": ["code": "security_blocked", "scope": scenario.scope]]
            } else if scenario.status == 200 {
                body = ["ok": true, "data": ["items": [], "next_cursor": "kept", "has_more": true]]
            } else {
                body = ["ok": false]
            }
            let transport = FakeHTTPTransport(results: [
                .init(data: try JSONSerialization.data(withJSONObject: body), isHTTPResponse: true, statusCode: scenario.status)
            ])
            let (state, client, routes) = try makeM9ScopedListState(transport: transport, service: .imAPI)
            let realtime = try XCTUnwrap(state.realtimeClient as? PostLoginSilentRealtimeTransport)
            realtime.start(url: URL(string: "wss://im.example.test")!, token: "synthetic")
            let before = client.runtimeRouteSelector.recovery(routes, service: .imAPI)
            let decoded = expectation(description: "Favorites response decoded")
            let release = DispatchSemaphore(value: 0)
            let trace = m9PausedDecode(decoded, release: release)
            let pending = Task {
                await SDKHTTPTrace.$current.withValue(trace) { await state.refreshFavoriteAssetsPage() }
            }
            // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112_BEGIN
            let arrived = await XCTWaiter.fulfillment(of: [decoded], timeout: 2)
            guard arrived == .completed else {
                pending.cancel()
                release.signal()
                _ = await pending.value
                XCTFail("The first background decode did not reach its gate: \(arrived)")
                return
            }
            // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112_END
            if scenario.renew { state.apiContext.credentialRevision += 1 }
            if scenario.cancel { pending.cancel() }
            release.signal()
            let page = await pending.value

            XCTAssertEqual(transport.requests().map(\.httpMethod), ["POST"])
            XCTAssertEqual(transport.requests().map(\.url?.host), ["im-primary.example.com"])
            XCTAssertEqual(transport.requests().map(\.url?.path), ["/api/im/favorites/list"])
            if scenario.renew || scenario.cancel {
                XCTAssertEqual(page.didSucceed, scenario.status == 200 && !scenario.cancel)
                if page.didSucceed { XCTAssertEqual(page.nextCursor, "kept") }
                XCTAssertTrue(state.apiContext.hasIMSession)
                XCTAssertTrue(state.isAuthenticated)
                XCTAssertTrue(realtime.isConnected)
                XCTAssertNotEqual(state.currentEnterprise.enterable, false)
                XCTAssertNil(state.favoriteAssetsSyncErrorMessage)
                XCTAssertFalse(client.coldLaunchOutcomeRecordedServices.contains(.imAPI))
                XCTAssertEqual(client.runtimeRouteSelector.recovery(routes, service: .imAPI), before)
                XCTAssertNil(client.accessDiagnosticsRouteHits[.imAPI])
            } else if scenario.status == 403 {
                XCTAssertFalse(page.didSucceed)
                XCTAssertFalse(state.apiContext.hasIMSession)
                XCTAssertFalse(realtime.isConnected)
                XCTAssertFalse(state.isAuthenticated)
                if scenario.scope == "tenant" {
                    XCTAssertEqual(state.currentEnterprise.disabledReason, "security_blocked")
                }
            } else {
                XCTAssertFalse(page.didSucceed)
                XCTAssertTrue(state.apiContext.hasIMSession)
                XCTAssertNotNil(state.favoriteAssetsSyncErrorMessage)
            }
        }
    }

    // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112_BEGIN
    private func m9PausedDecode(_ decoded: XCTestExpectation, release: DispatchSemaphore) -> SDKHTTPTraceContext {
        let gate = Phase6AliasContentionGate(entered: [decoded], releases: [release])
        return (sourceCorrelation: 3, delivery: { _, _, _ in }, decode: { _, _, onMain in
            XCTAssertFalse(onMain)
            gate.holdAttempt()
        }, linkToPhysicalSource: { _ in })
    }
    // WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112_END

    private func makeM9ScopedListState(transport: HTTPTransport, service: IMRuntimeRouteService,
        recovering: Bool = false, sleep: M9PreferredMembersProbePause? = nil)
        throws -> (AppState, IMAPIClient, IMRuntimeRouteSnapshot) {
        let routes = runtimeRouteSnapshotForHTTPWiring()
        let routeStore = isolatedRuntimeRouteStore()
        let clock = RuntimeRouteTestClock(nowMS: 100_000)
        let lifecycle = IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
        var context = makeContext()
        context.platformToken = nil
        let client = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://seed-tenant.example.test")!,
            imBase: URL(string: "https://seed-im.example.test")!,
            httpTransport: transport, runtimeRouteStore: routeStore, startupContext: context,
            runtimeColdLaunchLifecycle: lifecycle, runtimeMonotonicNowMS: { clock.now() }, runtimeSleep: { duration in
                if let sleep { try await sleep.wait() }
                clock.advance(by: duration)
            })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m9-list-owner-" + UUID().uuidString)
        let state = AppState(api: client, realtimeClient: PostLoginSilentRealtimeTransport(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")),
            protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
        state.setCurrentEnterprise(Enterprise(id: try XCTUnwrap(context.tenantID), name: "Fixture", code: "",
            role: "member", status: "active", memberCount: 1, isDefault: false, accentHex: 0x334455))
        state.suppressCurrentUserIdentityPersistence = true
        state.authenticationPresentationStore.setInitialAuthentication(true)
        state.setAuthScreen(.accountLogin)
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
        ).data)
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        state.organizationDirectoryStore.setTenantDepartmentEnabled(true)
        _ = state.remoteSyncEngine.beginRemoteSnapshotRefresh()
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
        XCTAssertTrue(routeStore.updateRecovery(.init(consecutiveQualifiedColdLaunchFailures: 1, recovery: recovering),
            service: service, snapshot: routes))
        lifecycle.beginProcessLaunch()
        lifecycle.sceneDidBecomeActive()
        lifecycle.setNetworkReachable(true)
        XCTAssertTrue(lifecycle.isTracking)
        return (state, client, routes)
    }
}
// WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END

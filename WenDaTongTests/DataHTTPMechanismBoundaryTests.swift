// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_BEGIN
import Foundation
import IM4Core // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
import XCTest
@testable import IM4Data
@testable import WenDaTong

@MainActor
final class DataHTTPMechanismBoundaryTests: XCTestCase {
    func testAppDefaultsActuallyConstructDataTransportAndStoreWithCoreContract() {
        let client = IMAPIClient()
        XCTAssertTrue(client.httpTransport is IM4Data.URLSessionHTTPTransport)
        XCTAssertTrue(String(reflecting: type(of: client.inFlightGETRequests)).hasPrefix("IM4Data.HTTPInFlightRequestStore<"))
        XCTAssertEqual(String(reflecting: HTTPTransportResult.self), "IM4Core.HTTPTransportResult")
    }

    func testStoreFactoryRunsSynchronouslyAtOriginalCallPointAndSharesOriginalTask() async throws {
        let store = HTTPInFlightRequestStore<Int>()
        var events = ["before"]
        let creator = store.task(for: "opaque-app-key") {
            events.append("factory")
            return Task { 17 }
        }
        let borrower = store.task(for: "opaque-app-key") {
            XCTFail("shared factory unexpectedly executed")
            return Task { 99 }
        }
        events.append("after")
        XCTAssertEqual(events, ["before", "factory", "after"])
        XCTAssertEqual(creator.task, borrower.task)
        let value = try await borrower.task.value
        XCTAssertEqual(value, 17)
        store.finish(borrower)
        XCTAssertEqual(store.registeredTaskCount, 1)
        store.finish(creator)
        XCTAssertEqual(store.registeredTaskCount, 0)
    }

    func testCreatorFailureCanBeReleasedThenSameKeyRecreatedWithoutChangingError() async throws {
        let store = HTTPInFlightRequestStore<Int>()
        let failed = store.task(for: "opaque") { Task { throw URLError(.cannotConnectToHost) } }
        do { _ = try await failed.task.value; XCTFail("failure unexpectedly succeeded") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        store.finish(failed)
        let retry = store.task(for: "opaque") { Task { 23 } }
        let value = try await retry.task.value
        XCTAssertEqual(value, 23)
        XCTAssertEqual(store.registeredTaskCount, 1)
        store.finish(retry)
        XCTAssertEqual(store.registeredTaskCount, 0)
    }

    func testURLSessionTransportUsesInjectedSessionAndPreservesNativeErrorAndResponse() async throws {
        RuntimeRouteURLProtocol.reset()
        defer { RuntimeRouteURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(session: session)
        let url = URL(string: "https://transport.example.test/path?q=fixture")!
        RuntimeRouteURLProtocol.install { request in
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Fixture"), "opaque")
            return (207, Data("fixture-response".utf8))
        }
        var request = URLRequest(url: url)
        request.setValue("opaque", forHTTPHeaderField: "X-Fixture")
        let result = try await transport.data(for: request)
        XCTAssertEqual(result.data, Data("fixture-response".utf8))
        XCTAssertEqual(result.statusCode, 207)
        XCTAssertEqual(result.responseURL, url)
        XCTAssertEqual(result.value(forHTTPHeaderField: "content-type"), "application/json")
        RuntimeRouteURLProtocol.install { _ in
            throw URLError(.serverCertificateUntrusted, userInfo: ["FixtureMarker": "original"])
        }
        do { _ = try await transport.data(for: request); XCTFail("TLS failure unexpectedly accepted") }
        catch {
            let error = error as NSError
            XCTAssertEqual(error.domain, NSURLErrorDomain)
            XCTAssertEqual(error.code, URLError.serverCertificateUntrusted.rawValue)
            XCTAssertEqual(error.userInfo["FixtureMarker"] as? String, "original")
        }
    }

}
// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_END

// WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
extension HTTPTransportTests {
    func testUserProfilesHundredRowsDecodeOffMainAndPreserveValues() async throws {
        captureA43RuntimeLoadedImages()
        let uids = (1...100).map { "profile-fixture-\($0)" }
        let items: [[String: Any]] = uids.map { uid in
            ["im_uid": uid, "user_id": uid, "user_summary": [
                "schema": "user_summary.v2", "contract_version": 1, "user_revision": 9,
                "generations": ["identity": 41, "certification": 7],
                "im_uid": uid, "user_id": uid, "display_name": "Fixture \(uid)",
                "display_name_source": "nickname", "raw_nickname": "Fixture \(uid)",
                "avatar": ["url": "/avatar.png", "version": "v1", "source": "uploaded"],
                "certification": ["verified": true, "label": "Test", "style": "tenant_certified_v1", "revision": 3]
            ]]
        }
        let payload: [String: Any] = ["items": items, "missing_uids": [String](), "max_uids": 100]
        let expected = try JSONDecoder().decode(RemoteUserProfilesResponse.self,
            from: JSONSerialization.data(withJSONObject: payload))
        let response = try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload])
        RuntimeRouteURLProtocol.install { request in
            guard request.httpMethod == "POST", request.url?.path == "/api/tenant/users/profiles" else {
                throw URLError(.unsupportedURL)
            }
            return (200, response)
        }
        defer { RuntimeRouteURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = makeClient(transport: URLSessionHTTPTransport(session: session),
            runtimeRouteStore: isolatedRuntimeRouteStore())
        let (stream, trace) = AsyncStream<Bool>.makeStream()
        let result = try await SDKHTTPTrace.$current.withValue((
            sourceCorrelation: 1, delivery: { _, _, _ in },
            decode: { _, _, onMain in trace.yield(onMain) }, linkToPhysicalSource: { _ in }
        )) {
            try await client.userProfiles(context: makeContext(), exactUIDs: uids)
        }
        trace.finish()
        var threads: [Bool] = []
        for await flag in stream { threads.append(flag) }
        let evidence = XCTAttachment(string: "profiles=\(result.items.count) decode_on_main=\(threads)")
        evidence.name = "user-profiles-decode-thread"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.items.map(\.imUID), uids)
        XCTAssertTrue(result.items.allSatisfy {
            if case .authoritative = $0.userSummaryProjection { return true }
            return false
        })
        XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts().count, 1)
        XCTAssertEqual(threads, [false])
        try await assertUserProfilesDoesNotClassifyRetiredDecode(transport: URLSessionHTTPTransport(session: session), success: response)
    }

    private func assertUserProfilesDoesNotClassifyRetiredDecode(transport: URLSessionHTTPTransport, success: Data) async throws {
        let observer = NotificationCenter.default.addObserver(forName: .imCurrentDeviceRevoked, object: nil, queue: nil) { _ in
            XCTFail("A retired user-profiles response emitted a device-revocation event")
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
        ).data)
        for retireAuthority in [false, true] {
            let revoked = Data(#"{"ok":false,"error":{"code":"device_revoked","message":"Fixture revoked"}}"#.utf8)
            RuntimeRouteURLProtocol.install { request in
                guard request.httpMethod == "POST", request.url?.path == "/api/tenant/users/profiles" else {
                    throw URLError(.unsupportedURL)
                }
                return retireAuthority ? (403, revoked) : (200, success)
            }
            let state = makeIsolatedAuthenticatedHTTPState(transport: transport, context: makeContext())
            // A cold policy lookup would run inside the profiles decode observation.
            state.appPolicyPresentationStore.installResolvedPolicy(policy)
            state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
            let context = state.apiContext
            let decoded = expectation(description: "Typed user-profiles decode reached its completion observer")
            let release = DispatchSemaphore(value: 0)
            let task = Task { @MainActor in
                try await SDKHTTPTrace.$current.withValue((
                    sourceCorrelation: 2, delivery: { _, _, _ in }, decode: { _, _, onMain in
                        XCTAssertFalse(onMain)
                        decoded.fulfill()
                        _ = release.wait(timeout: .now() + 3)
                    }, linkToPhysicalSource: { _ in }
                )) {
                    try await state.fetchUserProfiles(context: context, exactUIDs: ["profile-fixture-1"])
                }
            }
            let reachedDecode = await XCTWaiter.fulfillment(of: [decoded], timeout: 2)
            if retireAuthority {
                var replacement = context
                replacement.credentialRevision += 1
                state.apiContext = replacement
            } else {
                task.cancel()
            }
            let currentAuthority = state.apiContext.authSessionFence
            release.signal()
            XCTAssertEqual(reachedDecode, .completed)
            do {
                _ = try await task.value
                XCTFail("A retired user-profiles response was delivered")
            } catch is CancellationError {
                // Cancellation is classified before either envelope can affect this caller.
            }
            XCTAssertTrue(state.isAuthenticated)
            XCTAssertEqual(state.apiContext.authSessionFence, currentAuthority)
            XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts().count, 1)
        }
    }
}
// WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END

// WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
extension HTTPTransportTests {
    func testRetiredUserProfilesFailoverCannotRecordColdRouteOutcome() async throws {
        captureA43RuntimeLoadedImages()
        for scenario in ProfileColdRouteScenario.allCases {
            let suite = "ProfileColdRoute.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(ProfileRouteRecordingDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = IMRuntimeRouteStore(defaults: defaults)
            let routes = runtimeRouteSnapshotForHTTPWiring()
            let lifecycle = IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
            lifecycle.beginProcessLaunch()
            lifecycle.sceneDidBecomeActive()
            lifecycle.setNetworkReachable(true)
            let clock = RuntimeRouteTestClock(nowMS: 10_000)
            let owner = ProfileColdRouteOwner(context: makeContext(), scenario: scenario)
            let transport = RuntimeRouteBudgetTransport(clock: clock, actions: [
                .failure(.timedOut, advanceMS: 1_000),
                .failure(.timedOut, advanceMS: 1_000),
                .response(status: 200,
                    data: Data(#"{"ok":true,"data":{"items":[],"missing_uids":["uid-1"],"max_uids":100}}"#.utf8),
                    advanceMS: 0)
            ])
            let client = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://seed-tenant.example.test")!,
                imBase: URL(string: "https://seed-im.example.test")!,
                httpTransport: transport, runtimeRouteStore: store, runtimeColdLaunchLifecycle: lifecycle,
                runtimeMonotonicNowMS: { clock.now() }, runtimeSleep: { duration in
                    clock.advance(by: duration)
                    try await owner.waitForBackup()
                })
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
            XCTAssertTrue(store.updateRecovery(.init(consecutiveQualifiedColdLaunchFailures: 1),
                service: .tenantAPI, snapshot: routes))
            let before = store.record(appID: routes.appID, tenantID: routes.tenantID)
            let writes = defaults.writeCount()
            let captured = owner.context
            do {
                _ = try await UserProfilesRequestAuthority.$isCurrent.withValue({
                    owner.context.isSameAuthAuthority(as: captured.authSessionFence)
                }) {
                    try await client.userProfiles(context: captured, exactUIDs: ["uid-1"])
                }
                XCTFail("The previous profile attempt unexpectedly completed")
            } catch is CancellationError {
                // The interrupted attempt may not send a backup request.
            }
            XCTAssertEqual(owner.waits, 1)
            XCTAssertEqual(transport.requestHosts(), ["tenant-primary.example.com"])
            XCTAssertTrue(transport.requests().allSatisfy { $0.httpMethod == "POST" })
            if scenario == .currentCancellation {
                XCTAssertEqual(defaults.writeCount(), writes + 1)
                XCTAssertTrue(client.coldLaunchOutcomeRecordedServices.contains(.tenantAPI))
                XCTAssertEqual(client.runtimeRouteSelector.recovery(routes, service: .tenantAPI)
                    .consecutiveQualifiedColdLaunchFailures, 0)
                continue
            }
            XCTAssertFalse(owner.context.isSameAuthAuthority(as: captured.authSessionFence))
            XCTAssertEqual(owner.context.tenantID, captured.tenantID)
            XCTAssertEqual(owner.context.sessionEpoch, captured.sessionEpoch)
            XCTAssertEqual(defaults.writeCount(), writes)
            XCTAssertEqual(store.record(appID: routes.appID, tenantID: routes.tenantID), before)
            XCTAssertTrue(client.coldLaunchOutcomeRecordedServices.isEmpty)
            let fresh = owner.context
            let response = try await UserProfilesRequestAuthority.$isCurrent.withValue({
                owner.context.isSameAuthAuthority(as: fresh.authSessionFence)
            }) {
                try await client.userProfiles(context: fresh, exactUIDs: ["uid-1"])
            }
            XCTAssertEqual(response.missingUIDs, ["uid-1"])
            XCTAssertEqual(owner.waits, 2)
            XCTAssertEqual(transport.requestHosts(), [
                "tenant-primary.example.com", "tenant-primary.example.com", "tenant-backup.example.net"
            ])
            XCTAssertEqual(defaults.writeCount(), writes + 1)
            XCTAssertEqual(client.coldLaunchOutcomeRecordedServices, [.tenantAPI])
            XCTAssertEqual(client.runtimeRouteSelector.recovery(routes, service: .tenantAPI)
                .consecutiveQualifiedColdLaunchFailures, 2)
        }
    }
}

private enum ProfileColdRouteScenario: CaseIterable {
    case retiredWaitReturns, retiredWaitThrows, currentCancellation
}

@MainActor
private final class ProfileColdRouteOwner {
    var context: IMAPIContext
    let scenario: ProfileColdRouteScenario
    private(set) var waits = 0

    init(context: IMAPIContext, scenario: ProfileColdRouteScenario) {
        self.context = context
        self.scenario = scenario
    }

    func waitForBackup() throws {
        waits += 1
        guard waits == 1 else { return }
        if scenario != .currentCancellation { context.credentialRevision += 1 }
        if scenario != .retiredWaitReturns { throw CancellationError() }
    }
}

private final class ProfileRouteRecordingDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { writes += 1 }
        super.set(value, forKey: defaultName)
    }

    func writeCount() -> Int { lock.withLock { writes } }
}
// WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END

// WDT_IOS1_ORG_MEMBERS_PREFERRED_PROBE_AUTHORITY_20261111_BEGIN
extension HTTPTransportTests {
    func testM9PreferredMembersProbeOutlivesRefreshAndRespectsRetirement() async throws {
        captureA43RuntimeLoadedImages()
        let primary = "tenant-primary.example.com"
        let backup = "tenant-backup.example.net"
        let memberPath = "/api/tenant/org/members?department_id=dep%20%26%20team"
        let tree = #"{"ok":true,"data":{"department_enabled":true,"root":{"department_id":"company","children":[{"department_id":"dep & team"}]}}}"#
        let company = #"{"ok":true,"data":{"department_enabled":true,"items":[]}}"#
        let member = #"{"ok":true,"data":{"department_enabled":true,"items":[{"im_uid":"probe-member","nickname":"Probe member"}]}}"#
        let failure = #"{"ok":false,"error":{"code":"unavailable","message":"Fixture outage"}}"#
        func result(_ payload: String, _ status: Int = 200) -> HTTPTransportResult {
            .init(data: Data(payload.utf8), isHTTPResponse: true, statusCode: status)
        }

        var evidence: [[String: Any]] = []
        for scenario in M9PreferredMembersProbeScenario.allCases {
            let clock = RuntimeRouteTestClock(nowMS: 100_000)
            let sleep = M9PreferredMembersProbePause()
            let backupMember = M9PreferredMembersProbePause()
            let primaryDispatch = M9PreferredMembersProbePause()
            let defaultsName = "M9PreferredMembersProbe." + UUID().uuidString
            let defaults = try XCTUnwrap(ProfileRouteRecordingDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let store = IMRuntimeRouteStore(defaults: defaults)
            let transport = StrictAttachmentHTTPTransport(results: [
                result(tree), result(company), result(failure, 503), result(member),
                scenario == .httpFailure ? result(failure, 503) : result(member)
            ], uploadResults: [])
            let client = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://seed-tenant.example.test")!,
                imBase: URL(string: "https://seed-im.example.test")!,
                httpTransport: transport,
                runtimeRouteStore: store,
                runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false),
                runtimeMonotonicNowMS: { clock.now() },
                runtimeSleep: { milliseconds in
                    try await sleep.wait()
                    clock.advance(by: milliseconds)
                }
            )
            let routes = runtimeRouteSnapshotForHTTPWiring()
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
            XCTAssertTrue(store.updateRecovery(.init(recovery: true), service: .tenantAPI, snapshot: routes))
            let generation = client.tenantRouteTransientGeneration
            let context = makeContext()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(defaultsName)
            let state = AppState(
                api: client, realtimeClient: PostLoginSilentRealtimeTransport(),
                messageStore: AvatarProjectionEmptyMessageStore(),
                messagePersistence: MessagePersistenceCoordinator(
                    applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
                protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context
            )
            let policy = try XCTUnwrap(JSONDecoder().decode(
                APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
            ).data)
            state.appPolicyPresentationStore.installResolvedPolicy(policy)
            state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
            state.authenticationPresentationStore.setInitialAuthentication(true)
            state.organizationDirectoryStore.setTenantDepartmentEnabled(true)
            _ = state.remoteSyncEngine.beginRemoteSnapshotRefresh()
            let originalGate = client.forcedAuthRequestGate
            client.forcedAuthRequestGate = { request in
                try await originalGate?(request)
                guard request.path == memberPath else { return }
                if request.base.host == backup {
                    try await backupMember.wait()
                } else if scenario == .retiredAtDispatch, request.base.host == primary {
                    try await primaryDispatch.wait()
                } else if scenario == .localPolicyRefusal, request.base.host == primary {
                    throw IMAPIError.forcedAuthRequired(.phone)
                }
            }

            let refresh = Task { await state.refreshOrganizationDirectoryForCurrentSnapshot() }
            defer {
                refresh.cancel()
                sleep.close()
                backupMember.close()
                primaryDispatch.close()
                client.forcedAuthRequestGate = originalGate
            }
            try await waitForCondition { sleep.isWaiting && backupMember.isWaiting }
            XCTAssertTrue(state.organizationDirectoryStore.snapshot.isSyncing)
            XCTAssertEqual(transport.requests().map { $0.url?.host }, [backup, backup])
            try sleep.release()
            try await waitForCondition { !client.preferredHTTPProbeInFlightServices.contains(.tenantAPI) }
            XCTAssertFalse(client.preferredHTTPProbeInFlightServices.contains(.tenantAPI))
            XCTAssertEqual(transport.requests().map { $0.url?.path },
                           ["/api/tenant/org/tree", "/api/tenant/org/members", "/api/tenant/org/tree"])
            XCTAssertEqual(transport.requests().last?.url?.host, primary)
            let seeded = IMRuntimeRouteRecoveryState(recovery: true, consecutiveStablePreferredProbes: 1,
                                                     lastStableProbeAtMS: clock.now())
            XCTAssertTrue(store.updateRecovery(seeded, service: .tenantAPI, snapshot: routes))
            try backupMember.release()
            await refresh.value
            XCTAssertFalse(state.organizationDirectoryStore.snapshot.isSyncing)
            XCTAssertEqual(state.organizationDirectoryStore.snapshot.members(for: "dep & team").map { $0.id }, ["probe-member"])
            try await waitForCondition { sleep.isWaiting }
            XCTAssertEqual(transport.requests().map { $0.url?.host }, [backup, backup, primary, backup])
            let writes = defaults.writeCount()
            let before = store.record(appID: routes.appID, tenantID: routes.tenantID)
            func retireAuthority() {
                state.apiContext.credentialRevision += 1
                XCTAssertFalse(state.apiContext.isSameAuthAuthority(as: context.authSessionFence))
                XCTAssertTrue(client.runtimeProbeAuthorityIsCurrent(routes, tenantGeneration: generation))
            }
            if scenario == .retiredBeforeWake { retireAuthority() }
            try sleep.release(cancelled: scenario == .localCancellation)
            if scenario == .retiredAtDispatch {
                try await waitForCondition { primaryDispatch.isWaiting }
                retireAuthority()
                try primaryDispatch.release()
            }
            try await waitForCondition { !client.preferredHTTPProbeInFlightServices.contains(.tenantAPI) }
            XCTAssertFalse(client.preferredHTTPProbeInFlightServices.contains(.tenantAPI))
            let requests = transport.requests()
            let recovery = client.runtimeRouteSelector.recovery(routes, service: .tenantAPI)
            let writeDelta = defaults.writeCount() - writes
            if scenario == .success || scenario == .httpFailure {
                XCTAssertEqual(requests.map { $0.url?.host }, [backup, backup, primary, backup, primary])
                let probe = try XCTUnwrap(requests.last)
                XCTAssertEqual(probe.httpMethod, "GET")
                XCTAssertEqual(probe.cachePolicy, .reloadIgnoringLocalCacheData)
                XCTAssertEqual(probe.url?.path, "/api/tenant/org/members")
                let components = URLComponents(url: try XCTUnwrap(probe.url), resolvingAgainstBaseURL: false)
                XCTAssertEqual(components?.percentEncodedQuery, "department_id=dep%20%26%20team")
                XCTAssertTrue(probe.value(forHTTPHeaderField: "Authorization") == context.imToken.map { "Bearer " + $0 })
                XCTAssertEqual(recovery, .init(recovery: scenario == .httpFailure))
                XCTAssertEqual(writeDelta, 1)
            } else {
                XCTAssertEqual(requests.count, 4)
                XCTAssertEqual(recovery, seeded)
                XCTAssertEqual(store.record(appID: routes.appID, tenantID: routes.tenantID), before)
                XCTAssertEqual(writeDelta, 0)
            }
            evidence.append(["scenario": scenario.rawValue, "writes": writeDelta, "recovery": recovery.recovery,
                             "stablePreferredProbes": recovery.consecutiveStablePreferredProbes,
                             "afterRefreshRequests": requests.dropFirst(4).compactMap { $0.url?.absoluteString }])
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence), uniformTypeIdentifier: "public.json")
        attachment.name = "M9-preferred-members-probe-authority"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum M9PreferredMembersProbeScenario: String, CaseIterable {
    case success, retiredBeforeWake, retiredAtDispatch, localCancellation, localPolicyRefusal, httpFailure
}

@MainActor
final class M9PreferredMembersProbePause { // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
    private var pending: CheckedContinuation<Void, Error>?
    private var closed = false
    var isWaiting: Bool { pending != nil }

    func wait() async throws {
        guard !closed else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil)
            pending = continuation
        }
    }

    func release(cancelled: Bool = false) throws {
        let continuation = try XCTUnwrap(pending)
        pending = nil
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume()
        }
    }

    func close() {
        closed = true
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}
// WDT_IOS1_ORG_MEMBERS_PREFERRED_PROBE_AUTHORITY_20261111_END

extension HTTPTransportTests { // WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111_BEGIN
    func testTenantListsDecodeOffMainThroughURLSessionAndConsumers() async throws {
        captureA43RuntimeLoadedImages()
        let friends = Data(#"""
            {"ok":true,"data":{"items":[
              {"friend_uid":"peer-1","friend_user_id":"directory-1","friend_nickname":"Alice","remark":"Pinned"},
              {"friend_uid":"peer-1","friend_nickname":"Duplicate","remark":null}
            ]}}
            """#.utf8)
        let members = Data(#"""
            {"ok":true,"data":{
              "items":[{"im_uid":"peer-2","nickname":"Bob","role":"member","joined_at":null}],
              "self_member":null,"selfMember":{"im_uid":"uid-1","group_nickname":"My group name","role":"admin","revision":7},
              "total_count":"9","limit":"100","offset":null,"hasMore":"true","next_offset":"1","nextCursor":"opaque:+/="
            }}
            """#.utf8)
        RuntimeRouteURLProtocol.install { request in
            guard request.httpMethod == "GET" else { throw URLError(.unsupportedURL) }
            switch request.url?.path {
            case "/api/tenant/friends": return (200, friends)
            case "/api/tenant/groups/stage6-group/members": return (200, members)
            default: throw URLError(.unsupportedURL)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            RuntimeRouteURLProtocol.reset()
        }
        let suite = "tenant-lists-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let context = makeContext(tenantID: suite)
        let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec())
        let client = makeStage6ListClient(transport: URLSessionHTTPTransport(session: session), codec: codec,
            defaults: defaults, context: context)
        let state = AppState(
            api: client,
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            accessDiscovery: AccessDiscoveryManager(store: AccessDiscoveryStore(baseDirectory: root.appendingPathComponent("discovery"))),
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")),
            biometricDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: RecordingRememberedLoginPreferenceStore(),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context
        )
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data).data)
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        state.suppressCurrentUserIdentityPersistence = true
        state.setCurrentUser(makeUser(id: "uid-1", name: "Current"))
        state.groups = [makeGroupInfo(id: "stage6-group")]

        await state.refreshFriendPresenceForTesting()
        XCTAssertEqual(state.contacts.map(\.id), ["peer-1"])
        XCTAssertEqual(state.contactRemarks["peer-1"], "Pinned")
        let remarkRelations = try await client.friendRelationsForRemarkResolution(context: context)
        XCTAssertEqual(remarkRelations.map(\.authoritativeFriendUID), ["peer-1", "peer-1"])
        XCTAssertEqual(remarkRelations.map(\.remark), ["Pinned", nil])

        let page = try await client.listGroupMembersPaged(context: context, groupID: "stage6-group",
            limit: 100, offset: 5, cursor: "previous:+/=", keyword: nil, role: nil)
        XCTAssertEqual(page.selfMember?.imUID, "uid-1")
        XCTAssertEqual(page.items.map(\.imUID), ["peer-2"])
        XCTAssertNil(page.items.first?.joinedAt)
        XCTAssertEqual(page.total, 9)
        XCTAssertEqual(page.limit, 100)
        XCTAssertNil(page.offset)
        XCTAssertEqual(page.hasMore, true)
        XCTAssertEqual(page.nextOffset, 1)
        XCTAssertEqual(page.nextCursor, "opaque:+/=")

        let legacy = try await client.listGroupMembers(context: context, groupID: "stage6-group")
        XCTAssertEqual(legacy.total, 9)
        XCTAssertEqual(legacy.selfMember?.groupNickname, "My group name")
        XCTAssertNil(legacy.nextCursor)

        let projected = await state.searchGroupMentionMembers(groupID: "stage6-group", keyword: "")
        XCTAssertEqual(projected.map(\.id), ["peer-2"])
        XCTAssertEqual(state.myGroupNickname(groupID: "stage6-group"), "My group name")
        XCTAssertEqual(state.group(id: "stage6-group")?.membersNextCursor, "opaque:+/=")
        XCTAssertEqual(codec.decodedTypeNames().filter { $0.hasPrefix("APIEnvelope<") }, [
            "APIEnvelope<RemoteList<RemoteFriendRelation>>", "APIEnvelope<RemoteList<RemoteFriendRelation>>",
            "APIEnvelope<RemoteList<RemoteUserGroupMember>>", "APIEnvelope<RemoteList<RemoteUserGroupMember>>",
            "APIEnvelope<RemoteList<RemoteUserGroupMember>>",
        ])
        XCTAssertEqual(codec.decodedOnMainThread(), Array(repeating: false, count: 15))

        let decoded = expectation(description: "Group members decoded before group retirement")
        let resumeDecode = DispatchSemaphore(value: 0)
        let stalePage = Task {
            await SDKHTTPTrace.$current.withValue((
                sourceCorrelation: 1, delivery: { _, _, _ in }, decode: { _, _, onMain in
                    XCTAssertFalse(onMain)
                    decoded.fulfill()
                    _ = resumeDecode.wait(timeout: .now() + 3)
                }, linkToPhysicalSource: { _ in }
            )) {
                await state.searchGroupMentionMembers(groupID: "stage6-group", keyword: "")
            }
        }
        let reached = await XCTWaiter.fulfillment(of: [decoded], timeout: 2)
        state.applyGroupLifecycleEvent(event: "group_left", groupID: "stage6-group")
        resumeDecode.signal()
        let stale = await stalePage.value
        XCTAssertEqual(reached, .completed)
        XCTAssertTrue(stale.isEmpty)
        XCTAssertNil(state.group(id: "stage6-group"))
        XCTAssertEqual(state.myGroupNickname(groupID: "stage6-group"), "")
        XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), Array(repeating: "tenant.example.test", count: 6))
    }

    func testTenantListDecodeRequiresBothRouteAndResponseType() async throws {
        let suite = "tenant-list-match-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let friends = "/api/tenant/friends"
        let group = "/api/tenant/groups/a%2Fb/members?limit=30"
        let friendType = RemoteList<RemoteFriendRelation>.self
        let groupType = RemoteList<RemoteUserGroupMember>.self
        XCTAssertEqual(TypedListResponseRoute.matching(method: "GET", path: group, response: groupType), .groupMembers)
        for (method, path, type): (String, String, Any.Type) in [
            ("POST", friends, friendType), ("GET", friends, groupType), ("GET", group, friendType),
            ("GET", "/api/tenant/groups/a/b/members", groupType),
            ("GET", "/api/tenant/groups/a/members/extra", groupType),
            ("GET", "/api/tenant/groups//members", groupType),
        ] {
            XCTAssertEqual(TypedListResponseRoute.matching(method: method, path: path, response: type), .other)
        }
        let response = HTTPTransportResult(data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8),
            isHTTPResponse: true, statusCode: 200)
        let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec())
        let client = makeStage6ListClient(transport: FakeHTTPTransport(results: [response, response]), codec: codec,
            defaults: defaults, context: makeContext())
        let _: RemoteList<RemoteUserGroupMember> = try await client.request(base: client.tenantBase, path: friends)
        let _: RemoteList<RemoteFriendRelation> = try await client.request(base: client.tenantBase, path: group)
        XCTAssertEqual(codec.decodedOnMainThread(), Array(repeating: true, count: 6))
    }

    func testTenantListDecodeKeepsCoalescingFreshRemarksAndErrorClassification() async throws {
        let suite = "tenant-list-errors-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ok = HTTPTransportResult(data: Data(#"{"ok":true,"data":{"items":[{"friend_uid":"peer-1"}]}}"#.utf8),
            isHTTPResponse: true, statusCode: 200)
        let unauthorized = HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"unauthorized","message":"Expired"}}"#.utf8),
            isHTTPResponse: true, statusCode: 401)
        let locked = HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"account_locked","message":"Locked"}}"#.utf8),
            isHTTPResponse: true, statusCode: 423)
        let revoked = HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"device_revoked"}}"#.utf8),
            isHTTPResponse: true, statusCode: 403)
        let transport = FakeHTTPTransport(results: [ok, ok, unauthorized, locked, revoked], delayNanoseconds: 50_000_000)
        let context = makeContext()
        let client = makeStage6ListClient(transport: transport, codec: JSONWireCodec(), defaults: defaults, context: context)
        async let first = client.listFriends(context: context)
        async let second = client.listFriends(context: context)
        let (left, right) = try await (first, second)
        XCTAssertEqual(left.map(\.friendUID), ["peer-1"])
        XCTAssertEqual(right.map(\.friendUID), ["peer-1"])
        XCTAssertEqual(transport.requests().count, 1)

        let fresh = try await client.friendRelationsForRemarkResolution(context: context)
        XCTAssertEqual(fresh.map(\.friendUID), ["peer-1"])
        XCTAssertEqual(transport.requests().map(\.cachePolicy), [.useProtocolCachePolicy, .reloadIgnoringLocalCacheData])
        do {
            _ = try await client.listFriends(context: context)
            XCTFail("401 unexpectedly decoded as a successful list")
        } catch IMAPIError.unauthorized(let message) {
            XCTAssertEqual(message, "Expired")
        }
        do {
            _ = try await client.listGroupMembers(context: context, groupID: "stage6-group")
            XCTFail("423 unexpectedly decoded as a successful list")
        } catch IMAPIError.loginSecurity(let code, let message, _) {
            XCTAssertEqual(code, "account_locked")
            XCTAssertEqual(message, "账号已锁定，请联系商户后台管理员解锁")
        }

        let observer = NotificationCenter.default.addObserver(forName: .imCurrentDeviceRevoked, object: nil, queue: nil) { _ in
            XCTFail("A cancelled decode must not publish a revocation")
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let decoded = expectation(description: "Revocation decoded before cancellation")
        let resumeDecode = DispatchSemaphore(value: 0)
        let task = Task {
            try await SDKHTTPTrace.$current.withValue((
                sourceCorrelation: 2, delivery: { _, _, _ in }, decode: { _, _, onMain in
                    XCTAssertFalse(onMain)
                    decoded.fulfill()
                    _ = resumeDecode.wait(timeout: .now() + 3)
                }, linkToPhysicalSource: { _ in }
            )) {
                try await client.listGroupMembers(context: context, groupID: "stage6-group")
            }
        }
        let reached = await XCTWaiter.fulfillment(of: [decoded], timeout: 2)
        task.cancel()
        resumeDecode.signal()
        XCTAssertEqual(reached, .completed)
        do {
            _ = try await task.value
            XCTFail("A cancelled decode unexpectedly returned")
        } catch is CancellationError {}
    }

    private func makeStage6ListClient(transport: HTTPTransport, codec: any WireCodec,
        defaults: UserDefaults, context: IMAPIContext) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport, wireCodec: codec,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
            startupContext: context,
            runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
        )
    }
} // WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111_END

// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
extension HTTPTransportTests {
    func testGroupDirectoryPreferredProbeOutlivesRefreshAndChecksSessionBeforeSend() async throws {
        for retireSession in [false, true] {
            let clock = RuntimeRouteTestClock(nowMS: 100_000)
            let sleep = M9PreferredMembersProbePause()
            defer { sleep.close() }
            let store = isolatedRuntimeRouteStore()
            let response = HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[],"has_more":false}}"#.utf8),
                isHTTPResponse: true, statusCode: 200
            )
            let transport = FakeHTTPTransport(results: [response, response])
            let client = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://seed-tenant.example.test")!,
                imBase: URL(string: "https://seed-im.example.test")!,
                httpTransport: transport, runtimeRouteStore: store,
                runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false),
                runtimeMonotonicNowMS: { clock.now() }, runtimeSleep: { milliseconds in
                    try await sleep.wait()
                    clock.advance(by: milliseconds)
                }
            )
            let routes = runtimeRouteSnapshotForHTTPWiring()
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
            XCTAssertTrue(store.updateRecovery(.init(recovery: true), service: .tenantAPI, snapshot: routes))
            let refresh = AuthFlowGenerationState()
            let session = AuthFlowGenerationState()
            let refreshToken = refresh.issueToken()
            let sessionToken = session.issueToken()
            let owner = GroupDirectoryRequestOwner(
                ownsRefresh: { refresh.isCurrent(refreshToken) },
                ownsAuthority: { session.isCurrent(sessionToken) }
            )
            _ = try await GroupDirectoryRequestOwner.$current.withValue(owner) {
                try await client.listGroups(context: makeContext(), scope: "all")
            }
            try await waitForCondition { sleep.isWaiting }
            XCTAssertEqual(transport.requests().map { $0.url?.host }, ["tenant-backup.example.net"])
            refresh.invalidate()
            if retireSession { session.invalidate() }
            let before = store.record(appID: routes.appID, tenantID: routes.tenantID)
            try sleep.release()
            if retireSession {
                try await waitForCondition { !client.preferredHTTPProbeInFlightServices.contains(.tenantAPI) }
                XCTAssertEqual(transport.requests().map { $0.url?.host }, ["tenant-backup.example.net"])
                XCTAssertEqual(store.record(appID: routes.appID, tenantID: routes.tenantID), before)
            } else {
                try await waitForCondition { sleep.isWaiting || !client.preferredHTTPProbeInFlightServices.contains(.tenantAPI) }
                XCTAssertEqual(transport.requests().map { $0.url?.host },
                               ["tenant-backup.example.net", "tenant-primary.example.com"])
                XCTAssertNotEqual(store.record(appID: routes.appID, tenantID: routes.tenantID), before)
                sleep.close()
                try await waitForCondition { !client.preferredHTTPProbeInFlightServices.contains(.tenantAPI) }
            }
        }
    }
}
// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END

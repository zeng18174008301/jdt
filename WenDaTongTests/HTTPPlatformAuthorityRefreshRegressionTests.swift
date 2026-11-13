import Foundation
import Combine
import XCTest
@testable import WenDaTong

// WDT_IOS1_PLATFORM_OWNER_REFRESH_RETRY_20261111_BEGIN
extension HTTPTransportTests {
    func testForegroundPlatformRefreshCurrentDeviceRevokeClearsActiveTenantAndRememberedLogin() async throws {
        captureA43RuntimeLoadedImages()
        let f = try await platformAuthorityFixture(); defer { f.stop() }
        f.plan.arm(.device)
        let original = f.state.apiContext, scope = f.state.remoteDataScopeKey(for: original)
        let removals = f.cache.removeCount(scope: scope), clears = f.credentials.clearCount
        f.state.appDidEnterForeground()
        await fulfillment(of: [f.plan.refreshGate.entered], timeout: 1)
        XCTAssertTrue(f.state.apiContext.hasIMSession)
        XCTAssertEqual(f.state.apiContext.authSessionFence.authorityFamily, .tenant)
        f.plan.refreshGate.open()
        try await waitForCondition { !f.state.isAuthenticated }
        XCTAssertFalse(f.state.apiContext.hasIMSession)
        XCTAssertNil(f.state.apiContext.platformToken)
        XCTAssertFalse(IMAPIContext.load(sessionStore: f.protectedStore).hasIMSession)
        XCTAssertNil(IMAPIContext.load(sessionStore: f.protectedStore).platformToken)
        XCTAssertNotEqual(f.state.apiContext.deviceID, original.deviceID)
        XCTAssertGreaterThan(f.cache.removeCount(scope: scope), removals)
        XCTAssertGreaterThan(f.credentials.clearCount, clears)
        XCTAssertNil(f.state.rememberedLoginCredentialsForAuthUI())
        XCTAssertEqual(f.plan.paths().filter { $0 == "/api/platform/auth/session/refresh" }.count, 1)
    }
    func testForegroundPlatformDeviceRevokeAfterNewEpochPreservesCurrent() async throws {
        captureA43RuntimeLoadedImages(); try await assertLatePlatformDeviceRejection(.epoch)
    }
    func testForegroundPlatformDeviceRevokeAfterCredentialRevisionPreservesCurrent() async throws {
        captureA43RuntimeLoadedImages(); try await assertLatePlatformDeviceRejection(.revision)
    }
    func testForegroundPlatformDeviceRevokeAfterTenantOwnerReplacementPreservesCurrent() async throws {
        captureA43RuntimeLoadedImages(); try await assertLatePlatformDeviceRejection(.tenant)
    }
    private func assertLatePlatformDeviceRejection(_ replacement: PlatformP1Replacement) async throws {
        let f = try await platformAuthorityFixture(); defer { f.stop() }; f.plan.arm(.device)
        f.state.appDidEnterForeground()
        await fulfillment(of: [f.plan.refreshGate.entered], timeout: 1)
        let next = try replacePlatformP1Authority(f, replacement: replacement)
        let scope = f.state.remoteDataScopeKey(for: next), removals = f.cache.removeCount(scope: scope), clears = f.credentials.clearCount
        f.plan.refreshGate.open()
        try await waitForCondition { f.state.remoteSyncEngine.currentAuthSessionRefreshTask() == nil }
        XCTAssertTrue(f.state.isAuthenticated)
        XCTAssertTrue(f.state.apiContext.isSameAuthAuthority(as: next.authSessionFence))
        XCTAssertTrue(IMAPIContext.load(sessionStore: f.protectedStore).isSameAuthAuthority(as: next.authSessionFence))
        XCTAssertEqual(f.state.apiContext.deviceID, next.deviceID)
        XCTAssertEqual(f.cache.removeCount(scope: scope), removals)
        XCTAssertEqual(f.credentials.clearCount, clears)
        XCTAssertNotNil(f.state.rememberedLoginCredentialsForAuthUI())
    }
    func testTenantSwitch401PlatformRefreshSuccessRetriesActualEnterAndCommitsTenant() async throws {
        captureA43RuntimeLoadedImages()
        let f = try await platformAuthorityFixture(); defer { f.stop() }; f.plan.arm(.success)
        let original = f.state.apiContext, clears = f.credentials.clearCount
        let task = Task { try await f.state.switchPlatformTenant(tenantID: "tenant-1", allowLegacyFallback: false) }
        await fulfillment(of: [f.plan.refreshGate.entered], timeout: 1)
        XCTAssertEqual(f.plan.enterRequests().count, 1)
        f.plan.refreshGate.open(); try await task.value
        let enters = f.plan.enterRequests()
        XCTAssertEqual(enters.count, 2)
        XCTAssertEqual(enters.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + (original.platformToken ?? ""))
        XCTAssertEqual(enters.last?.value(forHTTPHeaderField: "Authorization"), "Bearer platform-authority-refreshed")
        XCTAssertEqual(f.plan.paths().filter { $0 == "/api/platform/auth/session/refresh" }.count, 1)
        XCTAssertEqual(f.plan.paths().filter { $0 == "/api/tenant/auth/platform-entry" }.count, 1)
        XCTAssertEqual(f.state.apiContext.platformToken, "platform-authority-refreshed")
        XCTAssertEqual(f.state.apiContext.imToken, "im-token-new")
        XCTAssertEqual(IMAPIContext.load(sessionStore: f.protectedStore).imToken, "im-token-new")
        XCTAssertEqual(f.state.apiContext.deviceID, original.deviceID)
        XCTAssertEqual(f.credentials.clearCount, clears)
    }
    func testTenantSwitchPlatformRefreshAfterNewEpochCannotRetryEnter() async throws {
        captureA43RuntimeLoadedImages(); try await assertLatePlatformSwitch(.epoch)
    }
    func testTenantSwitchPlatformRefreshAfterOtherCredentialAdvanceCannotRetryEnter() async throws {
        captureA43RuntimeLoadedImages(); try await assertLatePlatformSwitch(.revision)
    }
    private func assertLatePlatformSwitch(_ replacement: PlatformP1Replacement) async throws {
        let f = try await platformAuthorityFixture(); defer { f.stop() }; f.plan.arm(.success)
        let task = Task { () -> Error? in
            do { try await f.state.switchPlatformTenant(tenantID: "tenant-1", allowLegacyFallback: false); return nil }
            catch { return error }
        }
        await fulfillment(of: [f.plan.refreshGate.entered], timeout: 1)
        let next = try replacePlatformP1Authority(f, replacement: replacement), clears = f.credentials.clearCount
        f.plan.refreshGate.open(); let error = await task.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(f.plan.enterRequests().count, 1)
        XCTAssertFalse(f.plan.paths().contains("/api/tenant/auth/platform-entry"))
        XCTAssertTrue(f.state.apiContext.isSameAuthAuthority(as: next.authSessionFence))
        XCTAssertTrue(IMAPIContext.load(sessionStore: f.protectedStore).isSameAuthAuthority(as: next.authSessionFence))
        XCTAssertEqual(f.credentials.clearCount, clears)
    }
    func testTenantSwitchValidatedRefreshCannotContinueRetiredOriginalFlow() async throws {
        captureA43RuntimeLoadedImages()
        let f = try await platformAuthorityFixture(); defer { f.stop() }; f.plan.arm(.success)
        var current = true
        let task = Task { () -> Error? in
            do { try await f.state.switchPlatformTenant(tenantID: "tenant-1", allowLegacyFallback: false, isCurrent: { current }); return nil }
            catch { return error }
        }
        await fulfillment(of: [f.plan.refreshGate.entered], timeout: 1)
        current = false; f.plan.refreshGate.open(); let error = await task.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(f.state.apiContext.platformToken, "platform-authority-refreshed")
        XCTAssertEqual(f.plan.enterRequests().count, 1)
        XCTAssertFalse(f.plan.paths().contains("/api/tenant/auth/platform-entry"))
    }
    func testTenantSwitchPlatformDeviceRevokeKeepsDestructiveFailureGuard() async throws {
        captureA43RuntimeLoadedImages()
        let f = try await platformAuthorityFixture(); defer { f.stop() }; f.plan.arm(.device)
        let original = f.state.apiContext, clears = f.credentials.clearCount
        let task = Task { () -> Error? in
            do { try await f.state.switchPlatformTenant(tenantID: "tenant-1", allowLegacyFallback: false); return nil }
            catch { return error }
        }
        await fulfillment(of: [f.plan.refreshGate.entered], timeout: 1)
        f.plan.refreshGate.open(); let error = await task.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(f.state.apiContext.hasIMSession)
        XCTAssertNotEqual(f.state.apiContext.deviceID, original.deviceID)
        XCTAssertGreaterThan(f.credentials.clearCount, clears)
        XCTAssertEqual(f.plan.enterRequests().count, 1)
        XCTAssertFalse(f.plan.paths().contains("/api/tenant/auth/platform-entry"))
    }
    func testMatchingSharedPlatformRefreshReturnsSameValidatedInstalledAuthority() async throws {
        captureA43RuntimeLoadedImages()
        let f = try await platformAuthorityFixture(); defer { f.stop() }; f.plan.arm(.success)
        let original = f.state.apiContext
        let first = Task { await f.state.refreshPlatformAuthSessionAuthorityIfNeeded(reason: "shared-platform-test", silent: true, context: original, force: true) }
        await fulfillment(of: [f.plan.refreshGate.entered], timeout: 1)
        let second = Task { await f.state.refreshPlatformAuthSessionAuthorityIfNeeded(reason: "shared-platform-test", silent: true, context: original, force: true) }
        await Task.yield()
        f.plan.refreshGate.open(); let one = await first.value, two = await second.value
        XCTAssertNotNil(one); XCTAssertEqual(one, two)
        XCTAssertEqual(one, f.state.apiContext.authSessionFence)
        XCTAssertEqual(f.state.apiContext.credentialRevision, original.credentialRevision &+ 1)
        XCTAssertEqual(f.plan.paths().filter { $0 == "/api/platform/auth/session/refresh" }.count, 1)
    }
    private func replacePlatformP1Authority(_ f: PlatformAuthorityFixture, replacement: PlatformP1Replacement) throws -> IMAPIContext {
        var next = f.state.apiContext
        switch replacement {
        case .epoch: next.sessionEpoch = UUID().uuidString
        case .revision: next.credentialRevision &+= 1
        case .tenant:
            next.tenantID = "tenant-2"; next.imUID = "uid-2"; next.accountID = "account-2"
            next.tenantAuthSession = IMStoredAuthSession(sessionID: "platform-p1-replacement", refreshToken: "synthetic-replacement",
                tokenType: "im", tenantID: "tenant-2", accountID: "account-2", appID: next.appID, deviceID: next.deviceID, clientType: "ios")
        }
        XCTAssertTrue(next.save(sessionStore: f.protectedStore).isCommitted); f.state.apiContext = next
        if replacement != .revision { _ = f.state.authFlowGeneration.issueToken() }
        return next
    }
    private func platformAuthorityFixture() async throws -> PlatformAuthorityFixture {
        clearStoredAPIContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("platform-p1-\(UUID().uuidString)")
        var context = makeRefreshableMessageSendContext(deviceID: "platform-p1-\(UUID().uuidString)")
        context.platformAuthSession = IMStoredAuthSession(sessionID: "platform-authority-session", refreshToken: "synthetic-platform-refresh",
            tokenType: "platform", tenantID: "", accountID: context.accountID ?? "", appID: context.appID,
            deviceID: context.deviceID, clientType: "ios", authVersion: 4, sessionGeneration: 7, accessExpiresAt: 1_895_000_000)
        let protectedStore = InMemoryProtectedSessionStore(); XCTAssertTrue(context.save(sessionStore: protectedStore).isCommitted)
        let entered = try tenantEnterSuccess(entryTicket: "platform-p1-entry", routes: runtimeRouteSnapshotForHTTPWiring())
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: tenantPlatformEntrySuccess().data) as? [String: Any])
        var data = try XCTUnwrap(entry["data"] as? [String: Any]); data["device_id"] = context.deviceID
        var auth = try XCTUnwrap(data["auth_session"] as? [String: Any]); auth["device_id"] = context.deviceID; data["auth_session"] = auth; entry["data"] = data
        let plan = try PlatformAuthorityHTTPPlan(context: context, enter: entered.data, entry: JSONSerialization.data(withJSONObject: entry))
        let cache = PlatformAuthorityMessageStore(root: root.appendingPathComponent("cache"))
        let credentials = RecordingRememberedLoginCredentialStore(), preference = RecordingRememberedLoginPreferenceStore()
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [.string(realtimeEnvelopeString(type: "connect_ack"))])
        let realtime = RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: socket), quicConfiguration: .init(isEnabled: false),
            requestIDProvider: deterministicRealtimeRequestID, networkMonitorFactory: nil, continuity: IMRuntimeWebSocketContinuity())
        let state = AppState(api: makeClient(transport: plan, runtimeRouteStore: isolatedRuntimeRouteStore()), realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(), messageStore: cache,
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support")),
            rememberedLoginCredentialStore: credentials, rememberedLoginPreferenceStore: preference,
            protectedSessionStore: protectedStore, launchUnitTestOverride: false)
        XCTAssertTrue(state.isAuthenticated); XCTAssertNotNil(state.coldLaunchSessionRestoreTask)
        await state.coldLaunchSessionRestoreTask?.value
        state.appDidEnterBackground(); state.remoteSyncEngine.reset()
        var active = state.apiContext
        active.platformAuthSession = IMStoredAuthSession(sessionID: "platform-authority-session", refreshToken: "synthetic-platform-refresh",
            tokenType: "platform", tenantID: "", accountID: active.accountID ?? "", appID: active.appID,
            deviceID: active.deviceID, clientType: "ios", authVersion: 4, sessionGeneration: 7, accessExpiresAt: 1)
        XCTAssertTrue(active.save(sessionStore: protectedStore).isCommitted); state.apiContext = active
        let rememberedScope = RememberedLoginCredentialScope(context: active)
        XCTAssertTrue(credentials.save(RememberedLoginCredentials(mode: .account, identifier: "platform-p1-member", password: "synthetic-p1"), scope: rememberedScope))
        preference.set(true, scope: rememberedScope)
        XCTAssertTrue(active.hasIMSession); XCTAssertNotNil(state.rememberedLoginCredentialsForAuthUI())
        return PlatformAuthorityFixture(state: state, plan: plan, cache: cache, protectedStore: protectedStore, credentials: credentials)
    }
}
private enum PlatformP1Replacement { case epoch, revision, tenant }
@MainActor private struct PlatformAuthorityFixture {
    let state: AppState
    let plan: PlatformAuthorityHTTPPlan
    let cache: PlatformAuthorityMessageStore
    let protectedStore: InMemoryProtectedSessionStore
    let credentials: RecordingRememberedLoginCredentialStore
    func stop() { plan.refreshGate.open(); state.appDidEnterBackground(); state.stopInboxRefreshLoop(); state.stopRTCCallRefreshLoop(); state.remoteSyncEngine.reset() }
}
private final class PlatformAuthorityGate: @unchecked Sendable {
    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_BEGIN
    let entered: XCTestExpectation
    init(description: String = "actual platform refresh reaches transport") {
        entered = XCTestExpectation(description: description)
    }
    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_END
    private let lock = NSLock()
    private var released = false, didEnter = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let result = lock.withLock { () -> (Bool, Bool) in
                let first = !didEnter; didEnter = true
                if released { return (true, first) }
                continuations.append(continuation); return (false, first)
            }
            if result.1 { entered.fulfill() }; if result.0 { continuation.resume() }
        }
    }
    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in released = true; let result = continuations; continuations.removeAll(); return result }
        pending.forEach { $0.resume() }
    }
}
private final class PlatformAuthorityMessageStore: MessageStore, @unchecked Sendable {
    private let cache: SnapshotCache
    private let lock = NSLock()
    private var removed: [String: Int] = [:]
    init(root: URL) { cache = SnapshotCache(directoryURL: root) }
    var schemaVersion: Int { cache.schemaVersion }
    func scopeKey(for context: IMAPIContext) -> String { cache.scopeKey(for: context) }
    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? { await cache.load(scope: scope) }
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool { cache.write(snapshot, scope: scope) }
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool { await cache.writeNow(snapshot, scope: scope) }
    func remove(scope: String) { lock.withLock { removed[scope, default: 0] += 1 }; cache.remove(scope: scope) }
    func removeAll() { cache.removeAll() }
    func removeCount(scope: String) -> Int { lock.withLock { removed[scope, default: 0] } }
}
private final class PlatformAuthorityHTTPPlan: HTTPTransport, @unchecked Sendable {
    enum Mode { case idle, success, device }
    let refreshGate = PlatformAuthorityGate()
    private let lock = NSLock()
    private var mode: Mode = .idle
    private var requests: [URLRequest] = []
    private let platform: Data, tenant: Data, policy: Data, enter: Data, entry: Data
    func arm(_ mode: Mode) { lock.withLock { self.mode = mode; requests = [] } }
    func paths() -> [String] { lock.withLock { requests.compactMap { $0.url?.path } } }
    func enterRequests() -> [URLRequest] { lock.withLock { requests.filter { $0.url?.path.hasSuffix("/enter") == true } } }
    init(context: IMAPIContext, enter: Data, entry: Data) throws {
        self.enter = enter; self.entry = entry
        platform = try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["platform_token": "platform-authority-refreshed", "expires_at": 1_895_000_000,
            "auth_session": ["session_id": "platform-authority-session", "refresh_token": "synthetic-platform-next", "expires_at": 1_895_000_000,
                "token_type": "platform", "app_id": context.appID, "device_id": context.deviceID, "client_type": "ios", "auth_version": 5, "session_generation": 8]]])
        tenant = try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["im_token": "cold-restored-im", "expires_at": 1_895_000_000,
            "tenant": ["tenant_id": "tenant-1", "name": "Platform Fixture", "status": "active"],
            "member": ["tenant_id": "tenant-1", "account_id": "account-1", "im_uid": "uid-1", "status": "active", "role": "member"],
            "auth_session": ["session_id": "sess_platform-tenant-1", "refresh_token": "synthetic-tenant", "expires_at": 1_895_000_000,
                "tenant_id": "tenant-1", "app_id": context.appID, "device_id": context.deviceID, "client_type": "ios", "token_type": "im"]]])
        policy = try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["app_id": context.appID, "status": "active", "allow_workspace_switch": true, "allow_default_tenant_join": false, "cache_ttl_seconds": 600]])
    }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        let (current, enters) = lock.withLock { () -> (Mode, Int) in requests.append(request); return (mode, requests.filter { $0.url?.path.hasSuffix("/enter") == true }.count) }
        func response(_ data: Data, _ status: Int = 200) -> HTTPTransportResult { .init(data: data, isHTTPResponse: true, statusCode: status, responseURL: request.url) }
        if path == "/api/platform/auth/session/refresh" {
            if current != .idle { await refreshGate.wait() }
            if current == .device { return response(Data(#"{"ok":false,"error":{"code":"device_disabled","message":"synthetic current device rejection"}}"#.utf8), 403) }
            return response(platform)
        }
        if path.hasSuffix("/enter") {
            if current != .idle, enters == 1 { return response(Data(#"{"ok":false,"error":{"code":"invalid_token","message":"synthetic expired platform access"}}"#.utf8), 401) }
            return response(enter)
        }
        if path == "/api/tenant/auth/platform-entry" { return response(entry) }
        if path.hasSuffix("/session/refresh") || path == "/api/tenant/auth/refresh" { return response(tenant) }
        if path == "/api/platform/apps/current-policy" { return response(policy) }
        // Valid policy input prevents unrelated foreground privacy scrubbing from changing the cache deletion counter.
        return response(Data(#"{"ok":true,"data":{"items":[],"conversations":[],"has_more":false,"tenant_policy":{"show_group_member_count":true,"tenant_policy_generation":1,"contract_version":1,"authoritative":true},"client_policy":{"show_group_member_count":true,"tenant_policy_generation":1,"contract_version":1,"authoritative":true}}}"#.utf8))
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult { throw URLError(.unsupportedURL) }
}
// WDT_IOS1_PLATFORM_OWNER_REFRESH_RETRY_20261111_END

// WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_BEGIN
extension HTTPTransportTests {
    func testContactRemarkRequestOwnershipAcrossScopeAndCredentialChanges() async throws {
        // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
        enum Scenario: CaseIterable {
            case aba, epochDuringPatch, renewedFallback, renewedPatchSecurity, renewedReadbackSecurity, ordinaryPatch, cancelled
        }
        for scenario in Scenario.allCases {
            let holdsPatch = [.epochDuringPatch, .renewedPatchSecurity, .ordinaryPatch].contains(scenario)
            let holdsReadback = scenario == .renewedReadbackSecurity
            let held: ContactRequestOwnershipTransport.Step = holdsPatch ? .patch : holdsReadback ? .profile : .friends
            let reply: ContactRequestOwnershipTransport.Reply = scenario == .ordinaryPatch ? .ordinary
                : holdsPatch || holdsReadback ? .security : .normal
            let transport = ContactRequestOwnershipTransport(held: held, reply: reply)
            defer { transport.gate.open() }
            let state = try contactOwnershipState(transport)
            let initial = state.apiContext
            // WDT_IOS1_CONTACT_REMARK_FIXTURE_ADMISSION_20261112
            // The XCTest startup skips session restore, which binds the contact read fence.
            let initialScope = state.remoteDataScopeKey(for: initial)
            state.profileContactRevisionFence.rebind(scopeHash: initialScope)
            XCTAssertTrue(state.contacts.isEmpty)
            XCTAssertTrue(state.contactRemarks.isEmpty)
            let peer = makeUser(id: "uid-2", name: "Peer")
            var completion: FriendRemarkSaveResult?
            let task = try XCTUnwrap(state.setContactRemark("New Remark", for: peer) { completion = $0 })
            await fulfillment(of: [transport.gate.entered], timeout: 3)
            if holdsPatch || holdsReadback {
                XCTAssertEqual(state.contactRemarks[peer.id], "New Remark", "\(scenario)")
                XCTAssertEqual(state.contacts.first?.name, "New Remark", "\(scenario)")
                XCTAssertEqual(state.contactCardOriginalName(matching: [peer.id]), "Peer", "\(scenario)")
            }
            switch scenario {
            case .aba, .epochDuringPatch, .cancelled:
                if scenario == .cancelled { task.cancel() }
                else { replaceContactRequestContext(state, aba: scenario == .aba) }
                state.contacts = [makeUser(id: peer.id, name: "Current Contact")]
                state.contactRemarks = [peer.id: "Current Remark"]
            case .renewedFallback, .renewedPatchSecurity, .renewedReadbackSecurity:
                renewContactRequestContext(state)
            case .ordinaryPatch:
                break
            }
            let currentAuthority = state.apiContext.authSessionFence
            let scope = state.remoteDataScopeKey(for: state.apiContext)
            let beforeRead = state.profileContactRevisionFence.beginRead(scopeHash: scope)
            let writes = LockedInteger()
            let contactWrites = state.contactStore.$contacts.dropFirst().sink { _ in _ = writes.incrementAndGetPrevious() }
            let remarkWrites = state.contactStore.$remarks.dropFirst().sink { _ in _ = writes.incrementAndGetPrevious() }
            transport.gate.open()
            await task.value
            contactWrites.cancel()
            remarkWrites.cancel()
            let calls = await transport.calls
            XCTAssertTrue(state.apiContext.isSameAuthAuthority(as: currentAuthority))
            XCTAssertTrue(state.isAuthenticated)
            switch scenario {
            case .aba, .epochDuringPatch, .cancelled:
                XCTAssertNil(completion, "\(scenario)")
                XCTAssertEqual(state.contacts.first?.name, "Current Contact", "\(scenario)")
                XCTAssertEqual(state.contactRemarks[peer.id], "Current Remark", "\(scenario)")
                XCTAssertEqual(calls.map(\.step), holdsPatch ? [.friends, .patch] : [.friends], "\(scenario)")
            case .renewedFallback:
                XCTAssertEqual(completion, .success)
                XCTAssertEqual(state.contactRemarks[peer.id], "New Remark")
                XCTAssertEqual(state.contacts.first?.name, "New Remark")
                XCTAssertEqual(calls.map(\.step), [.friends, .patch, .profile, .applications, .blacklist, .friends])
                XCTAssertEqual(calls.first?.authorization, "Bearer \(initial.imToken ?? "")")
                XCTAssertTrue(calls.dropFirst().allSatisfy { $0.authorization == "Bearer contact-renewed" })
            case .renewedPatchSecurity, .renewedReadbackSecurity:
                XCTAssertNil(completion)
                XCTAssertEqual(writes.value(), 0, "Retired credential errors cannot publish a rollback")
                XCTAssertEqual(state.profileContactRevisionFence.beginRead(scopeHash: scope), beforeRead)
                XCTAssertEqual(state.contactRemarks[peer.id], "New Remark")
                XCTAssertEqual(state.contacts.first?.name, "New Remark")
                XCTAssertEqual(calls.map(\.step), holdsReadback ? [.friends, .patch, .profile] : [.friends, .patch])
                XCTAssertEqual(calls.last?.authorization, "Bearer \(initial.imToken ?? "")")
            case .ordinaryPatch:
                if case .failure? = completion {} else { XCTFail("Current ordinary error should complete with a rollback") }
                XCTAssertGreaterThan(writes.value(), 0)
                XCTAssertEqual(state.contactRemarks[peer.id], "Old Remark")
                XCTAssertEqual(state.contacts.first?.name, "Old Remark")
                XCTAssertEqual(calls.map(\.step), [.friends, .patch])
            }
        }
        // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END
    }

    func testFriendApplicationRequestOwnershipStopsRetiredRefreshAndKeepsRenewal() async throws {
        enum Scenario: CaseIterable {
            case lateReject, lateAcceptSecurity, lateApplications, renewedAccept, renewedAcceptSecurity, ordinaryPostFailure
            case retiredAcceptDevice, cancelledRejectDevice // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
        }
        for scenario in Scenario.allCases {
            let step: ContactRequestOwnershipTransport.Step
            switch scenario {
            case .lateReject, .cancelledRejectDevice: step = .reject
            case .lateApplications: step = .applications
            default: step = .accept
            }
            let reply: ContactRequestOwnershipTransport.Reply
            switch scenario {
            case .lateAcceptSecurity, .renewedAcceptSecurity: reply = .security
            case .retiredAcceptDevice, .cancelledRejectDevice: reply = .device
            case .ordinaryPostFailure: reply = .ordinary
            default: reply = .normal
            }
            let transport = ContactRequestOwnershipTransport(held: step, reply: reply,
                failBlacklist: scenario == .renewedAccept)
            defer { transport.gate.open() }
            let state = try contactOwnershipState(transport)
            let request = FriendRequest(id: "request-1", name: "Pending", source: "", message: "", accepted: false)
            state.friendRequests = [request]
            state.contacts = [makeUser(id: "uid-2", name: "Current Contact")]
            state.contactRemarks = ["uid-2": "Current Remark"]
            state.blacklist = [BlacklistItem(id: "kept-block", name: "Current Block", reason: "fixture")]
            // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
            let startingFence = state.apiContext.authSessionFence
            let notices = LockedInteger()
            let observer = NotificationCenter.default.addObserver(forName: .imCurrentDeviceRevoked, object: nil, queue: nil) {
                guard $0.object as? IMAuthSessionFence == startingFence else { return }
                _ = notices.incrementAndGetPrevious()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let task = try XCTUnwrap(step == .reject ? state.rejectFriendRequest(request.id) : state.acceptFriendRequest(request.id))
            // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END
            await fulfillment(of: [transport.gate.entered], timeout: 3)
            switch scenario {
            case .lateReject, .lateApplications, .lateAcceptSecurity, .retiredAcceptDevice:
                replaceContactRequestContext(state, aba: scenario != .lateAcceptSecurity)
                state.friendRequests = [request]
                state.contacts = [makeUser(id: "uid-2", name: "Current Contact")]
                state.contactRemarks = ["uid-2": "Current Remark"]
                state.blacklist = [BlacklistItem(id: "kept-block", name: "Current Block", reason: "fixture")]
            case .renewedAccept, .renewedAcceptSecurity:
                renewContactRequestContext(state)
            case .cancelledRejectDevice:
                task.cancel()
            case .ordinaryPostFailure:
                break
            }
            let authority = state.apiContext.authSessionFence
            transport.gate.open()
            await task.value
            let calls = await transport.calls
            XCTAssertTrue(state.apiContext.isSameAuthAuthority(as: authority))
            XCTAssertTrue(state.isAuthenticated)
            XCTAssertEqual(notices.value(), 0) // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
            switch scenario {
            case .lateReject, .lateAcceptSecurity, .lateApplications, .renewedAcceptSecurity, .retiredAcceptDevice, .cancelledRejectDevice:
                let expected: [ContactRequestOwnershipTransport.Step] = scenario == .lateApplications
                    ? [.accept, .applications] : [step]
                XCTAssertEqual(calls.map(\.step), expected, "\(scenario)")
                XCTAssertEqual(state.friendRequests, [request], "\(scenario)")
                XCTAssertEqual(state.blacklist.map(\.id), ["kept-block"], "\(scenario)")
                XCTAssertEqual(state.contactRemarks["uid-2"], "Current Remark", "\(scenario)")
                XCTAssertEqual(state.contacts.first?.name, "Current Contact", "\(scenario)")
            case .renewedAccept, .ordinaryPostFailure:
                XCTAssertEqual(calls.map(\.step), [.accept, .applications, .blacklist, .friends], "\(scenario)")
                XCTAssertTrue(state.friendRequests.isEmpty)
                XCTAssertEqual(state.contactRemarks["uid-2"], "Old Remark")
                XCTAssertEqual(state.contacts.first?.name, "Old Remark")
                if scenario == .renewedAccept {
                    XCTAssertTrue(calls.dropFirst().allSatisfy { $0.authorization == "Bearer contact-renewed" })
                    XCTAssertEqual(state.blacklist.map(\.id), ["kept-block"])
                } else {
                    XCTAssertTrue(state.blacklist.isEmpty)
                }
            }
        }
    }

    // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
    func testContactRemarkActualRouteRetryRechecksOwnerAfterPolicyAndDelay() async throws {
        enum Scenario: CaseIterable {
            case currentRetry, unownedRetry, retiredDuringDelay, renewedDuringDelay, retiredDuringBackupPolicy, cancelledDuringPrimaryPolicy
        }
        for scenario in Scenario.allCases {
            let routeDelay = PlatformAuthorityGate(description: "friends route waits before backup")
            let policyGate = PlatformAuthorityGate(description: "friends request awaits policy")
            let clock = RuntimeRouteTestClock(nowMS: 100_000)
            let transport = ContactRequestOwnershipTransport(held: .friends, reply: .network)
            transport.gate.open()
            let context = makeContext()
            let client = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://seed-tenant.example.test")!,
                imBase: URL(string: "https://seed-im.example.test")!,
                httpTransport: transport, runtimeRouteStore: isolatedRuntimeRouteStore(), startupContext: context,
                runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false),
                runtimeMonotonicNowMS: { clock.now() }, runtimeSleep: { duration in
                    if scenario == .retiredDuringDelay || scenario == .renewedDuringDelay { await routeDelay.wait() }
                    clock.advance(by: duration)
                })
            let state = try contactOwnershipState(transport, client: client, context: context)
            let routes = runtimeRouteSnapshotForHTTPWiring()
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
            let originalGate = client.forcedAuthRequestGate
            client.forcedAuthRequestGate = { request in
                try await originalGate?(request)
                guard request.path == "/api/tenant/friends" else { return }
                if (scenario == .retiredDuringBackupPolicy && request.base.host == "tenant-backup.example.net")
                    || (scenario == .cancelledDuringPrimaryPolicy && request.base.host == "tenant-primary.example.com") {
                    await policyGate.wait()
                }
            }
            defer {
                routeDelay.open()
                policyGate.open()
                client.forcedAuthRequestGate = originalGate
            }
            if scenario == .unownedRetry {
                let relations = try await client.friendRelationsForRemarkResolution(context: context)
                XCTAssertEqual(relations.map(\.friendUID), ["uid-2"])
                let calls = await transport.calls
                XCTAssertEqual(calls.map(\.host), ["tenant-primary.example.com", "tenant-backup.example.net"])
                continue
            }
            let peer = makeUser(id: "uid-2", name: "Current Contact")
            state.contacts = [peer]
            state.contactRemarks = [peer.id: "Current Remark"]
            var completion: FriendRemarkSaveResult?
            let task = try XCTUnwrap(state.setContactRemark("New Remark", for: peer) { completion = $0 })
            switch scenario {
            case .currentRetry, .unownedRetry: break
            case .retiredDuringDelay:
                await fulfillment(of: [routeDelay.entered], timeout: 3)
                replaceContactRequestContext(state, aba: true)
            case .renewedDuringDelay:
                await fulfillment(of: [routeDelay.entered], timeout: 3)
                renewContactRequestContext(state)
            case .retiredDuringBackupPolicy:
                await fulfillment(of: [policyGate.entered], timeout: 3)
                replaceContactRequestContext(state, aba: true)
            case .cancelledDuringPrimaryPolicy:
                await fulfillment(of: [policyGate.entered], timeout: 3)
                task.cancel()
            }
            routeDelay.open()
            policyGate.open()
            await task.value
            let calls = await transport.calls
            if scenario == .currentRetry {
                XCTAssertEqual(Array(calls.prefix(2)).map(\.host), ["tenant-primary.example.com", "tenant-backup.example.net"])
                XCTAssertEqual(calls.map(\.step), [.friends, .friends, .patch, .profile, .applications, .blacklist, .friends])
                XCTAssertEqual(completion, .success)
                XCTAssertEqual(state.contactRemarks[peer.id], "New Remark")
            } else {
                let expectedHosts = scenario == .cancelledDuringPrimaryPolicy ? [] : ["tenant-primary.example.com"]
                XCTAssertEqual(calls.map(\.host), expectedHosts, "\(scenario)")
                XCTAssertNil(completion)
                XCTAssertEqual(state.contactRemarks[peer.id], "Current Remark")
            }
        }
    }
    // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END

    // WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112_BEGIN
    func testContactRequestOwnsTheProductionPolicyGateVerificationAndPrompt() async throws {
        enum Scenario: CaseIterable {
            case latePolicy, lateDeviceABA, cancelledDevice, renewedDevice, lateVerificationSuccess, current, unowned
        }
        for scenario in Scenario.allCases {
            let held: ContactRequestOwnershipTransport.Step = scenario == .latePolicy ? .policy : .verification
            let revoke = [.lateDeviceABA, .cancelledDevice, .renewedDevice].contains(scenario)
            let transport = ContactRequestOwnershipTransport(held: held, reply: revoke ? .device : .normal)
            defer { transport.gate.open() }
            let state = try contactOwnershipState(transport)
            let client = try XCTUnwrap(state.api as? IMAPIClient)
            let context = state.apiContext
            state.setCurrentUser(makeUser(id: "uid-1", name: "Current User"))
            state.verificationRequirementAuthorityScopeKey = ""
            let requiringPolicy = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(
                #"{"app_id":"jianhuitong-ios","status":"active","require_phone_verification":true,"cache_ttl_seconds":60}"#.utf8
            ))
            if scenario == .latePolicy {
                state.currentAppPolicyExpiresAt = nil
            } else {
                state.appPolicyPresentationStore.installResolvedPolicy(requiringPolicy)
            }
            let notices = LockedInteger()
            let observer = NotificationCenter.default.addObserver(forName: .imCurrentDeviceRevoked, object: nil, queue: nil) {
                guard $0.object as? IMAuthSessionFence == context.authSessionFence else { return }
                _ = notices.incrementAndGetPrevious()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let owner = state.contactRequestOwner(context: context)
            let expectsPrompt = scenario == .current || scenario == .unowned
            let task = Task {
                do {
                    if scenario == .unowned {
                        _ = try await client.friendRelationsForRemarkResolution(context: context)
                    } else {
                        _ = try await state.withContactHTTPRequest(owner: owner, context: context) {
                            try await client.friendRelationsForRemarkResolution(context: context)
                        }
                    }
                    XCTFail("The real gate should stop the outer request")
                } catch IMAPIError.forcedAuthRequired(let requirement) {
                    XCTAssertTrue(expectsPrompt, "\(scenario)")
                    XCTAssertEqual(requirement, .phone)
                } catch is CancellationError {
                    XCTAssertFalse(expectsPrompt, "\(scenario)")
                } catch {
                    XCTFail("Unexpected policy gate error: \(error)")
                }
            }
            await fulfillment(of: [transport.gate.entered], timeout: 3)
            switch scenario {
            case .latePolicy, .lateDeviceABA, .lateVerificationSuccess:
                replaceContactRequestContext(state, aba: true)
            case .cancelledDevice: task.cancel()
            case .renewedDevice: renewContactRequestContext(state)
            case .current, .unowned: break
            }
            let authority = state.apiContext.authSessionFence
            let phone = state.currentUser.phone
            let verificationScope = state.verificationRequirementAuthorityScopeKey
            let policy = state.appPolicyPresentationStore.snapshot
            transport.gate.open()
            await task.value
            let calls = await transport.calls
            XCTAssertEqual(calls.map(\.step), [held], "\(scenario)")
            XCTAssertEqual(notices.value(), 0, "\(scenario)")
            XCTAssertTrue(state.isAuthenticated)
            XCTAssertEqual(state.apiContext.authSessionFence, authority)
            XCTAssertEqual(state.forcedAppPolicyAuthPrompt, expectsPrompt ? .phone : nil, "\(scenario)")
            if expectsPrompt {
                XCTAssertEqual(state.verificationRequirementAuthorityScopeKey, state.remoteDataScopeKey(for: context))
            } else {
                XCTAssertEqual(state.currentUser.phone, phone, "\(scenario)")
                XCTAssertEqual(state.verificationRequirementAuthorityScopeKey, verificationScope, "\(scenario)")
                XCTAssertEqual(state.appPolicyPresentationStore.snapshot, policy, "\(scenario)")
            }
        }
    }
    // WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112_END

    private func contactOwnershipState(_ transport: ContactRequestOwnershipTransport,
        client: IMAPIClient? = nil, context overrideContext: IMAPIContext? = nil) throws -> AppState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contact-owner-\(UUID().uuidString)")
        var context = overrideContext ?? makeContext()
        if overrideContext == nil { context.deviceID = "contact-owner-\(UUID().uuidString)" }
        let api = client ?? makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
        let state = AppState(api: api,
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context)
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let policy = try XCTUnwrap(JSONDecoder().decode(APIEnvelope<RemoteAppCurrentPolicy>.self,
            from: activeAppPolicyResult().data).data)
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        return state
    }

    private func replaceContactRequestContext(_ state: AppState, aba: Bool) {
        let original = state.apiContext
        let generation = state.localMessageSessionGeneration
        var next = original
        if aba {
            next.tenantID = "other-tenant"
            state.overrideAPIContextForTesting(next)
            state.overrideAPIContextForTesting(original)
            XCTAssertNotEqual(state.localMessageSessionGeneration, generation)
            XCTAssertEqual(state.apiContext.authSessionFence, original.authSessionFence)
        } else {
            next.sessionEpoch = UUID().uuidString
            state.sessionReauthenticationCommit = (original.authSessionFence, next.authSessionFence)
            state.overrideAPIContextForTesting(next)
            state.sessionReauthenticationCommit = nil
            XCTAssertEqual(state.localMessageSessionGeneration, generation)
            XCTAssertNotEqual(state.apiContext.authSessionFence, original.authSessionFence)
        }
    }

    private func renewContactRequestContext(_ state: AppState) {
        let original = state.apiContext
        var renewed = original
        renewed.credentialRevision &+= 1
        renewed.imToken = "contact-renewed"
        XCTAssertTrue(renewed.credentialsAdvanced(since: original.authSessionFence))
        state.overrideAPIContextForTesting(renewed)
    }
}

private actor ContactRequestOwnershipTransport: HTTPTransport {
    enum Step: Sendable {
        case friends, patch, profile, applications, blacklist, accept, reject, policy, verification
    }
    // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
    enum Reply: Sendable { case normal, security, device, ordinary, network }
    struct Call: Sendable { let step: Step; let authorization: String?; let host: String? }
    // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END

    nonisolated let gate = PlatformAuthorityGate(description: "contact request reaches transport")
    private(set) var calls: [Call] = []
    private let held: Step
    private let reply: Reply
    private let failBlacklist: Bool
    private var openedRequest = false
    private var saved = false

    init(held: Step, reply: Reply, failBlacklist: Bool = false) {
        self.held = held
        self.reply = reply
        self.failBlacklist = failBlacklist
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let step: Step
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/platform/apps/current-policy"): step = .policy
        case ("GET", "/api/tenant/me/verification-status"): step = .verification
        case ("GET", "/api/tenant/friends"): step = .friends
        case ("PATCH", "/api/tenant/friends/uid-2"): step = .patch
        case ("GET", "/api/tenant/friends/uid-2"): step = .profile
        case ("GET", "/api/tenant/friends/applications"): step = .applications
        case ("GET", "/api/tenant/blacklist"): step = .blacklist
        case ("POST", "/api/tenant/friends/applications/request-1/accept"): step = .accept
        case ("POST", "/api/tenant/friends/applications/request-1/reject"): step = .reject
        default: throw URLError(.unsupportedURL)
        }
        calls.append(Call(step: step, authorization: request.value(forHTTPHeaderField: "Authorization"), host: request.url?.host))
        func response(_ body: String, _ status: Int = 200) -> HTTPTransportResult {
            HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true, statusCode: status, responseURL: request.url)
        }
        if step == held, !openedRequest {
            openedRequest = true
            await gate.wait()
            switch reply {
            case .normal: break
            case .security: return response(#"{"ok":false,"error":{"code":"security_blocked","scope":"global"}}"#, 403)
            case .device: return response(#"{"ok":false,"error":{"code":"device_revoked"}}"#, 403)
            case .network: throw URLError(.timedOut)
            case .ordinary: return response(#"{"ok":false,"error":{"code":"temporary_failure","message":"fixture failure"}}"#, 422)
            }
        }
        switch step {
        case .friends:
            let remark = saved ? "New Remark" : "Old Remark"
            return response(#"{"ok":true,"data":{"items":[{"friend_uid":"uid-2","friend_user_id":"uid-2","raw_nickname":"Peer","remark":"\#(remark)"}]}}"#)
        case .patch, .profile:
            saved = true
            return response(#"{"ok":true,"data":{"im_uid":"uid-2","user_id":"uid-2","raw_nickname":"Peer","remark":"New Remark"}}"#)
        case .blacklist where failBlacklist:
            return response(#"{"ok":false,"error":{"code":"temporary_failure","message":"fixture failure"}}"#, 422)
        case .applications, .blacklist:
            return response(#"{"ok":true,"data":{"items":[]}}"#)
        case .accept, .reject:
            return response(#"{"ok":true,"data":{}}"#)
        case .policy:
            return response(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","require_phone_verification":true,"cache_ttl_seconds":60}}"#)
        case .verification:
            return response(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","account_id":"account-1","phone_masked":"138****1002","phone_bound":false,"phone_verified":false}}"#)
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_END

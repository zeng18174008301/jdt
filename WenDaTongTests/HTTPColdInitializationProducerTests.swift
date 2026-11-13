// WDT_IOS1_COLD_RESTORE_PRODUCER_CASES_20261111_BEGIN
import Foundation
import Combine
import XCTest
@testable import WenDaTong

extension HTTPTransportTests {
    func testColdInitProducerRestoreFinishesBeforeInitialActiveAdmitsExactlyOnce() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        f.state.appInitialSceneDidBecomeAvailable(isActive: false)
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        XCTAssertFalse(f.realtime.canReconnect?() ?? true)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertTrue(f.state.apiContext.hasIMSession)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 1)
        XCTAssertTrue(f.realtime.canReconnect?() ?? false)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 1)
        f.state.appDidEnterBackground()
        XCTAssertEqual(f.sockets.requestedURLs().count, 1)
        XCTAssertEqual(f.socket.cancelCount(), 1)
        XCTAssertFalse(f.realtime.canReconnect?() ?? true)
    }

    func testColdInitProducerInitialActiveBeforeRestoreWaitsForAuthDecision() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertEqual(f.sockets.requestedURLs().count, 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 1)
    }

    func testColdInitProducerInactiveRestoreNeverStartsSocket() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        f.state.appInitialSceneDidBecomeAvailable(isActive: false)
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.cacheGate.open(); f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        f.state.appInitialSceneDidBecomeAvailable(isActive: false)
        XCTAssertTrue(f.state.apiContext.hasIMSession)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
    }

    func testColdInitProducerBackgroundRetiresPendingInitialAdmission() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.state.appDidEnterBackground()
        f.cacheGate.open(); f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
    }

    func testColdInitProducerCancelledActualRestoreTaskCannotAdmit() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        let task = try XCTUnwrap(f.state.coldLaunchSessionRestoreTask)
        task.cancel()
        f.cacheGate.open(); f.http.authGate.open()
        await task.value
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
    }

    func testColdInitProducerRetiredTenantCannotAdmit() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.state.apiContext.tenantID = "retired-cold-tenant"
        f.cacheGate.open(); f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
    }

    func testColdInitProducerRetiredSameIdentityAuthEpochCannotAdmit() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.state.apiContext.sessionEpoch = UUID().uuidString
        f.cacheGate.open(); f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
    }

    func testColdInitProducerExplicitSessionRevocationCannotAdmit() async throws {
        let f = try coldInitFixture(outcome: .revoked)
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertFalse(f.state.apiContext.hasIMSession)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
    }

    func testColdInitProducerNonterminalRefreshFailureKeepsValidRestoredSession() async throws {
        let f = try coldInitFixture(outcome: .unavailable)
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.cacheGate.open(); f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertTrue(f.state.apiContext.hasIMSession)
        XCTAssertEqual(f.sockets.requestedURLs().count, 1)
    }

    func testColdInitProducerInitialAndForegroundProducersCoalesceOneAdmission() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.state.appDidEnterForeground()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        f.cacheGate.open()
        await Task.yield()
        f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertEqual(f.sockets.requestedURLs().count, 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 1)
    }

    func testColdInitProducerBackgroundDuringAuthCannotLeavePendingAdmission() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        f.state.appDidEnterBackground()
        f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        XCTAssertNil(f.state.pendingColdLaunchRealtimeAdmission)
    }

    func testColdInitProducerCancellationDuringAuthCannotAdmit() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        let task = try XCTUnwrap(f.state.coldLaunchSessionRestoreTask)
        task.cancel()
        f.http.authGate.open()
        await task.value
        XCTAssertTrue(f.state.apiContext.hasIMSession)
        XCTAssertEqual(f.state.apiContext.imToken, "cold-restored-im")
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
    }

    func testColdInitProducerAuthEpochRetiredDuringRefreshCannotAdmit() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        f.state.apiContext.sessionEpoch = UUID().uuidString
        let replacementEpoch = f.state.apiContext.sessionEpoch
        f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.state.apiContext.sessionEpoch, replacementEpoch)
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
    }

    func testColdInitProducerPendingAdmissionUsesLatestSameAuthorityCredential() async throws {
        let f = try coldInitFixture()
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.cacheGate.open(); f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertEqual(f.sockets.requestedURLs().count, 0)
        let epoch = f.state.apiContext.sessionEpoch
        f.state.apiContext.imToken = "cold-latest-same-authority"
        f.state.apiContext.credentialRevision += 1
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.state.apiContext.sessionEpoch, epoch)
        XCTAssertEqual(f.sockets.requestedRequests().count, 1)
        XCTAssertEqual(f.sockets.requestedRequests().first?.token, "cold-latest-same-authority")
        f.state.appInitialSceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(f.sockets.requestedRequests().count, 1)
    }


    // WDT_IOS1_LATE_AUTH_REFRESH_AUTHORITY_CASES_20261111_BEGIN
    func testLateFallbackNewAuthEpochCannotClearCurrentSession() async throws {
        captureA43RuntimeLoadedImages()
        try await lateFailureMustPreserveReplacement(outcome: .fallback(code: "refresh_token_reused", status: 401), replacement: .newEpoch)
    }
    func testLateFallbackTenantSwitchCannotClearCurrentSession() async throws {
        captureA43RuntimeLoadedImages()
        try await lateFailureMustPreserveReplacement(outcome: .fallback(code: "device_disabled", status: 403), replacement: .tenantSwitch)
    }
    func testLateFallbackTenantRevocationCannotClearNewEpoch() async throws {
        captureA43RuntimeLoadedImages()
        try await lateFailureMustPreserveReplacement(outcome: .fallback(code: "tenant_member_disabled", status: 403), replacement: .newEpoch)
    }
    func testLateFallbackSameSessionRevisionAdvanceCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        try await lateFailureMustPreserveReplacement(outcome: .fallback(code: "refresh_token_reused", status: 401), replacement: .sameSessionAdvance)
    }
    func testCurrentFallbackGlobalRevocationStillClearsSession() async throws {
        captureA43RuntimeLoadedImages()
        let f = try coldInitFixture(outcome: .fallback(code: "refresh_token_reused", status: 401))
        defer { f.stop() }
        try await enterLateFailureSecondary(f)
        f.http.secondaryGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertFalse(f.state.isAuthenticated)
        XCTAssertFalse(f.state.apiContext.hasIMSession)
        XCTAssertFalse(IMAPIContext.load(sessionStore: f.protectedStore).hasIMSession)
    }
    func testCancelledColdWaiterDoesNotCancelCurrentSharedRevocation() async throws {
        captureA43RuntimeLoadedImages()
        let f = try coldInitFixture(outcome: .fallback(code: "refresh_token_reused", status: 401))
        defer { f.stop() }
        try await enterLateFailureSecondary(f)
        let original = f.originalContext
        let scope = f.state.remoteDataScopeKey(for: original)
        XCTAssertNotNil(f.state.remoteSyncEngine.currentAuthSessionRefreshTask(for: original.authSessionFence))
        let follower = Task { await f.state.refreshStoredAuthSessionIfNeeded(reason: "coalesced_cold", silent: true, context: original, scope: scope) }
        await Task.yield()
        let cold = try XCTUnwrap(f.state.coldLaunchSessionRestoreTask)
        cold.cancel()
        f.http.secondaryGate.open()
        await cold.value
        let followerResult = await follower.value
        XCTAssertFalse(followerResult)
        XCTAssertFalse(f.state.isAuthenticated)
        XCTAssertFalse(IMAPIContext.load(sessionStore: f.protectedStore).hasIMSession)
        XCTAssertEqual(f.http.paths().filter { $0 == "/api/platform/tenants/tenant-1/session/refresh" }.count, 1)
        XCTAssertEqual(f.http.paths().filter { $0 == "/api/tenant/auth/session/refresh" }.count, 1)
    }
    func testLateRememberedRecoveryNewAuthEpochCannotClearCurrentSession() async throws {
        captureA43RuntimeLoadedImages()
        try await lateFailureMustPreserveReplacement(outcome: .rememberedExpiry, replacement: .newEpoch)
    }
    func testLateRememberedRecoveryTenantSwitchCannotClearCurrentSession() async throws {
        captureA43RuntimeLoadedImages()
        try await lateFailureMustPreserveReplacement(outcome: .rememberedExpiry, replacement: .tenantSwitch)
    }
    func testCurrentRememberedRecoveryFailureStillClearsExpiredSession() async throws {
        captureA43RuntimeLoadedImages()
        let f = try coldInitFixture(outcome: .rememberedExpiry)
        defer { f.stop() }
        XCTAssertNotNil(f.state.rememberedLoginCredentialsForAuthUI())
        try await enterLateFailureSecondary(f)
        f.http.secondaryGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertFalse(f.state.isAuthenticated)
        XCTAssertFalse(f.state.apiContext.hasIMSession)
        XCTAssertFalse(IMAPIContext.load(sessionStore: f.protectedStore).hasIMSession)
        XCTAssertEqual(f.http.paths().filter { $0 == "/api/platform/auth/im-login" }.count, 1)
    }
    func testLateRememberedNeutralUnavailableCannotIssueRetiredTenantLogin() async throws {
        captureA43RuntimeLoadedImages()
        try await lateFailureMustPreserveReplacement(outcome: .rememberedNeutralUnavailable, replacement: .newEpoch)
    }
    // WDT_IOS1_CURRENT_DEVICE_REVOKE_CONTRACT_20261111_BEGIN
    func testCurrentFallbackDeviceDisabledPreservesFullDeviceCleanup() async throws {
        captureA43RuntimeLoadedImages()
        let f = try coldInitFixture(outcome: .fallback(code: "device_disabled", status: 403))
        defer { f.stop() }
        try await enterLateFailureSecondary(f)
        let revoked = expectation(description: "actual current-device cleanup authenticates false")
        let observation = f.state.authenticationPresentationStore.authenticationUpdates
            .filter { !$0 }.first().sink { _ in revoked.fulfill() }
        defer { observation.cancel() }
        let scope = f.state.remoteDataScopeKey(for: f.originalContext)
        let removes = f.cache.removeCount(scope: scope)
        let credentialClears = f.credentialStore.clearCount
        f.http.secondaryGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        await fulfillment(of: [revoked], timeout: 1)
        XCTAssertFalse(f.state.isAuthenticated)
        XCTAssertFalse(f.state.apiContext.hasIMSession)
        XCTAssertFalse(IMAPIContext.load(sessionStore: f.protectedStore).hasIMSession)
        XCTAssertNotEqual(f.state.apiContext.deviceID, f.originalContext.deviceID)
        XCTAssertGreaterThan(f.cache.removeCount(scope: scope), removes)
        XCTAssertGreaterThan(f.credentialStore.clearCount, credentialClears)
    }
    // WDT_IOS1_CURRENT_DEVICE_REVOKE_CONTRACT_20261111_END

    // WDT_IOS1_DIRECT_DEVICE_AUTHORITY_CASES_20261111_BEGIN
    func testPrimaryDeviceRevokeAfterNewEpochCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        let f = try coldInitFixture(outcome: .primaryDevice)
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        let next = try installDeviceAuthorityReplacement(f, tenantSwitch: false)
        let clears = f.credentialStore.clearCount
        f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        assertDeviceAuthorityReplacement(f, next: next, credentialClears: clears)
    }
    func testCurrentPrimaryDeviceRevokePreservesFullCleanup() async throws {
        captureA43RuntimeLoadedImages()
        let f = try coldInitFixture(outcome: .primaryDevice)
        defer { f.stop() }
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        let scope = f.state.remoteDataScopeKey(for: f.state.apiContext)
        let removes = f.cache.removeCount(scope: scope), clears = f.credentialStore.clearCount
        f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        assertFullDeviceCleanup(f, previousDevice: f.originalContext.deviceID, scope: scope, removes: removes, credentialClears: clears)
    }
    func testRememberedDeviceRevokeAfterTenantSwitchCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        try await lateFailureMustPreserveReplacement(outcome: .rememberedDevice, replacement: .tenantSwitch)
    }
    func testCurrentRememberedDeviceRevokePreservesFullCleanup() async throws {
        captureA43RuntimeLoadedImages()
        let f = try coldInitFixture(outcome: .rememberedDevice)
        defer { f.stop() }
        try await enterLateFailureSecondary(f)
        let scope = f.state.remoteDataScopeKey(for: f.state.apiContext)
        let removes = f.cache.removeCount(scope: scope), clears = f.credentialStore.clearCount
        f.http.secondaryGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        assertFullDeviceCleanup(f, previousDevice: f.originalContext.deviceID, scope: scope, removes: removes, credentialClears: clears)
    }
    func testOrdinaryDeviceRevokeAfterSameTokenNewEpochCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        try await ordinaryDeviceFailureMustPreserveReplacement(tenantSwitch: false)
    }
    func testOrdinaryDeviceRevokeAfterTenantSwitchCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        try await ordinaryDeviceFailureMustPreserveReplacement(tenantSwitch: true)
    }
    func testCurrentOrdinaryDeviceRevokePreservesFullCleanup() async throws {
        captureA43RuntimeLoadedImages()
        let f = try await completedDeviceChannelFixture()
        defer { f.stop() }
        let original = f.state.apiContext
        let scope = f.state.remoteDataScopeKey(for: original)
        let removes = f.cache.removeCount(scope: scope), clears = f.credentialStore.clearCount
        let request = Task { do { _ = try await f.state.api.meProfile(context: original); XCTFail("device rejection unexpectedly succeeded") } catch {} }
        await fulfillment(of: [f.http.secondaryGate.entered], timeout: 1)
        f.http.secondaryGate.open(); await request.value
        assertFullDeviceCleanup(f, previousDevice: original.deviceID, scope: scope, removes: removes, credentialClears: clears)
    }
    func testDeviceRevokeGETCoalescingSeparatesSameTokenDifferentAuthEpochs() async throws {
        captureA43RuntimeLoadedImages()
        let f = try await completedDeviceChannelFixture()
        defer { f.stop() }
        let original = f.state.apiContext
        let first = Task { do { _ = try await f.state.api.meProfile(context: original); XCTFail("first device rejection unexpectedly succeeded") } catch {} }
        await fulfillment(of: [f.http.secondaryGate.entered], timeout: 1)
        let next = try installDeviceAuthorityReplacement(f, tenantSwitch: false)
        XCTAssertEqual(next.imToken, original.imToken)
        let second = Task { do { _ = try await f.state.api.meProfile(context: next); XCTFail("second device rejection unexpectedly succeeded") } catch {} }
        await fulfillment(of: [f.http.secondProfileEntered], timeout: 1)
        XCTAssertEqual(f.http.paths().filter { $0 == "/api/tenant/me/profile" }.count, 2)
        f.http.secondaryGate.open(); await first.value; await second.value
        XCTAssertFalse(f.state.apiContext.hasIMSession)
        XCTAssertNotEqual(f.state.apiContext.deviceID, next.deviceID)
    }
    func testPlatformOnlyDeviceRevokeUsesAuthFenceWithoutMessageScope() async throws {
        captureA43RuntimeLoadedImages()
        let f = try await completedDeviceChannelFixture()
        defer { f.stop() }
        var root = f.state.apiContext
        root.tenantID = nil; root.imUID = nil; root.imToken = nil; root.tenantAuthSession = nil
        root.platformToken = "synthetic-platform-only"
        root.platformAuthSession = IMStoredAuthSession(sessionID: "synthetic-platform-session", refreshToken: "synthetic-platform-refresh",
            tokenType: "platform", tenantID: "", accountID: root.accountID ?? "account-1", appID: root.appID, deviceID: root.deviceID, clientType: "ios")
        root.sessionEpoch = UUID().uuidString
        XCTAssertTrue(root.save(sessionStore: f.protectedStore).isCommitted)
        f.state.apiContext = root
        XCTAssertFalse(root.hasIMSession)
        let api = try XCTUnwrap(f.state.api as? IMAPIClient)
        let request = Task { do { _ = try await api.refreshCurrentSession(context: root); XCTFail("platform device rejection unexpectedly succeeded") } catch {} }
        await fulfillment(of: [f.http.secondaryGate.entered], timeout: 1)
        f.http.secondaryGate.open(); await request.value
        XCTAssertFalse(f.state.isAuthenticated)
        XCTAssertNil(f.state.apiContext.platformToken)
        XCTAssertNotEqual(f.state.apiContext.deviceID, root.deviceID)
        XCTAssertNil(IMAPIContext.load(sessionStore: f.protectedStore).platformToken)
    }
    private func completedDeviceChannelFixture() async throws -> ColdInitializationFixture {
        let f = try coldInitFixture(outcome: .ordinaryDevice)
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.cacheGate.open(); f.http.authGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertTrue(f.state.apiContext.hasIMSession)
        return f
    }
    private func installDeviceAuthorityReplacement(_ f: ColdInitializationFixture, tenantSwitch: Bool) throws -> IMAPIContext {
        var next = f.state.apiContext
        next.sessionEpoch = UUID().uuidString
        if tenantSwitch {
            next.tenantID = "tenant-2"; next.imUID = "uid-2"; next.accountID = "account-2"
            next.tenantAuthSession = IMStoredAuthSession(sessionID: "synthetic-new-session", refreshToken: "synthetic-new-refresh",
                tokenType: "im", tenantID: "tenant-2", accountID: "account-2", appID: next.appID, deviceID: next.deviceID, clientType: "ios")
        }
        XCTAssertTrue(next.save(sessionStore: f.protectedStore).isCommitted)
        f.state.apiContext = next; _ = f.state.authFlowGeneration.issueToken()
        return next
    }
    private func ordinaryDeviceFailureMustPreserveReplacement(tenantSwitch: Bool) async throws {
        let f = try await completedDeviceChannelFixture()
        defer { f.stop() }
        let original = f.state.apiContext
        let scope = f.state.remoteDataScopeKey(for: original), removes = f.cache.removeCount(scope: f.state.remoteDataScopeKey(for: original))
        let request = Task { do { _ = try await f.state.api.meProfile(context: original); XCTFail("device rejection unexpectedly succeeded") } catch {} }
        await fulfillment(of: [f.http.secondaryGate.entered], timeout: 1)
        let next = try installDeviceAuthorityReplacement(f, tenantSwitch: tenantSwitch)
        let clears = f.credentialStore.clearCount
        f.http.secondaryGate.open(); await request.value
        assertDeviceAuthorityReplacement(f, next: next, credentialClears: clears)
        XCTAssertEqual(f.cache.removeCount(scope: scope), removes)
    }
    private func assertDeviceAuthorityReplacement(_ f: ColdInitializationFixture, next: IMAPIContext, credentialClears: Int) {
        XCTAssertTrue(f.state.isAuthenticated)
        XCTAssertTrue(f.state.apiContext.isSameAuthAuthority(as: next.authSessionFence))
        XCTAssertTrue(IMAPIContext.load(sessionStore: f.protectedStore).isSameAuthAuthority(as: next.authSessionFence))
        XCTAssertEqual(f.credentialStore.clearCount, credentialClears)
        XCTAssertEqual(f.state.apiContext.deviceID, next.deviceID)
    }
    private func assertFullDeviceCleanup(_ f: ColdInitializationFixture, previousDevice: String, scope: String, removes: Int, credentialClears: Int) {
        XCTAssertFalse(f.state.isAuthenticated)
        XCTAssertFalse(f.state.apiContext.hasIMSession)
        XCTAssertFalse(IMAPIContext.load(sessionStore: f.protectedStore).hasIMSession)
        XCTAssertNotEqual(f.state.apiContext.deviceID, previousDevice)
        XCTAssertGreaterThan(f.cache.removeCount(scope: scope), removes)
        XCTAssertGreaterThan(f.credentialStore.clearCount, credentialClears)
    }
    // WDT_IOS1_DIRECT_DEVICE_AUTHORITY_CASES_20261111_END


    // WDT_IOS1_ROOT_DEVICE_AUTHORITY_CASES_20261111_BEGIN
    func testRootDirectoryDeviceRevokeAfterSameTokenNewEpochCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        try await rootDeviceFailure(kind: .directory, replacement: .newEpoch)
    }
    func testCurrentRootDirectoryDeviceRevokePreservesFullCleanup() async throws {
        captureA43RuntimeLoadedImages()
        try await rootDeviceFailure(kind: .directory, replacement: nil)
    }
    func testPretenantEnterDeviceRevokeAfterNewRootCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        try await rootDeviceFailure(kind: .enter, replacement: .tenantSwitch)
    }
    func testRootDeviceRevokeAfterCredentialRevisionAdvanceCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        try await rootDeviceFailure(kind: .directory, replacement: .sameSessionAdvance)
    }
    func testAnonymousDeviceRejectionAfterNewAuthCannotClearCurrent() async throws {
        captureA43RuntimeLoadedImages()
        try await rootDeviceFailure(kind: .anonymous, replacement: .newEpoch)
    }
    func testCurrentAnonymousDeviceRejectionReportsTypedFailureWithoutSessionCleanup() async throws {
        captureA43RuntimeLoadedImages()
        try await rootDeviceFailure(kind: .anonymous, replacement: nil)
    }
    private enum RootDeviceRequest: Equatable { case directory, enter, anonymous }
    private func rootDeviceFailure(kind: RootDeviceRequest, replacement: LateReplacement?) async throws {
        let f: ColdInitializationFixture
        if kind == .anonymous { f = try await completedDeviceChannelFixture() }
        else { f = try coldInitFixture(outcome: .ordinaryDevice, platformOnly: true) }
        defer { f.stop() }
        let original = f.state.apiContext, initialAuthentication = f.state.isAuthenticated
        let clears = f.credentialStore.clearCount
        let request = Task { () -> Error? in
            do {
                switch kind {
                case .directory: _ = try await f.state.api.myTenantDirectory(platformToken: original.platformToken, appID: original.appID, requestAuthority: original.authSessionFence)
                case .enter: _ = try await f.state.api.enterTenant(tenantID: "tenant-2", platformToken: original.platformToken, appID: original.appID, deviceID: original.deviceID, requestAuthority: original.authSessionFence)
                case .anonymous: _ = try await f.state.api.resolveEnterpriseContext(tenantCode: "WXT000001", appID: original.appID, deviceID: original.deviceID)
                }
                XCTFail("device rejection unexpectedly succeeded"); return nil
            } catch { return error }
        }
        await fulfillment(of: [f.http.secondaryGate.entered], timeout: 1)
        var next = original
        if let replacement {
            if replacement == .sameSessionAdvance { next.credentialRevision += 1 }
            else { next.sessionEpoch = UUID().uuidString }
            if replacement == .tenantSwitch {
                next.accountID = "root-account-2"
                next.platformAuthSession = IMStoredAuthSession(sessionID: "synthetic-new-root-session", refreshToken: "synthetic-new-root-refresh",
                    tokenType: "platform", tenantID: "", accountID: "root-account-2", appID: next.appID, deviceID: next.deviceID, clientType: "ios")
            }
            XCTAssertEqual(next.platformToken, original.platformToken)
            XCTAssertTrue(next.save(sessionStore: f.protectedStore).isCommitted)
            f.state.apiContext = next
            if replacement != .sameSessionAdvance { _ = f.state.authFlowGeneration.issueToken() }
        }
        f.http.secondaryGate.open()
        let requestError = await request.value
        let error = try XCTUnwrap(requestError)
        if kind == .anonymous {
            let rejection = try XCTUnwrap(error as? IMAnonymousDeviceRejectionError)
            XCTAssertEqual(rejection.statusCode, 403); XCTAssertEqual(rejection.code, "device_disabled")
            XCTAssertFalse(DeviceRevocationDetector.matches(error: rejection))
            f.state.handleRemoteError(rejection, fallback: "public flow rejected")
        }
        if kind != .anonymous, replacement == nil {
            XCTAssertFalse(f.state.isAuthenticated)
            XCTAssertNil(f.state.apiContext.platformToken)
            XCTAssertNil(IMAPIContext.load(sessionStore: f.protectedStore).platformToken)
            XCTAssertNotEqual(f.state.apiContext.deviceID, original.deviceID)
            XCTAssertGreaterThan(f.credentialStore.clearCount, clears)
        } else {
            XCTAssertEqual(f.state.isAuthenticated, initialAuthentication)
            XCTAssertTrue(f.state.apiContext.isSameAuthAuthority(as: next.authSessionFence))
            XCTAssertTrue(IMAPIContext.load(sessionStore: f.protectedStore).isSameAuthAuthority(as: next.authSessionFence))
            XCTAssertEqual(f.state.apiContext.deviceID, original.deviceID)
            XCTAssertEqual(f.credentialStore.clearCount, clears)
        }
    }
    // WDT_IOS1_ROOT_DEVICE_AUTHORITY_CASES_20261111_END

    private enum LateReplacement: Equatable { case newEpoch, tenantSwitch, sameSessionAdvance }
    private func enterLateFailureSecondary(_ f: ColdInitializationFixture) async throws {
        await fulfillment(of: [f.cacheGate.entered], timeout: 1)
        f.cacheGate.open()
        await fulfillment(of: [f.http.authGate.entered], timeout: 1)
        f.http.authGate.open()
        await fulfillment(of: [f.http.secondaryGate.entered], timeout: 1)
        XCTAssertTrue(f.state.isAuthenticated)
        XCTAssertTrue(f.state.apiContext.hasIMSession)
    }
    private func lateFailureMustPreserveReplacement(outcome: ColdInitializationHTTPTransport.Outcome, replacement: LateReplacement) async throws {
        let f = try coldInitFixture(outcome: outcome)
        defer { f.stop() }
        if outcome.usesRememberedRecovery { XCTAssertNotNil(f.state.rememberedLoginCredentialsForAuthUI()) }
        try await enterLateFailureSecondary(f)
        var next = makeRefreshableMessageSendContext(deviceID: f.originalContext.deviceID)
        switch replacement {
        case .newEpoch: XCTAssertNotEqual(next.sessionEpoch, f.originalContext.sessionEpoch)
        case .tenantSwitch:
            next.tenantID = "tenant-2"; next.imUID = "uid-2"; next.accountID = "account-2"
            next.tenantAuthSession = IMStoredAuthSession(sessionID: "new-tenant-session", refreshToken: "synthetic-new-refresh",
                tokenType: "im", tenantID: "tenant-2", accountID: "account-2", appID: next.appID,
                deviceID: next.deviceID, clientType: "ios")
        case .sameSessionAdvance:
            next = f.state.apiContext
            next.imToken = "synthetic-advanced-im"; next.credentialRevision += 1
        }
        XCTAssertTrue(next.save(sessionStore: f.protectedStore).isCommitted)
        f.state.apiContext = next
        if replacement != .sameSessionAdvance { _ = f.state.authFlowGeneration.issueToken() }
        XCTAssertTrue(f.state.apiContext.isSameAuthAuthority(as: next.authSessionFence))
        let scope = f.state.remoteDataScopeKey(for: next)
        let removes = f.cache.removeCount(scope: scope)
        f.http.secondaryGate.open()
        await f.state.coldLaunchSessionRestoreTask?.value
        XCTAssertTrue(f.state.isAuthenticated)
        XCTAssertTrue(f.state.apiContext.hasIMSession)
        XCTAssertTrue(f.state.apiContext.isSameAuthAuthority(as: next.authSessionFence))
        let durable = IMAPIContext.load(sessionStore: f.protectedStore)
        XCTAssertTrue(durable.hasIMSession)
        XCTAssertTrue(durable.isSameAuthAuthority(as: next.authSessionFence))
        XCTAssertEqual(f.cache.removeCount(scope: scope), removes)
        if case .rememberedNeutralUnavailable = outcome {
            XCTAssertFalse(f.http.paths().contains { $0 == "/api/tenant/auth/login" })
        }
    }
    // WDT_IOS1_LATE_AUTH_REFRESH_AUTHORITY_CASES_20261111_END

    private func coldInitFixture(outcome: ColdInitializationHTTPTransport.Outcome = .valid, platformOnly: Bool = false) throws -> ColdInitializationFixture {
        clearStoredAPIContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-producer-\(UUID().uuidString)")
        var context = makeRefreshableMessageSendContext(deviceID: "cold-\(UUID().uuidString)")
        if platformOnly {
            context.tenantID = nil; context.imUID = nil; context.imToken = nil; context.tenantAuthSession = nil
            context.platformToken = "synthetic-platform-root"
            context.platformAuthSession = IMStoredAuthSession(sessionID: "synthetic-root-session", refreshToken: "synthetic-root-refresh",
                tokenType: "platform", tenantID: "", accountID: context.accountID ?? "account-1", appID: context.appID, deviceID: context.deviceID, clientType: "ios")
        }
        let protectedStore = InMemoryProtectedSessionStore()
        XCTAssertTrue(context.save(sessionStore: protectedStore).isCommitted)
        let cacheGate = ColdInitializationGate(label: "actual legacy-cache load reached")
        let authGate = ColdInitializationGate(label: "actual auth refresh reached")
        let http = try ColdInitializationHTTPTransport(context: context, authGate: authGate, outcome: outcome)
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [.string(realtimeEnvelopeString(type: "connect_ack"))])
        let sockets = FakeRealtimeWebSocketTransport(socket: socket)
        let realtime = RealtimeClient(transport: sockets, quicConfiguration: .init(isEnabled: false),
            requestIDProvider: deterministicRealtimeRequestID, networkMonitorFactory: nil,
            continuity: IMRuntimeWebSocketContinuity())
        let cache = ColdInitializationMessageStore(root: root.appendingPathComponent("cache"), gate: cacheGate)
        let credentialStore = RecordingRememberedLoginCredentialStore()
        let preferenceStore = RecordingRememberedLoginPreferenceStore()
        if outcome.usesRememberedRecovery {
            let scope = RememberedLoginCredentialScope(context: context)
            XCTAssertTrue(credentialStore.save(RememberedLoginCredentials(mode: .account,
                identifier: "remembered-fixture", password: "synthetic-remembered-password"), scope: scope))
            preferenceStore.set(true, scope: scope)
        }
        let state = AppState(api: makeClient(transport: http, runtimeRouteStore: isolatedRuntimeRouteStore()),
            realtimeClient: realtime, voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: cache, messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support")),
            rememberedLoginCredentialStore: credentialStore, rememberedLoginPreferenceStore: preferenceStore,
            protectedSessionStore: protectedStore, launchUnitTestOverride: false)
        if platformOnly {
            XCTAssertFalse(state.isAuthenticated)
            XCTAssertNil(state.coldLaunchSessionRestoreTask)
            XCTAssertFalse(state.apiContext.hasIMSession)
            XCTAssertNotNil(state.apiContext.platformToken)
        } else {
            XCTAssertTrue(state.isAuthenticated)
            XCTAssertNotNil(state.coldLaunchSessionRestoreTask)
        }
        XCTAssertEqual(state.apiContext.sessionEpoch, context.sessionEpoch)
        return ColdInitializationFixture(state: state, realtime: realtime, socket: socket,
            sockets: sockets, cacheGate: cacheGate, http: http, protectedStore: protectedStore, cache: cache, originalContext: context, credentialStore: credentialStore)
    }
}

@MainActor
private struct ColdInitializationFixture {
    let state: AppState
    let realtime: RealtimeClient
    let socket: FakeRealtimeWebSocketTask
    let sockets: FakeRealtimeWebSocketTransport
    let cacheGate: ColdInitializationGate
    let http: ColdInitializationHTTPTransport
    let protectedStore: InMemoryProtectedSessionStore
    let cache: ColdInitializationMessageStore
    let originalContext: IMAPIContext
    let credentialStore: RecordingRememberedLoginCredentialStore

    func stop() {
        state.coldLaunchSessionRestoreTask?.cancel()
        cacheGate.open(); http.authGate.open(); http.secondaryGate.open()
        state.coldLaunchSessionRecoveryTask?.cancel()
        state.appDidEnterBackground()
        state.stopInboxRefreshLoop(); state.stopRTCCallRefreshLoop()
        // WDT_IOS1_ROOT_DEVICE_AUTHORITY_CASES_20261111_BEGIN — Retire all registered work owned by this fixture after assertions.
        state.remoteSyncEngine.reset()
        // WDT_IOS1_ROOT_DEVICE_AUTHORITY_CASES_20261111_END
    }
}

private final class ColdInitializationGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let lock = NSLock()
    private var released = false
    private var waits = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    init(label: String) { entered = XCTestExpectation(description: label) }
    func wait() async {
        await withCheckedContinuation { continuation in
            let result = lock.withLock { () -> (Bool, Bool) in
                waits += 1
                if released { return (true, waits == 1) }
                continuations.append(continuation)
                return (false, waits == 1)
            }
            if result.1 { entered.fulfill() }
            if result.0 { continuation.resume() }
        }
    }
    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true; let result = continuations; continuations.removeAll(); return result
        }
        pending.forEach { $0.resume() }
    }
}

private final class ColdInitializationMessageStore: MessageStore, @unchecked Sendable {
    private let cache: SnapshotCache
    private let gate: ColdInitializationGate
    private let removeLock = NSLock()
    private var removed: [String: Int] = [:]
    func removeCount(scope: String) -> Int { removeLock.withLock { removed[scope, default: 0] } }
    init(root: URL, gate: ColdInitializationGate) { cache = SnapshotCache(directoryURL: root); self.gate = gate }
    var schemaVersion: Int { cache.schemaVersion }
    func scopeKey(for context: IMAPIContext) -> String { cache.scopeKey(for: context) }
    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? { await gate.wait(); return await cache.load(scope: scope) }
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool { cache.write(snapshot, scope: scope) }
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool { await cache.writeNow(snapshot, scope: scope) }
    func remove(scope: String) { removeLock.withLock { removed[scope, default: 0] += 1 }; cache.remove(scope: scope) }
    func removeAll() { cache.removeAll() }
}

private final class ColdInitializationHTTPTransport: HTTPTransport, @unchecked Sendable {
    enum Outcome {
        case valid, revoked, unavailable, fallback(code: String, status: Int), rememberedExpiry, rememberedNeutralUnavailable, primaryDevice, rememberedDevice, ordinaryDevice
        var usesRememberedRecovery: Bool {
            switch self { case .rememberedExpiry, .rememberedNeutralUnavailable, .rememberedDevice: return true; default: return false }
        }
    }
    let authGate: ColdInitializationGate
    let secondaryGate = ColdInitializationGate(label: "actual fallback or remembered recovery reached")
    let secondProfileEntered = XCTestExpectation(description: "second exact-authority GET reaches actual transport")
    private let requestLock = NSLock()
    private var requestedPaths: [String] = []
    func paths() -> [String] { requestLock.withLock { requestedPaths } }
    private let outcome: Outcome
    private let validRefresh: Data
    private let policy: Data
    init(context: IMAPIContext, authGate: ColdInitializationGate, outcome: Outcome) throws {
        self.authGate = authGate; self.outcome = outcome
        policy = try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
            "app_id": context.appID, "status": "active", "allow_workspace_switch": true,
            "allow_default_tenant_join": false, "cache_ttl_seconds": 600]])
        validRefresh = try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
            "im_token": "cold-restored-im", "expires_at": 1_895_000_000,
            "tenant": ["tenant_id": "tenant-1", "name": "Cold Fixture", "status": "active"],
            "member": ["tenant_id": "tenant-1", "account_id": "account-1", "im_uid": "uid-1", "status": "active", "role": "member"],
            "auth_session": ["session_id": "sess_platform-tenant-1", "refresh_token": "cold-refresh", "expires_at": 1_895_000_000,
                "tenant_id": "tenant-1", "app_id": context.appID, "device_id": context.deviceID, "client_type": "ios", "token_type": "im"]]])
    }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        let profileCount = requestLock.withLock { () -> Int in requestedPaths.append(path); return requestedPaths.filter { $0 == "/api/tenant/me/profile" }.count }
        if case .ordinaryDevice = outcome, path == "/api/tenant/me/profile" || path == "/api/platform/auth/session/refresh" || path == "/api/platform/me/tenants" || path.hasSuffix("/enter") || path == "/api/platform/auth/enterprise-context/resolve" {
            if path == "/api/tenant/me/profile", profileCount == 2 { secondProfileEntered.fulfill() }
            await secondaryGate.wait()
            return rejection("device_disabled", status: 403, request: request)
        }
        if path == "/api/tenant/auth/session/refresh", case let .fallback(code, status) = outcome {
            await secondaryGate.wait()
            return rejection(code, status: status, request: request)
        }
        if path == "/api/platform/auth/im-login", outcome.usesRememberedRecovery {
            await secondaryGate.wait()
            if case .rememberedNeutralUnavailable = outcome { return rejection("endpoint_not_found", status: 404, request: request) }
            if case .rememberedDevice = outcome { return rejection("device_disabled", status: 403, request: request) }
            return rejection("invalid_credentials", status: 401, request: request)
        }
        if path == "/api/tenant/auth/login", outcome.usesRememberedRecovery {
            return rejection("invalid_credentials", status: 401, request: request)
        }
        if path.hasSuffix("/session/refresh") {
            await authGate.wait()
            switch outcome {
            case .fallback: throw URLError(.cannotConnectToHost)
            case .rememberedExpiry, .rememberedNeutralUnavailable, .rememberedDevice: return rejection("refresh_token_expired", status: 401, request: request)
            case .primaryDevice: return rejection("device_disabled", status: 403, request: request)
            case .valid, .ordinaryDevice: return HTTPTransportResult(data: validRefresh, isHTTPResponse: true, statusCode: 200, responseURL: request.url)
            case .revoked: return result(#"{"ok":false,"error":{"code":"session_revoked","message":"synthetic revoked"}}"#, status: 401, request: request)
            case .unavailable: return result(#"{"ok":false,"error":{"code":"service_unavailable","message":"synthetic unavailable"}}"#, status: 503, request: request)
            }
        }
        if path == "/api/platform/apps/current-policy" { return HTTPTransportResult(data: policy, isHTTPResponse: true, statusCode: 200, responseURL: request.url) }
        return result(#"{"ok":true,"data":{"items":[],"conversations":[],"has_more":false}}"#, status: 200, request: request)
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw FakeHTTPTransportError.responseQueueExhausted(method: request.httpMethod ?? "PUT", url: request.url?.path ?? "")
    }
    private func rejection(_ code: String, status: Int, request: URLRequest) -> HTTPTransportResult {
        let body = "{\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"synthetic fixture rejection\"}}"
        return result(body, status: status, request: request)
    }
    private func result(_ body: String, status: Int, request: URLRequest) -> HTTPTransportResult {
        HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true, statusCode: status, responseURL: request.url)
    }
}
// WDT_IOS1_COLD_RESTORE_PRODUCER_CASES_20261111_END

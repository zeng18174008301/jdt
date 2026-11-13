import Foundation
import Combine
import XCTest
import OSLog
import Security
@testable import WenDaTong

extension HTTPTransportTests {
    func testAuthenticatedSessionPersistsOnlyInProtectedStoreAcrossRelaunchAndLogoutClears() throws {
        let suiteName = "ProtectedSession.Relaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let sessionStore = InMemoryProtectedSessionStore()
        let context = makeProtectedSessionContext()
        let unprotectedSessionKeys = protectedSessionStorageKeys()
        defer {
            IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)
            defaults.removePersistentDomain(forName: suiteName)
        }
        XCTAssertEqual(
            context.save(defaults: defaults, sessionStore: sessionStore),
            .committed
        )
        XCTAssertTrue(unprotectedSessionKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        let relaunched = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)
        XCTAssertEqual(relaunched.platformToken, context.platformToken)
        XCTAssertEqual(relaunched.accountID, context.accountID)
        XCTAssertEqual(relaunched.tenantID, context.tenantID)
        XCTAssertEqual(relaunched.imUID, context.imUID)
        XCTAssertEqual(relaunched.imToken, context.imToken)
        XCTAssertEqual(relaunched.platformAuthSession, context.platformAuthSession)
        XCTAssertEqual(relaunched.tenantAuthSession, context.tenantAuthSession)
        XCTAssertTrue(relaunched.hasIMSession)
        XCTAssertTrue(relaunched.hasRefreshSession)
        var relaunchedAdmission = PostLoginWorkbenchAdmissionState()
        XCTAssertEqual(
            relaunchedAdmission.consume(hasIMSession: relaunched.hasIMSession, scope: "durable-relaunch"),
            .admitted
        )
        IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)
        let afterLogout = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)
        XCTAssertFalse(afterLogout.hasIMSession)
        XCTAssertFalse(afterLogout.hasRefreshSession)
        XCTAssertEqual(sessionStore.storedValueCount, 0)
        XCTAssertTrue(unprotectedSessionKeys.allSatisfy { defaults.object(forKey: $0) == nil })
    }

    func testPreemptiveAuthRefreshPolicyUsesSkewAndBoundedClockRechecks() {
        let now: TimeInterval = 2_000_000_000
        XCTAssertEqual(
            IMAuthSessionPreemptiveRefreshPolicy.delayUntilRefresh(
                accessExpiresAt: Int64(now + 600),
                now: now
            ),
            300 // WDT_IOS1_A17_CURRENT_FIXTURE_CONTRACT_20261111
        )
        XCTAssertEqual(
            IMAuthSessionPreemptiveRefreshPolicy.boundedSleepSeconds(for: 480),
            60
        )
        XCTAssertEqual(
            IMAuthSessionPreemptiveRefreshPolicy.delayUntilRefresh(
                accessExpiresAt: Int64(now + 120),
                now: now
            ),
            0
        )
        XCTAssertEqual(
            IMAuthSessionPreemptiveRefreshPolicy.delayUntilRefresh(
                accessExpiresAt: Int64(now + 600),
                now: now + 601
            ),
            0,
            "A forward system-clock correction becomes due at the next bounded recheck"
        )
        XCTAssertNil(
            IMAuthSessionPreemptiveRefreshPolicy.delayUntilRefresh(
                accessExpiresAt: 0,
                now: now
            )
        )
        XCTAssertEqual(
            IMAuthSessionPreemptiveRefreshPolicy.activeAccessExpiresAt(
                hasIMSession: true,
                contextAccessExpiresAt: Int64(now + 300),
                tenantAccessExpiresAt: Int64(now + 240),
                platformAccessExpiresAt: Int64(now + 3_600),
                legacyIMAccessExpiresAt: Int64(now + 300)
            ),
            Int64(now + 240),
            "A later platform credential must not hide the active IM credential boundary"
        )
        XCTAssertEqual(
            IMAuthSessionPreemptiveRefreshPolicy.activeAccessExpiresAt(
                hasIMSession: false,
                contextAccessExpiresAt: 0,
                tenantAccessExpiresAt: Int64(now + 240),
                platformAccessExpiresAt: Int64(now + 3_600),
                legacyIMAccessExpiresAt: Int64(now + 300)
            ),
            Int64(now + 3_600)
        )
    }

    func testAuthSessionTerminationPolicyRequiresExplicitSecurityAuthority() {
        let retryableCodes = [
            "session_expired",
            "refresh_token_expired",
            "invalid_token",
            "expired_token",
            "rate_limited",
            "audit_write_failed",
            "token_sign_failed",
            "service_unavailable"
        ]
        let terminalCodes = [
            "session_revoked",
            "session_family_revoked",
            "refresh_token_reused",
            "reauth_required",
            "device_revoked",
            "account_disabled",
            "tenant_service_stopped",
            "security_blocked",
            "password_changed",
            "auth_version_revoked"
        ]
        retryableCodes.forEach {
            XCTAssertFalse(IMAuthSessionTerminationPolicy.isTerminal(code: $0), $0)
        }
        terminalCodes.forEach {
            XCTAssertTrue(IMAuthSessionTerminationPolicy.isTerminal(code: $0), $0)
        }
    }

    func testUntilRevokedSessionIgnoresCompatibilityRefreshExpiryButHonorsAuthoritativeRevocationScope() {
        XCTAssertEqual(
            IMAuthSessionTerminationPolicy.disposition(
                code: "refresh_token_expired",
                lifetimeMode: .untilRevoked,
                authorityFamily: .tenant
            ),
            .retryable
        )
        XCTAssertEqual(
            IMAuthSessionTerminationPolicy.disposition(
                code: "session_expired",
                lifetimeMode: .absolute,
                authorityFamily: .tenant
            ),
            .tenantLocal
        )
        XCTAssertEqual(
            IMAuthSessionTerminationPolicy.disposition(
                code: "tenant_member_disabled",
                lifetimeMode: .untilRevoked,
                authorityFamily: .tenant
            ),
            .tenantLocal
        )
        XCTAssertEqual(
            IMAuthSessionTerminationPolicy.disposition(
                code: "device_revoked",
                lifetimeMode: .untilRevoked,
                authorityFamily: .tenant
            ),
            .global
        )
        XCTAssertEqual(
            IMAuthSessionTerminationPolicy.disposition(
                code: "refresh_token_reused",
                lifetimeMode: .untilRevoked,
                authorityFamily: .tenant
            ),
            .global
        )
        ["network_unavailable", "dns_failed", "tls_failed", "timeout", "bad_gateway", "service_unavailable", "gateway_timeout"].forEach {
            XCTAssertEqual(
                IMAuthSessionTerminationPolicy.disposition(
                    code: $0,
                    lifetimeMode: .untilRevoked,
                    authorityFamily: .tenant
                ),
                .retryable,
                $0
            )
        }
    }

    func testStoredUntilRevokedSessionRoundTripPreservesLifetimeAndTenantClearPreservesPlatform() throws {
        let suiteName = "StoredUntilRevokedSession.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let sessionStore = InMemoryProtectedSessionStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var context = makeContext()
        context.platformAuthSession = IMStoredAuthSession(
            sessionID: "platform-session",
            refreshToken: "platform-refresh",
            tokenType: "platform",
            lifetimeMode: .untilRevoked
        )
        context.tenantAuthSession = IMStoredAuthSession(
            sessionID: "tenant-session",
            refreshToken: "tenant-refresh",
            refreshExpiresAt: 1,
            tokenType: "im",
            tenantID: "tenant-1",
            lifetimeMode: .untilRevoked
        )
        XCTAssertTrue(context.save(defaults: defaults, sessionStore: sessionStore).isCommitted)
        var restored = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)
        XCTAssertEqual(restored.tenantAuthSession?.lifetimeMode, .untilRevoked)
        XCTAssertTrue(restored.hasRefreshSession)
        restored.clearIMSessionPreservingPlatform(defaults: defaults, sessionStore: sessionStore)
        XCTAssertNil(restored.tenantAuthSession)
        XCTAssertNil(restored.tenantID)
        XCTAssertEqual(restored.platformAuthSession?.sessionID, "platform-session")
        XCTAssertEqual(restored.platformAuthSession?.lifetimeMode, .untilRevoked)
        XCTAssertTrue(restored.hasRefreshSession)
    }

    func testAppPolicyVerifiedLastGoodDoesNotAgeEvict() throws {
        let suiteName = "PermanentAppPolicyLastGood.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = RemoteAppCurrentPolicy(
            appID: "jianhuitong-ios",
            platform: "ios",
            status: "active",
            allowWorkspaceSwitch: true,
            allowDefaultTenantJoin: true,
            registrationEnabled: true,
            enterpriseCodeFirst: true,
            preferredEnterpriseCode: "WXT000001",
            cacheTTLSeconds: 60
        )
        let savedAt = Date(timeIntervalSince1970: 1_000)
        IMAppPolicyLastGoodStore.save(policy, appID: policy.appID, defaults: defaults, now: savedAt)
        let restored = IMAppPolicyLastGoodStore.usable(
            appID: policy.appID,
            defaults: defaults,
            now: savedAt.addingTimeInterval(20 * 365 * 24 * 60 * 60)
        )
        XCTAssertNotNil(restored)
        XCTAssertFalse(restored?.isOnlineFresh ?? true)
    }

    func testAcceptedWorkbenchAdmissionIsVisibleAndDuplicateTransitionIsIdempotent() {
        let realtime = PostLoginSilentRealtimeTransport()
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [
                HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 503)
            ])),
            realtimeClient: realtime,
            apiContextOverride: makeProtectedSessionContext()
        )
        XCTAssertEqual(state.enterIM(showToast: false), .admitted)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertFalse(state.isShowingLaunchSplash)
        XCTAssertNil(state.activeSplashOverlay)
        state.activeTab = .contacts
        XCTAssertEqual(state.enterIM(showToast: false), .duplicate)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertFalse(state.isShowingLaunchSplash)
        XCTAssertNil(state.activeSplashOverlay)
        XCTAssertEqual(state.activeTab, .contacts)
        state.logout()
    }

    func testWorkbenchAdmissionWithoutIMSessionReturnsToRecoverableLogin() {
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [
                HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 503)
            ])),
            realtimeClient: PostLoginSilentRealtimeTransport(),
            apiContextOverride: makePreloginContext()
        )
        state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        XCTAssertEqual(state.enterIM(showToast: false), .rejectedMissingSession)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.authScreen, .accountLogin)
        XCTAssertFalse(state.isShowingLaunchSplash)
        XCTAssertNil(state.activeSplashOverlay)
        XCTAssertEqual(state.toast, "登录会话未完成，请重新登录")
    }

    func testSystemAuthenticatedSessionStoreRoundTripsAfterFirstUnlockKeychainData() {
        captureA43RuntimeLoadedImages() // WDT_IOS1_NATIVE_LOADED_IMAGE_OBSERVATION_20261111
        let store = IMKeychainSessionStore()
        let key = "test-session-\(UUID().uuidString)"
        let protectedValue = "synthetic-session-value-\(UUID().uuidString)"
        defer { _ = store.deleteString(forKey: key) }
        XCTAssertTrue(
            store.setString(protectedValue, forKey: key),
            "The runtime must retain authenticated-session protected-storage authority"
        )
        XCTAssertEqual(store.string(forKey: key), protectedValue)
        XCTAssertTrue(store.deleteString(forKey: key))
        XCTAssertNil(store.string(forKey: key))
    }

    #if targetEnvironment(simulator)
    func testSimulatorProtectedSessionStoreSerializesMultipleInstancesForOneFile() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorProtectedSessionConcurrency-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directoryURL.appendingPathComponent("session.json", isDirectory: false)
        let stores = [
            IMSimulatorProtectedSessionStore(fileURL: storeURL),
            IMSimulatorProtectedSessionStore(fileURL: storeURL),
        ]
        defer {
            _ = stores[0].deleteAll()
            try? FileManager.default.removeItem(at: directoryURL)
        }

        DispatchQueue.concurrentPerform(iterations: 40) { index in
            _ = stores[index % stores.count].setString("value-\(index)", forKey: "key-\(index)")
        }

        for index in 0..<40 {
            XCTAssertEqual(stores[(index + 1) % stores.count].string(forKey: "key-\(index)"), "value-\(index)")
        }
    }

    func testUnsignedSimulatorEnterpriseLoginPersistsProtectedSessionAndAuthenticates() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 31)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnsignedSimulatorEnterpriseLogin-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
        let sessionStore = IMKeychainSessionStore(simulatorFileURL: storeURL)
        defer {
            _ = sessionStore.deleteAll()
            try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        }
        let transport = FakeHTTPTransport(results: [
            enterpriseFirstPolicySuccess(),
            try enterpriseContextSuccess(routes: routes, tenantCode: "WXT000001"),
            slideCaptchaDisabledSuccess(),
            try atomicEnterpriseLoginSuccess(routes: routes),
        ])
        let context = makePreloginContext()
        let rememberedLogin = try ScopedSystemRememberedLoginFixture(context: context)
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            rememberedLoginCredentialStore: rememberedLogin.credentials,
            rememberedLoginPreferenceStore: rememberedLogin.preferences,
            protectedSessionStore: sessionStore,
            apiContextOverride: context
        )
        defer {
            state.authFlowGeneration.invalidate()
            rememberedLogin.clear()
        }

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        let enterpriseResolved = await state.resolveEnterpriseContext(enterpriseCode: "WXT000001")
        XCTAssertTrue(enterpriseResolved)
        state.startLoginFlow(identifier: "member31", password: "SyntheticPass123!")
        try await waitForCondition(iterations: 120) { state.isAuthenticated && !state.isAuthLoading }
        XCTAssertTrue(state.hasActiveIMSession)
        XCTAssertNotEqual(state.toast, "登录状态未能安全保存，请重试")
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(persisted.tenantID, "tenant-enterprise")
        XCTAssertEqual(persisted.appID, "jianhuitong-ios")
        XCTAssertEqual(persisted.deviceID, "device-1")
        XCTAssertTrue(persisted.hasRefreshSession)
    }

    func testUnsignedSimulatorEnterpriseRegistrationInstallsCompleteProtectedSession() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 32)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnsignedSimulatorEnterpriseRegistration-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
        let sessionStore = IMKeychainSessionStore(simulatorFileURL: storeURL)
        defer {
            _ = sessionStore.deleteAll()
            try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        }
        let transport = FakeHTTPTransport(results: [
            enterpriseFirstPolicySuccess(),
            try enterpriseContextSuccess(routes: routes, tenantCode: "WXT000001"),
            try atomicRegistrationSuccess(
                requestedTenantCode: "WXT000001",
                canonicalTenantCode: "WXT000001",
                routes: routes
            ),
            try tenantEnterSuccess(entryTicket: "registration-entry", routes: routes),
            try registrationTenantEntrySuccess(tenantID: "tenant-enterprise"),
        ])
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        let enterpriseResolved = await state.resolveEnterpriseContext(enterpriseCode: "WXT000001")
        XCTAssertTrue(enterpriseResolved)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.registerAndEnterIM(
            account: "member32",
            password: "SyntheticPass123!",
            enterpriseCode: ""
        )
        try await waitForCondition(iterations: 120) {
            state.toast == "注册成功，已自动登录" && !state.isAuthLoading
        }
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        XCTAssertNotEqual(state.toast, "注册失败：" + RegistrationFlowPolicy.incompleteSessionMessage)
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(persisted.tenantID, "tenant-enterprise")
        XCTAssertEqual(persisted.tenantAPIBaseURL, routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first)
        XCTAssertEqual(persisted.imAPIBaseURL, routes.services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first)
        XCTAssertTrue(persisted.hasRefreshSession)
    }
    #endif

    func testAuthenticatedSessionWriteFailurePreservesExistingLegacyMigrationSourceWithoutAddingNewDefaults() throws {
        let suiteName = "ProtectedSession.FailClosed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let sessionStore = InMemoryProtectedSessionStore(failWrites: true)
        let context = makeProtectedSessionContext()
        let unprotectedSessionKeys = protectedSessionStorageKeys()
        defer {
            IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(
            context.save(defaults: defaults, sessionStore: sessionStore),
            .failed
        )

        XCTAssertEqual(sessionStore.storedValueCount, 0)
        XCTAssertTrue(unprotectedSessionKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        let relaunched = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)
        XCTAssertFalse(relaunched.hasIMSession)
        XCTAssertFalse(relaunched.hasRefreshSession)

        defaults.set("legacy-sensitive-value", forKey: "im2.ios.imToken")
        let legacyAuthSession = try XCTUnwrap(context.platformAuthSession)
        let legacyAuthData = try JSONEncoder().encode(legacyAuthSession)
        defaults.set(
            try XCTUnwrap(String(data: legacyAuthData, encoding: .utf8)),
            forKey: "im2.ios.platformAuthSession"
        )
        let migrated = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)
        XCTAssertEqual(migrated.imToken, "legacy-sensitive-value")
        XCTAssertEqual(migrated.platformAuthSession, legacyAuthSession)
        XCTAssertEqual(defaults.string(forKey: "im2.ios.imToken"), "legacy-sensitive-value")
        XCTAssertNotNil(defaults.string(forKey: "im2.ios.platformAuthSession"))
    }

    func testPartialProtectedSessionWriteFailureCannotCommitColdLaunchSession() throws {
        let suiteName = "ProtectedSession.PartialWrite.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let sessionStore = InMemoryProtectedSessionStore(failingWriteNumbers: [2])
        let context = makeProtectedSessionContext()
        defer {
            IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(
            context.save(defaults: defaults, sessionStore: sessionStore),
            .committed
        )
        var rotated = context
        rotated.imToken = "rotated-im-token"
        rotated.pendingRefreshRequestID = "retry-request-2"
        XCTAssertEqual(
            rotated.save(defaults: defaults, sessionStore: sessionStore),
            .failed
        )
        let relaunched = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)
        XCTAssertTrue(relaunched.hasIMSession)
        XCTAssertEqual(relaunched.imToken, context.imToken)
        XCTAssertNil(relaunched.pendingRefreshRequestID)
        XCTAssertTrue(protectedSessionStorageKeys().allSatisfy { defaults.object(forKey: $0) == nil })
    }

    func testExplicitClearTombstonePreventsSnapshotResurrectionWhenProtectedDeleteFails() throws {
        let suiteName = "ProtectedSession.ClearTombstone.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let sessionStore = InMemoryProtectedSessionStore(failDeletes: true)
        let context = makeProtectedSessionContext()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(context.save(defaults: defaults, sessionStore: sessionStore), .committed)
        IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)

        let relaunched = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)
        XCTAssertFalse(relaunched.hasIMSession)
        XCTAssertFalse(relaunched.hasRefreshSession)
        XCTAssertGreaterThanOrEqual(sessionStore.storedValueCount, 1)
    }

    func testExplicitClearCommitsTombstoneBeforeProtectedSnapshotDeletion() throws {
        let suiteName = "ProtectedSession.ClearOrdering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        var tombstoneCommittedBeforeDelete = false
        let sessionStore = InMemoryProtectedSessionStore(onDeleteAll: {
            tombstoneCommittedBeforeDelete = defaults.object(forKey: "im2.ios.sessionClearedAt") != nil
        })
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(makeProtectedSessionContext().save(defaults: defaults, sessionStore: sessionStore), .committed)
        IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)

        XCTAssertTrue(tombstoneCommittedBeforeDelete)
        XCTAssertFalse(IMAPIContext.load(defaults: defaults, sessionStore: sessionStore).hasRefreshSession)
    }

    func testForegroundRealtimeConnectionIsStartedOnlyAfterRefreshDecision() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WenDaTong/Core/AppSupport/AppState+Realtime.swift") // WDT_IOS1_A17_REAL_PRODUCER_SOURCE_READERS_20261111
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sceneHook = try XCTUnwrap(
            source.components(separatedBy: "func iosRiskTelemetrySceneDidBecomeAvailable(isActive: Bool) {").dropFirst().first?
                .components(separatedBy: "func iosRiskScreenshotDetected() {").first
        )
        let foregroundHook = try XCTUnwrap(
            source.components(separatedBy: "func appDidEnterForeground() {").dropFirst().first?
                .components(separatedBy: "func appDidEnterBackground() {").first
        )

        XCTAssertFalse(sceneHook.contains("startRealtimeConnection"))
        let refreshOffset = try XCTUnwrap(foregroundHook.range(of: "refreshStoredAuthSessionIfNeeded")?.lowerBound)
        let realtimeOffset = try XCTUnwrap(foregroundHook.range(of: "startRealtimeConnection")?.lowerBound)
        XCTAssertLessThan(refreshOffset, realtimeOffset)
    }

    func testAuthFenceRejectsLateSameScopeResponseAfterAccountABA() {
        var original = makeProtectedSessionContext()
        original.credentialRevision = 20
        original.sessionEpoch = "epoch-a-1"
        let staleFence = original.authSessionFence

        var returnedToA = original
        returnedToA.credentialRevision = 24
        returnedToA.sessionEpoch = "epoch-a-2"
        returnedToA.tenantAuthSession = IMStoredAuthSession(
            sessionID: "tenant-session-a-2",
            refreshToken: "synthetic-tenant-refresh-a-2",
            tokenType: "im",
            tenantID: "tenant-1",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1",
            authVersion: 14,
            sessionGeneration: 9
        )

        XCTAssertFalse(returnedToA.credentialsAdvanced(since: staleFence))
        XCTAssertFalse(returnedToA.isSameAuthAuthority(as: staleFence))
        XCTAssertFalse(
            returnedToA.accepts(
                authVersion: 12,
                sessionGeneration: 7,
                for: staleFence
            )
        )

        var sameLineageAdvance = original
        sameLineageAdvance.credentialRevision = 21
        sameLineageAdvance.tenantAuthSession = IMStoredAuthSession(
            sessionID: original.tenantAuthSession?.sessionID ?? "",
            refreshToken: "synthetic-tenant-refresh-rotated",
            tokenType: "im",
            tenantID: "tenant-1",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1",
            authVersion: 1,
            sessionGeneration: 2
        )
        XCTAssertTrue(sameLineageAdvance.credentialsAdvanced(since: staleFence))
    }

    func testAuthFenceUsesActiveTenantGenerationInsteadOfLargerPlatformGeneration() {
        var context = makeProtectedSessionContext()
        context.platformAuthSession = IMStoredAuthSession(
            sessionID: "platform-session",
            refreshToken: "synthetic-platform-refresh",
            tokenType: "platform",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1",
            authVersion: 40,
            sessionGeneration: 80
        )
        context.tenantAuthSession = IMStoredAuthSession(
            sessionID: "tenant-session",
            refreshToken: "synthetic-tenant-refresh",
            tokenType: "im",
            tenantID: "tenant-1",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1",
            authVersion: 4,
            sessionGeneration: 8
        )

        let fence = context.authSessionFence

        XCTAssertEqual(fence.authorityFamily, .tenant)
        XCTAssertEqual(fence.authVersion, 4)
        XCTAssertEqual(fence.sessionGeneration, 8)
        XCTAssertTrue(
            context.accepts(
                authVersion: 4,
                sessionGeneration: 9,
                for: fence
            )
        )
    }

    func testVerifiedProtectedSessionCommitRemovesStaleClearMarkerAfterReadback() throws {
        let suiteName = "ProtectedSession.StaleClearMarker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let sessionStore = InMemoryProtectedSessionStore()
        let context = makeProtectedSessionContext()
        defer {
            IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)
            defaults.removePersistentDomain(forName: suiteName)
        }
        IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)

        XCTAssertEqual(
            context.save(defaults: defaults, sessionStore: sessionStore),
            .committed
        )
        let relaunched = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)
        XCTAssertTrue(relaunched.hasIMSession)
        XCTAssertTrue(relaunched.hasRefreshSession)
        XCTAssertEqual(relaunched.imToken, context.imToken)
    }

    func testLegacySessionMigrationRemovesDefaultsOnlyAfterProtectedWriteSucceeds() throws {
        let suiteName = "ProtectedSession.LegacyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let sessionStore = InMemoryProtectedSessionStore()
        let context = makeProtectedSessionContext()
        let legacyAuthSession = try XCTUnwrap(context.platformAuthSession)
        let legacyAuthData = try JSONEncoder().encode(legacyAuthSession)
        defer {
            IMAPIContext.clearStoredSession(defaults: defaults, sessionStore: sessionStore)
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set("legacy-sensitive-value", forKey: "im2.ios.imToken")
        defaults.set(
            try XCTUnwrap(String(data: legacyAuthData, encoding: .utf8)),
            forKey: "im2.ios.platformAuthSession"
        )

        let migrated = IMAPIContext.load(defaults: defaults, sessionStore: sessionStore)

        XCTAssertEqual(migrated.imToken, "legacy-sensitive-value")
        XCTAssertEqual(migrated.platformAuthSession, legacyAuthSession)
        XCTAssertNil(defaults.object(forKey: "im2.ios.imToken"))
        XCTAssertNil(defaults.object(forKey: "im2.ios.platformAuthSession"))
        XCTAssertEqual(sessionStore.storedValueCount, 2)
    }

    func makeProtectedSessionContext() -> IMAPIContext {
        IMAPIContext(
            platformToken: "synthetic-platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "synthetic-im-token",
            tenantAPIBaseURL: "https://tenant.example.test",
            imAPIBaseURL: "https://im.example.test",
            platformAuthSession: IMStoredAuthSession(
                sessionID: "platform-session",
                refreshToken: "synthetic-platform-refresh",
                tokenType: "platform",
                accountID: "account-1",
                appID: "jianhuitong-ios",
                deviceID: "device-1"
            ),
            tenantAuthSession: IMStoredAuthSession(
                sessionID: "tenant-session",
                refreshToken: "synthetic-tenant-refresh",
                tokenType: "im",
                tenantID: "tenant-1",
                accountID: "account-1",
                appID: "jianhuitong-ios",
                deviceID: "device-1"
            ),
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )
    }

    private func protectedSessionStorageKeys() -> [String] {
        [
            "im2.ios.platformToken",
            "im2.ios.accountID",
            "im2.ios.tenantID",
            "im2.ios.imUID",
            "im2.ios.imToken",
            "im2.ios.tenantAPIBaseURL",
            "im2.ios.imAPIBaseURL",
            "im2.ios.platformAuthSession",
            "im2.ios.tenantAuthSession"
        ]
    }
}

/// Keeps the real remembered-login store and Security calls in a test-owned namespace.
final class ScopedSystemRememberedLoginFixture {
    let credentials: KeychainRememberedLoginCredentialStore
    let preferences: UserDefaultsRememberedLoginPreferenceStore
    private let secrets: ScopedRememberedLoginSecrets
    private let scope: RememberedLoginCredentialScope
    private let defaults: UserDefaults
    private let suiteName: String

    init(context: IMAPIContext) throws {
        let suiteName = "BlueStoneIMTests.RememberedLogin." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secrets = ScopedRememberedLoginSecrets(prefix: suiteName + ".")
        self.suiteName = suiteName
        self.defaults = defaults
        self.secrets = secrets
        scope = RememberedLoginCredentialScope(context: context)
        credentials = KeychainRememberedLoginCredentialStore(defaults: defaults, secretStore: secrets)
        preferences = UserDefaultsRememberedLoginPreferenceStore(defaults: defaults)
    }

    func clear(file: StaticString = #filePath, line: UInt = #line) {
        credentials.clear(scope: scope)
        XCTAssertTrue(secrets.closeAndVerifyAbsence(), "Test-owned remembered-login items remain",
                      file: file, line: line)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class ScopedRememberedLoginSecrets: RememberedLoginSecretStoring {
    private struct Item: Hashable {
        let service: String
        let account: String
    }

    private let prefix: String
    private let store = SystemRememberedLoginSecretStore()
    private var writtenItems: Set<Item> = []
    private var isClosed = false

    init(prefix: String) {
        self.prefix = prefix
    }

    func data(service: String, account: String) -> Data? {
        store.data(service: prefix + service, account: account)
    }

    func set(_ data: Data, service: String, account: String) -> Bool {
        let service = prefix + service
        guard !isClosed, store.set(data, service: service, account: account) else { return false }
        writtenItems.insert(Item(service: service, account: account))
        return true
    }

    func delete(service: String, account: String) -> Bool {
        store.delete(service: prefix + service, account: account)
    }

    func closeAndVerifyAbsence() -> Bool {
        isClosed = true
        return writtenItems.allSatisfy { item in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var attributes: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &attributes) == errSecItemNotFound
        }
    }
}

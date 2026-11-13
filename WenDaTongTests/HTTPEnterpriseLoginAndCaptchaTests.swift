import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testWorkspaceEntryCodeURLAndUnicodeDashAreRejectedBeforeNetwork() async throws {
        let transport = FakeHTTPTransport(results: [])
        let client = makeClient(transport: transport)
        for invalid in ["https://example.test/AB001234", "AB–I00A001"] {
            do {
                _ = try await client.resolveWorkspaceEntry(
                    entryCode: invalid,
                    platformToken: "platform-token"
                )
                XCTFail("Expected entry_code_invalid for \(invalid)")
            } catch IMAPIError.businessForbidden(let code, _, _) {
                XCTAssertEqual(code, "entry_code_invalid")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            do {
                _ = try await client.prepareWorkspaceEntry(
                    tenantID: nil,
                    entryCode: invalid,
                    entrySource: "workspace_search",
                    idempotencyKey: nil,
                    platformToken: "platform-token"
                )
                XCTFail("Expected entry_code_invalid for \(invalid)")
            } catch IMAPIError.businessForbidden(let code, _, _) {
                XCTAssertEqual(code, "entry_code_invalid")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(transport.requests().isEmpty)
    }

    // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_BEGIN
    func testTenantCodeRequiredLoginScopesChallengeFeedbackAndClearsOnCancel() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","enterprise_code_first":false,"allow_workspace_switch":true,"phone_auth_enabled":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            slideCaptchaDisabledSuccess(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"tenant_code_required","message":"tenant code required"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 409
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makePreloginContext(appID: "jianhuitong-ios")
        )
        let store = state.loginTenantCodeChallengeStore
        state.startLoginFlow(identifier: "member1", password: "SyntheticPass123!", credentialMode: .account)
        try await waitForCondition { state.authScreen == .tenantCodeChallenge && !state.isAuthLoading }
        XCTAssertTrue(store.hasChallenge)
        XCTAssertEqual(store.snapshot, .init(identifier: "member1"))
        let requests = transport.requests()
        XCTAssertEqual(requests.last?.url?.path, "/api/platform/auth/im-login")
        state.submitLoginTenantCodeChallenge(enterpriseCode: "!")
        XCTAssertEqual(store.snapshot.errorMessage, RegistrationFlowPolicy.entryCodePrompt)
        XCTAssertEqual(transport.requests().count, requests.count)
        var appUpdates = 0
        var challengeUpdates = 0
        let observations = [
            state.objectWillChange.sink { appUpdates += 1 },
            store.$snapshot.dropFirst().sink { _ in challengeUpdates += 1 }
        ]
        withExtendedLifetime(observations) {
            state.loginTenantCodeChallengeInputDidChange()
            XCTAssertNil(store.snapshot.errorMessage)
            XCTAssertEqual(challengeUpdates, 1)
            XCTAssertEqual(appUpdates, 0)
        }
        state.cancelLoginTenantCodeChallenge()
        XCTAssertEqual(state.authScreen, .accountLogin)
        XCTAssertFalse(store.hasChallenge)
        XCTAssertEqual(store.snapshot, .init())
        XCTAssertFalse(state.hasActiveIMSession)
    }
    // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_END

    func testEnterpriseFirstLoginAndRegistrationSendResolvedAuthorityExactlyOnce() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200),
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"account":{}}}"#.utf8), isHTTPResponse: true, statusCode: 201),
        ])
        let client = makeClient(transport: transport)
        var context = makeContext(tenantID: "", imUID: "", imToken: "")
        context.appID = "jianhuitong-ios"
        context.deviceID = "device-1"
        _ = try await client.loginIMUser(
            username: "member1",
            password: "Demo1234",
            slideToken: nil,
            tenantCode: "WXT000001",
            enterpriseContextToken: "enterprise-proof-test-only",
            context: context
        )
        _ = try await client.register(
            username: "member2",
            phone: "",
            password: "Demo1234",
            tenantCode: "WXT000001",
            captchaCode: nil,
            enterpriseContextToken: "enterprise-proof-test-only",
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/platform/auth/im-login",
            "/api/platform/auth/register",
        ])
        for request in requests {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
            XCTAssertEqual(body["device_id"] as? String, "device-1")
            XCTAssertEqual(body["client_type"] as? String, "ios")
            XCTAssertEqual(body["tenant_code"] as? String, "WXT000001")
            XCTAssertEqual(body["enterprise_context_token"] as? String, "enterprise-proof-test-only")
        }
    }

    func testEnterpriseFirstLogoutInvalidatesResolvedContextAndRequiresFreshCode() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 7)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":true,"allow_default_tenant_join":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try enterpriseContextSuccess(routes: routes, tenantCode: "WXT000001")
        ])
        var context = makeContext(tenantID: "", imUID: "", imToken: "")
        context.platformToken = ""
        context.accountID = nil
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        XCTAssertEqual(state.authScreen, .enterpriseCode)
        let resolved = await state.resolveEnterpriseContext(enterpriseCode: "000001")
        XCTAssertTrue(resolved)
        XCTAssertTrue(state.hasUsablePreAuthEnterpriseContext)
        XCTAssertEqual(state.authScreen, .accountLogin)

        state.logout()
        XCTAssertNil(state.preAuthEnterpriseContext)
        XCTAssertFalse(state.hasUsablePreAuthEnterpriseContext)
        XCTAssertEqual(state.authScreen, .enterpriseCode)
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/platform/auth/enterprise-context/resolve" }.count, 1)
    }

    func testEnterpriseFirstRegistrationInstallsFrozenAtomicSessionAndResolvedRoutes() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 11)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try enterpriseContextSuccess(routes: routes, tenantCode: "WXT000001"),
            try atomicRegistrationSuccess(
                requestedTenantCode: "WXT000001",
                canonicalTenantCode: "WXT000001",
                routes: routes
            ),
            try tenantEnterSuccess(entryTicket: "registration-entry", routes: routes),
            try registrationTenantEntrySuccess(tenantID: "tenant-enterprise"),
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: "000001")
        XCTAssertTrue(contextResolved)
        XCTAssertEqual(state.preAuthEnterpriseContext?.tenantCode, "WXT000001")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryCode, "WXT000001")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryType, "enterprise_code")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryScheme, .legacyWXT)
        XCTAssertEqual(state.preAuthEnterpriseContext?.tenantName, "Resolved Tenant")
        XCTAssertEqual(state.preAuthEnterpriseContextStore.branding?.logoURL, "https://tenant.example.test/assets/logo.png") // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

        state.registerAndEnterIM(account: "admin14", password: "aa123456", enterpriseCode: "")
        try await waitForCondition {
            state.toast == "注册成功，已自动登录" && !state.isAuthLoading
        }
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        XCTAssertNil(state.preAuthEnterpriseContext)
        let requests = transport.requests()
        XCTAssertEqual(requests.prefix(3).map(\.url?.path), [
            "/api/platform/apps/current-policy",
            "/api/platform/auth/enterprise-context/resolve",
            "/api/platform/auth/register",
        ])
        let registerRequest = try XCTUnwrap(requests.first { $0.url?.path == "/api/platform/auth/register" })
        let registerBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(registerRequest.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(registerBody["tenant_code"] as? String, "WXT000001")
        XCTAssertEqual(registerBody["enterprise_context_token"] as? String, "enterprise-proof-test-only")
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(persisted.tenantID, "tenant-enterprise")
        XCTAssertEqual(persisted.imUID, "uid-1")
        XCTAssertEqual(persisted.imToken, "tenant-authoritative-token")
        XCTAssertEqual(persisted.tenantAPIBaseURL, routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first)
        XCTAssertEqual(persisted.imAPIBaseURL, routes.services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first)
    }

    func testEnterpriseFirstInviteRegistrationKeepsSubmittedYQMAndMatchesCanonicalTenantIdentity() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-invite", revision: 13)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try enterpriseContextSuccess(
                routes: routes,
                tenantCode: "YQM7K9P2A1B",
                canonicalTenantCode: "WXT710001"
            ),
            try atomicRegistrationSuccess(
                requestedTenantCode: "YQM7K9P2A1B",
                canonicalTenantCode: "WXT710001",
                routes: routes,
                statusCode: 201
            ),
            try tenantEnterSuccess(entryTicket: "registration-entry", routes: routes),
            try registrationTenantEntrySuccess(tenantID: "tenant-invite"),
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: " yqm7k9p2a1b ")
        XCTAssertTrue(contextResolved)
        XCTAssertEqual(state.preAuthEnterpriseContext?.tenantCode, "WXT710001")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryCode, "YQM7K9P2A1B")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryType, "member_invite_code")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryScheme, .legacyYQM)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.registerAndEnterIM(account: "admin14", password: "aa123456", enterpriseCode: "")
        try await waitForCondition {
            state.toast == "注册成功，已自动登录" && !state.isAuthLoading
        }
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        let registerRequest = try XCTUnwrap(
            transport.requests().first { $0.url?.path == "/api/platform/auth/register" }
        )
        let registerBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(registerRequest.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(registerBody["tenant_code"] as? String, "YQM7K9P2A1B")
        XCTAssertEqual(registerBody["enterprise_context_token"] as? String, "enterprise-proof-test-only")
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(persisted.tenantID, "tenant-invite")
        XCTAssertEqual(persisted.tenantAPIBaseURL, routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first)
    }

    func testEnterpriseFirstInviteRegistrationRejectsWrongCanonicalTenantCode() async throws {
        try await assertEnterpriseFirstInviteRegistrationIdentityMismatch(
            responseCanonicalTenantCode: "WXT999999",
            responseTenantID: "tenant-invite"
        )
    }

    func testEnterpriseFirstInviteRegistrationRejectsWrongTenantID() async throws {
        try await assertEnterpriseFirstInviteRegistrationIdentityMismatch(
            responseCanonicalTenantCode: "WXT710001",
            responseTenantID: "tenant-wrong"
        )
    }

    func testEnterpriseFirstInviteLoginKeepsProofBoundSubmittedYQM() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-invite", revision: 14)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try enterpriseContextSuccess(
                routes: routes,
                tenantCode: "YQM7K9P2A1B",
                canonicalTenantCode: "WXT710001"
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"enabled":false,"available":false,"required":false,"provider":"self_hosted_slide","surface":"ios","scene":"im_user_login"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_credentials","message":"invalid credentials"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
        ])
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            apiContextOverride: makePreloginContext()
        )

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: "YQM7K9P2A1B")
        XCTAssertTrue(contextResolved)
        state.startLoginFlow(identifier: "admin14", password: "aa123456")
        try await waitForCondition {
            transport.requests().contains { $0.url?.path == "/api/platform/auth/im-login" }
                && !state.isAuthLoading
        }

        let loginRequest = try XCTUnwrap(
            transport.requests().first { $0.url?.path == "/api/platform/auth/im-login" }
        )
        let loginBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(loginRequest.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(loginBody["tenant_code"] as? String, "YQM7K9P2A1B")
        XCTAssertEqual(loginBody["enterprise_context_token"] as? String, "enterprise-proof-test-only")
    }

    func testEnterpriseFirstLoginAcceptsNestedOnlySessionIdentityAndRetainsResolvedContext() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 21)
        let sessionStore = InMemoryProtectedSessionStore()
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
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: "WXT000001")
        XCTAssertTrue(policyLoaded)
        XCTAssertTrue(contextResolved)
        let resolvedContext = try XCTUnwrap(state.preAuthEnterpriseContext)

        state.startLoginFlow(identifier: "member21", password: "SyntheticPass123!")
        try await waitForCondition(iterations: 120) { state.isAuthenticated && !state.isAuthLoading }

        XCTAssertTrue(state.hasActiveIMSession)
        XCTAssertEqual(state.preAuthEnterpriseContext, resolvedContext)
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(persisted.appID, resolvedContext.appID)
        XCTAssertEqual(persisted.deviceID, resolvedContext.deviceID)
        XCTAssertEqual(persisted.tenantID, resolvedContext.tenantID)
        XCTAssertEqual(persisted.imUID, "uid-enterprise")
        XCTAssertEqual(persisted.imToken, "im-token-enterprise")
        XCTAssertEqual(persisted.tenantAuthSession?.appID, resolvedContext.appID)
        XCTAssertEqual(persisted.tenantAuthSession?.deviceID, resolvedContext.deviceID)
        XCTAssertEqual(persisted.tenantAuthSession?.tenantID, resolvedContext.tenantID)
        XCTAssertEqual(state.preAuthEnterpriseContext?.routeRevision, routes.revision)
        XCTAssertEqual(state.preAuthEnterpriseContext?.runtimeRoutes, routes)
    }

    func testEnterpriseFirstLoginRejectsTopLevelAndNestedSessionIdentityConflict() async throws {
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 22)

        try await assertEnterpriseFirstLoginRejected(
            resolvedRoutes: routes,
            loginResult: atomicEnterpriseLoginSuccess(
                routes: routes,
                topLevelAppID: routes.appID,
                topLevelDeviceID: "device-1",
                nestedAppID: "ios-conflicting-app"
            )
        )
    }

    func testEnterpriseFirstLoginRejectsEveryFrozenSessionAndRuntimeAuthorityMismatch() async throws {
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 23)
        let wrongRevisionRoutes = runtimeRouteSnapshotForHTTPWiring(
            tenantID: "tenant-enterprise",
            revision: routes.revision + 1
        )
        let wrongTopologyRoutes = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant-other.example.test"],
            tenantID: "tenant-enterprise",
            revision: routes.revision
        )
        let wrongHashRoutes = IMRuntimeRouteSnapshot(
            contractVersion: routes.contractVersion,
            appID: routes.appID,
            tenantID: routes.tenantID,
            revision: routes.revision,
            source: routes.source,
            status: routes.status,
            configHash: String(repeating: "0", count: 64),
            services: routes.services,
            policy: routes.policy
        )
        let mismatchedResults = try [
            atomicEnterpriseLoginSuccess(routes: routes, nestedAppID: "ios-other"),
            atomicEnterpriseLoginSuccess(routes: routes, nestedDeviceID: "device-other"),
            atomicEnterpriseLoginSuccess(
                routes: routes,
                nestedTenantID: "tenant-other",
                responseTenantID: "tenant-other"
            ),
            atomicEnterpriseLoginSuccess(routes: wrongRevisionRoutes),
            atomicEnterpriseLoginSuccess(routes: wrongTopologyRoutes),
            atomicEnterpriseLoginSuccess(routes: wrongHashRoutes),
        ]

        for loginResult in mismatchedResults {
            try await assertEnterpriseFirstLoginRejected(
                resolvedRoutes: routes,
                loginResult: loginResult
            )
        }
    }

    func testEnterpriseFirstPendingLoginRemainsPlatformOnlyAndNonAuthenticated() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 24)
        let sessionStore = InMemoryProtectedSessionStore()
        let transport = FakeHTTPTransport(results: [
            enterpriseFirstPolicySuccess(),
            try enterpriseContextSuccess(routes: routes, tenantCode: "WXT000001"),
            slideCaptchaDisabledSuccess(),
            try enterprisePendingLoginSuccess(routes: routes),
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
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: "WXT000001")
        XCTAssertTrue(policyLoaded)
        XCTAssertTrue(contextResolved)
        state.startLoginFlow(identifier: "member24", password: "SyntheticPass123!")
        try await waitForCondition(iterations: 120) {
            state.toast == "入企申请等待审批中，审核通过后请重新登录。" && !state.isAuthLoading
        }

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertNil(state.preAuthEnterpriseContext)
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertFalse(persisted.hasIMSession)
        XCTAssertEqual(persisted.platformToken, "platform-token-enterprise")
    }

    func testDefaultFallbackRegistrationPrefersRuntimeConfigV2OverInsecureLegacySessionServer() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let insecureLegacyTenantAPIBaseURL = "http://tenant-internal.example.test:8082"
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-default", revision: 12)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":false,"allow_default_tenant_join":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try atomicRegistrationSuccess(
                requestedTenantCode: "",
                canonicalTenantCode: "WXT000001",
                routes: routes,
                legacyTenantAPIBaseURL: insecureLegacyTenantAPIBaseURL,
                fallbackToDefaultTenant: true,
                statusCode: 201
            ),
            try tenantEnterSuccess(entryTicket: "registration-entry", routes: routes),
            try registrationTenantEntrySuccess(tenantID: "tenant-default"),
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.registerWithDefaultEnterprise(account: "admin14", password: "aa123456")
        try await waitForCondition {
            state.toast == "注册成功，已自动登录" && !state.isAuthLoading
        }

        XCTAssertNil(
            IMAPIClient.normalizedTenantAPIBaseURL(
                insecureLegacyTenantAPIBaseURL,
                allowLocalOrInsecure: false
            )
        )
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(persisted.tenantID, "tenant-default")
        XCTAssertEqual(
            persisted.tenantAPIBaseURL,
            routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first
        )
        XCTAssertEqual(
            persisted.imAPIBaseURL,
            routes.services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first
        )
        XCTAssertNotEqual(persisted.tenantAPIBaseURL, insecureLegacyTenantAPIBaseURL)
    }

    func testDefaultFallbackRegistrationWithoutRuntimeConfigStaysPendingForUnsafeLegacySessionServer() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let insecureLegacyTenantAPIBaseURL = "http://tenant-internal.example.test:8082"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":false,"allow_default_tenant_join":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try atomicRegistrationSuccess(
                requestedTenantCode: "",
                canonicalTenantCode: "WXT000001",
                legacyTenantAPIBaseURL: "http://user:password@tenant-internal.example.test:8082",
                fallbackToDefaultTenant: true,
                statusCode: 201
            ),
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.registerWithDefaultEnterprise(account: "admin14", password: "aa123456")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }

        XCTAssertNil(
            IMAPIClient.normalizedTenantAPIBaseURL(
                insecureLegacyTenantAPIBaseURL,
                allowLocalOrInsecure: false
            )
        )
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertFalse(IMAPIContext.load(sessionStore: sessionStore).hasIMSession)
        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage)
        XCTAssertTrue(state.isRegistrationSubmissionBlocked)
    }

    func testRegistrationDisabledBlocksCaptchaAndRegisterBeforeNetwork() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":false,"enterprise_code_first":false,"allow_default_tenant_join":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        XCTAssertFalse(state.isRegistrationEnabledForAuthUI)
        let cooldown = await state.sendRegisterCaptcha(phone: "13800138000")
        XCTAssertNil(cooldown)
        state.registerWithDefaultEnterprise(account: "member1", password: "Demo1234")

        XCTAssertEqual(state.authScreen, .accountLogin)
        XCTAssertEqual(state.toast, EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage)
        XCTAssertEqual(transport.requests().count, 1)
    }

    func testEnterprisePolicyLastGoodRoundTripPreservesGatesAndPreferredHint() throws {
        let suiteName = "EnterprisePolicyLastGood.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = RemoteAppCurrentPolicy(
            appID: "jianhuitong-ios",
            platform: "ios",
            status: "active",
            allowWorkspaceSwitch: true,
            allowDefaultTenantJoin: true,
            registrationEnabled: false,
            enterpriseCodeFirst: true,
            preferredEnterpriseCode: "WXT000001",
            cacheTTLSeconds: 300
        )

        IMAppPolicyLastGoodStore.save(policy, appID: policy.appID, defaults: defaults)

        let restored = try XCTUnwrap(IMAppPolicyLastGoodStore.usable(appID: policy.appID, defaults: defaults))
        XCTAssertFalse(restored.policy.registrationEnabled)
        XCTAssertTrue(restored.policy.enterpriseCodeFirst)
        XCTAssertEqual(restored.policy.preferredEnterpriseCode, "WXT000001")
    }

    func testEnterprisePolicyLastGoodRoutesFailClosedWithoutAutoResolvingStalePreferredCode() {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        var context = makeContext(tenantID: "", imUID: "", imToken: "")
        context.platformToken = ""
        context.accountID = nil
        let policy = RemoteAppCurrentPolicy(
            appID: context.appID,
            platform: "ios",
            status: "active",
            allowWorkspaceSwitch: true,
            allowDefaultTenantJoin: true,
            registrationEnabled: true,
            enterpriseCodeFirst: true,
            preferredEnterpriseCode: "WXT000001",
            cacheTTLSeconds: 300
        )
        let savedAt = Date(timeIntervalSinceNow: -TimeInterval(policy.cacheTTLSeconds) - 1)
        IMAppPolicyLastGoodStore.save(policy, appID: context.appID, now: savedAt)
        let cachedPolicy = IMAppPolicyLastGoodStore.usable(appID: context.appID)
        XCTAssertEqual(cachedPolicy?.isOnlineFresh, false)
        XCTAssertEqual(cachedPolicy?.policy.preferredEnterpriseCode, "WXT000001")
        let transport = FakeHTTPTransport(results: [])

        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context,
            launchUnitTestOverride: false
        )

        XCTAssertEqual(state.authScreen, .enterpriseCode)
        XCTAssertNil(state.preAuthEnterpriseContext)
        XCTAssertTrue(transport.requests().isEmpty)

        var authenticatedContext = makeContext()
        authenticatedContext.appID = context.appID
        let authenticatedState = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: []), runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: authenticatedContext
        )
        authenticatedState.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        authenticatedState.logout()
        XCTAssertEqual(authenticatedState.authScreen, .enterpriseCode)
        XCTAssertNil(authenticatedState.preAuthEnterpriseContext)
    }

    func testIMUserSlideCaptchaUsesPlatformEndpoints() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"enabled":true,"available":true,"required":true,"provider":"self_hosted_slide","surface":"ios","app_id":"jianhuitong-ios","scene":"im_user_login","token_ttl_seconds":120}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"provider":"self_hosted_slide","challenge_id":"challenge-1","background_image":"bg","piece_image":"piece","piece_y":42,"width":320,"height":160,"piece_size":48,"challenge_ttl_seconds":120}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"slide_token":"slide-token-redacted"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let config = try await client.slideCaptchaConfig(scene: "im_user_login", surface: "ios", appID: "jianhuitong-ios")
        _ = try await client.slideCaptchaChallenge(scene: "im_user_login", surface: "ios")
        let ticket = SlideCaptchaTicket(
            ticket: "ticket",
            randstr: "rand",
            challengeID: "challenge-1",
            lotNumber: "",
            captchaOutput: "output",
            passToken: "pass",
            genTime: "123",
            extra: [:]
        )
        _ = try await client.verifySlideCaptcha(SlideCaptchaVerifyRequest(scene: "im_user_login", config: config, ticket: ticket))

        let requests = transport.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://platform.example.test/api/platform/captcha/slide/config?scene=im_user_login&surface=ios&app_id=jianhuitong-ios")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://platform.example.test/api/platform/captcha/slide/challenge")
        XCTAssertEqual(requests[2].url?.absoluteString, "https://platform.example.test/api/platform/captcha/slide/verify")
    }
}

import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testRegistrationLeavingForLoginDetachesPendingEvenWhenLoginFails() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let pendingStatus = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"status":"PENDING"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
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
            pendingStatus
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            registrationSleep: { _ in try await Task.sleep(nanoseconds: 200_000_000) },
            apiContextOverride: makePreloginContext()
        )
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationResolutionState == .pending && !state.isAuthLoading }
        state.startLoginFlow(identifier: "admin11", password: "wrong-password", credentialMode: .account)
        try await waitForCondition { !state.isAuthLoading && state.toast?.contains("账号或密码") == true }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/platform/auth/register/status" })
        XCTAssertNil(state.registrationResolutionState)
        XCTAssertFalse(state.isRegistrationSubmissionBlocked)
        XCTAssertFalse(state.isAuthenticated)
        let statusCountAtLogout = transport.requests().filter {
            $0.url?.path == "/api/platform/auth/register/status"
        }.count
        state.logout()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path == "/api/platform/auth/register/status" }.count,
            statusCountAtLogout
        )
    }

    func testRegistrationSuccessfulLoginCancelsConfirmationAndLateStatusCannotClearSession() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = DelayedRegistrationStatusHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"enabled":false,"available":false,"required":false,"provider":"self_hosted_slide","surface":"ios","scene":"im_user_login"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"admin11","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session","refresh_token":"platform-refresh","expires_at":1785200000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"requires_workspace_selection":false,"can_direct_enter":true,"auto_entered_workspace_id":"tenant-default","entry_status":"entered","tenant":{"tenant_id":"tenant-default","tenant_code":"WXT553222","name":"Default Tenant","status":"active"},"session":{"im_uid":"uid-default","im_token":"im-token-default","app_id":"jianhuitong-ios","device_id":"device-1","expires_at":1785200000,"auth_session":{"session_id":"tenant-session","refresh_token":"tenant-refresh","expires_at":1785200000,"tenant_id":"tenant-default","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"im"}}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ], statusDelayNanoseconds: 500_000_000)
        let context = makePreloginContext()
        let rememberedLogin = try ScopedSystemRememberedLoginFixture(context: context)
        let state = AppState(
            api: makeClient(transport: transport),
            registrationSleep: { _ in },
            rememberedLoginCredentialStore: rememberedLogin.credentials,
            rememberedLoginPreferenceStore: rememberedLogin.preferences,
            apiContextOverride: context
        )
        defer {
            state.authFlowGeneration.invalidate()
            rememberedLogin.clear()
        }
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            transport.requests().contains { $0.url?.path == "/api/platform/auth/register/status" }
        }
        state.startLoginFlow(identifier: "admin11", password: "aa123456", credentialMode: .account)
        try await waitForCondition { state.isAuthenticated && !state.isAuthLoading }
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertNil(state.registrationResolutionState)
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count,
            1
        )
        state.logout()
    }

    func testRegistrationConfirmationTimesOutAfterFiveMinutesWithoutResubmit() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let clock = RegistrationTestClock()
        let pendingStatus = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"status":"PENDING"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ] + Array(repeating: pendingStatus, count: RegistrationConfirmationPolicy.sleepDelaysSeconds().count))
        let state = AppState(
            api: makeClient(transport: transport),
            registrationNow: { clock.now() },
            registrationSleep: { seconds in clock.advance(by: seconds) },
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationConfirmationTimedOut }

        XCTAssertEqual(clock.delays(), RegistrationConfirmationPolicy.sleepDelaysSeconds())
        XCTAssertEqual(clock.now(), RegistrationConfirmationPolicy.totalConfirmationSeconds)
        XCTAssertEqual(state.registrationResolutionState, .pending)
        XCTAssertFalse(state.isRegistrationSubmissionBlocked)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.timeoutMessage)
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count,
            1
        )
    }

    func testRegistrationHistoricalReceiptsNeverLockOrResumeAnOldRequest() async throws {
        for age in [20.0, 260.0, 400.0, 700.0] {
            for resolution in [RegistrationResolutionState.pending, .failed] {
                clearStoredAPIContext()
                defer { clearStoredAPIContext() }
                let original = PendingRegistrationReceipt(requestID: UUID().uuidString.lowercased(),
                    appID: "jianhuitong-ios", deviceID: "device-1", failureScreen: "phone",
                    startedAt: 10, resolutionState: resolution)
                var receiptBytes: Data? = try JSONEncoder().encode(original)
                let store = PendingRegistrationReceiptStore(readData: { receiptBytes }, writeData: { receiptBytes = $0 })
                let conflict = registrationDiagnosticResponse(#"{"ok":false,"error":{"code":"conflict","message":"username already exists"}}"#, status: 409)
                let transport = FakeHTTPTransport(results: [activeAppPolicyResult(), conflict])
                let state = AppState(api: makeClient(transport: transport), registrationNow: { age },
                    pendingRegistrationReceiptStore: store, registrationSessionStore: InMemoryProtectedSessionStore(),
                    apiContextOverride: makePreloginContext())
                defer { state.logout() }
                XCTAssertNil(state.registrationResolutionState)
                XCTAssertFalse(state.isRegistrationSubmissionBlocked)
                XCTAssertEqual(state.registrationSubmitButtonTitle, "注册并继续")
                XCTAssertTrue(transport.requests().isEmpty)
                XCTAssertEqual(store.load(), original)
                _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
                state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
                try await waitForCondition { state.registrationResolutionState == .failed && !state.isAuthLoading }
                let posts = transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }
                XCTAssertEqual(posts.count, 1)
                XCTAssertNotEqual(posts.first?.value(forHTTPHeaderField: "Idempotency-Key"), original.requestID)
                XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/register/status") == true })
                XCTAssertEqual(state.toast, "注册未通过，请检查填写内容；仍无法完成请联系管理员。")
                XCTAssertFalse(state.isAuthenticated)
            }
        }
    }

    func testRegistrationUnknownScopeAndLegacyReceiptsDoNotBlockOrQuery() throws {
        for data in [
            Data(#"{"requestID":"old-request","failureScreen":"account","startedAt":10}"#.utf8),
            try JSONEncoder().encode(PendingRegistrationReceipt(requestID: "other-request", appID: "other-app",
                deviceID: "other-device", failureScreen: "account", startedAt: 10))
        ] {
            var bytes: Data? = data
            let store = PendingRegistrationReceiptStore(readData: { bytes }, writeData: { bytes = $0 })
            let transport = FakeHTTPTransport(results: [])
            let state = AppState(api: makeClient(transport: transport), pendingRegistrationReceiptStore: store,
                registrationSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: makePreloginContext())
            XCTAssertNil(state.registrationResolutionState)
            XCTAssertFalse(state.isRegistrationSubmissionBlocked)
            XCTAssertTrue(transport.requests().isEmpty)
            XCTAssertEqual(bytes, data)
        }
    }

    func testDefaultEnterpriseRegistrationSharesSubmissionAndCancellationOwnership() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let policy = registrationDiagnosticResponse(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_default_tenant_join":true,"cache_ttl_seconds":60}}"#)
        let transport = HangingRegistrationHTTPTransport(policyResult: policy)
        let state = AppState(api: makeClient(transport: transport),
            registrationSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: makePreloginContext())
        defer { state.logout(); transport.releaseRegistration() }
        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        state.registerWithDefaultEnterprise(account: "admin11", password: "aa123456")
        state.registerWithDefaultEnterprise(account: "admin11", password: "aa123456")
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        XCTAssertTrue(state.isRegistrationSubmissionBlocked)
        try await waitForCondition { transport.registrationRequestCount() == 1 }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.registrationRequest()?.httpBody)) as? [String: Any])
        XCTAssertNil(payload["tenant_code"])
        state.registrationFormDidChange()
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("current default form")
        transport.releaseRegistration()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(state.isRegistrationSubmissionBlocked)
        XCTAssertNil(state.registrationResolutionState)
        XCTAssertEqual(state.toast, "current default form")
        XCTAssertEqual(transport.registrationRequestCount(), 1)
        XCTAssertFalse(state.isAuthenticated)
    }

    func testRegistrationDoubleClickOnlySubmitsOnceAndFormEditDiscardsLatePost() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = HangingRegistrationHTTPTransport(policyResult: activeAppPolicyResult())
        let state = AppState(api: makeClient(transport: transport),
            registrationSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: makePreloginContext())
        defer { state.logout(); transport.releaseRegistration() }
        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        XCTAssertTrue(state.isRegistrationSubmissionBlocked)
        try await waitForCondition { transport.registrationRequestCount() == 1 }
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(transport.registrationRequestCount(), 1)
        state.registrationFormDidChange()
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("current form")
        XCTAssertFalse(state.isRegistrationSubmissionBlocked)
        transport.releaseRegistration()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(state.registrationResolutionState)
        XCTAssertEqual(state.toast, "current form")
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(transport.registrationRequestCount(), 1)
    }

    func testRegistrationExplicitFormEditFencesLateOldStatusAndKeepsCurrentFailure() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = DelayedRegistrationStatusHTTPTransport(results: [activeAppPolicyResult(),
            registrationDiagnosticResponse("unavailable", status: 503),
            registrationDiagnosticResponse(#"{"ok":false,"error":{"code":"conflict","message":"username already exists"}}"#, status: 409)
        ], statusDelayNanoseconds: 300_000_000)
        let state = AppState(api: makeClient(transport: transport), registrationSleep: { _ in },
            registrationSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: makePreloginContext())
        defer { state.logout() }
        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { !state.isAuthLoading && transport.requests().contains { $0.url?.path.hasSuffix("/register/status") == true } }
        XCTAssertTrue(state.isRegistrationSubmissionBlocked)
        state.registrationFormDidChange()
        XCTAssertFalse(state.isRegistrationSubmissionBlocked)
        state.registerAndEnterIM(account: "admin12", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationResolutionState == .failed && !state.isAuthLoading }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(state.registrationResolutionState, .failed)
        XCTAssertEqual(state.toast, "注册未通过，请检查填写内容；仍无法完成请联系管理员。")
        XCTAssertFalse(state.isAuthenticated)
        let posts = transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertNotEqual(posts[0].value(forHTTPHeaderField: "Idempotency-Key"), posts[1].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/register/session") == true })
    }

    func testRegistrationFailedStatusNeverLocksEvenWhenReceiptCleanupFails() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        var receiptBytes: Data?
        let store = PendingRegistrationReceiptStore(readData: { receiptBytes }, writeData: { value in
            if receiptBytes == nil { receiptBytes = value }
        })
        let transport = FakeHTTPTransport(results: [activeAppPolicyResult(),
            registrationDiagnosticResponse("unavailable", status: 503),
            registrationDiagnosticResponse(#"{"ok":true,"data":{"status":"FAILED"}}"#)])
        let state = AppState(api: makeClient(transport: transport), registrationSleep: { _ in },
            pendingRegistrationReceiptStore: store, registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makePreloginContext())
        defer { state.logout() }
        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationResolutionState == .failed && !state.isAuthLoading }
        XCTAssertEqual(state.toast, "注册失败，请重新提交注册")
        XCTAssertFalse(state.isRegistrationSubmissionBlocked)
        XCTAssertEqual(store.load()?.resolutionState, .pending)
        let restarted = AppState(api: makeClient(transport: FakeHTTPTransport(results: [])),
            pendingRegistrationReceiptStore: store, registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makePreloginContext())
        XCTAssertNil(restarted.registrationResolutionState)
        XCTAssertFalse(restarted.isRegistrationSubmissionBlocked)
    }

    func testRegistrationStatusResponseCrossingDeadlineCannotBecomeSuccess() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let suiteName = "HTTPTransportTests.registration.slow-status.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingRegistrationReceiptStore(defaults: defaults)
        let clock = RegistrationTestClock()
        let transport = RegistrationStatusClockAdvancingTransport(clock: clock, responseElapsed: 299,
            policyResult: activeAppPolicyResult())
        let state = AppState(
            api: makeClient(transport: transport),
            registrationNow: { clock.now() },
            registrationSleep: { seconds in clock.advance(by: seconds) },
            pendingRegistrationReceiptStore: store,
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }

        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationConfirmationTimedOut }
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/platform/auth/register/status" }.count, 1)
        XCTAssertEqual(clock.now(), 301)
        XCTAssertEqual(state.registrationResolutionState, .pending)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNotNil(store.load())
    }

    func testRegistrationPersistsPendingIdentityBeforeInFlightRequestCompletes() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let suiteName = "HTTPTransportTests.registration.inflight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let transport = HangingRegistrationHTTPTransport(policyResult: activeAppPolicyResult())
        let firstState = AppState(
            api: makeClient(transport: transport),
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            apiContextOverride: makePreloginContext()
        )
        let policyLoaded = await firstState.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        firstState.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { transport.registrationRequestCount() == 1 }
        let receipt = try XCTUnwrap(PendingRegistrationReceiptStore(defaults: defaults).load())
        XCTAssertEqual(
            receipt.requestID,
            transport.registrationRequest()?.value(forHTTPHeaderField: "Idempotency-Key")
        )

        let restartedTransport = FakeHTTPTransport(results: [])
        let restartedState = AppState(
            api: makeClient(transport: restartedTransport),
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            apiContextOverride: makePreloginContext()
        )
        XCTAssertNil(restartedState.registrationResolutionState)
        XCTAssertFalse(restartedState.isRegistrationSubmissionBlocked)
        XCTAssertTrue(restartedTransport.requests().isEmpty)

        transport.releaseRegistration()
        restartedState.logout()
        firstState.logout()
    }

    func testRegistrationDoesNotSendWhenPendingReceiptCannotBePersisted() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [activeAppPolicyResult()])
        let failingStore = PendingRegistrationReceiptStore(
            readData: { nil },
            writeData: { _ in }
        )
        let state = AppState(
            api: makeClient(transport: transport),
            pendingRegistrationReceiptStore: failingStore,
            apiContextOverride: makePreloginContext()
        )
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationResolutionState == .failed && !state.isAuthLoading }

        XCTAssertEqual(state.toast, "注册暂时无法安全提交，请稍后重试")
        XCTAssertTrue(transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.isEmpty)
    }

    func testRegistrationExplicit4xxStartsCorrectedRetryWithNewRequestIdentifier() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let conflict = HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"account_username_exists","message":"username already exists"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 409
        )
        let transport = FakeHTTPTransport(results: [activeAppPolicyResult(), conflict, conflict])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makePreloginContext())
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .failed && !state.isAuthLoading
        }
        XCTAssertEqual(state.registrationSubmitButtonTitle, "注册并继续")
        XCTAssertEqual(state.toast, "账号已存在，请登录或更换账号。")
        XCTAssertFalse(state.toast?.hasPrefix("注册失败：") == true)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count == 2
                && !state.isAuthLoading
        }
        let registrationRequests = transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }
        XCTAssertEqual(registrationRequests.count, 2)
        XCTAssertNotEqual(
            registrationRequests[0].value(forHTTPHeaderField: "Idempotency-Key"),
            registrationRequests[1].value(forHTTPHeaderField: "Idempotency-Key")
        )
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/platform/auth/im-login" })
    }

    func testRegistrationExplicit4xxDoesNotExposeServerCodeOrEnglishMessage() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"opaque_business_rule","message":"backend English detail must stay private"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 422
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: makePreloginContext()
        )
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .failed && !state.isAuthLoading
        }

        let message = try XCTUnwrap(state.toast)
        XCTAssertEqual(message, "注册未通过，请检查填写内容；仍无法完成请联系管理员。")
        XCTAssertFalse(message.contains("opaque_business_rule"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("backend English"))
    }

    func testRegistrationOfflineTimeoutAndNonJSONResponsesAreUncertain() async throws {
        let outcomes: [HTTPTransport] = [
            FailingHTTPTransport(error: URLError(.notConnectedToInternet)),
            FailingHTTPTransport(error: URLError(.timedOut)),
            FakeHTTPTransport(results: [
                HTTPTransportResult(
                    data: Data("upstream unavailable".utf8),
                    isHTTPResponse: true,
                    statusCode: 503
                )
            ]),
            FakeHTTPTransport(results: [
                HTTPTransportResult(
                    data: Data("not-json".utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ])
        ]

        for transport in outcomes {
            let client = makeClient(transport: transport)
            do {
                _ = try await client.registerWithRequestID(
                    username: "admin11",
                    phone: "",
                    password: "aa123456",
                    tenantCode: "WXT553222",
                    captchaCode: nil,
                    enterpriseContextToken: nil,
                    appID: "jianhuitong-ios",
                    deviceID: "device-1",
                    requestID: "registration-test-request"
                )
                XCTFail("Expected uncertain registration outcome")
            } catch is RegistrationOutcomeUncertainError {
                // Expected: the client cannot safely infer success or failure.
            } catch {
                XCTFail("Unexpected error: \(type(of: error))")
            }
        }
    }

    func testRegistrationMapsMissingEnterpriseCodeToFriendlyToast() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"tenant_code_not_found","message":"tenant code not found"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 404
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: makePreloginContext()
        )
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        for _ in 0..<40 where state.toast != "该企业不存在，请检查企业编码。" {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(state.toast, "该企业不存在，请检查企业编码。")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        let registerRequest = try XCTUnwrap(requests.dropFirst().first)
        XCTAssertEqual(registerRequest.url?.absoluteString, "https://platform.example.test/api/platform/auth/register")
        let bodyData = try XCTUnwrap(registerRequest.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["tenant_code"] as? String, "WXT553222")
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
    }

    func testRegistrationQuotaExceededStaysOnRegisterPageWithFriendlyToast() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"registered_user_quota_exceeded","message":"quota reached"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 409
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makePreloginContext())
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin19", password: "aa123456", enterpriseCode: "WXT553222")
        try await waitForCondition {
            state.toast == "当前企业注册用户数已达上限，请联系企业管理员" && !state.isAuthLoading
        }

        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.debugHasIMSessionForTesting())
    }

    func testRegistrationInviteCodeUsesUnifiedTenantCodeFieldAndAutomaticallyEnters() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try atomicRegistrationSuccess(
                requestedTenantCode: "YQM7K9P2A1B",
                canonicalTenantCode: "WXT710001"
            ),
            try tenantEnterSuccess(entryTicket: "registration-entry", routes: runtimeRouteSnapshotForHTTPWiring()),
            try registrationTenantEntrySuccess(tenantID: "tenant-1")
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin12", password: "aa123456", enterpriseCode: " yqm7k9p2a1b ")
        try await waitForCondition {
            state.toast == "注册成功，已自动登录" && !state.isAuthLoading
        }

        XCTAssertFalse(state.isAuthLoading)
        XCTAssertEqual(state.toast, "注册成功，已自动登录")
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        let requests = transport.requests()
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        let registerRequest = try XCTUnwrap(requests.first { $0.url?.path == "/api/platform/auth/register" })
        XCTAssertEqual(registerRequest.url?.absoluteString, "https://platform.example.test/api/platform/auth/register")
        let bodyData = try XCTUnwrap(registerRequest.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["tenant_code"] as? String, "YQM7K9P2A1B")
        XCTAssertNil(body["member_invite_code"])
        XCTAssertNil(body["invite_code"])
        XCTAssertNil(body["inviteCode"])
        XCTAssertNil(body["code"])
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/platform/me/tenants/tenant-1/enter" })
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/tenant/auth/platform-entry" })
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/switch") == true })
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(persisted.tenantID, "tenant-1")
        XCTAssertEqual(persisted.imUID, "uid-1")
        XCTAssertEqual(persisted.imToken, "tenant-authoritative-token")
        XCTAssertEqual(persisted.tenantAPIBaseURL, runtimeRouteSnapshotForHTTPWiring().services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first)
        XCTAssertEqual(persisted.imAPIBaseURL, runtimeRouteSnapshotForHTTPWiring().services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first)
    }

    func testRegistrationDoesNotActivateInlineIMWhileTenantEntryIsPending() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let routes = runtimeRouteSnapshotForHTTPWiring()
        let transport = SessionReauthenticationRouteGateTransport(responses: [
            "/api/platform/apps/current-policy": activeAppPolicyResult(),
            "/api/platform/auth/register": try atomicRegistrationSuccess(requestedTenantCode: "WXT553222", canonicalTenantCode: "WXT553222"),
            "/api/platform/me/tenants/tenant-1/enter": try tenantEnterSuccess(entryTicket: "registration-entry", routes: routes),
            "/api/tenant/auth/platform-entry": try registrationTenantEntrySuccess(tenantID: "tenant-1")
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
                             protectedSessionStore: sessionStore, registrationSessionStore: InMemoryProtectedSessionStore(),
                             apiContextOverride: makePreloginContext())
        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        state.registerAndEnterIM(account: "fixture58", password: "fixture-password", enterpriseCode: "WXT553222")
        try await waitForCondition { transport.entryRequestCount == 1 }
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        let pending = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(pending.platformToken, "platform-token-redacted")
        XCTAssertNil(pending.imToken)
        XCTAssertNil(pending.tenantAuthSession)
        transport.releaseEntry()
        try await waitForCondition { state.registrationResolutionState == .success }
        let committed = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(committed.imToken, "tenant-authoritative-token")
        XCTAssertEqual(committed.tenantAuthSession?.sessionID, "trs_registration")
    }

    func testRegistrationRejectedEntryTicketDoesNotFallbackOrDiscardPlatformAuthority() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            try atomicRegistrationSuccess(requestedTenantCode: "WXT553222", canonicalTenantCode: "WXT553222"),
            try tenantEnterSuccess(entryTicket: "registration-entry", routes: runtimeRouteSnapshotForHTTPWiring()),
            HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"entry_ticket_invalid","message":"invalid entry_ticket"}}"#.utf8),
                                isHTTPResponse: true, statusCode: 401),
            try tenantEnterSuccess(entryTicket: "registration-retry-entry", routes: runtimeRouteSnapshotForHTTPWiring()),
            try registrationTenantEntrySuccess(tenantID: "tenant-1")
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
                             protectedSessionStore: sessionStore, registrationSessionStore: InMemoryProtectedSessionStore(),
                             apiContextOverride: makePreloginContext())
        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        state.registerAndEnterIM(account: "fixture58", password: "fixture-password", enterpriseCode: "WXT553222")
        try await waitForCondition { state.registrationConfirmationTimedOut && !state.isAuthLoading }
        XCTAssertEqual(state.registrationResolutionState, .pending)
        XCTAssertFalse(state.isAuthenticated)
        let committed = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(committed.platformToken, "platform-token-redacted")
        XCTAssertNil(committed.imToken)
        XCTAssertNil(committed.tenantAuthSession)
        XCTAssertFalse(state.isRegistrationSubmissionBlocked)
        XCTAssertEqual(state.registrationSubmitButtonTitle, "注册并继续")
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/tenant/auth/platform-entry" }.count, 1)
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/platform/auth/register/session" })
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count, 1)
        state.logout()
    }
}

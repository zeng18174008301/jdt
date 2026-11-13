import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_BEGIN
    func testEnterpriseSearchIgnoresResponseFromClearedQuery() async throws {
        let transport = EnterpriseSearchResponseGate()
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        let store = state.enterpriseDirectoryStore
        var changes: [EnterpriseDirectoryStore.Snapshot] = []
        let subscription = store.$snapshot.sink { changes.append($0) }
        defer {
            subscription.cancel()
            transport.close()
        }

        state.searchEnterprises(query: "OLD")
        try await waitForCondition { transport.isPending("OLD") }
        XCTAssertTrue(transport.isPending("OLD"))
        state.clearEnterpriseSearch()
        XCTAssertFalse(store.snapshot.isSearching)
        XCTAssertTrue(store.snapshot.results.isEmpty)

        state.searchEnterprises(query: "NEW")
        try await waitForCondition { transport.isPending("NEW") }
        guard transport.isPending("NEW") else { return XCTFail("新搜索应等待响应") }
        transport.release("OLD")
        transport.release("NEW")
        try await waitForCondition { store.snapshot.results.first?.id == "NEW" }
        XCTAssertEqual(store.snapshot.results.map(\.id), ["NEW"])
        XCTAssertFalse(store.snapshot.isSearching)
        XCTAssertTrue(changes.flatMap(\.results).allSatisfy { $0.id == "NEW" })
        XCTAssertEqual(changes.map(\.isSearching), [false, true, false, true, false])
    }

    func testEnterpriseJoinProgressSurvivesSearchAndRejectsOldCleanup() throws {
        let state = AppState(apiContextOverride: makeContext())
        let store = state.enterpriseDirectoryStore
        let first = try XCTUnwrap(store.beginJoin(key: "id:target"))
        XCTAssertNil(store.beginJoin(key: "id:target"))
        let request = store.beginSearch()
        store.clearSearch()
        store.finishSearch(request)
        XCTAssertTrue(store.snapshot.isJoining("id:target"))
        XCTAssertFalse(store.snapshot.isSearching)

        store.reset()
        let replacement = try XCTUnwrap(store.beginJoin(key: "id:target"))
        store.finishJoin(first, key: "id:target")
        XCTAssertTrue(store.snapshot.isJoining("id:target"))
        store.finishJoin(replacement, key: "id:target")
        XCTAssertFalse(store.snapshot.isJoining("id:target"))
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_END

    func testPolicyDrivenRegistrationCopyAndEnterpriseSwitcherState() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","status":"active","allow_workspace_switch":false,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let state = AppState(api: client)

        let didLoadPolicy = await state.refreshCurrentAppPolicyForAuthUI()

        XCTAssertTrue(didLoadPolicy)
        XCTAssertTrue(state.isRegistrationTenantCodeRequired)
        XCTAssertEqual(state.registrationTenantCodeRequirementText, "注册时必须填写企业编码或邀请码")
        XCTAssertFalse(state.registrationTenantCodeRequirementText.contains("默认企业"))
        XCTAssertFalse(state.registrationTenantCodeRequirementText.contains("可不填"))

        let enterprise = Enterprise(
            id: "tenant-1",
            name: "测试企业",
            code: "WXT123456",
            role: "member",
            status: "已加入",
            memberCount: 3,
            isDefault: false,
            accentHex: 0x5D6BFF,
            canSwitch: true,
            enterable: true
        )
        XCTAssertFalse(state.canOpenEnterpriseSwitcher(for: enterprise))
        XCTAssertEqual(state.enterpriseSwitchDisabledMessage(for: enterprise), "管理员已关闭企业切换")

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.example.test/api/platform/apps/current-policy?app_id=jianhuitong-ios")
    }

    #if DEBUG
    func testRegistrationDiagnosticSummaryUsesClosedVocabularyAndBoundsElapsedTime() throws {
        let codes = [
            "SUBMIT_RESPONSE_ACCEPTED", "SUBMIT_HTTP_REJECTED", "SUBMIT_SERVICE_UNAVAILABLE",
            "SUBMIT_TRANSPORT_FAILED", "SUBMIT_CONTRACT_FAILED", "SUBMIT_CANCELLED",
            "STATUS_PENDING", "STATUS_SUCCESS", "STATUS_FAILED", "STATUS_NOT_FOUND",
            "STATUS_HTTP_REJECTED", "STATUS_SERVICE_UNAVAILABLE", "STATUS_TRANSPORT_FAILED",
            "STATUS_CONTRACT_FAILED", "STATUS_CANCELLED", "CONFIRMATION_CANCELLED", "CONFIRMATION_EXPIRED"
        ]
        for code in codes {
            let diagnostic = try XCTUnwrap(RegistrationDiagnosticState(rawValue: code))
            XCTAssertEqual(diagnostic.safeSummary(elapsedSeconds: 1.25), "diagnostic=\(code) elapsed_ms=1250")
            for elapsed in [TimeInterval.nan, .infinity, -.infinity, -1] {
                XCTAssertEqual(diagnostic.safeSummary(elapsedSeconds: elapsed), "diagnostic=\(code) elapsed_ms=0")
            }
            XCTAssertEqual(diagnostic.safeSummary(elapsedSeconds: .greatestFiniteMagnitude), "diagnostic=\(code) elapsed_ms=86400000")
        }
        XCTAssertNil(RegistrationDiagnosticState(rawValue: registrationDiagnosticSentinel))
        XCTAssertEqual([RegistrationResolutionState.pending, .success, .failed].map(\.rawValue), ["PENDING", "SUCCESS", "FAILED"])
        XCTAssertNil(RegistrationResolutionState(rawValue: "STATUS_NOT_FOUND"))
    }

    func testRegistrationDiagnosticWriterDoesNotOverwriteResolutionSummary() throws {
        let defaults = UserDefaults.standard
        let summaryKey = "jianhuitong.debug.registration.lastSummary"
        let originalSummary = defaults.object(forKey: summaryKey)
        let originalDiagnostic = defaults.object(forKey: registrationDiagnosticKey)
        defer {
            defaults.set(originalSummary, forKey: summaryKey)
            defaults.set(originalDiagnostic, forKey: registrationDiagnosticKey)
        }
        defaults.set("state=PENDING elapsed_ms=2000", forKey: summaryKey)
        recordRegistrationDiagnostic(try XCTUnwrap(RegistrationDiagnosticState(rawValue: "STATUS_NOT_FOUND")), elapsedSeconds: 3)
        try assertRegistrationDiagnostic("STATUS_NOT_FOUND", elapsedMilliseconds: 3000)
        XCTAssertEqual(defaults.string(forKey: summaryKey), "state=PENDING elapsed_ms=2000")
    }

    func testRegistrationDiagnosticsPreserveThreeHTTP200StatusResultsAndBoundIdentity() async throws {
        defer { UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey) }
        let requestID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        for status in [RemoteRegistrationStatus.pending, .success, .failed] {
            UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey)
            let transport = FakeHTTPTransport(results: [registrationDiagnosticResponse(
                #"{"ok":true,"data":{"status":"\#(status.rawValue)","private":"\#(registrationDiagnosticSentinel)"}}"#
            )])
            let result = try await makeClient(transport: transport).registrationStatus(
                appID: "jianhuitong-ios", deviceID: registrationDiagnosticSentinel, requestID: requestID
            )
            XCTAssertEqual(result, status)
            try assertRegistrationDiagnostic("STATUS_\(status.rawValue)")
            let request = try XCTUnwrap(transport.requests().first)
            XCTAssertEqual(transport.requests().count, 1)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), requestID)
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "app_id", value: "jianhuitong-ios"),
                URLQueryItem(name: "device_id", value: registrationDiagnosticSentinel)
            ])
            XCTAssertFalse(try XCTUnwrap(UserDefaults.standard.string(forKey: registrationDiagnosticKey)).contains(requestID))
        }
    }

    func testRegistrationDiagnosticsDistinguishStatusHTTPFailuresFromBusinessStates() async throws {
        defer { UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey) }
        for (status, code) in [(404, "STATUS_NOT_FOUND"), (422, "STATUS_HTTP_REJECTED"), (503, "STATUS_SERVICE_UNAVAILABLE")] {
            UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey)
            let transport = FakeHTTPTransport(results: [registrationDiagnosticResponse(
                #"{"ok":false,"error":{"code":"diagnostic_fixture","message":"\#(registrationDiagnosticSentinel)"}}"#,
                status: status
            )])
            do {
                _ = try await makeClient(transport: transport).registrationStatus(
                    appID: "jianhuitong-ios", deviceID: registrationDiagnosticSentinel, requestID: UUID().uuidString
                )
                XCTFail("HTTP failure must not become a registration business state")
            } catch IMAPIError.httpStatus(let actual, _) {
                XCTAssertEqual(actual, status)
            } catch {
                XCTFail("Unexpected error type: \(type(of: error))")
            }
            try assertRegistrationDiagnostic(code)
        }
    }

    func testRegistrationDiagnosticsDistinguishStatusContractFailureWithoutChangingOther2xxReturns() async throws {
        defer { UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey) }
        let invalidBodies = [
            registrationDiagnosticSentinel,
            #"{"ok":true,"data":{"status":"UNKNOWN"}}"#,
            #"{"ok":true,"data":{}}"#,
            #"{"ok":true}"#,
            #"{"ok":false,"data":{"status":"SUCCESS"}}"#
        ]
        for response in invalidBodies.map({ registrationDiagnosticResponse($0) }) + [
            HTTPTransportResult(data: Data(registrationDiagnosticSentinel.utf8), isHTTPResponse: false, statusCode: nil)
        ] {
            UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey)
            do {
                _ = try await makeClient(transport: FakeHTTPTransport(results: [response])).registrationStatus(
                    appID: "jianhuitong-ios", deviceID: registrationDiagnosticSentinel, requestID: UUID().uuidString
                )
                XCTFail("Malformed status response must remain a failure")
            } catch {
                XCTAssertTrue(error is IMAPIError)
            }
            try assertRegistrationDiagnostic("STATUS_CONTRACT_FAILED")
        }
        for status in [201, 202, 204, 206, 299] {
            let client = makeClient(transport: FakeHTTPTransport(results: [registrationDiagnosticResponse(
                #"{"ok":true,"data":{"status":"SUCCESS"}}"#, status: status
            )]))
            let result = try await client.registrationStatus(
                appID: "jianhuitong-ios", deviceID: registrationDiagnosticSentinel, requestID: UUID().uuidString
            )
            XCTAssertEqual(result, .success, "Diagnostics must preserve the existing 2xx return contract")
            try assertRegistrationDiagnostic("STATUS_CONTRACT_FAILED")
        }
        let missingOK = makeClient(transport: FakeHTTPTransport(results: [registrationDiagnosticResponse(
            #"{"data":{"status":"PENDING"}}"#
        )]))
        let compatibleResult = try await missingOK.registrationStatus(
            appID: "jianhuitong-ios", deviceID: registrationDiagnosticSentinel, requestID: UUID().uuidString
        )
        XCTAssertEqual(compatibleResult, .pending)
        try assertRegistrationDiagnostic("STATUS_CONTRACT_FAILED")
    }

    func testRegistrationDiagnosticsClassifySubmitResponseWithoutChangingOutcome() async throws {
        defer { UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey) }
        let acceptedBody = #"{"ok":true,"data":{"account":{"id":"fixture-account","username":"fixture-user","status":"normal"},"platform_token":"\#(registrationDiagnosticSentinel)"}}"#
        let cases: [(HTTPTransportResult, String, Bool)] = [
            (registrationDiagnosticResponse(acceptedBody), "SUBMIT_RESPONSE_ACCEPTED", true),
            (registrationDiagnosticResponse(#"{"ok":false,"error":{"code":"fixture_rejected","message":"\#(registrationDiagnosticSentinel)"}}"#, status: 404), "SUBMIT_HTTP_REJECTED", false),
            (registrationDiagnosticResponse(registrationDiagnosticSentinel, status: 503), "SUBMIT_SERVICE_UNAVAILABLE", false),
            (registrationDiagnosticResponse(registrationDiagnosticSentinel), "SUBMIT_CONTRACT_FAILED", false),
            (registrationDiagnosticResponse(#"{"ok":true,"data":{}}"#), "SUBMIT_CONTRACT_FAILED", false),
            (registrationDiagnosticResponse(#"{"ok":false}"#), "SUBMIT_CONTRACT_FAILED", false),
            (HTTPTransportResult(data: Data(), isHTTPResponse: false, statusCode: nil), "SUBMIT_CONTRACT_FAILED", false)
        ]
        for (response, code, succeeds) in cases {
            UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey)
            let transport = FakeHTTPTransport(results: [response])
            do {
                let result = try await submitRegistrationDiagnosticFixture(makeClient(transport: transport))
                XCTAssertTrue(succeeds)
                XCTAssertEqual(result.platformToken, registrationDiagnosticSentinel)
            } catch {
                XCTAssertFalse(succeeds)
                if code == "SUBMIT_HTTP_REJECTED" {
                    guard case IMAPIError.businessForbidden(let errorCode, _, _) = error else {
                        XCTFail("Expected the original business rejection"); continue
                    }
                    XCTAssertEqual(errorCode, "fixture_rejected")
                } else {
                    XCTAssertTrue(error is RegistrationOutcomeUncertainError)
                }
            }
            try assertRegistrationDiagnostic(code)
            XCTAssertEqual(transport.requests().count, 1)
            XCTAssertEqual(transport.requests().first?.value(forHTTPHeaderField: "Idempotency-Key"), registrationDiagnosticSentinel)
        }
    }

    func testRegistrationDiagnosticsSeparateTransportFailureAndCancellationForBothEndpoints() async throws {
        defer { UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey) }
        let failures: [(Error, Bool)] = [
            (UnsafeLocalizedDescriptionError(message: registrationDiagnosticSentinel), false),
            (URLError(.notConnectedToInternet), false), (URLError(.timedOut), false),
            (CancellationError(), true), (URLError(.cancelled), true)
        ]
        for (error, cancelled) in failures {
            for submitting in [true, false] {
                UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey)
                let client = makeClient(transport: FailingHTTPTransport(error: error))
                do {
                    if submitting {
                        _ = try await submitRegistrationDiagnosticFixture(client)
                    } else {
                        _ = try await client.registrationStatus(
                            appID: "jianhuitong-ios", deviceID: registrationDiagnosticSentinel, requestID: UUID().uuidString
                        )
                    }
                    XCTFail("Transport failure must keep throwing")
                } catch {
                    if submitting { XCTAssertTrue(error is RegistrationOutcomeUncertainError) }
                    else { XCTAssertFalse(error is RegistrationOutcomeUncertainError) }
                }
                try assertRegistrationDiagnostic("\(submitting ? "SUBMIT" : "STATUS")_\(cancelled ? "CANCELLED" : "TRANSPORT_FAILED")")
            }
        }
    }

    func testRegistrationDiagnosticsPreserveConfirmedSuccessAndFailureWithoutResubmitting() async throws {
        clearStoredAPIContext()
        defer {
            clearStoredAPIContext()
            UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey)
        }
        for resolution in [RegistrationResolutionState.success, .failed] {
            let clock = RegistrationTestClock()
            let transport = FakeHTTPTransport(results: [
                activeAppPolicyResult(), registrationDiagnosticResponse("unavailable", status: 503),
                registrationDiagnosticResponse(#"{"ok":true,"data":{"status":"PENDING"}}"#),
                registrationDiagnosticResponse(#"{"ok":true,"data":{"status":"\#(resolution.rawValue)"}}"#)
            ] + (resolution == .success ? [registrationDiagnosticResponse("registration_session_unauthorized", status: 401)] : []))
            let state = AppState(
                api: makeClient(transport: transport), registrationNow: { clock.now() },
                registrationSleep: { seconds in clock.advance(by: seconds) }, apiContextOverride: makePreloginContext()
            )
            let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
            XCTAssertTrue(loaded)
            state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
            try await waitForCondition { state.registrationResolutionState == resolution && !state.isAuthLoading }
            try assertRegistrationDiagnostic("STATUS_\(resolution.rawValue)")
            XCTAssertEqual(UserDefaults.standard.string(forKey: "jianhuitong.debug.registration.lastSummary"), "state=\(resolution.rawValue) elapsed_ms=6000")
            XCTAssertFalse(state.isAuthenticated)
            XCTAssertEqual(clock.delays(), [2, 4])
            let submissions = transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }
            let statuses = transport.requests().filter { $0.url?.path.hasSuffix("/register/status") == true }
            XCTAssertEqual(submissions.count, 1)
            XCTAssertEqual(statuses.count, 2)
            let identity = try XCTUnwrap(submissions.first?.value(forHTTPHeaderField: "Idempotency-Key"))
            XCTAssertTrue(statuses.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") == identity })
            XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/im-login") == true })
            state.logout()
            clearStoredAPIContext()
        }
    }

    func testRegistrationDiagnosticExpiryAllowsExplicitNewSubmission() async throws {
        clearStoredAPIContext()
        defer {
            clearStoredAPIContext()
            UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey)
        }
        let clock = RegistrationTestClock()
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(), registrationDiagnosticResponse("unavailable", status: 503),
            registrationDiagnosticResponse(#"{"ok":true,"data":{"status":"PENDING"}}"#)
        ])
        let state = AppState(
            api: makeClient(transport: transport), registrationNow: { clock.now() },
            registrationSleep: { seconds in clock.advance(by: seconds) }, apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(loaded)
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationConfirmationTimedOut }
        try assertRegistrationDiagnostic("CONFIRMATION_EXPIRED", elapsedMilliseconds: 300000)
        XCTAssertEqual(clock.now(), 300)
        XCTAssertEqual(clock.delays(), RegistrationConfirmationPolicy.sleepDelaysSeconds())
        XCTAssertEqual(state.registrationResolutionState, .pending)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.timeoutMessage)
        XCTAssertFalse(state.isRegistrationSubmissionBlocked)
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count == 2 }
        let submissions = transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }
        XCTAssertEqual(submissions.count, 2)
        XCTAssertNotEqual(submissions[0].value(forHTTPHeaderField: "Idempotency-Key"), submissions[1].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/im-login") == true })
    }

    func testRegistrationDiagnosticCancellationPreservesLogoutAndStopsPolling() async throws {
        clearStoredAPIContext()
        defer {
            clearStoredAPIContext()
            UserDefaults.standard.removeObject(forKey: registrationDiagnosticKey)
        }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(), registrationDiagnosticResponse("unavailable", status: 503)
        ])
        let state = AppState(
            api: makeClient(transport: transport), registrationNow: { 10 },
            registrationSleep: { _ in try await Task.sleep(nanoseconds: 30_000_000_000) },
            apiContextOverride: makePreloginContext()
        )
        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(loaded)
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationResolutionState == .pending && !state.isAuthLoading }
        state.logout()
        for _ in 0..<10 { await Task.yield() }
        try assertRegistrationDiagnostic("CONFIRMATION_CANCELLED", elapsedMilliseconds: 0)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(PendingRegistrationReceiptStore(defaults: .standard).load())
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/register/status") == true })
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count, 1)
    }

    private var registrationDiagnosticKey: String { "jianhuitong.debug.registration.lastDiagnostic" }
    private var registrationDiagnosticSentinel: String { "PRIVATE_FIXTURE_MUST_NOT_APPEAR_9146" }

    func registrationDiagnosticResponse(_ body: String, status: Int = 200) -> HTTPTransportResult {
        HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true, statusCode: status, headers: [
            "X-Request-ID": registrationDiagnosticSentinel, "Set-Cookie": registrationDiagnosticSentinel
        ])
    }

    private func assertRegistrationDiagnostic(_ code: String, elapsedMilliseconds: Int? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let output = try XCTUnwrap(UserDefaults.standard.string(forKey: registrationDiagnosticKey), file: file, line: line)
        XCTAssertNotNil(output.range(of: "^diagnostic=\(code) elapsed_ms=[0-9]+$", options: .regularExpression), file: file, line: line)
        XCTAssertFalse(output.contains(registrationDiagnosticSentinel), file: file, line: line)
        if let elapsedMilliseconds {
            XCTAssertEqual(output, "diagnostic=\(code) elapsed_ms=\(elapsedMilliseconds)", file: file, line: line)
        }
    }

    private func submitRegistrationDiagnosticFixture(_ client: IMAPIClient) async throws -> RemoteAuthData {
        try await client.registerWithRequestID(
            username: registrationDiagnosticSentinel, phone: registrationDiagnosticSentinel,
            password: registrationDiagnosticSentinel, tenantCode: "WXT553222", captchaCode: registrationDiagnosticSentinel,
            enterpriseContextToken: registrationDiagnosticSentinel, appID: "jianhuitong-ios",
            deviceID: registrationDiagnosticSentinel, requestID: registrationDiagnosticSentinel
        )
    }
    #endif

    func testRegistration503BlocksRepeatedSubmissionWhileConfirming() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ])
        var receiptBytes: Data?
        let receiptStore = PendingRegistrationReceiptStore(readData: { receiptBytes }, writeData: { receiptBytes = $0 })
        let proofStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport),
            pendingRegistrationReceiptStore: receiptStore,
            registrationSessionStore: proofStore,
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }

        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage)
        XCTAssertTrue(state.isRegistrationSubmissionBlocked)
        XCTAssertEqual(state.registrationSubmitButtonTitle, "正在确认…")
        let originalReceipt = try XCTUnwrap(receiptBytes)
        let originalProof = try XCTUnwrap(proofStore.string(forKey: RegistrationSessionRecovery.storageKey))
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        state.registerWithDefaultEnterprise(account: "admin12", password: "aa123456")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count, 1)
        XCTAssertEqual(receiptBytes, originalReceipt)
        XCTAssertEqual(proofStore.string(forKey: RegistrationSessionRecovery.storageKey), originalProof)
        XCTAssertEqual(state.registrationResolutionState, .pending)
        XCTAssertFalse(state.registrationConfirmationTimedOut)
    }

    func testRegistrationPendingNeverUsesLoginAsConfirmationEndpoint() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }
        for _ in 0..<10 { await Task.yield() }

        let requests = transport.requests()
        let registrationRequests = requests.filter { $0.url?.path == "/api/platform/auth/register" }
        XCTAssertEqual(registrationRequests.count, 1)
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/platform/auth/im-login" })
        XCTAssertEqual(state.registrationResolutionState, .pending)
        XCTAssertTrue(state.isRegistrationSubmissionBlocked)
        XCTAssertFalse(state.isAuthenticated)
    }

    func testRegistrationPendingDoesNotTimeoutBeforeFirstStatusPoll() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(state.registrationResolutionState, .pending)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage)
        XCTAssertTrue(state.isRegistrationSubmissionBlocked)
        XCTAssertFalse(state.registrationConfirmationTimedOut)
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count,
            1
        )
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/platform/auth/im-login" })
    }

    func testRegistrationStatusUsesOriginalIdentityAndBoundScope() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"PENDING"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let requestID = UUID().uuidString.lowercased()

        let status = try await client.registrationStatus(
            appID: "jianhuitong-ios",
            deviceID: "device / 1",
            requestID: requestID
        )

        XCTAssertEqual(status, .pending)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/platform/auth/register/status")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
            [
                URLQueryItem(name: "app_id", value: "jianhuitong-ios"),
                URLQueryItem(name: "device_id", value: "device / 1")
            ]
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), requestID)
        XCTAssertNil(request.httpBody)
    }

    func testRegistrationCancellationWithoutReadableProofStopsLoading() {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let state = AppState(api: makeClient(transport: FakeHTTPTransport(results: [])),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makePreloginContext())
        state.authenticationPresentationStore.isLoading = true // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        state.cancelRegistrationSessionRecovery()
        XCTAssertFalse(state.isAuthLoading)
        XCTAssertFalse(state.isAuthenticated)
    }

    func testRegistrationCommittedPlatformRestoresAfterPublicReceiptDeadline() async throws {
        for age in [390.0, 601.0] {
            clearStoredAPIContext()
            defer { clearStoredAPIContext() }
            let suiteName = "Registration.Restore.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let sessionStore = InMemoryProtectedSessionStore()
            let recoveryStore = InMemoryProtectedSessionStore()
            var context = makeProtectedSessionContext()
            context.discardRegistrationIMState()
            XCTAssertEqual(context.save(defaults: defaults, sessionStore: sessionStore), .committed)
            let receipt = PendingRegistrationReceipt(requestID: UUID().uuidString.lowercased(),
                appID: context.appID, deviceID: context.deviceID, failureScreen: "account", startedAt: 10)
            var receiptBytes: Data? = try JSONEncoder().encode(receipt)
            let receiptStore = PendingRegistrationReceiptStore(readData: { receiptBytes }, writeData: { receiptBytes = $0 })
            let recovery = RegistrationSessionRecovery(requestID: receipt.requestID, appID: context.appID,
                deviceID: context.deviceID, entryCode: "553222", startedAt: receipt.startedAt,
                secret: try XCTUnwrap(RegistrationSessionRecovery.generateSecret()), tenantID: "tenant-1",
                platformSessionID: "platform-session")
            XCTAssertTrue(recoveryStore.setString(String(decoding: try JSONEncoder().encode(recovery), as: UTF8.self),
                forKey: RegistrationSessionRecovery.storageKey))
            let transport = FakeHTTPTransport(results: [
                try tenantEnterSuccess(entryTicket: "registration-resume", routes: runtimeRouteSnapshotForHTTPWiring()),
                try tenantPlatformEntrySuccess()
            ])
            let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
                registrationNow: { receipt.startedAt + age }, pendingRegistrationReceiptStore: receiptStore,
                protectedSessionStore: sessionStore, registrationSessionStore: recoveryStore, apiContextOverride: context)
            defer { state.logout() }
            try await waitForCondition { state.isAuthenticated }
            XCTAssertTrue(state.hasActiveIMSession)
            let paths = transport.requests().compactMap { $0.url?.path }
            XCTAssertFalse(paths.contains("/api/platform/auth/register/status"))
            XCTAssertFalse(paths.contains("/api/platform/auth/register/session"))
            XCTAssertTrue(paths.contains("/api/platform/me/tenants/tenant-1/enter"))
            XCTAssertEqual(recoveryStore.storedValueCount, 0)
        }
    }

    func testRegistrationEntryFailureUsesLatestCommittedPlatformSnapshot() throws {
        for mode in ["tenant503", "imSave", "unknownRefresh"] {
            let suiteName = "Registration.PlatformRecovery.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = InMemoryProtectedSessionStore(failingWriteNumbers: mode == "imSave" ? [3] : [])
            var captured = makeProtectedSessionContext()
            captured.discardRegistrationIMState()
            XCTAssertEqual(captured.save(defaults: defaults, sessionStore: store), .committed)
            var advanced = captured
            if mode == "unknownRefresh" {
                advanced.pendingRefreshRequestID = "synthetic-stable-refresh-request"
            } else {
                advanced.platformToken = "synthetic-rotated-platform"
                advanced.platformAuthSession = IMStoredAuthSession(
                    sessionID: "platform-session", refreshToken: "synthetic-rotated-refresh",
                    tokenType: "platform", accountID: "account-1", appID: captured.appID,
                    deviceID: captured.deviceID, authVersion: 2, sessionGeneration: 3, accessExpiresAt: 9000)
                advanced.credentialRevision = 7
                advanced.sessionEpoch = "synthetic-rotated-epoch"
            }
            XCTAssertEqual(advanced.save(defaults: defaults, sessionStore: store), .committed)
            var partial = advanced
            partial.imToken = "synthetic-uncommitted-im"
            partial.imUID = "uid-1"
            if mode == "imSave" {
                XCTAssertEqual(partial.save(defaults: defaults, sessionStore: store), .failed)
            }
            let restored = try XCTUnwrap(partial.registrationPlatformContext(
                sessionID: "platform-session", tenantID: "tenant-1", sessionStore: store))
            XCTAssertFalse(restored.hasIMSession)
            XCTAssertNil(restored.tenantAuthSession)
            XCTAssertEqual(restored.platformToken, advanced.platformToken)
            XCTAssertEqual(restored.platformAuthSession, advanced.platformAuthSession)
            XCTAssertEqual(restored.pendingRefreshRequestID, advanced.pendingRefreshRequestID)
            XCTAssertEqual(restored.credentialRevision, advanced.credentialRevision)
            XCTAssertEqual(restored.sessionEpoch, advanced.sessionEpoch)
            XCTAssertNil(partial.registrationPlatformContext(sessionID: "other-session", tenantID: "tenant-1", sessionStore: store))
            XCTAssertNil(partial.registrationPlatformContext(sessionID: "platform-session", tenantID: "other-tenant", sessionStore: store))
            partial.deviceID = "other-device"
            XCTAssertNil(partial.registrationPlatformContext(sessionID: "platform-session", tenantID: "tenant-1", sessionStore: store))
        }
    }

    func testRegistrationRecoveryCredentialWriteFailurePreventsSubmission() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [activeAppPolicyResult()])
        let state = AppState(api: makeClient(transport: transport),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            registrationSessionStore: InMemoryProtectedSessionStore(failingWriteNumbers: [1]),
            apiContextOverride: makePreloginContext())
        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(loaded)
        state.registerAndEnterIM(account: "admin11", password: "fixture-password", enterpriseCode: "553222")
        try await waitForCondition { state.toast == "无法安全保存注册凭据，请重试" }
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/platform/auth/register" })
    }

    func testRegistrationPendingPollsWithBackoffThenConfirmsSuccessWithoutSecondSubmit() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let clock = RegistrationTestClock()
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"PENDING"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"SUCCESS"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try registrationSessionRecoverySuccess(),
            try tenantEnterSuccess(entryTicket: "registration-entry", routes: runtimeRouteSnapshotForHTTPWiring()),
            try registrationTenantEntrySuccess(tenantID: "tenant-1")
        ])
        let recoveryStore = InMemoryProtectedSessionStore()
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            registrationNow: { clock.now() },
            registrationSleep: { seconds in clock.advance(by: seconds) },
            protectedSessionStore: sessionStore,
            registrationSessionStore: recoveryStore,
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110_BEGIN
        var presented: [RegistrationResolutionState] = []
        let observation = state.registrationConfirmationStore.$snapshot
            .compactMap(\.resolution).removeDuplicates().sink { presented.append($0) }
        defer { observation.cancel() }
        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition { state.registrationResolutionState == .success }
        XCTAssertEqual(presented, [.pending, .success])
        // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110_END

        let requests = transport.requests()
        let registrations = requests.filter { $0.url?.path == "/api/platform/auth/register" }
        let statuses = requests.filter { $0.url?.path == "/api/platform/auth/register/status" }
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(statuses.count, 2)
        let requestID = try XCTUnwrap(registrations.first?.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertTrue(statuses.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") == requestID })
        XCTAssertEqual(clock.delays(), [2, 4])
        let exchange = try XCTUnwrap(requests.first { $0.url?.path == "/api/platform/auth/register/session" })
        let registerJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(registrations[0].httpBody)) as? [String: Any])
        let exchangeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(exchange.httpBody)) as? [String: Any])
        let proof = try XCTUnwrap(registerJSON["registration_session_secret"] as? String)
        XCTAssertTrue(RegistrationSessionRecovery.isValidSecret(proof))
        XCTAssertEqual(exchangeJSON["registration_session_secret"] as? String, proof)
        XCTAssertEqual(exchangeJSON["registration_request_id"] as? String, requestID)
        XCTAssertNil(exchangeJSON["password"])
        XCTAssertFalse(IMAPIClient.redactedSensitiveLogText(String(decoding: try XCTUnwrap(exchange.httpBody), as: UTF8.self)).contains(proof))
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        XCTAssertEqual(recoveryStore.storedValueCount, 0)
        XCTAssertEqual(state.toast, "注册成功，已自动登录")
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/platform/auth/im-login" })
    }
}

// WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_BEGIN
private final class EnterpriseSearchResponseGate: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<HTTPTransportResult, Error>] = [:]
    private var closed = false

    func isPending(_ query: String) -> Bool { lock.withLock { pending[query] != nil } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard let url = request.url, url.path == "/api/tenant/workspaces/search",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
        else { throw URLError(.unsupportedURL) }
        let result: HTTPTransportResult = try await withCheckedThrowingContinuation { continuation in
            let reject = lock.withLock {
                guard !closed, pending[query] == nil else { return true }
                pending[query] = continuation
                return false
            }
            if reject { continuation.resume(throwing: URLError(.cancelled)) }
        }
        return result.resolvingResponseURL(url)
    }

    func release(_ query: String) {
        lock.withLock { pending.removeValue(forKey: query) }?.resume(returning: HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"items":[{"id":"\#(query)","name":"\#(query)"}]}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ))
    }

    func close() {
        let waiting = lock.withLock {
            closed = true
            defer { pending.removeAll() }
            return pending.values
        }
        waiting.forEach { $0.resume(throwing: URLError(.cancelled)) }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_END

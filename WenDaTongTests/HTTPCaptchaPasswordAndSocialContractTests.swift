@testable import IM4Domain
import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110_BEGIN
    func testSlideCaptchaPresentationResumesActiveWaiterAndCancelsReplacement() async throws {
        let decoder = JSONDecoder()
        let first = try decoder.decode(RemoteSlideCaptchaChallenge.self, from: Data(#"{"challenge_id":"first"}"#.utf8))
        let second = try decoder.decode(RemoteSlideCaptchaChallenge.self, from: Data(#"{"challenge_id":"second"}"#.utf8))
        let state = AppState(api: makeClient(transport: FakeHTTPTransport(results: [])), apiContextOverride: makePreloginContext())
        let store = state.slideCaptchaPresentationStore
        var updates: [RemoteSlideCaptchaChallenge?] = []
        var appUpdates = 0
        let observations = [
            store.$challenge.dropFirst().sink { updates.append($0) },
            state.objectWillChange.sink { appUpdates += 1 }
        ]
        defer {
            observations.forEach { $0.cancel() }
            state.cancelSlideCaptcha()
        }

        var firstCancelled = false
        let firstTask = Task {
            do { _ = try await state.presentSlideCaptcha(first) }
            catch IMAPIError.forbidden(let message) { firstCancelled = message == "已取消滑动验证" }
        }
        try await waitForCondition { store.challenge == first }
        XCTAssertEqual(store.challenge, first)

        let secondTask = Task { try await state.presentSlideCaptcha(second) }
        try await waitForCondition { store.challenge == second && firstCancelled }
        XCTAssertTrue(firstCancelled)
        XCTAssertEqual(store.challenge, second)
        store.complete(SlideCaptchaTicket(ticket: "", randstr: "", challengeID: "second", lotNumber: "",
                                         captchaOutput: "", passToken: "", genTime: "", extra: [:]))
        let ticket = try await secondTask.value
        _ = try await firstTask.value
        XCTAssertEqual(ticket.challengeID, "second")
        XCTAssertEqual(updates, [first, nil, second, nil])
        XCTAssertEqual(appUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110_END

    func testTenantAdminSlideCaptchaStillUsesTenantEndpoint() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"enabled":true,"available":true,"required":true,"provider":"self_hosted_slide","surface":"tenant_admin","scene":"tenant_admin_login","token_ttl_seconds":120}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        _ = try await client.slideCaptchaConfig(scene: "tenant_admin_login", surface: "tenant_admin", appID: "jianhuitong-ios")

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/captcha/slide/config?scene=tenant_admin_login&surface=tenant_admin&app_id=jianhuitong-ios")
    }

    func testPublicTenantCaptchaFetchesBoundPreauthDeviceProofWithoutBearer() async throws {
        let proof = "proof-contract-sensitive-value"
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T10:00:00Z"))
        let transport = FakeHTTPTransport(results: [
            preauthDeviceProofSuccess(proof: proof, expiresAt: "2026-07-23T11:00:00Z"),
            phoneCaptchaSuccess(requestID: "captcha-contract")
        ])
        let client = makeClient(transport: transport, preauthDeviceProofNow: { now })

        _ = try await client.sendTenantCaptcha(
            phone: "13800000000",
            scene: "register",
            tenantCode: "wxt000001", // WDT_IOS1_A17_CURRENT_FIXTURE_CONTRACT_20261111
            context: makeContext()
        )

        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        let proofRequest = requests[0]
        XCTAssertEqual(proofRequest.url?.absoluteString, "https://tenant.example.test/api/tenant/security/preauth-device")
        XCTAssertEqual(proofRequest.httpMethod, "POST")
        XCTAssertNil(proofRequest.value(forHTTPHeaderField: "Authorization"))
        let proofBody = try requestJSONObject(proofRequest)
        XCTAssertEqual(Set(proofBody.keys), Set(["app_id", "device_id", "platform"]))
        XCTAssertEqual(proofBody["app_id"] as? String, IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(proofBody["device_id"] as? String, "device-1")
        XCTAssertEqual(proofBody["platform"] as? String, "ios")

        let captchaRequest = requests[1]
        XCTAssertEqual(captchaRequest.url?.absoluteString, "https://tenant.example.test/api/tenant/captcha/send")
        XCTAssertEqual(captchaRequest.httpMethod, "POST")
        XCTAssertNil(captchaRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(captchaRequest.url?.absoluteString.contains(proof) ?? true)
        let captchaBody = try requestJSONObject(captchaRequest)
        XCTAssertEqual(captchaBody["phone"] as? String, "13800000000")
        XCTAssertEqual(captchaBody["scene"] as? String, "register")
        XCTAssertEqual(captchaBody["channel"] as? String, "sms")
        XCTAssertEqual(captchaBody["tenant_code"] as? String, "WXT000001")
        XCTAssertEqual(captchaBody["app_id"] as? String, IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(captchaBody["device_id"] as? String, "device-1")
        XCTAssertEqual(captchaBody["device_proof"] as? String, proof)
    }

    func testPublicTenantCaptchaCachesProofOnlyInMemoryUntilExpiry() async throws {
        let proof = "proof-memory-only-sensitive-value"
        var now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T10:00:00Z"))
        let transport = FakeHTTPTransport(results: [
            preauthDeviceProofSuccess(proof: proof, expiresAt: "2026-07-23T11:00:00Z"),
            phoneCaptchaSuccess(requestID: "captcha-cache-1"),
            phoneCaptchaSuccess(requestID: "captcha-cache-2"),
            preauthDeviceProofSuccess(proof: "proof-refreshed", expiresAt: "2026-07-23T13:00:00Z"),
            phoneCaptchaSuccess(requestID: "captcha-cache-3")
        ])
        let client = makeClient(transport: transport, preauthDeviceProofNow: { now })

        _ = try await client.sendTenantCaptcha(phone: "13800000000", scene: "register", context: makeContext())
        _ = try await client.sendTenantCaptcha(phone: "13800000000", scene: "register", context: makeContext())
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/tenant/security/preauth-device" }.count, 1)
        XCTAssertEqual(client.preauthDeviceProofCacheCountForTesting(), 1)
        XCTAssertFalse(persistedUserDefaultsContain(proof))

        now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T11:00:00Z"))
        _ = try await client.sendTenantCaptcha(phone: "13800000000", scene: "register", context: makeContext())

        let requests = transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/tenant/security/preauth-device" }.count, 2)
        let lastCaptcha = try XCTUnwrap(requests.last)
        XCTAssertEqual(try requestJSONObject(lastCaptcha)["device_proof"] as? String, "proof-refreshed")
        XCTAssertFalse(persistedUserDefaultsContain(proof))
    }

    func testPublicTenantCaptchaRefreshesProofAndRetriesBusinessRequestOnlyOnce() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T10:00:00Z"))
        let transport = FakeHTTPTransport(results: [
            preauthDeviceProofSuccess(proof: "proof-stale", expiresAt: "2026-07-23T11:00:00Z"),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"captcha_device_proof_required","message":"a fresh pre-login device proof is required"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 422
            ),
            preauthDeviceProofSuccess(proof: "proof-fresh", expiresAt: "2026-07-23T11:30:00Z"),
            phoneCaptchaSuccess(requestID: "captcha-after-refresh")
        ])
        let client = makeClient(transport: transport, preauthDeviceProofNow: { now })

        _ = try await client.sendTenantCaptcha(
            phone: "13800000000",
            scene: "password_reset",
            context: makeContext()
        )

        let requests = transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path ?? "" }, [
            "/api/tenant/security/preauth-device",
            "/api/tenant/captcha/send",
            "/api/tenant/security/preauth-device",
            "/api/tenant/captcha/send"
        ])
        XCTAssertEqual(try requestJSONObject(requests[1])["device_proof"] as? String, "proof-stale")
        XCTAssertEqual(try requestJSONObject(requests[3])["device_proof"] as? String, "proof-fresh")
    }

    func testPublicTenantCaptchaObserveModeFallsBackForFrozenCompatibilityStatuses() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T10:00:00Z"))
        let cases: [(status: Int, code: String)] = [
            (404, "not_found"),
            (403, "preauth_device_app_untrusted"),
            (429, "preauth_device_rate_limited"),
            (503, "preauth_device_unavailable")
        ]

        for item in cases {
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(
                    data: Data("{\"ok\":false,\"error\":{\"code\":\"\(item.code)\",\"message\":\"unavailable\"}}".utf8),
                    isHTTPResponse: true,
                    statusCode: item.status,
                    headers: item.status == 429 ? ["Retry-After": "60"] : [:]
                ),
                phoneCaptchaSuccess(requestID: "captcha-fallback-\(item.status)")
            ])
            let client = makeClient(transport: transport, preauthDeviceProofNow: { now })

            _ = try await client.sendTenantCaptcha(phone: "13800000000", scene: "register", context: makeContext())

            let requests = transport.requests()
            XCTAssertEqual(requests.count, 2, "status=\(item.status)")
            XCTAssertEqual(requests[0].url?.path, "/api/tenant/security/preauth-device")
            XCTAssertEqual(requests[1].url?.path, "/api/tenant/captcha/send")
            XCTAssertNil(try requestJSONObject(requests[1])["device_proof"], "status=\(item.status)")
        }
    }

    func testPublicTenantCaptchaRejectsProofLargerThanServerContract() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T10:00:00Z"))
        let transport = FakeHTTPTransport(results: [
            preauthDeviceProofSuccess(
                proof: String(repeating: "x", count: 2_049),
                expiresAt: "2026-07-23T11:00:00Z"
            )
        ])
        let client = makeClient(transport: transport, preauthDeviceProofNow: { now })

        do {
            _ = try await client.sendTenantCaptcha(phone: "13800000000", scene: "register", context: makeContext())
            XCTFail("Expected oversized preauth proof rejection")
        } catch {
            XCTAssertEqual(transport.requests().map { $0.url?.path ?? "" }, [
                "/api/tenant/security/preauth-device"
            ])
        }
    }

    func testPublicTenantCaptchaProofFailureBackoffDoesNotLoopOrMultiplyRequests() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T10:00:00Z"))
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"preauth_device_unavailable","message":"unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            ),
            phoneCaptchaSuccess(requestID: "captcha-backoff-1"),
            phoneCaptchaSuccess(requestID: "captcha-backoff-2")
        ])
        let client = makeClient(transport: transport, preauthDeviceProofNow: { now })

        _ = try await client.sendTenantCaptcha(phone: "13800000000", scene: "register", context: makeContext())
        _ = try await client.sendTenantCaptcha(phone: "13800000000", scene: "register", context: makeContext())

        XCTAssertEqual(transport.requests().map { $0.url?.path ?? "" }, [
            "/api/tenant/security/preauth-device",
            "/api/tenant/captcha/send",
            "/api/tenant/captcha/send"
        ])
    }

    func testPublicTenantCaptchaDoesNotRetryWhenRequiredAfterProofEndpointFallback() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T10:00:00Z"))
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"preauth_device_unavailable","message":"unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"captcha_device_proof_required","message":"required"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 422
            )
        ])
        let client = makeClient(transport: transport, preauthDeviceProofNow: { now })

        do {
            _ = try await client.sendTenantCaptcha(phone: "13800000000", scene: "register", context: makeContext())
            XCTFail("Expected captcha_device_proof_required")
        } catch IMAPIError.businessForbidden(let code, _, _) {
            XCTAssertEqual(code, "captcha_device_proof_required")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transport.requests().count, 2)
    }

    func testCaptchaEntryStatusCarriesApplicationAndTenantScope() async throws {
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"entries":[]}}"#.utf8),
            isHTTPResponse: true, statusCode: 200
        )])
        let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
        let scopes = [("customer-one-ios", "WXT183701"), ("customer-two-ios", "WXT183702")]
        for (appID, tenantCode) in scopes {
            _ = try await client.captchaEntryStatus(scene: "phone_bind", channel: "sms", tenantCode: tenantCode, appID: appID)
        }
        let requests = transport.requests()
        XCTAssertEqual(requests.count, scopes.count)
        for (request, scope) in zip(requests, scopes) {
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["app_id": IMAPIContext.normalizedIOSAppID(scope.0), "tenant_code": scope.1, "scene": "phone_bind", "channel": "sms"])
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(components.path, "/api/platform/captcha/entry-status")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testCaptchaEntryStatusKeepsPackagedAppWithoutInventingTenant() async throws {
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"entries":[]}}"#.utf8),
            isHTTPResponse: true, statusCode: 200
        )])
        let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
        _ = try await client.captchaEntryStatus(scene: "register", channel: "sms", appID: IMAPIContext.canonicalIOSAppID)
        let request = try XCTUnwrap(transport.requests().first)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.filter { $0.name == "app_id" }.map(\.value), [IMAPIContext.canonicalIOSAppID])
        XCTAssertFalse(query.contains { $0.name == "tenant_code" })
        XCTAssertEqual(transport.requests().count, 1)
    }

    func testPreloginCaptchaSendsWithoutAnIMSessionAfterReadyPrecheck() async throws {
        for scene in ["register", "password_reset"] {
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T10:00:00Z"))
            let policy: [String: Any] = [
                "ok": true, "data": ["app_id": IMAPIContext.canonicalIOSAppID, "platform": "ios",
                    "status": "active", "registration_enabled": true, "phone_auth_enabled": true,
                    "enterprise_code_first": false, "allow_default_tenant_join": true, "cache_ttl_seconds": 60]
            ]
            let entry: [String: Any] = ["ok": true, "data": ["entries": [[
                "scene": scene, "channel": "sms", "required": true, "enabled": true, "available": true
            ]]]]
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: policy), isHTTPResponse: true, statusCode: 200),
                HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: entry), isHTTPResponse: true, statusCode: 200),
                preauthDeviceProofSuccess(proof: "prelogin-captcha-fixture", expiresAt: "2026-07-23T11:00:00Z"),
                phoneCaptchaSuccess(requestID: "prelogin-\(scene)")
            ])
            let context = IMAPIContext(platformToken: nil, accountID: nil, tenantID: nil, imUID: nil, imToken: nil,
                platformAuthSession: nil, tenantAuthSession: nil, appID: IMAPIContext.canonicalIOSAppID, deviceID: "device-1")
            XCTAssertFalse(context.hasIMSession)
            let state = AppState(api: makeClient(transport: transport, preauthDeviceProofNow: { now }, runtimeRouteStore: isolatedRuntimeRouteStore()), apiContextOverride: context)
            let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
            XCTAssertTrue(loaded)
            let cooldown = scene == "register"
                ? await state.sendRegisterCaptcha(phone: "13800000000", tenantCode: "WXT183701")
                : await state.sendPasswordResetCaptcha(account: "13800000000")
            XCTAssertNotNil(cooldown, scene)
            let sends = transport.requests().filter { $0.url?.path == "/api/tenant/captcha/send" }
            XCTAssertEqual(sends.count, 1, scene)
            let body = try requestJSONObject(XCTUnwrap(sends.first))
            XCTAssertEqual(body["app_id"] as? String, state.currentAppID)
            XCTAssertEqual(body["scene"] as? String, scene)
        }
    }

    func testPhoneBindingUnavailablePrecheckDoesNotSendSMS() async throws {
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"entries":[{"scene":"phone_bind","channel":"sms","required":true,"enabled":true,"available":false,"reason_code":"captcha_channel_unavailable"}]}}"#.utf8),
            isHTTPResponse: true, statusCode: 200
        )])
        let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()), apiContextOverride: makeContext())
        let result = await state.sendPhoneBindingCode(phone: "13800000000")
        XCTAssertNil(result)
        XCTAssertEqual(state.toast, "当前验证码通道不可用")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/api/platform/captcha/entry-status")
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "app_id" }?.value, state.currentAppID)
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
    }

    func testAuthenticatedPhoneBindingDoesNotUsePreauthDeviceProof() async throws {
        let transport = FakeHTTPTransport(results: [phoneCaptchaSuccess(requestID: "phone-bind")])
        let client = makeClient(transport: transport)

        _ = try await client.sendPhoneBindingCode(context: makeContext(), phone: "13800000000")

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(transport.requests().count, 1)
        XCTAssertEqual(request.url?.path, "/api/tenant/me/phone/captcha")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertNil(try requestJSONObject(request)["device_proof"])
    }

    func testPasswordResetUsesExistingPlatformContractWithoutAuthorization() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"reset":true}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.resetPassword(
            phone: "13800000000",
            code: "123456",
            newPassword: "NewPass123"
        )

        XCTAssertTrue(result.reset)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://platform.example.test/api/platform/auth/password/reset")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try requestJSONObject(request)
        XCTAssertEqual(body["phone"] as? String, "13800000000")
        XCTAssertEqual(body["code"] as? String, "123456")
        XCTAssertEqual(body["new_password"] as? String, "NewPass123")
    }

    func testTenantFileForwardUsesCanonicalEndpointAndDecodesNestedMessage() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"file":{"id":"file-1"},"content_type":"file","message":{"message":{"message_id":"forwarded-1","channel_id":"g1","channel_type":"group","channel_seq":9,"from_uid":"uid-1","content_type":"file","payload":{"file_id":"file-1"},"status":"sent","created_at":"2026-08-13T00:00:00Z"},"duplicate":false}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 201
            )
        ])
        let client = makeClient(transport: transport)

        let message = try await client.forwardTenantFile(
            context: makeContext(),
            fileID: "file-1",
            targetChannelID: "g1",
            targetChannelType: "group",
            clientMessageID: "file-forward-1"
        )

        XCTAssertEqual(message.messageID, "forwarded-1")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/files/file-1/forward")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let body = try requestJSONObject(request)
        XCTAssertEqual(body["app_id"] as? String, IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(body["device_id"] as? String, "device-1")
        XCTAssertEqual(body["target_channel_id"] as? String, "g1")
        XCTAssertEqual(body["target_channel_type"] as? String, "group")
        XCTAssertEqual(body["client_msg_id"] as? String, "file-forward-1")
        XCTAssertNil(body["channel_id"])
        XCTAssertNil(body["channel_type"])
        XCTAssertNil(body["client_msg_no"])
    }

    func testTenantFileForwardRetryReusesClientMessageIDUntilAuthoritativeSuccess() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporary"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"file":{"id":"file-1"},"content_type":"file","message":{"message":{"message_id":"forwarded-2","channel_id":"g1","channel_type":"group","channel_seq":10,"from_uid":"uid-1","content_type":"file","payload":{"file_id":"file-1"},"status":"sent","created_at":"2026-08-13T00:00:01Z"},"duplicate":false}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 201
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.tenantInteractionStore.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.actions.forwardEnabled = true // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        let file = FileItem(
            id: "file-1",
            name: "report.pdf",
            type: "PDF",
            size: "2 KB",
            owner: "Me",
            source: "Group",
            time: "10:00",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "source-group",
            channelType: "group"
        )
        let target = BatchForwardTarget(channelID: "g1", channelType: "group", displayName: "Target Group")

        let firstAttempt = await state.forwardTenantFile(file, to: target)
        let secondAttempt = await state.forwardTenantFile(file, to: target)
        XCTAssertFalse(firstAttempt)
        XCTAssertTrue(secondAttempt)

        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        let firstID = try requestJSONObject(requests[0])["client_msg_id"] as? String
        let secondID = try requestJSONObject(requests[1])["client_msg_id"] as? String
        XCTAssertFalse((firstID ?? "").isEmpty)
        XCTAssertEqual(secondID, firstID)
        XCTAssertTrue(state.forwardingTenantFileIDs.isEmpty)
    }

    func testPreauthDeviceProofIsRedactedFromDiagnosticsText() {
        let proof = "proof-log-sensitive-value"
        let refresh = "refresh-log-sensitive-value"
        let access = "access-log-sensitive-value"
        let message = "message-log-sensitive-value"
        let raw = "device_proof=\(proof) body={\"device_proof\":\"\(proof)\",\"refresh_token\":\"\(refresh)\",\"im_token\":\"\(access)\",\"content\":\"\(message)\"}"
        let redacted = IMAPIClient.redactedSensitiveLogText(raw)

        XCTAssertFalse(redacted.contains(proof))
        XCTAssertFalse(redacted.contains(refresh))
        XCTAssertFalse(redacted.contains(access))
        XCTAssertFalse(redacted.contains(message))
        XCTAssertTrue(redacted.contains("device_proof=redacted"))
        XCTAssertEqual(
            BackendUserMessageSanitizer.sanitize(raw, fallback: "服务暂不可用"),
            "服务暂不可用"
        )
    }

    func testFriendRemarkDiagnosticsRedactPIIAndPreserveRequestID() throws {
        let remark = "客户王总"
        let friendUID = "friend/with+space ?#"
        let userID = "WXT000001"
        let nickname = "公开昵称"
        let displayName = "展示名称"
        let phone = "13800138000"
        let token = "im-token-sensitive"
        let requestID = "req-remark-123"
        let raw = """
        url=https://tenant.example.test/api/tenant/friends/friend%2Fwith%2Bspace%20%3F%23?friendRemark=\(remark)&userID=\(userID)&request_id=\(requestID)
        body={"remark":"\(remark)","friend_uid":"\(friendUID)","user_id":"\(userID)","nickname":"\(nickname)","display_name":"\(displayName)","phone":"\(phone)","im_token":"\(token)"}
        """
        let redacted = IMAPIClient.redactedSensitiveLogText(raw)

        XCTAssertFalse(redacted.contains(remark))
        XCTAssertFalse(redacted.contains(friendUID))
        XCTAssertFalse(redacted.contains(userID))
        XCTAssertFalse(redacted.contains(nickname))
        XCTAssertFalse(redacted.contains(displayName))
        XCTAssertFalse(redacted.contains(phone))
        XCTAssertFalse(redacted.contains(token))
        XCTAssertTrue(redacted.contains(requestID))

        let url = try XCTUnwrap(URL(string: "https://tenant.example.test/api/tenant/friends/friend%2Fwith%2Bspace%20%3F%23?friendRemark=%E5%AE%A2%E6%88%B7%E7%8E%8B%E6%80%BB&request_id=\(requestID)"))
        let redactedURL = IMAPIClient.redactedURLString(url, redactAllQueryValues: false)
        XCTAssertTrue(redactedURL.contains("/api/tenant/friends/hash-"))
        XCTAssertFalse(redactedURL.contains("friend%2Fwith"))
        XCTAssertFalse(redactedURL.contains("%E5%AE%A2%E6%88%B7%E7%8E%8B%E6%80%BB"))
        XCTAssertTrue(redactedURL.contains("request_id=\(requestID)"))
    }

    func testCurrentAppPolicyNormalizesBundleAppIDBeforeAuth() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        var context = makeContext()
        context.appID = "com.jianhuitongqiyetest.app"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","allow_workspace_switch":false,"allow_default_tenant_join":false,"support_contact_email":"","support_contact_configured":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)

        let didLoadPolicy = await state.refreshCurrentAppPolicyForAuthUI()

        XCTAssertTrue(didLoadPolicy)
        XCTAssertEqual(state.currentAppPolicy?.appID, "jianhuitong-ios")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.example.test/api/platform/apps/current-policy?app_id=jianhuitong-ios")
    }

    func testCurrentAppPolicyBootstrapsPlatformBaseFromHardcodedSeedDomain() async throws {
        clearStoredAPIContext()
        IMAppBootstrapLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppBootstrapLastGoodStore.clearAll()
        }
        let bootstrap = appBootstrapForHTTPWiring(platformBase: "https://platform.example.test")
        let transport = FakeHTTPTransport(results: [
            try apiSuccessResult(bootstrap),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = IMAPIClient(
            platformBase: IMAPIClient.releasePlaceholderPlatformBase,
            tenantBase: IMAPIClient.releasePlaceholderTenantBase,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [URL(string: "https://app-test.example.test")!],
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let policy = try await client.currentAppPolicy(appID: "jianhuitong-ios")

        XCTAssertEqual(policy.appID, "jianhuitong-ios")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://app-test.example.test/.well-known/wenxintong-app.json?app_id=jianhuitong-ios")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://platform.example.test/api/platform/apps/current-policy?app_id=jianhuitong-ios")
        XCTAssertEqual(client.platformBase.absoluteString, "https://platform.example.test")
    }

    func testGroupSummaryUsesSummaryEndpoint() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group":{"group_id":"g1","name":"全员公告群","member_count":503,"my_role":"admin"},"my_role":"admin","member_count":503,"member_preview":[{"im_uid":"u1","nickname":"群主","role":"owner","is_owner":true}],"counts":{"member_count":503,"pending_join_request_count":2,"file_count":3},"settings":{"invite_confirm_required":true,"file_count":3}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let summary = try await client.groupSummary(context: makeContext(), groupID: "g1")

        XCTAssertEqual(summary.summary.groupID, "g1")
        XCTAssertEqual(summary.memberCount, 503)
        XCTAssertEqual(summary.memberPreview.first?.imUID, "u1")
        XCTAssertEqual(summary.counts.pendingJoinRequestCount, 2)
        XCTAssertTrue(summary.settings.inviteConfirmRequired)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/g1/summary")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
    }

    func testSocialFriendCancellationUsesRequesterEndpointAndDecodesTerminalProjection() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"id":"application-1","applicant_uid":"uid-1","target_uid":"uid-2","status":"cancelled","tenant_review_status":"cancelled","direction":"outgoing","actionable_by_current_user":false,"peer_review_status":"cancelled","resolution_mode":"requester_cancel","outcome":"application_cancelled"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.cancelFriendApplication(context: makeContext(), id: "application-1")

        XCTAssertEqual(result.status, "cancelled")
        XCTAssertEqual(result.resolutionMode, "requester_cancel")
        XCTAssertEqual(result.outcome, "application_cancelled")
        XCTAssertEqual(result.actionableByCurrentUser, false)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/friends/applications/application-1/cancel")
        XCTAssertEqual(try requestJSONObject(request).count, 0)
    }

    func testSocialGroupDescriptionPatchPreservesExplicitClear() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group_id":"group-1","settings":{"description":""}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.updateGroupDescription(context: makeContext(), groupID: "group-1", description: "")

        XCTAssertEqual(result.settings.groupDescription, "")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/settings")
        let body = try requestJSONObject(request)
        XCTAssertNotNil(body["description"])
        XCTAssertEqual(body["description"] as? String, "")
    }

    func testGroupProfileAndSettingsMutationsSendOneSharedExpectedRevision() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group":{"group_id":"group-1","name":"Next","group_revision":8},"avatar_url":""}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group_id":"group-1","group_revision":9,"settings":{"description":"next","group_revision":9}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let profile = try await client.updateGroupProfile(
            context: makeContext(),
            groupID: "group-1",
            name: "Next",
            avatarFileID: nil,
            expectedGroupRevision: 7
        )
        let settings = try await client.updateGroupDescription(
            context: makeContext(),
            groupID: "group-1",
            description: "next",
            expectedGroupRevision: 8
        )

        XCTAssertEqual(profile.effectiveGroup.groupRevision, 8)
        XCTAssertEqual(settings.settings.groupRevision, 9)
        let requests = transport.requests()
        XCTAssertEqual(try requestJSONObject(requests[0])["expected_group_revision"] as? Int, 7)
        XCTAssertEqual(try requestJSONObject(requests[1])["expected_group_revision"] as? Int, 8)
    }

    func testSocialGroupSummaryOmittedDescriptionRemainsAbsentForLastGoodMerge() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group":{"group_id":"group-1","name":"Social"},"settings":{}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.groupSummary(context: makeContext(), groupID: "group-1")

        XCTAssertNil(result.summary.groupDescription)
        XCTAssertNil(result.settings.groupDescription)
    }

    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_BEGIN
    func testOwnerTransferProgressIsScopedAndOldOperationsCannotClearIt() throws {
        let state = AppState(apiContextOverride: makeContext())
        let store = state.groupModerationStore
        var progress: [Bool] = []
        var appUpdates = 0
        let ownerTransfer = store.ownerTransferPublisher(for: "group-a").sink { progress.append($0) }
        let app = state.objectWillChange.sink { appUpdates += 1 }
        defer {
            ownerTransfer.cancel()
            app.cancel()
        }

        let description = try XCTUnwrap(store.beginAdministration(.description, groupID: "group-a"))
        XCTAssertNil(store.beginAdministration(.description, groupID: "group-a"))
        _ = store.beginAdministration(.ownerTransfer, groupID: "group-b")
        XCTAssertEqual(progress, [false])

        let previous = try XCTUnwrap(store.beginAdministration(.ownerTransfer, groupID: "group-a"))
        XCTAssertNil(store.beginAdministration(.ownerTransfer, groupID: "group-a"))
        store.finishAdministration(.description, id: description, groupID: "group-a")
        XCTAssertEqual(progress, [false, true])

        store.reset()
        let current = try XCTUnwrap(store.beginAdministration(.ownerTransfer, groupID: "group-a"))
        store.finishAdministration(.ownerTransfer, id: previous, groupID: "group-a")
        XCTAssertTrue(store.ownsAdministration(.ownerTransfer, id: current, groupID: "group-a"))
        XCTAssertTrue(store.isTransferringOwner(groupID: "group-a"))
        store.finishAdministration(.ownerTransfer, id: current, groupID: "group-a")
        XCTAssertEqual(progress, [false, true, false, true, false])
        XCTAssertEqual(appUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_END

    func testSocialGroupOwnerTransferSendsBoundedIdempotencyKeyAndDecodesResult() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group":{"group_id":"group-1","name":"Social","owner_uid":"uid-2"},"previous_owner_uid":"uid-1","new_owner_uid":"uid-2","old_owner_role":"member","previous_owner":{"im_uid":"uid-1","role":"member"},"new_owner":{"im_uid":"uid-2","role":"owner"},"transferred_at":"2026-08-13T10:00:00Z","idempotent":false}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let key = UUID().uuidString.lowercased()

        let result = try await client.transferGroupOwner(
            context: makeContext(),
            groupID: "group-1",
            newOwnerUID: "uid-2",
            idempotencyKey: key
        )

        XCTAssertEqual(result.previousOwnerUID, "uid-1")
        XCTAssertEqual(result.newOwnerUID, "uid-2")
        XCTAssertEqual(result.oldOwnerRole, "member")
        XCTAssertFalse(result.idempotent)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/owner/transfer")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), key)
        XCTAssertLessThanOrEqual(try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key")).count, 128)
        XCTAssertEqual(try requestJSONObject(request)["new_owner_uid"] as? String, "uid-2")
    }

    func testSocialGroupAnnouncementPatchKeepsStableIDRawRevisionAndPrivacyGatedCounts() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"id":"announcement-1","announcement_id":"announcement-1","group_id":"group-1","title":"更新","content":"新正文","updated_at":"2026-08-13T10:01:02.123456Z","unread":true,"can_view_read_counts":true,"read_count":2,"unread_count":3,"recipient_count":5}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let revision = "2026-08-13T09:00:00.123456Z"

        let result = try await client.updateGroupAnnouncement(
            context: makeContext(),
            groupID: "group-1",
            announcementID: "announcement-1",
            title: "更新",
            content: "新正文",
            expectedUpdatedAt: revision
        )

        XCTAssertEqual(result.id, "announcement-1")
        XCTAssertEqual(result.updatedAt, "2026-08-13T10:01:02.123456Z")
        XCTAssertTrue(result.canViewReadCounts)
        XCTAssertEqual(result.readCount, 2)
        XCTAssertEqual(result.unreadCount, 3)
        XCTAssertEqual(result.recipientCount, 5)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/announcements/announcement-1")
        let body = try requestJSONObject(request)
        XCTAssertEqual(body["expected_updated_at"] as? String, revision)
        XCTAssertEqual(body["content"] as? String, "新正文")
    }
}

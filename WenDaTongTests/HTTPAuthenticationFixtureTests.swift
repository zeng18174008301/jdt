import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func tenantEnterSuccess(
        entryTicket: String,
        routes: IMRuntimeRouteSnapshot,
        tenantBaseURLOverride: String? = nil,
        imBaseURLOverride: String? = nil
    ) throws -> HTTPTransportResult {
        let declaredTenantBaseURL = try XCTUnwrap(routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first)
        let declaredIMBaseURL = try XCTUnwrap(routes.services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first)
        let tenantBaseURL = tenantBaseURLOverride ?? declaredTenantBaseURL
        let imBaseURL = imBaseURLOverride ?? declaredIMBaseURL
        let tenantID = try XCTUnwrap(routes.tenantID)
        let runtimeConfig: [String: Any] = [
            "tenant_api_base_url": tenantBaseURL,
            "tenant_api_base_url_source": "tenant_deployment_config",
            "tenant_api_base_url_configured": true,
            "im_api_base_url": imBaseURL,
            "contract_version": routes.contractVersion,
            "app_id": routes.appID,
            "tenant_id": tenantID,
            "route_revision": NSNumber(value: routes.revision),
            "route_source": routes.source,
            "route_status": routes.status,
            "route_hash": routes.configHash,
            "routes": routes.services.mapValues(\.canonicalJSONObject),
            "routing_policy": routes.policy.canonicalJSONObject,
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "data": [
                "entry_ticket": entryTicket,
                "runtime_config": runtimeConfig,
            ],
        ])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func tenantPlatformEntrySuccess(includeTenantPresentation: Bool = true) throws -> HTTPTransportResult {
        var payload: [String: Any] = [
            "tenant_id": "tenant-1",
            "member": [
                "tenant_id": "tenant-1",
                "account_id": "account-1",
                "im_uid": "uid-1",
                "status": "active",
                "role": "member",
            ],
            "im_uid": "uid-1",
            "im_token": "im-token-new",
            "app_id": "jianhuitong-ios",
            "device_id": "device-1",
            "auth_session": [
                "session_id": "tenant-session-1",
                "refresh_token": "tenant-refresh-1",
                "expires_at": 1_895_000_000,
                "tenant_id": "tenant-1",
                "app_id": "jianhuitong-ios",
                "device_id": "device-1",
                "client_type": "ios",
                "token_type": "im",
            ],
        ]
        if includeTenantPresentation {
            payload["tenant"] = [
                "tenant_id": "tenant-1",
                "name": "Local Tenant",
                "tenant_code": "WXT000001",
                "status": "active",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func registrationTenantEntrySuccess(tenantID: String) throws -> HTTPTransportResult {
        let original = try tenantPlatformEntrySuccess()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: original.data) as? [String: Any])
        var data = try XCTUnwrap(envelope["data"] as? [String: Any])
        data["tenant_id"] = tenantID
        data["im_token"] = "tenant-authoritative-token"
        for key in ["tenant", "member", "auth_session"] {
            var nested = try XCTUnwrap(data[key] as? [String: Any])
            nested["tenant_id"] = tenantID
            if key == "auth_session" { nested["session_id"] = "trs_registration" }
            data[key] = nested
        }
        envelope["data"] = data
        return HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: envelope), isHTTPResponse: true, statusCode: 200)
    }

    func enterpriseFirstPolicySuccess() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func slideCaptchaDisabledSuccess() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"enabled":false,"available":false,"required":false,"provider":"self_hosted_slide","surface":"ios","scene":"im_user_login"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func atomicEnterpriseLoginSuccess(
        routes: IMRuntimeRouteSnapshot,
        topLevelAppID: String? = nil,
        topLevelDeviceID: String? = nil,
        nestedAppID: String? = nil,
        nestedDeviceID: String? = nil,
        nestedTenantID: String? = nil,
        responseTenantID: String? = nil
    ) throws -> HTTPTransportResult {
        let runtimeTenantID = try XCTUnwrap(routes.tenantID)
        let tenantID = responseTenantID ?? runtimeTenantID
        let authTenantID = nestedTenantID ?? tenantID
        let tenantBaseURL = try XCTUnwrap(
            routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first
        )
        let imBaseURL = try XCTUnwrap(
            routes.services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first
        )
        let runtimeConfig: [String: Any] = [
            "tenant_api_base_url": tenantBaseURL,
            "tenant_api_base_url_source": "tenant_deployment_config",
            "tenant_api_base_url_configured": true,
            "im_api_base_url": imBaseURL,
            "contract_version": routes.contractVersion,
            "app_id": routes.appID,
            "tenant_id": runtimeTenantID,
            "route_revision": NSNumber(value: routes.revision),
            "route_source": routes.source,
            "route_status": routes.status,
            "route_hash": routes.configHash,
            "routes": routes.services.mapValues(\.canonicalJSONObject),
            "routing_policy": routes.policy.canonicalJSONObject,
        ]
        var session: [String: Any] = [
            "tenant": [
                "tenant_id": tenantID,
                "tenant_code": "WXT000001",
                "name": "Enterprise Tenant",
                "status": "active",
            ],
            "member": [
                "tenant_id": tenantID,
                "account_id": "account-enterprise",
                "im_uid": "uid-enterprise",
                "status": "active",
                "role": "member",
            ],
            "im_uid": "uid-enterprise",
            "im_token": "im-token-enterprise",
            "expires_at": 1_895_000_000,
            "auth_session": [
                "session_id": "tenant-session-enterprise",
                "refresh_token": "tenant-refresh-enterprise",
                "expires_at": 1_895_000_000,
                "tenant_id": authTenantID,
                "app_id": nestedAppID ?? routes.appID,
                "device_id": nestedDeviceID ?? "device-1",
                "client_type": "ios",
                "token_type": "im",
            ],
        ]
        if let topLevelAppID {
            session["app_id"] = topLevelAppID
        }
        if let topLevelDeviceID {
            session["device_id"] = topLevelDeviceID
        }
        let payload: [String: Any] = [
            "account": [
                "id": "account-enterprise",
                "username": "member-enterprise",
                "status": "normal",
            ],
            "platform_token": "platform-token-enterprise",
            "auth_session": [
                "session_id": "platform-session-enterprise",
                "refresh_token": "platform-refresh-enterprise",
                "expires_at": 1_895_000_000,
                "app_id": routes.appID,
                "device_id": "device-1",
                "client_type": "ios",
                "token_type": "platform",
            ],
            "tenant": [
                "tenant_id": tenantID,
                "tenant_code": "WXT000001",
                "name": "Enterprise Tenant",
                "status": "active",
            ],
            "can_direct_enter": true,
            "requires_workspace_selection": false,
            "entry_status": "entered",
            "auto_entered_workspace_id": tenantID,
            "session": session,
            "runtime_config": runtimeConfig,
        ]
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func enterprisePendingLoginSuccess(routes: IMRuntimeRouteSnapshot) throws -> HTTPTransportResult {
        let tenantID = try XCTUnwrap(routes.tenantID)
        let tenantBaseURL = try XCTUnwrap(
            routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first
        )
        let imBaseURL = try XCTUnwrap(
            routes.services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first
        )
        let payload: [String: Any] = [
            "account": [
                "id": "account-enterprise",
                "username": "member-enterprise",
                "status": "normal",
            ],
            "platform_token": "platform-token-enterprise",
            "auth_session": [
                "session_id": "platform-session-enterprise",
                "refresh_token": "platform-refresh-enterprise",
                "expires_at": 1_895_000_000,
                "app_id": routes.appID,
                "device_id": "device-1",
                "client_type": "ios",
                "token_type": "platform",
            ],
            "can_direct_enter": false,
            "requires_workspace_selection": false,
            "entry_status": "pending",
            "pending_entry_tenant_id": tenantID,
            "pending_approval_count": 1,
            "runtime_config": [
                "tenant_api_base_url": tenantBaseURL,
                "tenant_api_base_url_source": "tenant_deployment_config",
                "tenant_api_base_url_configured": true,
                "im_api_base_url": imBaseURL,
                "contract_version": routes.contractVersion,
                "app_id": routes.appID,
                "tenant_id": tenantID,
                "route_revision": NSNumber(value: routes.revision),
                "route_source": routes.source,
                "route_status": routes.status,
                "route_hash": routes.configHash,
                "routes": routes.services.mapValues(\.canonicalJSONObject),
                "routing_policy": routes.policy.canonicalJSONObject,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func assertEnterpriseFirstLoginRejected(
        resolvedRoutes: IMRuntimeRouteSnapshot,
        loginResult: HTTPTransportResult
    ) async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let sessionStore = InMemoryProtectedSessionStore()
        let transport = FakeHTTPTransport(results: [
            enterpriseFirstPolicySuccess(),
            try enterpriseContextSuccess(routes: resolvedRoutes, tenantCode: "WXT000001"),
            slideCaptchaDisabledSuccess(),
            loginResult,
        ])
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: "WXT000001")
        XCTAssertTrue(policyLoaded)
        XCTAssertTrue(contextResolved)
        state.startLoginFlow(identifier: "member-rejected", password: "SyntheticPass123!")
        try await waitForCondition(iterations: 120) {
            state.toast == "企业码验证已失效，请重新输入" && !state.isAuthLoading
        }

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertNil(state.preAuthEnterpriseContext)
        XCTAssertFalse(IMAPIContext.load(sessionStore: sessionStore).hasIMSession)
        XCTAssertEqual(state.authScreen, .enterpriseCode)
    }

    func registrationSessionRecoverySuccess() throws -> HTTPTransportResult {
        let original = try atomicRegistrationSuccess(requestedTenantCode: "553222", canonicalTenantCode: "WXT000001")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: original.data) as? [String: Any])
        var data = try XCTUnwrap(envelope["data"] as? [String: Any])
        data.removeValue(forKey: "session")
        data.removeValue(forKey: "runtime_config")
        data["tenant_id"] = "tenant-1"
        data["entry_status"] = "registration_session_ready"
        data["can_direct_enter"] = false
        envelope["data"] = data
        return HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: envelope), isHTTPResponse: true, statusCode: 200)
    }

    func atomicRegistrationSuccess(
        requestedTenantCode: String,
        canonicalTenantCode: String,
        routes: IMRuntimeRouteSnapshot? = nil,
        sessionTenantID: String? = nil,
        legacyTenantAPIBaseURL: String = "https://tenant.example.test",
        fallbackToDefaultTenant: Bool = false,
        statusCode: Int = 200
    ) throws -> HTTPTransportResult {
        let runtimeTenantID = routes?.tenantID ?? "tenant-1"
        let tenantID = sessionTenantID ?? runtimeTenantID
        var payload: [String: Any] = [
            "account": [
                "id": "account-1",
                "username": "admin12",
                "status": "normal",
            ],
            "app_id": "jianhuitong-ios",
            "device_id": "device-1",
            "platform_token": "platform-token-redacted",
            "auth_session": [
                "session_id": "platform-session",
                "refresh_token": "platform-refresh",
                "expires_at": 1_895_000_000,
                "app_id": "jianhuitong-ios",
                "device_id": "device-1",
                "client_type": "ios",
                "token_type": "platform",
            ],
            "requested_tenant_code": requestedTenantCode,
            "fallback_to_default_tenant": fallbackToDefaultTenant,
            "tenant": [
                "tenant_id": runtimeTenantID,
                "tenant_code": canonicalTenantCode,
                "name": "Invite Tenant",
                "status": "active",
            ],
            "tenant_member": [
                "tenant_id": runtimeTenantID,
                "account_id": "account-1",
                "im_uid": "uid-1",
                "status": "active",
                "role": "member",
            ],
            "requires_approval": false,
            "can_direct_enter": true,
            "entry_status": "entered",
            "requires_workspace_selection": false,
            "session": [
                "tenant": [
                    "tenant_id": tenantID,
                    "tenant_code": canonicalTenantCode,
                    "name": "Invite Tenant",
                    "status": "active",
                ],
                "server": [
                    "name": "Tenant Server",
                    "api_host": legacyTenantAPIBaseURL,
                    "gateway_host": "https://im.example.test",
                    "im_ws_host": "wss://im.example.test/ws",
                    "im_tcp_addr": "im.example.test:443",
                ],
                "app": ["app_id": "jianhuitong-ios"],
                "member": [
                    "tenant_id": tenantID,
                    "account_id": "account-1",
                    "im_uid": "uid-1",
                    "status": "active",
                    "role": "member",
                ],
                "im_uid": "uid-1",
                "im_token": "im-token-new",
                "auth_session": [
                    "session_id": "tenant-session-1",
                    "refresh_token": "tenant-refresh-1",
                    "expires_at": 1_895_000_000,
                    "tenant_id": tenantID,
                    "app_id": "jianhuitong-ios",
                    "device_id": "device-1",
                    "client_type": "ios",
                    "token_type": "im",
                ],
            ],
        ]
        if let routes {
            let tenantBaseURL = try XCTUnwrap(routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first)
            let imBaseURL = try XCTUnwrap(routes.services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first)
            payload["runtime_config"] = [
                "tenant_api_base_url": tenantBaseURL,
                "tenant_api_base_url_source": "tenant_deployment_config",
                "tenant_api_base_url_configured": true,
                "im_api_base_url": imBaseURL,
                "contract_version": routes.contractVersion,
                "app_id": routes.appID,
                "tenant_id": runtimeTenantID,
                "route_revision": NSNumber(value: routes.revision),
                "route_source": routes.source,
                "route_status": routes.status,
                "route_hash": routes.configHash,
                "routes": routes.services.mapValues(\.canonicalJSONObject),
                "routing_policy": routes.policy.canonicalJSONObject,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: statusCode)
    }

    func assertEnterpriseFirstInviteRegistrationIdentityMismatch(
        responseCanonicalTenantCode: String,
        responseTenantID: String
    ) async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-invite", revision: 15)
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
                canonicalTenantCode: responseCanonicalTenantCode,
                routes: routes,
                sessionTenantID: responseTenantID,
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
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: "YQM7K9P2A1B")
        XCTAssertTrue(contextResolved)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.registerAndEnterIM(account: "admin14", password: "aa123456", enterpriseCode: "")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertFalse(IMAPIContext.load(sessionStore: sessionStore).hasIMSession)
        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage)
        XCTAssertTrue(state.isRegistrationSubmissionBlocked)
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path == "/api/platform/auth/register" }.count,
            1
        )
    }

    func enterpriseContextSuccess(
        routes: IMRuntimeRouteSnapshot,
        tenantCode: String,
        canonicalTenantCode: String? = nil,
        entryType explicitEntryType: String? = nil,
        scheme explicitScheme: String? = nil,
        canonicalEntryCode: String? = nil,
        includeAdditiveAuthority: Bool = true
    ) throws -> HTTPTransportResult {
        let tenantID = try XCTUnwrap(routes.tenantID)
        let canonicalCode = canonicalTenantCode ?? tenantCode
        let entryCode = try XCTUnwrap(RegistrationFlowPolicy.normalizedEntryCode(tenantCode))
        let entryType = explicitEntryType
            ?? (entryCode.kind == .memberInvitation ? "member_invite_code" : "enterprise_code")
        let scheme = explicitScheme
            ?? (tenantCode.uppercased().hasPrefix("YQM") ? "legacy_yqm"
                : (tenantCode.uppercased().hasPrefix("WXT") ? "legacy_wxt" : "unified_v1"))
        let tenantBaseURL = try XCTUnwrap(routes.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.first)
        let imBaseURL = try XCTUnwrap(routes.services[IMRuntimeRouteService.imAPI.rawValue]?.preferred.first)
        let runtimeConfig: [String: Any] = [
            "tenant_api_base_url": tenantBaseURL,
            "tenant_api_base_url_source": "tenant_deployment_config",
            "tenant_api_base_url_configured": true,
            "im_api_base_url": imBaseURL,
            "contract_version": routes.contractVersion,
            "app_id": routes.appID,
            "tenant_id": tenantID,
            "route_revision": NSNumber(value: routes.revision),
            "route_source": routes.source,
            "route_status": routes.status,
            "route_hash": routes.configHash,
            "routes": routes.services.mapValues(\.canonicalJSONObject),
            "routing_policy": routes.policy.canonicalJSONObject,
        ]
        var payload: [String: Any] = [
            "app_id": routes.appID,
            "tenant_id": tenantID,
            "tenant_code": canonicalCode,
            "tenant_name": "Resolved Tenant",
            "tenant_logo_url": "https://tenant.example.test/assets/logo.png",
            "entry_type": entryType,
            "tenant": [
                "tenant_id": tenantID,
                "tenant_code": canonicalCode,
                "name": "Resolved Tenant",
                "logo_url": "https://tenant.example.test/assets/logo.png",
                "logo_status": "active",
                "logo_version": "3",
                "logo_cache_key": "tenant-logo-v3",
                "logo_mime": "image/png",
                "logo_width": 256,
                "logo_height": 256,
            ],
            "context_token": "enterprise-proof-test-only",
            "expires_at": NSNumber(value: Int64(Date().addingTimeInterval(300).timeIntervalSince1970)),
            "ttl_seconds": 300,
            "route_revision": NSNumber(value: routes.revision),
            "runtime_config": runtimeConfig,
        ]
        if includeAdditiveAuthority {
            payload["scheme"] = scheme
            payload["canonical"] = canonicalEntryCode ?? entryCode.normalizedValue
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func makeRTCQualityToken(scopes: [String]) throws -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payload = try JSONSerialization.data(withJSONObject: ["scopes": scopes])
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    func preauthDeviceProofSuccess(proof: String, expiresAt: String) -> HTTPTransportResult {
        let payload = [
            "ok": true,
            "data": [
                "device_proof": proof,
                "expires_at": expiresAt
            ]
        ] as [String: Any]
        return HTTPTransportResult(
            data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func phoneCaptchaSuccess(requestID: String) -> HTTPTransportResult {
        let payload = [
            "ok": true,
            "data": [
                "sent": true,
                "request_id": requestID,
                "phone_masked": "138****0000",
                "expires_in_seconds": 600,
                "cooldown_seconds": 60
            ]
        ] as [String: Any]
        return HTTPTransportResult(
            data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func requestJSONObject(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func persistedUserDefaultsContain(_ needle: String) -> Bool {
        UserDefaults.standard.dictionaryRepresentation().values.contains {
            persistedValue($0, contains: needle)
        }
    }

    private func persistedValue(_ value: Any, contains needle: String) -> Bool {
        if let string = value as? String {
            return string.contains(needle)
        }
        if let data = value as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string.contains(needle)
        }
        if let values = value as? [Any] {
            return values.contains { persistedValue($0, contains: needle) }
        }
        if let values = value as? [String: Any] {
            return values.values.contains { persistedValue($0, contains: needle) }
        }
        return false
    }

    func waitForCondition(
        iterations: Int = 80,
        _ condition: @escaping () -> Bool
    ) async throws {
        for _ in 0..<iterations {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func awaitMessage(
        in state: AppState,
        conversationID: String,
        matching predicate: @escaping (ChatMessage) -> Bool
    ) async throws -> ChatMessage {
        let matched = expectation(description: "attachment message state")
        matched.assertForOverFulfill = false
        var resolved: ChatMessage?
        let observation = state.conversationStore.memoryUpdates.map { _ in state.conversationStore.conversationMessageSnapshots() }.eraseToAnyPublisher().sink { conversations in // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            guard resolved == nil,
                  let message = conversations
                    .first(where: { $0.id == conversationID })?
                    .messages
                    .first(where: predicate) else { return }
            resolved = message
            matched.fulfill()
        }
        await fulfillment(of: [matched], timeout: 3)
        observation.cancel()
        return try XCTUnwrap(resolved)
    }

    func gifFixtureBytes(count: Int? = nil) -> Data {
        var data = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        if let count, count > data.count { data.append(Data(repeating: 0, count: count - data.count)) }
        return data
    }

    func gifRecoveryMessage() -> ChatMessage {
        var message = ChatMessage(id: "msg-gif", senderId: "uid-2", senderName: "对方", text: "图片消息.gif", time: "刚刚",
            isOutgoing: false, status: .sent, kind: .image, reactions: [], readBy: [], unreadBy: [], quote: nil,
            attachmentName: "图片消息.gif", attachmentMeta: "GIF")
        message.attachmentFileID = "file-gif"
        message.attachmentMimeType = "image/gif"
        message.attachmentSizeBytes = Int64(gifFixtureBytes().count)
        message.attachmentExtension = "gif"
        message.attachmentMediaCategory = "image"
        return message
    }

    func gifFileDetailResult(downloadURL: String = "", sizeBytes: Int? = nil, mimeType: String = "image/gif", downloadAllowed: Bool = true, previewAllowed: Bool = true, status: String = "uploaded", fileExtension: String = "gif") -> HTTPTransportResult {
        let thumbnail = "https://object.example.test/thumbnail.png"
        let body: [String: Any] = ["ok": true, "data": [
            "file": ["file_id": "file-gif", "file_name": "图片消息.gif", "mime_type": mimeType,
                "size_bytes": sizeBytes ?? gifFixtureBytes().count, "status": status, "extension": fileExtension,
                "media_category": "image", "thumbnail_url": thumbnail, "width": 1, "height": 1],
            "download_available": downloadAllowed, "download_url": downloadURL,
            "preview_available": previewAllowed, "preview_url": thumbnail,
            "download": ["url": downloadURL, "method": "GET", "headers": [:]]
        ]]
        return HTTPTransportResult(data: try! JSONSerialization.data(withJSONObject: body), isHTTPResponse: true, statusCode: 200)
    }

    func pngFixtureBytes(count: Int) -> Data {
        let basePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        precondition(count >= basePNG.count)
        var bytes = basePNG
        bytes.append(Data(repeating: 0, count: count - bytes.count))
        return bytes
    }

    func attachmentConfigResult() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"max_bytes":20971520}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func videoUploadFixture(_ status: Int, _ payload: [String: Any]) -> HTTPTransportResult {
        HTTPTransportResult(data: try! JSONSerialization.data(withJSONObject: payload), isHTTPResponse: true, statusCode: status)
    }

    func videoPresignFixture(fileID: String, url: String, transport: String, size: Int) -> HTTPTransportResult {
        videoUploadFixture(200, ["ok": true, "data": [
            "file": ["file_id": fileID, "status": "prepared", "mime_type": "video/mp4", "size_bytes": size],
            "upload": ["url": url, "method": "PUT", "transport": transport]
        ]])
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_BEGIN
    func testConcurrentLegalDocumentLoadsKeepErrorsWithTheirOwnDocument() async throws {
        let state = AppState(api: makeClient(transport: IndependentLegalDocumentHTTPTransport()), apiContextOverride: makeContext())
        async let terms = state.legalDocumentContent(for: .terms)
        async let privacy = state.legalDocumentContent(for: .privacy)
        let (termsResult, privacyResult) = await (terms, privacy)

        guard case let .failure(error) = termsResult else { return XCTFail("用户协议应返回本次加载的错误") }
        XCTAssertEqual(error.message, "协议内容暂不可用，请稍后再试")
        let content = try privacyResult.get()
        XCTAssertEqual(content.type, .privacy)
        XCTAssertEqual(content.sourceURL, LegalDocumentType.privacy.fixedWebURL)
        XCTAssertEqual(content.html, "<html><body>privacy</body></html>")
        XCTAssertNil(state.toast)
    }
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_END

    func testLegalDocumentContentUsesFixedTermsURLWhenBootstrapLegalManifestExists() async throws {
        clearStoredAPIContext()
        IMAppBootstrapLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppBootstrapLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("<html><body>fixed terms</body></html>".utf8),
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

        let content = try await client.legalDocumentContent(
            type: .terms,
            appID: "com.jianhuitongqiyetest.app",
            context: nil
        )

        XCTAssertEqual(content.html, "<html><body>fixed terms</body></html>")
        XCTAssertEqual(content.manifest.manifestRevision, 0)
        XCTAssertEqual(content.sourceURL.absoluteString, "https://wdatong.cn/ios_yonghu.html")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://wdatong.cn/ios_yonghu.html")
    }

    func testLegalDocumentContentUsesFixedTermsURLWhenTenantContextExists() async throws {
        clearStoredAPIContext()
        IMAppBootstrapLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppBootstrapLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("<html><body>fixed terms tenant context</body></html>".utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [URL(string: "https://app-test.example.test")!],
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let content = try await client.legalDocumentContent(
            type: .terms,
            appID: "jht-ios-main",
            context: makeContext()
        )

        let manifest = content.manifest
        XCTAssertEqual(manifest.appID, "jianhuitong-ios")
        XCTAssertEqual(content.html, "<html><body>fixed terms tenant context</body></html>")
        XCTAssertEqual(content.sourceURL.absoluteString, "https://wdatong.cn/ios_yonghu.html")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://wdatong.cn/ios_yonghu.html")
        XCTAssertFalse(requests.contains { $0.url?.host == "app-test.example.test" })
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testLegalDocsManifestPathsUseCanonicalAppID() {
        XCTAssertEqual(
            IMAPIClient.platformLegalDocsManifestPath(appID: "jht-ios-main"),
            "/api/app/legal-docs?app_id=jianhuitong-ios"
        )
        XCTAssertEqual(
            IMAPIClient.tenantLegalDocsManifestPath(appID: "com.jianhuitongqiyetest.app"),
            "/api/tenant/public/legal-docs?app_id=jianhuitong-ios"
        )
    }

    func testLegalDocAssetURLRequiresSameAPIOrigin() throws {
        let base = URL(string: "https://api.example.test:8443")!
        XCTAssertEqual(
            try IMAPIClient.resolvedLegalDocAssetURL(
                "/api/app/legal-docs?app_id=jianhuitong-ios&doc_type=terms&version=1&manifest_hash=hash-1",
                base: base
            ).absoluteString,
            "https://api.example.test:8443/api/app/legal-docs?app_id=jianhuitong-ios&doc_type=terms&version=1&manifest_hash=hash-1"
        )

        XCTAssertThrowsError(
            try IMAPIClient.resolvedLegalDocAssetURL(
                "https://cdn.example.test/legal/terms.html",
                base: base
            )
        )
        XCTAssertThrowsError(
            try IMAPIClient.resolvedLegalDocAssetURL(
                "https://api.example.test/api/app/legal-docs?app_id=jianhuitong-ios",
                base: base
            )
        )
        XCTAssertThrowsError(
            try IMAPIClient.resolvedLegalDocAssetURL(
                "https://api.example.test:443/api/app/legal-docs?app_id=jianhuitong-ios",
                base: base
            )
        )
    }

    func testCurrentAppPolicyForceRefreshBypassesHTTPPolicyCache() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"support_contact_email":"haha@qq.com","support_contact_configured":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let policy = try await client.currentAppPolicy(appID: "jht-ios-main", forceRefresh: true)

        XCTAssertEqual(policy.supportContactEmail, "haha@qq.com")
        let request = try XCTUnwrap(transport.requests().first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "platform.example.test")
        XCTAssertEqual(url.path, "/api/platform/apps/current-policy")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "app_id" })?.value, "jianhuitong-ios")
        XCTAssertNotNil(components?.queryItems?.first(where: { $0.name == "_ts" })?.value)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testTenantIMSessionRefreshUsesTenantBaseBearerAndBindingBody() async throws {
        var context = makeContext()
        context.appID = "jht-ios-main"
        context.deviceID = "ios-device-1"
        context.imToken = "old-im-token"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_token":"new-im-token","expires_at":1782600000,"im_uid":"uid-1","tenant_id":"tenant-1","app_id":"jht-ios-main","device_id":"ios-device-1","token_type":"im"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.refreshTenantIMSession(context: context, expiresInSeconds: 600)

        XCTAssertEqual(result.imToken, "new-im-token")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/auth/session/refresh")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(body["device_id"] as? String, "ios-device-1")
        XCTAssertEqual(body["expires_in_seconds"] as? Int, 600)
        XCTAssertNil(body["refresh_token"])
    }

    func testListMyTenantsUsesAppScopedDirectoryContract() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","app_scoped":true,"workspace_count":2,"enterable_workspace_count":1,"selection_mode":"workspace_selection","empty_reason":"","workspaces":[{"tenant_id":"tenant-ready","name":"Ready Tenant","tenant_code":"WXT000001","status":"active","join_status":"joined","member_status":"active","member_role":"member","member_im_uid":"uid-ready","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound","member_projection_status":"applied"},{"tenant_id":"tenant-pending","name":"Pending Tenant","tenant_code":"WXT000002","status":"active","join_status":"joined","member_status":"active","member_role":"member","account_id":"account-1","can_enter":false,"can_switch":false,"reason_code":"member_projection_syncing","reason_text":"enterprise member is syncing","app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound","member_projection_status":"pending","member_projection_reason_code":"member_projection_syncing"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let memberships = try await client.listMyTenants(platformToken: "platform-token", appID: "com.jianhuitongqiyetest.app")

        XCTAssertEqual(memberships.count, 2)
        XCTAssertEqual(memberships[0].tenant.id, "tenant-ready")
        XCTAssertEqual(memberships[0].enterable, true)
        XCTAssertEqual(memberships[1].tenant.id, "tenant-pending")
        XCTAssertEqual(memberships[1].canSwitch, false)
        XCTAssertEqual(memberships[1].disabledReason, "member_projection_syncing")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.example.test/api/platform/me/tenants?app_id=jianhuitong-ios")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
    }

    func testListMyTenantsPromotesOnlyAppliedProjectionSyncingRows() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","app_scoped":true,"workspace_count":4,"enterable_workspace_count":1,"selection_mode":"workspace_selection","workspaces":[{"tenant_id":"tenant-ready","name":"Ready Tenant","tenant_code":"WXT000001","status":"active","join_status":"joined","member_status":"active","member_role":"member","can_enter":false,"can_switch":false,"reason_code":"member_projection_syncing","reason_text":"enterprise member is syncing","member_projection_status":"applied"},{"tenant_id":"tenant-pending","name":"Pending Tenant","tenant_code":"WXT000002","status":"active","join_status":"joined","member_status":"active","member_role":"member","can_enter":false,"can_switch":false,"reason_code":"member_projection_syncing","member_projection_status":"pending"},{"tenant_id":"tenant-failed","name":"Failed Tenant","tenant_code":"WXT000003","status":"active","join_status":"joined","member_status":"active","member_role":"member","can_enter":false,"can_switch":false,"member_projection_status":"failed"},{"tenant_id":"tenant-policy","name":"Policy Tenant","tenant_code":"WXT000004","status":"active","join_status":"joined","member_status":"active","member_role":"member","can_enter":true,"can_switch":false,"reason_code":"workspace_switch_disabled","member_projection_status":"applied"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let memberships = try await client.listMyTenants(platformToken: "platform-token", appID: "jianhuitong-ios")

        let ready = try XCTUnwrap(memberships.first { $0.tenant.id == "tenant-ready" })
        XCTAssertEqual(ready.enterable, true)
        XCTAssertEqual(ready.canSwitch, true)
        XCTAssertTrue(ready.disabledReason.isEmpty)

        let pending = try XCTUnwrap(memberships.first { $0.tenant.id == "tenant-pending" })
        XCTAssertEqual(pending.enterable, false)
        XCTAssertEqual(pending.canSwitch, false)
        XCTAssertEqual(pending.disabledReason, "member_projection_syncing")

        let failed = try XCTUnwrap(memberships.first { $0.tenant.id == "tenant-failed" })
        XCTAssertEqual(failed.enterable, false)
        XCTAssertEqual(failed.canSwitch, false)
        XCTAssertEqual(failed.disabledReason, "member_projection_failed")

        let policy = try XCTUnwrap(memberships.first { $0.tenant.id == "tenant-policy" })
        XCTAssertEqual(policy.enterable, true)
        XCTAssertEqual(policy.canSwitch, false)
        XCTAssertEqual(policy.disabledReason, "workspace_switch_disabled")
    }

    func testPlatformTenantSearchJoinAndLegacySwitchCarryFixedAppID() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"tenant_id":"tenant-1","tenant_code":"WXT123456","name":"Bound Tenant","status":"active"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"tenant":{"tenant_id":"tenant-1","tenant_code":"WXT123456","name":"Bound Tenant","status":"active"},"member":{"tenant_id":"tenant-1","account_id":"account-1","im_uid":"uid-1","status":"active","role":"member"},"join_status":"joined","can_enter":true,"can_switch":true}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"tenant":{"tenant_id":"tenant-1","tenant_code":"WXT123456","name":"Bound Tenant","status":"active"},"app":{"app_id":"jianhuitong-ios"},"member":{"tenant_id":"tenant-1","account_id":"account-1","im_uid":"uid-1","status":"active","role":"member"},"im_uid":"uid-1","im_token":"im-token-redacted"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let tenant = try await client.searchTenant(code: " wxt123456 ", platformToken: "platform-token", appID: "com.jianhuitongqiyetest.app")
        let membership = try await client.joinTenant(code: " wxt123456 ", platformToken: "platform-token", appID: "jht-ios-main")
        let switched = try await client.switchTenant(tenantID: "tenant-1", platformToken: "platform-token", appID: "web-main", deviceID: "ios-device-1")

        XCTAssertEqual(tenant.id, "tenant-1")
        XCTAssertEqual(membership.tenant.id, "tenant-1")
        XCTAssertEqual(switched.tenant.id, "tenant-1")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://platform.example.test/api/platform/tenants/search?tenant_code=WXT123456&app_id=jianhuitong-ios")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://platform.example.test/api/platform/tenants/join")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
        let joinBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(joinBody["tenant_code"] as? String, "WXT123456")
        XCTAssertEqual(joinBody["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(requests[2].url?.absoluteString, "https://platform.example.test/api/platform/tenants/tenant-1/switch")
        XCTAssertEqual(requests[2].httpMethod, "POST")
        let switchBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(switchBody["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(switchBody["device_id"] as? String, "ios-device-1")
    }

    func testAppTenantNotBoundMapsToWorkspaceNotFoundCopy() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"app_tenant_not_bound","message":"tenant exists but is not bound to this app"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 404
            )
        ])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.searchTenant(code: "WXT123456", platformToken: "platform-token", appID: "jianhuitong-ios")
            XCTFail("Expected app_tenant_not_bound to fail")
        } catch IMAPIError.server(let message) {
            XCTAssertEqual(message, "目标企业不存在，请返回企业列表重新选择")
            XCTAssertFalse(message.contains("未绑定"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("bound"))
        }
    }

    func testEnterTenantAndPlatformEntryUseFinalP4ContractAndTenantBasePrefix() async throws {
        let routes = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant-a.example.test"]
        )
        let transport = FakeHTTPTransport(results: [
            try tenantEnterSuccess(
                entryTicket: "entry-ticket-test",
                routes: routes,
                tenantBaseURLOverride: "https://tenant-a.example.test/tenant-api?debug=true#frag",
                imBaseURLOverride: "https://im-a.example.test/gateway?debug=true#frag"
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","im_uid":"uid-1","im_token":"im-token-new","api_token":"api-token-new","expires_at":1782600000,"token_type":"im","refresh_session":{"session_id":"refresh-session-1","refresh_token":"refresh-token-1","expires_at":1785200000,"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"im"},"member":{"tenant_id":"tenant-1","account_id":"account-1","im_uid":"uid-1","status":"active","role":"member"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let enter = try await client.enterTenant(
            tenantID: "tenant-1",
            platformToken: "platform-token",
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )
        let tenantBase = try XCTUnwrap(IMAPIClient.normalizedTenantAPIBaseURL(enter.runtimeConfig.tenantAPIBaseURL))
        let imBase = try XCTUnwrap(IMAPIClient.normalizedIMAPIBaseURL(enter.runtimeConfig.imAPIBaseURL))
        let session = try await client.platformEntry(
            entryTicket: enter.entryTicket,
            tenantBaseURL: tenantBase,
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )

        XCTAssertEqual(session.imToken, "im-token-new")
        XCTAssertEqual(imBase.absoluteString, "https://im-a.example.test/gateway")
        XCTAssertEqual(session.authSession?.sessionID, "refresh-session-1")
        let requests = transport.requests()
        XCTAssertEqual(requests[0].url?.absoluteString, "https://platform.example.test/api/platform/me/tenants/tenant-1/enter")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
        let enterBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(enterBody["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(enterBody["device_id"] as? String, "device-1")
        XCTAssertEqual(enterBody["client_type"] as? String, "ios")
        XCTAssertEqual(enterBody["requested_capabilities"] as? [String], ["im_realtime"])
        XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant-a.example.test/tenant-api/api/tenant/auth/platform-entry")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        let entryBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(entryBody["entry_ticket"] as? String, "entry-ticket-test")
        XCTAssertEqual(entryBody["app_id"] as? String, "jianhuitong-ios")
        XCTAssertNil(entryBody["device_id"])
        XCTAssertEqual(entryBody["client_type"] as? String, "ios")
    }

	func testEnterTenantAcceptsFreshValidatedRouteAfterInvalidPersistedGeneration() async throws {
		let routes = runtimeRouteSnapshotForHTTPWiring(revision: 11)
		let defaults = UserDefaults(suiteName: "HTTPTransportTests.routes.invalid.\(UUID().uuidString)")!
		let store = IMRuntimeRouteStore(defaults: defaults)
		XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
		try invalidatePersistedCurrentRouteAuthority(defaults)
		let transport = FakeHTTPTransport(results: [
			try tenantEnterSuccess(entryTicket: "entry-ticket-test", routes: routes)
		])
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.example.test")!,
			tenantBase: URL(string: "https://tenant.example.test")!,
			imBase: URL(string: "https://im.example.test")!,
			httpTransport: transport,
			runtimeRouteStore: store
		)

		let entered = try await client.enterTenant(
			tenantID: "tenant-1",
			platformToken: "platform-token",
			appID: "jianhuitong-ios",
			deviceID: "device-1"
		)

		XCTAssertEqual(entered.runtimeConfig.routeRevision, routes.revision)
		XCTAssertEqual(transport.requests().count, 1)
		let record = store.record(appID: routes.appID, tenantID: routes.tenantID)
		XCTAssertEqual(record.current, routes)
		XCTAssertNil(record.previous)
	}

    func testTenantScopedRequestsUseTenantAPIBaseURLFromContext() async throws {
        var context = makeContext()
        context.tenantAPIBaseURL = "https://tenant-a.example.test/tenant-api?debug=true#frag"
        context.imAPIBaseURL = "https://im-a.example.test/gateway?debug=true#frag"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_token":"new-im-token","expires_at":1782600000,"im_uid":"uid-1","tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","token_type":"im"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        _ = try await client.refreshTenantIMSession(context: context, expiresInSeconds: nil)

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant-a.example.test/tenant-api/api/tenant/auth/session/refresh")
        XCTAssertEqual(client.webSocketURL(context: context)?.absoluteString, "wss://im-a.example.test/gateway/im/ws")
    }

    func testCurrentSessionRefreshUsesTenantLocalRefreshAfterEntry() async throws {
        let routeDefaultsName = "HTTPTransportTests.tenantLocalRefresh.\(UUID().uuidString)"
        let routeDefaults = UserDefaults(suiteName: routeDefaultsName)!
        defer { routeDefaults.removePersistentDomain(forName: routeDefaultsName) }
        var context = makeContext()
        context.tenantAPIBaseURL = "https://tenant-a.example.test/tenant-api"
        context.tenantAuthSession = IMStoredAuthSession(
            sessionID: "trs_tenant-session-1",
            refreshToken: "tenant-refresh-1",
            tokenType: "im",
            tenantID: "tenant-1",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1",
            clientType: "ios",
            authVersion: 7,
            sessionGeneration: 11,
            accessExpiresAt: 1782500000
        )
        context.pendingRefreshRequestID = "refresh-request-stable-1"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_token":"new-im-token","access_expires_at":1782600000,"auth_version":8,"session_generation":12,"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","refresh_session":{"session_id":"trs_tenant-session-2","refresh_token":"tenant-refresh-2","expires_at":1785200000,"access_expires_at":1782600000,"auth_version":8,"session_generation":12,"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"im"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(
            transport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
        )

        let result = try await client.refreshCurrentSession(context: context)

        XCTAssertEqual(result.imToken, "new-im-token")
        XCTAssertEqual(result.authSession.sessionID, "trs_tenant-session-2")
        XCTAssertEqual(result.authVersion, 8)
        XCTAssertEqual(result.sessionGeneration, 12)
        XCTAssertEqual(result.expiresAt, 1782600000)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant-a.example.test/tenant-api/api/tenant/auth/refresh")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "refresh-request-stable-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["session_id"] as? String, "trs_tenant-session-1")
        XCTAssertEqual(body["refresh_token"] as? String, "tenant-refresh-1")
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(body["client_type"] as? String, "ios")
        XCTAssertEqual(body["expected_auth_version"] as? Int, 7)
        XCTAssertEqual(body["expected_session_generation"] as? Int, 11)
    }

    func testCurrentSessionRefreshUsesPlatformTenantRefreshForDirectLoginSession() async throws {
        var context = makeContext()
        context.tenantAuthSession = IMStoredAuthSession(
            sessionID: "sess_platform-tenant-1",
            refreshToken: "platform-tenant-refresh-1",
            tokenType: "im",
            tenantID: "tenant-1",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1",
            clientType: "ios"
        )
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_token":"new-im-token","expires_at":1782600000,"tenant":{"tenant_id":"tenant-1","name":"Tenant 1","status":"active"},"member":{"tenant_id":"tenant-1","account_id":"account-1","im_uid":"uid-1","status":"active","role":"member"},"auth_session":{"session_id":"sess_platform-tenant-1","refresh_token":"platform-tenant-refresh-2","expires_at":1785200000,"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"im"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.refreshCurrentSession(context: context)

        XCTAssertEqual(result.imToken, "new-im-token")
        XCTAssertEqual(result.authSession.refreshToken, "platform-tenant-refresh-2")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://platform.example.test/api/platform/tenants/tenant-1/session/refresh"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["session_id"] as? String, "sess_platform-tenant-1")
        XCTAssertEqual(body["refresh_token"] as? String, "platform-tenant-refresh-1")
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(body["client_type"] as? String, "ios")
    }

    func testTenantLocalLogoutUsesServerAuthorityWithBoundedIOSAuxiliaryIdentity() async throws {
        var context = makeContext()
        context.tenantAPIBaseURL = "https://tenant-a.example.test/tenant-api"
        context.platformAuthSession = nil
        context.tenantAuthSession = IMStoredAuthSession(
            sessionID: "trs_logout-session-1",
            refreshToken: "synthetic-tenant-refresh",
            tokenType: "im",
            tenantID: "tenant-1",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1",
            clientType: "ios",
            authVersion: 7,
            sessionGeneration: 11
        )
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        await client.logoutAuthSessions(context: context)

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(transport.requests().count, 1)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://tenant-a.example.test/tenant-api/api/tenant/auth/session/logout"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(Set(body.keys), [
            "app_id",
            "client_type",
            "device_id",
            "expected_auth_version",
            "expected_session_generation",
            "refresh_token",
            "session_id"
        ])
        XCTAssertFalse((body["refresh_token"] as? String ?? "").isEmpty)
        XCTAssertEqual(body["session_id"] as? String, "trs_logout-session-1")
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(body["device_id"] as? String, "device-1")
        XCTAssertEqual(body["client_type"] as? String, "ios")
        XCTAssertEqual(body["expected_auth_version"] as? Int, 7)
        XCTAssertEqual(body["expected_session_generation"] as? Int, 11)
        for forbiddenKey in ["username", "nickname", "message", "message_text", "ip"] {
            XCTAssertNil(body[forbiddenKey])
        }
    }

    func testPlatformFallbackClassifierAllowsRecoverableFailureAndRejectsUnauthorized() {
        XCTAssertTrue(DisasterRecoveryFallbackClassifier.shouldFallbackFromPlatformFailure(IMAPIError.server("service unavailable")))
        XCTAssertTrue(DisasterRecoveryFallbackClassifier.shouldFallbackFromPlatformFailure(URLError(.networkConnectionLost)))
        XCTAssertFalse(DisasterRecoveryFallbackClassifier.shouldFallbackFromPlatformFailure(IMAPIError.unauthorized("invalid_credentials")))
        XCTAssertFalse(DisasterRecoveryFallbackClassifier.shouldFallbackFromPlatformFailure(IMAPIError.businessForbidden(code: "app_disabled", message: "disabled", error: nil)))
    }

    func testCurrentAppPolicyUsesPersistedLastGoodOnPlatform503() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        resetSharedAccessDiagnosticsForPolicyTests()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
            resetSharedAccessDiagnosticsForPolicyTests()
        }
        var context = makeContext()
        context.appID = "jht-ios-main"
        let firstTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"support_contact_email":"support@example.test","support_contact_configured":true,"access_diagnostics_overlay_enabled":true,"access_diagnostics_copy_enabled":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let firstState = AppState(api: makeClient(transport: firstTransport), apiContextOverride: context)
        let firstLoaded = await firstState.refreshCurrentAppPolicyForAuthUI()
        XCTAssertTrue(firstLoaded)
        XCTAssertNotNil(IMAppPolicyLastGoodStore.usable(appID: "jht-ios-main"))
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertFalse(AccessDiagnostics.shared.isVisible)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertFalse(AccessDiagnostics.shared.isCopyEnabled)

        let failingTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"platform_unavailable","message":"service unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ])
        let secondState = AppState(api: makeClient(transport: failingTransport), apiContextOverride: context)

        let fallbackLoaded = await secondState.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(fallbackLoaded)
        XCTAssertEqual(secondState.currentAppPolicy?.supportContactEmail, "support@example.test")
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertFalse(AccessDiagnostics.shared.isVisible)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertFalse(AccessDiagnostics.shared.isCopyEnabled)
        XCTAssertEqual(AccessDiagnostics.shared.snapshot.appIDSummary, IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(failingTransport.requests().first?.url?.host, "platform.example.test")
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    func testCurrentAppPolicyAccessDiagnosticsFlagOnlyAuthorizesManualLogoActivation() async throws {
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        clearStoredAPIContext()
        resetSharedAccessDiagnosticsForPolicyTests()
        defer {
            clearStoredAPIContext()
            resetSharedAccessDiagnosticsForPolicyTests()
        }
        var context = makeContext()
        context.appID = "jht-ios-main"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"debug_features":{"access_diagnostics_overlay_enabled":true,"access_diagnostics_copy_enabled":true},"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"access_diagnostics_overlay_enabled":false,"access_diagnostics_copy_enabled":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(
            api: makeClient(
                transport: transport,
                bootstrapBases: [URL(string: "https://platform.example.test")!]
            ),
            apiContextOverride: context
        )

        let firstLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(firstLoaded)
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertFalse(AccessDiagnostics.shared.isVisible)
        registerFiveStateAccessDiagnosticsLogoTaps(state)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertTrue(AccessDiagnostics.shared.isVisible)
        XCTAssertFalse(AccessDiagnostics.shared.isCopyEnabled)
        XCTAssertEqual(AccessDiagnostics.shared.snapshot.bootstrapHost, "platform.example.test")

        let secondLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(secondLoaded)
        XCTAssertFalse(AccessDiagnostics.shared.isVisible)
        XCTAssertFalse(AccessDiagnostics.shared.isCopyEnabled)
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertEqual(AccessDiagnostics.shared.snapshot.bootstrapHost, "未获取")
        XCTAssertEqual(AccessDiagnostics.shared.snapshot.currentPolicyOverlayStatus, "已关闭")
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

    func testAccountAndPhoneRegistrationLogoTapsOpenAndCloseMatchedEnabledDiagnostics() async throws {
        clearStoredAPIContext()
        resetSharedAccessDiagnosticsForPolicyTests()
        defer {
            clearStoredAPIContext()
            resetSharedAccessDiagnosticsForPolicyTests()
        }
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"phone_auth_enabled":true,"enterprise_code_first":false,"allow_workspace_switch":true,"allow_default_tenant_join":true,"access_diagnostics_overlay_enabled":true,"cache_ttl_seconds":60}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )])
        let state = AppState(
            api: makeClient(transport: transport, bootstrapBases: [URL(string: "https://platform.example.test")!]),
            apiContextOverride: makePreloginContext(appID: "jianhuitong-ios")
        )
        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(loaded)
        XCTAssertFalse(state.isAuthenticated)

        let registrationScreens: [AuthScreen] = [.accountRegister, .phoneRegister]
        for screen in registrationScreens {
            state.setAuthScreen(screen) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            XCTAssertEqual(state.authScreen, screen)
            XCTAssertFalse(AccessDiagnostics.shared.isVisible)
            for _ in 0..<4 {
                state.registerAccessDiagnosticsLogoTap(entry: .loggedOutLoginLogo)
                XCTAssertFalse(AccessDiagnostics.shared.isVisible)
            }
            state.registerAccessDiagnosticsLogoTap(entry: .loggedOutLoginLogo)
            XCTAssertTrue(AccessDiagnostics.shared.isVisible)
            XCTAssertEqual(AccessDiagnostics.shared.snapshot.currentPolicyOverlayStatus, "已启用")
            registerFiveStateAccessDiagnosticsLogoTaps(state)
            XCTAssertFalse(AccessDiagnostics.shared.isVisible)
        }
        XCTAssertTrue(transport.requests().allSatisfy { $0.url?.path == "/api/platform/apps/current-policy" })
    }
}

// WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_BEGIN
private final class IndependentLegalDocumentHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        try await Task.sleep(nanoseconds: 40_000_000)
        switch request.url {
        case LegalDocumentType.terms.fixedWebURL:
            return HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 503, responseURL: request.url)
        case LegalDocumentType.privacy.fixedWebURL:
            return HTTPTransportResult(
                data: Data("<html><body>privacy</body></html>".utf8), isHTTPResponse: true,
                statusCode: 200, responseURL: request.url
            )
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_END

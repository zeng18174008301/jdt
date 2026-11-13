import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testRememberedCredentialStoreSurvivesRelaunchWhenDefaultsMetadataWasNotFlushed() throws {
        let suiteName = "RememberedCredentialStore.AtomicRelaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secretStore = InMemoryRememberedLoginSecretStore()
        let scope = RememberedLoginCredentialScope(
            appID: "jianhuitong-ios",
            deviceID: "credential-device-\(UUID().uuidString)"
        )
        let credentials = RememberedLoginCredentials(
            mode: .account,
            identifier: "remember-user",
            password: "SyntheticPass123!"
        )
        defer {
            KeychainRememberedLoginCredentialStore(
                defaults: defaults,
                secretStore: secretStore
            ).clear(scope: scope)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstProcess = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: secretStore
        )
        XCTAssertTrue(firstProcess.save(credentials, scope: scope))

        // A row-defined kill can happen immediately after the authoritative
        // login transition, before asynchronously persisted defaults metadata
        // reaches disk. The protected record must remain independently whole.
        defaults.removePersistentDomain(forName: suiteName)
        let relaunchedProcess = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: secretStore
        )

        XCTAssertEqual(relaunchedProcess.load(scope: scope), credentials)
        XCTAssertEqual(secretStore.storedValueCount, 2)
    }

    func testRememberedCredentialStorePurgesLegacyAccountUnscopedRecordInsteadOfReusingPassword() throws {
        let suiteName = "RememberedCredentialStore.LegacyV2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secretStore = InMemoryRememberedLoginSecretStore()
        let scope = RememberedLoginCredentialScope(
            appID: "jianhuitong-ios",
            deviceID: "credential-device-\(UUID().uuidString)"
        )
        let storageKey = Data("\(scope.appID)\u{0}\(scope.deviceID)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let defaultsPrefix = "jianhuitong.login.rememberCredentials.v2.\(storageKey)"
        let credentials = RememberedLoginCredentials(
            mode: .account,
            identifier: "remember-user",
            password: "SyntheticPass123!"
        )
        defaults.set(true, forKey: "\(defaultsPrefix).enabled")
        defaults.set("account", forKey: "\(defaultsPrefix).mode")
        defaults.set(credentials.identifier, forKey: "\(defaultsPrefix).identifier")
        XCTAssertTrue(
            secretStore.set(
                Data(credentials.password.utf8),
                service: "jianhuitong.ios.login.remembered-password.v2",
                account: storageKey
            )
        )
        let store = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: secretStore
        )
        defer {
            store.clear(scope: scope)
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertNil(store.load(scope: scope))
        XCTAssertEqual(secretStore.storedValueCount, 0)
        XCTAssertNil(defaults.object(forKey: "\(defaultsPrefix).enabled"))
        XCTAssertNil(defaults.object(forKey: "\(defaultsPrefix).mode"))
        XCTAssertNil(defaults.object(forKey: "\(defaultsPrefix).identifier"))
    }

    func testLoginPostLoginDirectoryFailClosesUnboundAppTenantMemberships() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"enabled":false,"available":false,"required":false,"provider":"self_hosted_slide","surface":"ios","scene":"im_user_login"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"admin11","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session","refresh_token":"platform-refresh","expires_at":1785200000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"requires_workspace_selection":true,"can_direct_enter":false,"entry_status":"none","pending_entry_tenant_id":"","workspaces":[{"tenant_id":"tenant-other-app","tenant_code":"WXT553222","name":"Other App Tenant","status":"active","join_status":"joined","member_status":"active","member_role":"member","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"ios-other","app_tenant_bound":false,"app_binding_status":"unbound"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","app_scoped":true,"workspace_count":1,"enterable_workspace_count":0,"selection_mode":"workspace_selection","empty_reason":"app_tenant_not_bound","workspaces":[{"tenant_id":"tenant-other-app","name":"Other App Tenant","tenant_code":"WXT553222","status":"active","join_status":"joined","member_status":"active","member_role":"member","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"ios-other","app_tenant_bound":false,"app_binding_status":"unbound"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport))
        state.setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

        state.startLoginFlow(identifier: "admin11", password: "aa123456")
        try await waitForCondition {
            state.authScreen == .workspaceSelection
                && state.loginWorkspacePresentationStore.snapshot.message == "当前账号在此 App 下暂无可进入企业，请联系管理员确认企业归属。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                && !state.isAuthLoading
        }

        XCTAssertEqual(state.authScreen, .workspaceSelection)
        XCTAssertEqual(state.enterprises.count, 0)
        XCTAssertEqual(state.currentEnterprise.name, "请选择企业")
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        let requestURLs = transport.requests().compactMap { $0.url?.absoluteString }
        XCTAssertEqual(requestURLs, [
            "https://platform.example.test/api/platform/apps/current-policy?app_id=jianhuitong-ios",
            "https://platform.example.test/api/platform/captcha/slide/config?scene=im_user_login&surface=ios&app_id=jianhuitong-ios",
            "https://platform.example.test/api/platform/auth/im-login",
            "https://platform.example.test/api/platform/me/tenants?app_id=jianhuitong-ios"
        ])
    }

    // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110_BEGIN
    func testDefaultWorkspaceObservationIgnoresEntryMessageAndClearsViaPlatform() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"default_workspace_id":""}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makeContext()
        )
        let store = state.loginWorkspacePresentationStore
        store.snapshot.defaultWorkspaceID = "tenant-1"

        var defaultChanges: [String] = []
        var appUpdates = 0
        let observations = [
            store.updates(\.defaultWorkspaceID).sink { defaultChanges.append($0) },
            state.objectWillChange.sink { appUpdates += 1 }
        ]
        defer { observations.forEach { $0.cancel() } }

        store.snapshot.message = "入企申请等待审批中"
        XCTAssertEqual(defaultChanges, ["tenant-1"])
        XCTAssertEqual(appUpdates, 0)

        state.clearDefaultWorkspacePreference()
        try await waitForCondition { store.snapshot.defaultWorkspaceID.isEmpty }
        XCTAssertEqual(defaultChanges, ["tenant-1", ""])
        XCTAssertEqual(store.snapshot.message, "入企申请等待审批中")
        XCTAssertEqual(transport.requests().last?.url?.path, "/api/platform/me/tenants/default")
        XCTAssertEqual(transport.requests().last?.httpMethod, "DELETE")
        XCTAssertEqual(state.toast, "已清除默认企业")
    }
    // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110_END

    func testLoginPendingApprovalShowsWorkspaceSelectionWaitingState() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"enabled":false,"available":false,"required":false,"provider":"self_hosted_slide","surface":"ios","scene":"im_user_login"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"admin11","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session","refresh_token":"platform-refresh","expires_at":1785200000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"requires_workspace_selection":true,"can_direct_enter":false,"entry_status":"pending_approval","pending_entry_tenant_id":"tenant-pending","pending_approval_count":1,"workspaces":[{"tenant_id":"tenant-pending","tenant_code":"WXT553222","name":"Pending Tenant","status":"active","join_status":"pending_approval","member_status":"pending_approval","member_role":"member","account_id":"account-1","can_enter":false,"can_switch":false,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound","reason_code":"workspace_join_pending"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","app_scoped":true,"workspace_count":1,"enterable_workspace_count":0,"selection_mode":"workspace_selection","empty_reason":"","workspaces":[{"tenant_id":"tenant-pending","name":"Pending Tenant","tenant_code":"WXT553222","status":"active","join_status":"pending_approval","member_status":"pending_approval","member_role":"member","account_id":"account-1","can_enter":false,"can_switch":false,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound","reason_code":"workspace_join_pending"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport))
        state.setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

        state.startLoginFlow(identifier: "admin11", password: "aa123456")
        try await waitForCondition { state.authScreen == .workspaceSelection && !state.isAuthLoading }

        XCTAssertEqual(state.authScreen, .workspaceSelection)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.loginWorkspacePresentationStore.snapshot.message, "入企申请等待审批中，审核通过后再进入企业。") // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        XCTAssertEqual(state.enterprises.first?.name, "Pending Tenant")
        XCTAssertEqual(state.enterprises.first?.isWorkspaceJoinPending, true)
        XCTAssertFalse(state.hasActiveIMSession)
    }

    func testLoginDirectEnteredWorkspaceStillAutoEntersWhenBackendReturnsSession() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let credentialStore = RecordingRememberedLoginCredentialStore()
        let preferenceStore = RecordingRememberedLoginPreferenceStore()
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
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
        ])
        let context = makePreloginContext()
        let scope = RememberedLoginCredentialScope(context: context)
        let state = AppState(
            api: makeClient(transport: transport),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )
        defer { state.logout() }
        state.setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.setRememberLoginCredentialsEnabled(true)

        state.startLoginFlow(identifier: "admin11", password: "aa123456", credentialMode: .account)
        try await waitForCondition { state.isAuthenticated && !state.isAuthLoading }

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.currentEnterprise.id, "tenant-default")
        XCTAssertEqual(state.currentEnterprise.name, "Default Tenant")
        XCTAssertEqual(IMAPIContext.load().tenantID, "tenant-default")
        XCTAssertEqual(credentialStore.saveCount, 1)
        XCTAssertEqual(
            credentialStore.load(scope: scope)?.identifier,
            "admin11"
        )
        let requestURLs = transport.requests().compactMap { $0.url?.absoluteString }
        XCTAssertEqual(Array(requestURLs.prefix(3)), [
            "https://platform.example.test/api/platform/apps/current-policy?app_id=jianhuitong-ios",
            "https://platform.example.test/api/platform/captcha/slide/config?scene=im_user_login&surface=ios&app_id=jianhuitong-ios",
            "https://platform.example.test/api/platform/auth/im-login"
        ])
        XCTAssertFalse(requestURLs.contains("https://platform.example.test/api/platform/me/tenants?app_id=jianhuitong-ios"))
    }

    func testWorkspaceSelectionRefreshesExpiredPlatformTokenBeforeEnteringTenant() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let context = IMAPIContext(
            platformToken: "old-platform-token",
            accountID: "account-1",
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: IMStoredAuthSession(
                sessionID: "platform-session-1",
                refreshToken: "platform-refresh-1",
                tokenType: "platform",
                accountID: "account-1",
                appID: "jianhuitong-ios",
                deviceID: "device-1",
                clientType: "ios",
                authVersion: 4,
                sessionGeneration: 7,
                accessExpiresAt: 1
            ),
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )
        let protectedStore = InMemoryProtectedSessionStore()
        XCTAssertTrue(context.save(sessionStore: protectedStore).isCommitted)
        let tenantRoutes = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant.example.test"]
        )
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"expired access token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            workspaceSelectionCommittedPlatformRotation(),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"ready","tenant_id":"tenant-1","tenant_name":"Local Tenant","tenant_code":"WXT000001","can_switch":true}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try tenantEnterSuccess(entryTicket: "entry-ticket-test", routes: tenantRoutes),
            try tenantPlatformEntrySuccess()
        ])
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: protectedStore,
            apiContextOverride: context
        )
        let enterprise = Enterprise(
            id: "tenant-1",
            name: "Local Tenant",
            code: "WXT000001",
            role: "member",
            status: "active",
            memberCount: 1,
            isDefault: true,
            accentHex: 0x6E73FF
        )
        state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        state.selectLoginWorkspace(enterprise, makeDefault: false)
        try await waitForCondition(iterations: 120) { state.isAuthenticated && !state.isAuthLoading }

        XCTAssertEqual(state.authScreen, .workspaceSelection)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.currentEnterprise.name, "Local Tenant")
        XCTAssertNotEqual(state.toast, "登录已失效，请重新登录")
        let storedContext = IMAPIContext.load(sessionStore: protectedStore)
        XCTAssertEqual(storedContext.platformToken, "fresh-platform-token")
        let requests = transport.requests()
        XCTAssertGreaterThanOrEqual(requests.count, 5)
        let firstPrepare = try XCTUnwrap(requests.first)
        let refreshRequest = try XCTUnwrap(requests.dropFirst().first)
        let secondPrepare = try XCTUnwrap(requests.dropFirst(2).first)
        let enterRequest = try XCTUnwrap(requests.dropFirst(3).first)
        XCTAssertEqual(firstPrepare.url?.absoluteString, "https://tenant.example.test/api/tenant/workspace-entry/prepare")
        XCTAssertEqual(firstPrepare.value(forHTTPHeaderField: "Authorization"), "Bearer old-platform-token")
        XCTAssertEqual(refreshRequest.url?.absoluteString, "https://platform.example.test/api/platform/auth/session/refresh")
        XCTAssertEqual(secondPrepare.url?.absoluteString, "https://tenant.example.test/api/tenant/workspace-entry/prepare")
        XCTAssertEqual(secondPrepare.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-platform-token")
        XCTAssertEqual(enterRequest.url?.absoluteString, "https://platform.example.test/api/platform/me/tenants/tenant-1/enter")
        XCTAssertEqual(enterRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-platform-token")
        try assertWorkspaceSelectionCommittedRotation(
            requests: requests, refreshRequest: refreshRequest, storedContext: storedContext
        )
    }

    func testWorkspaceSelectionFallsBackToEnterWhenPrepareStillUnauthorizedAfterRefresh() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let context = IMAPIContext(
            platformToken: "old-platform-token",
            accountID: "account-1",
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: IMStoredAuthSession(
                sessionID: "platform-session-1",
                refreshToken: "platform-refresh-1",
                tokenType: "platform",
                accountID: "account-1",
                appID: "jianhuitong-ios",
                deviceID: "device-1",
                clientType: "ios",
                authVersion: 4,
                sessionGeneration: 7,
                accessExpiresAt: 1
            ),
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )
        let protectedStore = InMemoryProtectedSessionStore()
        XCTAssertTrue(context.save(sessionStore: protectedStore).isCommitted)
        let tenantRoutes = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant.example.test"]
        )
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"expired access token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            workspaceSelectionCommittedPlatformRotation(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"prepare still rejects platform token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            try tenantEnterSuccess(entryTicket: "entry-ticket-test", routes: tenantRoutes),
            try tenantPlatformEntrySuccess()
        ])
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: protectedStore,
            apiContextOverride: context
        )
        let enterprise = Enterprise(
            id: "tenant-1",
            name: "Local Tenant",
            code: "WXT000001",
            role: "member",
            status: "active",
            memberCount: 1,
            isDefault: true,
            accentHex: 0x6E73FF
        )
        state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        state.selectLoginWorkspace(enterprise, makeDefault: false)
        try await waitForCondition(iterations: 120) { state.isAuthenticated && !state.isAuthLoading }

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.currentEnterprise.name, "Local Tenant")
        let storedContext = IMAPIContext.load(sessionStore: protectedStore)
        XCTAssertEqual(storedContext.platformToken, "fresh-platform-token")
        XCTAssertEqual(storedContext.tenantID, "tenant-1")
        XCTAssertNotEqual(state.toast, "登录已失效，请重新登录")
        let requests = transport.requests()
        XCTAssertGreaterThanOrEqual(requests.count, 5)
        let firstPrepare = try XCTUnwrap(requests.first)
        let refreshRequest = try XCTUnwrap(requests.dropFirst().first)
        let secondPrepare = try XCTUnwrap(requests.dropFirst(2).first)
        let enterRequest = try XCTUnwrap(requests.dropFirst(3).first)
        XCTAssertEqual(firstPrepare.url?.absoluteString, "https://tenant.example.test/api/tenant/workspace-entry/prepare")
        XCTAssertEqual(refreshRequest.url?.absoluteString, "https://platform.example.test/api/platform/auth/session/refresh")
        XCTAssertEqual(secondPrepare.url?.absoluteString, "https://tenant.example.test/api/tenant/workspace-entry/prepare")
        XCTAssertEqual(secondPrepare.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-platform-token")
        XCTAssertEqual(enterRequest.url?.absoluteString, "https://platform.example.test/api/platform/me/tenants/tenant-1/enter")
        XCTAssertEqual(enterRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-platform-token")
        try assertWorkspaceSelectionCommittedRotation(
            requests: requests, refreshRequest: refreshRequest, storedContext: storedContext
        )
    }

    private func workspaceSelectionCommittedPlatformRotation() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"""
            {"ok":true,"data":{"platform_token":"fresh-platform-token","expires_at":1895000000,"auth_session":{
                "session_id":"platform-session-1","refresh_token":"platform-refresh-2","refresh_expires_at":1895003600,
                "access_expires_at":1895000000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios",
                "token_type":"platform","rotated":true,"requires_keychain":true,"auth_version":4,"session_generation":8
            }}}
            """#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    private func assertWorkspaceSelectionCommittedRotation(
        requests: [URLRequest], refreshRequest: URLRequest, storedContext: IMAPIContext
    ) throws {
        let preparePath = "/api/tenant/workspace-entry/prepare"
        let refreshPath = "/api/platform/auth/session/refresh"
        let enterPath = "/api/platform/me/tenants/tenant-1/enter"
        let exchangePath = "/api/tenant/auth/platform-entry"
        let transitionPaths = Set([preparePath, refreshPath, enterPath, exchangePath,
                                   "/api/tenant/workspace-entry/status", "/api/platform/tenants/tenant-1/switch"])
        let transitions = requests.filter { $0.url.map { transitionPaths.contains($0.path) } ?? false }
        XCTAssertEqual(transitions.compactMap { $0.url?.path }, [preparePath, refreshPath, preparePath, enterPath, exchangePath])
        XCTAssertEqual(transitions.map(\.httpMethod), Array(repeating: "POST", count: 5))
        XCTAssertEqual(transitions.last?.url?.absoluteString, "https://tenant.example.test/api/tenant/auth/platform-entry")
        let refreshBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(refreshRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(refreshBody["session_id"] as? String, "platform-session-1")
        XCTAssertEqual(refreshBody["expected_auth_version"] as? Int, 4)
        XCTAssertEqual(refreshBody["expected_session_generation"] as? Int, 7)
        XCTAssertNotNil(refreshRequest.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(storedContext.platformAuthSession?.sessionID, "platform-session-1")
        XCTAssertEqual(storedContext.platformAuthSession?.refreshToken, "platform-refresh-2")
        XCTAssertEqual(storedContext.platformAuthSession?.authVersion, 4)
        XCTAssertEqual(storedContext.platformAuthSession?.sessionGeneration, 8)
        XCTAssertNil(storedContext.pendingRefreshRequestID)
    }

    func testWorkspaceSelectionDefersPrepareUntilPlatformEnterSuppliesTenantBase() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let routeDefaultsName = "WorkspaceSelectionDeferredRoute.\(UUID().uuidString)"
        let routeDefaults = try XCTUnwrap(UserDefaults(suiteName: routeDefaultsName))
        defer { routeDefaults.removePersistentDomain(forName: routeDefaultsName) }
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: IMStoredAuthSession(
                sessionID: "platform-session-1",
                refreshToken: "platform-refresh-1",
                tokenType: "platform",
                accountID: "account-1",
                appID: "jianhuitong-ios",
                deviceID: "device-1"
            ),
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )
        let tenantRoutes = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant.example.test"]
        )
        let transport = FakeHTTPTransport(results: [
            try tenantEnterSuccess(entryTicket: "entry-ticket-test", routes: tenantRoutes),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"tenant":{"tenant_id":"tenant-1","name":"Local Tenant","tenant_code":"WXT000001","status":"active"},"member":{"tenant_id":"tenant-1","account_id":"account-1","im_uid":"uid-1","status":"active","role":"member"},"im_uid":"uid-1","im_token":"im-token-new","app_id":"jianhuitong-ios","device_id":"device-1","auth_session":{"session_id":"tenant-session-1","refresh_token":"tenant-refresh-1","expires_at":1785200000,"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"im"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = IMAPIClient(
            platformBase: URL(string: "https://app-test.example.test")!,
            tenantBase: IMAPIClient.releasePlaceholderTenantBase,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
        )
        let state = AppState(api: client, apiContextOverride: context)
        let enterprise = Enterprise(
            id: "tenant-1",
            name: "Local Tenant",
            code: "WXT000001",
            role: "member",
            status: "active",
            memberCount: 1,
            isDefault: true,
            accentHex: 0x6E73FF
        )
        state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        state.selectLoginWorkspace(enterprise, makeDefault: false)
        try await waitForCondition(iterations: 120) { state.isAuthenticated && !state.isAuthLoading }

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(IMAPIContext.load().tenantID, "tenant-1")
        let requests = transport.requests()
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.url?.path.contains("/api/tenant/workspace-entry/") == true })
        let platformEnterRequest = try XCTUnwrap(requests.first, "Expected the platform tenant-enter request")
        let platformEntryRequest = try XCTUnwrap(requests.dropFirst().first, "Expected the tenant platform-entry request")
        XCTAssertEqual(platformEnterRequest.url?.absoluteString, "https://app-test.example.test/api/platform/me/tenants/tenant-1/enter")
        XCTAssertEqual(platformEntryRequest.url?.absoluteString, "https://tenant.example.test/api/tenant/auth/platform-entry")
    }

    func testPlatformEntryUsesFreshPreferredDespitePersistedRecoveryAndNeverReplaysTicket() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let suiteName = "PlatformEntryFreshPreferred.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = IMRuntimeRouteStore(defaults: defaults)
        let routes = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant-fresh.example.test"]
        )
        XCTAssertEqual(store.apply(routes, appID: routes.appID, tenantID: routes.tenantID), .applied)
        let selector = IMRuntimeRouteSelector(store: store)
        let failedLaunch = IMRuntimeColdLaunchAttempt(
            processWasNotRunning: true, foregroundLaunch: true, networkReachable: true,
            backgroundedOrCancelled: false, qualifiedFailureDurationMS: 5_000
        )
        for _ in 0..<3 {
            selector.recordColdLaunch(failedLaunch, snapshot: routes, service: .tenantAPI)
        }
        XCTAssertTrue(selector.recovery(routes, service: .tenantAPI).recovery)

        let context = IMAPIContext(
            platformToken: "platform-token", accountID: "account-1", tenantID: nil,
            imUID: nil, imToken: nil,
            platformAuthSession: IMStoredAuthSession(
                sessionID: "platform-session-1", refreshToken: "platform-refresh-1",
                tokenType: "platform", accountID: "account-1", appID: "jianhuitong-ios",
                deviceID: "device-1"
            ),
            tenantAuthSession: nil, appID: "jianhuitong-ios", deviceID: "device-1"
        )
        let transport = FakeHTTPTransport(results: [
            try tenantEnterSuccess(entryTicket: "single-use-ticket", routes: routes),
            try tenantPlatformEntrySuccess(),
        ])
        let client = IMAPIClient(
            platformBase: URL(string: "https://app-test.example.test")!,
            tenantBase: IMAPIClient.releasePlaceholderTenantBase,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: store
        )
        let state = AppState(api: client, apiContextOverride: context)
        let enterprise = Enterprise(
            id: "tenant-1", name: "Local Tenant", code: "WXT000001", role: "member",
            status: "active", memberCount: 1, isDefault: true, accentHex: 0x6E73FF
        )
        state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        state.selectLoginWorkspace(enterprise, makeDefault: false)
        try await waitForCondition(iterations: 120) { state.isAuthenticated && !state.isAuthLoading }

        let platformEntryRequests = transport.requests().filter { $0.url?.path == "/api/tenant/auth/platform-entry" }
        XCTAssertEqual(platformEntryRequests.count, 1)
        XCTAssertEqual(platformEntryRequests.first?.url?.host, "tenant-fresh.example.test")
        XCTAssertFalse(transport.requests().contains {
            $0.url?.path == "/api/tenant/auth/platform-entry"
                && $0.url?.host == "tenant-backup.example.net"
        })
    }

    func testWorkspaceSelectionPlatformEntryNetworkFailureKeepsWorkspaceActionable() async throws {
        let serviceUnavailable = Data(
            #"{"ok":false,"error":{"code":"tenant_service_unavailable","message":"tenant service unavailable"}}"#.utf8
        )
        for terminalAction in [
            RuntimeRouteBudgetTransport.Action.failure(.cannotConnectToHost, advanceMS: 0),
            .response(status: 503, data: serviceUnavailable, advanceMS: 0),
        ] {
            clearStoredAPIContext()
            let suiteName = "PlatformEntryNetwork.\(UUID().uuidString)"
            let routeDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { routeDefaults.removePersistentDomain(forName: suiteName) }
            let store = IMRuntimeRouteStore(defaults: routeDefaults)
            let routes = runtimeRouteSnapshotForHTTPWiring(tenantPreferred: ["https://tenant-fresh.example.test"])
            let enter = try tenantEnterSuccess(entryTicket: "single-use-ticket", routes: routes)
            let clock = RuntimeRouteTestClock(nowMS: 0)
            let transport = RuntimeRouteBudgetTransport(clock: clock, actions: [
                .response(status: enter.statusCode ?? 200, data: enter.data, advanceMS: 0),
                terminalAction,
            ])
            let context = IMAPIContext(
                platformToken: "platform-token", accountID: "account-1", tenantID: nil,
                imUID: nil, imToken: nil,
                platformAuthSession: IMStoredAuthSession(
                    sessionID: "platform-session-1", refreshToken: "platform-refresh-1",
                    tokenType: "platform", accountID: "account-1", appID: "jianhuitong-ios",
                    deviceID: "device-1"
                ),
                tenantAuthSession: nil, appID: "jianhuitong-ios", deviceID: "device-1"
            )
            let client = IMAPIClient(
                platformBase: URL(string: "https://app-test.example.test")!,
                tenantBase: IMAPIClient.releasePlaceholderTenantBase,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport,
                runtimeRouteStore: store
            )
            let state = AppState(api: client, apiContextOverride: context)
            let enterprise = Enterprise(
                id: "tenant-1", name: "Local Tenant", code: "WXT000001", role: "member",
                status: "active", memberCount: 1, isDefault: true, accentHex: 0x6E73FF,
                canSwitch: true, enterable: true, tenantStatus: "active", memberStatus: "active"
            )
            state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            state.setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

            state.selectLoginWorkspace(enterprise, makeDefault: false)
            try await waitForCondition(iterations: 120) { !state.isAuthLoading }

            let retained = try XCTUnwrap(state.enterprises.first { $0.id == "tenant-1" })
            XCTAssertTrue(retained.canSwitch)
            XCTAssertEqual(retained.enterable, true)
            XCTAssertEqual(retained.tenantStatus, "active")
            XCTAssertTrue(retained.disabledReason.isEmpty)
            XCTAssertFalse(state.isAuthenticated)
            XCTAssertFalse(IMAPIContext.load().hasIMSession)
            XCTAssertEqual(state.toast, "企业服务连接暂不可用，请检查网络后重试")
            XCTAssertEqual(transport.requestURLs().filter { $0.hasSuffix("/api/tenant/auth/platform-entry") }.count, 1)
        }
        clearStoredAPIContext()
    }

    func testSuccessfulPlatformEntryClearsStaleDisabledProjectionAndPersistsSession() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let suiteName = "PlatformEntryStaleProjection.\(UUID().uuidString)"
        let routeDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { routeDefaults.removePersistentDomain(forName: suiteName) }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantPreferred: ["https://tenant-fresh.example.test"])
        let transport = FakeHTTPTransport(results: [
            try tenantEnterSuccess(entryTicket: "single-use-ticket", routes: routes),
            try tenantPlatformEntrySuccess(includeTenantPresentation: false),
        ])
        let context = IMAPIContext(
            platformToken: "platform-token", accountID: "account-1", tenantID: nil,
            imUID: nil, imToken: nil,
            platformAuthSession: IMStoredAuthSession(
                sessionID: "platform-session-1", refreshToken: "platform-refresh-1",
                tokenType: "platform", accountID: "account-1", appID: "jianhuitong-ios",
                deviceID: "device-1"
            ),
            tenantAuthSession: nil, appID: "jianhuitong-ios", deviceID: "device-1"
        )
        let client = IMAPIClient(
            platformBase: URL(string: "https://app-test.example.test")!,
            tenantBase: IMAPIClient.releasePlaceholderTenantBase,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
        )
        let state = AppState(api: client, apiContextOverride: context)
        let selection = Enterprise(
            id: "tenant-1", name: "Local Tenant", code: "WXT000001", role: "member",
            status: "active", memberCount: 1, isDefault: true, accentHex: 0x6E73FF
        )
        var stale = selection
        stale.canSwitch = false
        stale.enterable = false
        stale.tenantStatus = "disabled"
        stale.memberStatus = "disabled"
        stale.disabledReason = "tenant_disabled"
        state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.setEnterprises([stale]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setCurrentEnterprise(stale) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        state.selectLoginWorkspace(selection, makeDefault: false)
        try await waitForCondition(iterations: 120) { state.isAuthenticated && !state.isAuthLoading }

        for projected in [state.currentEnterprise, try XCTUnwrap(state.enterprises.first { $0.id == "tenant-1" })] {
            XCTAssertTrue(projected.canSwitch)
            XCTAssertEqual(projected.enterable, true)
            XCTAssertEqual(projected.tenantStatus, "active")
            XCTAssertEqual(projected.memberStatus, "active")
            XCTAssertTrue(projected.disabledReason.isEmpty)
            XCTAssertEqual(projected.name, "Local Tenant")
        }
        let saved = IMAPIContext.load()
        XCTAssertTrue(saved.hasIMSession)
        XCTAssertEqual(saved.tenantID, "tenant-1")
        XCTAssertEqual(saved.tenantAPIBaseURL, "https://tenant-fresh.example.test")
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/tenant/auth/platform-entry" }.count, 1)
    }
}

@testable import IM4Features
@testable import IM4Domain
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_BEGIN
    func testOrganizationMutationResponseFromBeforeResetCannotClearCurrentSaving() async throws {
        let transport = OrganizationDepartmentMutationGateTransport()
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        let store = state.organizationDirectoryStore
        let authority = RemoteOrganizationTree(departmentEnabled: true, canManage: true, root: nil, items: [])
        store.applyTree(authority)
        defer { transport.close() }

        let old = Task { await state.createOrganizationDepartment(parentDepartmentID: "company", name: "旧请求") }
        try await waitForCondition { transport.pendingCount == 1 }
        guard transport.pendingCount == 1 else { return XCTFail("旧创建请求应已发出") }
        XCTAssertTrue(store.isManagementSaving)
        XCTAssertNil(store.beginManagementMutation())

        state.resetAuthenticatedRemoteData(showLoading: false)
        XCTAssertFalse(store.isManagementSaving)
        store.applyTree(authority)
        let replacement = Task { await state.createOrganizationDepartment(parentDepartmentID: "company", name: "新请求") }
        try await waitForCondition { transport.pendingCount == 2 }
        guard transport.pendingCount == 2 else { return XCTFail("新创建请求应已发出") }

        transport.releaseFirst()
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(store.isManagementSaving)
        XCTAssertNil(state.toast)

        transport.releaseFirst()
        let currentResult = await replacement.value
        XCTAssertTrue(currentResult)
        XCTAssertFalse(store.isManagementSaving)
        XCTAssertEqual(state.toast, "部门已创建")
    }
    // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_END

    func testWorkspaceSelectionFallsBackToLegacySwitchWhenPlatformEntryTicketIsInvalid() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let routes = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant.example.test"]
        )
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
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"ready","tenant_id":"tenant-1","tenant_name":"Local Tenant","tenant_code":"WXT000001","can_switch":true}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try tenantEnterSuccess(entryTicket: "entry-ticket-test", routes: routes),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_entry_ticket","message":"entry_ticket is invalid"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"tenant":{"tenant_id":"tenant-1","name":"Local Tenant","tenant_code":"WXT000001","status":"active"},"app":{"app_id":"jianhuitong-ios"},"member":{"tenant_id":"tenant-1","account_id":"account-1","im_uid":"uid-1","status":"active","role":"member"},"im_uid":"uid-1","im_token":"im-token-legacy","auth_session":{"session_id":"tenant-session-1","refresh_token":"tenant-refresh-1","expires_at":1785200000,"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"im"}}}"#.utf8),
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
        XCTAssertEqual(state.currentEnterprise.name, "Local Tenant")
        XCTAssertFalse(state.isAuthLoading)
        XCTAssertNotEqual(state.toast, "登录已失效，请重新登录")
        let requests = transport.requests()
        XCTAssertGreaterThanOrEqual(requests.count, 4)
        let prepareRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(prepareRequest.url?.absoluteString, "https://tenant.example.test/api/tenant/workspace-entry/prepare")
        XCTAssertEqual(prepareRequest.value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
        XCTAssertTrue(requests.contains { $0.url?.absoluteString == "https://platform.example.test/api/platform/me/tenants/tenant-1/enter" })
        let platformEntry = try XCTUnwrap(requests.first { $0.url?.absoluteString == "https://tenant.example.test/api/tenant/auth/platform-entry" })
        let platformEntryBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(platformEntry.httpBody)) as? [String: Any])
        XCTAssertEqual(platformEntryBody["app_id"] as? String, "jianhuitong-ios")
        XCTAssertNil(platformEntryBody["device_id"])
        let legacySwitch = try XCTUnwrap(requests.first { $0.url?.absoluteString == "https://platform.example.test/api/platform/tenants/tenant-1/switch" })
        XCTAssertEqual(legacySwitch.value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
    }

    func testListMyTenantsFiltersUnboundAppTenantMemberships() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","app_scoped":true,"workspace_count":2,"enterable_workspace_count":1,"selection_mode":"workspace_selection","empty_reason":"","workspaces":[{"tenant_id":"tenant-ready","name":"Ready Tenant","tenant_code":"WXT000001","status":"active","join_status":"joined","member_status":"active","member_role":"member","member_im_uid":"uid-ready","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound"},{"tenant_id":"tenant-qa","name":"QA Tenant","tenant_code":"WXT999999","status":"active","join_status":"joined","member_status":"active","member_role":"member","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"ios-other","app_tenant_bound":false,"app_binding_status":"unbound"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let memberships = try await client.listMyTenants(platformToken: "platform-token-redacted", appID: "jianhuitong-ios")

        XCTAssertEqual(memberships.map(\.tenant.name), ["Ready Tenant"])
        XCTAssertFalse(memberships.contains { $0.tenant.name == "QA Tenant" || $0.tenant.tenantCode == "WXT999999" })
    }

    func testConfirmWorkspaceEntryUsesTenantEntryConfirmEndpoint() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"entry_status":"entered","default_workspace_id":"tenant-1","default_workspace_valid":true}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.confirmWorkspaceEntry(context: makeContext(), tenantID: "tenant-1")

        XCTAssertEqual(result.defaultWorkspaceID, "tenant-1")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/workspaces/tenant-1/entry/confirm")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertTrue(body.isEmpty)
    }

    func testWorkspaceEntryPrepareAndStatusUsePlatformToken() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"preparing","tenant_id":"tenant-1","pending_entry_tenant_id":"tenant-1","entry_source":"workspace_selection","poll_after_ms":800}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 202
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"ready","tenant_id":"tenant-1","workspace":{"tenant_id":"tenant-1","tenant_code":"WXT000001","name":"Ready Tenant","status":"active","join_status":"joined","member_status":"active","member_role":"member","can_enter":true,"can_switch":true}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let preparing = try await client.prepareWorkspaceEntry(
            tenantID: "tenant-1",
            entryCode: nil,
            entrySource: "workspace_selection",
            idempotencyKey: "ios-account-tenant-1",
            platformToken: "platform-token"
        )
        let ready = try await client.workspaceEntryStatus(tenantID: "tenant-1", platformToken: "platform-token")

        XCTAssertEqual(preparing.normalizedStatus, "preparing")
        XCTAssertEqual(preparing.pollAfterMS, 800)
        XCTAssertEqual(ready.normalizedStatus, "ready")
        XCTAssertEqual(ready.workspace?.name, "Ready Tenant")
        let requests = transport.requests()
        XCTAssertEqual(requests[0].url?.absoluteString, "https://tenant.example.test/api/tenant/workspace-entry/prepare")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
        let prepareBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(prepareBody["tenant_id"] as? String, "tenant-1")
        XCTAssertEqual(prepareBody["entry_source"] as? String, "workspace_selection")
        XCTAssertEqual(prepareBody["idempotency_key"] as? String, "ios-account-tenant-1")
        XCTAssertNil(prepareBody["confirmation"])
        XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant.example.test/api/tenant/workspace-entry/status?tenant_id=tenant-1")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
        XCTAssertEqual(requests[1].cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testWorkspaceEntryPrepareRejectsPlatformHostWhenTenantBaseIsReleasePlaceholder() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let routeDefaultsName = "WorkspaceEntryPlaceholderRoute.\(UUID().uuidString)"
        let routeDefaults = try XCTUnwrap(UserDefaults(suiteName: routeDefaultsName))
        defer { routeDefaults.removePersistentDomain(forName: routeDefaultsName) }
        let transport = FakeHTTPTransport(results: [])
        let client = IMAPIClient(
            platformBase: URL(string: "https://app-test.example.test")!,
            tenantBase: IMAPIClient.releasePlaceholderTenantBase,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )

        do {
            _ = try await client.prepareWorkspaceEntry(
                tenantID: "tenant-1",
                entryCode: nil,
                entrySource: "workspace_selection",
                idempotencyKey: "ios-account-tenant-1",
                platformToken: "platform-token",
                context: context
            )
            XCTFail("expected tenant data-plane context failure")
        } catch let IMAPIError.missingContext(field) {
            XCTAssertEqual(field, "tenant_api_base_url")
        }
        XCTAssertTrue(transport.requests().isEmpty)
    }

    func testWorkspaceEntryPrepareAndStatusPreferContextTenantBaseOverPlaceholder() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"preparing","tenant_id":"tenant-1","pending_entry_tenant_id":"tenant-1","entry_source":"workspace_selection","poll_after_ms":800}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 202
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"ready","tenant_id":"tenant-1","workspace":{"tenant_id":"tenant-1","tenant_code":"WXT000001","name":"Ready Tenant","status":"active","join_status":"joined","member_status":"active","member_role":"member","can_enter":true,"can_switch":true}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = IMAPIClient(
            platformBase: IMAPIClient.releasePlaceholderPlatformBase,
            tenantBase: IMAPIClient.releasePlaceholderTenantBase,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [URL(string: "https://app-test.example.test")!],
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: nil,
            imToken: nil,
            tenantAPIBaseURL: "https://tenant-runtime.example.test",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )

        _ = try await client.prepareWorkspaceEntry(
            tenantID: "tenant-1",
            entryCode: nil,
            entrySource: "workspace_selection",
            idempotencyKey: "ios-account-tenant-1",
            platformToken: "platform-token",
            context: context
        )
        _ = try await client.workspaceEntryStatus(
            tenantID: "tenant-1",
            platformToken: "platform-token",
            context: context
        )

        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://tenant-runtime.example.test/api/tenant/workspace-entry/prepare")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant-runtime.example.test/api/tenant/workspace-entry/status?tenant_id=tenant-1")
        XCTAssertFalse(requests.contains { $0.url?.host == "tenant-api.invalid" })
        XCTAssertFalse(requests.contains { $0.url?.host == "app-test.example.test" })
    }

    func testLogoutClearsPersistedSessionImmediately() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        var context = makeContext()
        context.appID = "jianhuitong-ios"
        context.platformAuthSession = IMStoredAuthSession(
            sessionID: "platform-session",
            refreshToken: "platform-refresh",
            tokenType: "platform",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )
        context.tenantAuthSession = IMStoredAuthSession(
            sessionID: "tenant-session",
            refreshToken: "tenant-refresh",
            tokenType: "im",
            tenantID: "tenant-1",
            accountID: "account-1",
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )
        context.save()
        XCTAssertTrue(IMAPIContext.load().hasIMSession)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200),
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        state.logout()

        let reloaded = IMAPIContext.load()
        XCTAssertFalse(reloaded.hasIMSession)
        XCTAssertFalse(reloaded.hasRefreshSession)
        XCTAssertEqual(state.authScreen, .welcome)
    }

    func testWorkspaceSwitchDisabledStopsAppIDFallbackRetryAndShowsFriendlyToast() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        var context = makeContext()
        context.appID = "legacy-ios"
        context.save()
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"workspace_switch_disabled","message":"switch disabled by policy"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 403
            )
        ])
        let client = makeClient(transport: transport)
        let state = AppState(api: client)
        let current = Enterprise(
            id: "tenant-1",
            name: "当前企业",
            code: "WXT111111",
            role: "member",
            status: "已加入",
            memberCount: 2,
            isDefault: true,
            accentHex: 0x5D6BFF,
            canSwitch: true,
            enterable: true
        )
        let target = Enterprise(
            id: "tenant-2",
            name: "目标企业",
            code: "WXT222222",
            role: "member",
            status: "已加入",
            memberCount: 2,
            isDefault: false,
            accentHex: 0x33AA88,
            canSwitch: true,
            enterable: true
        )
        state.setCurrentEnterprise(current) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setEnterprises([current, target]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        let initialCompletionRevision = state.enterpriseSwitchCompletionRevision

        state.switchEnterprise(target)
        for _ in 0..<40 where state.toast != "管理员已关闭企业切换" {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(state.toast, "管理员已关闭企业切换")
        XCTAssertEqual(state.enterpriseSwitchCompletionRevision, initialCompletionRevision)
        XCTAssertEqual(transport.requests().count, 1)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.example.test/api/platform/me/tenants/tenant-2/enter")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(body["client_type"] as? String, "ios")
    }

    func testSuccessfulEnterpriseSwitchPublishesOneCurrentCompletion() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let routes = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant-target.example.test"],
            tenantID: "tenant-2"
        )
        let entryPayload: [String: Any] = [
            "ok": true,
            "data": [
                "tenant_id": "tenant-2",
                "tenant": [
                    "tenant_id": "tenant-2",
                    "name": "Target Tenant",
                    "tenant_code": "WXT222222",
                    "status": "active"
                ],
                "member": [
                    "tenant_id": "tenant-2",
                    "account_id": "account-1",
                    "im_uid": "uid-1",
                    "status": "active",
                    "role": "member"
                ],
                "im_uid": "uid-1",
                "im_token": "im-token-target",
                "app_id": "jianhuitong-ios",
                "device_id": "device-1"
            ]
        ]
        let conversationSync = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"version":1,"conversations":[],"removed_conversations":[]}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [
            try tenantEnterSuccess(entryTicket: "entry-ticket-target", routes: routes),
            HTTPTransportResult(
                data: try JSONSerialization.data(withJSONObject: entryPayload),
                isHTTPResponse: true,
                statusCode: 200
            ),
            conversationSync
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let current = Enterprise(
            id: "tenant-1", name: "Current Tenant", code: "WXT111111", role: "member",
            status: "active", memberCount: 1, isDefault: true, accentHex: 0x5D6BFF,
            canSwitch: true, enterable: true
        )
        let target = Enterprise(
            id: "tenant-2", name: "Target Tenant", code: "WXT222222", role: "member",
            status: "active", memberCount: 1, isDefault: false, accentHex: 0x33AA88,
            canSwitch: true, enterable: true
        )
        state.setCurrentEnterprise(current) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setEnterprises([current, target]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        state.switchEnterprise(target)
        try await waitForCondition(iterations: 120) {
            state.enterpriseSwitchCompletionRevision == 1
        }

        XCTAssertEqual(state.enterpriseSwitchCompletionRevision, 1)
        XCTAssertEqual(state.currentEnterprise.id, "tenant-2")
        XCTAssertEqual(state.toast, "已切换到 Target Tenant")
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path == "/api/platform/me/tenants/tenant-2/enter" }.count,
            1
        )
    }

    func testSendAttachmentFallbackDownloadEndpointUsesPresignContract() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"message":{"message_id":"m1","channel_id":"g1","channel_type":"group","channel_seq":1,"from_uid":"uid-1","content_type":"file","payload":{"file_id":"file-1"},"status":"sent","created_at":"2026-06-26T00:00:00Z"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let file = RemoteAvatarFile(
            id: "file-1",
            fileName: "README.md",
            mimeType: "text/markdown",
            sizeBytes: 618,
            status: "uploaded",
            uploadStatus: "uploaded",
            previewAvailable: false,
            downloadAvailable: true,
            previewURL: "",
            downloadURL: "",
            downloadEndpoint: "",
            detailEndpoint: "",
            cacheKey: "cache-1",
            version: "v1",
            checksum: "",
            mediaCategory: "document",
            fileExtension: "md",
            thumbnailURL: "",
            posterURL: "",
            coverURL: "",
            previewKind: "download",
            contentDisposition: "attachment",
            width: nil,
            height: nil,
            durationSeconds: nil
        )

        _ = try await client.sendAttachment(
            context: makeContext(),
            conversation: makeGroupConversation(id: "g1"),
            channelID: "g1",
            kind: .file,
            file: file,
            name: "README.md",
            mimeType: "text/markdown",
            sizeBytes: 618,
            quote: nil,
            clientMessageID: "local-1"
        )

        let request = try XCTUnwrap(transport.requests().first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(payload["download_endpoint"] as? String, "/api/tenant/files/file-1/presign-download")
        XCTAssertEqual(payload["detail_endpoint"] as? String, "/api/tenant/files/file-1")
    }

    func testVoiceMessagePermissionGateWaitsForUserActionAndBusinessAllows() {
        XCTAssertFalse(VoiceMessagePermissionGate.shouldRequestMicrophone(userTriggered: false, businessBlocked: false, status: .notDetermined))
        XCTAssertFalse(VoiceMessagePermissionGate.shouldRequestMicrophone(userTriggered: true, businessBlocked: true, status: .notDetermined))
        XCTAssertFalse(VoiceMessagePermissionGate.shouldRequestMicrophone(userTriggered: true, businessBlocked: false, status: .granted))
        XCTAssertFalse(VoiceMessagePermissionGate.shouldRequestMicrophone(userTriggered: true, businessBlocked: false, status: .denied))
        XCTAssertTrue(VoiceMessagePermissionGate.shouldRequestMicrophone(userTriggered: true, businessBlocked: false, status: .notDetermined))
    }

    func testVoiceRecordingTooShortFeedbackRemainsAccessibleUntilNextAttempt() throws {
        var lifecycle = VoiceRecordingComposerLifecycle()

        lifecycle.presentTooShortFeedback()
        let feedback = try XCTUnwrap(lifecycle.feedback)
        XCTAssertEqual(feedback.message, "说话时间太短")
        XCTAssertEqual(feedback.accessibilityIdentifier, "chat_voice_recording_feedback_too_short")
        XCTAssertEqual(
            lifecycle.transition(to: .active, recordingPhase: .idle),
            .none
        )
        XCTAssertEqual(lifecycle.feedback, feedback)

        lifecycle.beginNewAttempt()
        XCTAssertNil(lifecycle.feedback)
    }

    func testVoiceRecordingLifecycleCancelsEveryTransientPhaseBeforeForegroundRestore() {
        let backgroundTransientPhases: [VoiceRecordingComposerPhase] = [
            .requesting,
            .recording,
            .finalizing,
            .preview,
        ]

        for recordingPhase in backgroundTransientPhases {
            var lifecycle = VoiceRecordingComposerLifecycle()
            lifecycle.presentTooShortFeedback()

            XCTAssertEqual(
                lifecycle.transition(to: .background, recordingPhase: recordingPhase),
                .cancelAndReset,
                "background must cancel \(recordingPhase)"
            )
            XCTAssertNil(lifecycle.feedback)
            XCTAssertEqual(
                lifecycle.transition(to: .active, recordingPhase: .idle),
                .none
            )
        }

        for recordingPhase in [VoiceRecordingComposerPhase.recording, .finalizing, .preview] {
            var lifecycle = VoiceRecordingComposerLifecycle()
            XCTAssertEqual(
                lifecycle.transition(to: .inactive, recordingPhase: recordingPhase),
                .cancelAndReset,
                "inactive must cancel \(recordingPhase)"
            )
        }

        var permissionRequest = VoiceRecordingComposerLifecycle()
        XCTAssertEqual(
            permissionRequest.transition(to: .inactive, recordingPhase: .requesting),
            .none,
            "the system permission sheet must not cancel its own user-triggered request"
        )
    }

    func testTextSendLostResponseRetriesOnceWithSameClientMessageIDAndKeepsSession() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = ScriptedMessageHTTPTransport(actions: [
            .response(activeAppPolicyResult()),
            .failure(.networkConnectionLost),
            .response(messageSendSuccessResult(messageID: "message-after-lost-response"))
        ])
        let state = makeMessageSendState(transport: transport)
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }

        XCTAssertTrue(state.sendText("hello", conversationID: "uid-1:uid-2", quote: nil))
        try await waitForCondition(iterations: 120) {
            state.conversationStore.conversationMessageSnapshots().first?.messages.first?.id == "message-after-lost-response"
        }

        let sends = transport.requests().filter { $0.url?.path == "/api/im/messages" }
        XCTAssertEqual(sends.count, 2)
        let bodies = try sends.map(requestJSONObject)
        let clientMessageID = try XCTUnwrap(bodies.first?["client_msg_no"] as? String)
        XCTAssertFalse(clientMessageID.isEmpty)
        XCTAssertEqual(bodies.last?["client_msg_no"] as? String, clientMessageID)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.count, 1)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
    }

    func testTextSend2XXDecodeFailureRetriesOnceWithSameClientMessageID() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = ScriptedMessageHTTPTransport(actions: [
            .response(activeAppPolicyResult()),
            .response(HTTPTransportResult(data: Data(#"{"ok":true,"data":{"message":{}}}"#.utf8), isHTTPResponse: true, statusCode: 201)),
            .response(messageSendSuccessResult(messageID: "message-after-decode-retry"))
        ])
        let state = makeMessageSendState(transport: transport)
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }

        XCTAssertTrue(state.sendText("hello", conversationID: "uid-1:uid-2", quote: nil))
        try await waitForCondition(iterations: 120) {
            state.conversationStore.conversationMessageSnapshots().first?.messages.first?.id == "message-after-decode-retry"
        }

        let sends = transport.requests().filter { $0.url?.path == "/api/im/messages" }
        XCTAssertEqual(sends.count, 2)
        guard sends.count == 2 else { return }
        let bodies = try sends.map(requestJSONObject)
        XCTAssertEqual(bodies[0]["client_msg_no"] as? String, bodies[1]["client_msg_no"] as? String)
        XCTAssertTrue(state.isAuthenticated)
    }

    func testTextSendRepeatedUncertainOutcomeStopsAfterOneRetryAndKeepsRetryableBubble() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = ScriptedMessageHTTPTransport(actions: [
            .response(activeAppPolicyResult()),
            .failure(.networkConnectionLost),
            .response(HTTPTransportResult(data: Data("not-json".utf8), isHTTPResponse: true, statusCode: 201))
        ])
        let state = makeMessageSendState(transport: transport)
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }

        XCTAssertTrue(state.sendText("hello", conversationID: "uid-1:uid-2", quote: nil))
        try await waitForCondition(iterations: 120) {
            state.conversationStore.conversationMessageSnapshots().first?.messages.first?.status == .failed
        }

        let sends = transport.requests().filter { $0.url?.path == "/api/im/messages" }
        XCTAssertEqual(sends.count, 2)
        guard sends.count == 2 else { return }
        let bodies = try sends.map(requestJSONObject)
        XCTAssertEqual(bodies[0]["client_msg_no"] as? String, bodies[1]["client_msg_no"] as? String)
        XCTAssertEqual(state.toast, "消息发送状态未确认，可点击重发")
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
    }

    func testTextSendOrdinaryBadRequestFailsMessageWithoutLogoutOrAutomaticRetry() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = ScriptedMessageHTTPTransport(actions: [
            .response(activeAppPolicyResult()),
            .response(HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"bad_request","message":"bad_request"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 400
            ))
        ])
        let state = makeMessageSendState(transport: transport)
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }

        XCTAssertTrue(state.sendText("hello", conversationID: "uid-1:uid-2", quote: nil))
        try await waitForCondition(iterations: 120) {
            state.conversationStore.conversationMessageSnapshots().first?.messages.first?.status == .failed
        }

        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/im/messages" }.count, 1)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
    }

    func testTextSendUnauthorizedRefreshesAndRetriesOnceWithSameClientMessageID() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"invalid_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_token":"fresh-im-token","expires_at":1800000000,"tenant":{"tenant_id":"tenant-1","name":"Tenant 1","status":"active"},"member":{"tenant_id":"tenant-1","account_id":"account-1","im_uid":"uid-1","status":"active","role":"member"},"auth_session":{"session_id":"sess_platform-tenant-1","refresh_token":"platform-tenant-refresh-2","expires_at":1800000000,"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"im"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"message":{"message_id":"message-confirmed","channel_id":"uid-1:uid-2","channel_type":"direct","channel_seq":7,"from_uid":"uid-1","content_type":"text","payload":{"text":"hello"},"status":"sent","created_at":"2026-08-17T11:02:18Z"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 201
            )
        ])
        let state = makeIsolatedOutgoingState(transport: transport, context: makeRefreshableMessageSendContext())
        state.authenticationPresentationStore.setInitialAuthentication(true)
        _ = try await state.loadCurrentAppPolicy(force: true)
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }
        XCTAssertEqual(transport.requests().map(\.url?.path), ["/api/platform/apps/current-policy"])

        XCTAssertTrue(state.sendText("hello", conversationID: "uid-1:uid-2", quote: nil))
        try await waitForCondition(iterations: 120) {
            state.conversationStore.conversationMessageSnapshots().first?.messages.first?.id == "message-confirmed"
        }

        let requests = transport.requests().filter { $0.url?.path != "/api/platform/apps/current-policy" }
        XCTAssertEqual(requests.map(\.url?.path), [
            "/api/im/messages",
            "/api/platform/tenants/tenant-1/session/refresh",
            "/api/im/messages"
        ])
        guard requests.count == 3 else {
            XCTFail("Expected one send, one refresh and one idempotent retry; got \(requests.count) requests")
            return
        }
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer stale-im-token")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer fresh-im-token")
        let sendBodies = try [requests[0], requests[2]].map(requestJSONObject)
        let firstClientMessageID = try XCTUnwrap(sendBodies[0]["client_msg_no"] as? String)
        XCTAssertFalse(firstClientMessageID.isEmpty)
        XCTAssertEqual(sendBodies[1]["client_msg_no"] as? String, firstClientMessageID)
        XCTAssertTrue(state.isAuthenticated)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testRegistrationRejectsConflictingNestedEntryWithoutChangingPlatformSnapshot() async throws {
        for conflict in ["device", "app", "platformFamily", "imUID", "imToken", "authTenant"] {
            clearStoredAPIContext()
            defer { clearStoredAPIContext() }
            let original = try registrationTenantEntrySuccess(tenantID: "tenant-1")
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: original.data) as? [String: Any])
            var data = try XCTUnwrap(envelope["data"] as? [String: Any])
            var auth = try XCTUnwrap(data["auth_session"] as? [String: Any])
            var nested: [String: Any] = ["app_id": "jianhuitong-ios", "device_id": "device-1",
                                         "im_uid": "uid-1", "im_token": "tenant-authoritative-token"]
            switch conflict {
            case "device": nested["device_id"] = "conflicting-device"
            case "app": nested["app_id"] = "conflicting-app"
            case "platformFamily": auth["token_type"] = "platform"; auth["session_id"] = "unexpected-platform"
            case "imUID": nested["im_uid"] = "conflicting-uid"
            case "imToken": nested["im_token"] = "conflicting-fixture-token"
            default: auth["tenant_id"] = "conflicting-tenant"
            }
            nested["auth_session"] = auth
            data["session"] = nested
            envelope["data"] = data
            let transport = SessionReauthenticationRouteGateTransport(responses: [
                "/api/platform/apps/current-policy": activeAppPolicyResult(),
                "/api/platform/auth/register": try atomicRegistrationSuccess(requestedTenantCode: "WXT553222", canonicalTenantCode: "WXT553222"),
                "/api/platform/me/tenants/tenant-1/enter": try tenantEnterSuccess(entryTicket: "registration-entry", routes: runtimeRouteSnapshotForHTTPWiring()),
                "/api/tenant/auth/platform-entry": HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: envelope), isHTTPResponse: true, statusCode: 200)
            ])
            let store = InMemoryProtectedSessionStore()
            let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
                                 protectedSessionStore: store, registrationSessionStore: InMemoryProtectedSessionStore(),
                                 apiContextOverride: makePreloginContext())
            _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
            state.registerAndEnterIM(account: "fixture58", password: "fixture-password", enterpriseCode: "WXT553222")
            try await waitForCondition { transport.entryRequestCount == 1 }
            let before = IMAPIContext.load(sessionStore: store)
            transport.releaseEntry()
            try await waitForCondition { state.registrationConfirmationTimedOut && !state.isAuthLoading }
            let after = IMAPIContext.load(sessionStore: store)
            XCTAssertEqual(after.authSessionFence, before.authSessionFence, conflict)
            XCTAssertEqual(after.platformToken, before.platformToken, conflict)
            XCTAssertEqual(after.platformAuthSession, before.platformAuthSession, conflict)
            XCTAssertEqual(after.appID, before.appID, conflict)
            XCTAssertEqual(after.deviceID, before.deviceID, conflict)
            XCTAssertNil(after.imToken, conflict)
            XCTAssertNil(after.tenantAuthSession, conflict)
            XCTAssertFalse(state.isAuthenticated, conflict)
            XCTAssertFalse(state.isRegistrationSubmissionBlocked, conflict)
        }
    }

    func testRegistrationTenantEntryPersistenceFailureKeepsPlatformAuthorityAndStaysPending() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try atomicRegistrationSuccess(
                requestedTenantCode: "WXT553222",
                canonicalTenantCode: "WXT553222"
            ),
            try tenantEnterSuccess(entryTicket: "registration-entry", routes: runtimeRouteSnapshotForHTTPWiring()),
            try registrationTenantEntrySuccess(tenantID: "tenant-1")
        ])
        // Fail tenant-authority commit after the platform-only snapshot;
        // recovery must retain the platform commit, never the inline IM token.
        let sessionStore = InMemoryProtectedSessionStore(failingWriteNumbers: [2])
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

        state.registerAndEnterIM(account: "admin12", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }

        XCTAssertGreaterThanOrEqual(sessionStore.writeAttemptCount, 2)
        XCTAssertEqual(sessionStore.deleteAllCount, 0)
        let retained = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertEqual(retained.platformToken, "platform-token-redacted")
        XCTAssertEqual(retained.platformAuthSession?.sessionID, "platform-session")
        XCTAssertNil(retained.imToken)
        XCTAssertNil(retained.tenantAuthSession)
        XCTAssertTrue(transport.requests().contains { $0.url?.path == "/api/tenant/auth/platform-entry" })
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/switch") == true })
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.timeoutMessage)
    }

    // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_BEGIN
    func testServerDefinedInviteReachesRegistrationAndCaptchaEndpoints() async throws {
        let code = "Invite_较长&A+=1-next"
        let rejection = HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"member_invite_code_invalid","message":"invite not found"}}"#.utf8),
            isHTTPResponse: true, statusCode: 403
        )
        let transport = FakeHTTPTransport(results: [rejection])
        let client = makeClient(transport: transport)
        let context = makePreloginContext()
        for action in [
            { _ = try await client.registerWithRequestID(username: "tester1", phone: "", password: "Test1234!",
                tenantCode: "  \(code)  ", captchaCode: nil, enterpriseContextToken: nil, appID: context.appID,
                deviceID: context.deviceID, requestID: UUID().uuidString) },
            { _ = try await client.captchaEntryStatus(scene: "register", channel: "sms", tenantCode: code, appID: context.appID) },
            { _ = try await client.sendPlatformCaptcha(phone: "13800138000", scene: "register", tenantCode: code) },
            { _ = try await client.resolveEnterpriseContext(tenantCode: code, appID: context.appID, deviceID: context.deviceID) },
        ] as [() async throws -> Void] {
            do {
                try await action()
                XCTFail("Expected the server rejection")
            } catch IMAPIError.businessForbidden(let returnedCode, _, _) {
                XCTAssertEqual(returnedCode, "member_invite_code_invalid")
            }
        }
        let requests = transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/platform/auth/register", "/api/platform/captcha/entry-status",
            "/api/platform/captcha/send", "/api/platform/auth/enterprise-context/resolve"
        ])
        for request in requests {
            if let body = request.httpBody {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(object["tenant_code"] as? String, code)
            } else {
                let url = try XCTUnwrap(request.url)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "tenant_code" })?.value, code)
            }
        }
    }
    // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_END

    func testRegistrationMemberInviteCodeInvalidUsesFriendlyToast() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"member_invite_code_invalid","message":"member invite code invalid"}}"#.utf8),
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

        state.registerAndEnterIM(account: "admin12", password: "aa123456", enterpriseCode: "Invite_custom-not-found") // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        try await waitForCondition {
            state.registrationResolutionState == .failed && !state.isAuthLoading
        }

        XCTAssertEqual(AppState.memberInviteCodeUserMessage(for: "member_invite_code_invalid"), "邀请码无效或已停用")
        XCTAssertEqual(state.toast, "注册失败：邀请码无效或已停用")
        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertFalse(state.isAuthenticated)
    }

    func testOnlineQuotaHTTPErrorDoesNotMapToAuthFailureOrServerUnavailable() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"online_quota_exceeded","message":"too many online users"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 422
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"online_quota_service_unavailable","message":"quota store unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.listDevices(context: makeContext())
            XCTFail("Expected online quota exceeded")
        } catch IMAPIError.businessForbidden(let code, let message, _) {
            XCTAssertEqual(code, "online_quota_exceeded")
            XCTAssertEqual(message, "当前企业在线人数已达上限，请稍后重试或联系企业管理员")
        }

        do {
            _ = try await client.listDevices(context: makeContext())
            XCTFail("Expected online quota service unavailable")
        } catch IMAPIError.businessForbidden(let code, let message, _) {
            XCTAssertEqual(code, "online_quota_service_unavailable")
            XCTAssertEqual(message, "在线服务暂时不可用，请稍后重试")
        }
    }

    func testRealtimeOnlineQuotaErrorPreservesSessionAndShowsRetryableToast() {
        let context = makeContext()
        let state = AppState(apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        state.debugHandleRealtimeEnvelopeForTesting(RealtimeEnvelope(
            type: "error",
            requestID: "connect-1",
            payload: [
                "code": .string("online_quota_exceeded"),
                "message": .string("quota reached")
            ]
        ))

        XCTAssertEqual(state.toast, "当前企业在线人数已达上限，请稍后重试或联系企业管理员")
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.debugHasIMSessionForTesting())
    }

    func testGroupMemberQuotaErrorUsesGroupCopyAndPreservesContext() {
        let state = AppState(apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        state.debugHandleRemoteErrorForTesting(
            IMAPIError.conflict(code: "group_member_quota_exceeded", message: "quota reached"),
            fallback: "邀请成员失败"
        )

        XCTAssertEqual(state.toast, "该群人数已达上限，暂时无法加入")
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.debugHasIMSessionForTesting())
    }

    // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_BEGIN
    func testLicenseQuotaDebugScreenshotScenariosPreserveExpectedState() throws {
        captureA43RuntimeLoadedImages()
        let suite = "QuotaScreenshot." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        var sessionStores: [InMemoryProtectedSessionStore] = []
        var recoveryStores: [InMemoryProtectedSessionStore] = []
        func makeQuotaState(_ scenario: String) -> AppState {
            let context = makeContext(tenantID: suite + "." + scenario)
            let files = root.appendingPathComponent(scenario)
            let session = InMemoryProtectedSessionStore()
            let recovery = InMemoryProtectedSessionStore()
            sessionStores.append(session)
            recoveryStores.append(recovery)
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: FakeHTTPTransport(results: []), runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
                startupContext: context, runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
            )
            let state = AppState(
                api: api, pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
                accessDiscovery: AccessDiscoveryManager(store: AccessDiscoveryStore(baseDirectory: files.appendingPathComponent("discovery"))),
                realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(),
                videoMediaClient: NoopVideoMediaClient(), messageStore: AvatarProjectionEmptyMessageStore(),
                messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: files.appendingPathComponent("support"),
                    cachesBase: files.appendingPathComponent("caches")),
                biometricDefaults: defaults, rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
                rememberedLoginPreferenceStore: RecordingRememberedLoginPreferenceStore(),
                protectedSessionStore: session, registrationSessionStore: recovery, apiContextOverride: context
            )
            state.suppressCurrentUserIdentityPersistence = true
            return state
        }

        let registration = makeQuotaState("registration")
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
        ).data)
        registration.appPolicyPresentationStore.installResolvedPolicy(policy)
        XCTAssertTrue(registration.configureLicenseQuotaScreenshotScenarioIfRequested(
            ["--license-quota-screenshot=registration"], fixtureDefaults: defaults
        ))
        XCTAssertEqual(registration.licenseQuotaScreenshotScenario, .registration)
        XCTAssertEqual(registration.authScreen, .accountRegister)
        XCTAssertFalse(registration.isAuthenticated)
        XCTAssertTrue(registration.isRegistrationEnabledForAuthUI)
        XCTAssertFalse(registration.isEnterpriseCodeFirstForAuthUI)
        XCTAssertEqual(
            registration.licenseQuotaRegistrationPrefill,
            LicenseQuotaRegistrationPrefill(
                enterpriseCode: "WXT900033",
                account: "ACCOUNT_PLACEHOLDER",
                password: "PASSWORD_PLACEHOLDER"
            )
        )
        XCTAssertEqual(registration.toast, "当前企业注册用户数已达上限，请联系企业管理员")

        let onlineLimit = makeQuotaState("online-limit")
        XCTAssertTrue(onlineLimit.configureLicenseQuotaScreenshotScenarioIfRequested(["--license-quota-screenshot=online-limit"], fixtureDefaults: defaults))
        XCTAssertEqual(onlineLimit.licenseQuotaScreenshotScenario, .onlineLimit)
        XCTAssertNil(onlineLimit.globalPolicyScreenshotScenario)
        XCTAssertTrue(onlineLimit.isAuthenticated)
        XCTAssertTrue(onlineLimit.debugHasIMSessionForTesting())
        XCTAssertEqual(onlineLimit.toast, "当前企业在线人数已达上限，请稍后重试或联系企业管理员")

        let onlineUnavailable = makeQuotaState("online-service-unavailable")
        XCTAssertTrue(onlineUnavailable.configureLicenseQuotaScreenshotScenarioIfRequested(["--license-quota-screenshot=online-service-unavailable"], fixtureDefaults: defaults))
        XCTAssertEqual(onlineUnavailable.licenseQuotaScreenshotScenario, .onlineServiceUnavailable)
        XCTAssertNil(onlineUnavailable.globalPolicyScreenshotScenario)
        XCTAssertTrue(onlineUnavailable.isAuthenticated)
        XCTAssertTrue(onlineUnavailable.debugHasIMSessionForTesting())
        XCTAssertEqual(onlineUnavailable.toast, "在线服务暂时不可用，请稍后重试")

        let group = makeQuotaState("group")
        XCTAssertTrue(group.configureLicenseQuotaScreenshotScenarioIfRequested(["--license-quota-screenshot=group"], fixtureDefaults: defaults))
        XCTAssertEqual(group.licenseQuotaScreenshotScenario, .group)
        XCTAssertTrue(group.isAuthenticated)
        XCTAssertTrue(group.debugHasIMSessionForTesting())
        XCTAssertEqual(group.group(id: "group-lifecycle-stage4")?.name, "群聊退出解散验收群")
        XCTAssertEqual(group.groupLifecycleScreenshotScenario, .member)
        XCTAssertEqual(group.toast, "该群人数已达上限，暂时无法加入")
        XCTAssertEqual(sessionStores.map { $0.deleteAllCount }, [1, 0, 0, 0])
        XCTAssertEqual(sessionStores.map { $0.writeAttemptCount }, [0, 0, 0, 0])
        XCTAssertTrue(recoveryStores.allSatisfy { $0.deleteAllCount == 0 && $0.writeAttemptCount == 0 })
    }
    // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_END

    func testMyInviteCodeUsesTenantEndpointAndDecodesCanonicalField() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"enabled":true,"item":{"id":"invite-1","tenant_id":"tenant-1","im_uid":"AB-U000001","user_id":"AB-U000001","display_name":"Admin","role":"admin","member_invite_code":"AB-I00A001","status":"active","sync_status":"synced","sync_version":3,"invite_count":2,"joined_count":1,"pending_count":1}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let response = try await client.myInviteCode(context: makeContext())

        XCTAssertTrue(response.enabled)
        XCTAssertEqual(response.memberInviteCode, "AB-I00A001")
        XCTAssertEqual(response.item?.imUID, "AB-U000001")
        XCTAssertEqual(response.item?.userID, "AB-U000001")
        XCTAssertEqual(response.item?.syncStatus, "synced")
        XCTAssertEqual(response.item?.inviteCount, 2)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/me/invite-code")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
    }

    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_BEGIN
    func testInviteCodeSnapshotPublishesCoherentLoadingAndResult() async {
        let transport = FakeHTTPTransport(results: [
            inviteCodeResponse(code: "YQMTEST1234", tenantID: "tenant-1", imUID: "uid-1")
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let store = state.inviteCodeStore
        var snapshots: [PersonalInviteCodeStore.Snapshot] = []
        let subscription = store.$snapshot.sink { snapshots.append($0) }
        defer { subscription.cancel() }

        await state.refreshMyInviteCode(force: true)
        XCTAssertEqual(snapshots.map(\.isLoading), [false, true, false])
        XCTAssertNil(snapshots.dropLast().first(where: { $0.code != nil }))
        XCTAssertEqual(snapshots.last?.code?.memberInviteCode, "YQMTEST1234")
        XCTAssertNil(snapshots.last?.errorMessage)

        var appUpdates = 0
        let app = state.objectWillChange.sink { appUpdates += 1 }
        store.reset()
        app.cancel()
        XCTAssertEqual(appUpdates, 0)
        XCTAssertEqual(snapshots.last, PersonalInviteCodeStore.Snapshot())
    }
    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_END

    func testInviteCodeActivationReadsCurrentAuthorityAndRejectsMismatchedIdentity() async throws {
        // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_BEGIN
        let transport = InviteCodeRaceHTTPTransport(
            first: inviteCodeResponse(code: "YQMTEST1234", tenantID: "tenant-1", imUID: "uid-1"),
            later: inviteCodeResponse(code: "YQMOTHER123", tenantID: "tenant-other", imUID: "uid-1")
        )
        transport.releaseFirstInviteResponse()
        // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_END
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        state.activateMyInviteCodeForCurrentSession()
        try await waitForCondition { state.myInviteCode?.memberInviteCode == "YQMTEST1234" }
        XCTAssertEqual(state.myInviteCode?.memberInviteCode, "YQMTEST1234")
        XCTAssertNil(state.myInviteCodeErrorMessage)

        await state.refreshMyInviteCode(force: true)
        XCTAssertNil(state.myInviteCode)
        XCTAssertEqual(state.myInviteCodeErrorMessage, "当前登录身份与请求不匹配，请重新登录后再试")
        XCTAssertFalse(state.isMyInviteCodeLoading)
    }

    func testInviteCodeLatestSameScopeRequestOwnsValueAndLoading() async throws {
        let transport = InviteCodeRaceHTTPTransport(
            first: inviteCodeResponse(code: "YQMOLDER123", tenantID: "tenant-1", imUID: "uid-1"),
            later: inviteCodeResponse(code: "YQMNEWER123", tenantID: "tenant-1", imUID: "uid-1")
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        let first = Task { await state.refreshMyInviteCode(force: true) }
        try await waitForCondition { transport.inviteRequestCount() == 1 }
        XCTAssertEqual(transport.inviteRequestCount(), 1)
        let second = Task { await state.refreshMyInviteCode(force: true) }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(transport.inviteRequestCount(), 1, "IMAPIClient should coalesce identical authenticated GETs")
        XCTAssertTrue(state.isMyInviteCodeLoading)

        transport.releaseFirstInviteResponse()
        await first.value
        await second.value
        XCTAssertEqual(state.myInviteCode?.memberInviteCode, "YQMOLDER123")
        XCTAssertFalse(state.isMyInviteCodeLoading)
    }

    func testInviteCodeLatePreviousTenantAndLogoutCannotPublish() async throws {
        let transport = InviteCodeRaceHTTPTransport(
            first: inviteCodeResponse(code: "YQMOLDER456", tenantID: "tenant-1", imUID: "uid-1"),
            later: inviteCodeResponse(code: "YQMNEWER456", tenantID: "tenant-2", imUID: "uid-2")
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        let oldTenantRequest = Task { await state.refreshMyInviteCode(force: true) }
        try await waitForCondition { transport.inviteRequestCount() == 1 }
        state.overrideAPIContextForTesting(
            makeContext(tenantID: "tenant-2", imUID: "uid-2", imToken: "im-token-2")
        )
        await state.refreshMyInviteCode(force: true)
        XCTAssertEqual(state.myInviteCode?.memberInviteCode, "YQMNEWER456")

        transport.releaseFirstInviteResponse()
        await oldTenantRequest.value
        XCTAssertEqual(state.myInviteCode?.memberInviteCode, "YQMNEWER456")

        let logoutTransport = InviteCodeRaceHTTPTransport(
            first: inviteCodeResponse(code: "YQMLOGOUT12", tenantID: "tenant-1", imUID: "uid-1"),
            later: inviteCodeResponse(code: "YQMIGNORED1", tenantID: "tenant-1", imUID: "uid-1")
        )
        let logoutState = AppState(api: makeClient(transport: logoutTransport), apiContextOverride: makeContext())
        logoutState.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let logoutRequest = Task { await logoutState.refreshMyInviteCode(force: true) }
        try await waitForCondition { logoutTransport.inviteRequestCount() == 1 }
        logoutState.logout()
        logoutTransport.releaseFirstInviteResponse()
        await logoutRequest.value
        XCTAssertFalse(logoutState.isAuthenticated)
        XCTAssertNil(logoutState.myInviteCode)
        XCTAssertNil(logoutState.myInviteCodeErrorMessage)
        XCTAssertFalse(logoutState.isMyInviteCodeLoading)
    }

    func testInviteCodeErrorsAreTruthfulAndDoNotExposeAuthorityValue() async {
        let unauthorized = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"unauthorized","message":"unauthorized"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 401
                )
            ])),
            apiContextOverride: makeContext()
        )
        unauthorized.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        await unauthorized.refreshMyInviteCode(force: true)
        XCTAssertEqual(unauthorized.myInviteCodeErrorMessage, "登录已失效，请重新登录")
        XCTAssertNil(unauthorized.myInviteCode)

        let forbidden = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"forbidden","message":"forbidden"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 403
                )
            ])),
            apiContextOverride: makeContext()
        )
        forbidden.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        await forbidden.refreshMyInviteCode(force: true)
        XCTAssertEqual(forbidden.myInviteCodeErrorMessage, "当前账号无权限读取邀请码")
        XCTAssertNil(forbidden.myInviteCode)

        let offline = AppState(
            api: makeClient(transport: FailingHTTPTransport(error: URLError(.notConnectedToInternet))),
            apiContextOverride: makeContext()
        )
        offline.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        await offline.refreshMyInviteCode(force: true)
        XCTAssertEqual(offline.myInviteCodeErrorMessage, "网络连接不可用，请稍后重试")
        XCTAssertNil(offline.myInviteCode)
    }

    func testRegistrationAmbiguousDefaultFallbackForUnboundEnterpriseCodeStaysPending() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"admin11","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session","refresh_token":"platform-refresh","expires_at":1785200000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"fallback_to_default_tenant":true,"fallback_reason":"tenant_code_not_found","requested_tenant_code":"553222","default_tenant_code":"WXT999999","tenant":{"tenant_id":"tenant-qa","tenant_code":"WXT999999","name":"QA Tenant","status":"active"},"tenant_member":{"tenant_id":"tenant-qa","account_id":"account-1","im_uid":"uid-qa","status":"active","role":"member"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }

        assertRegistrationAppIDIsolationPendingState(state)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage)
        XCTAssertEqual(transport.requests().count, 2)
    }

    func testRegistrationIncompleteSuccessResponseStaysPendingWithoutManualLoginFallback() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"admin11","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session-1","refresh_token":"platform-refresh-1","expires_at":1785200000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }

        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.url?.absoluteString == "https://platform.example.test/api/platform/me/tenants?app_id=jianhuitong-ios" })
    }

    func testRegistrationAccountCreatedJoinPendingUsesGenericConfirmationState() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","registration_enabled":true,"enterprise_code_first":false,"allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"admin15","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session-1","refresh_token":"platform-refresh-1","expires_at":1895000000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"entry_status":"account_created","entry_type":"enterprise_code","scheme":"unified_v1","canonical":"AB001234","requested_tenant_code":"AB001111","workspaces":[]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","app_scoped":true,"workspace_count":0,"enterable_workspace_count":0,"selection_mode":"workspace_selection","empty_reason":"","workspaces":[]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"tenant":{"tenant_id":"tenant-bound","tenant_code":"AB001234","name":"Bound Tenant","status":"active"},"member":{"tenant_id":"tenant-bound","account_id":"account-1","im_uid":"AB-U000001","status":"pending","role":"member"},"join_status":"pending_approval","application_status":"pending","approval_required":true,"can_enter":false,"can_switch":false,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound","reason_code":"workspace_join_pending"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin15", password: "aa123456", enterpriseCode: " ab001111 ")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }

        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage)
        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        let persisted = IMAPIContext.load(sessionStore: sessionStore)
        XCTAssertNil(persisted.platformToken)
        XCTAssertFalse(persisted.hasIMSession)
        let requests = transport.requests()
        XCTAssertEqual(requests.map(\.url?.path), [
            "/api/platform/apps/current-policy",
            "/api/platform/auth/register",
            "/api/platform/me/tenants",
            "/api/platform/tenants/join"
        ])
        let joinRequest = try XCTUnwrap(requests.last)
        let bodyData = try XCTUnwrap(joinRequest.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["tenant_code"] as? String, "AB001234")
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
    }

    func testRegistrationPendingApprovalClearsSessionAndUsesGenericConfirmationState() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"admin11","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session-1","refresh_token":"platform-refresh-1","expires_at":1895000000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"requires_approval":true,"requested_tenant_code":"WXT553222","tenant":{"tenant_id":"tenant-bound","tenant_code":"WXT553222","name":"Bound Tenant","status":"active"},"tenant_member":{"tenant_id":"tenant-bound","account_id":"account-1","im_uid":"uid-1","status":"pending","role":"member"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let sessionStore = InMemoryProtectedSessionStore()
        let state = AppState(
            api: makeClient(transport: transport),
            protectedSessionStore: sessionStore,
            apiContextOverride: makePreloginContext()
        )
        defer { state.logout() }
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)

        state.registerAndEnterIM(account: "admin11", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.registrationResolutionState == .pending && !state.isAuthLoading
        }

        XCTAssertFalse(state.isAuthLoading)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage)
        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertNil(IMAPIContext.load(sessionStore: sessionStore).platformToken)
        XCTAssertFalse(IMAPIContext.load(sessionStore: sessionStore).hasIMSession)
    }

    func testRegistrationCanonicalTenantProbeRateLimitRemainsVisibleOnRegistration() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","registration_enabled":true,"enterprise_code_first":false,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"registration_tenant_code_probe_rate_limited","message":"rate limited","retry_after":1800,"retry_after_seconds":1800}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 429,
                headers: ["Retry-After": "1800"]
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: makePreloginContext()
        )
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        state.setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

        state.registerAndEnterIM(account: "admin13", password: "aa123456", enterpriseCode: "553222")
        try await waitForCondition {
            state.toast == "企业码验证过于频繁，请稍后再试。" && !state.isAuthLoading
        }

        XCTAssertEqual(state.authScreen, .accountRegister)
        XCTAssertEqual(state.toast, "企业码验证过于频繁，请稍后再试。")
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertEqual(transport.requests().count, 2)
    }

    func testLoginRequiresWorkspaceSelectionDoesNotAutoEnterSingleEnterableWorkspace() async throws {
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
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"admin11","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session","refresh_token":"platform-refresh","expires_at":1785200000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"requires_workspace_selection":true,"can_direct_enter":false,"entry_status":"none","pending_entry_tenant_id":"","workspaces":[{"tenant_id":"tenant-bound","tenant_code":"WXT553222","name":"Bound Tenant","status":"active","join_status":"joined","member_status":"active","member_role":"member","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","app_scoped":true,"workspace_count":1,"enterable_workspace_count":1,"selection_mode":"workspace_selection","empty_reason":"","workspaces":[{"tenant_id":"tenant-bound","name":"Bound Tenant","tenant_code":"WXT553222","status":"active","join_status":"joined","member_status":"active","member_role":"member","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound"}]}}"#.utf8),
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
        XCTAssertEqual(state.enterprises.count, 1)
        XCTAssertEqual(state.enterprises.first?.name, "Bound Tenant")
        let requestURLs = transport.requests().compactMap { $0.url?.absoluteString }
        XCTAssertEqual(requestURLs, [
            "https://platform.example.test/api/platform/apps/current-policy?app_id=jianhuitong-ios",
            "https://platform.example.test/api/platform/captcha/slide/config?scene=im_user_login&surface=ios&app_id=jianhuitong-ios",
            "https://platform.example.test/api/platform/auth/im-login",
            "https://platform.example.test/api/platform/me/tenants?app_id=jianhuitong-ios"
        ])
    }

    func testFailedLoginNeverPersistsRememberedCredentials() async throws {
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
                data: Data(#"{"ok":false,"error":{"code":"invalid_credentials","message":"invalid credentials"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
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
        state.setRememberLoginCredentialsEnabled(true)

        state.startLoginFlow(identifier: "remember-user", password: "SyntheticPass123!", credentialMode: .account)
        try await waitForCondition { !state.isAuthLoading && state.toast != nil }

        XCTAssertEqual(credentialStore.saveCount, 0)
        XCTAssertNil(credentialStore.load(scope: scope))
        XCTAssertTrue(state.rememberLoginCredentialsEnabledForAuthUI)
    }
}

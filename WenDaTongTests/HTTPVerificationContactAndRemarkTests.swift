import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testVerificationRequirementSatisfiedAuthoritySurvivesRefreshAndFailsClosedAfterRelogin() async throws { // WDT_IOS1_WIRE83_FIXTURE_ISOLATION_20261111_BEGIN
        let suite = "VerificationAuthority.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: files) }
        var context = makeContext()
        context.appID = "jht-ios-main"

        func makeVerificationState(transport: HTTPTransport, stage: String) -> AppState {
            let root = files.appendingPathComponent(stage, isDirectory: true)
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport,
                runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
                startupContext: context,
                runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
            )
            let state = AppState(
                api: api,
                pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
                accessDiscovery: AccessDiscoveryManager(store: AccessDiscoveryStore(baseDirectory: root.appendingPathComponent("discovery"))),
                realtimeClient: PostLoginSilentRealtimeTransport(),
                voiceMediaClient: NoopVoiceMediaClient(),
                videoMediaClient: NoopVideoMediaClient(),
                messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
                messagePersistence: MessagePersistenceCoordinator(
                    applicationSupportBase: root.appendingPathComponent("support"),
                    cachesBase: root.appendingPathComponent("caches")
                ),
                biometricDefaults: defaults,
                rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
                rememberedLoginPreferenceStore: RecordingRememberedLoginPreferenceStore(),
                protectedSessionStore: InMemoryProtectedSessionStore(),
                registrationSessionStore: InMemoryProtectedSessionStore(),
                apiContextOverride: context
            )
            // Start with the same empty policy and identity cache conditions as the former fixture reset.
            state.appPolicyPresentationStore.snapshot = .init()
            state.currentAppPolicyExpiresAt = nil
            state.suppressCurrentUserIdentityPersistence = true
            return state
        }

        let policy = try JSONDecoder().decode(
            RemoteAppCurrentPolicy.self,
            from: Data(#"{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"require_real_name":true,"require_phone_verification":true,"cache_ttl_seconds":60}"#.utf8)
        )
        let authoritativeTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","phone_requirement_satisfied":true,"real_name_requirement_satisfied":true,"phone_masked":"138****1001","real_name_masked":"张*","real_name_status":"approved"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let firstState = makeVerificationState(transport: authoritativeTransport, stage: "initial")
        firstState.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        firstState.setCurrentUser(makeVerificationAuthorityUser(
            id: "uid-1",
            phoneVerified: false,
            realNameVerified: false
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        await firstState.refreshVerificationStatus()

        XCTAssertTrue(firstState.currentUser.phoneVerified)
        XCTAssertTrue(firstState.currentUser.realNameVerified)
        XCTAssertEqual(firstState.currentUser.phone, "138****1001")
        XCTAssertNil(AppPolicyForcedAuthRequirement.pendingRequirement(
            policy: policy,
            user: firstState.currentUser
        ))

        let reloginTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","phone_masked":"138****1001","real_name_masked":"张*","real_name_status":"approved"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let reloggedState = makeVerificationState(transport: reloginTransport, stage: "relogin")
        reloggedState.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        reloggedState.setCurrentUser(makeVerificationAuthorityUser(
            id: "uid-1",
            phoneVerified: true,
            realNameVerified: true
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        await reloggedState.refreshVerificationStatus()

        XCTAssertFalse(reloggedState.currentUser.phoneVerified)
        XCTAssertFalse(reloggedState.currentUser.realNameVerified)
        XCTAssertEqual(reloggedState.currentUser.phone, "138****1001")
        XCTAssertEqual(
            AppPolicyForcedAuthRequirement.pendingRequirement(
                policy: policy,
                user: reloggedState.currentUser
            ),
            .phone
        )
    } // WDT_IOS1_WIRE83_FIXTURE_ISOLATION_20261111_END

    func testVerificationRefreshKeepsMaskedPresentationWhenRequirementIsUnsatisfied() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        var context = makeContext()
        context.appID = "jht-ios-main"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"require_real_name":false,"require_phone_verification":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","account_id":"account-1","phone_bound":false,"phone_masked":"","real_name_verified":false,"real_name_status":"unsubmitted"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(IMUser(
            id: "uid-1",
            username: "admin2",
            name: "admin2",
            title: "",
            department: "",
            phone: "138****1002",
            phoneVerified: true,
            realNameVerified: false,
            realNameStatus: "unsubmitted",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        let didLoadPolicy = await state.refreshCurrentAppPolicyForAuthUI()
        XCTAssertTrue(didLoadPolicy)
        state.forcedAppPolicyAuthStore.setPrompt(.phone) // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110
        await state.refreshVerificationStatus()
        XCTAssertEqual(state.currentUser.phone, "138****1002")
        XCTAssertFalse(state.currentUser.phoneVerified)
        XCTAssertEqual(state.forcedAppPolicyAuthPrompt, .phone)
    }

    func testVerificationRefreshRejectsCrossUserAuthorityWithoutConsumingMaskedPresentation() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-other","phone_requirement_satisfied":true,"real_name_requirement_satisfied":true,"phone_masked":"139****9999","real_name_status":"approved"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeVerificationAuthorityUser(
            id: "uid-current",
            phoneVerified: true,
            realNameVerified: true
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        await state.refreshVerificationStatus()
        XCTAssertEqual(state.currentUser.phone, "138****1001")
        XCTAssertFalse(state.currentUser.phoneVerified)
        XCTAssertFalse(state.currentUser.realNameVerified)
        XCTAssertEqual(state.currentUser.realNameStatus, "approved")
    }

    func testVerificationRefreshFailsClosedWhenRequirementFieldsAreMissing() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        var context = makeContext()
        context.appID = "jht-ios-main"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"require_real_name":false,"require_phone_verification":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","account_id":"account-1","real_name_verified":false,"real_name_status":"unsubmitted"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(IMUser(
            id: "uid-1",
            username: "admin2",
            name: "admin2",
            title: "",
            department: "",
            phone: "138****1002",
            phoneVerified: true,
            realNameVerified: false,
            realNameStatus: "unsubmitted",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        let didLoadPolicy = await state.refreshCurrentAppPolicyForAuthUI()
        XCTAssertTrue(didLoadPolicy)
        state.forcedAppPolicyAuthStore.setPrompt(.phone) // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110
        await state.refreshVerificationStatus()
        XCTAssertEqual(state.currentUser.phone, "138****1002")
        XCTAssertFalse(state.currentUser.phoneVerified)
        XCTAssertEqual(state.forcedAppPolicyAuthPrompt, .phone)
    }

    func testForcedPhoneGateDoesNotUseProfileMaskedPhoneAsRequirementProof() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        var context = makeContext()
        context.appID = "jht-ios-main"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"require_real_name":false,"require_phone_verification":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","account_id":"account-1","phone":null,"phone_masked":null,"phone_bound":false,"phone_verified":null,"real_name_verified":false,"real_name_status":"unsubmitted"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","username":"admin2","nickname":"admin2","phone":"138****1002","status":"active"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let state = AppState(api: client, apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(IMUser(
            id: "uid-1",
            username: "admin2",
            name: "admin2",
            title: "",
            department: "",
            phone: "",
            phoneVerified: false,
            realNameVerified: false,
            realNameStatus: "unsubmitted",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        let didLoadPolicy = await state.refreshCurrentAppPolicyForAuthUI()
        XCTAssertTrue(didLoadPolicy)
        do {
            _ = try await client.listDevices(context: context)
            XCTFail("Expected the exact satisfied Boolean requirement gate")
        } catch IMAPIError.forcedAuthRequired(let requirement) {
            XCTAssertEqual(requirement, .phone)
        }
        XCTAssertEqual(state.currentUser.phone, "")
        XCTAssertFalse(state.currentUser.phoneVerified)
        XCTAssertEqual(state.forcedAppPolicyAuthPrompt, .phone)
        XCTAssertEqual(transport.requests().compactMap { $0.url?.path }, [
            "/api/platform/apps/current-policy",
            "/api/tenant/me/verification-status"
        ])
    }

    func testProfileNicknameUpdateUsesSubmittedNameWhenResponseOmitsNickname() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let context = makeContext()
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","username":"admin2","nickname":"","status":"active"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let currentUser = IMUser(
            id: "uid-1",
            userID: "uid-1",
            username: "admin2",
            name: "旧昵称",
            title: "",
            department: "",
            phone: "",
            phoneVerified: false,
            realNameVerified: false,
            realNameStatus: "unsubmitted",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )
        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [currentUser]
        var directConversation = makeDirectConversation(id: "uid-1:uid-2")
        directConversation.participants.insert(currentUser, at: 0)
        state.conversationStore.hydrateCachedConversations([directConversation])
        let ok = await state.updateCurrentUserProfile(name: "新昵称")
        XCTAssertTrue(ok)
        XCTAssertEqual(state.currentUser.name, "新昵称")
        XCTAssertEqual(state.contacts.first(where: { $0.id == "uid-1" })?.name, "新昵称")
        XCTAssertEqual(
            state.conversationStore.conversationMessageSnapshots().first?.participants.first(where: { $0.id == "uid-1" })?.name,
            "新昵称"
        )
        XCTAssertEqual(state.toast, "个人资料已更新")
        let request = try XCTUnwrap(
            transport.requests().first { $0.url?.path == "/api/tenant/me/profile" }
        )
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/me/profile")
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["nickname"] as? String, "新昵称")
    }

    func testProfileNicknameFailureRollsBackEveryOptimisticProjection() async throws {
        let context = makeContext()
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"temporary_failure","message":"temporary failure"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 500
                )
            ],
            delayNanoseconds: 100_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let currentUser = IMUser(
            id: "uid-1",
            userID: "uid-1",
            username: "admin2",
            name: "旧昵称",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )
        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [currentUser]
        var directConversation = makeDirectConversation(id: "uid-1:uid-2")
        directConversation.participants.insert(currentUser, at: 0)
        state.conversationStore.hydrateCachedConversations([directConversation])
        let update = Task { @MainActor in
            await state.updateCurrentUserProfile(name: "新昵称")
        }
        try await waitForCondition { state.currentUser.name == "新昵称" }
        XCTAssertEqual(state.contacts.first(where: { $0.id == "uid-1" })?.name, "新昵称")
        XCTAssertEqual(
            state.conversationStore.conversationMessageSnapshots().first?.participants.first(where: { $0.id == "uid-1" })?.name,
            "新昵称"
        )
        let succeeded = await update.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(state.currentUser.name, "旧昵称")
        XCTAssertEqual(state.contacts.first(where: { $0.id == "uid-1" })?.name, "旧昵称")
        XCTAssertEqual(
            state.conversationStore.conversationMessageSnapshots().first?.participants.first(where: { $0.id == "uid-1" })?.name,
            "旧昵称"
        )
        XCTAssertTrue(state.toast?.contains("个人资料保存失败") == true)
    }

    func testContactRemarkCreateAndClearProjectImmediatelyThenAcceptAuthoritativeResponse() async throws {
        // WDT_IOS1_CORE23_ISOLATED_AUTH_FIXTURE_20261111: keep original RPCs, rollback and waits on isolated authenticated input.
        let peer = makeUser(id: "uid-2", name: "Public Name")
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
        ).data)
        let emptyList = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200
        )
        let expectedRequests = [
            "GET /api/tenant/friends", "PATCH /api/tenant/friends/uid-2", "GET /api/tenant/friends/uid-2",
            "GET /api/tenant/friends/applications", "GET /api/tenant/blacklist", "GET /api/tenant/friends"
        ]
        let createTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"friend_uid":"uid-2","friend_user_id":"uid-2","raw_nickname":"Public Name","display_name":"Public Name","display_name_source":"nickname","remark":""}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-2","user_id":"uid-2","raw_nickname":"Public Name","display_name":"Private Remark","display_name_source":"remark","remark":"Private Remark"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-2","user_id":"uid-2","raw_nickname":"Public Name","display_name":"Private Remark","display_name_source":"remark","remark":"Private Remark"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            emptyList, emptyList, HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"friend_uid":"uid-2","friend_user_id":"uid-2","raw_nickname":"Public Name","display_name":"Private Remark","display_name_source":"remark","remark":"Private Remark"}]}}"#.utf8),
                isHTTPResponse: true, statusCode: 200
            )
        ])
        let createState = makeIsolatedAuthenticatedHTTPState(transport: createTransport, context: makeContext())
        createState.appPolicyPresentationStore.installResolvedPolicy(policy)
        createState.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        createState.contacts = [peer]
        createState.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        var createCompletion: FriendRemarkSaveResult?
        createState.setContactRemark("Private Remark", for: peer) {
            createCompletion = $0
        }
        try await waitForCondition { createCompletion == .success }
        XCTAssertEqual(createCompletion, .success)
        XCTAssertEqual(createState.contactRemarks[peer.id], "Private Remark")
        XCTAssertEqual(createState.contacts.first?.name, "Private Remark")
        XCTAssertEqual(createState.conversations.first?.title, "Private Remark")
        XCTAssertEqual(createState.toast, "已保存好友备注")
        try await waitForCondition { createTransport.requests().count >= expectedRequests.count }
        XCTAssertEqual(createTransport.requests().map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, expectedRequests)

        let clearTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"friend_uid":"uid-2","friend_user_id":"uid-2","raw_nickname":"Public Name","display_name":"Old Remark","display_name_source":"remark","remark":"Old Remark"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-2","user_id":"uid-2","raw_nickname":"Public Name","display_name":"Public Name","display_name_source":"nickname","remark":""}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-2","user_id":"uid-2","raw_nickname":"Public Name","display_name":"Public Name","display_name_source":"nickname","remark":""}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            emptyList, emptyList, HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"friend_uid":"uid-2","friend_user_id":"uid-2","raw_nickname":"Public Name","display_name":"Public Name","display_name_source":"nickname","remark":""}]}}"#.utf8),
                isHTTPResponse: true, statusCode: 200
            )
        ])
        let clearState = makeIsolatedAuthenticatedHTTPState(transport: clearTransport, context: makeContext())
        clearState.appPolicyPresentationStore.installResolvedPolicy(policy)
        clearState.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        clearState.contacts = [peer]
        clearState.contactRemarks = [peer.id: "Old Remark"]
        clearState.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        var clearCompletion: FriendRemarkSaveResult?
        clearState.setContactRemark("", for: peer) {
            clearCompletion = $0
        }
        try await waitForCondition { clearCompletion == .success }
        XCTAssertEqual(clearCompletion, .success)
        XCTAssertNil(clearState.contactRemarks[peer.id])
        XCTAssertEqual(clearState.contacts.first?.name, "Public Name")
        XCTAssertEqual(clearState.conversations.first?.title, "Public Name")
        XCTAssertEqual(clearState.toast, "已清空好友备注")
        try await waitForCondition { clearTransport.requests().count >= expectedRequests.count }
        XCTAssertEqual(clearTransport.requests().map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, expectedRequests)
    }

    func testBlockAndUnblockProjectImmediatelyWithoutDeletingPrivateRemarkOrHistory() async throws {
        let peer = makeUser(id: "uid-2", name: "Peer")
        let blockTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"owner_uid":"uid-1","blocked_uid":"uid-2","reason":"用户主动拉黑"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let blockState = AppState(api: makeClient(transport: blockTransport), apiContextOverride: makeContext())
        configureOrdinaryActionPolicyForExistingFlowTest(blockState)
        blockState.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        blockState.contacts = [peer]
        blockState.contactRemarks = [peer.id: "Private Remark"]
        blockState.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        blockState.blockContact(peer)
        XCTAssertTrue(blockState.blacklist.contains { $0.id == peer.id })
        XCTAssertFalse(blockState.contacts.contains { $0.id == peer.id })
        XCTAssertEqual(blockState.contactRemarks[peer.id], "Private Remark")
        XCTAssertEqual(blockState.conversations.count, 1)
        try await waitForCondition { blockState.toast == "已拉黑 Peer" }

        let unblockTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let unblockState = AppState(api: makeClient(transport: unblockTransport), apiContextOverride: makeContext())
        unblockState.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        unblockState.blacklist = [BlacklistItem(id: peer.id, name: peer.name, reason: "已拉黑")]
        unblockState.contactRemarks = [peer.id: "Private Remark"]
        unblockState.removeFromBlacklist(peer.id)
        XCTAssertFalse(unblockState.blacklist.contains { $0.id == peer.id })
        XCTAssertEqual(unblockState.contactRemarks[peer.id], "Private Remark")
        try await waitForCondition { unblockState.toast == "已将 Peer 移出黑名单" }
    }

    func testContactMutationFailuresRollbackOptimisticProjectionAndExposeActionableErrors() async throws {
        let failure = HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"temporary_failure","message":"temporary failure"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 500
        )
        // WDT_IOS1_CORE23_ISOLATED_AUTH_FIXTURE_20261111: keep original RPCs, rollback and waits on isolated authenticated input.
        let peer = makeUser(id: "uid-2", name: "Public Name")
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
        ).data)
        let remarkTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"friend_uid":"uid-2","friend_user_id":"uid-2","raw_nickname":"Public Name","display_name":"Old Remark","display_name_source":"remark","remark":"Old Remark"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            failure
        ])
        let remarkState = makeIsolatedAuthenticatedHTTPState(transport: remarkTransport, context: makeContext())
        remarkState.appPolicyPresentationStore.installResolvedPolicy(policy)
        remarkState.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        remarkState.contacts = [makeUser(id: peer.id, name: "Old Remark")]
        remarkState.contactRemarks = [peer.id: "Old Remark"]
        var remarkCompletion: FriendRemarkSaveResult?
        remarkState.setContactRemark("New Remark", for: peer) {
            remarkCompletion = $0
        }
        try await waitForCondition {
            if case .failure? = remarkCompletion {
                return true
            }
            return false
        }
        XCTAssertTrue(remarkState.toast?.contains("temporary failure") == true)
        XCTAssertEqual(remarkState.contacts.first?.name, "Old Remark")
        XCTAssertEqual(remarkState.contactRemarks[peer.id], "Old Remark")
        if case .failure(let failure)? = remarkCompletion {
            XCTAssertEqual(failure.kind, .server)
        } else {
            XCTFail("Expected contact remark save to fail")
        }
        let blockTransport = FakeHTTPTransport(results: [failure])
        let blockState = makeIsolatedAuthenticatedHTTPState(transport: blockTransport, context: makeContext())
        blockState.appPolicyPresentationStore.installResolvedPolicy(policy)
        blockState.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        configureOrdinaryActionPolicyForExistingFlowTest(blockState)
        blockState.contacts = [peer]
        blockState.contactRemarks = [peer.id: "Private Remark"]
        blockState.blockContact(peer)
        XCTAssertTrue(blockState.blacklist.contains { $0.id == peer.id })
        try await waitForCondition { blockState.toast?.contains("拉黑失败") == true }
        XCTAssertFalse(blockState.blacklist.contains { $0.id == peer.id })
        XCTAssertTrue(blockState.contacts.contains { $0.id == peer.id })
        XCTAssertEqual(blockState.contactRemarks[peer.id], "Private Remark")
        let unblockTransport = FakeHTTPTransport(results: [failure])
        let unblockState = makeIsolatedAuthenticatedHTTPState(transport: unblockTransport, context: makeContext())
        unblockState.appPolicyPresentationStore.installResolvedPolicy(policy)
        unblockState.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        unblockState.blacklist = [BlacklistItem(id: peer.id, name: peer.name, reason: "已拉黑")]
        unblockState.removeFromBlacklist(peer.id)
        XCTAssertTrue(unblockState.blacklist.isEmpty)
        try await waitForCondition { unblockState.toast?.contains("移出黑名单失败") == true }
        XCTAssertEqual(unblockState.blacklist.map(\.id), [peer.id])
        XCTAssertEqual(remarkTransport.requests().map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
                       ["GET /api/tenant/friends", "PATCH /api/tenant/friends/uid-2"])
        XCTAssertEqual(blockTransport.requests().map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
                       ["POST /api/tenant/blacklist"])
        XCTAssertEqual(unblockTransport.requests().map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
                       ["DELETE /api/tenant/blacklist/uid-2"])
    }

    func testForcedPolicyRefreshUpdatesCachedSupportContactEmail() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"support_contact_email":"","support_contact_configured":false,"cache_ttl_seconds":600}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"support_contact_email":"haha@qq.com","support_contact_configured":true,"cache_ttl_seconds":600}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport))
        let firstRefresh = await state.refreshCurrentAppPolicyForAuthUI()
        XCTAssertTrue(firstRefresh)
        XCTAssertEqual(state.currentAppPolicy?.supportContactEmail, "")
        XCTAssertFalse(state.currentAppPolicy?.supportContactConfigured ?? true)
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
        let store = state.appPolicyPresentationStore
        var authUpdates = 0
        var contactUpdates: [String] = []
        let observers = [
            store.updates(\.authentication).dropFirst().sink { _ in authUpdates += 1 },
            store.updates(\.supportContact).dropFirst().sink { contactUpdates.append($0.email) }
        ]
        defer { observers.forEach { $0.cancel() } }
        let forcedRefresh = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertEqual(authUpdates, 0)
        XCTAssertEqual(contactUpdates, ["haha@qq.com"])
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
        XCTAssertTrue(forcedRefresh)
        XCTAssertEqual(state.currentAppPolicy?.supportContactEmail, "haha@qq.com")
        XCTAssertTrue(state.currentAppPolicy?.supportContactConfigured ?? false)
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        let cachedPolicyRequest = try XCTUnwrap(requests.first)
        let forcedPolicyRequest = try XCTUnwrap(requests.dropFirst().first)
        XCTAssertEqual(cachedPolicyRequest.url?.query?.contains("_ts="), false)
        XCTAssertEqual(forcedPolicyRequest.url?.query?.contains("_ts="), true)
        XCTAssertEqual(forcedPolicyRequest.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testEnterpriseCodeInputFilterKeepsOnlyFirstSixDigits() throws {
        let filter = AuthInputFilter.digits(maxLength: 6)
        XCTAssertEqual(filter.apply(to: "WXT123456abc789"), "123456")
        XCTAssertEqual(filter.apply(to: "12-34 56"), "123456")
        XCTAssertEqual(filter.apply(to: "abcdef"), "")
        XCTAssertEqual(filter.apply(to: "9876543210"), "987654")
    }

    func testNotificationSettingsShowsOnlyReminderToggleAndPreservesPermissionLifecycleContract() throws {
        // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_BEGIN
        // WDT_IOS1_REFACTOR_ME_SETTINGS_VIEWS_20261109_BEGIN
        let iosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = iosRoot.appendingPathComponent("WenDaTong/Features/Me/NotificationSettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let viewSource = try XCTUnwrap(
            source.components(separatedBy: "struct NotificationSettingsView: View {").dropFirst().first
        )
        // WDT_IOS1_REFACTOR_ME_SETTINGS_VIEWS_20261109_END
        let wrapperBody = try XCTUnwrap(viewSource.components(separatedBy: "var body: some View {").dropFirst().first?
            .components(separatedBy: "private func scheduleNotificationPermissionRefresh()").first)
        let featureURL = iosRoot.appendingPathComponent("Sources/IM4Features/Me/NotificationSettingsContent.swift")
        let featureSource = try String(contentsOf: featureURL, encoding: .utf8)
        let bodySource = try XCTUnwrap(featureSource.components(separatedBy: "public var body: some View {").dropFirst().first)
        let renderedSource = wrapperBody + bodySource
        XCTAssertTrue(bodySource.contains("Form {"))
        XCTAssertTrue(bodySource.contains("Toggle(\"开启通知提醒\", isOn: $enabled)"))
        for expectedOnce in ["Form {", "Toggle(", "\"开启通知提醒\""] {
            XCTAssertEqual(renderedSource.components(separatedBy: expectedOnce).count - 1, 1)
        }
        for forbiddenText in ["接收范围", "灰度能力", "语音消息推送", "视频通话推送", "灰度中"] {
            XCTAssertEqual(
                renderedSource.components(separatedBy: forbiddenText).count - 1,
                0,
                "notification settings must not render \(forbiddenText)"
            )
        }
        XCTAssertFalse(renderedSource.contains("Section("), "the single toggle must not leave an empty section wrapper")

        for requiredLifecycleCall in [
            "NotificationSettingsContent(enabled: Binding(get: { notificationEnabled }, set: handleNotificationToggle)",
            ".onAppear {\n            scheduleNotificationPermissionRefresh()",
            "UIApplication.willEnterForegroundNotification)) { _ in\n            scheduleNotificationPermissionRefresh()",
            ".onDisappear {\n            cancelNotificationPermissionRefresh()"
        ] {
            XCTAssertTrue(wrapperBody.contains(requiredLifecycleCall), "notification lifecycle lost: \(requiredLifecycleCall)")
        }
        for requiredContract in [
            "await refreshNotificationPermission()",
            "IOSNotificationPermissionCoordinator.shared.currentStatus()",
            "if enabled {\n            Task { await enableNotificationPermissionIfNeeded() }",
            "IOSNotificationPermissionCoordinator.shared.requestFromUserGestureIfNeeded()",
            "} else {\n            openAppNotificationSettings()",
            "UIApplication.shared.open(url)"
        ] {
            XCTAssertTrue(viewSource.contains(requiredContract), "notification permission contract lost: \(requiredContract)")
        }
        let meSource = try String(contentsOf: iosRoot.appendingPathComponent("WenDaTong/MeSettingsViews.swift"), encoding: .utf8)
        XCTAssertTrue(meSource.contains("case .notifications:\n                NotificationSettingsView()"))
        // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_END
    }

    func testApp1PushEntitlementsAndBothArchivePathsUseFinalVerifier() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = iosRoot.appendingPathComponent("WenDaTong")
        let projectRoot = iosRoot.appendingPathComponent("WenDaTong.xcodeproj/xcshareddata/xcschemes")
        func plist(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: sourceRoot.appendingPathComponent(name))
            return try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
        }
        XCTAssertNil(try plist("WDTConfiguration/WenDaTongDebug.entitlements")["aps-environment"])
        XCTAssertEqual(try plist("WDTConfiguration/WenDaTongRelease.entitlements")["aps-environment"] as? String, "production")
        for scheme in ["WenDaTong-App1.xcscheme", "WenDaTong.xcscheme"] {
            let source = try String(contentsOf: projectRoot.appendingPathComponent(scheme), encoding: .utf8)
            XCTAssertTrue(source.contains("Verify final APP1 archive"))
            XCTAssertTrue(source.contains("python3"))
            XCTAssertTrue(source.contains("verify_app1_archive.py"))
            XCTAssertFalse(source.contains("verify-app1-archive.sh"))
            XCTAssertTrue(source.contains("Products/Applications/WenDaTong.app"))
        }
        let verifier = try String(
            contentsOf: iosRoot.appendingPathComponent("scripts/verify_app1_archive.py"),
            encoding: .utf8
        )
        for frozenIdentity in [
            "EXPECTED_BUNDLE_ID = \"app.xltest.com\"",
            "A3PN7W63G3",
            "required_text(profile.get(\"Name\"))",
            "EXPECTED_APS_ENVIRONMENT = \"production\"",
            "EXPECTED_ORDINARY_TOPIC = EXPECTED_BUNDLE_ID",
            "EXPECTED_VOIP_TOPIC = f\"{EXPECTED_BUNDLE_ID}.voip\""
        ] {
            XCTAssertTrue(verifier.contains(frozenIdentity))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent("scripts/verify-app1-archive.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent("scripts/test-verify-app1-archive.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent("WenDaTongTests/test_verify_app1_archive.py").path))
    }

    func testEnterpriseCodeUserFacingCopyDoesNotRevealCanonicalLength() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let explicitLength = try NSRegularExpression(
            pattern: #"(?:(?:企业编码|企业码|邀请码)[^"\n]{0,80}(?:[（(]\s*[6６六]|[6６六]\s*位)|(?:[（(]\s*[6６六]|[6６六]\s*位)[^"\n]{0,80}(?:企业编码|企业码|邀请码))"#
        )
        var leaks: [String] = []
        for path in ["WenDaTong", "Sources/IM4Features"] {
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: sourceRoot.appendingPathComponent(path, isDirectory: true),
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            )
            for case let sourceURL as URL in enumerator where sourceURL.pathExtension == "swift" {
                let source = try String(contentsOf: sourceURL, encoding: .utf8)
                for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let text = String(line)
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    if explicitLength.firstMatch(in: text, range: range) != nil {
                        leaks.append("\(sourceURL.lastPathComponent):\(offset + 1)")
                    }
                }
            }
        }
        XCTAssertTrue(leaks.isEmpty, "企业码用户文案不得暴露固定长度：\(leaks.joined(separator: ", "))")
        for path in [
            "Sources/IM4Features/Auth/AuthEnterpriseEntryContent.swift",
            "Sources/IM4Features/Auth/AuthTenantChallengeContent.swift"
        ] {
            let authSource = try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(authSource.contains("请输入企业编码或邀请码"), path)
        }
        // WDT_IOS1_REFACTOR_AUTH_VIEWS_20261109_BEGIN
        let registrationSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("WenDaTong/Features/Auth/AuthFlipView.swift"),
            encoding: .utf8
        )
        // WDT_IOS1_REFACTOR_AUTH_VIEWS_20261109_END
        let settingsSource = try String(
            // WDT_IOS1_REFACTOR_ME_SETTINGS_VIEWS_20261109
            contentsOf: sourceRoot.appendingPathComponent("Sources/IM4Features/Me/EnterpriseSwitcherContent.swift"),
            encoding: .utf8
        )
        let stateSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("WenDaTong/Core/AppSupport/RemoteSync/AppState+RegistrationResolution.swift"), // WDT_IOS1_A17_REAL_PRODUCER_SOURCE_READERS_20261111
            encoding: .utf8
        )
        // WDT_IOS1_REFACTOR_AUTH_VIEWS_20261109
        XCTAssertTrue(registrationSource.contains("选填，企业编码或邀请码"))
        XCTAssertTrue(settingsSource.contains("输入企业编码或邀请码"))
        XCTAssertTrue(stateSource.contains("企业编码或邀请码格式不正确，请检查后重试。"))
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

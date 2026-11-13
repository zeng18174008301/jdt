import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import SwiftUI
import UIKit // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
import XCTest
@testable import WenDaTong

// WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112: Mounted favorites are covered in DomainMessageActionsAndInitialSyncTests.swift.

// WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_BEGIN
extension IdentityPresentationTests {

    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedWorkspaceMembershipAndSelectionRefreshWithoutGlobalPublication() async throws {
        IMAppPolicyLastGoodStore.clearAll()
        defer { IMAppPolicyLastGoodStore.clearAll() }
        let state = try await authRoutingUIState()
        let alpha = enterprisePresentationFixture(id: "alpha", name: "Alpha Workspace")
        let beta = enterprisePresentationFixture(id: "beta", name: "Beta Workspace")
        let added = enterprisePresentationFixture(id: "added", name: "Aardvark Workspace")
        state.setCurrentEnterprise(alpha)
        state.setEnterprises([alpha, beta])
        state.setAuthenticated(true)
        try await withMountedConversationSurface(
            LoginWorkspaceSelectionView().appStateEnvironment(state), settleNanoseconds: 400_000_000
        ) { snapshot in
            let initial = try await snapshot()
            var globalUpdates = 0
            let observation = state.objectWillChange.sink { globalUpdates += 1 }
            defer { observation.cancel() }
            state.setEnterprises([alpha, beta, added])
            XCTAssertEqual(globalUpdates, 0)
            let expanded = try await snapshot()
            XCTAssertNotEqual(expanded, initial)
            state.setEnterprises([alpha, beta])
            let restoredList = try await snapshot()
            XCTAssertEqual(restoredList, initial)
            state.setCurrentEnterprise(beta)
            XCTAssertEqual(globalUpdates, 0)
            let selected = try await snapshot()
            XCTAssertNotEqual(selected, initial)
            state.setCurrentEnterprise(alpha)
            let restoredSelection = try await snapshot()
            XCTAssertEqual(restoredSelection, initial)
        }
        try await withMountedConversationSurface(
            NavigationStackCompat { ConversationListView() }.appStateEnvironment(state), settleNanoseconds: 400_000_000
        ) { snapshot in
            let initial = try await snapshot()
            var globalUpdates = 0
            let observation = state.objectWillChange.sink { globalUpdates += 1 }
            defer { observation.cancel() }
            state.setCurrentEnterprise(enterprisePresentationFixture(id: "alpha", name: "Renamed Workspace"))
            XCTAssertEqual(globalUpdates, 0)
            let renamed = try await snapshot()
            XCTAssertNotEqual(renamed, initial)
            state.setCurrentEnterprise(alpha)
            let restored = try await snapshot()
            XCTAssertEqual(restored, initial)
        }
    }

    @MainActor
    func testMountedGroupCreationReactsToEnterpriseRoleWithoutGlobalPublication() async throws {
        let state = try mountedLocalGroupChat(role: "member", active: false, repairRequired: false, expecting: [.groupSummary]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let member = enterprisePresentationFixture(id: "tenant-ui", name: "Role Workspace")
        let admin = enterprisePresentationFixture(id: "tenant-ui", name: "Role Workspace", role: "admin")
        state.setCurrentEnterprise(member)
        state.storeCancellables.removeAll()
        try await withMountedConversationSurface(
            NavigationStackCompat { GroupListView() }.appStateEnvironment(state), settleNanoseconds: 350_000_000
        ) { snapshot in
            let denied = try await snapshot()
            var globalUpdates = 0
            let observation = state.objectWillChange.sink { globalUpdates += 1 }
            defer { observation.cancel() }
            state.setCurrentEnterprise(admin)
            XCTAssertTrue(state.canCreateGroupChat)
            XCTAssertEqual(globalUpdates, 0)
            let allowed = try await snapshot()
            XCTAssertNotEqual(allowed, denied)
            state.setCurrentEnterprise(member)
            XCTAssertFalse(state.canCreateGroupChat)
            let revoked = try await snapshot()
            XCTAssertEqual(revoked, denied)
        }
    }

    private func enterprisePresentationFixture(id: String, name: String, role: String = "member") -> Enterprise {
        Enterprise(
            id: id, name: name, code: id, role: role, status: "已加入",
            memberCount: 3, isDefault: false, accentHex: 0x5D6BFF, canSwitch: true, enterable: true
        )
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedRootChangesAuthenticationBranchWithoutGlobalPublication() async throws {
        let suite = "mounted-auth-root-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_BEGIN
        let policyKey = "im2.ios.lastGoodAppPolicies.v1"
        let previousPolicy = UserDefaults.standard.data(forKey: policyKey)
        defer { XCTAssertEqual(UserDefaults.standard.data(forKey: policyKey), previousPolicy) }
        let state = try await IMAppPolicyLastGoodStore.$fixtureSuiteName.withValue(suite) {
            try await authRoutingUIState(isolatedDefaults: defaults)
        }
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_END
        let api = try XCTUnwrap(state.api as? IMAPIClient)
        let transport = try XCTUnwrap(api.httpTransport as? FakeHTTPTransport)
        func forcedPolicyRequests() -> Int {
            transport.requests().count { request in
                guard request.httpMethod == "GET", let url = request.url,
                      url.host == "platform.example.test", url.path == "/api/platform/apps/current-policy" else { return false }
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(where: { $0.name == "_ts" }) == true
            }
        }
        let policyRequestsBeforeMount = forcedPolicyRequests()
        state.bootstrapPresentationStore.launch.isShowingLaunchSplash = false
        state.setAuthScreen(.accountLogin)
        var authentication: [Bool] = []
        let observation = state.authenticationPresentationStore.authenticationUpdates.sink { authentication.append($0) }
        defer { observation.cancel() }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousWindow?.makeKey() }
        func tabBar(in view: UIView, window: UIWindow) -> UITabBar? {
            guard !view.isHidden, view.alpha > 0 else { return nil }
            if let bar = view as? UITabBar, bar.items?.isEmpty == false, bar.window === window,
               bar.convert(bar.bounds, to: window).intersects(window.bounds) {
                return bar
            }
            return view.subviews.lazy.compactMap { tabBar(in: $0, window: window) }.first
        }
        try await withMountedConversationSurface(
            // WDT_IOS1_PRODUCTION_ROOT_FIXTURE_20261112
            RootView(mountingNormalContentForTesting: true).appStateEnvironment(state).environment(\.scenePhase, .inactive),
            settleNanoseconds: 1_500_000_000
        ) { snapshot in
            _ = try await snapshot()
            let mountedWindow = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
            XCTAssertFalse(mountedWindow === previousWindow)
            @MainActor func mainShellTabBar() -> UITabBar? {
                tabBar(in: mountedWindow, window: mountedWindow)
            }
            XCTAssertNil(mainShellTabBar())
            XCTAssertGreaterThan(forcedPolicyRequests(), policyRequestsBeforeMount)
            var globalUpdates = 0
            let global = state.objectWillChange.sink { globalUpdates += 1 }
            defer { global.cancel() }
            state.setAuthenticated(true)
            XCTAssertEqual(globalUpdates, 0)
            XCTAssertTrue(state.isAuthenticated)
            _ = try await snapshot()
            XCTAssertTrue(mountedWindow.isKeyWindow)
            let visibleTabBar = mainShellTabBar()
            XCTAssertNotNil(visibleTabBar)
            XCTAssertEqual(visibleTabBar?.items?.count, MainTab.allCases.count)
            let beforeSignOut = globalUpdates
            let policyRequestsBeforeSignOut = forcedPolicyRequests()
            state.setAuthenticated(false)
            XCTAssertEqual(globalUpdates, beforeSignOut)
            XCTAssertFalse(state.isAuthenticated)
            _ = try await snapshot()
            XCTAssertTrue(mountedWindow.isKeyWindow)
            XCTAssertNil(mainShellTabBar())
            XCTAssertGreaterThan(forcedPolicyRequests(), policyRequestsBeforeSignOut)
            XCTAssertEqual(authentication, [false, true, false])
            // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112
            XCTAssertEqual(IMAppPolicyLastGoodStore.usable(appID: state.apiContext.appID, defaults: defaults)?.policy.appID,
                state.apiContext.appID)
        }
    }

    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_END
    @MainActor
    func testMountedAuthRootNavigatesAndNormalizesWithoutGlobalPublication() async throws {
        IMAppPolicyLastGoodStore.clearAll()
        defer { IMAppPolicyLastGoodStore.clearAll() }
        let state = try await authRoutingUIState()
        state.setAuthScreen(.accountLogin)
        var screens: [AuthScreen] = []
        let observation = state.authenticationPresentationStore.screenUpdates.sink { screens.append($0) }
        defer { observation.cancel() }

        try await withMountedConversationSurface(
            AuthRootView(animatesBackground: false).appStateEnvironment(state),
            settleNanoseconds: 1_500_000_000
        ) { snapshot in
            let login = try await snapshot()
            var globalUpdates = 0
            let globalObservation = state.objectWillChange.sink { globalUpdates += 1 }
            defer { globalObservation.cancel() }

            state.setAuthScreen(.forgotPassword)
            XCTAssertEqual(globalUpdates, 0)
            let recovery = try await snapshot()
            XCTAssertNotEqual(recovery, login)

            state.setAuthScreen(.workspaceSelection)
            XCTAssertEqual(globalUpdates, 0)
            let workspaces = try await snapshot()
            XCTAssertNotEqual(workspaces, login)
            XCTAssertNotEqual(workspaces, recovery)

            state.setAuthScreen(.phoneLogin)
            XCTAssertEqual(state.authScreen, .accountLogin)
            XCTAssertEqual(globalUpdates, 0)
            let normalizedLogin = try await snapshot()
            if normalizedLogin != login {
                for (name, data) in [("initial-login", login), ("returned-login", normalizedLogin)] {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            XCTAssertEqual(normalizedLogin, login)
            XCTAssertEqual(screens, [.accountLogin, .forgotPassword, .workspaceSelection, .phoneLogin, .accountLogin])
        }
    }

    @MainActor
    func testMountedAuthFlipConsumesRegistrationRouteAndReturnsToLogin() async throws {
        IMAppPolicyLastGoodStore.clearAll()
        defer { IMAppPolicyLastGoodStore.clearAll() }
        let state = try await authRoutingUIState()
        state.setAuthScreen(.accountLogin)

        try await withMountedConversationSurface(
            AuthFlipView(initialRegister: false, initialMode: .account).appStateEnvironment(state),
            settleNanoseconds: 900_000_000
        ) { snapshot in
            let login = try await snapshot()
            var globalUpdates = 0
            let observation = state.objectWillChange.sink { globalUpdates += 1 }
            defer { observation.cancel() }

            state.setAuthScreen(.accountRegister)
            XCTAssertEqual(state.authScreen, .accountRegister)
            XCTAssertEqual(globalUpdates, 0)
            let registration = try await snapshot()
            XCTAssertNotEqual(registration, login)

            state.setAuthScreen(.accountLogin)
            XCTAssertEqual(globalUpdates, 0)
            let restored = try await snapshot()
            XCTAssertEqual(restored, login)
        }
    }


    // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
    @MainActor
    func testCurrentUserPrivateProfileDoesNotPublishChatAndPreservesIdentityCache() throws {
        let state = directChatUIState(nickname: "Peer", remark: nil)
        let original = state.currentUser
        defer {
            state.suppressCurrentUserIdentityPersistence = false
            state.setCurrentUser(original)
        }
        var globalUpdates = 0
        var chatUsers: [IMUser] = []
        let global = state.objectWillChange.sink { globalUpdates += 1 }
        let chat = state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.display)
            .sink { chatUsers.append($0) }
        defer { global.cancel(); chat.cancel() }
        XCTAssertTrue(state.objectWillChange === state.objectWillChange)
        let privateProfile = currentUserObservationFixture(original, phone: "13800138000", phoneVerified: true)
        state.setCurrentUser(privateProfile)
        XCTAssertEqual(state.currentUser.phone, "13800138000")
        XCTAssertTrue(state.currentUser.phoneVerified)
        XCTAssertEqual(chatUsers, [original])
        let renamed = currentUserObservationFixture(privateProfile, name: "Updated Self")
        state.setCurrentUser(renamed)
        XCTAssertEqual(chatUsers, [original, renamed])
        let cached = try XCTUnwrap(IMCurrentUserIdentityCache.load(context: state.apiContext))
        XCTAssertEqual(cached.makeUser(fallbackEnterprise: "", fallbackSeed: 1).name, renamed.name)
        state.suppressCurrentUserIdentityPersistence = true
        state.setCurrentUser(original)
        let retained = try XCTUnwrap(IMCurrentUserIdentityCache.load(context: state.apiContext))
        XCTAssertEqual(retained.makeUser(fallbackEnterprise: "", fallbackSeed: 1).name, renamed.name)
        XCTAssertEqual(globalUpdates, 0)
    }

    @MainActor
    func testMountedMeAndAvatarRefreshCurrentUserWithoutGlobalPublication() async throws {
        // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111_BEGIN
        // Keep the real on-appear policy refresh on the empty transport, with its own cache key.
        let appID = try XCTUnwrap(
            IMAPIContext.allowsRuntimeAppIDOverride ? "me-avatar-snapshot-\(UUID().uuidString)" : nil,
            "Snapshot policy requires an isolated Debug app ID"
        )
        var context = remarkContractContext(tenantID: "tenant-ui", imUID: "viewer-ui")
        context.appID = appID
        // WDT_IOS1_STAGE0_SNAPSHOT_PERSISTENCE_ISOLATION_20261111_BEGIN
        let defaults = try XCTUnwrap(UserDefaults(suiteName: appID))
        let persistenceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(appID, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: appID)
            try? FileManager.default.removeItem(at: persistenceRoot)
        }
        // Me starts policy/invite requests on appearance. Resolve them through a
        // controlled transport so unrelated loading animations cannot race snapshots.
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: FakeHTTPTransport(results: []),
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
            startupContext: context // WDT_IOS1_STAGE0_SNAPSHOT_API_STARTUP_CONTEXT_20261111
        )
        let state = AppState(
            api: client,
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            messageStore: SnapshotCache(directoryURL: persistenceRoot.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: persistenceRoot.appendingPathComponent("support"),
                cachesBase: persistenceRoot.appendingPathComponent("caches")
            ),
            biometricDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: RecordingRememberedLoginPreferenceStore(),
            apiContextOverride: context
        )
        // WDT_IOS1_STAGE0_SNAPSHOT_PERSISTENCE_ISOLATION_20261111_END
        let policy = RemoteAppCurrentPolicy(
            appID: appID,
            platform: "ios",
            status: "active",
            allowWorkspaceSwitch: true,
            allowDefaultTenantJoin: true,
            cacheTTLSeconds: 60
        )
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.suppressCurrentUserIdentityPersistence = true
        // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111_END
        state.setCurrentUser(makeRemarkContractUser(id: "viewer-ui", userID: "VIEWER-UI", name: "查看者"))
        state.storeCancellables.removeAll()
        let original = state.currentUser
        let updated = currentUserObservationFixture(original, name: "Updated Self", avatarSeed: 0xFF5722)
        let surfaces = [AnyView(MeView()), AnyView(AvatarEditSheet())]
        for (index, surface) in surfaces.enumerated() {
            state.setCurrentUser(original)
            try await withMountedConversationSurface(surface.appStateEnvironment(state), settleNanoseconds: 500_000_000) { snapshot in
                // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111_BEGIN
                @MainActor
                func capture() async throws -> Data {
                    let data = try await snapshot()
                    if index == 0 {
                        XCTAssertEqual(state.currentAppPolicy, policy)
                        XCTAssertTrue(state.canOpenEnterpriseSwitcher(for: state.currentEnterprise))
                    }
                    return data
                }

                let initial = try await capture()
                // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111_END
                var globalUpdates = 0
                let observation = state.objectWillChange.sink { globalUpdates += 1 }
                defer { observation.cancel() }
                state.setCurrentUser(updated)
                XCTAssertEqual(globalUpdates, 0)
                let changed = try await capture() // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111
                XCTAssertNotEqual(changed, initial)
                state.setCurrentUser(original)
                let restored = try await capture() // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111
                for (phase, data) in [("initial", initial), ("changed", changed), ("restored", restored)] {
                    let attachment = XCTAttachment(image: try XCTUnwrap(UIImage(data: data)))
                    attachment.name = "CurrentUserSurface-\(index)-\(phase)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(restored, initial)
            }
        }
    }

    @MainActor
    func testMountedPhoneAndRealNameConsumeCurrentUserVerificationWithoutGlobalPublication() async throws {
        let state = try mountedLocalDirectChat(nickname: "Peer", remark: nil, expecting: [.verification]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        state.storeCancellables.removeAll()
        let original = state.currentUser
        let verified = currentUserObservationFixture(
            original, phone: "13800138000", phoneVerified: true, realNameVerified: true, realNameStatus: "verified"
        )
        let surfaces = [AnyView(PhoneBindingFlowView()), AnyView(RealNameVerificationFlowView())]
        for surface in surfaces {
            state.setCurrentUser(original)
            try await withMountedConversationSurface(surface.appStateEnvironment(state), settleNanoseconds: 500_000_000) { snapshot in
                let initial = try await snapshot()
                var globalUpdates = 0
                let observation = state.objectWillChange.sink { globalUpdates += 1 }
                defer { observation.cancel() }
                state.setCurrentUser(verified)
                XCTAssertEqual(globalUpdates, 0)
                let changed = try await snapshot()
                XCTAssertNotEqual(changed, initial)
                state.setCurrentUser(original)
                let restored = try await snapshot()
                XCTAssertEqual(restored, initial)
            }
        }
    }

    @MainActor
    func testMountedChatOwnAvatarConsumesCurrentUserWithoutGlobalPublication() async throws {
        let state = directChatUIState(nickname: "Peer", remark: nil)
        state.storeCancellables.removeAll()
        let original = state.currentUser
        let updated = currentUserObservationFixture(original, name: "Updated Self", avatarSeed: 0xFF5722)
        state.conversationStore.mutateStoredConversation(at: 0) { $0.messages = [ChatMessage(
            id: "own-observation", senderId: original.id, senderName: "",
            text: "Current user avatar observation", time: "12:00", isOutgoing: true, status: .read,
            kind: .text, reactions: [], readBy: [], unreadBy: []
        )] }
        try await withMountedConversationSurface(
            NavigationStackCompat { ChatView(conversationID: "direct-ui-chat") }.appStateEnvironment(state),
            settleNanoseconds: 500_000_000
        ) { snapshot in
            let initial = try await snapshot()
            var globalUpdates = 0
            let observation = state.objectWillChange.sink { globalUpdates += 1 }
            defer { observation.cancel() }
            state.setCurrentUser(updated)
            XCTAssertEqual(globalUpdates, 0)
            let changed = try await snapshot()
            XCTAssertNotEqual(changed, initial)
            state.setCurrentUser(original)
            let restored = try await snapshot()
            XCTAssertEqual(restored, initial)
        }
    }

    private func currentUserObservationFixture(
        _ user: IMUser, name: String? = nil, phone: String? = nil, phoneVerified: Bool? = nil,
        realNameVerified: Bool? = nil, realNameStatus: String? = nil, avatarSeed: UInt? = nil
    ) -> IMUser {
        IMUser(
            id: user.id, userID: user.userID, username: user.username, name: name ?? user.name,
            title: user.title, department: user.department, departmentPathNames: user.departmentPathNames,
            phone: phone ?? user.phone, phoneVerified: phoneVerified ?? user.phoneVerified,
            realNameVerified: realNameVerified ?? user.realNameVerified,
            realNameStatus: realNameStatus ?? user.realNameStatus, email: user.email,
            status: user.status, lastLoginAt: user.lastLoginAt, enterprise: user.enterprise,
            avatarSeed: avatarSeed ?? user.avatarSeed, avatarURL: user.avatarURL,
            avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, badges: user.badges
        )
    }
    // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

    @MainActor
    private func authRoutingUIState(isolatedDefaults: UserDefaults? = nil) async throws -> AppState {
        let result = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","phone_auth_enabled":false,"registration_enabled":true,"enterprise_code_first":false,"cache_ttl_seconds":60}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [result, result, result]) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let context = IMAPIContext(
            platformToken: nil, accountID: nil, tenantID: nil, imUID: nil, imToken: nil,
            platformAuthSession: nil, tenantAuthSession: nil,
            appID: "jianhuitong-ios", deviceID: "auth-routing-" + UUID().uuidString
        )
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: isolatedDefaults.map { _ in [] },
            httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: isolatedDefaults ?? .standard),
            startupContext: isolatedDefaults.map { _ in context }
        )
        let state: AppState
        if let defaults = isolatedDefaults {
            state = AppState(api: client,
                pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
                realtimeClient: PostLoginSilentRealtimeTransport(),
                voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
                biometricDefaults: defaults,
                rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
                rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
                protectedSessionStore: InMemoryProtectedSessionStore(),
                registrationSessionStore: InMemoryProtectedSessionStore(),
                apiContextOverride: context)
        } else {
            state = AppState(api: client, apiContextOverride: context)
        }
        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(loaded)
        XCTAssertFalse(state.isPhoneAuthEnabledForAuthUI)
        XCTAssertTrue(state.isRegistrationEnabledForAuthUI)
        return state
    }
}
// WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_BEGIN
extension IdentityPresentationTests {
    @MainActor
    func testMountedStickerMessageRefreshesResolvedAndLocalAssetWithoutGlobalPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-observation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func imageFile(_ color: UIColor, name: String) throws -> URL {
            let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
            let image = UIGraphicsImageRenderer(bounds: rect).image { renderer in
                renderer.cgContext.setFillColor(color.cgColor)
                renderer.cgContext.fill(rect)
            }
            let url = root.appendingPathComponent(name + ".png")
            try XCTUnwrap(image.pngData()).write(to: url)
            return url
        }
        let remoteFixture = try imageFile(.red, name: "resolved")
        let localFixture = try imageFile(.blue, name: "local")
        let transport = StickerMessageAssetGateTransport()
        defer { transport.close() }
        let state = stickerAssetState(transport: transport)
        let message = stickerAssetMessage()
        var presentations: [StickerMessageAssetStore.Presentation] = []
        let projection = state.stickerMessageAssetStore.updates { state.stickerMessageAssetPresentation(for: message, snapshot: $0) }
            .sink { presentations.append($0) }
        defer { projection.cancel() }
        try await withMountedConversationSurface(
            StickerMessageView(message: message).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white).environment(\.scenePhase, .active)
                .appStateEnvironment(state), settleNanoseconds: 400_000_000
        ) { snapshot in
            let initial = try await snapshot()
            try await waitForStickerAsset { transport.pendingCount == 1 }
            XCTAssertNil(state.resolvedStickerAnimationURL(for: message.stickerSnapshot))
            var globalUpdates = 0
            let observation = state.objectWillChange.sink { globalUpdates += 1 }
            defer { observation.cancel() }
            transport.releaseFirst(stickerAssetResponse(fileName: "resolved.png", thumbnail: remoteFixture.absoluteString))
            try await waitForStickerAsset { state.resolvedStickerAnimationURL(for: message.stickerSnapshot) == remoteFixture }
            let resolved = try await snapshot()
            XCTAssertNotEqual(resolved, initial)
            try await waitForStickerAsset { state.resolvingStickerMessageFileAssetKeys.isEmpty }
            let entry = try XCTUnwrap(state.stickerMessageFileAssets.first)
            var local = entry.value
            local.localThumbnailURL = localFixture.absoluteString
            local.localPreviewURL = localFixture.absoluteString
            local.localDownloadURL = localFixture.absoluteString
            state.stickerMessageAssetStore.upsert(local, for: entry.key)
            let hydrated = try await snapshot()
            XCTAssertNotEqual(hydrated, resolved)
            XCTAssertEqual(state.resolvedStickerAnimationURL(for: message.stickerSnapshot), localFixture)
            XCTAssertEqual(state.resolvedStickerThumbnailURL(for: message.stickerSnapshot), localFixture)
            let matchingUpdateCount = presentations.count
            state.stickerMessageAssetStore.upsert(local, for: "unrelated-file")
            let unrelated = try await snapshot()
            XCTAssertEqual(unrelated, hydrated)
            XCTAssertEqual(presentations.count, matchingUpdateCount)
            XCTAssertEqual(matchingUpdateCount, 3)
            state.stickerMessageAssetStore.reset()
            let cleared = try await snapshot()
            XCTAssertEqual(cleared, initial)
            XCTAssertEqual(globalUpdates, 0)
            for (phase, data) in [("initial", initial), ("resolved", resolved), ("local", hydrated), ("cleared", cleared)] {
                let attachment = XCTAttachment(image: try XCTUnwrap(UIImage(data: data)))
                attachment.name = "StickerMessageAsset-" + phase
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testStickerMessageAssetsRejectDelayedSuccessAndFailureAcrossFourSessionTransitions() async throws {
        for transition in ["tenant", "logout-login", "A-B-A", "reauthentication"] {
            for fails in [false, true] {
                let transport = StickerMessageAssetGateTransport()
                defer { transport.close() }
                let state = stickerAssetState(transport: transport)
                let original = state.apiContext
                let originalGeneration = state.stickerMessageAssetStore.snapshot.generation
                let message = stickerAssetMessage()
                state.resolveStickerMessageAssetsIfNeeded(for: message.stickerSnapshot)
                try await waitForStickerAsset { transport.pendingCount == 1 }
                var next = original
                switch transition {
                case "tenant":
                    next.tenantID = "tenant-next"
                    state.apiContext = next
                case "logout-login":
                    next.imToken = nil
                    state.apiContext = next
                    state.apiContext = original
                case "A-B-A":
                    next.tenantID = "tenant-next"
                    state.apiContext = next
                    state.apiContext = original
                default:
                    next.sessionEpoch = UUID().uuidString
                    state.apiContext = next
                }
                XCTAssertNotEqual(state.stickerMessageAssetStore.snapshot.generation, originalGeneration, transition)
                XCTAssertTrue(state.stickerMessageFileAssets.isEmpty, transition)
                state.resolveStickerMessageAssetsIfNeeded(for: message.stickerSnapshot)
                try await waitForStickerAsset { transport.pendingCount == 2 }
                guard transport.pendingCount == 2 else { continue }
                var globalUpdates = 0
                let observation = state.objectWillChange.sink { globalUpdates += 1 }
                defer { observation.cancel() }
                if fails { transport.failFirst() }
                else { transport.releaseFirst(stickerAssetResponse(fileName: "obsolete.png")) }
                try await waitForStickerAsset { transport.completedCount >= 1 }
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertTrue(state.stickerMessageFileAssets.isEmpty, transition)
                XCTAssertTrue(state.failedStickerMessageFileAssetKeys.isEmpty, transition)
                XCTAssertEqual(state.resolvingStickerMessageFileAssetKeys.count, 1, transition)
                transport.releaseFirst(stickerAssetResponse(fileName: "current.png"))
                try await waitForStickerAsset {
                    state.stickerMessageFileAssets.values.first?.fileName == "current.png"
                        && state.resolvingStickerMessageFileAssetKeys.isEmpty
                }
                XCTAssertEqual(state.stickerMessageFileAssets.count, 1, transition)
                XCTAssertTrue(state.failedStickerMessageFileAssetKeys.isEmpty, transition)
                XCTAssertEqual(globalUpdates, 0, transition)
            }
        }
    }

    @MainActor
    func testStickerMessageAssetsKeepActiveFailureDeduplicatedUntilSessionReset() async throws {
        let transport = StickerMessageAssetGateTransport()
        defer { transport.close() }
        let state = stickerAssetState(transport: transport)
        let message = stickerAssetMessage()
        state.resolveStickerMessageAssetsIfNeeded(for: message.stickerSnapshot)
        state.resolveStickerMessageAssetsIfNeeded(for: message.stickerSnapshot)
        try await waitForStickerAsset { transport.pendingCount == 1 }
        transport.failFirst()
        try await waitForStickerAsset {
            state.failedStickerMessageFileAssetKeys.count == 1 && state.resolvingStickerMessageFileAssetKeys.isEmpty
        }
        state.resolveStickerMessageAssetsIfNeeded(for: message.stickerSnapshot)
        XCTAssertEqual(transport.pendingCount, 0)
        XCTAssertTrue(state.stickerMessageFileAssets.isEmpty)
        var renewed = state.apiContext
        renewed.sessionEpoch = UUID().uuidString
        state.apiContext = renewed
        state.resolveStickerMessageAssetsIfNeeded(for: message.stickerSnapshot)
        try await waitForStickerAsset { transport.pendingCount == 1 }
        transport.releaseFirst(stickerAssetResponse(fileName: "retried.png"))
        try await waitForStickerAsset { state.stickerMessageFileAssets.values.first?.fileName == "retried.png" }
        XCTAssertTrue(state.failedStickerMessageFileAssetKeys.isEmpty)
    }

    @MainActor
    private func stickerAssetState(transport: HTTPTransport) -> AppState {
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(api: client, apiContextOverride: remarkContractContext(tenantID: "sticker-" + UUID().uuidString, imUID: "viewer-ui"))
        state.storeCancellables.removeAll()
        return state
    }

    private func stickerAssetMessage() -> ChatMessage {
        ChatMessage(
            id: "same-sticker-message", senderId: "peer-ui", senderName: "Peer",
            text: StickerMessageSnapshot.fallbackText, time: "12:00", isOutgoing: false, status: .read,
            kind: .text, contentType: "sticker", reactions: [], readBy: [], unreadBy: [],
            stickerSnapshot: StickerMessageSnapshot(stickerID: "sticker-ui", fileID: "file-ui", mimeType: "image/png", width: 128, height: 128)
        )
    }

    private func stickerAssetResponse(fileName: String, thumbnail: String = "") -> HTTPTransportResult {
        let payload: [String: Any] = [
            "ok": true, "data": [
                "file": ["id": "file-ui", "file_name": fileName, "mime_type": "image/png", "size_bytes": 0,
                         "status": "uploaded", "cache_key": "sticker-ui", "version": "v1", "checksum": "", "thumbnail_url": thumbnail],
                "preview_available": false, "download_available": false, "preview_url": "", "download_url": ""
            ]
        ]
        return HTTPTransportResult(data: try! JSONSerialization.data(withJSONObject: payload), isHTTPResponse: true, statusCode: 200)
    }

    @MainActor
    private func waitForStickerAsset(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private final class StickerMessageAssetGateTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<HTTPTransportResult, Error>] = []
    private var completed = 0
    private var closed = false
    var pendingCount: Int { lock.withLock { pending.count } }
    var completedCount: Int { lock.withLock { completed } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.httpMethod == "GET", request.url?.path == "/api/tenant/files/file-ui" else {
            throw URLError(.unsupportedURL)
        }
        defer { lock.withLock { completed += 1 } }
        let result: HTTPTransportResult = try await withCheckedThrowingContinuation { continuation in
            let reject = lock.withLock {
                guard !closed else { return true }
                pending.append(continuation)
                return false
            }
            if reject { continuation.resume(throwing: URLError(.cancelled)) }
        }
        return result.resolvingResponseURL(request.url)
    }

    func releaseFirst(_ result: HTTPTransportResult) {
        guard let continuation = takeFirst() else { XCTFail("No pending sticker request"); return }
        continuation.resume(returning: result)
    }

    func failFirst() {
        guard let continuation = takeFirst() else { XCTFail("No pending sticker request"); return }
        continuation.resume(throwing: URLError(.cancelled))
    }

    private func takeFirst() -> CheckedContinuation<HTTPTransportResult, Error>? {
        lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    }

    func close() {
        let waiting = lock.withLock {
            closed = true
            defer { pending.removeAll() }
            return pending
        }
        waiting.forEach { $0.resume(throwing: URLError(.cancelled)) }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

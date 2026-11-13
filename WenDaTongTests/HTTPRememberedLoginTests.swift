import Foundation
import Combine
import XCTest
import SwiftUI // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
import UIKit // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
    func testMountedLoginUpdatesPhoneEntryWithoutChangingAccountRoute() async throws {
        IMAppPolicyLastGoodStore.clearAll()
        defer { IMAppPolicyLastGoodStore.clearAll() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","phone_auth_enabled":true,"registration_enabled":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makePreloginContext(appID: "jianhuitong-ios"))
        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(loaded)
        XCTAssertTrue(state.isPhoneAuthEnabledForAuthUI)
        state.setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let originalPolicy = state.appPolicyPresentationStore.snapshot

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let host = UIHostingController(
            rootView: AuthFlipView(initialRegister: false, initialMode: .account).appStateEnvironment(state)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func snapshot() async throws -> Data {
            try await Task.sleep(nanoseconds: 350_000_000)
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return try XCTUnwrap(image.pngData())
        }

        let enabled = try await snapshot()
        var globalUpdates = 0
        let observation = state.objectWillChange.sink { globalUpdates += 1 }
        withExtendedLifetime(observation) {
            state.disablePhoneAuthForCurrentApp()
            XCTAssertEqual(state.authScreen, .accountLogin)
            XCTAssertFalse(state.isPhoneAuthEnabledForAuthUI)
            XCTAssertEqual(globalUpdates, 0)
        }
        let disabled = try await snapshot()
        if disabled == enabled {
            let attachment = XCTAttachment(data: enabled, uniformTypeIdentifier: "public.png")
            attachment.name = "mounted-account-login"
            add(attachment)
        }
        XCTAssertNotEqual(disabled, enabled)

        state.appPolicyPresentationStore.snapshot = originalPolicy
        let restored = try await snapshot()
        XCTAssertEqual(restored, enabled)
    }
    // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END

    func testRememberLoginPreferenceDefaultsOnOnlyUntilExplicitUserChoiceAcrossRelaunch() throws {
        let suiteName = "RememberLoginPreference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferenceStore = UserDefaultsRememberedLoginPreferenceStore(defaults: defaults)
        let credentialStore = RecordingRememberedLoginCredentialStore()
        let context = makePreloginContext()

        let firstLaunch = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )
        XCTAssertTrue(firstLaunch.rememberLoginCredentialsEnabledForAuthUI)

        // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110_BEGIN
        var presentedChoices: [Bool] = []
        var globalUpdates = 0
        let observers = [
            firstLaunch.rememberLoginPresentationStore.$isEnabled.sink { presentedChoices.append($0) },
            firstLaunch.objectWillChange.sink { globalUpdates += 1 }
        ]
        withExtendedLifetime(observers) {
            firstLaunch.setRememberLoginCredentialsEnabled(false)
            XCTAssertEqual(presentedChoices, [true, false])
            XCTAssertEqual(globalUpdates, 0)
        }
        // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110_END
        let afterOptOut = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )
        XCTAssertFalse(afterOptOut.rememberLoginCredentialsEnabledForAuthUI)

        afterOptOut.setRememberLoginCredentialsEnabled(true)
        let afterReenable = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )
        XCTAssertTrue(afterReenable.rememberLoginCredentialsEnabledForAuthUI)

        let scope = RememberedLoginCredentialScope(context: context)
        XCTAssertTrue(credentialStore.save(
            RememberedLoginCredentials(
                mode: .account,
                identifier: "security-clear-user",
                password: "SyntheticPass123!"
            ),
            scope: scope
        ))
        afterReenable.clearRememberedLoginCredentials()
        let afterSecurityClear = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )
        XCTAssertTrue(afterSecurityClear.rememberLoginCredentialsEnabledForAuthUI)
        XCTAssertNil(afterSecurityClear.rememberedLoginCredentialsForAuthUI())

        let persistedDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(persistedDomain.isEmpty)
        XCTAssertTrue(persistedDomain.values.allSatisfy { $0 is Bool })

        let legacySuiteName = "RememberLoginPreference.Legacy.\(UUID().uuidString)"
        let legacyDefaults = try XCTUnwrap(UserDefaults(suiteName: legacySuiteName))
        defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }
        let legacyStorageKey = Data("\(scope.appID)\u{0}\(scope.deviceID)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        legacyDefaults.set(
            false,
            forKey: "jianhuitong.login.rememberCredentials.v2.\(legacyStorageKey).enabled"
        )
        let migratedLegacyChoice = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: legacyDefaults),
            apiContextOverride: context
        )
        XCTAssertFalse(migratedLegacyChoice.rememberLoginCredentialsEnabledForAuthUI)
    }

    #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
    func testRememberedLoginCommitOutcomeClassifiesOnlyTheFrozenThreeClasses() {
        XCTAssertEqual(
            RememberedLoginCommitOutcome.classify(
                authorityAccepted: false,
                protectedStoreWriteSucceeded: false,
                immediateReadMatched: false
            ),
            .authorityGuardRejected
        )
        XCTAssertEqual(
            RememberedLoginCommitOutcome.classify(
                authorityAccepted: true,
                protectedStoreWriteSucceeded: false,
                immediateReadMatched: false
            ),
            .protectedStoreWriteFailed
        )
        XCTAssertEqual(
            RememberedLoginCommitOutcome.classify(
                authorityAccepted: true,
                protectedStoreWriteSucceeded: true,
                immediateReadMatched: false
            ),
            .protectedStoreWriteFailed
        )
        XCTAssertEqual(
            RememberedLoginCommitOutcome.classify(
                authorityAccepted: true,
                protectedStoreWriteSucceeded: true,
                immediateReadMatched: true
            ),
            .committedAndImmediatelyReadable
        )
    }

    func testRememberedLoginCommitDiagnosticEmitsOnlyTheFrozenEnumValue() throws {
        let suiteName = "RememberedLoginCommitDiagnostic.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cases: [(RememberedLoginCommitOutcome, String)] = [
            (.authorityGuardRejected, "authority_guard_rejected"),
            (.protectedStoreWriteFailed, "protected_store_write_failed"),
            (.committedAndImmediatelyReadable, "committed_and_immediately_readable")
        ]
        let allowedValues = Set(cases.map(\.1))

        for (outcome, expected) in cases {
            RememberedLoginCommitDiagnostics.record(outcome, defaults: defaults)
            let emitted = try XCTUnwrap(RememberedLoginCommitDiagnostics.latest(defaults: defaults))
            let persisted = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
            XCTAssertEqual(emitted, expected)
            XCTAssertEqual(
                Set(persisted.keys),
                ["post_authoritative_success_remember_commit_class"]
            )
            XCTAssertEqual(
                persisted["post_authoritative_success_remember_commit_class"] as? String,
                expected
            )
            XCTAssertTrue(allowedValues.contains(emitted))
            for forbiddenLabel in ["account=", "password=", "token=", "session=", "key=", "hash="] {
                XCTAssertFalse(emitted.contains(forbiddenLabel))
            }
        }
    }

    func testPostLoginSuccessConsumptionStageDiagnosticIsSingleFieldStrictAndMonotonic() throws {
        let suiteName = "PostLoginSuccessConsumptionStageDiagnostic.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expectedValues = [
            "request_sent",
            "response_decoded",
            "generation_current",
            "complete_entered",
            "tenant_data_applied",
            "enterprise_im_session_rejected",
            "workspace_resolution_entered",
            "workspace_selection_terminal",
            "authenticated_main_terminal",
            "caught_after_request"
        ]

        XCTAssertEqual(PostLoginSuccessConsumptionStage.allCases.map(\.rawValue), expectedValues)
        PostLoginSuccessConsumptionDiagnostics.begin(generation: 41, defaults: defaults)
        XCTAssertEqual(PostLoginSuccessConsumptionDiagnostics.latest(defaults: defaults), "request_sent")
        PostLoginSuccessConsumptionDiagnostics.advance(.tenantDataApplied, generation: 41, defaults: defaults)
        PostLoginSuccessConsumptionDiagnostics.advance(.responseDecoded, generation: 41, defaults: defaults)
        XCTAssertEqual(PostLoginSuccessConsumptionDiagnostics.latest(defaults: defaults), "tenant_data_applied")
        PostLoginSuccessConsumptionDiagnostics.advance(.workspaceSelectionTerminal, generation: 41, defaults: defaults)

        let persisted = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
        XCTAssertEqual(Set(persisted.keys), ["post_login_success_consumption_stage"])
        let emitted = try XCTUnwrap(persisted["post_login_success_consumption_stage"] as? String)
        XCTAssertEqual(emitted, "workspace_selection_terminal")
        XCTAssertTrue(Set(expectedValues).contains(emitted))
        for forbiddenLabel in ["status=", "body=", "error=", "tenant=", "account=", "url=", "token=", "hash=", "identity="] {
            XCTAssertFalse(emitted.contains(forbiddenLabel))
        }

        PostLoginSuccessConsumptionDiagnostics.begin(generation: 42, defaults: defaults)
        XCTAssertEqual(PostLoginSuccessConsumptionDiagnostics.latest(defaults: defaults), "request_sent")
        PostLoginSuccessConsumptionDiagnostics.advance(.caughtAfterRequest, generation: 41, defaults: defaults)
        XCTAssertEqual(PostLoginSuccessConsumptionDiagnostics.latest(defaults: defaults), "request_sent")
    }

    @MainActor
    func testGroupForegroundSessionClearDiagnosticIsValueSafeAndFirstBoundaryStable() throws {
        let suiteName = "GroupForegroundSessionClearDiagnostic.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = IMAPIContext(
            platformToken: "platform-token-redacted",
            accountID: "account-redacted",
            tenantID: "tenant-redacted",
            imUID: "uid-redacted",
            imToken: "im-token-redacted",
            platformAuthSession: nil,
            tenantAuthSession: IMStoredAuthSession(
                sessionID: "tenant-session-redacted",
                refreshToken: "refresh-redacted",
                tokenType: "tenant"
            ),
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "device-redacted"
        )

        XCTAssertEqual(GroupForegroundAuthRefreshRouteClass.resolve(context: context), .platformTenant)
        XCTAssertEqual(GroupForegroundFirstOutcomeClass.classify(IMAPIError.unauthorized("private-value")), .unauthorized)
        XCTAssertEqual(GroupForegroundFirstOutcomeClass.classify(IMAPIError.httpStatus(503, message: "private-value")), .serverError)
        XCTAssertEqual(GroupForegroundFirstOutcomeClass.classify(URLError(.timedOut)), .transport)
        XCTAssertEqual(GroupForegroundSafeCodeClass.classify(IMAPIError.unauthorized("session_expired private-value")), .sessionExpired)
        XCTAssertEqual(GroupForegroundSafeCodeClass.classify(IMAPIError.server("private-value")), .unknown)

        GroupForegroundSessionClearDiagnostics.begin(
            context: context,
            scopeCurrent: true,
            postAuthenticated: true,
            defaults: defaults
        )
        GroupForegroundSessionClearDiagnostics.recordPrimaryOutcome(
            error: IMAPIError.httpStatus(503, message: "private-value"),
            scopeCurrent: true,
            defaults: defaults
        )
        GroupForegroundSessionClearDiagnostics.recordTenantIMFallback(
            attempted: true,
            error: nil,
            scopeCurrent: true,
            defaults: defaults
        )
        GroupForegroundSessionClearDiagnostics.recordClear(
            origin: .groupBundleRemoteError,
            scopeCurrent: true,
            postAuthenticated: false,
            postHasRefreshSession: false,
            postHasIMSession: false,
            defaults: defaults
        )
        GroupForegroundSessionClearDiagnostics.recordClear(
            origin: .authRefreshTerminal,
            scopeCurrent: false,
            postAuthenticated: false,
            postHasRefreshSession: false,
            postHasIMSession: false,
            defaults: defaults
        )

        let persisted = try XCTUnwrap(GroupForegroundSessionClearDiagnostics.latest(defaults: defaults))
        XCTAssertEqual(Set(persisted.keys), [
            "firstClearOrigin",
            "authRefreshRouteClass",
            "firstOutcomeClass",
            "safeCodeClass",
            "tenantIMFallbackAttempted",
            "tenantIMFallbackOutcomeClass",
            "scopeCurrentAtDecision",
            "clearSessionCount",
            "postAuthenticated",
            "postHasRefreshSession",
            "postHasIMSession"
        ])
        XCTAssertEqual(persisted["firstClearOrigin"] as? String, "GROUP_BUNDLE_REMOTE_ERROR")
        XCTAssertEqual(persisted["authRefreshRouteClass"] as? String, "PLATFORM_TENANT")
        XCTAssertEqual(persisted["firstOutcomeClass"] as? String, "5XX")
        XCTAssertEqual(persisted["safeCodeClass"] as? String, "UNKNOWN")
        XCTAssertEqual(persisted["tenantIMFallbackAttempted"] as? Bool, true)
        XCTAssertEqual(persisted["tenantIMFallbackOutcomeClass"] as? String, "2XX")
        XCTAssertEqual(persisted["scopeCurrentAtDecision"] as? Bool, false)
        XCTAssertEqual(persisted["clearSessionCount"] as? Int, 1)
        XCTAssertEqual(persisted["postAuthenticated"] as? Bool, false)
        XCTAssertEqual(persisted["postHasRefreshSession"] as? Bool, false)
        XCTAssertEqual(persisted["postHasIMSession"] as? Bool, false)

        let emitted = String(describing: persisted)
        for forbiddenValue in [
            "platform-token-redacted",
            "account-redacted",
            "tenant-redacted",
            "uid-redacted",
            "im-token-redacted",
            "refresh-redacted",
            "private-value"
        ] {
            XCTAssertFalse(emitted.contains(forbiddenValue))
        }
    }
    #endif

    func testSuccessfulLoginToWorkspaceChooserPersistsRememberedCredentialsAcrossReturnAndLifecycle() async throws {
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
                data: Data(#"{"ok":true,"data":{"account":{"id":"account-1","username":"remember-user","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session","refresh_token":"platform-refresh","expires_at":1785200000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"requires_workspace_selection":true,"can_direct_enter":false,"entry_status":"none","pending_entry_tenant_id":"","workspaces":[{"tenant_id":"tenant-bound","tenant_code":"WXT553222","name":"Bound Tenant","status":"active","join_status":"joined","member_status":"active","member_role":"member","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","app_scoped":true,"workspace_count":1,"enterable_workspace_count":1,"selection_mode":"workspace_selection","empty_reason":"","workspaces":[{"tenant_id":"tenant-bound","name":"Bound Tenant","tenant_code":"WXT553222","status":"active","join_status":"joined","member_status":"active","member_role":"member","account_id":"account-1","can_enter":true,"can_switch":true,"app_id":"jianhuitong-ios","app_tenant_bound":true,"app_binding_status":"bound"}]}}"#.utf8),
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
        state.setRememberLoginCredentialsEnabled(true)

        state.startLoginFlow(identifier: "remember-user", password: "SyntheticPass123!", credentialMode: .account)
        try await waitForCondition { state.authScreen == .workspaceSelection && !state.isAuthLoading }

        XCTAssertEqual(credentialStore.saveCount, 1)
        XCTAssertEqual(
            credentialStore.load(scope: scope),
            RememberedLoginCredentials(mode: .account, identifier: "remember-user", password: "SyntheticPass123!")
        )
        state.cancelLoginWorkspaceSelection()
        XCTAssertEqual(state.authScreen, .accountLogin)
        XCTAssertEqual(state.rememberedLoginCredentialsForAuthUI()?.identifier, "remember-user")

        let relaunched = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )
        XCTAssertTrue(relaunched.rememberLoginCredentialsEnabledForAuthUI)
        XCTAssertEqual(relaunched.rememberedLoginCredentialsForAuthUI()?.mode, .account)
    }

    func testDisablingRememberClearsBoundScopeAndNormalLogoutPreservesReenabledCredentials() {
        let credentialStore = RecordingRememberedLoginCredentialStore()
        let preferenceStore = RecordingRememberedLoginPreferenceStore()
        let firstContext = makeContext()
        let otherContext = IMAPIContext(
            platformToken: nil,
            accountID: nil,
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: firstContext.appID,
            deviceID: "device-other"
        )
        let firstScope = RememberedLoginCredentialScope(context: firstContext)
        let otherScope = RememberedLoginCredentialScope(context: otherContext)
        let credentials = RememberedLoginCredentials(
            mode: .account,
            identifier: "remember-user",
            password: "SyntheticPass123!"
        )
        XCTAssertTrue(credentialStore.save(credentials, scope: firstScope))
        XCTAssertTrue(credentialStore.save(credentials, scope: otherScope))
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: firstContext
        )

        state.setRememberLoginCredentialsEnabled(false)
        XCTAssertNil(credentialStore.load(scope: firstScope))
        XCTAssertNotNil(credentialStore.load(scope: otherScope))

        let switchedAccountScope = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: otherContext
        )
        XCTAssertTrue(switchedAccountScope.rememberLoginCredentialsEnabledForAuthUI)
        XCTAssertEqual(switchedAccountScope.rememberedLoginCredentialsForAuthUI(), credentials)

        state.setRememberLoginCredentialsEnabled(true)
        XCTAssertTrue(credentialStore.save(credentials, scope: firstScope))
        state.reloadRememberedLoginCredentialsForCurrentScope()
        XCTAssertTrue(state.rememberLoginCredentialsEnabledForAuthUI)
        state.logout()
        XCTAssertEqual(credentialStore.load(scope: firstScope), credentials)
        XCTAssertNotNil(credentialStore.load(scope: otherScope))
        XCTAssertTrue(state.rememberLoginCredentialsEnabledForAuthUI)
    }

    func testNormalLogoutPreservesRememberedCredentialsUntilExplicitRememberOff() {
        let credentialStore = RecordingRememberedLoginCredentialStore()
        let preferenceStore = RecordingRememberedLoginPreferenceStore()
        let context = makeContext()
        let scope = RememberedLoginCredentialScope(context: context)
        let credentials = RememberedLoginCredentials(
            mode: .account,
            identifier: "remember-user",
            password: "SyntheticPass123!"
        )
        XCTAssertTrue(credentialStore.save(credentials, scope: scope))
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )
        state.setRememberLoginCredentialsEnabled(true)

        state.logout()

        XCTAssertEqual(credentialStore.load(scope: scope), credentials)
        XCTAssertTrue(state.rememberLoginCredentialsEnabledForAuthUI)
        let returnedToEnterpriseFirst = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )
        XCTAssertTrue(returnedToEnterpriseFirst.rememberLoginCredentialsEnabledForAuthUI)
        XCTAssertEqual(returnedToEnterpriseFirst.rememberedLoginCredentialsForAuthUI(), credentials)
        returnedToEnterpriseFirst.setRememberLoginCredentialsEnabled(false)
        XCTAssertNil(credentialStore.load(scope: scope))
        XCTAssertFalse(returnedToEnterpriseFirst.rememberLoginCredentialsEnabledForAuthUI)
    }

    func testLogoutFencesLateSuccessfulLoginFromPersistingStaleCredentials() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let credentialStore = RecordingRememberedLoginCredentialStore()
        let preferenceStore = RecordingRememberedLoginPreferenceStore()
        let transport = RememberedLoginGateHTTPTransport()
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
        try await waitForCondition { transport.loginRequestCount == 1 }
        state.logout()
        transport.releaseLoginResponse()
        try await waitForCondition { transport.loginResponseCount == 1 }

        XCTAssertEqual(credentialStore.saveCount, 0)
        XCTAssertNil(credentialStore.load(scope: scope))
        XCTAssertTrue(state.rememberLoginCredentialsEnabledForAuthUI)
    }

    func testRememberedCredentialStoreRoundTripsExactScopeAndFailsClosedWhenSecretWriteFails() throws {
        let suiteName = "RememberedCredentialStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secretStore = InMemoryRememberedLoginSecretStore()
        let store = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: secretStore
        )
        let scope = RememberedLoginCredentialScope(
            appID: "jianhuitong-ios",
            deviceID: "credential-device-\(UUID().uuidString)"
        )
        let otherScope = RememberedLoginCredentialScope(
            appID: "jianhuitong-ios",
            deviceID: "credential-device-\(UUID().uuidString)"
        )
        defer {
            store.clear(scope: scope)
            store.clear(scope: otherScope)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let credentials = RememberedLoginCredentials(
            mode: .phone,
            identifier: "13800000000",
            password: "SyntheticPass123!"
        )

        XCTAssertTrue(store.save(credentials, scope: scope))
        XCTAssertEqual(store.load(scope: scope), credentials)
        XCTAssertNil(store.load(scope: otherScope))
        store.clear(scope: scope)
        XCTAssertNil(store.load(scope: scope))

        let failingSecretStore = InMemoryRememberedLoginSecretStore(failWrites: true)
        let failingStore = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: failingSecretStore
        )
        XCTAssertFalse(failingStore.save(credentials, scope: otherScope))
        XCTAssertNil(failingStore.load(scope: otherScope))
        XCTAssertEqual(failingSecretStore.storedValueCount, 0)
    }

    func testRememberedCredentialIdentityNormalizesAccountAndAutofillInvalidatesOnAccountOrModeChange() throws {
        let credentials = RememberedLoginCredentials(
            mode: .account,
            identifier: "  ADMIN11  ",
            password: "SyntheticPass123!"
        )
        let binding = try XCTUnwrap(RememberedLoginAutofillBinding(credentials: credentials))

        XCTAssertTrue(binding.stillMatches(mode: .account, identifier: "admin11"))
        XCTAssertTrue(binding.stillMatches(mode: .account, identifier: " ADMIN11 "))
        XCTAssertFalse(binding.stillMatches(mode: .account, identifier: "other-user"))
        XCTAssertFalse(binding.stillMatches(mode: .phone, identifier: "admin11"))
    }

    func testRememberedCredentialStoreRebindsProtectedItemToNormalizedIdentifierWithoutLeavingOldCredential() throws {
        let suiteName = "RememberedCredentialStore.Rebind.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secretStore = InMemoryRememberedLoginSecretStore()
        let store = KeychainRememberedLoginCredentialStore(defaults: defaults, secretStore: secretStore)
        let scope = RememberedLoginCredentialScope(appID: "jianhuitong-ios", deviceID: "device-rebind")
        defer {
            store.clear(scope: scope)
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(
            store.save(
                RememberedLoginCredentials(
                    mode: .account,
                    identifier: " FirstUser ",
                    password: "SyntheticFirst123!"
                ),
                scope: scope
            )
        )
        XCTAssertEqual(store.load(scope: scope)?.identifier, "firstuser")
        XCTAssertEqual(secretStore.storedValueCount, 2)

        XCTAssertTrue(
            store.save(
                RememberedLoginCredentials(
                    mode: .account,
                    identifier: "SecondUser",
                    password: "SyntheticSecond123!"
                ),
                scope: scope
            )
        )
        XCTAssertEqual(store.load(scope: scope)?.identifier, "seconduser")
        XCTAssertEqual(secretStore.storedValueCount, 2)
        let relaunchedStore = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: secretStore
        )
        XCTAssertEqual(relaunchedStore.load(scope: scope)?.identifier, "seconduser")
    }

    func testRememberedCredentialStoreFailedRebindDoesNotKeepEitherCredentialReachable() throws {
        let suiteName = "RememberedCredentialStore.FailedRebind.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secretStore = InMemoryRememberedLoginSecretStore()
        let store = KeychainRememberedLoginCredentialStore(defaults: defaults, secretStore: secretStore)
        let scope = RememberedLoginCredentialScope(appID: "jianhuitong-ios", deviceID: "device-failed-rebind")
        defer {
            store.clear(scope: scope)
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(
            store.save(
                RememberedLoginCredentials(
                    mode: .account,
                    identifier: "first-user",
                    password: "SyntheticFirst123!"
                ),
                scope: scope
            )
        )
        secretStore.failNextWrite(afterSuccessfulWrites: 2)
        XCTAssertFalse(
            store.save(
                RememberedLoginCredentials(
                    mode: .account,
                    identifier: "second-user",
                    password: "SyntheticSecond123!"
                ),
                scope: scope
            )
        )
        XCTAssertNil(store.load(scope: scope))
        let relaunchedStore = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: secretStore
        )
        XCTAssertNil(relaunchedStore.load(scope: scope))
    }

    func testRememberedCredentialStoreIndexWriteAndCleanupDeleteFailureKeepsScopeBlockedAcrossRelaunch() throws {
        let suiteName = "RememberedCredentialStore.IndexCleanupFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secretStore = InMemoryRememberedLoginSecretStore()
        let store = KeychainRememberedLoginCredentialStore(defaults: defaults, secretStore: secretStore)
        let scope = RememberedLoginCredentialScope(appID: "jianhuitong-ios", deviceID: "device-index-cleanup")
        defer {
            KeychainRememberedLoginCredentialStore(
                defaults: defaults,
                secretStore: secretStore
            ).clear(scope: scope)
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(
            store.save(
                RememberedLoginCredentials(
                    mode: .account,
                    identifier: "first-user",
                    password: "SyntheticFirst123!"
                ),
                scope: scope
            )
        )
        secretStore.failNextWrite(afterSuccessfulWrites: 2)
        secretStore.failNextDelete(afterSuccessfulDeletes: 1)

        XCTAssertFalse(
            store.save(
                RememberedLoginCredentials(
                    mode: .account,
                    identifier: "second-user",
                    password: "SyntheticSecond123!"
                ),
                scope: scope
            )
        )
        XCTAssertNil(store.load(scope: scope))

        let relaunchedStore = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: secretStore
        )
        XCTAssertNil(relaunchedStore.load(scope: scope))
        relaunchedStore.clear(scope: scope)
        XCTAssertNil(relaunchedStore.load(scope: scope))
        XCTAssertEqual(secretStore.storedValueCount, 0)
    }

    func testRememberedCredentialStoreClearDeleteFailureRemainsBlockedUntilRelaunchedCleanupCompletes() throws {
        let suiteName = "RememberedCredentialStore.ClearDeleteFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secretStore = InMemoryRememberedLoginSecretStore()
        let store = KeychainRememberedLoginCredentialStore(defaults: defaults, secretStore: secretStore)
        let scope = RememberedLoginCredentialScope(appID: "jianhuitong-ios", deviceID: "device-clear-failure")
        defer {
            KeychainRememberedLoginCredentialStore(
                defaults: defaults,
                secretStore: secretStore
            ).clear(scope: scope)
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(
            store.save(
                RememberedLoginCredentials(
                    mode: .account,
                    identifier: "clear-user",
                    password: "SyntheticClear123!"
                ),
                scope: scope
            )
        )
        secretStore.failNextDelete()
        store.clear(scope: scope)
        XCTAssertNil(store.load(scope: scope))

        let relaunchedStore = KeychainRememberedLoginCredentialStore(
            defaults: defaults,
            secretStore: secretStore
        )
        XCTAssertNil(relaunchedStore.load(scope: scope))
        relaunchedStore.clear(scope: scope)
        XCTAssertNil(relaunchedStore.load(scope: scope))
        XCTAssertEqual(secretStore.storedValueCount, 0)
    }

    func testSystemRememberedLoginSecretStoreRoundTripsThisDeviceOnlyKeychainData() throws {
        let store = SystemRememberedLoginSecretStore()
        let service = "jianhuitong.ios.tests.remembered-credentials.\(UUID().uuidString)"
        let account = "scope-\(UUID().uuidString)"
        let protectedPayload = Data("synthetic-protected-value-\(UUID().uuidString)".utf8)
        defer { _ = store.delete(service: service, account: account) }

        XCTAssertTrue(
            store.set(protectedPayload, service: service, account: account),
            "The signed test host must retain protected Keychain write authority"
        )
        XCTAssertEqual(store.data(service: service, account: account), protectedPayload)
        XCTAssertTrue(store.delete(service: service, account: account))
        XCTAssertNil(store.data(service: service, account: account))
    }
}

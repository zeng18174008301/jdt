import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func testCurrentUserIdentityCacheRestoresUsernameAndClearsByScope() throws {
        let suiteName = "BlueStoneIMTests.identity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "im-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-main",
            deviceID: "device-1"
        )
        let user = IMUser(
            id: "im-1",
            userID: "user-1",
            username: " admin1 ",
            name: "赵悦",
            title: "",
            department: "",
            phone: "",
            email: "account-1",
            status: "在线",
            enterprise: "Local Tenant",
            avatarSeed: 42,
            avatarURL: "https://example.test/avatar.png",
            badges: []
        )

        let authorityScope = CurrentProfileAuthorityScope(
            tenantID: "tenant-1",
            actorIMUID: "im-1",
            appID: "ios-main"
        )!
        let authorityCheckpoint = CurrentProfileAuthorityCheckpoint(
            scope: authorityScope,
            userRevision: 8,
            identityGeneration: 13,
            nickname: "赵悦",
            avatar: "https://example.test/avatar.png"
        )

        IMCurrentUserIdentityCache.save(
            user,
            context: context,
            profileAuthorityCheckpoint: authorityCheckpoint,
            defaults: defaults
        )
        let stored = try XCTUnwrap(IMCurrentUserIdentityCache.load(context: context, defaults: defaults))
        let restored = stored.makeUser(fallbackEnterprise: "Fallback Tenant", fallbackSeed: 1)

        XCTAssertEqual(restored.username, "admin1")
        XCTAssertEqual(restored.name, "赵悦")
        XCTAssertEqual(restored.enterprise, "Local Tenant")
        XCTAssertEqual(restored.avatarSeed, 42)
        XCTAssertEqual(stored.authorityCheckpoint, authorityCheckpoint)

        let otherAppContext = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "im-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-app2",
            deviceID: "device-1"
        )
        XCTAssertNil(IMCurrentUserIdentityCache.load(context: otherAppContext, defaults: defaults))

        IMCurrentUserIdentityCache.clear(context: context, defaults: defaults)
        XCTAssertNil(IMCurrentUserIdentityCache.load(context: context, defaults: defaults))
    }

    func testAppStateRefreshCurrentEnterpriseProfileAppliesRenamedTenantAndLogo() async throws {
        let transport = EnterpriseProfileRefreshHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        let oldEnterprise = Enterprise(
            id: "tenant-1",
            name: "旧企业",
            code: "WXT000001",
            role: "成员",
            status: "正常",
            memberCount: 0,
            isDefault: true,
            accentHex: 0x5D6BFF,
            logoURL: "https://tenant.example.test/api/tenant/avatar/logo-v1.png",
            logoStatus: "ready",
            logoVersion: "logo-v1",
            logoUpdatedAt: "2026-06-26T10:00:00Z",
            logoCacheKey: "logo-v1"
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentEnterprise(oldEnterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setEnterprises([oldEnterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setCurrentUser(IMUser(
            id: "uid-1",
            userID: "account-1",
            username: "admin1",
            name: "赵悦",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "旧企业",
            avatarSeed: 0x5D6BFF,
            badges: []
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        let updated = await state.refreshCurrentEnterpriseProfile(silent: false)

        XCTAssertTrue(updated)
        XCTAssertEqual(state.currentEnterprise.name, "后台改名企业")
        XCTAssertEqual(state.currentEnterprise.code, "WXT000001")
        XCTAssertEqual(state.currentEnterprise.logoURL, "https://tenant.example.test/api/tenant/avatar/logo-v2.png")
        XCTAssertEqual(state.currentEnterprise.logoCacheKey, "logo-v2")
        XCTAssertEqual(state.currentUser.enterprise, "后台改名企业")
        let requestPaths = transport.requestPaths()
        XCTAssertTrue(requestPaths.contains("/api/tenant/profile"))
        XCTAssertTrue(requestPaths.contains("/api/tenant/workspaces"))
    }

    func testAppStateRefreshCurrentEnterpriseProfileUsesTenantContextRoleAuthorityForInternalGroupCreation() async throws {
        let transport = EnterpriseProfileRefreshHTTPTransport(tenantContextRole: "internal")
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        let staleWorkspaceEnterprise = Enterprise(
            id: "tenant-1",
            name: "旧企业",
            code: "WXT000001",
            role: "member",
            status: "normal",
            memberCount: 0,
            isDefault: true,
            accentHex: 0x5D6BFF
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentEnterprise(staleWorkspaceEnterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setEnterprises([staleWorkspaceEnterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        XCTAssertFalse(state.canCreateGroupChat)
        let firstRefresh = await state.refreshCurrentEnterpriseProfile(silent: false)
        XCTAssertTrue(firstRefresh)
        XCTAssertEqual(state.currentEnterprise.role, "internal")
        XCTAssertTrue(state.canCreateGroupChat)

        // A later workspace refresh still reports the stale member role. The current
        // tenant-context authority must remain stable and prevent the action from
        // disappearing again.
        let secondRefresh = await state.refreshCurrentEnterpriseProfile(silent: false)
        XCTAssertTrue(secondRefresh)
        XCTAssertEqual(state.currentEnterprise.role, "internal")
        XCTAssertTrue(state.canCreateGroupChat)
        XCTAssertEqual(state.enterprises.first(where: { $0.id == "tenant-1" })?.role, "internal")
        XCTAssertEqual(transport.requestPaths().filter { $0 == "/api/tenant/context" }.count, 2)
    }

    func testAppStateProjectsAuthoritativeMultiDeviceBooleanWithoutInventingNumericLimit() async throws {
        let cases: [(String, String)] = [
            (#"{"multi_device_enabled":false,"authoritative":true,"contract_version":1}"#, "1 台设备"),
            (#"{"multi_device_enabled":true,"authoritative":true,"contract_version":1}"#, "允许多设备")
        ]

        for (devicePolicyJSON, expectedText) in cases {
            let transport = EnterpriseProfileRefreshHTTPTransport(
                tenantContextRole: "member",
                tenantContextDevicePolicyJSON: devicePolicyJSON
            )
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let context = IMAPIContext(
                platformToken: "platform-token",
                accountID: "account-1",
                tenantID: "tenant-1",
                imUID: "uid-1",
                imToken: "im-token",
                platformAuthSession: nil,
                tenantAuthSession: nil,
                appID: IMAPIContext.canonicalIOSAppID,
                deviceID: "unit-test-device"
            )
            let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
            let existingDevices = [
                DeviceSession(
                    id: "existing-device",
                    name: "iPhone",
                    platform: "ios",
                    lastSeen: "刚刚",
                    status: "可信设备",
                    isBound: true,
                    isBlocked: false
                )
            ]
            state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            state.deviceSessions = existingDevices

            let refreshed = await state.refreshCurrentEnterpriseProfile(silent: false)
            XCTAssertTrue(refreshed)
            XCTAssertEqual(state.tenantDeviceLimitPresentationText, expectedText)
            XCTAssertEqual(state.deviceSessions, existingDevices)
        }
    }

    func testAppStateKeepsMultiDevicePresentationUnavailableForMalformedAuthority() async throws {
        let malformedPolicies = [
            #"{"multi_device_enabled":true,"contract_version":1}"#,
            #"{"multi_device_enabled":"true","authoritative":true,"contract_version":1}"#,
            #"{"multi_device_enabled":true,"authoritative":false,"contract_version":1}"#
        ]

        for devicePolicyJSON in malformedPolicies {
            let transport = EnterpriseProfileRefreshHTTPTransport(
                tenantContextRole: "member",
                tenantContextDevicePolicyJSON: devicePolicyJSON
            )
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let state = AppState(
                api: api,
                voiceMediaClient: NoopVoiceMediaClient(),
                apiContextOverride: IMAPIContext(
                    platformToken: "platform-token",
                    accountID: "account-1",
                    tenantID: "tenant-1",
                    imUID: "uid-1",
                    imToken: "im-token",
                    platformAuthSession: nil,
                    tenantAuthSession: nil,
                    appID: IMAPIContext.canonicalIOSAppID,
                    deviceID: "unit-test-device"
                )
            )
            state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

            let refreshed = await state.refreshCurrentEnterpriseProfile(silent: false)
            XCTAssertTrue(refreshed)
            XCTAssertEqual(state.tenantDeviceLimitPresentationText, "同步中")
        }
    }

    func testAppStateDropsOlderTenantDevicePolicyResponseWithinSameSession() async throws {
        let gate = FirstReadAckSuspensionGate()
        let transport = TenantDevicePolicyRaceHTTPTransport(firstTenantContextGate: gate)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110_BEGIN
        var deviceLimits: [String] = []
        let observation = state.tenantDevicePolicyPresentationStore.textUpdates.dropFirst().sink { deviceLimits.append($0) }
        defer { observation.cancel() }
        // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110_END

        let olderRefresh = Task { await state.refreshCurrentEnterpriseProfile(silent: false) }
        for _ in 0..<200 {
            if await gate.isWaiting() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard await gate.isWaiting() else {
            await gate.resumeFirst()
            olderRefresh.cancel()
            XCTFail("Timed out waiting for the first tenant-context request")
            return
        }

        let newerRefresh = Task { await state.refreshCurrentEnterpriseProfile(silent: false) }
        for _ in 0..<10 {
            await Task.yield()
        }

        await gate.resumeFirst()
        let newerUpdated = await newerRefresh.value
        let olderUpdated = await olderRefresh.value
        XCTAssertTrue(newerUpdated)
        XCTAssertTrue(olderUpdated)
        XCTAssertEqual(transport.tenantContextRequests(), 1)
        XCTAssertEqual(state.tenantDeviceLimitPresentationText, "1 台设备")
        XCTAssertEqual(deviceLimits, ["1 台设备"]) // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110
    }

    func testAppStateInvalidatesTenantDevicePolicyAcrossSessionChangeAndDropsOldResponse() async throws {
        let gate = FirstReadAckSuspensionGate()
        let transport = TenantDevicePolicyRaceHTTPTransport(firstTenantContextGate: gate)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        var context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token-old",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        let olderRefresh = Task { await state.refreshCurrentEnterpriseProfile(silent: false) }
        for _ in 0..<200 {
            if await gate.isWaiting() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard await gate.isWaiting() else {
            await gate.resumeFirst()
            olderRefresh.cancel()
            XCTFail("Timed out waiting for the first tenant-context request")
            return
        }

        context.imToken = "im-token-new"
        state.overrideAPIContextForTesting(context)
        XCTAssertEqual(state.tenantDeviceLimitPresentationText, "同步中")

        let newerRefresh = await state.refreshCurrentEnterpriseProfile(silent: false)
        XCTAssertTrue(newerRefresh)
        XCTAssertEqual(state.tenantDeviceLimitPresentationText, "允许多设备")

        await gate.resumeFirst()
        _ = await olderRefresh.value
        XCTAssertEqual(transport.tenantContextRequests(), 2)
        XCTAssertEqual(state.tenantDeviceLimitPresentationText, "允许多设备")
    }

    func testAppStateRefreshCurrentEnterpriseProfilePromotesReadyProjectionAdmission() async throws {
        let transport = EnterpriseProfileRefreshHTTPTransport(
            tenantContextRole: "internal",
            workspaceItemsJSON: """
                  {
                    "id": "tenant-1",
                    "tenantCode": "WXT000001",
                    "tenantName": "后台改名企业",
                    "status": "enabled",
                    "join_status": "joined",
                    "member_status": "normal",
                    "member_role": "internal",
                    "can_switch": false,
                    "enterable": false,
                    "current": true,
                    "reason_code": "member_projection_syncing",
                    "reason_text": "enterprise member is syncing",
                    "member_projection_status": "applied",
                    "logo_url": "/api/tenant/avatar/logo-v1.png",
                    "logo_status": "ready",
                    "logo_cache_key": "logo-v1"
                  }
            """
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        var staleWorkspaceEnterprise = Enterprise(
            id: "tenant-1",
            name: "旧企业",
            code: "WXT000001",
            role: "member",
            status: "normal",
            memberCount: 0,
            isDefault: true,
            accentHex: 0x5D6BFF
        )
        staleWorkspaceEnterprise.canSwitch = false
        staleWorkspaceEnterprise.enterable = false
        staleWorkspaceEnterprise.tenantStatus = "enabled"
        staleWorkspaceEnterprise.memberStatus = "normal"
        staleWorkspaceEnterprise.disabledReason = "member_projection_syncing"
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.setCurrentEnterprise(staleWorkspaceEnterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setEnterprises([staleWorkspaceEnterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        let refreshed = await state.refreshCurrentEnterpriseProfile(silent: false)

        XCTAssertTrue(refreshed)
        let refreshedEnterprise = try XCTUnwrap(state.enterprises.first { $0.id == "tenant-1" })
        XCTAssertEqual(refreshedEnterprise.role, "internal")
        XCTAssertTrue(refreshedEnterprise.canSwitch)
        XCTAssertEqual(refreshedEnterprise.enterable, true)
        XCTAssertTrue(refreshedEnterprise.disabledReason.isEmpty)
        XCTAssertTrue(refreshedEnterprise.isWorkspaceEnterable)
        XCTAssertEqual(state.currentEnterprise.role, "internal")
        XCTAssertTrue(state.currentEnterprise.canSwitch)
        XCTAssertEqual(state.currentEnterprise.enterable, true)
        XCTAssertTrue(state.currentEnterprise.disabledReason.isEmpty)
        XCTAssertTrue(transport.requestPaths().contains("/api/tenant/workspaces"))
    }

    func testAppStatePrepareSearchJumpTargetSyncsAnchorBeforeSeqAndFindsExactMessage() async throws {
        let transport = SearchJumpTargetHTTPTransport(syncItemsJSON: """
        [
          {
            "message_id": "msg-42",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 42,
            "from_uid": "uid-2",
            "sender_display_name": "测试用户",
            "content_type": "text",
            "payload": {"text":"锚点消息"},
            "status": "normal",
            "created_at": "2026-06-27T10:00:00Z"
          }
        ]
        """)
        let state = AppState(
            api: makeSearchJumpAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.conversationStore.commitConversationSnapshots([
            makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 42, lastReadSeq: 0)
        ])

        let resolved = await state.prepareSearchJumpTarget(
            RemoteTenantSearchJumpTarget(
                kind: "message",
                channelID: "group-1",
                channelType: "group",
                channelSeq: 42,
                messageID: "msg-42"
            ),
            conversationID: "group-1"
        )

        XCTAssertEqual(resolved, "msg-42")
        let body = try XCTUnwrap(transport.requestBodies().first)
        XCTAssertEqual(body["after_seq"] as? Int, 0)
        XCTAssertEqual(body["before_seq"] as? Int, 43)
    }

    func testAppStatePrepareSearchJumpTargetHydratesPinnedContextOnlyAnchor() async throws {
        let transport = SearchJumpTargetHTTPTransport(syncItemsJSON: """
        [
          {
            "message_id": "msg-42",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 42,
            "from_uid": "uid-2",
            "sender_display_name": "测试用户",
            "content_type": "text",
            "payload": {"text":"搜索命中消息"},
            "status": "normal",
            "created_at": "2026-06-27T10:00:00Z"
          }
        ]
        """)
        let state = AppState(
            api: makeSearchJumpAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var conversation = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 42, lastReadSeq: 0)
        var contextOnly = makeMessage(id: "msg-42", seq: 42, isPinned: true, text: "旧置顶占位")
        contextOnly.isPinnedContextOnly = true
        conversation.messages = [contextOnly]
        state.conversationStore.commitConversationSnapshots([conversation])

        let resolved = await state.prepareSearchJumpTarget(
            RemoteTenantSearchJumpTarget(
                kind: "message",
                channelID: "group-1",
                channelType: "group",
                channelSeq: 42,
                messageID: "msg-42"
            ),
            conversationID: "group-1"
        )

        XCTAssertEqual(resolved, "msg-42")
        XCTAssertEqual(transport.requestBodies().count, 1)
        XCTAssertFalse(state.conversationStore.conversationMessageSnapshots()[0].messages[0].isPinnedContextOnly)
    }

    func testAppStatePrepareSearchJumpTargetReturnsNilWhenAnchorStillMissing() async throws {
        let transport = SearchJumpTargetHTTPTransport(syncItemsJSON: "[]")
        let state = AppState(
            api: makeSearchJumpAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.conversationStore.commitConversationSnapshots([
            makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 42, lastReadSeq: 0)
        ])

        let resolved = await state.prepareSearchJumpTarget(
            RemoteTenantSearchJumpTarget(
                kind: "message",
                channelID: "group-1",
                channelType: "group",
                channelSeq: 42,
                messageID: "msg-missing"
            ),
            conversationID: "group-1"
        )

        XCTAssertNil(resolved)
        let body = try XCTUnwrap(transport.requestBodies().first)
        XCTAssertEqual(body["after_seq"] as? Int, 0)
        XCTAssertEqual(body["before_seq"] as? Int, 43)
    }

    func testManualOlderHistoryIsDurableWhenLoadTaskFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-history-persistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"message_id":"msg-49","channel_id":"group-history","channel_type":"group","channel_seq":49,"from_uid":"uid-2","sender_display_name":"历史用户","content_type":"text","payload":{"text":"即时落库的旧消息"},"status":"normal","created_at":"2026-08-27T10:00:00Z"}],"has_more_before":true,"total":1}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let context = makeAuthenticatedAPIContext()
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let syncEngine = DefaultSyncEngine()
        _ = syncEngine.beginRemoteSnapshotRefresh()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            messagePersistence: persistence,
            remoteSyncEngine: syncEngine,
            apiContextOverride: context
        )
        var conversation = makeConversation(
            id: "group-history",
            kind: .group,
            unread: 0,
            lastMsgSeq: 149,
            lastReadSeq: 149
        )
        conversation.messages = (50...149).map { sequence in
            makeMessage(id: "msg-\(sequence)", seq: Int64(sequence), text: "当前窗口 \(sequence)")
        }
        var signedAttachment = makeMessage(id: "msg-50", seq: 50, text: "当前窗口 50", kind: .file)
        signedAttachment.attachmentPreviewURL = "https://cdn.example.test/preview?auth_key=secret"
        signedAttachment.attachmentDownloadURL = "https://cdn.example.test/download?signature=secret"
        signedAttachment.attachmentThumbnailURL = "https://cdn.example.test/thumb?token=secret"
        conversation.messages[0] = signedAttachment
        conversation.messageCoveredThroughSeq = 149
        state.conversationStore.commitConversationSnapshots([conversation])

        let viewport = FirstJoinSuspensionGate()
        XCTAssertTrue(state.loadOlderMessagesIfAvailable(conversation.id) {
            await viewport.passOrSuspendFirst()
            return true
        })
        for _ in 0..<200 {
            if await viewport.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let reachedViewportGate = await viewport.isWaiting()
        XCTAssertTrue(reachedViewportGate)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshot(id: conversation.id)?.messages.count, 100)
        await viewport.resumeFirst()
        for _ in 0..<200 {
            let hasOldMessage = state.conversationStore.conversationMessageSnapshots().first?.messages.contains(where: { $0.id == "msg-49" }) == true
            if hasOldMessage && !state.conversationStore.isHistoryLoading(conversationID: conversation.id) {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots().first?.messages.contains(where: { $0.id == "msg-49" }) == true)
        XCTAssertFalse(state.conversationStore.isHistoryLoading(conversationID: conversation.id))

        let loaded = try await persistence.activateAndLoad(
            context: context,
            sessionGeneration: 1,
            conversationLimit: 10,
            messagesPerConversation: 200
        )
        let persisted = try XCTUnwrap(loaded.conversations.first(where: { $0.id == conversation.id }))
        XCTAssertEqual(persisted.messages.count, 101)
        XCTAssertTrue(persisted.messages.contains(where: { $0.id == "msg-49" }))
        let persistedAttachment = try XCTUnwrap(persisted.messages.first(where: { $0.id == "msg-50" }))
        XCTAssertEqual(persistedAttachment.attachmentPreviewURL, "")
        XCTAssertEqual(persistedAttachment.attachmentDownloadURL, "")
        XCTAssertEqual(persistedAttachment.attachmentThumbnailURL, "")
    }

    func testManualOlderHistoryRejectsMalformedRTCCollisionBeforeAdvancingCoverage() async throws {
        for field in ["schema_version", "ended_at"] {
            try await assertManualOlderRTCHistoryPage(malformedField: field)
        }
    }

    func testManualOlderHistoryRejectsMalformedRTCWithAuthorityInAnotherConversation() async throws {
        try await assertManualOlderRTCHistoryPage(malformedField: "schema_version", authorityInOtherConversation: true)
    }

    func testManualOlderHistoryStillAcceptsOrdinaryPageWithoutRTCRecoveryGap() async throws {
        try await assertManualOlderRTCHistoryPage(malformedField: nil)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111_BEGIN
extension DomainStoreTests {
    func testPhase6SearchDropsRetiredLocalHitsAndKeepsSameAuthorityFallback() async throws {
        for change in ["scope", "epoch", "credential-cancel", "credential"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("phase6-search-\(UUID().uuidString)")
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")
            )
            let context = makeAuthenticatedAPIContext(accountID: UUID().uuidString)
            let response = HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"message":{"message_id":"search-remote","channel_id":"scope-search-group","channel_type":"group","channel_seq":2,"from_uid":"uid-2","content_type":"text","payload":{"text":"scopeoracle remote"},"status":"normal","created_at":"2026-08-27T10:00:00Z"},"match_text":"scopeoracle remote"}],"has_more":false}}"#.utf8),
                isHTTPResponse: true, statusCode: 200)
            let transport = FakeHTTPTransport(results: [response])
            let state = AppState(api: makeSearchJumpAPI(transport: transport), voiceMediaClient: NoopVoiceMediaClient(),
                videoMediaClient: NoopVideoMediaClient(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshot")),
                messagePersistence: persistence, protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
            var row = makeConversation(id: "scope-search-group", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
            row.messages = [makeMessage(id: "search-local", senderId: "uid-2", seq: 1, text: "scopeoracle local")]
            let conversationID = row.id
            state.conversationStore.hydrateCachedConversations([row])
            let ticket = try await persistence.ensureTicket(context: context, sessionGeneration: state.localMessageSessionGeneration)
            state.localMessageTicket = ticket
            _ = try await persistence.persist(ticket: ticket, snapshots: [
                LocalMessageConversationSnapshot(conversation: row, channelID: row.id, channelType: "group", currentActorID: "uid-1")
            ], source: .history, revision: 1)
            let before = try await persistence.search(ticket: ticket, query: "scopeoracle", limit: 100)
            XCTAssertEqual(before.map(\.message.model.id), ["search-local"])
            let entered = expectation(description: "search worker is held for \(change)")
            let release = DispatchSemaphore(value: 0)
            let once = DispatchSemaphore(value: 1)
            defer {
                state.realtimeComputeRuntime.probe = nil
                release.signal()
                once.signal()
            }
            state.realtimeComputeRuntime.probe = { phase in
                if case .mapping = phase, once.wait(timeout: .now()) == .success {
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 8), .success)
                }
            }
            let task = Task { @MainActor in
                let hits = await state.searchMessages(in: conversationID, keyword: "scopeoracle")
                return (ids: hits.map(\.messageID), firstSnippet: hits.first?.snippet)
            }
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/im/messages/search" }.count, 1)
            var next = context
            switch change {
            case "scope": next.tenantID = "scope-search-replacement"
            case "epoch": next.sessionEpoch = UUID().uuidString
            default:
                next.imToken = "search-fixture-renewed"
                next.credentialRevision += 1
            }
            state.apiContext = next
            if change == "credential-cancel" { task.cancel() }
            release.signal()
            let hits = await task.value
            switch change {
            case "scope", "epoch":
                XCTAssertTrue(hits.ids.isEmpty, change)
            case "credential-cancel":
                XCTAssertEqual(hits.ids, ["search-local"])
                XCTAssertEqual(hits.firstSnippet, "scopeoracle local")
            default:
                XCTAssertEqual(hits.ids, ["search-remote", "search-local"])
            }
            let remoteInstalled = state.conversationStore.conversationMessageSnapshot(id: conversationID)?
                .messages.contains(where: { $0.id == "search-remote" }) == true
            XCTAssertEqual(remoteInstalled, change == "credential")
        }
    }
}
// WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111_END

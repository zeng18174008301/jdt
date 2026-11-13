@testable import IM4Domain
import IM4Core // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    #if targetEnvironment(simulator)
    func testSimulatorObsoleteTestSelectionFallsBackToProductionEndpoints() throws {
        let suiteName = "im4.ios.simulator-production-endpoints.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("test", forKey: SimulatorAccessEnvironment.modeKey)
        defaults.set("https://app-test.wenxintong-test.com", forKey: "im2.api.platformBase")
        defaults.set("https://shanghu-a.wenxintong-test.com", forKey: "im2.api.tenantBase")
        defaults.set("https://im-a.wenxintong-test.com", forKey: "im2.api.imBase")
        defaults.set("https://app-test.wenxintong-test.com", forKey: "im2.api.bootstrapBase")

        XCTAssertEqual(SimulatorAccessEnvironment.current(defaults: defaults), .production)
        XCTAssertFalse(SimulatorAccessEnvironment.apply(.production, defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: SimulatorAccessEnvironment.modeKey), "production")
        XCTAssertNil(defaults.string(forKey: "im2.api.platformBase"))
        XCTAssertNil(defaults.string(forKey: "im2.api.tenantBase"))
        XCTAssertNil(defaults.string(forKey: "im2.api.imBase"))
        XCTAssertEqual(
            defaults.string(forKey: "im2.api.bootstrapBase"),
            "https://bootstrap.wdatong.com"
        )
    }
    #endif

    func testReleaseProductionRouteBasesPreserveTenantAndIMPaths() async throws {
        let suiteName = "im4.ios.release-route-prefixes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configured = IMAPIClient.configuredAPIBases(defaults: defaults, allowLocalOverride: false)

        // A context-supplied base may carry a prefix when no v2 tenant snapshot is installed.
        var context = makeContext()
        context.tenantAPIBaseURL = "https://api-prefix.example.test/tenant/"
        context.imAPIBaseURL = "https://api-prefix.example.test/im/"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"contract_version":1,"batch_id":"batch-server-1","client_batch_id":"batch-client-1","source_count":1,"target_count":1,"created_count":1,"state":"committed","idempotent_replay":false,"authoritative_source_message_ids":["message-1"],"targets":[{"target_ordinal":0,"channel_id":"friend-1:uid-1","channel_type":"direct","messages":[{"source_ordinal":0,"source_message_id":"message-1","message_id":"created-1"}]}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = IMAPIClient(
            platformBase: configured.platformBase,
            tenantBase: configured.tenantBase,
            imBase: configured.imBase,
            bootstrapBases: [],
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        _ = try await client.listDevices(context: context)
        _ = try await client.forwardBatch(
            context: context,
            command: BatchForwardSubmitCommand(
                request: BatchForwardRequest(
                    clientBatchID: "batch-client-1",
                    sourceChannelID: "direct-source",
                    sourceChannelType: "direct",
                    sourceMessageIDs: ["message-1"],
                    targets: [
                        BatchForwardTargetRequest(channelID: "friend-1:uid-1", channelType: "direct")
                    ],
                    mode: .separate
                ),
                headers: [:]
            )
        )

        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[safe: 0]?.url?.absoluteString, "https://api-prefix.example.test/tenant/api/tenant/devices")
        XCTAssertEqual(requests[safe: 1]?.url?.absoluteString, "https://api-prefix.example.test/im/api/im/messages/forward-batch")
        XCTAssertEqual(client.webSocketURL(context: context)?.absoluteString, "wss://api-prefix.example.test/im/ws")
    }

    func testDebugDefaultUsesCurrentProductionAuthoritiesWhileBootstrapSeedRemainsAvailable() async throws {
        let suiteName = "im3.ios.debug-bootstrap-default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configured = IMAPIClient.configuredAPIBases(defaults: defaults, allowLocalOverride: true)
        let bootstrapBases = IMAPIClient.configuredBootstrapBases(defaults: defaults, allowLocalOverride: true)
        let packagedBases = try XCTUnwrap(Bundle.main.object(
            forInfoDictionaryKey: IMAppBootstrapHostConfigurationLoader.basesInfoKey
        ) as? [String])

        XCTAssertEqual(IMAPIContext.canonicalIOSAppID, "jianhuitong-ios")
        XCTAssertEqual([configured.platformBase, configured.tenantBase, configured.imBase].map(\.absoluteString),
                       Array(repeating: "about:blank", count: 3))
        XCTAssertFalse(packagedBases.isEmpty)
        XCTAssertEqual(bootstrapBases.map(\.absoluteString), packagedBases)

        try await assertUnresolvedCurrentPolicy(
            platformBase: configured.platformBase, tenantBase: configured.tenantBase, imBase: configured.imBase
        )
    }

    func testLocalGroupedCoreRuntimeIsDebugOnlyAndDerivesPlainWebSocket() throws {
        let localTenant = "http://127.0.0.1:18082?debug=true#fragment"
        let localIM = "http://127.0.0.1:18083?debug=true#fragment"

        XCTAssertEqual(
            IMAPIClient.normalizedTenantAPIBaseURL(localTenant, allowLocalOrInsecure: true)?.absoluteString,
            "http://127.0.0.1:18082"
        )
        XCTAssertEqual(
            IMAPIClient.normalizedIMAPIBaseURL(localIM, allowLocalOrInsecure: true)?.absoluteString,
            "http://127.0.0.1:18083"
        )
        XCTAssertNil(IMAPIClient.normalizedTenantAPIBaseURL(localTenant, allowLocalOrInsecure: false))
        XCTAssertNil(IMAPIClient.normalizedIMAPIBaseURL(localIM, allowLocalOrInsecure: false))

        var localContext = makeContext()
        localContext.tenantAPIBaseURL = localTenant
        localContext.imAPIBaseURL = localIM
        let localClient = IMAPIClient(
            platformBase: try XCTUnwrap(URL(string: "http://127.0.0.1:18081")),
            tenantBase: try XCTUnwrap(URL(string: "http://127.0.0.1:18082")),
            imBase: try XCTUnwrap(URL(string: "http://127.0.0.1:18083")),
            httpTransport: FakeHTTPTransport(results: [])
        )
        XCTAssertEqual(localClient.webSocketURL(context: localContext)?.absoluteString, "ws://127.0.0.1:18083/im/ws")

        var releaseContext = makeContext()
        releaseContext.tenantAPIBaseURL = "https://tenant.example.test"
        releaseContext.imAPIBaseURL = "https://im.example.test"
        XCTAssertNotNil(IMAPIClient.normalizedTenantAPIBaseURL(releaseContext.tenantAPIBaseURL, allowLocalOrInsecure: false))
        XCTAssertNotNil(IMAPIClient.normalizedIMAPIBaseURL(releaseContext.imAPIBaseURL, allowLocalOrInsecure: false))
        XCTAssertEqual(
            makeClient(transport: FakeHTTPTransport(results: [])).webSocketURL(context: releaseContext)?.absoluteString,
            "wss://im.example.test/im/ws"
        )
    }

    func testDebugGroupedCoreRoutesCanonicalCurrentPolicyAndKeepsDiagnosticsFalse() async throws {
        IMAppBootstrapLastGoodStore.clearAll()
        let suiteName = "im3.ios.debug-grouped-core.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            IMAppBootstrapLastGoodStore.clearAll()
        }
        let configured = IMAPIClient.configuredAPIBases(defaults: defaults, allowLocalOverride: true)
        let bootstrapBases = IMAPIClient.configuredBootstrapBases(defaults: defaults, allowLocalOverride: true)
        let seed = try XCTUnwrap(bootstrapBases.first)
        let platformRoute = try XCTUnwrap(bootstrapBases.dropFirst().first)
        XCTAssertNotEqual(seed.host, platformRoute.host)
        let appID = IMAPIContext.canonicalIOSAppID
        let transport = FakeHTTPTransport(results: [
            .init(data: try groupedCoreBootstrapResponse(appID: appID, seed: seed, platformRoute: platformRoute),
                  isHTTPResponse: true, statusCode: 200),
            .init(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
                "app_id": appID, "platform": "ios", "status": "enabled", "access_diagnostics_overlay_enabled": false
            ]]), isHTTPResponse: true, statusCode: 200)
        ])
        let client = IMAPIClient(
            platformBase: configured.platformBase,
            tenantBase: configured.tenantBase,
            imBase: configured.imBase,
            bootstrapBases: bootstrapBases,
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        XCTAssertFalse(client.bootstrapResolutionCompleted)
        let policy = try await client.currentAppPolicy(appID: appID)

        XCTAssertFalse(policy.accessDiagnosticsOverlayEnabled)
        XCTAssertTrue(client.bootstrapResolutionCompleted)
        XCTAssertEqual(client.platformBase, platformRoute)
        let requests = transport.requests()
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            seed.absoluteString + "/.well-known/wenxintong-app.json?app_id=" + appID,
            platformRoute.absoluteString + "/api/platform/apps/current-policy?app_id=" + appID
        ])
    }

    func testRegisterDeviceVoIPTokenUsesContractBody() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"id":"device-1","device_id":"ios-codex-admin2","device_type":"ios","app_id":"jht-ios-main","status":"normal","banned_at":"0001-01-01T00:00:00Z"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let device = try await client.registerDevice(
            context: makeContext(),
            registration: .voip(token: "voip-token-redacted", bundleID: "com.jianhuitongqiyetest.app", environment: "sandbox")
        )

        XCTAssertFalse(device.banned)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/devices")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["device_type"] as? String, "ios")
        XCTAssertEqual(body["push_token_type"] as? String, "voip")
        XCTAssertEqual(body["push_token"] as? String, "voip-token-redacted")
        XCTAssertEqual(body["bundle_id"] as? String, "com.jianhuitongqiyetest.app")
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertNil(body["voip_push_token"])
    }

    func testRetireCurrentPushTokenUsesClaimsScopedCASContract() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"retired","slot":"voip","provider":"apns_voip","terminal":false}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let fingerprint = String(repeating: "a", count: 64)

        let response = try await client.retireCurrentPushToken(
            context: makeContext(),
            provider: .apnsVoIP,
            tokenFingerprint: fingerprint
        )

        XCTAssertEqual(response.status, .retired)
        XCTAssertEqual(response.slot, .voip)
        XCTAssertEqual(response.provider, .apnsVoIP)
        XCTAssertFalse(response.terminal)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/devices/current/push-token/retire")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["provider", "token_fingerprint"]))
        XCTAssertEqual(body["provider"] as? String, "apns_voip")
        XCTAssertEqual(body["token_fingerprint"] as? String, fingerprint)
    }

    func testResolveNotificationTargetUsesOnlyAuthenticatedOpaqueReference() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"kind":"conversation","conversation_id":"conversation-opaque","message_id":"message-opaque","channel_seq":123}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let target = try await client.resolveNotificationTarget(
            context: makeContext(),
            targetRef: "target-ref-opaque"
        )

        XCTAssertEqual(target.kind, .conversation)
        XCTAssertEqual(target.conversationID, "conversation-opaque")
        XCTAssertEqual(target.messageID, "message-opaque")
        XCTAssertEqual(target.channelSeq, 123)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/notifications/targets/resolve")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["target_ref"]))
        XCTAssertEqual(body["target_ref"] as? String, "target-ref-opaque")
    }

    func testDisableDeviceUsesAuthenticatedSelfScopedDelete() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"id":"device-1","device_id":"ios-device-1","device_type":"ios","app_id":"jht-ios-main","status":"disabled","banned":false}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        try await client.disableDevice(context: makeContext(), deviceID: "ios-device-1")

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/devices/ios-device-1")
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertNil(request.httpBody)
    }

    func testApplyFriendUsesV2ContractAndDecodesSuppressedOutcome() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"application_id":"application-1","status":"suppressed","outcome":"application_suppressed","relation_status":"history","friend_action":"request","friend_flow":"ordinary_to_internal","directly_established":false,"requires_tenant_review":false,"requires_target_approval":false}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.applyFriend(
            context: makeContext(),
            targetUID: "internal-1",
            message: "你好",
            source: "search_user"
        )

        XCTAssertEqual(result.outcome, "application_suppressed")
        XCTAssertEqual(result.relationStatus, "history")
        XCTAssertEqual(result.friendFlow, "ordinary_to_internal")
        XCTAssertEqual(AppState.friendApplyResolution(result), .terminal)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/friends/apply")
        XCTAssertEqual(request.httpMethod, "POST")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["target_uid"] as? String, "internal-1")
        XCTAssertEqual(body["message"] as? String, "你好")
        XCTAssertEqual(body["source"] as? String, "search_user")
    }

    func testApplyFriendMapsRelationChangedConflictWithoutLeakingBackendMessage() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"code":"friend_relation_changed","message":"internal relation race details"}"#.utf8),
                isHTTPResponse: true,
                statusCode: 409
            )
        ])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.applyFriend(
                context: makeContext(),
                targetUID: "ordinary-1",
                message: "",
                source: "profile"
            )
            XCTFail("Expected friend_relation_changed")
        } catch IMAPIError.conflict(let code, let message) {
            XCTAssertEqual(code, "friend_relation_changed")
            XCTAssertEqual(message, "好友关系已更新，请查看最新状态")
            XCTAssertFalse(message.contains("internal"))
        }
    }

    func testGroupMemberInviteSystemPreviewUsesServerBatchText() throws {
        let state = AppState(apiContextOverride: makeContext())
        let message = try decodeRemoteMessage("""
        {
          "message_id": "msg-batch-text",
          "channel_id": "group_1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "system",
          "content_type": "system",
          "payload": {
            "event": "group_member_invited",
            "event_type": "group_member_invited",
            "text": "客服邀请半夏安、韩宁等2人加入群「全员群7」",
            "actor_name": "客服",
            "target_name": "半夏安",
            "target_names": ["半夏安", "韩宁"],
            "target_count": 2,
            "batch": true,
            "group_name": "全员群7"
          },
          "status": "normal"
        }
        """)

        let preview = state.debugMessagePreviewForTesting(message)

        XCTAssertEqual(preview, "客服邀请半夏安、韩宁等2人加入群「全员群7」")
    }

    func testGroupMemberInviteSystemPreviewFormatsBatchTargetsWhenTextMissing() throws {
        let state = AppState(apiContextOverride: makeContext())
        let message = try decodeRemoteMessage("""
        {
          "message_id": "msg-batch-fallback",
          "channel_id": "group_1",
          "channel_type": "group",
          "channel_seq": 2,
          "from_uid": "system",
          "content_type": "system",
          "payload": {
            "event": "group_member_invited",
            "event_type": "group_member_invited",
            "actor_name": "客服",
            "target_name": "半夏安",
            "target_names": ["半夏安", "韩宁"],
            "target_count": 2,
            "batch": true,
            "group_name": "全员群7"
          },
          "status": "normal"
        }
        """)

        let preview = state.debugMessagePreviewForTesting(message)

        XCTAssertEqual(preview, "客服邀请半夏安、韩宁加入群「全员群7」")
        XCTAssertTrue(preview.contains("韩宁"))
        XCTAssertNotEqual(preview, "客服邀请半夏安加入群「全员群7」")
    }

    func testCreateGroupUsesMemberUIDsContractBody() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group":{"group_id":"group-1","name":"全员群"},"members":[{"im_uid":"uid-2","role":"member"},{"im_uid":"uid-3","role":"member"}],"system_messages":[]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 201
            )
        ])
        let client = makeClient(transport: transport)

        _ = try await client.createGroup(context: makeContext(), name: "全员群", memberUIDs: ["uid-2", "uid-3"])

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "全员群")
        XCTAssertEqual(body["member_uids"] as? [String], ["uid-2", "uid-3"])
        XCTAssertNil(body["member_ids"])
    }

    func testListGroupsConsumesEveryStableOffsetPage() async throws { // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_BEGIN
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"group_id":"group-newer","name":"第一页群"}],"limit":500,"offset":0,"has_more":true,"next_offset":500}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"group_id":"group-newer","name":"重复群"},{"group_id":"group-authoritative","name":"后续页群"}],"limit":500,"offset":500,"has_more":false,"next_offset":0}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let (threads, decode) = AsyncStream<Bool>.makeStream()
        let groups = try await SDKHTTPTrace.$current.withValue(
            (sourceCorrelation: 1, delivery: { _, _, _ in }, decode: { _, _, onMain in decode.yield(onMain) },
             linkToPhysicalSource: { _ in })
        ) { try await client.listGroups(context: makeContext(), scope: "all") }
        decode.finish()
        let decodedOnMain = await threads.reduce(into: [Bool]()) { @Sendable values, onMain in values.append(onMain) }
        XCTAssertEqual(decodedOnMain, [false, false])
        XCTAssertEqual(groups.map(\.groupID), ["group-newer", "group-authoritative"])
        XCTAssertEqual(groups.first?.name, "第一页群") // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
        XCTAssertEqual(
            transport.requests().compactMap { request in
                guard let url = request.url else { return nil }
                return url.path + (url.query.map { "?\($0)" } ?? "")
            },
            [
                "/api/tenant/groups?scope=all&limit=500&offset=0",
                "/api/tenant/groups?scope=all&limit=500&offset=500"
            ]
        )
    } // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_END
    func testGroupDirectoryRefreshProjectsExternallyAddedMembership() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"group_id":"group-authoritative","name":"权威群","my_role":"member"}],"limit":500,"offset":0,"has_more":false,"next_offset":0}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            conversationStore: ConversationStore(scope: TestMessageMemoryScope.value),
            apiContextOverride: makeContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        XCTAssertTrue(state.groups.isEmpty)

        let refreshed = await state.refreshGroupDirectory()

        XCTAssertTrue(refreshed)
        XCTAssertEqual(state.groups.map(\.id), ["group-authoritative"])
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots().contains { $0.id == "group-authoritative" })
    }

    func testGroupDirectoryEntryWiresAnAuthoritativeRefresh() throws {
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_BEGIN
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WenDaTong/Features/Contacts/ContactGroupList.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let groupList = try XCTUnwrap(
            source.components(separatedBy: "struct GroupListView: View {").dropFirst().first?
                .components(separatedBy: "private struct GroupCreateEntryRow: View {").first
        )

        XCTAssertTrue(groupList.contains("startGroupDirectoryRefresh()"))
        XCTAssertTrue(groupList.contains(".refreshable {"))
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_END
    }

    func testEveryGroupDirectoryAppearanceStartsANewAuthoritativeRefresh() throws {
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_BEGIN
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WenDaTong/Features/Contacts/ContactGroupList.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let groupList = try XCTUnwrap(
            source.components(separatedBy: "struct GroupListView: View {").dropFirst().first?
                .components(separatedBy: "private struct GroupCreateEntryRow: View {").first
        )
        let onAppear = try XCTUnwrap(
            groupList.components(separatedBy: ".onAppear {").dropFirst().first?
                .components(separatedBy: ".refreshable {").first
        )

        XCTAssertTrue(onAppear.contains("startGroupDirectoryRefresh()"))
        XCTAssertTrue(groupList.contains("private func startGroupDirectoryRefresh()"))
        XCTAssertTrue(groupList.contains("await state.refreshGroupDirectory()"))
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_END
    }

    func testCancelledGroupDirectoryRefreshCannotAffectCurrentSession() async throws { // WDT_IOS1_GROUP_DIRECTORY_CANCEL_SELECTOR_20261111_BEGIN
        let transport = FakeHTTPTransport(results: [
            .init(data: Data(#"{"ok":false,"error":{"code":"unauthorized"}}"#.utf8), isHTTPResponse: true, statusCode: 401)
        ], delayNanoseconds: 1_000_000_000)
        let state = makeIsolatedAuthenticatedHTTPState(transport: transport, context: makeContext())
        let response = try JSONDecoder().decode(APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data)
        let policy = try XCTUnwrap(response.data)
        XCTAssertFalse(policy.requireRealName || policy.requirePhoneVerification)
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        let refresh = Task { await state.refreshGroupDirectory(silent: false) }
        defer { refresh.cancel() }
        let pageWasRequested = {
            let requests = transport.requests()
            guard requests.count == 1, let request = requests.first else { return false }
            return request.httpMethod == "GET" && request.url?.path == "/api/tenant/groups"
                && request.url?.query == "scope=all&limit=500&offset=0"
        }
        try await waitForCondition(pageWasRequested) // WDT_IOS1_GROUP_DIRECTORY_CANCEL_TIMEOUT_20261112
        guard pageWasRequested() else { return XCTFail("Timed out waiting for the group directory page 0 GET") }
        refresh.cancel()
        let refreshSucceeded = await refresh.value
        XCTAssertFalse(refreshSucceeded)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertNil(state.toast)
        XCTAssertEqual(transport.requests().count, 1)
    } // WDT_IOS1_GROUP_DIRECTORY_CANCEL_SELECTOR_20261111_END

    func testCurrentAppPolicyUsesAnonymousPlatformEndpoint() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","allow_workspace_switch":false,"allow_default_tenant_join":true,"require_real_name":true,"require_phone_verification":false,"support_contact_email":"support@example.com","support_contact_configured":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let policy = try await client.currentAppPolicy(appID: "jht-ios-main")

        XCTAssertEqual(policy.appID, "jianhuitong-ios")
        XCTAssertEqual(policy.platform, "ios")
        XCTAssertFalse(policy.allowWorkspaceSwitch)
        XCTAssertTrue(policy.allowDefaultTenantJoin)
        XCTAssertTrue(policy.requireRealName)
        XCTAssertFalse(policy.requirePhoneVerification)
        XCTAssertEqual(policy.supportContactEmail, "support@example.com")
        XCTAssertTrue(policy.supportContactConfigured)
        let request = try XCTUnwrap(
            transport.requests().first { $0.url?.path == "/api/platform/apps/current-policy" }
        )
        XCTAssertEqual(request.url?.absoluteString, "https://platform.example.test/api/platform/apps/current-policy?app_id=jianhuitong-ios")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_BEGIN
    func testEnterpriseResolutionPublishesFormAndBrandingSeparately() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 7)
        let transport = FakeHTTPTransport(results: [
            enterpriseFirstPolicySuccess(),
            try enterpriseContextSuccess(routes: routes, tenantCode: "WXT000001")
        ])
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makePreloginContext()
        )
        let store = state.preAuthEnterpriseContextStore
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        XCTAssertEqual(state.authScreen, .enterpriseCode)

        var formUpdates: [PreAuthEnterpriseContextStore.Form] = []
        var brandingUpdates: [PreAuthEnterpriseContextStore.Branding?] = []
        let observations = [
            store.$form.dropFirst().sink { formUpdates.append($0) },
            store.$branding.dropFirst().sink { brandingUpdates.append($0) }
        ]
        defer { observations.forEach { $0.cancel() } }

        let invalid = await state.resolveEnterpriseContext(enterpriseCode: "  ") // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        XCTAssertFalse(invalid)
        XCTAssertEqual(formUpdates, [.init(errorMessage: RegistrationFlowPolicy.entryCodePrompt)])
        XCTAssertTrue(brandingUpdates.isEmpty)
        XCTAssertEqual(transport.requests().count, 1)

        formUpdates.removeAll()
        let resolved = await state.resolveEnterpriseContext(enterpriseCode: "WXT000001")
        XCTAssertTrue(resolved)
        XCTAssertEqual(formUpdates, [.init(isResolving: true), .init()])
        let context = try XCTUnwrap(state.usablePreAuthEnterpriseContext())
        let branding = try XCTUnwrap(store.branding)
        XCTAssertEqual(branding.name, context.tenantName)
        XCTAssertEqual(branding.logoCacheKey, context.tenantLogoCacheKey)
        XCTAssertEqual(brandingUpdates, [branding])
        XCTAssertEqual(state.authScreen, .accountLogin)

        formUpdates.removeAll()
        state.clearPreAuthEnterpriseContext()
        XCTAssertEqual(state.authScreen, .enterpriseCode)
        XCTAssertNil(state.usablePreAuthEnterpriseContext())
        XCTAssertNil(store.branding)
        XCTAssertEqual(brandingUpdates, [branding, nil])
        XCTAssertTrue(formUpdates.isEmpty)
    }
    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_END

    func testEnterpriseContextResolveUsesAnonymousPlatformContractAndValidatedRuntimeAuthority() async throws {
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-enterprise", revision: 7)
        let transport = FakeHTTPTransport(results: [
            try enterpriseContextSuccess(routes: routes, tenantCode: "WXT000001")
        ])
        let client = makeClient(transport: transport)

        let result = try await client.resolveEnterpriseContext(
            tenantCode: " wxt000001 ",
            appID: "ios-main",
            deviceID: "device-1"
        )

        XCTAssertEqual(result.appID, routes.appID)
        XCTAssertEqual(result.tenantID, "tenant-enterprise")
        XCTAssertEqual(result.tenantCode, "WXT000001")
        XCTAssertEqual(result.entryType, "enterprise_code")
        XCTAssertEqual(result.scheme, "legacy_wxt")
        XCTAssertEqual(result.canonical, "WXT000001")
        XCTAssertEqual(result.tenant?.id, "tenant-enterprise")
        XCTAssertEqual(result.tenant?.tenantCode, "WXT000001")
        XCTAssertEqual(result.tenant?.name, "Resolved Tenant")
        XCTAssertEqual(result.tenant?.logoURL, "https://tenant.example.test/assets/logo.png")
        XCTAssertEqual(result.routeRevision, 7)
        XCTAssertEqual(result.runtimeConfig.runtimeRouteSnapshot, routes)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.example.test/api/platform/auth/enterprise-context/resolve")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["app_id"] as? String, routes.appID)
        XCTAssertEqual(body["device_id"] as? String, "device-1")
        XCTAssertEqual(body["tenant_code"] as? String, "WXT000001")
        XCTAssertEqual(body.count, 3)
    }

    func testEnterpriseContextResolveDecodesCanonicalInviteProjectionAndRateLimitBoundary() async throws {
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-invite", revision: 9)
        let successTransport = FakeHTTPTransport(results: [
            try enterpriseContextSuccess(
                routes: routes,
                tenantCode: "YQM7K9P2A1B",
                canonicalTenantCode: "WXT710001"
            )
        ])
        let successClient = makeClient(transport: successTransport)

        let result = try await successClient.resolveEnterpriseContext(
            tenantCode: "YQM7K9P2A1B",
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        )

        XCTAssertEqual(result.entryType, "member_invite_code")
        XCTAssertEqual(result.scheme, "legacy_yqm")
        XCTAssertEqual(result.canonical, "YQM7K9P2A1B")
        XCTAssertEqual(result.tenantCode, "WXT710001")
        XCTAssertEqual(result.tenant?.tenantCode, "WXT710001")

        let limitedTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"enterprise_context_rate_limited","message":"rate limited","retry_after":1800,"retry_after_seconds":1800}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 429,
                headers: ["Retry-After": "1800"]
            )
        ])
        let limitedClient = makeClient(transport: limitedTransport)
        do {
            _ = try await limitedClient.resolveEnterpriseContext(
                tenantCode: "WXT000001",
                appID: "jianhuitong-ios",
                deviceID: "device-1"
            )
            XCTFail("Expected canonical enterprise-context rate limit")
        } catch IMAPIError.rateLimited(let code, _, let retryAfterSeconds, _) {
            XCTAssertEqual(code, "enterprise_context_rate_limited")
            XCTAssertEqual(retryAfterSeconds, 1_800)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnterpriseContextConsumesUnifiedTypedAuthorityWithoutLegacyPrefixGuessing() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-unified", revision: 10)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try enterpriseContextSuccess(
                routes: routes,
                tenantCode: "AB001234",
                canonicalTenantCode: "AB001234",
                entryType: "enterprise_code",
                scheme: "unified_v1",
                canonicalEntryCode: "AB001234"
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makePreloginContext())

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: " ab001234 ")
        XCTAssertTrue(policyLoaded)
        XCTAssertTrue(contextResolved)
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryCode, "AB001234")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryType, "enterprise_code")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryScheme, .unifiedV1)
    }

    func testEnterpriseContextPreservesPreTypedLegacyResponseCompatibility() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let routes = runtimeRouteSnapshotForHTTPWiring(tenantID: "tenant-legacy", revision: 11)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"enterprise_code_first":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try enterpriseContextSuccess(
                routes: routes,
                tenantCode: "WXT000001",
                entryType: "tenant_code",
                includeAdditiveAuthority: false
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makePreloginContext())

        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        let contextResolved = await state.resolveEnterpriseContext(enterpriseCode: "wxt000001")
        XCTAssertTrue(policyLoaded)
        XCTAssertTrue(contextResolved)
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryType, "enterprise_code")
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryScheme, .legacyWXT)
        XCTAssertEqual(state.preAuthEnterpriseContext?.entryCode, "WXT000001")
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

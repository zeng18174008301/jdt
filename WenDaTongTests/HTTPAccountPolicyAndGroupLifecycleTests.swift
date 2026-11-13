import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
import SwiftUI
import UIKit
@testable import WenDaTong

extension HTTPTransportTests {
    func testLoginLogoAfterTransientPolicyFailurePreservesOnlyExplicitlyEnabledAuthorization() async throws {
        defer {
            clearStoredAPIContext()
            resetSharedAccessDiagnosticsForPolicyTests()
        }
        for overlayEnabled in [true, false] {
            clearStoredAPIContext()
            resetSharedAccessDiagnosticsForPolicyTests()
            let policyJSON = """
            {"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","phone_auth_enabled":true,"enterprise_code_first":false,"allow_workspace_switch":true,"allow_default_tenant_join":true,"access_diagnostics_overlay_enabled":\(overlayEnabled),"cache_ttl_seconds":60}}
            """
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(data: Data(policyJSON.utf8), isHTTPResponse: true, statusCode: 200),
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"platform_unavailable","message":"service unavailable"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 503
                )
            ])
            let state = AppState(
                api: makeClient(transport: transport, bootstrapBases: [URL(string: "https://platform.example.test")!]),
                apiContextOverride: makePreloginContext(appID: "jianhuitong-ios")
            )
            let initiallyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
            XCTAssertTrue(initiallyLoaded)
            state.setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            XCTAssertFalse(AccessDiagnostics.shared.isVisible)
            for _ in 0..<4 {
                state.registerAccessDiagnosticsLogoTap(entry: .loggedOutLoginLogo)
            }

            // Remove only the mock test's fallback so the real auth-UI error
            // path executes, rather than reapplying a last-good policy.
            IMAppPolicyLastGoodStore.clearAll()
            let loadedAfterFailure = await state.refreshCurrentAppPolicyForAuthUI(force: true)
            XCTAssertFalse(loadedAfterFailure)
            XCTAssertNotNil(state.currentAppPolicyErrorMessage)
            XCTAssertFalse(state.isAuthenticated)
            XCTAssertEqual(state.authScreen, .accountLogin)
            XCTAssertFalse(AccessDiagnostics.shared.isVisible)
            for index in 0..<5 {
                state.registerAccessDiagnosticsLogoTap(entry: .loggedOutLoginLogo)
                XCTAssertEqual(AccessDiagnostics.shared.isVisible, overlayEnabled && index == 4)
            }
            registerFiveStateAccessDiagnosticsLogoTaps(state)
            XCTAssertFalse(AccessDiagnostics.shared.isVisible)
            XCTAssertTrue(transport.requests().allSatisfy { $0.url?.path == "/api/platform/apps/current-policy" })
        }
    }

    func testCurrentAppPolicyFetchRemainsHiddenUntilExplicitTruePolicyLoads() async throws {
        clearStoredAPIContext()
        resetSharedAccessDiagnosticsForPolicyTests()
        defer {
            clearStoredAPIContext()
            resetSharedAccessDiagnosticsForPolicyTests()
        }
        var context = makeContext()
        context.appID = "jht-ios-main"
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"access_diagnostics_overlay_enabled":true,"access_diagnostics_copy_enabled":true,"cache_ttl_seconds":60}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ],
            delayNanoseconds: 200_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)

        let loadTask = Task {
            await state.refreshCurrentAppPolicyForAuthUI(force: true)
        }
        await Task.yield()

        XCTAssertFalse(AccessDiagnostics.shared.isVisible)
        XCTAssertFalse(AccessDiagnostics.shared.isCopyEnabled)
        XCTAssertEqual(AccessDiagnostics.shared.snapshot, .initial)

        let loaded = await loadTask.value
        XCTAssertTrue(loaded)
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertFalse(AccessDiagnostics.shared.isVisible)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertFalse(AccessDiagnostics.shared.isCopyEnabled)
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertEqual(AccessDiagnostics.shared.snapshot.bootstrapState, "正在获取")
        XCTAssertEqual(AccessDiagnostics.shared.snapshot.currentPolicyOverlayStatus, "已启用")
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

    func testCurrentAppPolicyAppDisabledClearsLastGoodAndFailsClosed() async throws {
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
        IMAppPolicyLastGoodStore.save(
            RemoteAppCurrentPolicy(
                appID: "jht-ios-main",
                platform: "ios",
                status: "active",
                allowWorkspaceSwitch: true,
                allowDefaultTenantJoin: true,
                supportContactEmail: "support@example.test",
                supportContactConfigured: true,
                accessDiagnosticsOverlayEnabled: true,
                accessDiagnosticsCopyEnabled: true,
                cacheTTLSeconds: 60
            ),
            appID: "jht-ios-main"
        )
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        let scope = AccessDiagnosticsActivationScope(appID: "jht-ios-main", authPhase: .loggedOut)
        AccessDiagnostics.shared.updateScope(scope)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        AccessDiagnostics.shared.applyPolicy(
            AccessDiagnosticsPolicy(appID: "jht-ios-main", overlayEnabled: true, copyEnabled: true)
        )
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        registerFiveSharedAccessDiagnosticsLogoTaps(scope: scope)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        AccessDiagnostics.shared.record(
            .bootstrapSucceeded(
                appID: "jht-ios-main",
                bootstrapHost: "https://platform.example.test",
                fallbackHost: nil,
                source: "test"
            )
        )
        XCTAssertTrue(AccessDiagnostics.shared.isVisible)
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"app_disabled","message":"app disabled"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 403
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)

        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertFalse(loaded)
        XCTAssertNil(IMAppPolicyLastGoodStore.usable(appID: "jht-ios-main"))
        XCTAssertNil(state.currentAppPolicy)
        XCTAssertFalse(AccessDiagnostics.shared.isVisible)
        XCTAssertFalse(AccessDiagnostics.shared.isCopyEnabled)
        XCTAssertEqual(AccessDiagnostics.shared.snapshot, .initial)
    }

    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    func testTenantSearchKeepsHTTPFailureCodeAndRetryAfter() async {
        let cases: [(Int, String, TenantSearchFailure)] = [
            (422, "query_too_short", .shortMessageQuery),
            (503, "search_messages_unavailable", .unavailable),
            (504, "search_timeout", .timeout),
            (410, "search_cursor_expired", .cursorExpired),
            (429, "search_capacity_limited", .busy)
        ]
        for (status, code, expected) in cases {
            let response = HTTPTransportResult(
                data: Data("""
                {"ok":false,"error":{"code":"\(code)","message":"search failure"}}
                """.utf8),
                isHTTPResponse: true,
                statusCode: status,
                headers: status == 429 ? ["Retry-After": "7"] : [:]
            )
            let client = makeClient(transport: FakeHTTPTransport(results: [response]))
            do {
                _ = try await client.tenantSearch(
                    context: makeContext(), scope: "global", query: "合同", types: ["messages"], limit: 20
                )
                XCTFail("Expected search failure for \(code)")
            } catch {
                XCTAssertEqual(TenantSearchFailure(error: error), expected)
                if case let IMAPIError.rateLimited(actualCode, _, delay, _) = error {
                    XCTAssertEqual(actualCode, code)
                    XCTAssertEqual(delay, 7)
                } else {
                    XCTAssertEqual((error as? TenantSearchHTTPFailure)?.code, code)
                    XCTAssertEqual((error as? TenantSearchHTTPFailure)?.status, status)
                }
            }
        }
    }
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END

    // WDT_IOS1_SEARCH_CURSOR_V2_20261113_BEGIN
    func testTenantMessageSearchSendsEmptyV2StarterAndOpaqueContinuationWithoutLegacyCursor() async throws {
        let successfulResult = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"results_by_type":{"messages":{"items":[]}}}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [successfulResult, successfulResult])
        let client = makeClient(transport: transport)
        let context = makeContext()
        let cursors = ["", "opaque.test-token_1"]
        for cursor in cursors {
            _ = try await client.tenantSearch(
                context: context, scope: "conversation", query: "合同", types: ["messages"],
                limit: 20, cursorV2: cursor, channelID: "group-1", channelType: "group"
            )
        }
        XCTAssertEqual(transport.requests().count, 2)
        for (request, expectedCursor) in zip(transport.requests(), cursors) {
            let url = try XCTUnwrap(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "cursor_v2" })?.value, expectedCursor)
            XCTAssertFalse(items.contains(where: { $0.name == "cursor" || $0.name == "messages_cursor" }))
            XCTAssertEqual(items.first(where: { $0.name == "channel_id" })?.value, "group-1")
        }
    }
    // WDT_IOS1_SEARCH_CURSOR_V2_20261113_END

    func testTenantSearchUsesUnifiedTenantSearchEndpoint() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"query":"合同","scope":"conversation","types":["messages","files"],"limit":20,"results_by_type":{},"items":[],"compatibility":{},"analytics":{},"conversation_search":{"hit_channel_seqs":[],"total":0}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let response = try await client.tenantSearch(
            context: makeContext(),
            scope: "conversation",
            query: "合同",
            types: ["messages", "files"],
            limit: 20,
            cursor: "next-1",
            typeCursors: ["messages": "msg-cursor", "files": "file-cursor"],
            channelID: "group-1",
            channelType: "group",
            fromUID: "u_100",
            senderID: "u_100",
            startAt: "2026-06-01T00:00:00Z",
            after: "2026-06-01",
            endAt: "2026-06-27T23:59:59Z",
            before: "2026-06-28",
            fileType: "pdf",
            mimeType: "application/pdf",
            date: "2026-06-27"
        )

        XCTAssertEqual(response.query, "合同")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "tenant.example.test")
        XCTAssertEqual(url.path, "/api/tenant/search")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "scope" })?.value, "conversation")
        XCTAssertEqual(queryItems.first(where: { $0.name == "q" })?.value, "合同")
        XCTAssertEqual(queryItems.first(where: { $0.name == "types" })?.value, "messages,files")
        XCTAssertEqual(queryItems.first(where: { $0.name == "limit" })?.value, "20")
        XCTAssertEqual(queryItems.first(where: { $0.name == "cursor" })?.value, "next-1")
        XCTAssertEqual(queryItems.first(where: { $0.name == "messages_cursor" })?.value, "msg-cursor")
        XCTAssertEqual(queryItems.first(where: { $0.name == "files_cursor" })?.value, "file-cursor")
        XCTAssertEqual(queryItems.first(where: { $0.name == "channel_id" })?.value, "group-1")
        XCTAssertEqual(queryItems.first(where: { $0.name == "channel_type" })?.value, "group")
        XCTAssertEqual(queryItems.first(where: { $0.name == "from_uid" })?.value, "u_100")
        XCTAssertEqual(queryItems.first(where: { $0.name == "sender_id" })?.value, "u_100")
        XCTAssertEqual(queryItems.first(where: { $0.name == "start_at" })?.value, "2026-06-01T00:00:00Z")
        XCTAssertEqual(queryItems.first(where: { $0.name == "after" })?.value, "2026-06-01")
        XCTAssertEqual(queryItems.first(where: { $0.name == "end_at" })?.value, "2026-06-27T23:59:59Z")
        XCTAssertEqual(queryItems.first(where: { $0.name == "before" })?.value, "2026-06-28")
        XCTAssertEqual(queryItems.first(where: { $0.name == "file_type" })?.value, "pdf")
        XCTAssertEqual(queryItems.first(where: { $0.name == "mime_type" })?.value, "application/pdf")
        XCTAssertEqual(queryItems.first(where: { $0.name == "date" })?.value, "2026-06-27")
    }

    func testReactMessageCanSendRemoveAction() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        _ = try await client.reactMessage(context: makeContext(), messageID: "m1", emoji: "👍", action: "remove")

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://im.example.test/api/im/messages/m1/reaction")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["emoji"] as? String, "👍")
        XCTAssertEqual(body["action"] as? String, "remove")
    }

    func testSyncMessagesAnchorRequestUsesBeforeSeqWindow() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.syncMessages(
            context: makeContext(),
            channelID: "group-1",
            channelType: "group",
            afterSeq: 0,
            beforeSeq: 43,
            limit: 50
        )
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.historyVisibleFromSeq, 1)
        XCTAssertFalse(result.historyLimited)

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://im.example.test/api/im/sync")
        XCTAssertEqual(request.httpMethod, "POST")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["channel_id"] as? String, "group-1")
        XCTAssertEqual(body["channel_type"] as? String, "group")
        XCTAssertEqual(body["after_seq"] as? Int, 0)
        XCTAssertEqual(body["before_seq"] as? Int, 43)
        XCTAssertEqual(body["limit"] as? Int, 50)
    }

    func testUpdateGroupHistoryVisibilitySendsSettingsPatchBodyOnly() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group_id":"group-1","settings":{"history_visible":true}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"summary":{"group_id":"group-1","name":"测试群","history_visible_from_seq":1,"history_limited":false},"settings":{"history_visible":true},"my_role":"owner"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let detail = try await client.updateGroupHistoryVisibility(context: makeContext(), groupID: "group-1", historyVisible: true)

        XCTAssertTrue(detail.settings.historyVisible)
        let requests = transport.requests()
        XCTAssertEqual(requests[0].url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/settings")
        XCTAssertEqual(requests[0].httpMethod, "PATCH")
        let bodyData = try XCTUnwrap(requests[0].httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["history_visible"] as? Bool, true)
        XCTAssertNil(body["invite_confirm_required"])
        XCTAssertNil(body["all_muted"])
        XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1")
    }

    func testTenantSearchAnalyticsEventPostsRedactedMetadata() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        try await client.postTenantSearchEvent(
            context: makeContext(),
            event: TenantSearchAnalyticsEvent(
                searchID: "search-1",
                requestID: "req-1",
                eventType: "click",
                scope: "global",
                types: ["messages"],
                resultType: "message",
                resultID: "message:msg-1",
                resultRank: 3,
                queryLength: 8,
                elapsedMS: 12,
                filters: ["from": "u_100", "before": "2026-06-27"]
            )
        )

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/tenant/search/events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["search_id"] as? String, "search-1")
        XCTAssertEqual(body["request_id"] as? String, "req-1")
        XCTAssertEqual(body["event_type"] as? String, "click")
        XCTAssertEqual(body["query_length"] as? Int, 8)
        XCTAssertNil(body["query"])
        XCTAssertNil(body["message_body"])
        XCTAssertNil(body["object_key"])
        XCTAssertNil(body["token"])
    }

    func testRemoveGroupMemberDecodesSearchInvalidations() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"search_invalidations":[{"tenant_id":"tenant-1","event_type":"group_member_removed","reason":"permission_lost","channel_id":"group-1","channel_type":"group","invalidation_key":"group:group-1:member","version":3}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let response = try await client.removeGroupMember(context: makeContext(), groupID: "group-1", userID: "uid-2")

        XCTAssertEqual(response.searchInvalidations.count, 1)
        XCTAssertEqual(response.searchInvalidations.first?.channelID, "group-1")
        XCTAssertEqual(response.searchInvalidations.first?.version, 3)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/members/uid-2")
    }

    func testLeaveGroupUsesContractPathAndReasonBody() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"left":true,"group_id":"group-1","left_at":"2026-07-02T12:00:00Z","conversation_removed":true,"notification_audience":"group_owner_and_admins","notification_count":2,"search_invalidations":[{"tenant_id":"tenant-1","event_type":"removed_conversation","channel_id":"group-1","channel_type":"group","invalidation_key":"group:group-1:leave","version":4}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let response = try await client.leaveGroup(context: makeContext(), groupID: "group-1", reason: "user_request")

        XCTAssertTrue(response.left)
        XCTAssertEqual(response.groupID, "group-1")
        XCTAssertTrue(response.conversationRemoved)
        XCTAssertEqual(response.notificationAudience, "group_owner_and_admins")
        XCTAssertEqual(response.searchInvalidations.first?.channelID, "group-1")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/leave")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["reason"] as? String, "user_request")
        XCTAssertNil(body["confirmation"])
    }

    func testDissolveGroupPreviewAndConfirmUseFrozenContract() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group_id":"group-1","member_count":3,"affected_members":3,"confirmation_required":true,"confirmation_mode":"button","effects":["group_hidden","conversations_removed"]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"dissolved":true,"group_id":"group-1","status":"dissolved","dissolved_at":"2026-07-02T12:10:00Z","removed_members":3,"removed_conversations":3,"notification_count":3,"search_invalidations":[{"tenant_id":"tenant-1","event_type":"removed_conversation","channel_id":"group-1","channel_type":"group","invalidation_key":"group:group-1:dissolved","version":5}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let preview = try await client.previewDissolveGroup(context: makeContext(), groupID: "group-1")
        let result = try await client.dissolveGroup(context: makeContext(), groupID: "group-1", confirmed: true, reason: "owner_request")

        XCTAssertEqual(preview.memberCount, 3)
        XCTAssertEqual(preview.confirmationMode, "button")
        XCTAssertTrue(result.dissolved)
        XCTAssertEqual(result.status, "dissolved")
        let requests = transport.requests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/dissolve/preview")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/dissolve")
        let bodyData = try XCTUnwrap(requests[1].httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["confirmed"] as? Bool, true)
        XCTAssertNil(body["confirmation"])
        XCTAssertEqual(body["reason"] as? String, "owner_request")
    }

    func testGroupDissolvedEventRemovesLocalGroupConversation() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let state = AppState(api: makeClient(transport: FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])), apiContextOverride: makeContext())
        state.groups = [
            GroupInfo(
                id: "group-1",
                name: "测试群",
                notice: "",
                owner: "owner",
                members: [],
                admins: [],
                muted: false,
                allMuted: false,
                memberCount: 3
            )
        ]
        state.conversationStore.hydrateCachedConversations([
            ConversationMessageSnapshot(
                id: "group-1",
                title: "测试群",
                subtitle: "群聊",
                kind: .group,
                lastMessage: "hello",
                time: "刚刚",
                unread: 1,
                isPinned: true,
                isMuted: false,
                memberCount: 3,
                accentHex: 0x5D6BFF,
                participants: [],
                messages: []
            )
        ])

        state.applyGroupLifecycleEventForTesting(event: "group_dissolved", groupID: "group-1")

        XCTAssertFalse(state.groups.contains { $0.id == "group-1" })
        XCTAssertNil(state.conversationStore.conversationMessageSnapshot(id: "group-1"))
        XCTAssertEqual(state.toast, "群聊已解散")
    }

    // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110_BEGIN
    func testRealNameProviderRejectedShowsSubmissionError() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"provider_rejected","message":"实名认证失败，请检查资料正确性！","data":{"reason_code":"provider_rejected","status":"failed","provider_code":"10001"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 422
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())

        let outcome = await state.submitRealNameVerification(realName: "张三", idNumber: "11010519491231002X")

        XCTAssertEqual(outcome, .rejected(message: "实名认证失败，请检查资料正确性！"))
        XCTAssertEqual(state.toast, "实名认证失败，请检查资料正确性！")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/me/real-name/submit")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testRealNameRejectedStatusStaysOnFormWithError() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","account_id":"account-1","phone_bound":true,"phone_masked":"138****0000","real_name_verified":false,"real_name_status":"rejected","real_name_reject_reason":"实名认证失败，请检查资料正确性！"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 201
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setCurrentUser(makeVerificationAuthorityUser(
            id: "uid-1",
            phoneVerified: false,
            realNameVerified: false
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        let outcome = await state.submitRealNameVerification(realName: "张三", idNumber: "11010519491231002X")

        XCTAssertEqual(state.currentUser.realNameStatus, "rejected")
        XCTAssertFalse(state.currentUser.realNameVerified)
        XCTAssertEqual(outcome, .rejected(message: "实名认证失败，请检查资料正确性！"))
        XCTAssertEqual(state.toast, "实名认证失败，请检查资料正确性！")
    }

    func testRealNameValidationReturnsIndependentErrorsWithoutSendingRequests() async {
        let transport = FakeHTTPTransport(results: [])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        let invalidName = await state.submitRealNameVerification(realName: "invalid", idNumber: "")
        let invalidID = await state.submitRealNameVerification(realName: "测试", idNumber: "")
        XCTAssertEqual(invalidName, .rejected(message: "真实姓名格式不正确"))
        XCTAssertEqual(invalidID, .rejected(message: "身份证号码格式不正确"))
        XCTAssertTrue(transport.requests().isEmpty)
    }
    // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110_END

    func testForcedAppPolicyGateBlocksTenantBusinessRequestsAndAllowsVerificationFlow() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        var context = makeContext()
        context.appID = "jht-ios-main"
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jht-ios-main","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"require_real_name":true,"require_phone_verification":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","account_id":"account-1","phone_requirement_satisfied":false,"real_name_requirement_satisfied":false,"phone_masked":"","real_name_status":"unsubmitted"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let state = AppState(api: client, apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(IMUser(
            id: "uid-1",
            username: "admin1",
            name: "admin1",
            title: "",
            department: "",
            phone: "",
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

        do {
            _ = try await client.listDevices(context: context)
            XCTFail("Expected forced auth gate to block listDevices before transport")
        } catch IMAPIError.forcedAuthRequired(let requirement) {
            XCTAssertEqual(requirement, .realName)
        }
        XCTAssertEqual(state.forcedAppPolicyAuthPrompt, .realName)
        let requestsAfterBlockedBusinessCall = transport.requests()
        XCTAssertEqual(requestsAfterBlockedBusinessCall.filter { $0.url?.path == "/api/platform/apps/current-policy" }.count, 1)
        XCTAssertFalse(requestsAfterBlockedBusinessCall.contains { request in
            request.httpMethod == "GET" && request.url?.path == "/api/tenant/devices"
        })

        let status = try await client.verificationStatus(context: context)

        XCTAssertFalse(status.realNameVerified)
        let requestsAfterVerification = transport.requests()
        XCTAssertTrue(requestsAfterVerification.contains { request in
            request.url?.absoluteString == "https://tenant.example.test/api/tenant/me/verification-status"
        })
        XCTAssertFalse(requestsAfterVerification.contains { request in
            request.httpMethod == "GET" && request.url?.path == "/api/tenant/devices"
        })
    }

    func testForcedAppPolicyPromptIsHiddenAndClearedBeforeLogin() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let state = AppState(apiContextOverride: makeContext())
        state.setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.forcedAppPolicyAuthStore.setPrompt(.phone) // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110
        state.forcedAppPolicyAuthStore.setDestination(.realName) // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110

        XCTAssertNil(state.visibleForcedAppPolicyAuthPrompt)
        XCTAssertNil(state.visibleForcedAppPolicyAuthDestination)

        state.updateVisibleForcedAppPolicyAuthPrompt(.phone)
        XCTAssertNil(state.forcedAppPolicyAuthPrompt)
        XCTAssertNil(state.forcedAppPolicyAuthDestination)
    }

    func testForcedAppPolicyPromptWaitsForNestedGroupApprovalSheetDismissal() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            apiContextOverride: makeContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        let presentationLease = state.beginForcedAppPolicyAuthPromptDeferral()
        state.updateVisibleForcedAppPolicyAuthPrompt(.realName)

        XCTAssertEqual(state.forcedAppPolicyAuthPrompt, .realName)
        XCTAssertNil(
            state.visibleForcedAppPolicyAuthPrompt,
            "The root alert must stay queued while the nested approval sheet owns presentation"
        )

        state.endForcedAppPolicyAuthPromptDeferral(presentationLease)

        XCTAssertEqual(
            state.visibleForcedAppPolicyAuthPrompt,
            .realName,
            "The queued alert may become visible only from the stable parent after sheet onDismiss"
        )
    }

    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
    func testForcedAuthStorePublishesQueuedAndVisiblePromptSeparately() {
        let state = AppState(apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let store = state.forcedAppPolicyAuthStore
        var queued: [AppPolicyForcedAuthRequirement?] = []
        var visible: [AppPolicyForcedAuthRequirement?] = []
        var appUpdates = 0
        let subscriptions = [
            store.updates(\.prompt).sink { queued.append($0) },
            store.updates(\.presentation.prompt).sink { visible.append($0) },
            state.objectWillChange.sink { appUpdates += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        let outer = state.beginForcedAppPolicyAuthPromptDeferral()
        let inner = state.beginForcedAppPolicyAuthPromptDeferral()
        state.presentForcedAppPolicyAuthPrompt(.phone)
        XCTAssertEqual(queued, [nil, .phone])
        XCTAssertEqual(visible, [nil])
        state.endForcedAppPolicyAuthPromptDeferral(outer)
        XCTAssertEqual(visible, [nil])
        state.endForcedAppPolicyAuthPromptDeferral(inner)
        XCTAssertEqual(visible, [nil, .phone])
        state.resetForcedAppPolicyAuthState()
        XCTAssertEqual(visible, [nil, .phone, nil])
        XCTAssertEqual(appUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
    func testMountedForcedAuthPresenterWaitsForDeferralBeforeShowingAlert() async throws {
        let state = AppState(api: makeClient(transport: FakeHTTPTransport(results: [])), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let token = state.beginForcedAppPolicyAuthPromptDeferral()
        state.presentForcedAppPolicyAuthPrompt(.phone)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: Color.clear.modifier(ForcedAppPolicyAuthPresentationModifier(state: state)))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertNil(host.presentedViewController)
        state.endForcedAppPolicyAuthPromptDeferral(token)
        try await waitForCondition { host.presentedViewController != nil }
        XCTAssertNotNil(host.presentedViewController)
    }
    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END

    func testForcedAppPolicyPresentationFenceDeduplicatesDestinationTransition() {
        var fence = ForcedAppPolicyAuthPresentationFence()

        XCTAssertTrue(fence.beginDestinationTransition(.realName))
        XCTAssertFalse(fence.canExposePrompt)
        XCTAssertFalse(fence.beginDestinationTransition(.realName))
        XCTAssertFalse(fence.beginDestinationTransition(.phone))
        XCTAssertEqual(fence.completeDestinationTransition(), .realName)
        XCTAssertTrue(fence.canExposePrompt)
    }

    func testForcedAppPolicyDestinationStartsAfterAlertDismissalFence() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            apiContextOverride: makeContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.updateVisibleForcedAppPolicyAuthPrompt(.realName)

        state.openForcedAppPolicyAuthDestination(.realName)
        state.updateVisibleForcedAppPolicyAuthPrompt(.realName)

        XCTAssertNil(state.forcedAppPolicyAuthPrompt)
        XCTAssertNil(state.visibleForcedAppPolicyAuthPrompt)
        XCTAssertNil(
            state.forcedAppPolicyAuthDestination,
            "The full-screen flow must not start in the same UIKit transition as alert dismissal"
        )

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(state.forcedAppPolicyAuthDestination, .realName)
        XCTAssertEqual(state.visibleForcedAppPolicyAuthDestination, .realName)
    }

    func testVerificationRefreshKeepsMaskedPhoneAsPresentationOnly() async throws {
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
                data: Data(#"{"ok":true,"data":{"im_uid":"uid-1","user_id":"uid-1","account_id":"account-1","phone_masked":"138****1001","real_name_verified":false,"real_name_status":"unsubmitted"}}"#.utf8),
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
        state.forcedAppPolicyAuthStore.setPrompt(.phone) // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110
        state.forcedAppPolicyAuthStore.setDestination(.phone) // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110

        await state.refreshVerificationStatus()

        XCTAssertEqual(state.currentUser.phone, "138****1001")
        XCTAssertFalse(state.currentUser.phoneVerified)
        XCTAssertEqual(state.forcedAppPolicyAuthPrompt, .phone)
        XCTAssertEqual(state.forcedAppPolicyAuthDestination, .phone)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

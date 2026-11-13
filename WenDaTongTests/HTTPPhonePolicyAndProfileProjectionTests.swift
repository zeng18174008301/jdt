import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest; @testable import IM4Features
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testPhoneAuthDisabledLoginErrorUsesFriendlyMessageAndClosesPhoneMode() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"phone_auth_enabled":true,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"phone_auth_disabled","message":"phone auth disabled"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 403
            )
        ])
        let state = AppState(api: makeClient(transport: transport))
        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(loaded)
        XCTAssertTrue(state.isPhoneAuthEnabledForAuthUI)
        state.setAuthScreen(.phoneLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

        state.startLoginFlow(identifier: "13800000000", password: "aa123456")
        try await waitForCondition {
            state.toast == PhoneAuthPresentationPolicy.disabledMessage && !state.isAuthLoading
        }

        XCTAssertEqual(state.toast, "当前应用未开放手机号登录或注册，请使用账号继续")
        XCTAssertEqual(state.authScreen, .accountLogin)
        XCTAssertFalse(state.isPhoneAuthEnabledForAuthUI)
        XCTAssertFalse(state.currentAppPolicy?.phoneAuthEnabled ?? true)
        XCTAssertEqual(transport.requests().map(\.url?.path), [
            "/api/platform/apps/current-policy",
            "/api/platform/captcha/slide/config"
        ])
    }

    func testIMAPIClientGroupMuteListUsesFrozenTenantEndpoints() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"group_id":"group-1","target_uid":"uid-target","target_user_id":"WXTAB123456","target_nickname":"王同学","target_role":"member","operator_uid":"uid-admin","operator_name":"管理员","reason":"广告刷屏","created_at":"2026-07-22T10:00:00Z","updated_at":"2026-07-22T10:05:00Z"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group_id":"group-1","target_uid":"uid-target","target_user_id":"WXTAB123456","target_nickname":"王同学","target_role":"member","operator_uid":"uid-admin","operator_name":"管理员","reason":"广告刷屏","created_at":"2026-07-22T10:00:00Z","updated_at":"2026-07-22T10:05:00Z"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let items = try await client.listGroupMuteList(context: makeContext(), groupID: "group-1")
        let added = try await client.addGroupMuteListMember(context: makeContext(), groupID: "group-1", targetUID: " uid-target ", reason: "  广告刷屏  ")
        try await client.removeGroupMuteListMember(context: makeContext(), groupID: "group-1", uid: "uid-target")

        XCTAssertEqual(items.first?.targetUID, "uid-target")
        XCTAssertEqual(added.targetUID, "uid-target")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/mute-list")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/mute-list")
        let bodyData = try XCTUnwrap(requests[1].httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["target_uid"] as? String, "uid-target")
        XCTAssertEqual(body["reason"] as? String, "广告刷屏")
        XCTAssertNil(body["im_uid"])
        XCTAssertNil(body["user_id"])
        XCTAssertEqual(requests[2].httpMethod, "DELETE")
        XCTAssertEqual(requests[2].url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-1/mute-list/uid-target")
    }

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
    func testGroupModerationSnapshotsOnlyNotifyTheirGroupAndSurface() throws {
        let state = AppState(apiContextOverride: makeContext())
        let store = state.groupModerationStore
        var listUpdates: [GroupModerationStore.ListSnapshot] = []
        var settingsUpdates: [GroupModerationStore.SettingsSnapshot] = []
        var appUpdates = 0
        let list = store.listPublisher(for: "group-a").sink { listUpdates.append($0) }
        let settings = store.settingsPublisher(for: "group-a").sink { settingsUpdates.append($0) }
        let app = state.objectWillChange.sink { appUpdates += 1 }
        defer {
            list.cancel()
            settings.cancel()
            app.cancel()
        }

        _ = store.beginListLoad(groupID: "group-b")
        store.setSettingsMutation(groupID: "group-b", isMutating: true)
        XCTAssertEqual(listUpdates.count, 1)
        XCTAssertEqual(settingsUpdates.count, 1)

        let requestID = store.beginListLoad(groupID: "group-a")
        XCTAssertEqual(listUpdates.last?.isLoading, true)
        XCTAssertEqual(settingsUpdates.count, 1)
        store.setListItems([], groupID: "group-a")
        store.finishListLoad(requestID, groupID: "group-a")
        XCTAssertEqual(listUpdates.last?.items, [])
        XCTAssertEqual(listUpdates.last?.isLoading, false)
        let memberRequestID = try XCTUnwrap(store.beginMemberMutation(groupID: "group-a", targetUID: "uid-a"))
        XCTAssertEqual(listUpdates.last?.isMutating(targetUID: "uid-a"), true)
        XCTAssertNil(store.beginMemberMutation(groupID: "group-a", targetUID: "uid-a"))
        store.finishMemberMutation(memberRequestID, groupID: "group-a", targetUID: "uid-a")
        XCTAssertEqual(listUpdates.last?.isMutating(targetUID: "uid-a"), false)

        let listCount = listUpdates.count
        store.setSettingsMutation(groupID: "group-a", isMutating: true)
        store.setSettingsMutation(groupID: "group-a", isMutating: false, errorMessage: "保存失败")
        XCTAssertEqual(settingsUpdates.map(\.isMutating), [false, true, false])
        XCTAssertEqual(settingsUpdates.last?.errorMessage, "保存失败")
        XCTAssertEqual(listUpdates.count, listCount)
        XCTAssertEqual(appUpdates, 0)

        store.reset()
        let replacement = store.beginListLoad(groupID: "group-a")
        store.finishListLoad(requestID, groupID: "group-a")
        XCTAssertTrue(store.ownsListLoad(replacement, groupID: "group-a"))
        XCTAssertEqual(listUpdates.last?.isLoading, true)
        XCTAssertNil(listUpdates.last?.items)
        XCTAssertNil(settingsUpdates.last?.errorMessage)
    }

    func testOldMuteListMutationCannotClearReplacementAfterScopeReset() async throws {
        let transport = GroupMuteListMutationGateTransport()
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let group = GroupInfo(
            id: "group-a", name: "测试群", notice: "", owner: "管理员", members: [], admins: [],
            muted: false, allMuted: false, myRole: "owner", canManageMuteList: true
        )
        state.groups = [group]

        let old = Task { await state.addGroupMuteListMember(groupID: group.id, targetUID: "uid-a", reason: "") }
        defer { transport.releaseRemaining() }
        try await waitForCondition { transport.pendingCount == 1 }
        XCTAssertEqual(transport.pendingCount, 1)
        XCTAssertTrue(state.groupModerationStore.listSnapshot(for: group.id).isMutating(targetUID: "uid-a"))

        state.resetAuthenticatedRemoteData(showLoading: false)
        state.groups = [group]
        let replacement = Task { await state.addGroupMuteListMember(groupID: group.id, targetUID: "uid-a", reason: "") }
        try await waitForCondition { transport.pendingCount == 2 }
        guard transport.pendingCount == 2 else { return XCTFail("两个成员操作应同时等待响应") }

        transport.releaseFirst(HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"group_id":"group-a","target_uid":"uid-a"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ))
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(state.groupModerationStore.listSnapshot(for: group.id).isMutating(targetUID: "uid-a"))
        XCTAssertNil(state.groupModerationStore.listSnapshot(for: group.id).items)
        XCTAssertNil(state.toast)

        transport.releaseRemaining()
        _ = await replacement.value
        XCTAssertFalse(state.groupModerationStore.listSnapshot(for: group.id).isMutating(targetUID: "uid-a"))
    }
    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END

    func testGroupMuteListLocalPolicyDisablesOnlyMutedGroupConversations() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.groups = [
            GroupInfo(
                id: "group-muted",
                name: "禁言群",
                notice: "",
                owner: "Owner",
                members: [],
                admins: [],
                muted: false,
                allMuted: false,
                myRole: "member",
                groupMuted: true,
                canManageMuteList: false,
                muteListCount: nil
            )
        ]
        state.conversationStore.hydrateCachedConversations([
            makeGroupConversation(id: "group-muted"),
            ConversationMessageSnapshot(
                id: "uid-1:uid-2",
                title: "单聊",
                subtitle: "",
                kind: .direct,
                lastMessage: "",
                time: "",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: 2,
                accentHex: 0x6677FF,
                participants: [makeUser(id: "uid-2", name: "对方")],
                messages: []
            )
        ])

        XCTAssertEqual(state.conversationSendDisabledReason("group-muted"), AppState.groupMemberMutedMessage)
        XCTAssertEqual(state.conversationSendDisabledReason("uid-1:uid-2"), "")

        state.loadGroupMuteList(groupID: "group-muted", force: true)

        XCTAssertEqual(state.toast, "禁言名单仅群主或管理员可查看")
        XCTAssertTrue(transport.requests().isEmpty)
    }

    func testUpdateMyGroupNicknameUsesFrozenSelfOnlyPatchContract() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(
                    #"""
                    {
                      "ok": true,
                      "data": {
                        "contract_version": 1,
                        "group_id": "group-a",
                        "im_uid": "uid-1",
                        "group_nickname": "A 群昵称",
                        "raw_nickname": "全局昵称",
                        "display_name": "A 群昵称",
                        "display_name_source": "group_nickname",
                        "revision": 3,
                        "group_membership_generation": 7,
                        "updated_at": "2026-07-28T12:00:00Z"
                      }
                    }
                    """#.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let profile = try await client.updateMyGroupNickname(
            context: makeContext(),
            groupID: "group-a",
            groupNickname: "A 群昵称"
        )

        XCTAssertEqual(profile.groupID, "group-a")
        XCTAssertEqual(profile.groupMembershipGeneration, 7)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/group-a/members/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let body = try requestJSONObject(request)
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body["group_nickname"] as? String, "A 群昵称")
    }

    func testGroupMemberListSelfMemberHydratesNicknameOutsideFirstPageAndKeepsGenerationFence() throws { // WDT_IOS1_CORE_GROUP_SELF_SNAPSHOT_FIXTURE_20261111_BEGIN
        let state = AppState(api: makeClient(transport: FakeHTTPTransport(results: [])), apiContextOverride: makeContext())
        state.setCurrentUser(makeUser(id: "uid-1", name: "我的全局昵称")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.groups = [makeGroupInfo(id: "group-large")]
        let firstPage = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data(#"""
        {
          "items": [
            {"im_uid":"uid-2","nickname":"第一页成员","role":"member"}
          ],
          "self_member": {
            "im_uid":"uid-1",
            "nickname":"全局昵称",
            "group_nickname":"页外群昵称",
            "role":"member",
            "revision":9,
            "group_membership_generation":12
          },
          "has_more":true
        }
        """#.utf8))
        state.debugApplyGroupMembersResultForTesting(
            RemoteGroupMembersResult(
                items: firstPage.items,
                selfMember: firstPage.selfMember,
                total: nil,
                hasMore: firstPage.hasMore
            ),
            groupID: "group-large"
        )

        XCTAssertEqual(state.myGroupNickname(groupID: "group-large"), "页外群昵称")
        let group = try XCTUnwrap(state.group(id: "group-large"))
        XCTAssertEqual(group.members.map(\.id), ["uid-2"])
        let groupConversation = makeGroupConversation(id: "group-large")
        let groupResolver = MessageSenderResolver(
            currentUser: state.currentUser,
            enterpriseName: "",
            conversation: groupConversation,
            contacts: [],
            group: group,
            exactGroupSelf: state.myGroupMemberProjection(groupID: "group-large")
        )
        let selfMessage = ChatMessage(
            id: "message-self-outside-page",
            senderId: "uid-1",
            senderName: "历史全局快照",
            text: "hello",
            time: "",
            isOutgoing: true,
            status: .read,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: [],
            quote: nil,
            attachmentName: nil,
            attachmentMeta: nil
        )
        XCTAssertEqual(
            groupResolver.displaySenderName(
                for: selfMessage,
                resolvedUser: groupResolver.senderUser(for: selfMessage)
            ),
            "页外群昵称"
        )
        let directConversation = makeDirectConversation(id: "direct-uid-2")
        let directResolver = MessageSenderResolver(
            currentUser: state.currentUser,
            enterpriseName: "",
            conversation: directConversation,
            contacts: [],
            group: nil
        )
        // No authoritative snapshot: preserve the original global-name fallback/isolation assertion.
        var legacyDirectSelfMessage = selfMessage; legacyDirectSelfMessage.senderName = ""
        XCTAssertEqual(
            directResolver.displaySenderName(
                for: legacyDirectSelfMessage,
                resolvedUser: directResolver.senderUser(for: legacyDirectSelfMessage)
            ),
            "我的全局昵称"
        )
        XCTAssertEqual(directResolver.displaySenderName(for: selfMessage,
            resolvedUser: directResolver.senderUser(for: selfMessage)), "历史全局快照")
        let stalePage = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data(#"""
        {
          "items": [],
          "selfMember": {
            "im_uid":"uid-1",
            "nickname":"全局昵称",
            "group_nickname":"过期群昵称",
            "role":"member",
            "revision":8,
            "group_membership_generation":11
          }
        }
        """#.utf8))
        state.debugApplyGroupMembersResultForTesting(
            RemoteGroupMembersResult(
                items: stalePage.items,
                selfMember: stalePage.selfMember,
                total: nil
            ),
            groupID: "group-large"
        )
        XCTAssertEqual(state.myGroupNickname(groupID: "group-large"), "页外群昵称")
    } // WDT_IOS1_CORE_GROUP_SELF_SNAPSHOT_FIXTURE_20261111_END
    func testNicknamePatchCachesAuthoritativeSelfProjectionBeforeGroupSummaryMaterializes() async throws {
        let response = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"group_id":"group-pending-summary","im_uid":"uid-1","group_nickname":"先到昵称","raw_nickname":"全局昵称","display_name":"先到昵称","display_name_source":"group_nickname","revision":3,"group_membership_generation":7}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [response])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "全局昵称")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        XCTAssertNil(state.group(id: "group-pending-summary"))

        let updated = await state.updateMyGroupNickname(
            groupID: "group-pending-summary",
            rawValue: "先到昵称"
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(state.myGroupNickname(groupID: "group-pending-summary"), "先到昵称")
        XCTAssertEqual(state.myGroupMemberProjection(groupID: "group-pending-summary")?.name, "先到昵称")
        XCTAssertEqual(
            transport.requests().filter { $0.httpMethod == "PATCH" }.count,
            1
        )
    }

    func testLegacyUnversionedNicknamePatchInvalidatesOlderBundleAndQueuesPostCommitRefresh() async throws {
        let transport = GroupNicknameMutationRaceHTTPTransport()
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "我的全局昵称")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.groups = [makeGroupInfo(id: "group-a")]

        state.loadGroupDetailIfNeeded(groupID: "group-a", force: true)
        try await waitForCondition {
            transport.memberRequestCount() == 1
        }

        let updated = await state.updateMyGroupNickname(
            groupID: "group-a",
            rawValue: "提交后的群昵称"
        )
        XCTAssertTrue(updated)
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "提交后的群昵称")
        XCTAssertEqual(
            state.myGroupMemberProjection(groupID: "group-a")?.name,
            "提交后的群昵称"
        )

        transport.releasePrePatchMemberResponse()
        try await waitForCondition {
            transport.memberRequestCount() == 2
        }
        // The second, post-commit member read is deliberately delayed. At this
        // point the older unversioned page has completed, so retaining the PATCH
        // projection proves that its request-start epoch was rejected.
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "提交后的群昵称")
        XCTAssertEqual(
            state.myGroupMemberProjection(groupID: "group-a")?.name,
            "提交后的群昵称"
        )

        try await waitForCondition {
            transport.completedPostCommitMemberResponse()
        }
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "提交后的群昵称")
        XCTAssertEqual(transport.memberRequestCount(), 2)
    }

    func testGroupMemberProfileRealtimeIgnoresStaleGenerationAndDoesNotReadNicknameValue() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "group.member.updated",
                requestID: nil,
                payload: [
                    "group_id": .string("group-a"),
                    "group_membership_generation": .int(8),
                    "changed": .array([.string("group_nickname")])
                ]
            )
        )
        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "group.member.updated",
                requestID: nil,
                payload: [
                    "group_id": .string("group-a"),
                    "group_membership_generation": .int(7),
                    "changed": .array([.string("group_nickname")]),
                    "group_nickname": .string("不得从事件直接采用")
                ]
            )
        )

        XCTAssertEqual(state.debugMinimumGroupMemberProfileGenerationForTesting(groupID: "group-a"), 8)
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "")
        try await Task.sleep(nanoseconds: 80_000_000)
        let profileRefreshRequests = transport.requests().filter {
            $0.url?.path == "/api/tenant/groups/group-a/summary"
        }
        XCTAssertLessThanOrEqual(profileRefreshRequests.count, 1)
    }

    func testGroupMemberProfileRealtimeQueuesAuthoritativeRefreshBehindInflightBundle() async throws {
        let transport = GroupNicknameMutationRaceHTTPTransport()
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "我的全局昵称")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.groups = [makeGroupInfo(id: "group-a")]

        state.loadGroupDetailIfNeeded(groupID: "group-a", force: true)
        try await waitForCondition {
            transport.memberRequestCount() == 1
        }

        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "group.member.updated",
                requestID: nil,
                payload: [
                    "group_id": .string("group-a"),
                    "group_membership_generation": .int(1),
                    "changed": .array([.string("group_nickname")])
                ]
            )
        )
        transport.releasePrePatchMemberResponse()

        try await waitForCondition {
            transport.memberRequestCount() == 2
        }
        try await waitForCondition {
            transport.completedPostCommitMemberResponse()
        }

        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "提交后的群昵称")
        XCTAssertEqual(transport.memberRequestCount(), 2)
    }

    func testMessageSenderResolverPrefersCurrentGroupProjectionWithoutMutatingSnapshot() {
        let currentUser = makeUser(id: "uid-1", name: "我")
        let globalMember = makeUser(id: "uid-2", name: "全局昵称")
        let exactGroupMember = makeUser(id: "uid-2", name: "A 群昵称")
        let conversation = ConversationMessageSnapshot(
            id: "group-a",
            title: "A 群",
            subtitle: "",
            kind: .group,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: 2,
            accentHex: 0,
            participants: [globalMember],
            messages: []
        )
        let group = GroupInfo(
            id: "group-a",
            name: "A 群",
            notice: "",
            owner: "",
            members: [exactGroupMember],
            admins: [],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil
        )
        let resolver = MessageSenderResolver(
            currentUser: currentUser,
            enterpriseName: "",
            conversation: conversation,
            contacts: [globalMember],
            group: group,
            contactRemarks: ["uid-2": "好友备注"]
        )
        let snapshotMessage = ChatMessage(
            id: "message-1",
            senderId: "uid-2",
            senderName: "服务端精确群投影",
            text: "hello",
            time: "",
            isOutgoing: false,
            status: .read,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: [],
            quote: nil,
            attachmentName: nil,
            attachmentMeta: nil
        )
        let fallbackMessage = ChatMessage(
            id: "message-2",
            senderId: "uid-2",
            senderName: "",
            text: "hello",
            time: "",
            isOutgoing: false,
            status: .read,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: [],
            quote: nil,
            attachmentName: nil,
            attachmentMeta: nil
        )

        let resolvedUser = resolver.senderUser(for: snapshotMessage)

        XCTAssertEqual(resolvedUser?.name, "A 群昵称")
        XCTAssertEqual(
            resolver.displaySenderName(for: snapshotMessage, resolvedUser: resolvedUser),
            "A 群昵称"
        )
        XCTAssertEqual(
            resolver.displaySenderName(for: fallbackMessage, resolvedUser: resolver.senderUser(for: fallbackMessage)),
            "A 群昵称"
        )

        let groupOnlyResolver = MessageSenderResolver(
            currentUser: currentUser,
            enterpriseName: "",
            conversation: conversation,
            contacts: [globalMember],
            group: group
        )
        XCTAssertEqual(
            groupOnlyResolver.displaySenderName(
                for: snapshotMessage,
                resolvedUser: groupOnlyResolver.senderUser(for: snapshotMessage)
            ),
            "A 群昵称"
        )
        XCTAssertEqual(
            groupOnlyResolver.displaySenderName(
                for: fallbackMessage,
                resolvedUser: groupOnlyResolver.senderUser(for: fallbackMessage)
            ),
            "A 群昵称"
        )
    }

    func testMessageSenderResolverPresentsCurrentSelfGroupNicknameAndKeepsStoredSnapshot() {
        let currentUser = makeUser(id: "uid-1", name: "我的全局昵称")
        let exactSelf = makeUser(id: "uid-1", name: "我的 A 群昵称")
        let conversation = ConversationMessageSnapshot(
            id: "group-a",
            title: "A 群",
            subtitle: "",
            kind: .group,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: 1,
            accentHex: 0,
            participants: [currentUser],
            messages: []
        )
        let group = GroupInfo(
            id: "group-a",
            name: "A 群",
            notice: "",
            owner: "",
            members: [exactSelf],
            admins: [],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil
        )
        let resolver = MessageSenderResolver(
            currentUser: currentUser,
            enterpriseName: "",
            conversation: conversation,
            contacts: [],
            group: group,
            contactRemarks: ["uid-1": "不应使用的本人备注"]
        )
        let message = ChatMessage(
            id: "message-self",
            senderId: "uid-1",
            senderName: "旧快照",
            text: "hello",
            time: "",
            isOutgoing: true,
            status: .read,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: [],
            quote: nil,
            attachmentName: nil,
            attachmentMeta: nil
        )

        XCTAssertEqual(
            resolver.displaySenderName(for: message, resolvedUser: resolver.senderUser(for: message)),
            "我的 A 群昵称"
        )
        XCTAssertEqual(message.senderName, "旧快照")
    }

    func testSyncedMessageAndReplyKeepTheirIndependentSenderSnapshotsAcrossNicknameChange() throws {
        let state = AppState(api: makeClient(transport: FakeHTTPTransport(results: [])), apiContextOverride: makeContext())
        state.setCurrentUser(makeUser(id: "uid-self", name: "我")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        let currentMember = makeUser(id: "uid-2", name: "当前群昵称")
        let remote = try decodeRemoteMessage(#"""
        {
          "message_id":"m-new",
          "channel_id":"group-a",
          "channel_type":"group",
          "channel_seq":43,
          "from_uid":"uid-2",
          "sender_display_name":"当前权威群昵称",
          "content_type":"text",
          "payload":{
            "text":"回复旧消息",
            "sender_snapshot_name":"变更后群昵称",
            "reply_to":{
              "message_id":"m-old",
              "channel_seq":41,
              "from_uid":"uid-2",
              "sender_display_name":"变更前群昵称",
              "content_type":"text",
              "text":"旧消息"
            }
          },
          "status":"sent",
          "created_at":"2026-08-18T10:00:00Z"
        }
        """#)

        let mapped = state.debugChatMessageForTesting(remote, participants: [currentMember])

        XCTAssertEqual(mapped.senderName, "变更后群昵称")
        XCTAssertEqual(mapped.replyContext?.senderID, "uid-2")
        XCTAssertEqual(mapped.replyContext?.senderName, "变更前群昵称")
        XCTAssertEqual(mapped.replyContext?.channelSeq, 41)
    }

    func testOpeningDirectConversationFromGroupProfileUsesGlobalContactIdentity() throws {
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [
                HTTPTransportResult(data: Data(#"{"ok":true,"data":{}}"#.utf8), isHTTPResponse: true, statusCode: 200)
            ])),
            conversationStore: ConversationStore(scope: TestMessageMemoryScope.value),
            apiContextOverride: makeContext()
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "我")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        let globalContact = makeUser(id: "uid-2", name: "全局昵称")
        let groupProjectedMember = makeUser(id: "uid-2", name: "A 群昵称")
        state.contacts = [globalContact]

        let conversationID = try XCTUnwrap(
            state.openOrCreateDirectConversationID(for: groupProjectedMember, activateChatsTab: false)
        )
        let conversation = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first { $0.id == conversationID })

        XCTAssertEqual(conversation.title, "全局昵称")
        XCTAssertEqual(conversation.participants.first?.name, "全局昵称")
    }
}

// WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
private final class GroupMuteListMutationGateTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<HTTPTransportResult, Error>] = []
    private var closed = false

    var pendingCount: Int { lock.withLock { pending.count } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.httpMethod == "POST", request.url?.path.hasSuffix("/mute-list") == true else {
            throw URLError(.unsupportedURL)
        }
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
        lock.withLock { pending.removeFirst() }.resume(returning: result)
    }

    func releaseRemaining() {
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
// WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

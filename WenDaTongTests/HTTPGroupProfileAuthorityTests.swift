import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testUnversionedSelfMemberRemainsCompatibleUntilPositiveFenceThenCannotOverwrite() throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.groups = [makeGroupInfo(id: "group-a")]
        let initial = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data(#"""
        {
          "items": [],
          "self_member": {
            "im_uid": "uid-1",
            "nickname": "全局昵称",
            "group_nickname": "兼容旧服务端昵称",
            "role": "member"
          }
        }
        """#.utf8))
        state.debugApplyGroupMembersResultForTesting(
            RemoteGroupMembersResult(items: initial.items, selfMember: initial.selfMember, total: nil),
            groupID: "group-a"
        )
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "兼容旧服务端昵称")

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
        let staleUnversioned = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data(#"""
        {
          "items": [],
          "self_member": {
            "im_uid": "uid-1",
            "nickname": "全局昵称",
            "group_nickname": "不得覆盖的新旧不明昵称",
            "role": "member"
          }
        }
        """#.utf8))
        state.debugApplyGroupMembersResultForTesting(
            RemoteGroupMembersResult(
                items: staleUnversioned.items,
                selfMember: staleUnversioned.selfMember,
                total: nil
            ),
            groupID: "group-a"
        )

        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "兼容旧服务端昵称")
        XCTAssertEqual(state.debugMinimumGroupMemberProfileGenerationForTesting(groupID: "group-a"), 8)

        let postFenceUnversioned = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data(#"""
        {
          "items": [],
          "self_member": {
            "im_uid": "uid-1",
            "nickname": "全局昵称",
            "group_nickname": "事件后重新读取的昵称",
            "role": "member"
          }
        }
        """#.utf8))
        state.debugApplyGroupMembersResultForTesting(
            RemoteGroupMembersResult(
                items: postFenceUnversioned.items,
                selfMember: postFenceUnversioned.selfMember,
                total: nil
            ),
            groupID: "group-a",
            profileGenerationAtRequestStart: 8
        )

        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "事件后重新读取的昵称")
        XCTAssertEqual(state.debugMinimumGroupMemberProfileGenerationForTesting(groupID: "group-a"), 0)
    }

    func testRejectedStaleMutationProfileCannotPatchGroupMembers() throws {
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [])),
            apiContextOverride: makeContext()
        )
        state.groups = [
            GroupInfo(
                id: "group-a",
                name: "A 群",
                notice: "",
                owner: "",
                members: [makeUser(id: "uid-1", name: "旧群昵称")],
                admins: [],
                muted: false,
                allMuted: false,
                allMuteStart: nil,
                allMuteEnd: nil
            )
        ]
        let current = try JSONDecoder().decode(RemoteGroupMemberProfile.self, from: Data(#"""
        {
          "group_id":"group-a",
          "im_uid":"uid-1",
          "group_nickname":"新群昵称",
          "raw_nickname":"全局昵称",
          "display_name":"新群昵称",
          "revision":12,
          "group_membership_generation":12
        }
        """#.utf8))
        let stale = try JSONDecoder().decode(RemoteGroupMemberProfile.self, from: Data(#"""
        {
          "group_id":"group-a",
          "im_uid":"uid-1",
          "group_nickname":"过期群昵称",
          "raw_nickname":"全局昵称",
          "display_name":"过期群昵称",
          "revision":11,
          "group_membership_generation":11
        }
        """#.utf8))

        state.debugApplyMyGroupMemberProfileForTesting(current, fallbackGroupID: "group-a")
        state.debugApplyMyGroupMemberProfileForTesting(stale, fallbackGroupID: "group-a")

        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "新群昵称")
        XCTAssertEqual(state.group(id: "group-a")?.members.first?.name, "新群昵称")
    }

    func testGroupLifecycleClearsProfileScopeAndCancelsInflightRefresh() async throws {
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"group":{"group_id":"group-a","name":"A 群"},"my_role":"member","member_preview":[]}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ],
            delayNanoseconds: 180_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.groups = [
            GroupInfo(
                id: "group-a",
                name: "A 群",
                notice: "",
                owner: "",
                members: [],
                admins: [],
                muted: false,
                allMuted: false,
                allMuteStart: nil,
                allMuteEnd: nil
            )
        ]
        let versioned = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data(#"""
        {
          "items": [],
          "self_member": {
            "im_uid":"uid-1",
            "nickname":"全局昵称",
            "group_nickname":"离群前昵称",
            "role":"member",
            "revision":12,
            "group_membership_generation":12
          }
        }
        """#.utf8))
        state.debugApplyGroupMembersResultForTesting(
            RemoteGroupMembersResult(items: [], selfMember: versioned.selfMember, total: nil),
            groupID: "group-a"
        )
        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "group.member.updated",
                requestID: nil,
                payload: [
                    "group_id": .string("group-a"),
                    "group_membership_generation": .int(13),
                    "changed": .array([.string("group_nickname")])
                ]
            )
        )
        try await waitForCondition {
            !transport.requests().isEmpty
        }

        state.applyGroupLifecycleEventForTesting(event: "group_left", groupID: "group-a")
        try await Task.sleep(nanoseconds: 240_000_000)

        XCTAssertNil(state.group(id: "group-a"))
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "")
        XCTAssertEqual(state.debugMinimumGroupMemberProfileGenerationForTesting(groupID: "group-a"), 0)
        let groupRequests = transport.requests().filter {
            $0.url?.path.hasPrefix("/api/tenant/groups/group-a") == true
        }
        XCTAssertEqual(groupRequests.count, 1)
        XCTAssertEqual(groupRequests.first?.url?.path, "/api/tenant/groups/group-a/summary")
    }

    func testGroupLifecycleRejectsInflightNicknameMutationResponse() async throws {
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"group_id":"group-a","im_uid":"uid-1","group_nickname":"离群后不得恢复","raw_nickname":"全局昵称","display_name":"离群后不得恢复","display_name_source":"group_nickname","updated_at":"2026-07-28T10:01:00Z"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ],
            delayNanoseconds: 180_000_000
        )
        let state = AppState(
            api: makeClient(transport: transport),
            conversationStore: ConversationStore(scope: TestMessageMemoryScope.value),
            apiContextOverride: makeContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "全局昵称")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.groups = [
            GroupInfo(
                id: "group-a",
                name: "A 群",
                notice: "",
                owner: "",
                members: [],
                admins: [],
                muted: false,
                allMuted: false,
                allMuteStart: nil,
                allMuteEnd: nil
            )
        ]

        let update = Task { await state.updateMyGroupNickname(groupID: "group-a", rawValue: "离群后不得恢复") }
        try await waitForCondition {
            transport.requests().contains { $0.httpMethod == "PATCH" }
        }
        state.applyGroupLifecycleEventForTesting(event: "group_left", groupID: "group-a")

        let updateSucceeded = await update.value
        XCTAssertFalse(updateSucceeded)
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "")
        XCTAssertNil(state.group(id: "group-a"))
    }

    func testGroupLifecycleRejectsInflightUnversionedMemberPageResponse() async throws {
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"items":[],"self_member":{"im_uid":"uid-1","nickname":"全局昵称","group_nickname":"离群后不得恢复","role":"member"},"has_more":false}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ],
            delayNanoseconds: 180_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "全局昵称")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        var group = makeGroupInfo(id: "group-a")
        group.members = [makeUser(id: "uid-2", name: "成员")]
        group.membersPartial = true
        group.membersLoadedCount = 1
        group.membersNextOffset = 1
        state.groups = [group]

        state.loadNextGroupMembersPageIfNeeded(groupID: "group-a")
        try await waitForCondition {
            transport.requests().contains { $0.url?.path.hasSuffix("/groups/group-a/members") == true }
        }
        state.applyGroupLifecycleEventForTesting(event: "group_left", groupID: "group-a")
        try await Task.sleep(nanoseconds: 240_000_000)

        XCTAssertNil(state.group(id: "group-a"))
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "")
    }

    func testGroupLifecycleRejectsInflightUnversionedMentionResponse() async throws {
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"items":[{"im_uid":"uid-2","nickname":"群成员","role":"member"}],"self_member":{"im_uid":"uid-1","nickname":"全局昵称","group_nickname":"离群后不得恢复","role":"member"},"has_more":false}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ],
            delayNanoseconds: 180_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "全局昵称")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.groups = [makeGroupInfo(id: "group-a")]

        let search = Task {
            await state.searchGroupMentionMembers(groupID: "group-a", keyword: "")
        }
        try await waitForCondition {
            transport.requests().contains { $0.url?.path.hasSuffix("/groups/group-a/members") == true }
        }
        state.applyGroupLifecycleEventForTesting(event: "group_left", groupID: "group-a")

        let result = await search.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertNil(state.group(id: "group-a"))
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "")
    }

    func testGroupLifecycleRejectsInflightNicknameFailureToast() async throws {
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"暂不可用"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 503
                )
            ],
            delayNanoseconds: 180_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.groups = [makeGroupInfo(id: "group-a")]

        let update = Task {
            await state.updateMyGroupNickname(groupID: "group-a", rawValue: "新群昵称")
        }
        try await waitForCondition {
            transport.requests().contains { $0.httpMethod == "PATCH" }
        }
        state.applyGroupLifecycleEventForTesting(event: "group_left", groupID: "group-a")
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("离群后的当前提示")

        let updateSucceeded = await update.value
        XCTAssertFalse(updateSucceeded)
        XCTAssertEqual(state.toast, "离群后的当前提示")
    }

    func testNicknameMutationRejectsMismatchedGroupAndCurrentIdentity() async {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group_id":"group-b","im_uid":"uid-1","group_nickname":"错误群","raw_nickname":"全局昵称","display_name":"错误群","display_name_source":"group_nickname","updated_at":"2026-07-28T10:01:00Z"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group_id":"group-a","im_uid":"uid-other","group_nickname":"错误账号","raw_nickname":"全局昵称","display_name":"错误账号","display_name_source":"group_nickname","updated_at":"2026-07-28T10:02:00Z"}}"#.utf8),
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
        state.setCurrentUser(makeUser(id: "uid-1", name: "全局昵称")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        let mismatchedGroupSucceeded = await state.updateMyGroupNickname(groupID: "group-a", rawValue: "错误群")
        let mismatchedIdentitySucceeded = await state.updateMyGroupNickname(groupID: "group-a", rawValue: "错误账号")
        XCTAssertFalse(mismatchedGroupSucceeded)
        XCTAssertFalse(mismatchedIdentitySucceeded)
        XCTAssertEqual(state.myGroupNickname(groupID: "group-a"), "")
    }

    func decodeRemoteMessage(_ json: String) throws -> RemoteMessage {
        try JSONDecoder().decode(RemoteMessage.self, from: Data(json.utf8))
    }

    func makeSessionReauthenticationFixture(
        transport: HTTPTransport,
        store: InMemoryProtectedSessionStore
    ) throws -> (state: AppState, original: IMAPIContext, persistence: MessagePersistenceCoordinator, root: URL, client: IMAPIClient, routes: IMRuntimeRouteStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios1-reauth-\(UUID().uuidString)")
        let original = makeRefreshableMessageSendContext()
        XCTAssertTrue(original.save(sessionStore: store).isCommitted)
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let routes = isolatedRuntimeRouteStore()
        let client = makeClient(transport: transport, runtimeRouteStore: routes)
        let state = AppState(
            api: client,
            realtimeClient: PostLoginSilentRealtimeTransport(),
            messageStore: AvatarProjectionEmptyMessageStore(),
            messagePersistence: persistence,
            protectedSessionStore: store,
            apiContextOverride: original
        )
        state.bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.beginSessionReauthentication()
        XCTAssertTrue(state.isSessionReauthenticationPresented)
        return (state, original, persistence, root, client, routes)
    }

    func assertSessionReauthenticationRetiresUpload(
        kind: MessageKind, phase: String, lateFailure: Bool, retireDurableTicketOnly: Bool = false
    ) async throws {
        let bytes = kind == .image ? pngFixtureBytes(count: 4_096) : Data([1, 2, 3, 4])
        let transport = SessionReauthenticationUploadGateTransport(
            phase: phase, lateFailure: lateFailure, voice: kind == .voice, size: bytes.count,
            loginResult: try sessionReauthenticationLoginResult()
        )
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        fixture.state.cancelSessionReauthentication()
        defer {
            transport.releaseOld()
            transport.releaseReplacement()
            // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        }
        let conversationID = "uid-1:uid-2"
        fixture.state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: conversationID)])
        var sourceURL = fixture.root.appendingPathComponent("owned-source.png")
        defer { PendingAttachmentFileStore.removeManagedFile(at: sourceURL) }
        if kind == .image {
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try bytes.write(to: sourceURL)
            // Match the production file-picker handoff: sendAttachment accepts only
            // owned pending files, not an arbitrary URL in the test directory.
            sourceURL = try PendingAttachmentFileStore.stageFile(from: sourceURL, preferredName: "fixture.png").url
            XCTAssertTrue(fixture.state.sendAttachment(
                kind: .image, name: "fixture.png", mimeType: "image/png", sizeBytes: Int64(bytes.count),
                data: nil, fileURL: sourceURL, removeFileWhenFinished: true, conversationID: conversationID, quote: nil
            ), fixture.state.toast ?? "image send returned false without a toast")
        } else {
            XCTAssertTrue(fixture.state.sendVoiceMessage(
                data: bytes, name: "voice.m4a", mimeType: "audio/mp4", sizeBytes: Int64(bytes.count),
                durationMS: 1_500, waveform: [10, 20, 30], conversationID: conversationID, quote: nil
            ), fixture.state.toast ?? "voice send returned false without a toast")
        }
        let localID = try XCTUnwrap(
            fixture.state.conversationStore.conversationMessageSnapshot(id: conversationID)?.messages.first?.id,
            fixture.state.toast ?? "outgoing local message was not queued"
        )
        defer { fixture.state.cancelAttachmentUpload(messageID: localID, in: conversationID) }
        try await waitForCondition { transport.oldIsWaiting }
        XCTAssertTrue(transport.oldIsWaiting, "\(kind) \(phase) \(lateFailure)")
        let oldTask = try XCTUnwrap(fixture.state.attachmentUploadTaskForReauthenticationTesting(messageID: localID))
        let oldRequestCounts = transport.oldCounts

        if retireDurableTicketOnly {
            // Leave AppState's operation/context untouched while independently retiring
            // only its durable ticket. Failed checkpoint persistence must stop transport.
            _ = try await fixture.persistence.ensureTicket(context: fixture.original, sessionGeneration: 2)
            transport.releaseOld()
            await oldTask.value
            XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
            XCTAssertEqual(transport.oldCounts["finalize", default: 0], 0)
            XCTAssertEqual(transport.oldCounts["send", default: 0], 0)
            XCTAssertTrue(fixture.state.fileStore.hasPendingAttachmentUpload(messageID: localID))
            let pending = try XCTUnwrap(fixture.state.fileStore.pendingAttachmentUpload(messageID: localID))
            if kind == .image {
                XCTAssertEqual(pending.fileURL, sourceURL)
                XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
            } else {
                XCTAssertEqual(pending.data, bytes)
            }
            return
        }

        fixture.state.beginSessionReauthentication()
        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
        )
        XCTAssertTrue(succeeded)
        XCTAssertTrue(fixture.state.fileStore.hasPendingAttachmentUpload(messageID: localID))
        transport.expectReplacementConfig()
        fixture.state.startQueuedAttachmentUploadsInOrder([localID], in: conversationID)
        try await waitForCondition { transport.replacementIsWaiting }
        guard transport.replacementIsWaiting else {
            return XCTFail("The replacement never reached upload configuration")
        }
        let replacementTask = try XCTUnwrap(fixture.state.attachmentUploadTaskForReauthenticationTesting(messageID: localID))
        let beforeLate = try XCTUnwrap(fixture.state.conversationStore.conversationMessageSnapshot(id: conversationID)?.messages.first(where: { $0.id == localID }))
        let beforeCheckpoint = fixture.state.fileStore.attachmentUploadCheckpoint(messageID: localID)
        XCTAssertTrue(fixture.state.fileStore.hasAttachmentUploadTask(messageID: localID))

        transport.releaseOld()
        await oldTask.value

        XCTAssertEqual(transport.oldCounts, oldRequestCounts, "retired sender must not advance to another HTTP phase")
        XCTAssertFalse(replacementTask.isCancelled)
        XCTAssertTrue(fixture.state.fileStore.hasAttachmentUploadTask(messageID: localID))
        XCTAssertTrue(fixture.state.fileStore.hasPendingAttachmentUpload(messageID: localID))
        let afterLate = try XCTUnwrap(fixture.state.conversationStore.conversationMessageSnapshot(id: conversationID)?.messages.first(where: { $0.id == localID }))
        XCTAssertEqual(afterLate.status, beforeLate.status)
        XCTAssertEqual(afterLate.attachmentUploadStatus, beforeLate.attachmentUploadStatus)
        XCTAssertEqual(afterLate.attachmentTransferProgress, beforeLate.attachmentTransferProgress)
        XCTAssertEqual(fixture.state.fileStore.attachmentUploadCheckpoint(messageID: localID)?.fileID, beforeCheckpoint?.fileID)
        let pending = try XCTUnwrap(fixture.state.fileStore.pendingAttachmentUpload(messageID: localID))
        if kind == .image {
            XCTAssertEqual(pending.fileURL, sourceURL)
            XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        } else {
            XCTAssertEqual(pending.data, bytes)
        }
        let saved = IMAPIContext.load(sessionStore: store)
        let ticket = try await fixture.persistence.ensureTicket(context: saved, sessionGeneration: 2)
        let outbox = try await fixture.persistence.recoverableOutbox(ticket: ticket)
        XCTAssertEqual(outbox.map(\.clientMessageID), [localID])
        let item = try XCTUnwrap(outbox.first)
        let staged = try await fixture.persistence.loadStagedAttachment(ticket: ticket, item: item)
        XCTAssertEqual(staged, bytes)

        // Drain both captured tasks; no sleep is used to infer that the late callback ran.
        replacementTask.cancel()
        transport.releaseReplacement()
        await replacementTask.value
    }

    func sessionReauthenticationRoutes(revision: UInt64, suffix: String) -> IMRuntimeRouteSnapshot {
        let base = runtimeRouteSnapshotForHTTPWiring(
            tenantPreferred: ["https://tenant-\(suffix).example.test"],
            realtimePreferred: "wss://ws-\(suffix).example.test", revision: revision
        )
        var services = base.services
        services[IMRuntimeRouteService.imAPI.rawValue] = .init(
            preferred: ["https://im-\(suffix).example.test"], backups: ["https://im-backup.example.net"],
            preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
        )
        let unsigned = IMRuntimeRouteSnapshot(
            contractVersion: base.contractVersion, appID: base.appID, tenantID: base.tenantID,
            revision: base.revision, source: base.source, status: base.status,
            configHash: String(repeating: "0", count: 64), services: services, policy: base.policy
        )
        return IMRuntimeRouteSnapshot(
            contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: unsigned.tenantID,
            revision: unsigned.revision, source: unsigned.source, status: unsigned.status,
            configHash: unsigned.recomputedConfigHash!, services: services, policy: unsigned.policy
        )
    }

    func sessionReauthenticationRouteLoginResult(
        routes: IMRuntimeRouteSnapshot,
        platformOnly: Bool
    ) throws -> HTTPTransportResult {
        let login = try sessionReauthenticationLoginResult()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: login.data) as? [String: Any])
        var data = try XCTUnwrap(envelope["data"] as? [String: Any])
        if platformOnly {
            data.removeValue(forKey: "session")
        } else {
            let enter = try tenantEnterSuccess(entryTicket: "unused-direct-entry", routes: routes)
            let enterEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: enter.data) as? [String: Any])
            let enterData = try XCTUnwrap(enterEnvelope["data"] as? [String: Any])
            data["runtime_config"] = try XCTUnwrap(enterData["runtime_config"])
        }
        envelope["data"] = data
        return HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: envelope), isHTTPResponse: true, statusCode: 200)
    }

    func sessionReauthenticationLoginResult() throws -> HTTPTransportResult {
        let payload: [String: Any] = [
            "account": ["id": "account-1", "username": "member1", "status": "normal"],
            "platform_token": "reauth-platform-token",
            "auth_session": [
                "session_id": "reauth-platform-session", "refresh_token": "reauth-platform-refresh",
                "expires_at": 1_895_000_000, "app_id": "jianhuitong-ios", "device_id": "device-1",
                "client_type": "ios", "token_type": "platform"
            ],
            "tenant": ["tenant_id": "tenant-1", "name": "Synthetic Tenant", "status": "active"],
            "session": [
                "im_uid": "uid-1", "im_token": "reauth-im-token", "expires_at": 1_895_000_000,
                "app_id": "jianhuitong-ios", "device_id": "device-1",
                "auth_session": [
                    "session_id": "reauth-tenant-session", "refresh_token": "reauth-tenant-refresh",
                    "expires_at": 1_895_000_000, "tenant_id": "tenant-1",
                    "app_id": "jianhuitong-ios", "device_id": "device-1",
                    "client_type": "ios", "token_type": "im"
                ]
            ]
        ]
        return HTTPTransportResult(
            data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload]),
            isHTTPResponse: true, statusCode: 200
        )
    }

    func makeClient(
        transport: HTTPTransport,
        wireCodec: any WireCodec = JSONWireCodec(),
        preauthDeviceProofNow: @escaping () -> Date = { Date() },
        runtimeRouteStore: IMRuntimeRouteStore = IMRuntimeRouteStore(),
        bootstrapBases: [URL]? = nil
    ) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: bootstrapBases,
            httpTransport: transport,
            wireCodec: wireCodec,
            runtimeRouteStore: runtimeRouteStore,
            preauthDeviceProofNow: preauthDeviceProofNow
        )
    }

	func runtimeRouteSnapshotForHTTPWiring(
		tenantPreferred: [String] = ["https://tenant-primary.example.com"],
		tenantID: String = "tenant-1",
		realtimePreferred: String = "wss://ws-primary.example.com",
		realtimeBackup: String = "wss://ws-backup.example.net",
		revision: UInt64 = 1,
        imBackups: [String] = ["https://im-backup.example.net"] // WDT_IOS1_HTTP_ROUTE_V5_20261113
	) -> IMRuntimeRouteSnapshot {
		let services: [String: IMRuntimeRouteEndpointSet] = [
			"platform_api": .init(
				preferred: ["https://platform-primary.example.com"], backups: ["https://platform-backup.example.net"],
				preferredSource: "app_preferred", backupSource: "common_platform_backup"
			),
			"tenant_api": .init(
				preferred: tenantPreferred, backups: ["https://tenant-backup.example.net"],
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
			"im_api": .init(
				preferred: ["https://im-primary.example.com"], backups: imBackups,
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
			"im_realtime": .init(
				preferred: [realtimePreferred], backups: [realtimeBackup],
				preferredSource: "tenant_deployment_authority", backupSource: "tenant_deployment_backup"
			),
		]
		let unsigned = IMRuntimeRouteSnapshot(
			contractVersion: 2, appID: IMAPIContext.normalizedIOSAppID("ios-main"), tenantID: tenantID, revision: revision,
			source: "tenant_entry", status: "ready", configHash: String(repeating: "0", count: 64),
			services: services, policy: IMRuntimeRoutePolicy()
		)
		return IMRuntimeRouteSnapshot(
			contractVersion: unsigned.contractVersion, appID: unsigned.appID, tenantID: unsigned.tenantID,
			revision: unsigned.revision, source: unsigned.source, status: unsigned.status,
			configHash: unsigned.recomputedConfigHash!, services: services, policy: unsigned.policy
		)
	}

	func invalidatePersistedCurrentRouteAuthority(_ defaults: UserDefaults) throws {
		let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("wxt.runtime.routes.v2.") })
		let encoded = try XCTUnwrap(defaults.data(forKey: key))
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		var current = try XCTUnwrap(object["current"] as? [String: Any])
		var services = try XCTUnwrap(current["services"] as? [String: Any])
		var tenantAPI = try XCTUnwrap(services["tenant_api"] as? [String: Any])
		tenantAPI["preferred_source"] = "app_preferred"
		services["tenant_api"] = tenantAPI
		current["services"] = services
		object["current"] = current
		defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
	}

    func appBootstrapForHTTPWiring(
        platformBase: String,
        platformBackups: [String] = [],
        legal: RemoteAppBootstrap.Legal = .init()
    ) -> RemoteAppBootstrap {
        let services: [String: IMRuntimeRouteEndpointSet] = [
            IMRuntimeRouteService.platformAPI.rawValue: .init(
                preferred: [platformBase], backups: platformBackups, status: "ready",
                preferredSource: "app_preferred", backupSource: "common_platform_backup"
            ),
            IMRuntimeRouteService.tenantAPI.rawValue: .init(
                preferred: ["https://tenant-bootstrap.example.test"], backups: [], status: "ready",
                preferredSource: "app_preferred", backupSource: "common_platform_backup"
            ),
            IMRuntimeRouteService.imAPI.rawValue: .init(
                preferred: ["https://im-bootstrap.example.test"], backups: [], status: "ready",
                preferredSource: "app_preferred", backupSource: "common_platform_backup"
            ),
            IMRuntimeRouteService.imRealtime.rawValue: .init(
                preferred: ["wss://realtime-bootstrap.example.test"], backups: [], status: "ready",
                preferredSource: "app_preferred", backupSource: "common_platform_backup"
            )
        ]
        let preferred = services.mapValues(\.preferred)
        let policy = IMRuntimeRoutePolicy()
        let unsigned = IMRuntimeRouteSnapshot(
            contractVersion: 2,
            appID: IMAPIContext.canonicalIOSAppID,
            tenantID: nil,
            revision: 1,
            source: "app_bootstrap",
            status: "ready",
            configHash: String(repeating: "0", count: 64),
            services: services,
            policy: policy,
            hashScope: .appBootstrap,
            bootstrapHost: "app-test.example.test",
            preferredEndpoints: preferred
        )
        return RemoteAppBootstrap(
            appID: IMAPIContext.canonicalIOSAppID,
            platform: "ios",
            status: "enabled",
            bootstrapHost: "app-test.example.test",
            appDomain: "app-test.example.test",
            configVersion: "boot-v2",
            ttlSeconds: 300,
            directory: .init(apiBaseURL: platformBase),
            legal: legal,
            configHash: unsigned.recomputedConfigHash!,
            contractVersion: 2,
            routeRevision: 1,
            routeSource: "app_bootstrap",
            routeStatus: "ready",
            routes: services,
            preferredEndpoints: preferred,
            routingPolicy: policy
        )
    }

    func isolatedRuntimeRouteStore() -> IMRuntimeRouteStore {
        let defaults = UserDefaults(suiteName: "HTTPTransportTests.routes.\(UUID().uuidString)")!
        return IMRuntimeRouteStore(defaults: defaults)
    }

    func apiSuccessResult<T: Encodable>(_ value: T) throws -> HTTPTransportResult {
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": object])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

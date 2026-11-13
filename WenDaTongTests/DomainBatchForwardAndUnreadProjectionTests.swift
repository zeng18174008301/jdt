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
    func testLogoutScopeChangeClearsIdleBatchForwardDraftBeforeConversationIDReuse() {
        let state = AppState(
            api: makeCallEndingAPI(
                transport: FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
            ),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var source = makeConversation(
            id: "reused-conversation",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(
            id: "source-before-logout",
            senderId: "uid-1",
            seq: 1,
            isOutgoing: true
        )
        message.senderProvenance = .authoritativeStored
        source.messages = [message]
        state.conversationStore.commitConversationSnapshots([source])
        state.tenantInteractionStore.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.actions.forwardEnabled = true // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_BEGIN
        var selections: [Set<String>] = []
        let observation = state.batchForwardStore.selectionUpdates(for: source.id).sink { selections.append($0.ids) }
        defer { observation.cancel() }
        // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_END
        state.beginBatchForward(
            conversationID: source.id,
            initialMessageID: message.id
        )

        XCTAssertNotNil(state.batchForwardState)
        XCTAssertEqual(state.batchForwardSourceConversationID, source.id)

        state.logout()

        var reused = source
        reused.messages = [
            makeMessage(
                id: "source-after-logout",
                senderId: "different-scope-user",
                seq: 1
            )
        ]
        state.conversationStore.commitConversationSnapshots([reused])
        state.refreshBatchForwardContext(conversationID: reused.id)

        XCTAssertNil(state.batchForwardState)
        XCTAssertNil(state.batchForwardSourceConversationID)
        XCTAssertEqual(selections, [[], [message.id], []]) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    func testLogoutKeepsFailClosedCleanupFailureVisible() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logout-cleanup-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"),
            forceCleanupTombstoneFailureForTesting: true,
            forceScopeCleanupFallbackFailureForTesting: true
        )
        let state = AppState(
            api: makeCallEndingAPI(
                transport: FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
            ),
            voiceMediaClient: NoopVoiceMediaClient(),
            messagePersistence: persistence,
            protectedSessionStore: IMKeychainSessionStore(
                simulatorFileURL: root.appendingPathComponent("session.json")
            ),
            apiContextOverride: makeAuthenticatedAPIContext()
        )

        state.logout()

        XCTAssertEqual(
            state.toast,
            "本机数据安全清理失败，已阻止旧作用域缓存访问"
        )
    }

    func testLogoutScopeChangeCancelsSubmittingBatchForwardRequestAndClearsDraft() async {
        let transport = BatchForwardLifecycleHTTPTransport(
            behavior: .waitForCancellation
        )
        let state = AppState(
            api: makeCallEndingAPI(
                transport: transport
            ),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var source = makeConversation(
            id: "batch-source",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(
            id: "source-message",
            senderId: "uid-1",
            seq: 1,
            isOutgoing: true
        )
        message.senderProvenance = .authoritativeStored
        source.messages = [message]
        let target = makeConversation(
            id: "batch-target",
            kind: .group,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )
        state.conversationStore.commitConversationSnapshots([source, target])
        state.tenantInteractionStore.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.actions.forwardEnabled = true // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.beginBatchForward(
            conversationID: source.id,
            initialMessageID: message.id
        )
        state.toggleBatchForwardTarget(target)
        state.submitBatchForward()

        for _ in 0..<100 where !transport.didStartForwardRequest {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(transport.didStartForwardRequest)
        guard case .submitting = state.batchForwardState?.submissionPhase else {
            XCTFail("expected submitting batch-forward draft")
            return
        }

        state.logout()

        XCTAssertNil(state.batchForwardState)
        XCTAssertNil(state.batchForwardSourceConversationID)
        for _ in 0..<100 where !transport.didObserveCancellation {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(transport.didObserveCancellation)
    }

    func testSourceConversationExitCancelsAndFencesLateBatchForwardCompletion() async {
        let transport = BatchForwardLifecycleHTTPTransport(
            behavior: .returnCommittedAfterCancellation
        )
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var source = makeConversation(
            id: "source-conversation",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(
            id: "source-message",
            senderId: "uid-1",
            seq: 1,
            isOutgoing: true
        )
        message.senderProvenance = .authoritativeStored
        source.messages = [message]
        let target = makeConversation(
            id: "target-conversation",
            kind: .group,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )
        state.conversationStore.commitConversationSnapshots([source, target])
        state.tenantInteractionStore.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.actions.forwardEnabled = true // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.beginBatchForward(
            conversationID: source.id,
            initialMessageID: message.id
        )
        state.toggleBatchForwardTarget(target)
        state.submitBatchForward()

        for _ in 0..<100 where !transport.didStartForwardRequest {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        state.leaveBatchForwardSourceConversation(source.id)
        for _ in 0..<100 where !transport.didReturnForwardResponse {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(transport.didObserveCancellation)
        XCTAssertTrue(transport.didReturnForwardResponse)
        XCTAssertNil(state.batchForwardState)
        XCTAssertNil(state.batchForwardSourceConversationID)
        XCTAssertNotEqual(state.toast, "已转发 1 条消息到 1 个会话")
    }

    func testBatchForwardCandidatesIncludeFriendAndGroupWithoutExistingConversationAndAllowSourceTarget() {
        let state = AppState(
            api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let friend = makeUser(id: "friend-no-chat", name: "未聊好友")
        state.contacts = [friend]
        let sourceGroup = GroupInfo(
            id: "source-group",
            name: "来源群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false
        )
        let groupWithoutConversation = GroupInfo(
            id: "group-no-chat",
            name: "未聊群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false
        )
        state.groups = [sourceGroup, groupWithoutConversation]
        var source = makeConversation(
            id: sourceGroup.id,
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(
            id: "source-message",
            senderId: "uid-1",
            seq: 1,
            isOutgoing: true
        )
        message.senderProvenance = .authoritativeStored
        source.messages = [message]
        state.conversationStore.commitConversationSnapshots([source])

        state.tenantInteractionStore.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.actions.forwardEnabled = true // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.beginBatchForward(
            conversationID: source.id,
            initialMessageID: message.id
        )

        let candidates = state.batchForwardTargetCandidates()
        let keys = Set(candidates.map(\.identityKey))
        XCTAssertTrue(keys.contains("direct|friend-no-chat:uid-1"))
        XCTAssertTrue(keys.contains("group|group-no-chat"))
        XCTAssertTrue(keys.contains("group|source-group"))
        XCTAssertEqual(
            Set(state.batchForwardState.map {
                Array($0.targetsByIdentity.keys)
            } ?? []),
            keys
        )

        // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_BEGIN
        var sourceSelections: [Set<String>] = []
        var otherSelections: [Set<String>] = []
        var selectedTargetCounts: [Int] = []
        var appUpdates = 0
        let observations = [
            state.batchForwardStore.selectionUpdates(for: source.id).sink { sourceSelections.append($0.ids) },
            state.batchForwardStore.selectionUpdates(for: "different-chat").sink { otherSelections.append($0.ids) },
            state.batchForwardStore.draftUpdates(for: source.id).sink { selectedTargetCounts.append($0?.state.selectedTargets.count ?? 0) },
            state.objectWillChange.sink { appUpdates += 1 }
        ]
        defer { observations.forEach { $0.cancel() } }
        // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_END
        for key in [
            "direct|friend-no-chat:uid-1",
            "group|group-no-chat",
            "group|source-group"
        ] {
            let candidate = candidates.first { $0.identityKey == key }
            XCTAssertNotNil(candidate)
            if let candidate {
                state.toggleBatchForwardTarget(candidate.target)
            }
        }
        XCTAssertEqual(state.batchForwardState?.selectedTargets.count, 3)
        // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_BEGIN
        XCTAssertEqual(sourceSelections, [[message.id]])
        XCTAssertEqual(otherSelections, [[]])
        XCTAssertEqual(selectedTargetCounts, [0, 1, 2, 3])
        XCTAssertEqual(appUpdates, 0)
        // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_END

        // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
        var conversationOnly = makeConversation(
            id: "historical-peer:uid-1", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1
        )
        conversationOnly.messages = [message]
        state.conversationStore.mutateMessageSnapshotsForTesting { $0.append(conversationOnly) }
        let liveTargets = state.batchForwardTargetCandidates()
        XCTAssertTrue(liveTargets.contains { $0.identityKey == "direct|historical-peer:uid-1" })
        XCTAssertEqual(
            state.batchForwardTargetCandidates(from: state.conversationStore.conversationMessageSnapshots().map { ConversationMessageSnapshot(conversation: $0.conversation, messages: []) }),
            liveTargets
        )
        // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END

        // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110_BEGIN
        var publishedSource = source
        publishedSource.messages[0].status = .recalled
        state.refreshBatchForwardContext(
            conversationID: source.id,
            conversations: [publishedSource, conversationOnly]
        )
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .sent)
        XCTAssertEqual(state.batchForwardState?.sourcesByID[message.id]?.clientState, "recalled")
        // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110_END
    }

    func testConversationStoreMergeMappedRemoteMessagesPreservesSidecarStateAndAppliesReadSummary() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var previousMessage = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: true)
        previousMessage.reactions = [
            Reaction(id: "m1_ok", emoji: "ok", count: 2, reactedByMe: true)
        ]
        previousMessage.readBy = [makeReadReceipt(userID: "reader-1")]
        previousMessage.readCount = 2
        previousMessage.readStateKnown = true
        previous.messages = [previousMessage]
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "me",
          "content_type": "text",
          "payload": {},
          "status": "normal",
          "read_status": "read",
          "read_count": 3,
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote,
                    message: makeMessage(id: "m1", seq: 1, isOutgoing: true),
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: true,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: false
        )

        let updated = try XCTUnwrap(result.messages.first)
        XCTAssertEqual(updated.status, .read)
        XCTAssertEqual(updated.readCount, 3)
        XCTAssertTrue(updated.readStateKnown)
        XCTAssertEqual(updated.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(updated.reactions, previousMessage.reactions)
    }

    func testConversationStoreMergeMappedRemoteMessagesRetainsLatestTailWindowAndPinnedContext() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 8, lastReadSeq: 8)
        var pinnedContext = makeMessage(id: "pinned-context", seq: 2, text: "old pinned")
        pinnedContext.isPinned = true
        pinnedContext.isPinnedContextOnly = true
        previous.messages = [pinnedContext] + (1...8).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        } + [
            makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "pending")
        ]
        let remote9 = try decodeRemoteMessage("""
        {"message_id":"m9","channel_id":"c1","channel_type":"group","channel_seq":9,"from_uid":"u9","content_type":"text","payload":{"text":"nine"},"status":"sent"}
        """)
        let remote10 = try decodeRemoteMessage("""
        {"message_id":"m10","channel_id":"c1","channel_type":"group","channel_seq":10,"from_uid":"u10","content_type":"text","payload":{"text":"ten"},"status":"sent"}
        """)

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote9,
                    message: makeMessage(id: "m9", seq: 9),
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                ),
                ConversationStore.MappedRemoteMessage(
                    remote: remote10,
                    message: makeMessage(id: "m10", seq: 10),
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: false,
            windowRetention: .latestTail(limit: 5)
        )

        XCTAssertEqual(
            result.messages.map(\.id),
            ["local_1", "pinned-context", "m6", "m7", "m8", "m9", "m10"]
        )
        XCTAssertEqual(result.latestKnownSeq, 10)
        XCTAssertEqual(result.latestMessage?.id, "m10")
    }

    func testConversationStoreTrimConversationToLatestWindowKeepsPendingAndPinnedContext() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 8, lastReadSeq: 8)
        var pinnedContext = makeMessage(id: "pinned-context", seq: 2, text: "old pinned")
        pinnedContext.isPinned = true
        pinnedContext.isPinnedContextOnly = true
        conversation.messages = [pinnedContext] + (1...8).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        } + [
            makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "pending")
        ]
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.trimConversationToLatestWindow(conversationID: "c1", limit: 3))

        XCTAssertEqual(
            store.conversationMessageSnapshots()[0].messages.map(\.id),
            ["local_1", "pinned-context", "m6", "m7", "m8"]
        )
    }

    func testConversationStoreMergeMappedRemoteMessagesTracksIncomingRealtimeOnlyForNewRemoteMessages() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        previous.messages = [
            makeMessage(id: "m1", seq: 1)
        ]
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m2",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 2,
          "from_uid": "other",
          "content_type": "text",
          "payload": {},
          "status": "normal",
          "created_at": "2026-06-23T10:01:00Z"
        }
        """)

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote,
                    message: makeMessage(id: "m2", seq: 2, isOutgoing: false),
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: true
        )

        XCTAssertEqual(result.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(result.incomingRealtimeMessages.map(\.id), ["m2"])
        XCTAssertEqual(result.latestKnownSeq, 2)
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationIncrementsUnreadAndFlagsSoundForInactiveRealtime() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        previous.time = "09:59"
        previous.sortTimestamp = 100
        previous.messages = [makeMessage(id: "m1", seq: 1)]
        store.commitConversationSnapshots([previous])

        var latest = makeMessage(id: "m2", seq: 2, isOutgoing: false, text: "hello", time: "10:01")
        latest.createdAt = Date(timeIntervalSince1970: 200)
        let result = store.applyMergedRemoteMessagesConversation(
            channelID: "remote-c1",
            kind: .group,
            previous: previous,
            title: "Group",
            subtitle: "群聊",
            participants: [],
            messages: [previous.messages[0], latest],
            latestMessage: latest,
            incomingRealtimeMessages: [latest],
            latestKnownSeq: 2,
            fromRealtime: true,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 8,
            accentHex: 42,
            avatarURL: "https://example.com/avatar.png",
            avatarVersion: "v2",
            avatarUpdatedAt: "2026-06-23T10:01:00Z"
        )

        XCTAssertEqual(result.conversation.id, "c1")
        XCTAssertEqual(result.conversation.unread, 2)
        XCTAssertEqual(result.conversation.time, "10:01")
        XCTAssertEqual(result.conversation.sortTimestamp, 200)
        XCTAssertEqual(result.conversation.lastMsgSeq, 2)
        XCTAssertEqual(result.conversation.memberCount, 8)
        XCTAssertEqual(result.conversation.avatarVersion, "v2")
        XCTAssertEqual(result.incomingRealtimeMessages.map(\.id), ["m2"])
        XCTAssertTrue(result.shouldPlayIncomingSound)
        XCTAssertFalse(result.shouldAutoRead)
        XCTAssertEqual(store.conversationMessageSnapshots().first?.id, "c1")
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationAutoReadsActiveRealtimeAndUpdatesPulledLatest() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        previous.time = "09:59"
        previous.sortTimestamp = 500
        previous.messages = [makeMessage(id: "m1", seq: 1)]
        store.commitConversationSnapshots([previous])

        var realtimeLatest = makeMessage(id: "m2", seq: 2, isOutgoing: false, text: "active", time: "10:01")
        realtimeLatest.createdAt = Date(timeIntervalSince1970: 600)
        let realtimeResult = store.applyMergedRemoteMessagesConversation(
            channelID: "c1",
            kind: .group,
            previous: previous,
            title: "Group",
            subtitle: "群聊",
            participants: [],
            messages: [previous.messages[0], realtimeLatest],
            latestMessage: realtimeLatest,
            incomingRealtimeMessages: [realtimeLatest],
            latestKnownSeq: 2,
            fromRealtime: true,
            isActiveRealtimeConversation: true,
            canAutoReadActiveRealtimeConversation: true,
            memberCount: 2,
            accentHex: 42,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(realtimeResult.conversation.unread, 0)
        XCTAssertTrue(realtimeResult.shouldAutoRead)
        XCTAssertFalse(realtimeResult.shouldPlayIncomingSound)

        var historyPrevious = makeConversation(id: "c2", kind: .direct, unread: 3, lastMsgSeq: 10, lastReadSeq: 7)
        historyPrevious.time = "昨天"
        historyPrevious.sortTimestamp = 1_000
        historyPrevious.messages = [makeMessage(id: "h1", seq: 10, text: "old")]
        store.commitConversationSnapshots([historyPrevious])
        var historyLatest = makeMessage(id: "h2", seq: 11, text: "newer history", time: "今天")
        historyLatest.createdAt = Date(timeIntervalSince1970: 2_000)

        let historyResult = store.applyMergedRemoteMessagesConversation(
            channelID: "c2",
            kind: .direct,
            previous: historyPrevious,
            title: "Direct",
            subtitle: "单聊",
            participants: [],
            messages: [historyPrevious.messages[0], historyLatest],
            latestMessage: historyLatest,
            incomingRealtimeMessages: [],
            latestKnownSeq: 11,
            fromRealtime: false,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 0,
            accentHex: 7,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(historyResult.conversation.unread, 3)
        XCTAssertEqual(historyResult.conversation.lastMessage, "newer history")
        XCTAssertEqual(historyResult.conversation.time, "今天")
        XCTAssertEqual(historyResult.conversation.sortTimestamp, 2_000)
        XCTAssertFalse(historyResult.shouldAutoRead)
        XCTAssertFalse(historyResult.shouldPlayIncomingSound)
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationPreservesDirectPeerIdentityWhenProjectionIsBlank() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let currentUser = makeUser(id: "current-user", name: "Current User")
        let peer = makeUser(id: "peer-user", name: "Known Peer")
        var previous = makeConversation(id: "current-user:peer-user", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        previous.title = peer.name
        previous.participants = [currentUser, peer]
        previous.messages = [makeMessage(id: "m1", seq: 1)]
        store.commitConversationSnapshots([previous])

        let result = store.applyMergedRemoteMessagesConversation(
            channelID: previous.id,
            kind: .direct,
            previous: previous,
            title: "  ",
            subtitle: "单聊",
            participants: [],
            messages: previous.messages,
            latestMessage: previous.messages[0],
            incomingRealtimeMessages: [],
            latestKnownSeq: 1,
            fromRealtime: false,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 0,
            accentHex: 7,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(result.conversation.title, "Known Peer")
        XCTAssertEqual(result.conversation.participants.map(\.id), ["current-user", "peer-user"])
    }

    // WDT_CHAT_UNREAD_BADGE_20261021_BEGIN
    func testRepeatedConfirmedTailAckClearsStaleUnreadWithoutTouchingOtherConversations() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "read", unread: 4, lastMsgSeq: 3, lastReadSeq: 3)
        conversation.messages = (1...3).map { makeMessage(id: "m\($0)", seq: Int64($0), isOutgoing: $0 > 1) }
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        let other = makeConversation(id: "other", unread: 7, lastMsgSeq: 9, lastReadSeq: 2)
        store.commitConversationSnapshots([conversation, other])
        var publications = 0
        let observation = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { _ in publications += 1 } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        defer { observation.cancel() }

        store.advanceRead(conversationID: "read", through: 3)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastReadSeq, 3)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadSeq, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadMessageID, "")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorSeq, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorState, "none")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages, conversation.messages)
        XCTAssertEqual(store.conversationMessageSnapshots()[1], other)
        let settledPublications = publications
        store.advanceRead(conversationID: "read", through: 3)
        XCTAssertEqual(publications, settledPublications)
    }

    func testRepeatedAckDoesNotClearNewIncomingOrCrossCoverageGap() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "read", unread: 4, lastMsgSeq: 5, lastReadSeq: 3)
        conversation.messages = (1...5).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        store.commitConversationSnapshots([conversation])
        store.advanceRead(conversationID: "read", through: 3)
        XCTAssertEqual(store.conversationMessageSnapshots()[0], conversation)
        store.advanceRead(conversationID: "read", through: 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0], conversation)

        conversation.messageCoveredThroughSeq = 3
        conversation.messageCoverageRequiresRecovery = true
        conversation.messages.removeAll { $0.channelSeq == 4 }
        store.commitConversationSnapshots([conversation])
        store.advanceRead(conversationID: "read", through: 5)
        XCTAssertEqual(store.conversationMessageSnapshots()[0], conversation)

        conversation.messageCoveredThroughSeq = 0
        conversation.lastReadSeq = 0
        store.commitConversationSnapshots([conversation])
        store.advanceRead(conversationID: "read", through: 5)
        XCTAssertEqual(store.conversationMessageSnapshots()[0], conversation)
    }

    func testRepeatedTailAckPreservesUnacknowledgedReactionState() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "reactions", unread: 4, lastMsgSeq: 3, lastReadSeq: 3)
        conversation.messages = (1...3).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        conversation.hasUnreadReaction = true
        conversation.unreadReactionCount = 4
        store.commitConversationSnapshots([conversation])
        store.advanceRead(conversationID: conversation.id, through: 3)
        XCTAssertEqual(store.conversationMessageSnapshots()[0], conversation)
    }
    // WDT_CHAT_UNREAD_BADGE_20261021_END

    func testCachedConversationsApplyConfirmedReadsBeforePublishingUnreadBadges() {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeAuthenticatedAPIContext())
        var stale = makeConversation(id: "cached-group", kind: .group, unread: 2, lastMsgSeq: 2, lastReadSeq: 0)
        stale.hasUnreadReaction = false
        stale.unreadReactionCount = 0
        stale.messageCoverageRequiresRecovery = true
        var newer = makeConversation(id: "newer-group", kind: .group, unread: 3, lastMsgSeq: 3, lastReadSeq: 0)
        newer.hasUnreadReaction = false
        newer.unreadReactionCount = 0
        newer.messages = (1...3).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        let projected = state.cachedConversationsApplyingConfirmedReads(
            [stale, newer],
            confirmedReads: [stale.id: 2, newer.id: 2]
        )

        XCTAssertEqual(projected.map(\.lastReadSeq), [2, 2])
        XCTAssertEqual(projected.map(\.unread), [0, 1])
        XCTAssertEqual(projected[1].firstUnreadSeq, 3)
    }

    func testCachedConversationDoesNotRestoreOldUnreadCountWithoutSeparateAck() {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeAuthenticatedAPIContext())
        var read = makeConversation(id: "read", kind: .group, unread: 150, lastMsgSeq: 300, lastReadSeq: 300)
        read.hasUnreadReaction = false
        read.unreadReactionCount = 0
        var newer = makeConversation(id: "newer", kind: .group, unread: 150, lastMsgSeq: 302, lastReadSeq: 300)
        newer.hasUnreadReaction = false
        newer.unreadReactionCount = 0
        var reaction = read
        reaction.hasUnreadReaction = true
        reaction.unreadReactionCount = 1

        let projected = state.cachedConversationsApplyingConfirmedReads([read, newer, reaction], confirmedReads: [:])

        XCTAssertEqual(projected.map(\.unread), [0, 2, 1])
        XCTAssertEqual(projected[0].unreadAnchorState, "none")
        XCTAssertTrue(projected[2].hasUnreadReaction)
    }

    func testConversationStoreAdvanceReadPreservesTailAcrossCoverageGapAndConvergesAfterRecovery() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "gap", kind: .group, unread: 3, lastMsgSeq: 4, lastReadSeq: 0)
        conversation.messages = [1, 2, 4].map { makeMessage(id: "m\($0)", seq: Int64($0), isOutgoing: false) }
        conversation.messageCoveredThroughSeq = 2
        conversation.messageCoverageRequiresRecovery = true
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.firstUnreadSeq = 1
        conversation.firstUnreadMessageID = "m1"
        conversation.unreadAnchorSeq = 1
        conversation.unreadAnchorState = "resolved"
        store.commitConversationSnapshots([conversation])

        store.advanceRead(conversationID: conversation.id, through: 4)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastReadSeq, 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadSeq, 4)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorSeq, 4)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorState, "resolved")

        store.advanceRead(conversationID: conversation.id, through: 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadSeq, 4)

        store.mutateStoredConversation(at: 0) { $0.messages.insert(makeMessage(id: "m3", seq: 3, isOutgoing: false), at: 2) }
        store.mutateStoredConversation(at: 0) { $0.messageCoveredThroughSeq = 4 }
        store.mutateStoredConversation(at: 0) { $0.messageCoverageRequiresRecovery = false }
        store.advanceRead(conversationID: conversation.id, through: 4)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastReadSeq, 4)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].firstUnreadSeq, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadAnchorState, "none")
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

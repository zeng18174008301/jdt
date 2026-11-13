import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong
@testable import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110

extension DomainStoreTests {
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    func testConversationGroupObserversPreserveExactAndAliasOrderWithoutGlobalRefresh() {
        var conversation = makeConversation(id: "local-id", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        conversation.title = "Shared title"
        let conversationStore = ConversationStore(scope: TestMessageMemoryScope.value)
        conversationStore.commitConversationSnapshots([conversation])
        let state = AppState(conversationStore: conversationStore, apiContextOverride: TestMessageMemoryScope.context)
        let store = state.contactStore
        let selectors = state.groupObservationSelectors(conversationID: conversation.id)
        func group(_ id: String, name: String) -> GroupInfo {
            GroupInfo(id: id, name: name, notice: "", owner: "", members: [], admins: [], muted: false, allMuted: false)
        }
        var updates: [[String?]] = []
        var globalUpdates = 0
        let groupObserver = store.groupUpdates(matching: selectors).sink { updates.append($0.map { $0?.id }) }
        let globalObserver = state.objectWillChange.sink { globalUpdates += 1 }
        defer {
            groupObserver.cancel()
            globalObserver.cancel()
        }

        let alias = group("remote-id", name: "Shared title")
        let exact = group("local-id", name: "Exact")
        store.groups = [alias, exact]
        XCTAssertEqual(state.group(for: conversation)?.id, "remote-id")
        XCTAssertEqual(updates.last, ["local-id", "remote-id"])
        store.groups.append(group("unrelated", name: "Other"))
        XCTAssertEqual(updates.count, 2)
        store.groups.removeFirst()
        XCTAssertEqual(state.group(for: conversation)?.id, "local-id")
        XCTAssertEqual(updates.last, ["local-id", "local-id"])

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(globalUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    func testMountedGroupSnapshotRefreshesOnlyTheSelectedGroup() {
        let store = ContactStore()
        func group(_ id: String, name: String) -> GroupInfo {
            GroupInfo(id: id, name: name, notice: "", owner: "", members: [], admins: [], muted: false, allMuted: false)
        }
        store.groups = [group("selected", name: "Before")]
        var renderedNames: [String?] = []
        func content() -> some View {
            let name = store.groups.first { $0.id == "selected" }?.name
            renderedNames.append(name)
            return Text(name ?? "无群资料")
        }
        let hosted = hostForSimulatorUI(
            GroupSnapshotView(store: store, groupID: "selected", content: content),
            size: CGSize(width: 320, height: 80)
        )
        defer { hosted.window.isHidden = true }
        func renderPendingChanges() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosted.controller.view.layoutIfNeeded()
        }
        let initialCount = renderedNames.count
        XCTAssertEqual(renderedNames.last ?? nil, "Before")
        store.groups.append(group("other", name: "Other"))
        renderPendingChanges()
        XCTAssertEqual(renderedNames.count, initialCount)
        store.groups[0] = group("selected", name: "After")
        renderPendingChanges()
        XCTAssertEqual(renderedNames.last ?? nil, "After")
        store.groups.removeFirst()
        renderPendingChanges()
        XCTAssertNil(renderedNames.last ?? nil)
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    func testAppStateFailedQueuedReadAckPersistsAndRetriesTheSameTailToSuccess() async throws {
        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-ack-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: persistenceRoot.appendingPathComponent("Application Support", isDirectory: true),
            cachesBase: persistenceRoot.appendingPathComponent("Caches", isDirectory: true)
        )
        let gate = FirstReadAckSuspensionGate()
        let transport = ReadAckCoalescingHTTPTransport(
            firstRequestGate: gate,
            failSecondRequest: true
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
            messagePersistence: persistence,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        var conversation = makeConversation(
            id: "read-convergence-group",
            kind: .group,
            unread: 1,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        conversation.messages = [
            makeMessage(id: "incoming-1", senderId: "peer-1", seq: 1, kind: .text)
        ]
        conversation.messageCoveredThroughSeq = 1
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        state.conversationStore.commitConversationSnapshots([conversation])

        state.markConversationRead(conversation.id, showToast: false)
        for _ in 0..<80 {
            if await gate.isWaiting() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let firstRequestIsWaiting = await gate.isWaiting()
        XCTAssertTrue(firstRequestIsWaiting)

        conversation.messages.append(
            makeMessage(id: "incoming-2", senderId: "peer-1", seq: 2, kind: .text)
        )
        conversation.lastMsgSeq = 2
        conversation.unread = 2
        conversation.messageCoveredThroughSeq = 2
        state.conversationStore.commitConversationSnapshots([conversation])
        state.markConversationRead(conversation.id, showToast: false)

        await gate.resumeFirst()
        let syncKey = "group|read-convergence-group"
        for _ in 0..<120 {
            if transport.requestedSequences().count == 2,
               !state.conversationStore.isReadAckSyncInFlight(syncKey: syncKey) {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(transport.requestedSequences(), [1, 2])
        let refreshed = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first(where: { $0.id == conversation.id }))
        XCTAssertEqual(refreshed.lastReadSeq, 1)
        XCTAssertEqual(refreshed.unread, 1)
        XCTAssertEqual(refreshed.firstUnreadSeq, 2)
        XCTAssertEqual(
            state.conversationStore.locallyReadSeq(forKey: syncKey),
            1,
            "failed ack2 must not advance the local authoritative high-water"
        )

        try await Task.sleep(nanoseconds: 1_100_000_000)
        await state.recoverDurableReadAcksForTesting()

        XCTAssertEqual(transport.requestedSequences(), [1, 2, 2])
        let recovered = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first(where: { $0.id == conversation.id }))
        XCTAssertEqual(recovered.lastReadSeq, 2)
        XCTAssertEqual(recovered.unread, 0)
        XCTAssertEqual(state.conversationStore.locallyReadSeq(forKey: syncKey), 2)
    }

    func testDurableReadAckRecoveryIsSingleFlightAndBackgroundStopsBeforeClaimingNextRow() async throws {
        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-ack-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: persistenceRoot.appendingPathComponent("Application Support", isDirectory: true),
            cachesBase: persistenceRoot.appendingPathComponent("Caches", isDirectory: true)
        )
        let gate = FirstReadAckSuspensionGate()
        let transport = LifecycleReadAckHTTPTransport(suspendedRequestNumber: 3, gate: gate)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = makeAuthenticatedAPIContext()
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            messagePersistence: persistence,
            apiContextOverride: context
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        var first = makeConversation(
            id: "lifecycle-a",
            kind: .group,
            unread: 1,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        first.messages = [makeMessage(id: "lifecycle-a-1", senderId: "peer-1", seq: 1, kind: .text)]
        first.messageCoveredThroughSeq = 1
        var second = makeConversation(
            id: "lifecycle-b",
            kind: .group,
            unread: 1,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        second.messages = [makeMessage(id: "lifecycle-b-1", senderId: "peer-1", seq: 1, kind: .text)]
        second.messageCoveredThroughSeq = 1
        state.conversationStore.commitConversationSnapshots([first, second])

        var firstCompleted: Bool?
        state.markConversationRead(first.id, showToast: false) { firstCompleted = $0 }
        for _ in 0..<120 where firstCompleted == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(firstCompleted, false)

        var secondCompleted: Bool?
        state.markConversationRead(second.id, showToast: false) { secondCompleted = $0 }
        for _ in 0..<120 where secondCompleted == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(secondCompleted, false)
        XCTAssertEqual(transport.requestCount(), 2)

        state.iosRiskTelemetrySceneDidBecomeAvailable(isActive: true)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let firstTrigger = Task { await state.recoverDurableReadAcksForTesting(requiresActiveScene: true) }
        for _ in 0..<120 {
            if await gate.isWaiting() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let recoveryRequestIsWaiting = await gate.isWaiting()
        XCTAssertTrue(recoveryRequestIsWaiting)
        let secondTrigger = Task { await state.recoverDurableReadAcksForTesting(requiresActiveScene: true) }
        let thirdTrigger = Task { await state.recoverDurableReadAcksForTesting(requiresActiveScene: true) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(transport.requestCount(), 3, "multiple recovery triggers must share one consumer")

        state.appDidEnterBackground()
        await gate.resumeFirst()
        await firstTrigger.value
        await secondTrigger.value
        await thirdTrigger.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.requestCount(), 3, "background transition must stop before the next row is sent")

        let ticket = try await persistence.ensureTicket(context: context, sessionGeneration: 1)
        let states = try await persistence.ackStates(ticket: ticket, type: "read")
        let attemptsByChannel = Dictionary(uniqueKeysWithValues: states.map { ($0.channelID, $0.attemptCount) })
        XCTAssertEqual(attemptsByChannel["lifecycle-a"], 2)
        XCTAssertEqual(
            attemptsByChannel["lifecycle-b"],
            1,
            "the unsent second row must not consume retry budget while backgrounded"
        )
    }

    func testConversationStoreRemoveDirectConversationsMatchesPeerIDFromResolverParticipantsAndChannelParts() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var participantMatch = makeConversation(id: "direct_participant", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        participantMatch.participants = [makeUser(id: "peer-1")]
        var retainedDirect = makeConversation(id: "direct_retained", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        retainedDirect.participants = [makeUser(id: "peer-2")]
        var retainedGroup = makeConversation(id: "group:peer-1", kind: .group, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        retainedGroup.participants = [makeUser(id: "peer-1")]
        store.commitConversationSnapshots([
            makeConversation(id: "direct_resolver", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0),
            participantMatch,
            makeConversation(id: "tenant:peer-1", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0),
            retainedDirect,
            retainedGroup
        ])

        store.removeDirectConversations(peerID: " peer-1 ") { conversation in
            conversation.id == "direct_resolver" ? "peer-1" : nil
        }

        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["direct_retained", "group:peer-1"])
    }

    func testConversationStoreRemoveDirectConversationsIgnoresEmptyPeerID() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "tenant:peer-1", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        ])

        store.removeDirectConversations(peerID: "  ") { _ in "peer-1" }

        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["tenant:peer-1"])
    }

    func testConversationStoreMarkDirectConversationUnavailableSetsContextMessagesAndListState() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var direct = makeConversation(id: "direct-1", kind: .direct, unread: 3, lastMsgSeq: 4, lastReadSeq: 0)
        direct.subtitle = "可发送"
        let group = makeConversation(id: "group-1", kind: .group, unread: 2, lastMsgSeq: 4, lastReadSeq: 0)
        store.commitConversationSnapshots([direct, group])
        let context = DirectFriendRequestContext(
            targetUID: "peer-1",
            canApplyFriend: false,
            friendRequestStatus: "pending",
            reasonCode: "friendship_required"
        )

        store.markDirectConversationUnavailable(direct, context: context)

        XCTAssertEqual(store.directFriendRequestContext(conversationID: "direct-1")?.targetUID, "peer-1")
        XCTAssertEqual(store.directDisabledMessage(conversationID: "direct-1"), FriendAddPresentation.sentMessage)
        XCTAssertEqual(store.historyMessage(conversationID: "direct-1"), FriendAddPresentation.sentMessage)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].subtitle, "需要好友关系")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].id, "group-1")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].unread, 2)
    }

    func testConversationStoreMarkDirectConversationUnavailableIgnoresNonDirectConversation() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let group = makeConversation(id: "group-1", kind: .group, unread: 2, lastMsgSeq: 4, lastReadSeq: 0)
        store.commitConversationSnapshots([group])
        let context = DirectFriendRequestContext(
            targetUID: "peer-1",
            canApplyFriend: nil,
            friendRequestStatus: "",
            reasonCode: "friendship_required"
        )

        store.markDirectConversationUnavailable(group, context: context, fallbackMessage: "fallback")

        XCTAssertNil(store.directFriendRequestContext(conversationID: "group-1"))
        XCTAssertNil(store.directDisabledMessage(conversationID: "group-1"))
        XCTAssertNil(store.historyMessage(conversationID: "group-1"))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 2)
    }

    func testConversationStoreDeleteConversationRemovesTargetAndReturnsRemovedConversation() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2),
            makeConversation(id: "target", kind: .direct, unread: 3, lastMsgSeq: 5, lastReadSeq: 1),
            makeConversation(id: "newer", kind: .group, unread: 1, lastMsgSeq: 8, lastReadSeq: 7)
        ])

        let removed = store.deleteConversation(conversationID: " target ")

        XCTAssertEqual(removed?.id, "target")
        XCTAssertEqual(removed?.title, "target")
        XCTAssertEqual(removed?.unread, 3)
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["older", "newer"])
    }

    func testConversationStoreDeleteConversationSkipsInvalidOrMissingTarget() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2),
            makeConversation(id: "newer", kind: .group, unread: 1, lastMsgSeq: 8, lastReadSeq: 7)
        ])

        XCTAssertNil(store.deleteConversation(conversationID: "   "))
        XCTAssertNil(store.deleteConversation(conversationID: "missing"))
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["older", "newer"])
    }

    func testConversationStoreHydrateCachedConversationsReplacesListAndReturnsCount() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "old", kind: .direct, unread: 1, lastMsgSeq: 4, lastReadSeq: 3)
        ])

        let count = store.hydrateCachedConversations([
            makeConversation(id: "cached-1", kind: .direct, unread: 2, lastMsgSeq: 5, lastReadSeq: 4),
            makeConversation(id: "cached-2", kind: .group, unread: 0, lastMsgSeq: 9, lastReadSeq: 9)
        ])

        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["cached-1", "cached-2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].kind, .group)
    }

    func testConversationStoreHydrateCachedConversationsDropsDuplicateConversationIDs() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var olderDuplicate = makeConversation(id: "cached", kind: .group, unread: 1, lastMsgSeq: 2, lastReadSeq: 1)
        olderDuplicate.sortTimestamp = 100
        var newerDuplicate = makeConversation(id: "cached", kind: .group, unread: 9, lastMsgSeq: 8, lastReadSeq: 7)
        newerDuplicate.sortTimestamp = 300

        let count = store.hydrateCachedConversations([
            olderDuplicate,
            newerDuplicate,
            makeConversation(id: "other", kind: .direct, unread: 0, lastMsgSeq: 4, lastReadSeq: 4)
        ])

        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["cached", "other"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 9)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMsgSeq, 8)
    }

    func testConversationStoreHydrateCachedConversationsPreservesRuntimeReadState() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "old", kind: .direct, unread: 1, lastMsgSeq: 4, lastReadSeq: 3)
        ])
        store.rememberRead(key: "read-key", readSeq: 7)

        let count = store.hydrateCachedConversations([
            makeConversation(id: "cached", kind: .direct, unread: 0, lastMsgSeq: 8, lastReadSeq: 8)
        ])

        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["cached"])
        XCTAssertEqual(store.locallyReadSeq(forKey: "read-key"), 7)
    }

    func testConversationStoreInsertDirectConversationCreatesRowAtTopWithParticipantProfile() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        ])
        let participant = makeUser(
            id: "peer-1",
            name: "Alice",
            avatarURL: "https://avatar.example/alice.png",
            avatarVersion: "v2",
            avatarUpdatedAt: "t2"
        )

        let created = store.insertDirectConversation(
            channelID: " self:peer-1 ",
            title: "Alice",
            participant: participant,
            accentHex: 88
        )

        XCTAssertEqual(created?.id, "self:peer-1")
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["self:peer-1", "older"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].kind, .direct)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].title, "Alice")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].subtitle, "单聊")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["peer-1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarURL, "https://avatar.example/alice.png")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarVersion, "v2")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarUpdatedAt, "t2")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].accentHex, 88)
    }

    func testConversationStoreInsertDirectConversationSkipsEmptyAndReusesExistingChannelID() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var existing = makeConversation(id: "self:peer-1", kind: .direct, unread: 1, lastMsgSeq: 4, lastReadSeq: 3)
        existing.title = "Existing"
        store.commitConversationSnapshots([existing])

        XCTAssertNil(store.insertDirectConversation(
            channelID: "   ",
            title: "Invalid",
            participant: makeUser(id: "peer-2"),
            accentHex: 0
        ))

        let reused = store.insertDirectConversation(
            channelID: " self:peer-1 ",
            title: "Changed",
            participant: makeUser(id: "peer-1"),
            accentHex: 99
        )

        XCTAssertEqual(reused?.id, "self:peer-1")
        XCTAssertEqual(store.conversationMessageSnapshots().count, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].title, "Existing")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].accentHex, existing.accentHex)
    }

    func testConversationStoreTogglePinnedSortsAndRestoresPreviousValue() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var older = makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        older.sortTimestamp = 100
        var newer = makeConversation(id: "newer", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        newer.sortTimestamp = 200
        store.commitConversationSnapshots([newer, older])

        let change = store.toggleConversationPinned(conversationID: "older")

        XCTAssertEqual(change?.previousValue, false)
        XCTAssertEqual(change?.conversation.id, "older")
        XCTAssertEqual(change?.conversation.isPinned, true)
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["older", "newer"])
        XCTAssertEqual(store.conversationMessageSnapshots().first(where: { $0.id == "older" })?.isPinned, true)

        store.restoreConversationPinned(conversationID: "older", to: false)

        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["newer", "older"])
        XCTAssertEqual(store.conversationMessageSnapshots().first(where: { $0.id == "older" })?.isPinned, false)
    }

    func testConversationStoreToggleMutedRestoresWithoutSorting() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var older = makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        older.sortTimestamp = 100
        var newer = makeConversation(id: "newer", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        newer.sortTimestamp = 200
        store.commitConversationSnapshots([older, newer])

        let change = store.toggleConversationMuted(conversationID: "older")

        XCTAssertEqual(change?.previousValue, false)
        XCTAssertEqual(change?.conversation.id, "older")
        XCTAssertEqual(change?.conversation.isMuted, true)
        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["older", "newer"])
        XCTAssertEqual(store.conversationMessageSnapshots().first(where: { $0.id == "older" })?.isMuted, true)

        store.restoreConversationMuted(conversationID: "older", to: false)

        XCTAssertEqual(store.conversationMessageSnapshots().map(\.id), ["older", "newer"])
        XCTAssertEqual(store.conversationMessageSnapshots().first(where: { $0.id == "older" })?.isMuted, false)
    }

    func testConversationStoreSetGroupConversationMutedMatchesIDAndName() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var idMatch = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        idMatch.title = "Original"
        var nameMatch = makeConversation(id: "legacy-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        nameMatch.title = "Team Blue"
        store.commitConversationSnapshots([idMatch, nameMatch])

        XCTAssertTrue(store.setGroupConversationMuted(groupID: " group-1 ", groupName: "Ignored", isMuted: true))
        XCTAssertTrue(store.conversationMessageSnapshots()[0].isMuted)
        XCTAssertFalse(store.conversationMessageSnapshots()[1].isMuted)

        XCTAssertTrue(store.setGroupConversationMuted(groupID: "missing", groupName: " Team Blue ", isMuted: true))
        XCTAssertTrue(store.conversationMessageSnapshots()[1].isMuted)
    }

    func testConversationStoreSetGroupConversationMutedIgnoresEmptyOrMissingTarget() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        ])

        XCTAssertFalse(store.setGroupConversationMuted(groupID: " ", groupName: " ", isMuted: true))
        XCTAssertFalse(store.conversationMessageSnapshots()[0].isMuted)

        XCTAssertFalse(store.setGroupConversationMuted(groupID: "missing", groupName: "Missing", isMuted: true))
        XCTAssertFalse(store.conversationMessageSnapshots()[0].isMuted)
    }

    func testConversationStoreUpdateGroupAllMutedConversationPreviewMatchesIDChannelAndName() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var idMatch = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        idMatch.title = "Original"
        var channelMatch = makeConversation(id: "legacy-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        channelMatch.title = "Channel Backed"
        var nameMatch = makeConversation(id: "name-backed", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        nameMatch.title = "Team Blue"
        store.commitConversationSnapshots([idMatch, channelMatch, nameMatch])

        XCTAssertTrue(store.updateGroupAllMutedConversationPreview(groupID: " group-1 ", groupName: "Ignored", message: "id preview") { _ in "" })
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "id preview")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "刚刚")

        XCTAssertTrue(store.updateGroupAllMutedConversationPreview(groupID: "group-2", groupName: "Ignored", message: "channel preview") { conversation in
            conversation.id == "legacy-channel" ? "group-2" : ""
        })
        XCTAssertEqual(store.conversationMessageSnapshots()[1].lastMessage, "channel preview")

        XCTAssertTrue(store.updateGroupAllMutedConversationPreview(groupID: "missing", groupName: " Team Blue ", message: "name preview") { _ in "" })
        XCTAssertEqual(store.conversationMessageSnapshots()[2].lastMessage, "name preview")
    }

    func testConversationStoreUpdateGroupAllMutedConversationPreviewIgnoresEmptyOrMissingTarget() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([
            makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        ])

        XCTAssertFalse(store.updateGroupAllMutedConversationPreview(groupID: " ", groupName: " ", message: "ignored") { _ in "" })
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "")

        XCTAssertFalse(store.updateGroupAllMutedConversationPreview(groupID: "missing", groupName: "Missing", message: "ignored") { _ in "" })
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMessage, "")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].time, "")
    }

    func testConversationStoreRemoveParticipantFromGroupConversationMatchesIDAndNameAndUpdatesCount() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var idMatch = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        idMatch.title = "Original"
        idMatch.participants = [makeUser(id: "u1"), makeUser(id: "u2")]
        idMatch.memberCount = 2
        var nameMatch = makeConversation(id: "legacy", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        nameMatch.title = "Team Blue"
        nameMatch.participants = [makeUser(id: "u3"), makeUser(id: "u4")]
        nameMatch.memberCount = 2
        store.commitConversationSnapshots([idMatch, nameMatch])

        XCTAssertTrue(store.removeParticipantFromGroupConversation(groupID: " group-1 ", groupName: "Ignored", userID: " u1 ", memberCount: 4))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].memberCount, 4)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["u3", "u4"])

        XCTAssertTrue(store.removeParticipantFromGroupConversation(groupID: "missing", groupName: " Team Blue ", userID: "u3", memberCount: 3))
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["u4"])
        XCTAssertEqual(store.conversationMessageSnapshots()[1].memberCount, 3)
    }

    func testConversationStoreRemoveParticipantFromAllConversationsIgnoresEmptyAndCountsRemovals() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.participants = [makeUser(id: "u1"), makeUser(id: "u2")]
        var second = makeConversation(id: "c2", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.participants = [makeUser(id: "u1"), makeUser(id: "u3")]
        store.commitConversationSnapshots([first, second])

        XCTAssertEqual(store.removeParticipantFromAllConversations(userID: " "), 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u1", "u2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["u1", "u3"])

        XCTAssertEqual(store.removeParticipantFromAllConversations(userID: " u1 "), 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["u3"])
    }

    func testConversationStoreUpdateConversationParticipantsTransformsAndCountsChangedParticipants() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.participants = [makeUser(id: "u1"), makeUser(id: "u2")]
        var second = makeConversation(id: "c2", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.participants = [makeUser(id: "u3")]
        store.commitConversationSnapshots([first, second])

        let updatedCount = store.updateConversationParticipants { user in
            guard user.id == "u1" || user.id == "u3" else { return user }
            return IMUser(
                id: user.id,
                userID: user.userID,
                username: user.username,
                name: user.name,
                title: user.title,
                department: user.department,
                phone: user.phone,
                phoneVerified: user.phoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.email,
                status: user.status,
                enterprise: user.enterprise,
                avatarSeed: user.avatarSeed,
                avatarURL: "https://avatar.example/\(user.id).png",
                avatarVersion: "v2",
                avatarUpdatedAt: "now",
                badges: user.badges
            )
        }

        XCTAssertEqual(updatedCount, 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants[0].avatarURL, "https://avatar.example/u1.png")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants[0].avatarVersion, "v2")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants[1].avatarURL, "")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants[0].avatarURL, "https://avatar.example/u3.png")
    }

    func testConversationStoreUpdateConversationParticipantsSkipsEmptyAndUnchangedValues() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let empty = makeConversation(id: "empty", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var unchanged = makeConversation(id: "unchanged", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        unchanged.participants = [makeUser(id: "u1")]
        store.commitConversationSnapshots([empty, unchanged])

        XCTAssertEqual(store.updateConversationParticipants { $0 }, 0)
        XCTAssertTrue(store.conversationMessageSnapshots()[0].participants.isEmpty)
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["u1"])
    }

    func testConversationStoreRefreshDirectConversationProfilesUpdatesTitleParticipantsAndAvatar() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var directWithAvatar = makeConversation(id: "direct-1", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        directWithAvatar.title = "direct-1"
        var directWithoutAvatar = makeConversation(id: "direct-2", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        directWithoutAvatar.title = "Stable"
        var group = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        group.title = "Group"
        store.commitConversationSnapshots([directWithAvatar, directWithoutAvatar, group])

        let updatedCount = store.refreshDirectConversationProfiles(
            channelIDForConversation: { $0.id },
            titleForChannel: { channelID in channelID == "direct-1" ? "Alice" : "" },
            participantsForChannel: { channelID in
                switch channelID {
                case "direct-1":
                    return [makeUser(id: "u1", name: "Alice", avatarURL: "https://avatar.example/u1.png", avatarVersion: "v2", avatarUpdatedAt: "t2")]
                case "direct-2":
                    return [makeUser(id: "u2", name: "Bob")]
                default:
                    return [makeUser(id: "ignored")]
                }
            }
        )

        XCTAssertEqual(updatedCount, 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].title, "Alice")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarURL, "https://avatar.example/u1.png")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarVersion, "v2")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarUpdatedAt, "t2")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].title, "Stable")
        XCTAssertEqual(store.conversationMessageSnapshots()[1].participants.map(\.id), ["u2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[1].avatarURL, "")
        XCTAssertEqual(store.conversationMessageSnapshots()[2].title, "Group")
        XCTAssertTrue(store.conversationMessageSnapshots()[2].participants.isEmpty)
    }

    func testConversationStoreRefreshDirectConversationProfilesSkipsEmptyAndUnchangedValues() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var direct = makeConversation(id: "direct-1", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        direct.title = "Alice"
        direct.participants = [makeUser(id: "u1", name: "Alice", avatarURL: "https://avatar.example/u1.png", avatarVersion: "v2", avatarUpdatedAt: "t2")]
        direct.avatarURL = "https://avatar.example/u1.png"
        direct.avatarVersion = "v2"
        direct.avatarUpdatedAt = "t2"
        store.commitConversationSnapshots([direct])

        let unchangedCount = store.refreshDirectConversationProfiles(
            channelIDForConversation: { $0.id },
            titleForChannel: { _ in "Alice" },
            participantsForChannel: { _ in
                [makeUser(id: "u1", name: "Alice", avatarURL: "https://avatar.example/u1.png", avatarVersion: "v2", avatarUpdatedAt: "t2")]
            }
        )
        XCTAssertEqual(unchangedCount, 0)

        let emptyCount = store.refreshDirectConversationProfiles(
            channelIDForConversation: { $0.id },
            titleForChannel: { _ in "" },
            participantsForChannel: { _ in [] }
        )
        XCTAssertEqual(emptyCount, 0)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].title, "Alice")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarURL, "https://avatar.example/u1.png")
    }

    func testConversationStoreUpsertCreatedGroupConversationMergesExistingAndPreservesRuntimeState() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var existing = makeConversation(id: "legacy", kind: .group, unread: 5, lastMsgSeq: 9, lastReadSeq: 3)
        existing.title = "Old Name"
        existing.memberCount = 10
        existing.isPinned = true
        existing.isMuted = true
        existing.messages = [makeMessage(id: "m1", seq: 9)]
        existing.avatarURL = "https://avatar.example/group-old.png"
        existing.avatarVersion = "old-v"
        existing.hasMention = true
        existing.mentionCount = 2
        existing.mentionSummaryText = "@你"
        existing.sortTimestamp = 123
        store.commitConversationSnapshots([existing])

        let updated = store.upsertCreatedGroupConversation(
            groupID: " remote-1 ",
            name: "New Name",
            members: [makeUser(id: "u1"), makeUser(id: "u2")],
            invitedMemberCount: 5,
            accentHex: 42,
            sortTimestamp: 999,
            channelIDForConversation: { conversation in conversation.id == "legacy" ? "remote-1" : conversation.id }
        )

        XCTAssertEqual(updated?.id, "legacy")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].title, "New Name")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].memberCount, 10)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].participants.map(\.id), ["u1", "u2"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["m1"])
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 5)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].isPinned, true)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].isMuted, true)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarURL, "https://avatar.example/group-old.png")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].avatarVersion, "old-v")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].hasMention, true)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].mentionCount, 2)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].mentionSummaryText, "@你")
        XCTAssertEqual(store.conversationMessageSnapshots()[0].sortTimestamp, 123)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

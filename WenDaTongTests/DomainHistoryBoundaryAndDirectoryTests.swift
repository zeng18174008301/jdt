@testable import IM4Features
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
    func testConversationStoreNewerHistoryFilterRejectsCurrentAndDuplicateMessages() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let newer = try decodeRemoteMessage("""
        {
          "message_id": "m5",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 5,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)
        let current = try decodeRemoteMessage("""
        {
          "message_id": "m3",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 3,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)
        let unsequenced = try decodeRemoteMessage("""
        {
          "message_id": "m0",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 0,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)

        XCTAssertTrue(store.isRemoteMessageNewerThanCurrentWindow(newer, newestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageNewerThanCurrentWindow(current, newestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageNewerThanCurrentWindow(unsequenced, newestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageNewerThanCurrentWindow(newer, newestSeq: 3, existingIDs: ["m5"], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageNewerThanCurrentWindow(newer, newestSeq: 3, existingIDs: [], existingSeqs: [5]))
    }

    func testRealtimeMessageIngestBufferGroupsByScopeAndConversationOrder() throws {
        var buffer = RealtimeMessageIngestBuffer()
        let first = try decodeRemoteMessage(remoteMessageJSON(id: "m1", channelID: "g1", channelType: "group", seq: 1))
        let second = try decodeRemoteMessage(remoteMessageJSON(id: "m2", channelID: "g1", channelType: "group", seq: 2))
        let third = try decodeRemoteMessage(remoteMessageJSON(id: "m3", channelID: "g2", channelType: "group", seq: 1))
        let stale = try decodeRemoteMessage(remoteMessageJSON(id: "stale", channelID: "g1", channelType: "group", seq: 3))

        buffer.append(first, scopeKey: "scope-a")
        buffer.append(third, scopeKey: "scope-a")
        buffer.append(stale, scopeKey: "scope-b")
        buffer.append(second, scopeKey: "scope-a")

        let groups = buffer.drainGrouped(currentScopeKey: "scope-a")

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].channelID, "g1")
        XCTAssertEqual(groups[0].messages.map(\.messageID), ["m1", "m2"])
        XCTAssertEqual(groups[1].channelID, "g2")
        XCTAssertEqual(groups[1].messages.map(\.messageID), ["m3"])
    }

    func testConversationScrollArbiterNormalJumpAndGenerationRules() {
        var arbiter = ConversationScrollArbiter()
        let now = Date(timeIntervalSince1970: 100)
        arbiter.beginNormalOpen(now: now, duration: 3)
        let generation = arbiter.generation

        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .followBottom, targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation),
                now: now.addingTimeInterval(1)
            ),
            .allow
        )
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .readAck, targetID: "m1", anchor: .center, userInitiated: false, generation: generation),
                now: now.addingTimeInterval(1)
            ),
            .deny
        )
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .searchJump, targetID: "old", anchor: .center, userInitiated: true, generation: generation),
                now: now.addingTimeInterval(1.2)
            ),
            .allowAndEndWindow
        )
        XCTAssertTrue(arbiter.isJumpMode)
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .followBottom, targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation),
                now: now.addingTimeInterval(1.4)
            ),
            .deny
        )
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .jumpToLatest, targetID: "bottom", anchor: .bottom, userInitiated: true, generation: generation),
                now: now.addingTimeInterval(1.6)
            ),
            .allowAndEndWindow
        )
        XCTAssertFalse(arbiter.isJumpMode)

        arbiter.beginNormalOpen(now: now.addingTimeInterval(10), duration: 3)
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .followBottom, targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation),
                now: now.addingTimeInterval(11)
            ),
            .deny
        )
    }

    func testConversationStoreHistoryBoundaryFiltersRestrictedGroupMessagesFailClosed() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "g1", kind: .group, unread: 3, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m420", seq: 420),
            makeMessage(id: "m0", seq: 0),
            makeMessage(id: "m421", seq: 421),
            makeMessage(id: "m422", seq: 422)
        ]

        let bounded = try XCTUnwrap(store.applyingHistoryVisibilityBoundary(
            ConversationStore.HistoryVisibilityBoundary(fromSeq: 421, limited: true),
            to: conversation,
            keepPendingLocalMessages: false
        ))

        XCTAssertEqual(bounded.messages.map(\.id), ["m421", "m422"])
        XCTAssertEqual(bounded.lastMessage, "m422")
        XCTAssertEqual(bounded.unread, 0)
        XCTAssertEqual(bounded.historyVisibleFromSeq, 421)
        XCTAssertTrue(bounded.historyLimited)
        XCTAssertTrue(bounded.historyBoundaryConfirmed)
    }

    func testConversationStoreHistoryBoundaryDecreaseClearsOldSnapshotForNewEpisode() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "g1", kind: .group, unread: 0, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.historyVisibleFromSeq = 421
        conversation.historyLimited = true
        conversation.historyBoundaryConfirmed = true
        conversation.messages = [
            makeMessage(id: "m421", seq: 421),
            makeMessage(id: "m422", seq: 422)
        ]
        conversation.lastMessage = "m422"

        let widened = try XCTUnwrap(store.applyingHistoryVisibilityBoundary(
            ConversationStore.HistoryVisibilityBoundary(fromSeq: 1, limited: false),
            to: conversation
        ))

        XCTAssertTrue(widened.messages.isEmpty)
        XCTAssertEqual(widened.lastMessage, "")
        XCTAssertEqual(widened.historyVisibleFromSeq, 1)
        XCTAssertFalse(widened.historyLimited)
        XCTAssertTrue(widened.historyBoundaryConfirmed)
    }

    func testConversationStoreHistoryBoundaryDoesNotClipDirectConversation() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "d1", kind: .direct, unread: 1, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m420", seq: 420)
        ]

        let bounded = try XCTUnwrap(store.applyingHistoryVisibilityBoundary(
            ConversationStore.HistoryVisibilityBoundary(fromSeq: 421, limited: true),
            to: conversation
        ))

        XCTAssertEqual(bounded.messages.map(\.id), ["m1", "m420"])
        XCTAssertFalse(bounded.historyBoundaryConfirmed)
    }

    func testConfirmedCachedGroupConversationPublishesItsBoundaryAdmittedHistoryImmediately() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "g1", kind: .group, unread: 4, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m420", seq: 420),
            makeMessage(id: "m421", seq: 421),
            makeMessage(id: "m422", seq: 422)
        ]
        conversation.lastMessage = "m422"
        conversation.historyVisibleFromSeq = 421
        conversation.historyLimited = true
        conversation.historyBoundaryConfirmed = true

        let safe = store.conversationPreparedForLocalHistoryProjection(conversation)

        XCTAssertEqual(safe.messages.map(\.id), ["m421", "m422"])
        XCTAssertEqual(safe.lastMessage, "m422")
        XCTAssertEqual(safe.unread, 0)
        XCTAssertTrue(safe.historyBoundaryConfirmed)
    }

    func testUnconfirmedCachedGroupConversationStillFailsClosedBeforeLocalProjection() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "g1", kind: .group, unread: 4, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m421", seq: 421),
            makeMessage(id: "m422", seq: 422)
        ]
        conversation.lastMessage = "m422"
        conversation.historyVisibleFromSeq = 421
        conversation.historyLimited = true
        conversation.historyBoundaryConfirmed = false

        let safe = store.conversationPreparedForLocalHistoryProjection(conversation)

        XCTAssertTrue(safe.messages.isEmpty)
        XCTAssertEqual(safe.lastMessage, "")
        XCTAssertEqual(safe.unread, 0)
        XCTAssertFalse(safe.historyBoundaryConfirmed)
    }

    func testConversationSelectionEpochFenceRejectsLateAtoBtoAResponses() {
        var fence = ConversationSelectionEpochFence()

        let firstA = fence.select(scope: "scope-one", conversationID: "direct-a")
        let selectedB = fence.select(scope: "scope-one", conversationID: "direct-b")
        let secondA = fence.select(scope: "scope-one", conversationID: "direct-a")

        XCTAssertFalse(fence.accepts(firstA))
        XCTAssertFalse(fence.accepts(selectedB))
        XCTAssertTrue(fence.accepts(secondA))

        fence.leave(scope: "scope-one", conversationID: "direct-a")
        XCTAssertFalse(fence.accepts(secondA))
    }

    func testGroupHistoryBoundaryGenerationTrackerDropsOutOfOrderResponses() {
        var tracker = GroupHistoryBoundaryGenerationTracker()
        let first = tracker.begin(key: "tenant|user|g1")
        let second = tracker.begin(key: "tenant|user|g1")

        XCTAssertFalse(tracker.accepts(key: "tenant|user|g1", generation: first))
        XCTAssertTrue(tracker.accepts(key: "tenant|user|g1", generation: second))
        XCTAssertTrue(tracker.accepts(key: "tenant|user|g2", generation: nil))
    }

    @MainActor
    func testRemovingFriendRelationshipPreservesReadableDirectHistoryAndParticipantSnapshot() {
        let peer = makeUser(id: "peer-retained", name: "Retained Peer")
        var conversation = makeConversation(
            id: "direct-retained",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        conversation.participants = [peer]
        conversation.messages = [makeMessage(id: "history-1", senderId: peer.id, seq: 1)]
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([conversation])
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let state = AppState(
            conversationStore: store,
            messageStore: SnapshotCache(directoryURL: cacheDirectory),
            apiContextOverride: TestMessageMemoryScope.context
        )
        state.contacts = [peer]
        state.contactRemarks = [peer.id: "旧备注"]

        state.removeFriendData(peer)

        XCTAssertFalse(state.contacts.contains { $0.id == peer.id })
        XCTAssertNil(state.contactRemarks[peer.id])
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.map(\.id), ["history-1"])
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.participants.map(\.id), [peer.id])
    }

    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
    func testBlacklistUpdatesOnlyMatchingPeerAndPreservesSendAndCallGuards() {
        let peer = makeUser(id: "peer", name: "Peer")
        var conversation = makeConversation(id: "uid-1:peer", unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        conversation.participants = [peer]
        let conversationStore = ConversationStore(scope: TestMessageMemoryScope.value)
        conversationStore.commitConversationSnapshots([conversation])
        let state = AppState(conversationStore: conversationStore, apiContextOverride: makeAuthenticatedAPIContext())
        let store = state.contactStore

        var reasons: [String?] = []
        func content(_ ids: Set<String>) -> some View {
            reasons.append(state.directSendBlockedMessage(for: conversation))
            return Text(ids.isEmpty ? "可发送" : "不可发送")
        }
        let hosted = hostForSimulatorUI(
            PublisherSnapshotView(
                initialValue: store.blacklistIDs(matching: ["peer"]),
                updates: store.blacklistIDUpdates(matching: ["peer"]),
                content: content
            ),
            size: CGSize(width: 320, height: 80)
        )
        defer { hosted.window.isHidden = true }
        func renderPendingChanges() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosted.controller.view.layoutIfNeeded()
        }
        var globalUpdates = 0
        let observation = state.objectWillChange.sink { globalUpdates += 1 }
        defer { observation.cancel() }
        let initialCount = reasons.count

        store.blacklist = [BlacklistItem(id: "other", name: "Other", reason: "blocked")]
        renderPendingChanges()
        XCTAssertEqual(reasons.count, initialCount)

        store.blacklist.append(BlacklistItem(id: " peer ", name: "Peer", reason: "blocked"))
        renderPendingChanges()
        XCTAssertTrue(state.isBlockedProfile(peer))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: peer), "已拉黑该用户，解除后才能发起语音通话")
        XCTAssertEqual(state.videoCallEntryUnavailableReason(for: peer), "已拉黑该用户，解除后才能发起视频通话")
        XCTAssertNil(state.directSendBlockedMessage(for: conversation))

        store.blacklist[1] = BlacklistItem(id: "peer", name: "Peer", reason: "blocked")
        renderPendingChanges()
        XCTAssertEqual(reasons.last ?? nil, "你已拉黑对方，无法发送消息")
        XCTAssertTrue(state.isBlockedProfile(peer))

        store.blacklist.removeLast()
        renderPendingChanges()
        XCTAssertNil(reasons.last ?? nil)
        XCTAssertFalse(state.isBlockedProfile(peer))
        XCTAssertEqual(globalUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END

    @MainActor
    func testBlockingFriendPreservesPrivateRemarkAndReadableDirectHistory() {
        let peer = makeUser(id: "peer-blocked", name: "Blocked Peer")
        var conversation = makeConversation(
            id: "direct-blocked",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        conversation.participants = [peer]
        conversation.messages = [makeMessage(id: "blocked-history-1", senderId: peer.id, seq: 1)]
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([conversation])
        let state = AppState(conversationStore: store, apiContextOverride: TestMessageMemoryScope.context)
        state.contacts = [peer]
        state.contactRemarks = [peer.id: "查看者私有备注"]

        state.removeFriendData(peer, removePrivateRemark: false)

        XCTAssertFalse(state.contacts.contains { $0.id == peer.id })
        XCTAssertEqual(state.contactRemarks[peer.id], "查看者私有备注")
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.map(\.id), ["blocked-history-1"])
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.participants.map(\.id), [peer.id])
    }

    @MainActor
    func testBackgroundSystemNotificationNeverUsesViewerPrivateRemark() {
        let privateRemark = "查看者私有备注"
        let peer = makeUser(id: "peer-notification", name: privateRemark)
        var conversation = makeConversation(
            id: "self:peer-notification",
            kind: .direct,
            unread: 1,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        conversation.title = privateRemark
        conversation.participants = [peer]
        let state = AppState()
        state.contacts = [peer]
        state.contactRemarks = [peer.id: privateRemark]
        var privateSnapshot = makeMessage(id: "message-private", senderId: peer.id, seq: 1)
        privateSnapshot.senderName = privateRemark

        XCTAssertEqual(
            state.systemNotificationTitleForTesting(
                conversation: conversation,
                latestIncomingMessage: privateSnapshot
            ),
            "问达通"
        )

        var publicSnapshot = privateSnapshot
        publicSnapshot.senderName = "Public Nickname"
        XCTAssertEqual(
            state.systemNotificationTitleForTesting(
                conversation: conversation,
                latestIncomingMessage: publicSnapshot
            ),
            "问达通"
        )

        let privateContactCard = makeMessage(
            id: "private-contact-card",
            senderId: peer.id,
            seq: 2,
            text: privateRemark,
            kind: .contactCard
        )
        let privateSystemMessage = makeMessage(
            id: "private-system-message",
            senderId: peer.id,
            seq: 3,
            text: privateRemark,
            kind: .system
        )
        XCTAssertEqual(
            state.systemNotificationBodyForTesting(message: privateContactCard),
            "收到新消息通知"
        )
        XCTAssertEqual(
            state.systemNotificationBodyForTesting(message: privateSystemMessage),
            "收到新消息通知"
        )
        XCTAssertEqual(
            state.systemNotificationBodyForTesting(
                message: makeMessage(id: "ordinary-text", seq: 4, text: "公开消息")
            ),
            "收到新消息通知"
        )
    }

    func testBiometricProtectionRequiresAuthenticationBeforePersistingAndRestoresByAccountScope() async throws {
        let defaultsName = "BlueStoneIMTests.biometric.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let context = makeAuthenticatedAPIContext()
        let rejectedAuthenticator = RecordingBiometricAuthenticator(
            error: NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue)
        )
        let rejectedState = AppState(
            biometricAuthenticator: rejectedAuthenticator,
            biometricDefaults: defaults,
            apiContextOverride: context
        )
        var rejectedDraft = BiometricProtectionSettingsDraft(settings: rejectedState.biometricProtectionSettings)
        let rejectedRequest = try XCTUnwrap(rejectedDraft.beginEnabledChange(to: true))
        XCTAssertFalse(rejectedDraft.enabled)
        let rejectedSave = await rejectedState.saveBiometricProtectionSettings(
            enabled: rejectedRequest.enabled,
            unlockChats: rejectedRequest.unlockChats,
            previewFiles: rejectedRequest.previewFiles
        )
        rejectedDraft.finish(with: rejectedState.biometricProtectionSettings)
        XCTAssertFalse(rejectedSave)
        XCTAssertFalse(rejectedDraft.enabled)
        XCTAssertFalse(rejectedDraft.isUpdating)
        XCTAssertFalse(rejectedState.biometricProtectionSettings.enabled)
        XCTAssertEqual(rejectedAuthenticator.requestCount, 1)
        XCTAssertEqual(rejectedState.toast, "Face ID 验证已取消")
        XCTAssertNil(defaults.data(forKey: BiometricProtectionStore.scopeKey(context: context)))

        let authenticator = RecordingBiometricAuthenticator()
        let state = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: context
        )

        XCTAssertFalse(state.biometricProtectionSettings.enabled)
        var enableDraft = BiometricProtectionSettingsDraft(settings: state.biometricProtectionSettings)
        let requestedEnable = try XCTUnwrap(enableDraft.beginEnabledChange(to: true))
        XCTAssertFalse(enableDraft.enabled, "Enable-time verification must not optimistically flip the UI")
        XCTAssertTrue(enableDraft.isUpdating)
        let didSave = await state.saveBiometricProtectionSettings(
            enabled: requestedEnable.enabled,
            unlockChats: requestedEnable.unlockChats,
            previewFiles: false
        )
        enableDraft.finish(with: state.biometricProtectionSettings)
        XCTAssertTrue(didSave)
        XCTAssertEqual(authenticator.requestCount, 1)
        XCTAssertTrue(enableDraft.enabled)
        XCTAssertTrue(state.requiresChatBiometricProtection)
        XCTAssertFalse(state.requiresFileBiometricProtection)
        let unprotectedFileWasAuthorized = await state.authorizeProtectedAccess(.filePreview)
        XCTAssertTrue(unprotectedFileWasAuthorized)
        XCTAssertEqual(authenticator.requestCount, 1)

        let restored = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: context
        )
        XCTAssertEqual(restored.biometricProtectionSettings, state.biometricProtectionSettings)
        let didAuthorize = await restored.authorizeProtectedAccess(.chat)
        XCTAssertTrue(didAuthorize)
        XCTAssertEqual(authenticator.requestCount, 2)

        let otherAccount = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: makeAuthenticatedAPIContext(accountID: "account-2", imUID: "uid-2")
        )
        XCTAssertEqual(otherAccount.biometricProtectionSettings, .disabled)

        var emptyAccountContext = makeAuthenticatedAPIContext(accountID: "", imUID: "uid-fallback")
        emptyAccountContext.accountID = ""
        XCTAssertTrue(
            BiometricProtectionStore.scopeKey(context: emptyAccountContext).hasSuffix(".uid-fallback")
        )
    }

    func testBiometricEnableDoesNotWriteAcrossAccountSwitchDuringAuthentication() async throws {
        let defaultsName = "BlueStoneIMTests.biometric-enable-scope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let firstContext = makeAuthenticatedAPIContext()
        let secondContext = makeAuthenticatedAPIContext(accountID: "account-2", imUID: "uid-2")
        let authenticator = SuspendedBiometricAuthenticator()
        let state = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: firstContext
        )

        let save = Task {
            await state.saveBiometricProtectionSettings(
                enabled: true,
                unlockChats: true,
                previewFiles: true
            )
        }
        for _ in 0..<1_000 where !authenticator.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(authenticator.isWaiting)
        state.overrideAPIContextForTesting(secondContext)
        authenticator.succeed()

        let didSave = await save.value
        XCTAssertFalse(didSave)
        XCTAssertEqual(state.toast, "登录状态已变化，请重新设置 Face ID")
        XCTAssertEqual(state.biometricProtectionSettings, .disabled)
        XCTAssertNil(defaults.data(forKey: BiometricProtectionStore.scopeKey(context: firstContext)))
        XCTAssertNil(defaults.data(forKey: BiometricProtectionStore.scopeKey(context: secondContext)))
    }

    func testBiometricProtectionAllowsSuccessfulSystemPromptAfterSceneBecomesInactiveAndRelocksLater() async throws {
        let defaultsName = "BlueStoneIMTests.biometric-prompt-inactive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let context = makeAuthenticatedAPIContext()
        try BiometricProtectionStore.save(
            BiometricProtectionSettings(enabled: true, unlockChats: true, previewFiles: true),
            context: context,
            defaults: defaults
        )
        let authenticator = SuspendedBiometricAuthenticator()
        let riskTelemetry = IOSRiskTelemetryController(
            queueStore: IOSRiskTelemetryQueueStore(
                defaults: defaults,
                keyPrefix: "biometric-prompt-risk"
            ),
            submit: { _, events in
                IOSRiskActivityBatchResult(items: events.indices.map {
                    IOSRiskActivityItemResult(index: $0, status: "accepted")
                })
            }
        )
        let state = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: context,
            iosRiskTelemetry: riskTelemetry
        )
        let accessScopeBeforePrompt = state.biometricAccessScopeToken
        XCTAssertFalse(state.isProtectedAccessAuthorized(.chat))
        let authorization = Task { await state.authorizeProtectedAccess(.chat) }
        for _ in 0..<1_000 where !authenticator.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(authenticator.isWaiting)

        // Presenting the system Face ID sheet makes the app scene inactive. That lifecycle
        // transition must relock any prior grant without invalidating this in-flight prompt.
        state.appDidBecomeInactive()
        XCTAssertNotEqual(state.biometricAccessScopeToken, accessScopeBeforePrompt)
        authenticator.succeed()

        let wasAuthorized = await authorization.value
        XCTAssertTrue(wasAuthorized)
        XCTAssertTrue(state.isProtectedAccessAuthorized(.chat))

        let accessScopeAfterPrompt = state.biometricAccessScopeToken
        state.appDidEnterBackground()
        XCTAssertNotEqual(state.biometricAccessScopeToken, accessScopeAfterPrompt)
        XCTAssertFalse(state.isProtectedAccessAuthorized(.chat))
    }

    func testBiometricProtectionRejectsStaleAuthenticationAndRelocksProtectedSurfaces() async throws {
        let defaultsName = "BlueStoneIMTests.biometric-stale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let firstContext = makeAuthenticatedAPIContext()
        try BiometricProtectionStore.save(
            BiometricProtectionSettings(enabled: true, unlockChats: true, previewFiles: true),
            context: firstContext,
            defaults: defaults
        )
        let authenticator = SuspendedBiometricAuthenticator()
        let state = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: firstContext
        )
        let initialScopeToken = state.biometricAccessScopeToken
        let authorization = Task { await state.authorizeProtectedAccess(.chat) }
        for _ in 0..<1_000 where !authenticator.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(authenticator.isWaiting)

        state.overrideAPIContextForTesting(
            makeAuthenticatedAPIContext(accountID: "account-2", imUID: "uid-2")
        )
        authenticator.succeed()

        let wasAuthorized = await authorization.value
        XCTAssertFalse(wasAuthorized)
        XCTAssertEqual(state.toast, "登录状态已变化，请重新验证")
        XCTAssertNotEqual(state.biometricAccessScopeToken, initialScopeToken)
        XCTAssertEqual(state.biometricProtectionSettings, .disabled)

        let beforeInactive = state.biometricAccessScopeToken
        state.appDidBecomeInactive()
        XCTAssertNotEqual(state.biometricAccessScopeToken, beforeInactive)
    }

    func testBiometricEnableErrorsRemainTruthfulAndNeverPersist() async throws {
        let cases: [(LAError.Code, String)] = [
            (.biometryNotAvailable, "此设备不支持 Face ID"),
            (.biometryNotEnrolled, "请先在系统设置中录入 Face ID"),
            (.biometryLockout, "Face ID 已锁定，请先在系统设置中解锁"),
            (.authenticationFailed, "Face ID 验证失败，请重试")
        ]
        for (code, message) in cases {
            let defaultsName = "BlueStoneIMTests.biometric-error.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let context = makeAuthenticatedAPIContext()
            let state = AppState(
                biometricAuthenticator: RecordingBiometricAuthenticator(error: LAError(code)),
                biometricDefaults: defaults,
                apiContextOverride: context
            )

            let didSave = await state.saveBiometricProtectionSettings(
                enabled: true,
                unlockChats: true,
                previewFiles: true
            )
            XCTAssertFalse(didSave)
            XCTAssertEqual(state.biometricProtectionSettings, .disabled)
            XCTAssertEqual(state.toast, message)
            XCTAssertNil(defaults.data(forKey: BiometricProtectionStore.scopeKey(context: context)))
        }
    }

    func testAppCacheCleanerDeletesOnlyOwnedRootsAndReportsRealBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests-cache-\(UUID().uuidString)", isDirectory: true)
        let cacheBase = root.appendingPathComponent("Caches", isDirectory: true)
        let tempBase = root.appendingPathComponent("Temp", isDirectory: true)
        let ownedCache = cacheBase.appendingPathComponent("BlueStoneIMAttachmentDownloads", isDirectory: true)
        let ownedTemp = tempBase.appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
        let unrelated = cacheBase.appendingPathComponent("UserOwned", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [ownedCache, ownedTemp, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(repeating: 7, count: 4_096).write(to: ownedCache.appendingPathComponent("a.bin"))
        try Data(repeating: 8, count: 2_048).write(to: ownedTemp.appendingPathComponent("b.bin"))
        try Data(repeating: 9, count: 128).write(to: unrelated.appendingPathComponent("keep.bin"))

        let result = await AppCacheCleaner.clear(cacheBase: cacheBase, temporaryBase: tempBase)

        XCTAssertGreaterThanOrEqual(result.bytesRemoved, 6_144)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("keep.bin").path))
    }

    func testProjectedGroupDirectoryRetainsAuthoritativeGroupsAndAddsConversationBackedMemberships() {
        let authoritative = GroupInfo(
            id: "group-authoritative",
            name: "权威群",
            notice: "公告",
            owner: "群主",
            members: [],
            admins: [],
            muted: false,
            allMuted: false,
            myRole: "owner"
        )
        var matchingConversation = makeConversation(
            id: authoritative.id,
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        matchingConversation.title = authoritative.name

        let member = makeUser(id: "member-1", name: "群成员")
        var conversationBacked = makeConversation(
            id: "group-conversation-backed",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        conversationBacked.title = "会话已验证群"
        conversationBacked.participants = [member]
        conversationBacked.memberCount = 7
        conversationBacked.isMuted = true
        conversationBacked.avatarURL = "https://example.invalid/group.png"

        let projected = ContactStore.projectedGroupDirectory(
            authoritativeGroups: [authoritative],
            conversations: [matchingConversation, conversationBacked]
        )

        XCTAssertEqual(projected.map(\.id), [authoritative.id, conversationBacked.id])
        XCTAssertEqual(projected[0], authoritative)
        XCTAssertEqual(projected[1].name, conversationBacked.title)
        XCTAssertEqual(projected[1].myRole, "member")
        XCTAssertEqual(projected[1].members, [member])
        XCTAssertEqual(projected[1].memberCount, 7)
        XCTAssertTrue(projected[1].membersPartial)
        XCTAssertTrue(projected[1].muted)
        XCTAssertEqual(projected[1].avatarURL, conversationBacked.avatarURL)
        XCTAssertFalse(projected[1].canCurrentUserManage)
    }

    func testProjectedGroupDirectoryDeduplicatesAConversationWithAnAuthoritativeGroupName() {
        let authoritative = GroupInfo(
            id: "remote-group-id",
            name: "同名群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false
        )
        var conversation = makeConversation(
            id: "local-conversation-id",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        conversation.title = " 同名群 "

        let projected = ContactStore.projectedGroupDirectory(
            authoritativeGroups: [authoritative],
            conversations: [conversation]
        )

        XCTAssertEqual(projected, [authoritative])
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

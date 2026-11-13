import XCTest; @testable import IM4Features // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

@MainActor
final class DomainStoreTests: XCTestCase {
    func testBackgroundConversationProjectionWaitsForScrollAndHonorsCancellation() async throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeAuthenticatedAPIContext())
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        state.isConversationListUserInteracting = true
        var pauses = 0
        try await state.waitForConversationListInteractionToEnd(scope: scope, pause: { _ in
            pauses += 1
            state.isConversationListUserInteracting = false
        })
        XCTAssertEqual(pauses, 1)
        state.isConversationListUserInteracting = true
        do {
            try await state.waitForConversationListInteractionToEnd(scope: scope, pause: { _ in throw CancellationError() })
            XCTFail("Cancelled background projection must not continue")
        } catch is CancellationError {
        }
        state.isConversationListUserInteracting = false
    }

    func testRealtimeResubscriptionYieldsAndStopsAfterDisconnect() async {
        let realtime = DeviceKickRealtimeTransport()
        let state = AppState(realtimeClient: realtime, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeAuthenticatedAPIContext())
        state.isRealtimeConnected = true
        state.contacts = (0..<1000).map { makeUser(id: "subscription-peer-\($0)") }
        state.conversationStore.commitConversationSnapshots((0..<1000).map {
            makeConversation(id: "subscription-\($0)", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        })
        var pauses = 0
        await state.resubscribeRealtimeChannelsCooperatively(pause: { _ in
            pauses += 1
            state.isRealtimeConnected = false
        })
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(realtime.subscriptions.count, 16)
        realtime.resetSubscriptions()
        state.isRealtimeConnected = true
        pauses = 0
        await state.resubscribeRealtimeChannelsCooperatively(pause: { _ in pauses += 1 })
        XCTAssertEqual(realtime.subscriptions.count, 1000)
        XCTAssertEqual(pauses, 62)
        XCTAssertEqual(realtime.subscriptions.first?.channelID, state.remoteChannelID(for: state.conversationStore.conversationMessageSnapshots()[0]))
        XCTAssertEqual(realtime.subscriptions.last?.channelID, state.remoteChannelID(for: state.conversationStore.conversationMessageSnapshots()[999]))
        XCTAssertTrue(realtime.subscriptions.allSatisfy { $0.tenantID == state.apiContext.tenantID && $0.imUID == state.apiContext.imUID })
    }

    func testRecallForUncachedMessageSkipsUnrelatedPeerResolution() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots((0..<1000).map { makeConversation(id: "recall-direct-\($0)", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1) })
        var resolutions = 0
        XCTAssertFalse(store.applyRecall(messageID: "uncached-message", conversationID: "target-group",
            channelIDForConversation: { row in resolutions += 1; return row.id }))
        XCTAssertEqual(resolutions, 0)
    }

    func testGroupDirectoryMatchingSkipsDirectPeerResolutionAndNoopPublications() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var group = makeConversation(id: "canonical-group", kind: .group, unread: 4, lastMsgSeq: 8, lastReadSeq: 2)
        group.memberCount = 6
        group.subtitle = "群聊"
        store.commitConversationSnapshots((0..<1000).map { makeConversation(id: "direct-\($0)", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1) } + [group])
        var resolutions = 0
        var publications = 0
        let observation = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { _ in publications += 1 } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        defer { observation.cancel() }
        let updated = store.ensureGroupConversation(groupID: group.id, name: group.title, notice: group.lastMessage,
            members: group.participants, muted: group.isMuted, memberCount: group.memberCount,
            avatarURL: group.avatarURL, avatarVersion: group.avatarVersion, avatarUpdatedAt: group.avatarUpdatedAt,
            avatarIsAuthoritative: true, accentHex: group.accentHex,
            channelIDForConversation: { row in resolutions += 1; return row.id })
        XCTAssertEqual(updated, group)
        XCTAssertEqual(resolutions, 0, "Canonical group identity must not normalize any direct peers")
        XCTAssertEqual(publications, 0, "Unchanged group metadata must not invalidate the entire conversation list")
        let boundary = ConversationStore.HistoryVisibilityBoundary(fromSeq: 1, limited: false, confirmed: true)
        _ = store.applyHistoryVisibilityBoundary(channelID: group.id, boundary: boundary,
            channelIDForConversation: { row in resolutions += 1; return row.id })
        XCTAssertEqual(resolutions, 0)
        let before = publications
        _ = store.applyHistoryVisibilityBoundary(channelID: group.id, boundary: boundary,
            channelIDForConversation: { row in resolutions += 1; return row.id })
        XCTAssertEqual(publications, before)
        XCTAssertEqual(store.conversationMessageSnapshots().last?.unread, 4)
        XCTAssertEqual(store.conversationMessageSnapshots().count, 1001)
    }

    // WDT_CONVERSATION_LIST_STABILITY_20261103_BEGIN
    func testRepeatedGroupDirectoryRefreshPreservesSnapshotSummaryAndOrder() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let boundary = ConversationStore.HistoryVisibilityBoundary(fromSeq: 1, limited: false, confirmed: true)
        var older = makeMessage(id: "cached-old", seq: 7, time: "10:00", kind: .video)
        older.createdAt = Date(timeIntervalSince1970: 100)
        var snapshot = makeConversation(id: "group", kind: .group, unread: 3, lastMsgSeq: 8, lastReadSeq: 5)
        snapshot.historyBoundaryConfirmed = true
        snapshot.lastMessage = "latest.mp4"
        snapshot.time = "11:00"
        snapshot.sortTimestamp = 300
        var other = makeConversation(id: "other", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        other.sortTimestamp = 200
        var pinned = makeConversation(id: "pinned", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        pinned.isPinned = true
        pinned.sortTimestamp = 50
        let remote = try decodeRemoteConversation("""
        {"channel_id":"group","channel_type":"group","last_msg_seq":8,"unread_count":3}
        """)
        for cachedMessages in [[ChatMessage](), [older]] {
            snapshot.messages = cachedMessages
            store.commitConversationSnapshots([pinned, snapshot, other])
            for _ in 0..<3 {
                _ = store.mergeRemoteConversationList(
                    entries: [.init(channelID: snapshot.id, remote: remote, conversation: snapshot)],
                    replacing: false,
                    channelIDForConversation: { $0.id }
                )
                XCTAssertFalse(store.applyHistoryVisibilityBoundary(
                    channelID: snapshot.id, boundary: boundary, channelIDForConversation: { $0.id }
                ))
                let refreshed = try XCTUnwrap(store.conversationMessageSnapshots().first(where: { $0.id == snapshot.id }))
                XCTAssertEqual(refreshed, snapshot)
                XCTAssertEqual(store.conversationMessageSnapshots().sorted(by: store.conversationListPrecedes).map(\.id),
                               [pinned.id, snapshot.id, other.id])
                XCTAssertNil(conversationListMessageTimestamp(refreshed))
            }
        }
    }

    func testUnchangedGroupBoundaryStillFiltersIneligibleMessagesAndUnread() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "group", kind: .group, unread: 3, lastMsgSeq: 8, lastReadSeq: 0)
        conversation.historyVisibleFromSeq = 8
        conversation.historyLimited = true
        conversation.historyBoundaryConfirmed = true
        conversation.lastMessage = "hidden"
        conversation.sortTimestamp = 300
        var visible = makeMessage(id: "visible", seq: 8)
        visible.createdAt = Date(timeIntervalSince1970: 100)
        conversation.messages = [makeMessage(id: "hidden", seq: 7), visible]
        let bounded = try XCTUnwrap(store.applyingHistoryVisibilityBoundary(
            .init(fromSeq: 8, limited: true, confirmed: true), to: conversation
        ))
        XCTAssertEqual(bounded.messages.map(\.id), [visible.id])
        XCTAssertEqual(bounded.lastMessage, visible.text)
        XCTAssertEqual(bounded.sortTimestamp, 100)
        XCTAssertEqual(bounded.unread, 0)
        XCTAssertEqual(bounded.firstUnreadSeq, 0)
    }
    func testUnchangedGroupBoundaryPreservesSummaryWithoutSkippingUnreadCleanup() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "group", kind: .group, unread: 3, lastMsgSeq: 10, lastReadSeq: 0)
        conversation.historyVisibleFromSeq = 8
        conversation.historyLimited = true
        conversation.historyBoundaryConfirmed = true
        conversation.lastMessage = "latest.mp4"
        conversation.time = "11:00"
        conversation.sortTimestamp = 300
        conversation.messages = [makeMessage(id: "visible", seq: 8)]
        let bounded = try XCTUnwrap(store.applyingHistoryVisibilityBoundary(
            .init(fromSeq: 8, limited: true, confirmed: true), to: conversation
        ))
        XCTAssertEqual(bounded.messages, conversation.messages)
        XCTAssertEqual(bounded.lastMessage, conversation.lastMessage)
        XCTAssertEqual(bounded.time, conversation.time)
        XCTAssertEqual(bounded.sortTimestamp, conversation.sortTimestamp)
        XCTAssertEqual(bounded.lastMsgSeq, 10)
        XCTAssertEqual(bounded.unread, 0)
        XCTAssertEqual(bounded.firstUnreadSeq, 0)
    }
    // WDT_CONVERSATION_LIST_STABILITY_20261103_END

    func testGroupHistoryFallbackDoesNotNormalizeUnrelatedDirectPeers() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots((0..<1000).map { makeConversation(id: "direct-only-\($0)", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1) })
        var resolutions = 0
        let changed = store.applyHistoryVisibilityBoundary(channelID: "absent-group",
            boundary: ConversationStore.HistoryVisibilityBoundary(fromSeq: 4, limited: true, confirmed: true),
            channelIDForConversation: { row in resolutions += 1; return row.id })
        XCTAssertFalse(changed)
        XCTAssertEqual(resolutions, 0)
    }


    func testConversationListLoginUpdatesDoNotRemeasureUnchangedHeaders() async throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: TestMessageMemoryScope.context)
        state.setCurrentUser(makeUser(id: "me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.conversationStore.commitConversationSnapshots([])
        state.bootstrapPresentationStore.sync.isInitialDataLoading = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; window.rootViewController = nil }
        let host = UIHostingController(rootView: NavigationStackCompat { ConversationListView() }.appStateEnvironment(state))
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 150_000_000)
        state.conversationStore.commitConversationSnapshots((0..<1000).map { index in
            makeConversation(id: "login-update-\(index)", kind: .direct, unread: 0, lastMsgSeq: 20, lastReadSeq: 20)
        })
        state.bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        try await Task.sleep(nanoseconds: 400_000_000)
        let headersBefore = ConversationListLayoutDiagnostics.headerMeasurements
        let searchesBefore = ConversationListLayoutDiagnostics.searchMeasurements
        // Login publishes unrelated app state frequently. It must not invalidate table headers.
        for index in 0..<30 {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("sync-\(index)")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertLessThanOrEqual(ConversationListLayoutDiagnostics.headerMeasurements - headersBefore, 2)
        XCTAssertLessThanOrEqual(ConversationListLayoutDiagnostics.searchMeasurements - searchesBefore, 2)
        for index in 0..<20 {
            state.conversationStore.mutateStoredConversation(at: index) { $0.lastMessage = "incoming-\(index)" }
            state.conversationStore.mutateStoredConversation(at: index) { $0.unread += 1 }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertLessThanOrEqual(ConversationListLayoutDiagnostics.headerMeasurements - headersBefore, 2)
        XCTAssertLessThanOrEqual(ConversationListLayoutDiagnostics.searchMeasurements - searchesBefore, 2)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().count, 1000)
    }

    func testConversationListReusesVisibleCellsWithOneThousandConversations() async throws {
        // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111_BEGIN
        // Use a per-run app ID so the app-policy read cannot reuse a previous test's cache.
        let appID = try XCTUnwrap(
            IMAPIContext.allowsRuntimeAppIDOverride ? "conversation-list-snapshot-\(UUID().uuidString)" : nil,
            "Snapshot policy requires an isolated Debug app ID"
        )
        var context = TestMessageMemoryScope.context
        context.appID = appID
        // WDT_IOS1_STAGE0_SNAPSHOT_PERSISTENCE_ISOLATION_20261111_BEGIN
        let defaults = try XCTUnwrap(UserDefaults(suiteName: appID))
        let persistenceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(appID, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: appID)
            try? FileManager.default.removeItem(at: persistenceRoot)
        }
        let state = AppState(
            api: IMAPIClient(
                runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
                startupContext: context // WDT_IOS1_STAGE0_SNAPSHOT_API_STARTUP_CONTEXT_20261111
            ),
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            voiceMediaClient: NoopVoiceMediaClient(),
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
            allowWorkspaceSwitch: false,
            allowDefaultTenantJoin: true,
            cacheTTLSeconds: 60
        )
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111_END
        state.setCurrentUser(makeUser(id: "me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_BEGIN
        let probe = ConversationListMountedProjectionProbe(binding: state.conversationStore.messageMemoryStore.bindingID)
        defer { probe.stop() }
        // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_END
        state.conversationStore.commitConversationSnapshots((0..<1000).map { index in
            var conversation = makeConversation(id: "reuse-\(index)", kind: .direct, unread: index % 3, lastMsgSeq: 20, lastReadSeq: 18)
            conversation.title = "测试会话 \(index)"
            conversation.sortTimestamp = probe.clock.timeIntervalSince1970 - Double(index + 1) // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112
            conversation.messages = (1...20).map { makeMessage(id: "\(index)-\($0)", seq: Int64($0), status: .read, isOutgoing: false) }
            return conversation
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; window.rootViewController = nil }
        let host = UIHostingController(rootView: NavigationStackCompat { ConversationListView() }.appStateEnvironment(state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 450_000_000)
        window.layoutIfNeeded(); host.view.layoutIfNeeded()
        func findTable(_ view: UIView) -> UITableView? {
            if let table = view as? UITableView { return table }
            return view.subviews.lazy.compactMap(findTable).first
        }
        let table = try XCTUnwrap(findTable(host.view))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1002)
        XCTAssertFalse(table.isPrefetchingEnabled)
        XCTAssertGreaterThan(table.visibleCells.count, 0)
        XCTAssertLessThan(table.visibleCells.count, 30)
        // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111_BEGIN
        XCTAssertEqual(state.currentAppPolicy, policy)
        XCTAssertFalse(state.canOpenEnterpriseSwitcher(for: state.currentEnterprise))
        // WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111_END
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "conversation-list-1000-rows"
        attachment.lifetime = .keepAlways
        add(attachment)
        table.scrollToRow(at: IndexPath(row: 800, section: 0), at: .middle, animated: false)
        table.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(table.cellForRow(at: IndexPath(row: 800, section: 0)))
        XCTAssertLessThan(table.visibleCells.count, 30)
        // Incoming updates must wait until dragging and deceleration finish.
        table.delegate?.scrollViewWillBeginDragging?(table)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(state.isConversationListUserInteracting)
        let rebuildsBeforeDrag = ConversationListLayoutDiagnostics.sectionRebuilds
        for index in 0..<20 {
            state.conversationStore.mutateStoredConversation(at: index) { $0.unread += 1 }
        }
        try await simulateConversationListScrollMovement(table, intervals: 7)
        XCTAssertEqual(ConversationListLayoutDiagnostics.sectionRebuilds, rebuildsBeforeDrag)
        table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: true)
        XCTAssertTrue(state.isConversationListUserInteracting)
        try await simulateConversationListScrollMovement(table, intervals: 4)
        XCTAssertEqual(ConversationListLayoutDiagnostics.sectionRebuilds, rebuildsBeforeDrag)
        table.delegate?.scrollViewDidEndDecelerating?(table)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(state.isConversationListUserInteracting)
        XCTAssertGreaterThan(ConversationListLayoutDiagnostics.sectionRebuilds, rebuildsBeforeDrag)
        // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_BEGIN
        try await probe.verifyVisibleUpdates(in: table, store: state.conversationStore, index: 799)
        // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_END
        XCTAssertTrue(findTable(host.view) === table)
        XCTAssertEqual(table.rectForRow(at: IndexPath(row: 800, section: 0)).height, 96, accuracy: 0.5)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1002)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().count, 1000)
        func findField(_ view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            return view.subviews.lazy.compactMap(findField).first
        }
        let field = try XCTUnwrap(findField(host.view))
        XCTAssertTrue(field.becomeFirstResponder())
        probe.projected.removeAll() // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112
        field.text = "reuse-search"; field.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(probe.projected.contains { $0 == nil }) // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112
        XCTAssertTrue(findTable(host.view) === table)
        XCTAssertTrue(field.isFirstResponder, "搜索切换不能替换输入框或丢失键盘")
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
        field.text = ""; field.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1002)
        field.resignFirstResponder()
    }

    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    func testEmptyChatCanMountAndReleaseRepeatedlyForDirectAndGroupConversations() async throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeIsolatedAPIContext())
        state.setCurrentUser(makeUser(id: "me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        let direct = makeConversation(id: "empty-direct", kind: .direct, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        let group = makeConversation(id: "empty-group", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        state.conversationStore.commitConversationSnapshots([direct, group])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }
        for index in 0..<30 {
            let id = index.isMultiple(of: 2) ? direct.id : group.id
            window.rootViewController = UIHostingController(rootView:
                NavigationStackCompat { ChatView(conversationID: id) }.appStateEnvironment(state))
            window.makeKeyAndVisible()
            window.rootViewController?.view.layoutIfNeeded()
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 40_000_000)
            XCTAssertFalse(try XCTUnwrap(window.rootViewController?.view).subviews.isEmpty)
            window.rootViewController = nil
        }
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots().allSatisfy { $0.messages.isEmpty })
    }
    // WDT_IOS1_CHAT_STATE_20261023_END

    // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023_BEGIN
    func testReceiptDenialPreservesReactionsWithoutExposingCountsOrReaders() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "g1", kind: .group, unread: 5, lastMsgSeq: 7, lastReadSeq: 2)
        var message = makeMessage(id: "m1", seq: 7, status: .read, isOutgoing: true)
        message.readCount = 3
        message.readBy = [makeReadReceipt(userID: "old-reader")]
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])
        let response = try decodeRemoteReadReceiptResponse(#"{"read":true,"can_view_details":false,"read_count":4,"unread_count":2,"items":[],"reactions":[{"operator_uid":"u2","emoji":"ok","created_at":"2026-10-23T10:00:00Z"}]}"#)
        XCTAssertFalse(response.canViewDetails)
        XCTAssertTrue(store.applyRemoteReadReceiptDetails(response: response, messageID: "m1", conversationID: "g1",
            makeReadReceipt: makeReadReceipt(from:conversation:), makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)))
        let updated = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertNil(updated.readCount)
        XCTAssertNil(updated.unreadCount)
        XCTAssertTrue(updated.readBy.isEmpty)
        XCTAssertTrue(updated.unreadBy.isEmpty)
        XCTAssertFalse(updated.canViewReadDetails)
        XCTAssertEqual(updated.reactionDetails.count, 1)
        XCTAssertEqual(updated.status, .read)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 5)
        let reactionsOnly = try decodeRemoteReadReceiptResponse(#"{"read":true,"reactions":[{"operator_uid":"u2","emoji":"ok"}]}"#)
        XCTAssertFalse(reactionsOnly.canViewDetails)
        let legacy = try decodeRemoteReadReceiptResponse(#"{"read":true,"read_count":2}"#)
        XCTAssertTrue(legacy.canViewDetails)
    }

    func testReceiptSyncVisibilityIsConversationScopedAndLateDetailsCannotRestoreIt() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "g1", kind: .group, unread: 3, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: true)
        message.readCount = 2
        message.reactionDetails = [ReactionDetail(id: "r1", emoji: "ok", user: makeUser(id: "u2"), time: "10:00")]
        conversation.messages = [message]
        var other = makeConversation(id: "g2", kind: .group, unread: 3, lastMsgSeq: 1, lastReadSeq: 0)
        other.messages = [message]
        store.commitConversationSnapshots([conversation, other])
        XCTAssertTrue(store.updateReadReceiptDetailsVisibility(false, conversationID: "g1"))
        XCTAssertFalse(store.updateReadReceiptDetailsVisibility(false, conversationID: "g1"))
        let receipt = try decodeRemoteReceipt(#"{"message_id":"m1","im_uid":"u2","receipt_type":"read","channel_seq":1}"#)
        _ = store.applyRemoteReadReceipts([receipt], channelID: "g1", readReceiptsEnabled: true,
            channelIDForConversation: { $0.id }, makeReadReceipt: makeReadReceipt(from:conversation:))
        let hidden = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertFalse(hidden.canViewReadDetails)
        XCTAssertNil(hidden.readCount)
        XCTAssertTrue(hidden.readBy.isEmpty)
        XCTAssertEqual(hidden.status, .read)
        XCTAssertEqual(hidden.reactionDetails.count, 1)
        XCTAssertEqual(store.conversationMessageSnapshots()[1], other)
        XCTAssertTrue(store.updateReadReceiptDetailsVisibility(true, conversationID: "g1"))
    }

    func testOrdinaryGroupMemberCannotDisplayCachedReadDetails() {
        let state = AppState(apiContextOverride: makeAuthenticatedAPIContext())
        state.setReadReceiptsEnabled(true)
        state.setCurrentUser(makeUser(id: "me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        var conversation = makeConversation(id: "g1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: true)
        conversation.messages = [message]
        state.conversationStore.commitConversationSnapshots([conversation])
        var group = GroupInfo(id: "g1", name: "g1", notice: "", owner: "Other", members: [], admins: [],
                              muted: false, allMuted: false, allMuteStart: nil, allMuteEnd: nil)
        group.ownerID = "other"
        // WDT_IOS1_RECEIPT_ROLE_20261023_BEGIN
        for tenantRole in ["member", "internal", "admin", "unknown", ""] {
            state.setCurrentEnterprise(Enterprise(id: "tenant", name: "test", code: "test", role: tenantRole,
                status: "normal", memberCount: 1, isDefault: true, accentHex: 0)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            for groupRole in ["member", "admin", "owner"] {
                group.myRole = groupRole
                state.groups = [group]
                // WDT_RECEIPT_DETAIL_SCOPE_20261023: even an authorized tenant role needs an explicit sync grant.
                state.applyReadReceiptDetailAuthority(true, conversationID: conversation.id)
                XCTAssertEqual(state.canViewMessageReadDetails(message, in: conversation),
                    ["internal", "admin"].contains(tenantRole), "tenant=\(tenantRole), group=\(groupRole)")
            }
        }
        // WDT_IOS1_RECEIPT_ROLE_20261023_END
        message.canViewReadDetails = false
        XCTAssertFalse(state.canViewMessageReadDetails(message, in: conversation))
        message.canViewReadDetails = true
        let unrelated = makeConversation(id: "not-g1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        XCTAssertFalse(state.canViewMessageReadDetails(message, in: unrelated))
    }
    // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023_END

    // WDT_RECEIPT_DETAIL_SCOPE_20261023_BEGIN
    func testDirectAndOrdinaryGroupDetailLoaderMakesNoPersonnelRequest() async {
        for kind in [ConversationKind.direct, .group] {
            for role in ["member", "admin", "internal", "unknown", ""] {
                let transport = FakeHTTPTransport(results: [])
                let state = makeReceiptDetailTestState(transport: transport, kind: kind, role: role)
                if kind == .direct || !["admin", "internal"].contains(role) {
                    state.applyReadReceiptDetailAuthority(true, conversationID: "c1")
                    await state.loadReadReceipts(messageID: "m1", in: "c1").value
                    XCTAssertTrue(transport.requests().isEmpty, "\(kind) \(role)")
                    XCTAssertEqual(state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .read)
                    XCTAssertEqual(state.conversationStore.conversationMessageSnapshots()[0].messages[0].reactionDetails.count, 1)
                    XCTAssertNil(state.conversationStore.conversationMessageSnapshots()[0].messages[0].readCount)
                    XCTAssertNil(state.toast)
                    XCTAssertTrue(state.isAuthenticated)
                }
            }
        }
    }

    func testUnknownReceiptAuthorityDoesNotUseDefaultMessagePermission() async {
        let transport = FakeHTTPTransport(results: [])
        let state = makeReceiptDetailTestState(transport: transport, kind: .group, role: "admin")
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots()[0].messages[0].canViewReadDetails)
        XCTAssertFalse(state.canViewMessageReadDetails(state.conversationStore.conversationMessageSnapshots()[0].messages[0], in: state.conversationStore.conversationMessageSnapshots()[0]))
        await state.loadReadReceipts(messageID: "m1", in: "c1").value
        XCTAssertTrue(transport.requests().isEmpty)
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots()[0].messages[0].readBy.isEmpty)
        XCTAssertNil(state.toast)
        state.applyReadReceiptDetailAuthority(true, conversationID: "c1")
        XCTAssertTrue(state.canViewMessageReadDetails(state.conversationStore.conversationMessageSnapshots()[0].messages[0], in: state.conversationStore.conversationMessageSnapshots()[0]))
    }

    // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110_BEGIN
    func testReadReceiptAuthorityPublishesOnlyToMatchingConversation() {
        let state = makeReceiptDetailTestState(
            transport: FakeHTTPTransport(results: []), kind: .group, role: "admin"
        )
        state.storeCancellables.removeAll()
        let conversation = state.conversationStore.conversationMessageSnapshots()[0]
        let message = conversation.messages[0]
        let other = makeConversation(id: "c2", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        state.conversationStore.mutateMessageSnapshotsForTesting { $0.append(other) }
        let initialScope = state.readReceiptDetailScope

        var applicationUpdates = 0
        var primaryUpdates: [Bool?] = []
        var otherUpdates: [Bool?] = []
        let app = state.objectWillChange.sink { applicationUpdates += 1 }
        let primary = state.readReceiptAuthorityStore.updates(for: conversation.id)
            .sink { primaryUpdates.append($0?.allowed) }
        let secondary = state.readReceiptAuthorityStore.updates(for: other.id)
            .sink { otherUpdates.append($0?.allowed) }
        defer {
            app.cancel()
            primary.cancel()
            secondary.cancel()
        }

        state.applyReadReceiptDetailAuthority(true, conversationID: other.id)
        XCTAssertEqual(primaryUpdates, [nil])
        XCTAssertFalse(state.canViewMessageReadDetails(message, in: conversation))

        state.applyReadReceiptDetailAuthority(true, conversationID: conversation.id)
        state.applyReadReceiptDetailAuthority(true, conversationID: conversation.id)
        XCTAssertTrue(state.canViewMessageReadDetails(message, in: conversation))

        state.clearReadReceiptDetailAuthority(conversationID: conversation.id)
        XCTAssertFalse(state.canViewMessageReadDetails(message, in: conversation))
        XCTAssertEqual(otherUpdates, [nil, true])

        state.invalidateReadReceiptDetailAuthorities()
        XCTAssertNotEqual(initialScope, state.readReceiptDetailScope)
        XCTAssertEqual(primaryUpdates, [nil, true, false, nil])
        XCTAssertEqual(otherUpdates, [nil, true, nil])
        XCTAssertEqual(applicationUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110_BEGIN
    func testChatAvailabilityUpdatesOnlyTheMatchingConversation() async throws {
        let state = AppState(apiContextOverride: TestMessageMemoryScope.context)
        let store = state.conversationStore
        var selected: [ConversationStore.ChatAvailabilitySnapshot] = []
        var appChanges = 0
        let status = store.chatAvailabilityUpdates(for: "selected").sink { selected.append($0) }
        let app = state.objectWillChange.sink { appChanges += 1 }
        defer { status.cancel(); app.cancel() }
        store.setHistoryMessage(conversationID: "other", message: "Other error")
        XCTAssertTrue(store.beginApplyingFriend(conversationID: "other"))
        XCTAssertEqual(selected.count, 1)

        store.historyLoadingIDs.insert("selected")
        store.setHistoryMessage(conversationID: "selected", message: "History status")
        store.setDirectDisabledMessage(conversationID: "selected", message: "Blocked")
        let context = DirectFriendRequestContext(
            targetUID: "peer", canApplyFriend: true, friendRequestStatus: "", reasonCode: "friendship_required"
        )
        store.setDirectFriendRequestContext(conversationID: "selected", context: context)
        XCTAssertTrue(store.beginApplyingFriend(conversationID: "selected"))
        XCTAssertEqual(selected.count, 6)
        XCTAssertEqual(selected.last, store.chatAvailability(for: "selected"))
        XCTAssertEqual(selected.last?.friendRequestContext, context)

        store.finishApplyingFriend(conversationID: "selected")
        XCTAssertEqual(selected.last?.isApplyingFriend, false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(appChanges, 0)
        // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110_BEGIN
        var unread: [Int?] = []
        let conversation = store.conversationPresentationUpdates(id: "selected").sink { unread.append($0?.unread) }
        defer { conversation.cancel() }
        store.commitConversationSnapshots([makeConversation(id: "selected", kind: .direct, unread: 1, lastMsgSeq: 1, lastReadSeq: 0)])
        store.mutateMessageSnapshotsForTesting { $0.append(makeConversation(id: "other", kind: .group, unread: 3, lastMsgSeq: 3, lastReadSeq: 0)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(unread, [nil, 1])
        XCTAssertEqual(appChanges, 0)
        // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110_END
    }
    // WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110_END

    func testDirectReceiptPanelLoadsRealReactionsOnlyThroughExtras() async {
        let response = HTTPTransportResult(data: Data(#"{"ok":true,"data":{"items":[{"message_id":"m1","channel_id":"c1","channel_type":"direct","operator_uid":"reader-2","extra_type":"reaction","emoji":"ok","action":"add","version":1,"payload":{"display_name":"Reader Two"}}]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        let transport = FakeHTTPTransport(results: [response])
        let state = makeReceiptDetailTestState(transport: transport, kind: .direct, role: "admin")
        await state.prepareReadReceiptPanel(messageID: "m1", in: "c1").value
        XCTAssertTrue(transport.requests().contains { $0.url?.path == "/api/im/message-extras/sync" })
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/read-receipts") == true })
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots()[0].messages[0].reactionDetails.contains { $0.user.id == "reader-2" })
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots()[0].messages[0].status, .read)
        XCTAssertNil(state.toast)
    }

    func testReceiptPermissionDenialClearsDetailsWithoutLoggingOutOrChangingReadState() async {
        for code in ["permission_denied", "forbidden", "read_receipt_details_forbidden"] {
            let response = HTTPTransportResult(data: Data("{\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"没有权限查看或执行该操作\"}}".utf8), isHTTPResponse: true, statusCode: 403)
            let transport = FakeHTTPTransport(results: [response])
            let state = makeReceiptDetailTestState(transport: transport, kind: .group, role: "admin")
            state.applyReadReceiptDetailAuthority(true, conversationID: "c1")
            await state.loadReadReceipts(messageID: "m1", in: "c1").value
            XCTAssertEqual(transport.requests().filter { $0.url?.path.hasSuffix("/read-receipts") == true }.count, 1)
            let message = state.conversationStore.conversationMessageSnapshots()[0].messages[0]
            XCTAssertTrue(message.readBy.isEmpty)
            XCTAssertNil(message.readCount)
            XCTAssertFalse(message.canViewReadDetails)
            XCTAssertEqual(message.status, .read)
            XCTAssertEqual(message.reactionDetails.count, 1)
            XCTAssertEqual(state.conversationStore.conversationMessageSnapshots()[0].unread, 3)
            XCTAssertNil(state.toast)
            XCTAssertTrue(state.isAuthenticated)
        }
    }

    func testAuthorizedReceiptResponseCannotOverwriteSyncedReactions() async {
        let transport = FakeHTTPTransport(results: [receiptDetailSuccessResponse()])
        let state = makeReceiptDetailTestState(transport: transport, kind: .group, role: "internal")
        state.applyReadReceiptDetailAuthority(true, conversationID: "c1")
        let reactions = state.conversationStore.conversationMessageSnapshots()[0].messages[0].reactionDetails
        await state.loadReadReceipts(messageID: "m1", in: "c1").value
        XCTAssertEqual(transport.requests().count, 1)
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots()[0].messages[0].readBy.contains { $0.user.id == "new-reader" })
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots()[0].messages[0].reactionDetails, reactions)
        XCTAssertNil(state.toast)
    }

    func testRestrictedReceiptResponsePreservesUnknownBinaryStatus() async {
        let response = HTTPTransportResult(data: Data(#"{"ok":true,"data":{"can_view_details":false,"read_count":99,"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        let transport = FakeHTTPTransport(results: [response])
        let state = makeReceiptDetailTestState(transport: transport, kind: .group, role: "admin")
        state.applyReadReceiptDetailAuthority(true, conversationID: "c1")
        state.conversationStore.mutateStoredConversation(at: 0) { $0.messages[0].status = .sent }
        state.conversationStore.mutateStoredConversation(at: 0) { $0.messages[0].readStateKnown = false }
        await state.loadReadReceipts(messageID: "m1", in: "c1").value
        let message = state.conversationStore.conversationMessageSnapshots()[0].messages[0]
        XCTAssertEqual(message.status, .sent)
        XCTAssertFalse(message.readStateKnown)
        XCTAssertNil(message.readCount)
        XCTAssertTrue(message.readBy.isEmpty)
        XCTAssertEqual(message.reactionDetails.count, 1)
        XCTAssertNil(state.toast)
    }

    func testLateReceiptResponseIsDiscardedAfterScopeSelectionOrAuthorityChanges() async throws {
        for change in ["role", "tenant", "session", "selection", "authority", "message"] {
            let transport = FakeHTTPTransport(results: [receiptDetailSuccessResponse()], delayNanoseconds: 120_000_000)
            let state = makeReceiptDetailTestState(transport: transport, kind: .group, role: "admin")
            state.applyReadReceiptDetailAuthority(true, conversationID: "c1")
            state.conversationStore.mutateStoredConversation(at: 0) { $0.messages[0].readBy = [] }
            state.conversationStore.mutateStoredConversation(at: 0) { $0.messages[0].status = .sent }
            let task = state.loadReadReceipts(messageID: "m1", in: "c1")
            for _ in 0..<100 where transport.requests().isEmpty {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertFalse(transport.requests().isEmpty)
            switch change {
            case "role", "tenant":
                state.setCurrentEnterprise(Enterprise(id: change == "tenant" ? "tenant-2" : "tenant-1",
                    name: "Test", code: "Test", role: change == "role" ? "member" : "admin",
                    status: "normal", memberCount: 1, isDefault: true, accentHex: 0)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            case "session": state.localMessageSessionGeneration &+= 1
            case "selection": state.leaveRealtimeConversation("c1")
            case "authority": state.applyReadReceiptDetailAuthority(false, conversationID: "c1")
            default: state.conversationStore.mutateStoredConversation(at: 0) { $0.messages.removeAll() }
            }
            await task.value
            if let message = state.conversationStore.conversationMessageSnapshots()[0].messages.first {
                XCTAssertTrue(message.readBy.isEmpty, change)
                XCTAssertEqual(message.status, .sent, change)
                XCTAssertEqual(message.reactionDetails.count, 1, change)
            }
            XCTAssertNil(state.toast)
        }
    }

    private func receiptDetailSuccessResponse() -> HTTPTransportResult {
        HTTPTransportResult(data: Data(#"{"ok":true,"data":{"read":true,"can_view_details":true,"items":[{"message_id":"m1","im_uid":"new-reader","receipt_type":"read","channel_seq":1}],"read_count":1,"unread_count":0,"reactions":[{"operator_uid":"stale-reactor","emoji":"old"}]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
    }

    private func makeReceiptDetailTestState(transport: HTTPTransport, kind: ConversationKind, role: String) -> AppState {
        let syncEngine = DefaultSyncEngine()
        _ = syncEngine.beginRemoteSnapshotRefresh()
        let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: NoopVoiceMediaClient(),
                             remoteSyncEngine: syncEngine, apiContextOverride: makeAuthenticatedAPIContext())
        state.setCurrentEnterprise(Enterprise(id: "tenant-1", name: "Test", code: "Test", role: role,
                                             status: "normal", memberCount: 1, isDefault: true, accentHex: 0)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setReadReceiptsEnabled(true)
        var conversation = makeConversation(id: "c1", kind: kind, unread: 3, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: true)
        message.readBy = [makeReadReceipt(userID: "old-reader")]
        message.readCount = 1
        message.reactionDetails = [ReactionDetail(id: "real", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")]
        conversation.messages = [message]
        state.conversationStore.commitConversationSnapshots([conversation])
        _ = state.conversationSelectionEpochFence.select(scope: state.remoteDataScopeKey(for: state.apiContext), conversationID: "c1")
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(nil)
        return state
    }
    // WDT_RECEIPT_DETAIL_SCOPE_20261023_END

    // WDT_CHAT_FIX2_DELETE_REFRESH_20261023_BEGIN
    func testRemovalRefreshUsesPublishedSnapshotAndIgnoresOrdinaryUpdates() {
        let original = (1...3).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        XCTAssertFalse(chatNeedsImmediateRemovalRefresh(cachedMessages: original, messages: original))
        var next = original
        next[1].isDeletedLocally = true
        XCTAssertTrue(chatNeedsImmediateRemovalRefresh(cachedMessages: original, messages: next))
        next = original
        next[1].status = .recalled
        XCTAssertTrue(chatNeedsImmediateRemovalRefresh(cachedMessages: original, messages: next))
        XCTAssertTrue(chatNeedsImmediateRemovalRefresh(cachedMessages: original, messages: [original[0], original[2]]))
        XCTAssertTrue(chatNeedsImmediateRemovalRefresh(cachedMessages: original, messages: []))
        next = original
        next[1].status = .read
        XCTAssertFalse(chatNeedsImmediateRemovalRefresh(cachedMessages: original, messages: next))
        XCTAssertFalse(chatNeedsImmediateRemovalRefresh(cachedMessages: original, messages: original + [makeMessage(id: "m4", seq: 4)]))
        XCTAssertFalse(chatNeedsImmediateRemovalRefresh(cachedMessages: original, messages: [makeMessage(id: "m0", seq: 0)] + original))
    }
    // WDT_CHAT_FIX2_DELETE_REFRESH_20261023_END

    // WDT_CHAT_FIX4_USER_ID_HINT_20261023_BEGIN
    func testFindUserHintUsesOwnNumericSuffixWithoutPrefixDigitsOrInventedID() {
        XCTAssertEqual(findUserNumericIDHint(userID: "AA-U910273"), "你ID是“AA-U910273”，对方只需输入“910273”即可找到你。")
        XCTAssertEqual(findUserNumericIDHint(userID: " AA12-U000045 "), "你ID是“AA12-U000045”，对方只需输入“000045”即可找到你。")
        XCTAssertNotNil(findUserNumericIDHint(userID: "910273"))
        for invalid in ["", "AA-U", "pending", "AA-U12b", "AA-U１２３"] {
            XCTAssertNil(findUserNumericIDHint(userID: invalid))
        }
    }
    // WDT_CHAT_FIX4_USER_ID_HINT_20261023_END

    // WDT_CHAT_FIX5_RETURN_BOTTOM_20261023_BEGIN
    func testReturnToBottomOverlayKeepsItsActionAndUsesBottomTrailingPlacement() throws { // WDT_IOS1_CORE_CHAT_SOURCE_READERS_20261111_BEGIN
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent(); let feature = root.appendingPathComponent("Sources/IM4Features/Chat", isDirectory: true)
        let assembly = try String(contentsOf: root.appendingPathComponent("WenDaTong/App/ChatTranscriptLayoutAssembly.swift"), encoding: .utf8)
        let layout = try String(contentsOf: feature.appendingPathComponent("ChatViewLayout.swift"), encoding: .utf8) + String(contentsOf: feature.appendingPathComponent("ChatScreenLayout.swift"), encoding: .utf8) + String(contentsOf: feature.appendingPathComponent("ChatTimelineLayout.swift"), encoding: .utf8)
        let consumer = try String(contentsOf: feature.appendingPathComponent("ChatHistorySupportViews.swift"), encoding: .utf8)
        let receipts = try String(contentsOf: feature.appendingPathComponent("ReadReceiptSheet.swift"), encoding: .utf8)
        let start = try XCTUnwrap(layout.range(of: "struct ChatReturnToBottomOverlay")); let overlay = String(layout[start.lowerBound...])
        XCTAssertTrue(overlay.contains("ZStack(alignment: .bottomTrailing)"))
        XCTAssertTrue(overlay.contains(".padding(.bottom, 12)"))
        XCTAssertTrue(assembly.contains("ChatReturnToBottomOverlay(")); XCTAssertTrue(overlay.contains("ReturnToBottomBar(count: pendingUnreadCount, action: returnToBottom)"))
        XCTAssertTrue(assembly.contains("chatReturnToBottomActionPlan(bottomAnchorID: bottomAnchorID)"))
        XCTAssertTrue(assembly.contains("setScrollTarget(plan.targetID, source: plan.source, anchor: plan.anchor)"))
        XCTAssertTrue(consumer.contains("struct ReturnToBottomBar: View")); XCTAssertTrue(consumer.contains("Button(action: action)"))
        XCTAssertEqual(receipts.components(separatedBy: "emptyText: \"未统计明细\"").count - 1, 2)
        XCTAssertTrue(receipts.contains("receiptSection(title: \"已读\", receipts: [], read: true, emptyText: \"未统计明细\")")); XCTAssertTrue(receipts.contains("receiptSection(title: \"未读\", receipts: [], read: false, emptyText: \"未统计明细\")"))
    } // WDT_IOS1_CORE_CHAT_SOURCE_READERS_20261111_END
    // WDT_CHAT_FIX5_RETURN_BOTTOM_20261023_END

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_BEGIN
extension DomainStoreTests {
    func testConversationListCommitSelectsOneWindowAndRejectsRetiredBinding() throws {
        let scope = try LocalMessageScope(context: TestMessageMemoryScope.context)
        let store = ConversationStore(scope: scope)
        let memory = store.messageMemoryStore
        var target = makeConversation(id: "target", unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        target.messages = [makeMessage(id: "m", seq: 1, status: .read, isOutgoing: false)]
        let peer = makeConversation(id: "peer", unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        store.commitConversationSnapshots([target, peer])
        let changes = ConversationListMemoryChanges()
        changes.didProject(binding: memory.bindingID, revision: memory.revision)
        var commits: [ConversationStore.MemoryCommit] = []
        let commit = store.memoryCommits.sink { commits.append($0) }
        var peerEvents = 0
        let row = memory.conversationRowUpdates(id: peer.id).dropFirst().sink { _ in peerEvents += 1 }
        defer { commit.cancel(); row.cancel() }
        store.mutateStoredConversation(at: 0) { $0.messages[0].text = "Changed" }
        let single = try XCTUnwrap(commits.last)
        XCTAssertTrue(changes.receive(single, activeBinding: memory.bindingID))
        XCTAssertEqual(changes.pending, .rows([target.id]))
        XCTAssertEqual(changes.row(id: target.id, in: memory)?.messages.first?.text, "Changed")
        XCTAssertEqual(peerEvents, 0)
        store.commitConversationSnapshots([target])
        XCTAssertTrue(changes.receive(try XCTUnwrap(commits.last), activeBinding: memory.bindingID))
        XCTAssertEqual(changes.pending, .full)
        store.bindMessageScope(nil, preservesMessages: false)
        XCTAssertFalse(changes.receive(single, activeBinding: memory.bindingID))
        XCTAssertNil(changes.row(id: target.id, in: memory))
    }
}
// WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_END

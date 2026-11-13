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
    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    func testAnnouncementProjectionPublishesOnlyAnnouncementChangesWithoutGlobalRefresh() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store = state.contactStore
        var snapshots: [[InboxItem]] = []
        var globalUpdates = 0
        let announcements = store.announcementUpdates.sink { snapshots.append($0) }
        let global = state.objectWillChange.sink { globalUpdates += 1 }
        defer {
            announcements.cancel()
            global.cancel()
        }

        let notice = InboxItem(
            id: "notice", title: "系统消息", subtitle: "", time: "", category: "系统", isRead: false, accentHex: 0
        )
        var announcement = InboxItem(
            id: "announcement", title: "企业公告", subtitle: "", time: "", category: "公告", isRead: false, accentHex: 0
        )
        store.inboxItems = [notice]
        XCTAssertEqual(snapshots, [[]])
        store.inboxItems = [notice, announcement]
        XCTAssertEqual(snapshots.last, [announcement])
        XCTAssertEqual(store.announcements.filter { !$0.isRead }.map(\.id), ["announcement"])
        announcement.isRead = true
        store.inboxItems[1] = announcement
        XCTAssertEqual(snapshots.last, [announcement])
        XCTAssertTrue(store.announcements.filter { !$0.isRead }.isEmpty)
        store.inboxItems = []
        XCTAssertEqual(snapshots, [[], [InboxItem(
            id: "announcement", title: "企业公告", subtitle: "", time: "", category: "公告", isRead: false, accentHex: 0
        )], [announcement], []])

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(globalUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    func testGroupAnnouncementObserversSeparateCurrentAndSelectedDetails() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store = state.contactStore
        var banner: [String?] = []
        var detail: [String?] = []
        var globalUpdates = 0
        let bannerObservation = store.currentGroupAnnouncementUpdates(groupID: "group").sink { banner.append($0?.id) }
        let detailObservation = store.groupAnnouncementUpdates(groupID: "group", announcementID: "old").sink { detail.append($0?.id) }
        let globalObservation = state.objectWillChange.sink { globalUpdates += 1 }
        defer {
            bannerObservation.cancel()
            detailObservation.cancel()
            globalObservation.cancel()
        }
        func announcement(_ id: String, group: String) -> GroupAnnouncement {
            GroupAnnouncement(id: id, groupID: group, title: "公告", content: "内容", summary: "",
                createdBy: "owner", status: "published", createdAt: "", updatedAt: "", publishedAt: "", unread: true,
                readAt: nil, displayPosition: "", readAction: "", readCount: nil, unreadCount: nil,
                recipientCount: nil, canViewReadCounts: false)
        }
        let foreign = announcement("old", group: "other")
        let latest = announcement("latest", group: "group")
        store.groupAnnouncements["other"] = [foreign]
        store.currentGroupAnnouncements["other"] = foreign
        store.groupAnnouncements["group"] = [latest, announcement("old", group: "group")]
        XCTAssertEqual(banner, [nil])
        XCTAssertEqual(detail, [nil, "old"])
        XCTAssertEqual(store.groupAnnouncement(groupID: "group", announcementID: nil)?.id, "latest")

        store.currentGroupAnnouncements["group"] = latest
        store.currentGroupAnnouncements["group"] = nil
        XCTAssertEqual(banner, [nil, "latest", nil])
        XCTAssertEqual(detail, [nil, "old"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(globalUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110_END

    func testContactStoreInboxRuntimeStateLifecycle() {
        let store = ContactStore()

        XCTAssertTrue(store.knownInboxIDs().isEmpty)
        XCTAssertFalse(store.hasKnownInboxIDs())
        XCTAssertFalse(store.isSystemInboxReadLocally(id: "system1"))

        store.replaceKnownInboxIDs(["inbox1"])
        XCTAssertEqual(store.knownInboxIDs(), ["inbox1"])
        XCTAssertTrue(store.hasKnownInboxIDs())

        store.mergeKnownInboxIDs(["inbox2", "inbox1"])
        XCTAssertEqual(store.knownInboxIDs(), ["inbox1", "inbox2"])

        store.rememberSystemInboxReadLocally(id: "")
        XCTAssertFalse(store.hasLocallyReadSystemInboxIDs())

        store.rememberSystemInboxReadLocally(id: "system1")
        XCTAssertTrue(store.isSystemInboxReadLocally(id: "system1"))
        XCTAssertTrue(store.hasLocallyReadSystemInboxIDs())

        store.reset()
        XCTAssertTrue(store.knownInboxIDs().isEmpty)
        XCTAssertFalse(store.isSystemInboxReadLocally(id: "system1"))
    }

    func testContactStoreContactsSyncStateAndErrorLifecycle() {
        let store = ContactStore()

        XCTAssertFalse(store.isContactsSyncing())
        XCTAssertNil(store.contactsSyncError())

        XCTAssertTrue(store.beginContactsSync())
        XCTAssertFalse(store.beginContactsSync())
        XCTAssertTrue(store.isContactsSyncing())

        store.setContactsSyncError("通讯录同步失败，请稍后重试")
        XCTAssertEqual(store.contactsSyncError(), "通讯录同步失败，请稍后重试")

        store.finishContactsSync()
        XCTAssertFalse(store.isContactsSyncing())

        XCTAssertTrue(store.beginContactsSync())
        XCTAssertNil(store.contactsSyncError())
        store.finishContactsSync()
    }

    func testContactStoreAnnouncementDetailLoadingKeyAndLifecycleDedupesRequests() {
        let store = ContactStore()
        let context = store.groupAnnouncementDetailLoadingKeyContext(
            groupID: " group-1 ",
            announcementID: " announcement-1 "
        )

        XCTAssertEqual(
            context,
            ContactStore.GroupAnnouncementDetailLoadingKeyContext(
                groupID: "group-1",
                announcementID: "announcement-1"
            )
        )
        XCTAssertEqual(context.loadingKey, "group-1|announcement-1")
        XCTAssertFalse(store.hasAnnouncementDetailLoadingKeys())
        XCTAssertFalse(store.beginGroupAnnouncementDetailLoading(loadingKey: " "))
        XCTAssertTrue(store.beginGroupAnnouncementDetailLoading(loadingKey: " \(context.loadingKey) "))
        XCTAssertFalse(store.beginGroupAnnouncementDetailLoading(loadingKey: context.loadingKey))
        XCTAssertTrue(store.isGroupAnnouncementDetailLoading(loadingKey: context.loadingKey))
        XCTAssertTrue(store.hasAnnouncementDetailLoadingKeys())

        store.finishGroupAnnouncementDetailLoading(loadingKey: " \(context.loadingKey) ")

        XCTAssertFalse(store.isGroupAnnouncementDetailLoading(loadingKey: context.loadingKey))
        XCTAssertFalse(store.hasAnnouncementDetailLoadingKeys())
        XCTAssertTrue(store.beginGroupAnnouncementDetailLoading(loadingKey: context.loadingKey))
    }

    func testContactStoreGroupBundleRefreshLifecycleQueuesPendingFullRefreshAfterLightRefresh() {
        let store = ContactStore()
        let context = store.groupBundleRefreshKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            groupID: " group-1 "
        )

        XCTAssertEqual(
            context,
            ContactStore.GroupBundleRefreshKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                groupID: "group-1"
            )
        )
        XCTAssertEqual(context.refreshKey, "tenant-a|user-a|group-1")
        XCTAssertFalse(store.hasGroupBundleRefreshModes())
        XCTAssertFalse(store.hasGroupBundlePendingFullRefreshKeys())
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: " ", includeSecondaryData: false))
        XCTAssertTrue(store.beginGroupBundleRefresh(refreshKey: " \(context.refreshKey) ", includeSecondaryData: false))
        XCTAssertTrue(store.isGroupBundleRefreshInFlight(refreshKey: context.refreshKey))
        XCTAssertEqual(store.groupBundleRefreshIncludesSecondaryData(refreshKey: context.refreshKey), false)
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: context.refreshKey, includeSecondaryData: false))
        XCTAssertFalse(store.hasGroupBundlePendingFullRefreshKeys())
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: context.refreshKey, includeSecondaryData: true))
        XCTAssertTrue(store.isGroupBundlePendingFullRefresh(refreshKey: context.refreshKey))
        XCTAssertTrue(store.hasGroupBundlePendingFullRefreshKeys())
        XCTAssertTrue(store.finishGroupBundleRefresh(refreshKey: " \(context.refreshKey) "))
        XCTAssertFalse(store.isGroupBundleRefreshInFlight(refreshKey: context.refreshKey))
        XCTAssertFalse(store.isGroupBundlePendingFullRefresh(refreshKey: context.refreshKey))

        XCTAssertTrue(store.beginGroupBundleRefresh(refreshKey: context.refreshKey, includeSecondaryData: true))
        XCTAssertEqual(store.groupBundleRefreshIncludesSecondaryData(refreshKey: context.refreshKey), true)
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: context.refreshKey, includeSecondaryData: true))
        XCTAssertFalse(store.hasGroupBundlePendingFullRefreshKeys())
        XCTAssertFalse(
            store.beginGroupBundleRefresh(
                refreshKey: context.refreshKey,
                includeSecondaryData: true,
                queueIfAlreadyRunning: true
            )
        )
        XCTAssertTrue(store.isGroupBundlePendingFullRefresh(refreshKey: context.refreshKey))
        XCTAssertTrue(store.finishGroupBundleRefresh(refreshKey: context.refreshKey))
    }

    func testConversationStoreResetClearsRuntimeStateAndCancelsTasks() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let warmTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        XCTAssertTrue(store.beginMessageSync(historyKey: "loading|c1", conversationID: "c1", showLoadingIndicator: true))
        store.setHistoryMessage(conversationID: "c1", message: "loading")
        store.setDirectDisabledMessage(conversationID: "c1", message: "disabled")
        XCTAssertTrue(store.beginApplyingFriend(conversationID: "c1"))
        store.setDirectFriendRequestContext(
            conversationID: "c1",
            context: DirectFriendRequestContext(
                targetUID: "u1",
                canApplyFriend: true,
                friendRequestStatus: "",
                reasonCode: "friendship_required"
            )
        )
        store.rememberRead(key: "c1", readSeq: 10)
        store.markOlderHistoryNeedsContinue(
            historyKey: "backfill|c1",
            conversationID: "c1",
            nextBackfillAfterSeq: 103,
            pageLimit: 100,
            message: "continue"
        )
        store.markHistoryUnavailable(historyKey: "reached|c1", conversationID: "c1", message: "done")
        XCTAssertTrue(store.beginOlderHistoryLoad(
            historyKey: "load|c1",
            conversationID: "c1",
            now: Date(),
            throttleInterval: 1
        ))
        store.rememberConversationBottomSeq(9, stateKey: "scope|c1")
        store.prepareActiveRealtimeConversationAutoRead(conversationID: "c1")
        XCTAssertTrue(store.updateActiveRealtimeConversationAutoRead(
            conversationID: "c1",
            activeConversationID: "c1",
            canAutoRead: true
        ))
        let resetReactionExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "thumbs_up",
          "action": "add",
          "created_at": "2026-06-23T10:00:00Z",
          "payload": {}
        }
        """)
        XCTAssertTrue(store.shouldApplyReactionExtra(resetReactionExtra))
        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: "c1"))
        XCTAssertTrue(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: false))
        store.replaceWarmRefreshTask(refreshKey: "c1", task: warmTask)
        XCTAssertTrue(store.beginMessageExtrasSync(syncKey: "m1"))
        XCTAssertTrue(store.beginMessageReceiptsSync(syncKey: "m2"))
        XCTAssertTrue(store.beginReadAckSync(syncKey: "read|c1"))
        XCTAssertTrue(store.beginPinnedMessagesRefresh(refreshKey: "pin|c1"))

        store.reset()

        XCTAssertFalse(store.hasHistoryLoadingIDs())
        XCTAssertFalse(store.hasHistoryMessages())
        XCTAssertFalse(store.hasDirectDisabledMessages())
        XCTAssertFalse(store.hasApplyingFriendIDs())
        XCTAssertFalse(store.hasDirectFriendRequestContexts())
        XCTAssertFalse(store.hasLocallyReadSeqs())
        XCTAssertFalse(store.hasHistoryBackfillAfterSeqs())
        XCTAssertFalse(store.hasHistoryReachedStartKeys())
        XCTAssertFalse(store.hasHistoryLoadRequestTimes())
        XCTAssertFalse(store.hasConfirmedConversationBottomSeqs())
        XCTAssertFalse(store.hasActiveRealtimeConversationAutoReadStates())
        XCTAssertFalse(store.hasAppliedReactionExtraKeys())
        XCTAssertFalse(store.hasHistorySyncErrorToastTimes())
        XCTAssertFalse(store.isMessageSyncInFlight(historyKey: "scope|c1"))
        XCTAssertFalse(store.hasWarmRefreshTasks())
        XCTAssertFalse(store.isMessageExtrasSyncInFlight(syncKey: "m1"))
        XCTAssertFalse(store.isMessageReceiptsSyncInFlight(syncKey: "m2"))
        XCTAssertFalse(store.isReadAckSyncInFlight(syncKey: "read|c1"))
        XCTAssertFalse(store.isPinnedMessagesRefreshInFlight(refreshKey: "pin|c1"))
        XCTAssertTrue(warmTask.isCancelled)
    }

    func testConversationStoreSidecarSyncLifecycleDedupesExtrasAndReceiptsIndependently() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)

        XCTAssertFalse(store.beginMessageExtrasSync(syncKey: ""))
        XCTAssertFalse(store.beginMessageReceiptsSync(syncKey: ""))

        XCTAssertTrue(store.beginMessageExtrasSync(syncKey: "scope|c1"))
        XCTAssertTrue(store.isMessageExtrasSyncInFlight(syncKey: "scope|c1"))
        XCTAssertFalse(store.beginMessageExtrasSync(syncKey: "scope|c1"))
        XCTAssertTrue(store.beginMessageReceiptsSync(syncKey: "scope|c1"))
        XCTAssertTrue(store.isMessageReceiptsSyncInFlight(syncKey: "scope|c1"))

        store.finishMessageExtrasSync(syncKey: "scope|c1")
        XCTAssertFalse(store.isMessageExtrasSyncInFlight(syncKey: "scope|c1"))
        XCTAssertTrue(store.isMessageReceiptsSyncInFlight(syncKey: "scope|c1"))

        store.finishMessageReceiptsSync(syncKey: "scope|c1")
        XCTAssertFalse(store.isMessageReceiptsSyncInFlight(syncKey: "scope|c1"))
        XCTAssertTrue(store.beginMessageExtrasSync(syncKey: "scope|c1"))
    }

    func testConversationStorePinnedMessagesRefreshKeyAndLifecycleUsesSyncEngine() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let context = store.pinnedMessagesRefreshKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            conversationID: " conversation-1 ",
            channelID: " group-1 "
        )

        XCTAssertEqual(
            context,
            ConversationStore.PinnedMessagesRefreshKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                conversationID: "conversation-1",
                channelID: "group-1"
            )
        )
        XCTAssertEqual(context.refreshKey, "tenant-a|user-a|conversation-1|group-1")
        XCTAssertFalse(store.beginPinnedMessagesRefresh(refreshKey: ""))
        XCTAssertFalse(store.isPinnedMessagesRefreshInFlight(refreshKey: ""))
        XCTAssertTrue(store.beginPinnedMessagesRefresh(refreshKey: context.refreshKey))
        XCTAssertTrue(store.isPinnedMessagesRefreshInFlight(refreshKey: context.refreshKey))
        XCTAssertFalse(store.beginPinnedMessagesRefresh(refreshKey: context.refreshKey))
        XCTAssertTrue(store.beginPinnedMessagesRefresh(refreshKey: "tenant-a|user-a|conversation-2|group-2"))

        store.finishPinnedMessagesRefresh(refreshKey: context.refreshKey)

        XCTAssertFalse(store.isPinnedMessagesRefreshInFlight(refreshKey: context.refreshKey))
        XCTAssertTrue(store.beginPinnedMessagesRefresh(refreshKey: context.refreshKey))
    }

    func testConversationStoreMessageSidecarSyncKeyContextBuildsNormalizedStableKey() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var normalizationInputs: [String] = []

        let context = store.messageSidecarSyncKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            channelID: " peer-a ",
            channelType: " Direct ",
            suffix: " read ",
            normalizeChannelID: { rawChannelID, rawChannelType in
                normalizationInputs.append("\(rawChannelID)|\(rawChannelType)")
                return " user-a:peer-a "
            }
        )

        XCTAssertEqual(normalizationInputs, [" peer-a | Direct "])
        XCTAssertEqual(
            context,
            ConversationStore.MessageSidecarSyncKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                channelID: "peer-a",
                channelType: "direct",
                normalizedChannelID: "user-a:peer-a",
                suffix: "read"
            )
        )
        XCTAssertEqual(context.syncKey, "tenant-a|user-a|direct|user-a:peer-a|read")

        let sparseContext = store.messageSidecarSyncKeyContext(
            tenantID: nil,
            imUID: " ",
            channelID: " raw ",
            channelType: " ",
            suffix: " extras ",
            normalizeChannelID: { _, _ in " " }
        )

        XCTAssertEqual(sparseContext.syncKey, "extras")
    }

    func testConversationStoreReadReceiptSidecarSyncTargetPreservesDeliveryAcrossDetailedReceiptConfig() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(
            id: "local-c1",
            kind: .group,
            unread: 0,
            lastMsgSeq: 2,
            lastReadSeq: 0
        )
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2, isOutgoing: true)
        ]
        store.commitConversationSnapshots([conversation])

        let target = store.readReceiptSidecarSyncTarget(
            channelID: " remote-c1 ",
            channelType: " group ",
            readReceiptsEnabled: true,
            channelIDForConversation: { conversation in
                conversation.id == "local-c1" ? " remote-c1 " : conversation.id
            }
        )

        XCTAssertEqual(
            target,
            ConversationStore.ReadReceiptSidecarSyncTarget(channelID: "remote-c1", channelType: "group")
        )
        XCTAssertEqual(
            store.readReceiptSidecarSyncTarget(
                channelID: "remote-c1",
                channelType: "group",
                readReceiptsEnabled: false,
                channelIDForConversation: { _ in "remote-c1" }
            ),
            ConversationStore.ReadReceiptSidecarSyncTarget(channelID: "remote-c1", channelType: "group")
        )
        XCTAssertNil(
            store.readReceiptSidecarSyncTarget(
                channelID: " ",
                channelType: "group",
                readReceiptsEnabled: true,
                channelIDForConversation: { _ in "remote-c1" }
            )
        )

        conversation.messages = [makeMessage(id: "m3", seq: 3)]
        store.commitConversationSnapshots([conversation])
        XCTAssertNil(
            store.readReceiptSidecarSyncTarget(
                channelID: "remote-c1",
                channelType: "group",
                readReceiptsEnabled: true,
                channelIDForConversation: { _ in "remote-c1" }
            )
        )
    }

    func testConversationStoreConversationReadStateKeyContextBuildsStableKey() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var normalizationInputs: [String] = []

        let context = store.conversationReadStateKeyContext(
            channelID: " c1 ",
            channelType: " Group ",
            normalizeChannelID: { rawChannelID, rawChannelType in
                normalizationInputs.append("\(rawChannelID)|\(rawChannelType)")
                return " normalized-c1 "
            }
        )

        XCTAssertEqual(normalizationInputs, [" c1 | Group "])
        XCTAssertEqual(
            context,
            ConversationStore.ConversationReadStateKeyContext(
                channelID: "c1",
                channelType: "group",
                normalizedChannelID: "normalized-c1"
            )
        )
        XCTAssertEqual(context.syncKey, "group|normalized-c1")

        let emptyContext = store.conversationReadStateKeyContext(
            channelID: " ",
            channelType: " ",
            normalizeChannelID: { _, _ in " " }
        )
        XCTAssertEqual(emptyContext.syncKey, "|")
    }

    func testConversationStoreConversationHistoryKeyContextBuildsStableKey() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)

        let context = store.conversationHistoryKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            conversationID: " c1 "
        )

        XCTAssertEqual(
            context,
            ConversationStore.ConversationHistoryKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                conversationID: "c1"
            )
        )
        XCTAssertEqual(context.historyKey, "tenant-a|user-a|c1")

        let sparseContext = store.conversationHistoryKeyContext(
            tenantID: nil,
            imUID: " ",
            conversationID: " c2 "
        )
        XCTAssertEqual(sparseContext.historyKey, "c2")
    }

    func testConversationStoreActiveConversationScopedStateKeyContextBuildsScopeAndStableKey() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)

        let context = store.activeConversationScopedStateKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            conversationID: " c1 "
        )

        XCTAssertEqual(
            context,
            ConversationStore.ActiveConversationScopedStateKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                conversationID: "c1"
            )
        )
        XCTAssertEqual(context.scope, "tenant-a|user-a")
        XCTAssertEqual(context.stateKey, "tenant-a|user-a|c1")

        let sparseContext = store.activeConversationScopedStateKeyContext(
            tenantID: nil,
            imUID: " ",
            conversationID: " c2 "
        )
        XCTAssertEqual(sparseContext.scope, "")
        XCTAssertEqual(sparseContext.stateKey, "|c2")
    }

    func testConversationStoreConversationBottomSeqMemoryIsMonotonicByStateKey() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)

        XCTAssertEqual(store.rememberedConversationBottomSeq(stateKey: " scope|c1 "), 0)

        store.rememberConversationBottomSeq(4, stateKey: " scope|c1 ")
        store.rememberConversationBottomSeq(2, stateKey: "scope|c1")
        store.rememberConversationBottomSeq(8, stateKey: "scope|c1")
        store.rememberConversationBottomSeq(0, stateKey: "scope|c1")
        store.rememberConversationBottomSeq(6, stateKey: "scope|c2")

        XCTAssertEqual(store.rememberedConversationBottomSeq(stateKey: "scope|c1"), 8)
        XCTAssertEqual(store.rememberedConversationBottomSeq(stateKey: "scope|c2"), 6)
        XCTAssertEqual(store.rememberedConversationBottomSeq(stateKey: "scope|missing"), 0)
    }

    func testConversationStoreActiveRealtimeAutoReadStateTracksActiveConversationAndFallbackIDs() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)

        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))

        store.prepareActiveRealtimeConversationAutoRead(conversationID: " c1 ")
        XCTAssertEqual(store.activeRealtimeConversationAutoReadState(conversationID: "c1"), false)
        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))
        XCTAssertFalse(store.updateActiveRealtimeConversationAutoRead(
            conversationID: "c2",
            activeConversationID: "c1",
            canAutoRead: true
        ))
        XCTAssertNil(store.activeRealtimeConversationAutoReadState(conversationID: "c2"))

        XCTAssertTrue(store.updateActiveRealtimeConversationAutoRead(
            conversationID: " c1 ",
            activeConversationID: " c1 ",
            canAutoRead: true
        ))
        XCTAssertTrue(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))
        XCTAssertTrue(store.canAutoReadActiveRealtimeConversation(previousConversationID: "previous-id", channelID: "c1"))
        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: "previous-id", channelID: "c2"))

        store.prepareActiveRealtimeConversationAutoRead(conversationID: "c1")
        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))

        XCTAssertTrue(store.updateActiveRealtimeConversationAutoRead(
            conversationID: "c1",
            activeConversationID: "c1",
            canAutoRead: true
        ))
        store.clearActiveRealtimeConversationAutoRead(conversationID: " c1 ")
        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))
        XCTAssertFalse(store.hasActiveRealtimeConversationAutoReadStates())
    }

    func testConversationStoreWarmRefreshTaskLifecycleReplacesFinishesAndCancelsByConversation() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        func makeWarmTask() -> Task<Void, Never> {
            Task<Void, Never> {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        let first = makeWarmTask()
        let second = makeWarmTask()
        store.replaceWarmRefreshTask(refreshKey: " tenant|user|c1 ", task: first)
        XCTAssertTrue(store.hasWarmRefreshTask(refreshKey: "tenant|user|c1"))

        store.replaceWarmRefreshTask(refreshKey: "tenant|user|c1", task: second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
        XCTAssertTrue(store.hasWarmRefreshTask(refreshKey: "tenant|user|c1"))

        store.finishWarmRefreshTask(refreshKey: " tenant|user|c1 ")
        XCTAssertFalse(store.hasWarmRefreshTask(refreshKey: "tenant|user|c1"))
        XCTAssertFalse(second.isCancelled)
        second.cancel()

        let sameConversation = makeWarmTask()
        let sameConversationOtherScope = makeWarmTask()
        let otherConversation = makeWarmTask()
        store.replaceWarmRefreshTask(refreshKey: "tenant|user|c1", task: sameConversation)
        store.replaceWarmRefreshTask(refreshKey: "tenant|other-user|c1", task: sameConversationOtherScope)
        store.replaceWarmRefreshTask(refreshKey: "tenant|user|c2", task: otherConversation)

        store.cancelWarmRefreshTasks(conversationID: " c1 ")

        XCTAssertTrue(sameConversation.isCancelled)
        XCTAssertTrue(sameConversationOtherScope.isCancelled)
        XCTAssertFalse(otherConversation.isCancelled)
        XCTAssertFalse(store.hasWarmRefreshTask(refreshKey: "tenant|user|c1"))
        XCTAssertFalse(store.hasWarmRefreshTask(refreshKey: "tenant|other-user|c1"))
        XCTAssertTrue(store.hasWarmRefreshTask(refreshKey: "tenant|user|c2"))

        store.cancelAllWarmRefreshTasks()
        XCTAssertTrue(otherConversation.isCancelled)
        XCTAssertFalse(store.hasWarmRefreshTasks())

        let emptyKeyTask = makeWarmTask()
        store.replaceWarmRefreshTask(refreshKey: " ", task: emptyKeyTask)
        XCTAssertTrue(emptyKeyTask.isCancelled)
        XCTAssertFalse(store.hasWarmRefreshTasks())
    }

    func testConversationStoreReactionExtraDedupeSkipsRepeatedKeysIncludingDefaultActionOnlyKey() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let extra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "thumbs_up",
          "action": "add",
          "created_at": "2026-06-23T10:00:00Z",
          "payload": {}
        }
        """)

        XCTAssertTrue(store.shouldApplyReactionExtra(extra))
        XCTAssertFalse(store.shouldApplyReactionExtra(extra))
        XCTAssertTrue(store.hasAppliedReactionExtraKey(extra.dedupeKey))
        XCTAssertEqual(store.appliedReactionExtraKeyCount(), 1)

        let emptyKeyExtra = try decodeRemoteExtra("""
        {
          "extra_type": "reaction",
          "payload": {}
        }
        """)
        XCTAssertTrue(store.shouldApplyReactionExtra(emptyKeyExtra))
        XCTAssertFalse(store.shouldApplyReactionExtra(emptyKeyExtra))
        XCTAssertTrue(store.hasAppliedReactionExtraKey(extra.dedupeKey))
        XCTAssertTrue(store.hasAppliedReactionExtraKey(emptyKeyExtra.dedupeKey))
        XCTAssertEqual(store.appliedReactionExtraKeyCount(), 2)
    }

    func testConversationStoreDedupedReactionAddRepairsMissingEmojiAfterReload() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, isOutgoing: true)
        ]
        store.commitConversationSnapshots([conversation])
        let extra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "🔥",
          "action": "add",
          "payload": { "display_name": "Reader One" },
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)

        XCTAssertTrue(store.shouldApplyReactionExtra(extra))
        XCTAssertFalse(store.shouldApplyReactionExtra(extra))
        XCTAssertTrue(store.applyDedupedReactionExtraIfMissing(
            extra,
            currentUserIDs: ["me"],
            makeReactionDetail: makeReactionDetail(from:id:)
        ))
        XCTAssertFalse(store.applyDedupedReactionExtraIfMissing(
            extra,
            currentUserIDs: ["me"],
            makeReactionDetail: makeReactionDetail(from:id:)
        ))

        let message = store.conversationMessageSnapshots()[0].messages[0]
        XCTAssertEqual(message.reactions, [
            Reaction(id: "m1_🔥", emoji: "🔥", count: 1, reactedByMe: false)
        ])
        XCTAssertEqual(message.reactionDetails.map(\.id), ["m1_reader-1_🔥"])
    }

    func testConversationStoreDedupedReactionRemoveRepairsOnlyMatchingOperatorEmoji() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, isOutgoing: true)
        message.reactions = [
            Reaction(id: "m1_🔥", emoji: "🔥", count: 1, reactedByMe: false)
        ]
        message.reactionDetails = [
            ReactionDetail(id: "m1_reader-1_🔥", emoji: "🔥", user: makeUser(id: "reader-1"), time: "10:00")
        ]
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])
        let removeExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "🔥",
          "action": "remove",
          "payload": {},
          "created_at": "2026-06-23T10:01:00Z"
        }
        """)

        XCTAssertTrue(store.shouldApplyReactionExtra(removeExtra))
        XCTAssertFalse(store.shouldApplyReactionExtra(removeExtra))
        XCTAssertTrue(store.applyDedupedReactionExtraIfMissing(
            removeExtra,
            currentUserIDs: ["me"],
            makeReactionDetail: makeReactionDetail(from:id:)
        ))
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].reactions.isEmpty)
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].reactionDetails.isEmpty)

        var unrelatedConversation = makeConversation(id: "c2", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var unrelatedMessage = makeMessage(id: "m2", seq: 1, isOutgoing: true)
        unrelatedMessage.reactions = [
            Reaction(id: "m2_🔥", emoji: "🔥", count: 1, reactedByMe: false)
        ]
        unrelatedConversation.messages = [unrelatedMessage]
        store.commitConversationSnapshots([unrelatedConversation])
        let unmatchedRemove = try decodeRemoteExtra("""
        {
          "message_id": "m2",
          "channel_id": "remote-c2",
          "channel_type": "group",
          "operator_uid": "reader-2",
          "extra_type": "reaction",
          "emoji": "🔥",
          "action": "remove",
          "payload": {},
          "created_at": "2026-06-23T10:02:00Z"
        }
        """)

        XCTAssertFalse(store.applyDedupedReactionExtraIfMissing(
            unmatchedRemove,
            currentUserIDs: ["me"],
            makeReactionDetail: makeReactionDetail(from:id:)
        ))
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].reactions, [
            Reaction(id: "m2_🔥", emoji: "🔥", count: 1, reactedByMe: false)
        ])
    }

    func testConversationStoreHistorySyncErrorToastThrottleIsScopedByConversationAndResettable() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: " c1 ", now: start, throttleInterval: 20))
        XCTAssertEqual(store.historySyncErrorToastTime(conversationID: "c1"), start)
        XCTAssertFalse(store.shouldShowHistorySyncErrorToast(conversationID: "c1", now: start.addingTimeInterval(19.9), throttleInterval: 20))
        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: "c2", now: start.addingTimeInterval(5), throttleInterval: 20))
        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: "c1", now: start.addingTimeInterval(20), throttleInterval: 20))
        XCTAssertFalse(store.shouldShowHistorySyncErrorToast(conversationID: "c1", now: start.addingTimeInterval(39.9), throttleInterval: 20))

        store.reset()

        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: "c1", now: start.addingTimeInterval(40), throttleInterval: 20))
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

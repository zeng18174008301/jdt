import XCTest; @testable import IM4Features // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong
extension DomainStoreTests {
    func testConversationStoreMessageSyncPlanUsesRemoteHistoryWindowsForUnreadEntry() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "large_unread", unread: 500, lastMsgSeq: 1_000, lastReadSeq: 500)
        conversation.firstUnreadSeq = 501
        conversation.unreadAnchorSeq = 501
        conversation.messages = [makeMessage(id: "m1000", seq: 1_000)]
        let plan = store.messageSyncPlan(
            for: conversation,
            historyKey: "scope|large_unread",
            force: false,
            latestHistoryWindowLimit: 100
        )
        XCTAssertEqual(plan, .remoteHistory(historyKey: "scope|large_unread", windows: [
            ConversationStore.MessageSyncWindow(afterSeq: 900, limit: 100)
        ]))
    }
    func testConversationStoreMessageSyncPlanUsesSidecarsOnlyForCompleteHistory() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "complete", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m3", seq: 3)
        ]
        XCTAssertEqual(
            store.messageSyncPlan(
                for: conversation,
                historyKey: "scope|complete",
                force: false,
                latestHistoryWindowLimit: 100
            ),
            .sidecarsOnly
        )
        XCTAssertEqual(
            store.messageSyncPlan(
                for: conversation,
                historyKey: "scope|complete",
                force: true,
                latestHistoryWindowLimit: 100
            ),
            .remoteHistory(historyKey: "scope|complete", windows: [
                ConversationStore.MessageSyncWindow(afterSeq: 0, limit: 100)
            ])
        )
    }
    func testChatInitialScrollAnchorUsesBottomForLargeUnreadEntry() throws {
        let boundaryMessages = (481...580).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }
        let messages = boundaryMessages + [makeMessage(id: "m1000", seq: 1_000)]
        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: messages.count,
            lastReadSeq: 500,
            firstUnreadMessageID: "m501",
            firstUnreadSeq: 501,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))
        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }
    func testChatInitialScrollAnchorUsesBottomWhenUnreadBoundaryIsNewerThanLoadedWindow() throws {
        let oldWindowMessages = (21...40).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }
        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: oldWindowMessages,
            unreadCount: 3,
            lastReadSeq: 500,
            firstUnreadMessageID: "m38",
            firstUnreadSeq: 501,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))
        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }
    func testChatUnreadDividerUsesFirstUnreadSequenceInsideLoadedWindow() {
        let messages = (498...505).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }
        let dividerID = chatFirstUnreadMessageIDForDivider(
            messages: messages,
            firstUnreadMessageID: "",
            firstUnreadSeq: 501,
            lastReadSeq: 500,
            unreadCount: 5
        )
        XCTAssertEqual(dividerID, "m501")
    }
    func testChatUnreadDividerDoesNotPinToTrimmedLatestWindowTop() {
        let latestWindowMessages = (901...1_000).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }
        let dividerID = chatFirstUnreadMessageIDForDivider(
            messages: latestWindowMessages,
            firstUnreadMessageID: "",
            firstUnreadSeq: 501,
            lastReadSeq: 500,
            unreadCount: 500
        )
        XCTAssertNil(dividerID)
    }
    func testChatUnreadDividerFallsBackToLastReadSequenceWhenRemoteAnchorMissing() {
        let messages = (498...505).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        let dividerID = chatFirstUnreadMessageIDForDivider(
            messages: messages,
            firstUnreadMessageID: "",
            firstUnreadSeq: 0,
            lastReadSeq: 500,
            unreadCount: 5
        )

        XCTAssertEqual(dividerID, "m501")
    }

    // WDT_CHAT_DELETE_REFRESH_20261021_BEGIN
    func testChatDeletionCacheInvalidatesMiddleTombstoneWithoutCountOrEndpointChanges() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        conversation.messages = (1...3).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        store.commitConversationSnapshots([conversation])
        let cachedMessages = conversation.messages

        XCTAssertTrue(chatMessageDeletionStateMatches(cachedMessages: cachedMessages, messages: cachedMessages))
        XCTAssertTrue(store.applyAdminDeletedMessage(
            messageID: "m2",
            conversationID: "c1",
            channelIDForConversation: { $0.id }
        ))
        let updated = store.conversationMessageSnapshots()[0].messages
        XCTAssertEqual(updated.count, cachedMessages.count)
        XCTAssertEqual(updated.first, cachedMessages.first)
        XCTAssertEqual(updated.last, cachedMessages.last)
        XCTAssertFalse(chatMessageDeletionStateMatches(cachedMessages: cachedMessages, messages: updated))
        XCTAssertTrue(chatMessageDeletionStateMatches(cachedMessages: updated, messages: updated))
        XCTAssertFalse(cachedMessages[1].isDeletedLocally)
        XCTAssertTrue(updated[1].isDeletedLocally)
        XCTAssertEqual(updated[1].text, "原消息已删除")
        XCTAssertEqual(chatTimelineMessagesForRendering(updated).map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(chatTimelineMessagesForRendering(updated, showsProcessingNotices: false).map(\.id), ["m1", "m3"])

        let projectionCache = ChatTranscriptProjectionCache()
        XCTAssertEqual(projectionCache.projection(for: cachedMessages, showsProcessingNotices: false).timeline.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(projectionCache.projection(for: updated, showsProcessingNotices: false).timeline.map(\.id), ["m1", "m3"])
        XCTAssertEqual(projectionCache.projection(for: updated, showsProcessingNotices: true).timeline.map(\.id), ["m1", "m2", "m3"])
    }

    func testChatDeletionCacheInvalidatesRemovalAndSameCountReplacement() {
        let cached = (1...4).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        let removed = cached.filter { $0.id != "m2" }
        XCTAssertFalse(chatMessageDeletionStateMatches(cachedMessages: cached, messages: removed))

        var replaced = cached
        replaced[1] = makeMessage(id: "replacement", seq: 2)
        XCTAssertFalse(chatMessageDeletionStateMatches(cachedMessages: cached, messages: replaced))

        let empty: [ChatMessage] = []
        XCTAssertFalse(chatMessageDeletionStateMatches(cachedMessages: cached, messages: empty))
        XCTAssertTrue(chatMessageDeletionStateMatches(cachedMessages: empty, messages: empty))
    }

    func testChatDeletionCacheChecksReusedHistorySuffixWithoutChangingOtherFields() {
        let cached = (3...5).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        let older = (1...2).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        var prepended = older + cached
        XCTAssertTrue(chatMessageDeletionStateMatches(
            cachedMessages: cached.lazy.map { $0 },
            messages: prepended.dropFirst(older.count)
        ))
        prepended[3].status = .recalled
        XCTAssertFalse(chatMessageDeletionStateMatches(
            cachedMessages: cached.lazy.map { $0 },
            messages: prepended.dropFirst(older.count)
        ))
        prepended[3].status = cached[1].status
        prepended[3].isDeletedLocally = true
        XCTAssertFalse(chatMessageDeletionStateMatches(
            cachedMessages: cached.lazy.map { $0 },
            messages: prepended.dropFirst(older.count)
        ))
        XCTAssertEqual(prepended.map(\.channelSeq), [1, 2, 3, 4, 5])
        XCTAssertFalse(cached[1].isDeletedLocally)
    }
    // WDT_CHAT_DELETE_REFRESH_20261021_END

    func testProcessingNoticeVisibilityDoesNotDestroyTombstonesOrMatchUserText() {
        var recalled = makeMessage(id: "recalled", seq: 1, text: "某某撤回了一条消息")
        recalled.status = .recalled
        var deleted = makeMessage(id: "deleted", seq: 2, text: "原消息已删除")
        deleted.isDeletedLocally = true
        var edited = makeMessage(id: "edited", seq: 3, text: "新正文")
        edited.isEdited = true
        edited.editRevision = 4
        let userText = makeMessage(id: "user-text", seq: 4, text: "已删除")
        let messages = [recalled, deleted, edited, userText]
        XCTAssertEqual(chatTimelineMessagesForRendering(messages, showsProcessingNotices: false).map(\.id), ["edited", "user-text"])
        XCTAssertEqual(chatTimelineMessagesForRendering(messages).map(\.id), messages.map(\.id))
        XCTAssertEqual(messages[0].status, .recalled)
        XCTAssertTrue(messages[1].isDeletedLocally)
        XCTAssertEqual(messages[2].editRevision, 4)
    }

    func testChatTimelineRenderingFiltersPinnedContextOnlyMessagesFromAnchorInput() throws {
        var oldPinned = makeMessage(id: "pinned-old", seq: 11, text: "old pinned")
        oldPinned.isPinned = true
        oldPinned.isPinnedContextOnly = true
        let latestWindow = [
            makeMessage(id: "m430", seq: 430, text: "last read"),
            makeMessage(id: "m431", seq: 431, text: "unread 1"),
            makeMessage(id: "m432", seq: 432, text: "unread 2"),
            makeMessage(id: "m433", seq: 433, text: "unread 3")
        ]

        let timelineMessages = chatTimelineMessagesForRendering([oldPinned] + latestWindow)
        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: timelineMessages,
            unreadCount: 3,
            lastReadSeq: 430,
            firstUnreadMessageID: "m431",
            firstUnreadSeq: 431,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(timelineMessages.map(\.id), ["m430", "m431", "m432", "m433"])
        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertFalse(anchor.anchorsLastReadMessage)
    }

    func testConversationStorePinnedMessageSnapshotMergesContextMessagesAndUpdatesStore() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 20, lastReadSeq: 0)
        var staleContext = makeMessage(id: "stale", seq: 2, isPinned: true, text: "stale pinned")
        staleContext.isPinnedContextOnly = true
        var oldPinned = makeMessage(id: "old", seq: 4, isPinned: true, text: "old pinned")
        oldPinned.isPinnedContextOnly = false
        var unpinned = makeMessage(id: "unpinned", seq: 12, isPinned: true, text: "was pinned")
        unpinned.isPinnedContextOnly = false
        conversation.messages = [
            staleContext,
            oldPinned,
            makeMessage(id: "m10", seq: 10, text: "timeline 10"),
            unpinned,
            makeMessage(id: "m20", seq: 20, text: "timeline 20")
        ]
        store.commitConversationSnapshots([conversation])

        let newPinned = makeMessage(id: "new", seq: 15, text: "new pinned")
        let recalled = makeMessage(id: "recalled", seq: 18, text: "recalled pinned")
        let updated = try XCTUnwrap(store.applyPinnedMessageSnapshot([
            ConversationStore.PinnedMessageSnapshotEntry(
                messageID: " old ",
                status: "pinned",
                message: makeMessage(id: "old", seq: 4, text: "old pinned")
            ),
            ConversationStore.PinnedMessageSnapshotEntry(
                messageID: "new",
                status: "pinned",
                message: newPinned
            ),
            ConversationStore.PinnedMessageSnapshotEntry(
                messageID: "stale",
                status: "deleted",
                message: staleContext
            ),
            ConversationStore.PinnedMessageSnapshotEntry(
                messageID: "recalled",
                status: "recalled",
                message: recalled
            )
        ], conversationID: " c1 "))

        XCTAssertEqual(updated.messages.map(\.id), ["old", "m10", "unpinned", "new", "m20"])
        let mergedOld = try XCTUnwrap(updated.messages.first { $0.id == "old" })
        XCTAssertTrue(mergedOld.isPinned)
        XCTAssertTrue(mergedOld.isPinnedContextOnly)
        let mergedUnpinned = try XCTUnwrap(updated.messages.first { $0.id == "unpinned" })
        XCTAssertFalse(mergedUnpinned.isPinned)
        XCTAssertFalse(mergedUnpinned.isPinnedContextOnly)
        let mergedNew = try XCTUnwrap(updated.messages.first { $0.id == "new" })
        XCTAssertTrue(mergedNew.isPinned)
        XCTAssertTrue(mergedNew.isPinnedContextOnly)
        XCTAssertNil(updated.messages.first { $0.id == "stale" })
        XCTAssertNil(updated.messages.first { $0.id == "recalled" })
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), updated.messages.map(\.id))
    }

    func testConversationStorePinnedMessageSnapshotSkipsMissingConversation() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, isPinned: true, text: "pinned")
        message.isPinnedContextOnly = true
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])

        XCTAssertNil(store.applyPinnedMessageSnapshot([], conversationID: " "))
        XCTAssertNil(store.applyPinnedMessageSnapshot([], conversationID: "missing"))

        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages.map(\.id), ["m1"])
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].isPinned)
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].isPinnedContextOnly)
    }

    func testConversationStoreOldestConfirmedMessageSeqIgnoresTransientAndPinnedBoundary() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 20, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "local_1", seq: 1),
            makeMessage(id: "sending", seq: 2, status: .sending),
            makeMessage(id: "failed", seq: 3, status: .failed),
            makeMessage(id: "pinned", seq: 4, isPinned: true),
            makeMessage(id: "m8", seq: 8),
            makeMessage(id: "m10", seq: 10)
        ]

        XCTAssertEqual(store.oldestConfirmedMessageSeq(in: conversation), 8)

        conversation.messages = [
            makeMessage(id: "pinned-only", seq: 4, isPinned: true)
        ]
        XCTAssertEqual(store.oldestConfirmedMessageSeq(in: conversation), 4)

        conversation.messages = [
            makeMessage(id: "local_2", seq: 5),
            makeMessage(id: "sending-2", seq: 6, status: .sending),
            makeMessage(id: "failed-2", seq: 7, status: .failed)
        ]
        XCTAssertNil(store.oldestConfirmedMessageSeq(in: conversation))
    }

    func testConversationStoreUsableRemoteHistoryRequiresRecentConfirmedWindow() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var complete = makeConversation(id: "complete", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        complete.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m3", seq: 3)
        ]
        var stale = makeConversation(id: "stale", kind: .group, unread: 0, lastMsgSeq: 4, lastReadSeq: 0)
        stale.messages = complete.messages
        var sparse = makeConversation(id: "sparse", kind: .group, unread: 0, lastMsgSeq: 5, lastReadSeq: 0)
        sparse.messages = [
            makeMessage(id: "m4", seq: 4),
            makeMessage(id: "m5", seq: 5)
        ]

        XCTAssertTrue(store.hasUsableRemoteHistory(for: complete))
        XCTAssertFalse(store.hasUsableRemoteHistory(for: stale))
        XCTAssertFalse(store.hasUsableRemoteHistory(for: sparse))
    }

    func testConversationStoreUsableRemoteHistoryIgnoresDeletedAndRecalledMessages() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2, status: .recalled, isDeletedLocally: true),
            makeMessage(id: "m3", seq: 3)
        ]
        var deletedOnly = makeConversation(id: "deleted", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        deletedOnly.messages = [
            makeMessage(id: "m1", seq: 1, status: .recalled, isDeletedLocally: true),
            makeMessage(id: "m2", seq: 2, status: .recalled, isDeletedLocally: true)
        ]

        XCTAssertFalse(store.hasUsableRemoteHistory(for: conversation))
        XCTAssertFalse(store.hasUsableRemoteHistory(for: deletedOnly))
    }

    func testConversationStoreHistoryHydrationRequiresCompleteUsableWindow() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var complete = makeConversation(id: "complete", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        complete.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m3", seq: 3)
        ]
        var deletedOnly = makeConversation(id: "deleted", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        deletedOnly.messages = [
            makeMessage(id: "m1", seq: 1, status: .recalled, isDeletedLocally: true),
            makeMessage(id: "m2", seq: 2, status: .recalled, isDeletedLocally: true)
        ]
        var sparse = makeConversation(id: "sparse", kind: .group, unread: 0, lastMsgSeq: 5, lastReadSeq: 0)
        sparse.messages = [
            makeMessage(id: "m4", seq: 4),
            makeMessage(id: "m5", seq: 5)
        ]

        XCTAssertFalse(store.needsHistoryHydration(local: complete, remoteLatestSeq: 3, remoteLastMessageID: "m3"))
        XCTAssertTrue(store.needsHistoryHydration(local: nil, remoteLatestSeq: 3, remoteLastMessageID: "m3"))
        XCTAssertTrue(store.needsHistoryHydration(local: complete, remoteLatestSeq: 4, remoteLastMessageID: "m4"))
        XCTAssertTrue(store.needsHistoryHydration(local: complete, remoteLatestSeq: 3, remoteLastMessageID: "missing"))
        XCTAssertTrue(store.needsHistoryHydration(local: deletedOnly, remoteLatestSeq: 2, remoteLastMessageID: "m2"))
        XCTAssertTrue(store.needsHistoryHydration(local: sparse, remoteLatestSeq: 5, remoteLastMessageID: "m5"))
    }

    func testConversationStoreHistoryPrefetchTargetsFilterSortAndExplainCandidates() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var complete = makeConversation(id: "complete", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        complete.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m3", seq: 3)
        ]
        var activeLocal = makeConversation(id: "active-local", kind: .group, unread: 0, lastMsgSeq: 4, lastReadSeq: 0)
        activeLocal.messages = [makeMessage(id: "a4", seq: 4)]
        var unreadLocal = makeConversation(id: "unread-local", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        unreadLocal.messages = [makeMessage(id: "u1", seq: 1)]
        var latestLocal = makeConversation(id: "latest-local", kind: .group, unread: 0, lastMsgSeq: 5, lastReadSeq: 0)
        latestLocal.messages = [makeMessage(id: "l5", seq: 5)]

        let completeRemote = try decodeRemoteConversation("""
        {"channel_id":"complete","channel_type":"group","last_msg_seq":3,"unread_count":0}
        """)
        let activeRemote = try decodeRemoteConversation("""
        {"channel_id":"active","channel_type":"group","last_msg_seq":5,"unread_count":0}
        """)
        let unreadRemote = try decodeRemoteConversation("""
        {"channel_id":"unread","channel_type":"group","last_msg_seq":4,"unread_count":3}
        """)
        let latestRemote = try decodeRemoteConversation("""
        {"channel_id":"latest","channel_type":"group","last_msg_seq":9,"unread_count":0}
        """)

        let targets = store.historyPrefetchTargets(
            candidates: [
                ConversationStore.HistoryPrefetchCandidate(
                    remote: completeRemote,
                    channelID: "complete",
                    local: complete,
                    isActive: false,
                    latestSeq: 3,
                    sortTimestamp: 400,
                    logID: "complete"
                ),
                ConversationStore.HistoryPrefetchCandidate(
                    remote: latestRemote,
                    channelID: "latest",
                    local: latestLocal,
                    isActive: false,
                    latestSeq: 9,
                    sortTimestamp: 900,
                    logID: "latest"
                ),
                ConversationStore.HistoryPrefetchCandidate(
                    remote: unreadRemote,
                    channelID: "unread",
                    local: unreadLocal,
                    isActive: false,
                    latestSeq: 4,
                    sortTimestamp: 100,
                    logID: "unread"
                ),
                ConversationStore.HistoryPrefetchCandidate(
                    remote: activeRemote,
                    channelID: "active",
                    local: activeLocal,
                    isActive: true,
                    latestSeq: 5,
                    sortTimestamp: 50,
                    logID: "active"
                )
            ],
            limit: 3
        )

        XCTAssertEqual(targets.map(\.channelID), ["active", "unread", "latest"])
        XCTAssertEqual(targets.map(\.reason), ["active", "unread", "latest_seq"])
        XCTAssertEqual(
            targets.map(\.summaryFragment),
            [
                "active#seq5#ts50#active",
                "unread#seq4#ts100#unread",
                "latest#seq9#ts900#latest_seq"
            ]
        )
    }

    func testConversationStoreHistoryPrefetchExecutionPlanBuildsBatchesAndFetchWindows() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let firstRemote = try decodeRemoteConversation("""
        {"channel_id":"first","channel_type":"group","last_msg_seq":120,"unread_count":0}
        """)
        let secondRemote = try decodeRemoteConversation("""
        {"channel_id":"second","channel_type":"group","last_msg_seq":20,"unread_count":0}
        """)
        let thirdRemote = try decodeRemoteConversation("""
        {"channel_id":"third","channel_type":"group","last_msg_seq":60,"unread_count":0}
        """)

        let targets = [
            ConversationStore.HistoryPrefetchTarget(
                remote: firstRemote,
                channelID: "first",
                reason: "unread",
                latestSeq: 120,
                sortTimestamp: 1_000,
                logID: "first"
            ),
            ConversationStore.HistoryPrefetchTarget(
                remote: secondRemote,
                channelID: "second",
                reason: "recent_activity",
                latestSeq: 20,
                sortTimestamp: 900,
                logID: "second"
            ),
            ConversationStore.HistoryPrefetchTarget(
                remote: thirdRemote,
                channelID: "third",
                reason: "latest_seq",
                latestSeq: 60,
                sortTimestamp: 800,
                logID: "third"
            )
        ]

        let plan = store.historyPrefetchExecutionPlan(
            targets: targets,
            messageLimit: 50,
            maxConcurrent: 2
        )

        XCTAssertEqual(plan.maxConcurrent, 2)
        XCTAssertEqual(plan.commands.map(\.channelID), ["first", "second", "third"])
        XCTAssertEqual(plan.commands.map(\.apiChannelID), ["first", "second", "third"])
        XCTAssertEqual(plan.commands.map(\.afterSeq), [70, 0, 10])
        XCTAssertEqual(plan.commands.map(\.limit), [50, 50, 50])
        XCTAssertEqual(plan.commands.map(\.reason), ["unread", "recent_activity", "latest_seq"])
        XCTAssertEqual(
            plan.targetSummary,
            "first#seq120#ts1000#unread,second#seq20#ts900#recent_activity,third#seq60#ts800#latest_seq"
        )
        XCTAssertEqual(
            plan.batches.map { $0.map(\.channelID) },
            [["first", "second"], ["third"]]
        )

        let serialPlan = store.historyPrefetchExecutionPlan(
            targets: Array(targets.prefix(2)),
            messageLimit: 50,
            maxConcurrent: 0
        )
        XCTAssertEqual(serialPlan.maxConcurrent, 1)
        XCTAssertEqual(serialPlan.batches.map { $0.map(\.channelID) }, [["first"], ["second"]])
    }

    func testConversationStoreHistoryPrefetchReadReceiptBackfillPreservesDeliveryAcrossDetailedReceiptConfig() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var outgoingConversation = makeConversation(id: "outgoing", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        outgoingConversation.messages = [
            makeMessage(id: "out-1", seq: 1, isOutgoing: true)
        ]
        var incomingOnlyConversation = makeConversation(id: "incoming", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        incomingOnlyConversation.messages = [
            makeMessage(id: "in-1", seq: 1)
        ]
        store.commitConversationSnapshots([outgoingConversation, incomingOnlyConversation])

        let outgoingRemote = try decodeRemoteConversation("""
        {"channel_id":"outgoing","channel_type":"group","last_msg_seq":3,"unread_count":0}
        """)
        let incomingRemote = try decodeRemoteConversation("""
        {"channel_id":"incoming","channel_type":"group","last_msg_seq":3,"unread_count":0}
        """)
        let plan = store.historyPrefetchExecutionPlan(
            targets: [
                ConversationStore.HistoryPrefetchTarget(
                    remote: outgoingRemote,
                    channelID: "outgoing",
                    reason: "recent_activity",
                    latestSeq: 3,
                    sortTimestamp: 300,
                    logID: "outgoing"
                ),
                ConversationStore.HistoryPrefetchTarget(
                    remote: incomingRemote,
                    channelID: "incoming",
                    reason: "recent_activity",
                    latestSeq: 3,
                    sortTimestamp: 200,
                    logID: "incoming"
                )
            ],
            messageLimit: 50,
            maxConcurrent: 2
        )

        let outgoingCommand = try XCTUnwrap(plan.commands.first { $0.channelID == "outgoing" })
        let incomingCommand = try XCTUnwrap(plan.commands.first { $0.channelID == "incoming" })

        store.mutateMessageSnapshotsForTesting { $0.insert(contentsOf: (0..<1000).map {
            makeConversation(id: "receipt-unrelated-\($0)", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        }, at: 0) }
        var identityResolutions = 0
        XCTAssertEqual(
            store.historyPrefetchReadReceiptBackfillTarget(
                for: outgoingCommand,
                readReceiptsEnabled: true,
                channelIDForConversation: { identityResolutions += 1; return $0.id }
            ),
            ConversationStore.HistoryPrefetchReadReceiptBackfillTarget(
                channelID: "outgoing",
                channelType: "group"
            )
        )
        XCTAssertEqual(
            store.historyPrefetchReadReceiptBackfillTarget(
                for: outgoingCommand,
                readReceiptsEnabled: false,
                channelIDForConversation: { identityResolutions += 1; return $0.id }
            ),
            ConversationStore.HistoryPrefetchReadReceiptBackfillTarget(
                channelID: "outgoing",
                channelType: "group"
            )
        )
        XCTAssertNil(
            store.historyPrefetchReadReceiptBackfillTarget(
                for: incomingCommand,
                readReceiptsEnabled: true,
                channelIDForConversation: { identityResolutions += 1; return $0.id }
            )
        )
        XCTAssertEqual(identityResolutions, 0, "Canonical receipt targets must skip unrelated identity normalization")
        let index = try XCTUnwrap(store.conversationMessageSnapshots().firstIndex { $0.id == "outgoing" })
        var legacy = makeConversation(id: "legacy-outgoing", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        legacy.messages = store.conversationMessageSnapshots()[index].messages
        store.commitConversationSnapshot(legacy, at: index)
        XCTAssertNotNil(store.historyPrefetchReadReceiptBackfillTarget(
            for: outgoingCommand, readReceiptsEnabled: true,
            channelIDForConversation: { $0.id == "legacy-outgoing" ? "outgoing" : $0.id }
        ), "Legacy channel aliases must retain receipt catch-up")
    }

    func testConversationStoreOlderHistoryFilterRejectsCurrentAndDuplicateMessages() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let older = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 1,
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

        XCTAssertTrue(store.isRemoteMessageOlderThanCurrentWindow(older, oldestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageOlderThanCurrentWindow(current, oldestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageOlderThanCurrentWindow(unsequenced, oldestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageOlderThanCurrentWindow(older, oldestSeq: 3, existingIDs: ["m1"], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageOlderThanCurrentWindow(older, oldestSeq: 3, existingIDs: [], existingSeqs: [1]))
    }
}

// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
extension DomainStoreTests {
    func incrementalContext(_ scope: [String?] = ["account", "tenant", "app", "actor", "device"], group: Bool = false) -> ChatTimelineContext {
        .init(conversationID: "timeline", scope: scope, sessionGeneration: 1, historyScope: "history", policy: nil, isGroup: group, isReadOnly: false, canManageGroup: false)
    }
    func applyTimeline(_ model: ChatTimelineViewModel, _ messages: [ChatMessage], _ context: ChatTimelineContext, unread: String? = nil) {
        model.update(messages: messages, context: context, unreadID: unread, unreadCount: unread == nil ? 0 : 1) { index in
            .init(index: index, message: messages[index], showsSenderHeader: index == 0, senderUser: nil, displaySenderName: messages[index].senderName,
                  timeSeparatorText: ChatView(conversationID: "timeline").timeSeparatorText(before: messages[index], previous: index > 0 ? messages[index - 1] : nil))
        }
    }
    func testIncrementalTimelineMiddleEditRefreshesBothNeighborsAndKeepsDistantRows() {
        let model = ChatTimelineViewModel(), context = incrementalContext(); var messages = (1...8).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        for index in messages.indices { messages[index].createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60) }
        applyTimeline(model, messages, context); let before = model.rows
        messages[3].text = "edited"; messages[3].createdAt = messages[3].createdAt?.addingTimeInterval(-600); applyTimeline(model, messages, context)
        XCTAssertEqual(model.rebuiltIDs, ["m3", "m4", "m5"]); XCTAssertEqual(model.rows[0], before[0]); XCTAssertEqual(model.rows[7], before[7])
        XCTAssertNil(before[4].timeSeparatorText); XCTAssertNotNil(model.rows[4].timeSeparatorText); XCTAssertEqual(model.rows[3].message.text, "edited")
    }
    func testIncrementalTimelinePrependAndRemovalRefreshJoinAndKeepDistantIdentity() {
        let model = ChatTimelineViewModel(), context = incrementalContext(); var messages = (1...8).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        applyTimeline(model, messages, context); let tail = model.rows[7]
        messages.insert(makeMessage(id: "older", seq: 0), at: 0); applyTimeline(model, messages, context)
        XCTAssertEqual(model.rows.last, tail); XCTAssertEqual(model.rows.last?.index, 8); XCTAssertTrue(model.rebuiltIDs.isSuperset(of: ["older", "m1", "m2"]))
        messages.remove(at: 4); applyTimeline(model, messages, context)
        XCTAssertTrue(model.rebuiltIDs.isSuperset(of: ["m3", "m5"])); XCTAssertEqual(model.rows.last, tail); XCTAssertEqual(model.rows.last?.index, 7)
    }
    func testIncrementalTimelineUnreadMoveRefreshesBothOldAndNewBoundaries() {
        let model = ChatTimelineViewModel(), context = incrementalContext(), messages = (1...8).map { makeMessage(id: "m\($0)", seq: Int64($0)) }
        applyTimeline(model, messages, context, unread: "m3"); let first = model.rows[0]; applyTimeline(model, messages, context, unread: "m6")
        XCTAssertTrue(model.rebuiltIDs.isSuperset(of: ["m2", "m3", "m5", "m6"])); XCTAssertEqual(model.rows[0], first)
    }
}
// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END

// WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
extension DomainStoreTests {
    func testMountedChatComposerPreservesIMESelectionFailureDraftAndTimelineIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString)")
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("cache"))
        let rejected = HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"group_muted","message":"全员禁言"}}"#.utf8), isHTTPResponse: true, statusCode: 403)
        let transport = FakeHTTPTransport(results: [rejected], delayNanoseconds: 20_000_000)
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test"), tenantBase: URL(string: "https://tenant.example.test"), imBase: URL(string: "https://im.example.test"), httpTransport: transport)
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), messagePersistence: persistence, apiContextOverride: makeAuthenticatedAPIContext(accountID: UUID().uuidString))
        addTeardownBlock { @MainActor in await persistence.detach(ticket: state.localMessageTicket)
            try? FileManager.default.removeItem(at: root) }
        let owner = ComposerState(); state.setCurrentUser(makeUser(id: "uid-1")); state.setAuthenticated(true)
        var conversation = makeConversation(id: "composer-ui", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.hasUnreadReaction = false; conversation.unreadReactionCount = 0; conversation.messages = [makeMessage(id: "stable-ui", seq: 1)]; state.conversationStore.commitConversationSnapshots([conversation])
        var composer: ChatComposer?; ChatTimelineRenderDiagnostics.reset(); ChatTimelineRenderDiagnostics.enabled = true; ChatTimelineRenderDiagnostics.composerBody = { composer = $0 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first), window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStackCompat { ChatView(composerState: owner, conversationID: "composer-ui") }.appStateEnvironment(state))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { ChatTimelineRenderDiagnostics.reset(); window.isHidden = true; window.rootViewController = nil }
        func editor(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.lazy.compactMap(editor).first }
        try await Task.sleep(nanoseconds: 500_000_000); let textView = try XCTUnwrap(editor(host.view)); XCTAssertTrue(textView.becomeFirstResponder())
        try await Task.sleep(nanoseconds: 3_500_000_000)
        try await assertScopedChatRuntimeWiring(state, conversationID: "composer-ui", editor: { editor(host.view) }); let bodies = ChatTimelineRenderDiagnostics.bubbleBodies, rows = ChatTimelineRenderDiagnostics.rowResolutions, timelines = ChatTimelineRenderDiagnostics.timelineBodies
        XCTAssertGreaterThan(bodies, 0); XCTAssertGreaterThan(rows, 0)
        composerBoundaryTrace("old-basic-before", editor: textView, owner: owner, host: host)
        textView.text = "中😀"; textView.selectedRange = NSRange(location: 3, length: 0); textView.delegate?.textViewDidChange?(textView)
        composerBoundaryTrace("old-basic-after", editor: textView, owner: owner, host: host)
        try await Task.sleep(nanoseconds: 100_000_000); XCTAssertEqual(owner.draft.input, "中😀"); XCTAssertTrue(editor(host.view) === textView)
        XCTAssertEqual(ChatTimelineRenderDiagnostics.rowResolutions, rows); XCTAssertEqual(ChatTimelineRenderDiagnostics.bubbleBodies, bodies); XCTAssertEqual(ChatTimelineRenderDiagnostics.timelineBodies, timelines)
        composerBoundaryTrace("old-marked-before", editor: textView, owner: owner, host: host)
        textView.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0)); textView.delegate?.textViewDidChange?(textView)
        composerBoundaryTrace("old-marked-after", editor: textView, owner: owner, host: host)
        let markedText = textView.text; XCTAssertNotNil(textView.markedTextRange); owner.draft.replyQuote = "quote"
        try await Task.sleep(nanoseconds: 100_000_000); XCTAssertNotNil(textView.markedTextRange); XCTAssertEqual(textView.text, markedText)
        composerBoundaryTrace("old-selection-before", editor: textView, owner: owner, host: host)
        textView.unmarkText(); textView.text = "前😀后"; textView.selectedRange = NSRange(location: 1, length: 2); textView.delegate?.textViewDidChange?(textView)
        composerBoundaryTrace("old-selection-after", editor: textView, owner: owner, host: host)
        composerBoundaryTrace("old-at-insert-before", editor: textView, owner: owner, host: host)
        try XCTUnwrap(composer).insertEmojiAtCurrentSelection("@")
        composerBoundaryTrace("old-at-insert-after", editor: textView, owner: owner, host: host)
        try await Task.sleep(nanoseconds: 100_000_000); XCTAssertEqual(textView.text, "前@后"); XCTAssertEqual(owner.draft.selection, NSRange(location: 2, length: 0))
        composerBoundaryTrace("old-send-before", editor: textView, owner: owner, host: host)
        try XCTUnwrap(composer).sendCurrentInput(); XCTAssertEqual(owner.draft.input, "")
        composerBoundaryTrace("old-send-after", editor: textView, owner: owner, host: host)
        XCTAssertTrue(textView.becomeFirstResponder())
        composerBoundaryTrace("old-continue-before", editor: textView, owner: owner, host: host)
        textView.text = "new"; textView.selectedRange = NSRange(location: 3, length: 0); textView.delegate?.textViewDidChange?(textView)
        composerBoundaryTrace("old-continue-after", editor: textView, owner: owner, host: host)
        for _ in 0..<100 { if owner.draft.input == "前@后\nnew" { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(owner.draft.input, "前@后\nnew"); XCTAssertEqual(owner.draft.replyQuote, "quote"); XCTAssertEqual(textView.text, owner.draft.input); XCTAssertTrue(transport.requests().contains { $0.url?.path == "/api/im/messages" })
        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 0)); XCTAssertEqual(owner.draft.selection, textView.selectedRange) // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110
        let editorTrace = XCTAttachment(string: "editable=\(textView.isEditable); current_view_same=\(editor(host.view) === textView); first_responder=\(textView.isFirstResponder); in_window=\(textView.window != nil); send_reason=\(state.conversationSendDisabledReason("composer-ui")); composer_disabled=\(composer?.isDisabled ?? false)"); editorTrace.name = "composer-ime-failure-editor-state"; editorTrace.lifetime = .keepAlways; add(editorTrace)
        composerBoundaryTrace("old-X-before", editor: textView, owner: owner, host: host)
        textView.insertText("X"); textView.delegate?.textViewDidChange?(textView); XCTAssertEqual(owner.draft.input, "前@后\nnewX"); XCTAssertEqual(textView.text, owner.draft.input)
        composerBoundaryTrace("old-X-after", editor: textView, owner: owner, host: host)
        let afterTrace = XCTAttachment(string: "ui_text=\(textView.text ?? "nil"); owner_text=\(owner.draft.input); marked=\(textView.markedTextRange != nil); ui_selection=\(textView.selectedRange); owner_selection=\(owner.draft.selection); owner_token=\(String(describing: owner.token))"); afterTrace.name = "composer-ime-after-X"; afterTrace.lifetime = .keepAlways; add(afterTrace)
        var second = makeConversation(id: "composer-other", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0); second.hasUnreadReaction = false; state.conversationStore.commitConversationSnapshots(state.conversationStore.conversationMessageSnapshots() + [second])
        host.rootView = NavigationStackCompat { ChatView(composerState: owner, conversationID: "composer-other") }.appStateEnvironment(state)
        try await Task.sleep(nanoseconds: 150_000_000); XCTAssertEqual(owner.token?.conversationID, "composer-other"); XCTAssertEqual(owner.draft.input, ""); XCTAssertEqual(editor(host.view)?.text, "")
        owner.draft.input = "other draft"; host.rootView = NavigationStackCompat { ChatView(composerState: owner, conversationID: "composer-ui") }.appStateEnvironment(state)
        try await Task.sleep(nanoseconds: 150_000_000); XCTAssertEqual(owner.token?.conversationID, "composer-ui"); XCTAssertEqual(owner.draft.input, "前@后\nnewX"); XCTAssertEqual(editor(host.view)?.text, owner.draft.input)
    }
}
// WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END

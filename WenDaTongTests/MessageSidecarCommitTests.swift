import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
import Combine
import XCTest
@testable import WenDaTong

// WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_BEGIN
extension DomainStoreTests {
    func testRemoteReactionEntryCommitsCountDetailsReadAndReminderTogether() throws {
        // A tenant-data fixture requires all five fields even while auth is offline.
        var context = makeIsolatedAPIContext()
        context.accountID = "reaction-memory-account"
        context.tenantID = "reaction-memory-tenant"
        context.imUID = "reaction-memory-actor"
        let state = AppState(
            api: IMAPIClient(httpTransport: RTCWireOfflineHTTPTransport()),
            messageStore: RTCWireEmptyMessageStore(), apiContextOverride: context
        )
        let store = state.conversationStore
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.messages = [makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)]
        store.commitConversationSnapshots([conversation])
        var frames: [CapturedConversationMemorySnapshot] = []
        let changes = store.memoryUpdates.dropFirst().sink { frame in
            frames.append(frame.captureMessages(from: store))
            XCTAssertEqual(store.conversations, frame.conversations)
            XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
        }
        defer { changes.cancel() }
        let add = try decodeRemoteExtra(#"{"message_id":"m1","channel_id":"c1","channel_type":"group","channel_seq":1,"operator_uid":"reader","extra_type":"reaction","emoji":"ok","action":"add","version":1}"#)
        let revision = store.memorySnapshot.revision
        state.applyRemoteMessageExtra(add, fromRealtime: true)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].revision, revision + 1)
        let updated = frames[0].conversations[0]
        XCTAssertEqual(updated.messages[0].reactions.map(\.count), [1])
        XCTAssertEqual(updated.messages[0].reactionDetails.map(\.id), ["m1_reader_ok"])
        XCTAssertEqual(updated.messages[0].status, .read)
        XCTAssertTrue(updated.messages[0].readStateKnown)
        XCTAssertEqual(updated.messages[0].readCount, 1)
        XCTAssertTrue(updated.messages[0].readBy.isEmpty)
        XCTAssertEqual(updated.unread, 1)
        XCTAssertEqual(updated.unreadReactionCount, 1)
        XCTAssertTrue(updated.hasUnreadReaction)
        XCTAssertEqual(frames[0].alertingUnreadTotal, 1)
        state.applyRemoteMessageExtra(add, fromRealtime: true)
        XCTAssertEqual(frames.count, 1, "deduped replay must not reapply reminder/read fields")
        XCTAssertEqual(store.memorySnapshot.revision, revision + 1)
        let remove = try decodeRemoteExtra(#"{"message_id":"m1","channel_id":"c1","channel_type":"group","operator_uid":"reader","extra_type":"reaction","emoji":"ok","action":"remove","version":2}"#)
        state.applyRemoteMessageExtra(remove, fromRealtime: true)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames[1].conversations[0].messages[0].reactions.isEmpty)
        XCTAssertTrue(frames[1].conversations[0].messages[0].reactionDetails.isEmpty)
        XCTAssertEqual(frames[1].conversations[0].unread, 1, "remove keeps the existing reminder contract")
        XCTAssertTrue(conversation.messages[0].reactions.isEmpty)
    }

    func testReactionEventPreservesOriginalCrossConversationTargetSelection() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        first.hasUnreadReaction = false
        first.unreadReactionCount = 0
        first.messages = [makeMessage(id: "same", seq: 1, status: .sent, isOutgoing: false)]
        var second = makeConversation(id: "second", unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        second.hasUnreadReaction = false
        second.unreadReactionCount = 0
        second.messages = [makeMessage(id: "same", seq: 1, status: .sent, isOutgoing: true)]
        store.commitConversationSnapshots([first, second])
        var frames: [[ConversationMessageSnapshot]] = []
        let changes = store.memoryUpdates.dropFirst().sink { _ in frames.append(store.conversationMessageSnapshots()) }
        defer { changes.cancel() }
        let extra = try decodeRemoteExtra(#"{"message_id":"same","channel_id":"second","channel_type":"group","operator_uid":"reader","extra_type":"reaction","emoji":"ok","action":"add"}"#)
        XCTAssertTrue(store.applyReactionExtra(extra, currentUserIDs: ["me"], activeConversationID: nil,
            includeReminder: true, channelIDForConversation: { $0.id }, makeReactionDetail: makeReactionDetail(from:id:)))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0][0].messages[0].reactions.count, 1)
        XCTAssertEqual(frames[0][0].messages[0].reactionDetails.count, 1)
        XCTAssertEqual(frames[0][0].messages[0].status, .sent)
        XCTAssertEqual(frames[0][0].unread, 1)
        XCTAssertEqual(frames[0][1].messages[0].status, .read)
        XCTAssertTrue(frames[0][1].messages[0].readStateKnown)
        XCTAssertTrue(frames[0][1].messages[0].reactions.isEmpty)
        XCTAssertEqual(frames[0][1].unread, 0)
    }

    func testReactionEventDoesNotShortCircuitReadAndReminderWhenEmojiIsInvalid() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.messages = [makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)]
        store.commitConversationSnapshots([conversation])
        let revision = store.memorySnapshot.revision
        let extra = try decodeRemoteExtra(#"{"message_id":"m1","channel_id":"c1","channel_type":"group","operator_uid":"reader","extra_type":"reaction","emoji":" ","action":"add"}"#)
        XCTAssertFalse(store.applyReactionExtra(extra, currentUserIDs: ["me"], activeConversationID: nil,
            includeReminder: true, channelIDForConversation: { $0.id }, makeReactionDetail: makeReactionDetail(from:id:)))
        XCTAssertEqual(store.memorySnapshot.revision, revision + 1)
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].reactions.isEmpty)
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].reactionDetails.isEmpty)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[0].status, .read)
        XCTAssertTrue(store.conversationMessageSnapshots()[0].messages[0].readStateKnown)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unreadReactionCount, 1)
    }

    func testRemoteEditAndPinPublishAllMatchingConversationsInOneRevision() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        func row(_ id: String) -> ConversationMessageSnapshot {
            var row = makeConversation(id: id, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
            row.messages = [makeMessage(id: "same", seq: 1, status: .read, text: "original")]
            row.lastMessage = "original"
            return row
        }
        let original = [row("first"), row("second"), row("other")]
        store.commitConversationSnapshots(original)
        var frames: [CapturedConversationMemorySnapshot] = []
        let changes = store.memoryUpdates.dropFirst().sink { frames.append($0.captureMessages(from: store)) }
        defer { changes.cancel() }
        let edit = try decodeRemoteExtra(#"{"message_id":"same","channel_id":"remote","channel_type":"group","channel_seq":1,"extra_type":"edit","payload":{"edit_revision":5,"payload":{"text":"edited","edit_revision":5}}}"#)
        XCTAssertTrue(store.applyRemoteEditExtra(edit, normalizedChannelID: "remote", channelIDForConversation: { value in
            XCTAssertEqual(store.conversationMessageSnapshots(), original, "mapping cannot observe another row half edited")
            return value.id == "other" ? "other" : "remote"
        }))
        XCTAssertEqual(frames.count, 1)
        for value in frames[0].conversations.prefix(2) {
            XCTAssertEqual(value.messages[0].text, "edited")
            XCTAssertTrue(value.messages[0].isEdited)
            XCTAssertEqual(value.messages[0].editRevision, 5)
            XCTAssertEqual(value.lastMessage, "edited")
        }
        XCTAssertEqual(frames[0].conversations[2], original[2])
        XCTAssertFalse(store.applyRemoteEditExtra(edit, normalizedChannelID: "remote",
            channelIDForConversation: { $0.id == "other" ? "other" : "remote" }))
        XCTAssertEqual(frames.count, 1)
        let pin = try decodeRemoteExtra(#"{"message_id":"same","extra_type":"pin","action":"pin","payload":{"pinned":true}}"#)
        XCTAssertTrue(store.applyRemotePinExtra(pin, normalizedChannelID: "remote",
            channelIDForConversation: { $0.id == "other" ? "other" : "remote" }))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1].revision, frames[0].revision + 1)
        XCTAssertEqual(frames[1].conversations.map { $0.messages[0].isPinned }, [true, true, false])
    }

    func testPersistedHistoryFallbackPublishesOnlyTheSortedCompleteWindow() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 30, lastReadSeq: 0)
        conversation.messages = [makeMessage(id: "m20", seq: 20)]
        conversation.lastMessage = "server summary"
        store.commitConversationSnapshots([conversation])
        var frames: [[ConversationMessageSnapshot]] = []
        let changes = store.memoryUpdates.dropFirst().sink { _ in frames.append(store.conversationMessageSnapshots()) }
        defer { changes.cancel() }
        let page = [makeMessage(id: "m30", seq: 30), makeMessage(id: "m10", seq: 10), makeMessage(id: "m25", seq: 25)]
        XCTAssertEqual(store.mergePersistedMessagePage(page, conversationID: "c1"), 3)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0][0].messages.map(\.channelSeq), [10, 20, 25, 30])
        XCTAssertEqual(frames[0][0].lastMessage, "server summary")
        XCTAssertEqual(conversation.messages.map(\.channelSeq), [20])
        let revision = store.memorySnapshot.revision
        XCTAssertEqual(store.mergePersistedMessagePage(page, conversationID: "c1"), 0)
        XCTAssertEqual(store.memorySnapshot.revision, revision)
        XCTAssertEqual(frames.count, 1)
    }

    func testSystemUnreadClearCommitsAllRowsAndRecoveryCoverageTogether() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "system-first", kind: .system, unread: 9, lastMsgSeq: 10, lastReadSeq: 0)
        first.messageCoveredThroughSeq = 4
        first.messageCoverageRequiresRecovery = true
        var second = makeConversation(id: "system-second", kind: .system, unread: 19, lastMsgSeq: 20, lastReadSeq: 0)
        second.messageCoveredThroughSeq = 10
        second.messageCoverageRequiresRecovery = true
        let direct = makeConversation(id: "direct", unread: 5, lastMsgSeq: 5, lastReadSeq: 0)
        store.commitConversationSnapshots([first, second, direct])
        var frames: [CapturedConversationMemorySnapshot] = []
        let changes = store.memoryUpdates.dropFirst().sink { frame in
            frames.append(frame.captureMessages(from: store))
            XCTAssertEqual(store.conversations, frame.conversations)
            XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
        }
        defer { changes.cancel() }
        store.clearUnread(conversationID: "system-alias", includeSystemConversations: true)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].conversations.prefix(2).map(\.lastReadSeq), [4, 10])
        for value in frames[0].conversations.prefix(2) {
            XCTAssertEqual(value.unread, 0)
            XCTAssertFalse(value.hasUnreadReaction)
            XCTAssertEqual(value.unreadReactionCount, 0)
            XCTAssertEqual(value.firstUnreadSeq, 0)
            XCTAssertEqual(value.firstUnreadMessageID, "")
            XCTAssertEqual(value.unreadAnchorState, "none")
            XCTAssertTrue(value.messageCoverageRequiresRecovery)
        }
        XCTAssertEqual(frames[0].conversations[2], direct)
        XCTAssertEqual(frames[0].alertingUnreadTotal, 5)
        store.clearUnread(conversationID: "missing", includeSystemConversations: false)
        XCTAssertEqual(frames.count, 1)
    }
}

extension RTCCallRecordMessageTests {
    @MainActor
    func testPersistedHistoryConflictPublishesCoverageAndOptionalInsertionInOneRevision() throws {
        let record = try XCTUnwrap(parse(outcome: .busy))
        for includeNormal in [false, true] {
            let authority = makeMessage(id: "authority", sequence: 10, record: record)
            let collision = makeMessage(id: "collision", sequence: 15, record: record)
            let normal = makeMessage(id: "normal", sequence: 7, record: nil)
            let owner = makeConversation(id: "owner", messages: [authority], coveredThrough: 10)
            let target = makeConversation(id: "target", messages: [makeMessage(id: "existing", sequence: 5, record: nil)], coveredThrough: 20)
            let store = ConversationStore(scope: TestMessageMemoryScope.value)
            store.commitConversationSnapshots([owner, target])
            var frames: [CapturedConversationMemorySnapshot] = []
            let changes = store.memoryUpdates.dropFirst().sink { frame in
                frames.append(frame.captureMessages(from: store))
                XCTAssertEqual(store.conversations, frame.conversations)
            }
            defer { changes.cancel() }
            let page = includeNormal ? [collision, normal] : [collision]
            XCTAssertEqual(store.mergePersistedMessagePage(page, conversationID: "target"), includeNormal ? 1 : 0)
            XCTAssertEqual(frames.count, 1)
            let committed = frames[0].conversations[1]
            XCTAssertEqual(committed.messageCoveredThroughSeq, 14)
            XCTAssertTrue(committed.messageCoverageRequiresRecovery)
            XCTAssertEqual(committed.messages.map(\.id), includeNormal ? ["existing", "normal"] : ["existing"])
            XCTAssertEqual(frames[0].conversations[0], owner)
            XCTAssertEqual(target.messageCoveredThroughSeq, 20)
        }
    }
}
// WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_END

// WDT_IOS1_REFACTOR_LIFECYCLE_ATOMIC_COMMIT_20261110_BEGIN
extension DomainStoreTests {
    func testLifecyclePinCommitsOnlyTheFinalSortedOrder() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var target = makeConversation(id: "target", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        target.sortTimestamp = 1
        var other = makeConversation(id: "other", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        other.sortTimestamp = 2
        store.commitConversationSnapshots([other, target])
        var frames: [[ConversationMessageSnapshot]] = []
        let changes = store.memoryUpdates.dropFirst().sink { _ in frames.append(store.conversationMessageSnapshots()) }
        defer { changes.cancel() }
        let change = try XCTUnwrap(store.toggleConversationPinned(conversationID: target.id))
        XCTAssertFalse(change.previousValue)
        XCTAssertTrue(change.conversation.isPinned)
        XCTAssertEqual(frames.map { $0.map(\.id) }, [["target", "other"]])
        XCTAssertTrue(frames.allSatisfy { $0[0].isPinned })
        frames.removeAll()
        store.restoreConversationPinned(conversationID: target.id, to: change.previousValue)
        XCTAssertEqual(frames.map { $0.map(\.id) }, [["other", "target"]])
        XCTAssertTrue(frames.allSatisfy { !$0[1].isPinned })
        XCTAssertEqual(store.conversationMessageSnapshots(), [other, target])
    }

    func testLifecycleGroupPreviewAndMembershipCommitCompleteMetadata() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var group = makeConversation(id: "group", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        group.lastMessage = "original"
        group.time = "old time"
        group.participants = [makeUser(id: "old")]
        group.memberCount = 7
        store.commitConversationSnapshots([group])
        var frames: [[ConversationMessageSnapshot]] = []
        let changes = store.memoryUpdates.dropFirst().sink { _ in frames.append(store.conversationMessageSnapshots()) }
        defer { changes.cancel() }
        XCTAssertTrue(store.updateGroupAllMutedConversationPreview(groupID: "group", groupName: "", message: "muted",
            time: "new time", channelIDForConversation: { $0.id }))
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0[0].lastMessage == "muted" && $0[0].time == "new time" })
        frames.removeAll()
        XCTAssertTrue(store.setGroupConversationParticipants(groupID: "group", groupName: "",
            participants: [makeUser(id: "new")], memberCount: 9))
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0[0].participants.map(\.id) == ["new"] && $0[0].memberCount == 9 })
        frames.removeAll()
        XCTAssertTrue(store.removeParticipantFromGroupConversation(groupID: "group", groupName: "", userID: "new", memberCount: nil))
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0[0].participants.isEmpty && $0[0].memberCount == nil })
        let revision = store.memorySnapshot.revision
        XCTAssertFalse(store.setGroupConversationParticipants(groupID: "missing", groupName: "", participants: [], memberCount: 1))
        XCTAssertEqual(store.memorySnapshot.revision, revision)
        XCTAssertEqual(group.memberCount, 7)
        XCTAssertEqual(group.participants.map(\.id), ["old"])
    }

    func testLifecycleParticipantBatchesKeepCallbacksOnThePreviousCompleteSnapshot() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.participants = [makeUser(id: "peer"), makeUser(id: "other")]
        var second = makeConversation(id: "second", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.participants = [makeUser(id: "peer")]
        let original = [first, second]
        store.commitConversationSnapshots(original)
        var frames: [[ConversationMessageSnapshot]] = []
        let changes = store.memoryUpdates.dropFirst().sink { _ in frames.append(store.conversationMessageSnapshots()) }
        defer { changes.cancel() }
        XCTAssertEqual(store.updateConversationParticipants { user in
            XCTAssertEqual(store.conversationMessageSnapshots(), original, "transform must not see an earlier row half committed")
            return user.withName(user.name + " updated")
        }, 3)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0.flatMap(\.participants).allSatisfy { $0.name.hasSuffix(" updated") } })
        let retained = store.conversationMessageSnapshots()
        frames.removeAll()
        XCTAssertEqual(store.updateConversationParticipants { $0 }, 0)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(store.removeParticipantFromAllConversations(userID: "peer"), 2)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0.map { $0.participants.map(\.id) } == [["other"], []] })
        XCTAssertEqual(retained[0].participants.map(\.id), ["peer", "other"])
        XCTAssertEqual(retained[1].participants.map(\.id), ["peer"])
    }

    func testDirectUnavailableCommitsSubtitleAndUnreadTogether() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var direct = makeConversation(id: "direct", kind: .direct, unread: 7, lastMsgSeq: 7, lastReadSeq: 0)
        direct.subtitle = "available"
        direct.hasUnreadReaction = false
        direct.unreadReactionCount = 0
        direct.messages = [makeMessage(id: "m1", seq: 7, text: "original")]
        store.commitConversationSnapshots([direct])
        let context = DirectFriendRequestContext(targetUID: "peer", canApplyFriend: false,
            friendRequestStatus: "pending", reasonCode: "friendship_required")
        var frames: [CapturedConversationMemorySnapshot] = []
        let changes = store.memoryUpdates.dropFirst().sink { frames.append($0.captureMessages(from: store)) }
        defer { changes.cancel() }
        store.markDirectConversationUnavailable(direct, context: context)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0.conversations[0].subtitle == "需要好友关系" && $0.conversations[0].unread == 0 && $0.alertingUnreadTotal == 0 })
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages, direct.messages)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastReadSeq, direct.lastReadSeq)
        XCTAssertEqual(store.directFriendRequestContext(conversationID: direct.id), context)
        XCTAssertEqual(store.directDisabledMessage(conversationID: direct.id), context.disabledMessage)
        XCTAssertEqual(store.historyMessage(conversationID: direct.id), context.disabledMessage)
        let revision = store.memorySnapshot.revision
        store.markDirectConversationUnavailable(direct, context: context)
        XCTAssertEqual(store.memorySnapshot.revision, revision)
        XCTAssertEqual(direct.unread, 7)
        XCTAssertEqual(direct.subtitle, "available")
    }
}
// WDT_IOS1_REFACTOR_LIFECYCLE_ATOMIC_COMMIT_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
extension DomainStoreTests {
    func testIncrementalUnreadKeepsPhysicalDuplicateRowsAndLegacyContributionRules() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var rows = [
            makeConversation(id: "same", unread: 3, lastMsgSeq: 9, lastReadSeq: 1),
            makeConversation(id: "same", unread: 8, lastMsgSeq: 9, lastReadSeq: 1),
            makeConversation(id: " same ", unread: 5, lastMsgSeq: 9, lastReadSeq: 1),
            makeConversation(id: "", unread: 4, lastMsgSeq: 9, lastReadSeq: 1),
            makeConversation(id: "system_notification", kind: .system, unread: 6, lastMsgSeq: 9, lastReadSeq: 1)
        ]
        store.commitConversationSnapshots(rows)
        XCTAssertEqual(store.alertingUnreadTotal, 26)
        XCTAssertEqual(ConversationUnreadBadgeProjection.total(store.conversations, excludingConversationID: "same"), 15)
        rows[1].unread = -8
        store.commitConversationSnapshot(rows[1], at: 1)
        XCTAssertEqual(store.alertingUnreadTotal, 18)
        rows[0].unread = 9; rows[2].isMuted = true
        store.commitConversationChanges([0: rows[0], 2: rows[2]])
        XCTAssertEqual(store.alertingUnreadTotal, 19)
        XCTAssertEqual(store.conversations.count, 5, "duplicate and normalization-conflicting IDs are not deduplicated by the unread cache")
        XCTAssertNotNil(store.deleteConversation(conversationID: "same"))
        XCTAssertEqual(store.alertingUnreadTotal, 10)
        XCTAssertNotNil(store.toggleConversationPinned(conversationID: "system_notification"))
        XCTAssertEqual(store.alertingUnreadTotal, 10)
        XCTAssertNotNil(store.toggleConversationMuted(conversationID: " same "))
        XCTAssertEqual(store.alertingUnreadTotal, 15)
        store.clearUnread(conversationID: "system_notification", includeSystemConversations: true)
        XCTAssertEqual(store.alertingUnreadTotal, 9)
        var silent = makeConversation(id: "silent", unread: Int.max, lastMsgSeq: 1, lastReadSeq: 0)
        silent.isMuted = true
        let negative = makeConversation(id: "negative", unread: Int.min, lastMsgSeq: 1, lastReadSeq: 0)
        store.commitConversationSnapshots([silent, negative])
        XCTAssertEqual(store.alertingUnreadTotal, 0)
    }

    // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_BEGIN
    func testDuplicateListProjectionSignalCoversHiddenRowsAndSharedWindows() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let first = makeConversation(id: "same", unread: 1, lastMsgSeq: 0, lastReadSeq: 0)
        var duplicate = first
        duplicate.title = "second"
        duplicate.unread = 2
        var commits: [ConversationStore.MemoryCommit] = []
        let observation = store.memoryCommits.sink { commits.append($0) }
        defer { observation.cancel() }

        store.commitConversationSnapshots([first])
        store.commitConversationSnapshots([first, duplicate])
        store.commitConversationSnapshots([first, duplicate])
        duplicate.hasMention = true
        duplicate.mentionCount = 1
        store.commitConversationSnapshot(duplicate, at: 1)
        let hiddenRow = try XCTUnwrap(commits.last)
        XCTAssertTrue(hiddenRow.changedConversationRowIDs.isEmpty)
        XCTAssertFalse(hiddenRow.conversationOrderChanged)
        XCTAssertTrue(hiddenRow.messageChanges.isEmpty)
        XCTAssertEqual(hiddenRow.current.conversations.map(\.mentionCount), [0, 1])
        XCTAssertEqual(store.conversation(id: first.id), first.conversation)
        XCTAssertEqual(store.alertingUnreadTotal, ConversationUnreadBadgeProjection.total([first.conversation, duplicate.conversation]))

        var firstWithMessage = first
        firstWithMessage.messages = [makeMessage(id: "message", seq: 1)]
        store.commitConversationSnapshot(firstWithMessage, at: 0)
        let sharedWindow = try XCTUnwrap(commits.last)
        XCTAssertTrue(sharedWindow.changedConversationRowIDs.isEmpty)
        XCTAssertFalse(sharedWindow.conversationOrderChanged)
        XCTAssertEqual(sharedWindow.messageChanges[first.id]?.current, firstWithMessage.messages)
        XCTAssertEqual(store.conversationMessageSnapshot(id: first.id), firstWithMessage)

        store.commitConversationSnapshots([firstWithMessage])
        var last = firstWithMessage
        last.messages.append(makeMessage(id: "next", seq: 2))
        let result = ConversationStore.AppliedRemoteMessagesConversationResult(conversation: last,
            incomingRealtimeMessages: [], shouldPlayIncomingSound: false, shouldAutoRead: false)
        store.performRealtimeAtomicCommand(allowsSingleConversationUpdate: true) {
            _ = store.applyPreparedRealtimeConversation(result, previousID: first.id, channelID: first.id, changed: true)
        }
        XCTAssertEqual(store.conversationMessageSnapshot(id: first.id), last)
        XCTAssertEqual(commits.map(\.requiresFullConversationListProjection), [false, true, false, true, true, true, false])

        store.commitConversationSnapshots([last, duplicate])
        store.bindMessageScope(nil, preservesMessages: false)
        XCTAssertEqual(commits.suffix(2).map(\.requiresFullConversationListProjection), [true, true])
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertNil(store.conversationMessageSnapshot(id: first.id))
    }
    // WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_END

    func testIncrementalUnreadBatchRemovesOldContributionsBeforeAddingNewOnes() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", unread: Int.max - 2, lastMsgSeq: 1, lastReadSeq: 0)
        var second = makeConversation(id: "second", unread: 2, lastMsgSeq: 1, lastReadSeq: 0)
        store.commitConversationSnapshots([first, second])
        XCTAssertEqual(store.alertingUnreadTotal, Int.max)
        first.unread = 0; second.unread = Int.max
        store.commitConversationChanges([0: first, 1: second])
        XCTAssertEqual(store.alertingUnreadTotal, Int.max, "valid final totals cannot overflow because of mutation iteration order")
        XCTAssertNotNil(store.toggleConversationMuted(conversationID: "second"))
        XCTAssertEqual(store.alertingUnreadTotal, 0)
        XCTAssertNotNil(store.toggleConversationMuted(conversationID: "second"))
        XCTAssertEqual(store.alertingUnreadTotal, Int.max)
    }

    func testIncrementalUnreadMixedPointAndSmallBatchSequenceMatchesAuthoritativeTotal() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let rows = (0..<80).map { index -> ConversationMessageSnapshot in
            var row = makeConversation(id: "row-\(index)", kind: index % 9 == 0 ? .system : .group,
                                       unread: index % 13 - 2, lastMsgSeq: 100, lastReadSeq: 1)
            row.isMuted = index % 5 == 0
            row.messages = [makeMessage(id: "message-\(index)", seq: 100)]
            return row
        }
        store.commitConversationSnapshots(rows)
        var frames = 0, badgeValues: [Int] = []
        let memory = store.memoryUpdates.dropFirst().sink { frame in
            frames += 1
            XCTAssertEqual(frame.alertingUnreadTotal, ConversationUnreadBadgeProjection.total(frame.conversations))
            XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
            XCTAssertEqual(store.memorySnapshot.revision, frame.revision)
            XCTAssertEqual(store.messageMemoryStore.revision, frame.revision)
        }
        let badges = store.alertingUnreadUpdates.dropFirst().sink { badgeValues.append($0) }
        defer { memory.cancel(); badges.cancel() }
        for step in 0..<240 {
            let index = (step * 37) % store.conversations.count
            let id = store.conversations[index].id
            switch step % 6 {
            case 0:
                store.mutateStoredConversation(at: index) { $0.unread = step % 37 - 8 }
            case 1:
                XCTAssertNotNil(store.toggleConversationMuted(conversationID: id))
            case 2:
                store.clearUnread(conversationID: id, includeSystemConversations: step % 18 == 2)
            case 3:
                let other = (index + step % 7) % store.conversations.count
                var changes: [Int: ConversationMessageSnapshot] = [:]
                for position in [index, other] {
                    var next = store.conversationMessageSnapshot(at: position)
                    next.unread = step % 29 - 4
                    next.isMuted.toggle()
                    changes[position] = next
                }
                store.commitConversationChanges(changes)
            case 4:
                let total = store.alertingUnreadTotal
                XCTAssertNotNil(store.toggleConversationPinned(conversationID: id))
                XCTAssertEqual(store.alertingUnreadTotal, total)
            default:
                let total = store.alertingUnreadTotal, count = badgeValues.count
                let message = store.conversationMessageSnapshot(at: index).messages[0]
                _ = store.updateAttachmentProgress(Double(step % 10) / 10, messageID: message.id, conversationID: id)
                XCTAssertEqual(store.alertingUnreadTotal, total)
                XCTAssertEqual(badgeValues.count, count, "message-only changes do not publish a badge")
            }
            XCTAssertEqual(store.alertingUnreadTotal, ConversationUnreadBadgeProjection.total(store.conversations))
        }
        XCTAssertGreaterThan(frames, 200)
        XCTAssertFalse(badgeValues.isEmpty)
    }

    func testIncrementalUnreadReentrantCommandsUseEachPendingFrameAndPublishCoherently() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let first = makeConversation(id: "first", unread: 3, lastMsgSeq: 10, lastReadSeq: 1)
        let second = makeConversation(id: "second", unread: 5, lastMsgSeq: 10, lastReadSeq: 1)
        store.commitConversationSnapshots([first, second])
        let revision = store.memorySnapshot.revision
        var totals: [Int] = [], badges: [Int] = [], commits: [UInt64] = []
        let memory = store.memoryUpdates.dropFirst().sink { frame in
            totals.append(frame.alertingUnreadTotal)
            XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
            XCTAssertEqual(frame.alertingUnreadTotal, ConversationUnreadBadgeProjection.total(frame.conversations))
            if frame.revision == revision + 1 {
                XCTAssertNotNil(store.toggleConversationMuted(conversationID: "first"))
                store.clearUnread(conversationID: "second", includeSystemConversations: false)
                store.mutateStoredConversation(at: 0) { $0.unread = 7 }
                XCTAssertNotNil(store.toggleConversationMuted(conversationID: "first"))
                XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
            }
        }
        let badge = store.alertingUnreadUpdates.dropFirst().sink { value in
            badges.append(value); XCTAssertEqual(store.alertingUnreadTotal, value)
        }
        let changes = store.memoryCommits.sink { commit in
            commits.append(commit.current.revision)
            XCTAssertEqual(store.alertingUnreadTotal, commit.current.alertingUnreadTotal)
            XCTAssertEqual(store.memorySnapshot.revision, commit.current.revision)
        }
        defer { memory.cancel(); badge.cancel(); changes.cancel() }
        store.mutateStoredConversation(at: 0) { $0.unread = 4 }
        XCTAssertEqual(totals, [9, 5, 0, 0, 7])
        XCTAssertEqual(badges, [9, 5, 0, 7])
        XCTAssertEqual(commits, (1...5).map { revision + UInt64($0) })
        XCTAssertEqual(store.alertingUnreadTotal, 7)
    }

    func testIncrementalUnreadCacheFollowsFullScopeAndPreservesSameScopeCredentialRotation() throws {
        let state = AppState(api: IMAPIClient(httpTransport: RTCWireOfflineHTTPTransport()),
            messageStore: RTCWireEmptyMessageStore(), protectedSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makeAuthenticatedAPIContext(accountID: UUID().uuidString))
        let store = state.conversationStore
        let scope = try LocalMessageScope(context: state.apiContext)
        let row = makeConversation(id: "same", unread: 11, lastMsgSeq: 20, lastReadSeq: 1)
        store.commitConversationSnapshots([row])
        state.apiContext.imToken = "incremental-unread-rotated-test-credential"
        XCTAssertEqual(store.alertingUnreadTotal, 11)
        store.bindMessageScope(scope, preservesMessages: true)
        XCTAssertEqual(store.alertingUnreadTotal, 11)
        let replacement = try LocalMessageScope(accountID: scope.accountID, tenantID: "other-tenant",
            appID: scope.appID, actorID: scope.actorID, deviceID: scope.deviceID)
        store.bindMessageScope(replacement, preservesMessages: false)
        XCTAssertEqual(store.alertingUnreadTotal, 0)
        XCTAssertTrue(store.conversations.isEmpty)
        var updated = row; updated.unread = 7
        store.commitConversationSnapshots([updated])
        XCTAssertEqual(store.alertingUnreadTotal, 7)
        store.reset()
        XCTAssertEqual(store.alertingUnreadTotal, 0)
        store.bindMessageScope(scope, preservesMessages: false)
        XCTAssertEqual(store.alertingUnreadTotal, 0)
        store.commitConversationSnapshots([row])
        XCTAssertEqual(store.alertingUnreadTotal, 11)
    }
}
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

// WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
extension DomainStoreTests {
    func testIncrementalUnreadSyncedReactionBatchKeepsBothRowsAndOneRevision() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var first = makeConversation(id: "first", kind: .group, unread: 3, lastMsgSeq: 1, lastReadSeq: 0)
        var second = makeConversation(id: "second", kind: .group, unread: 5, lastMsgSeq: 1, lastReadSeq: 0)
        first.messages = [makeMessage(id: "first-message", seq: 1)]
        second.messages = [makeMessage(id: "second-message", seq: 1)]
        store.commitConversationSnapshots([first, second])
        let one = try decodeRemoteExtra(#"{"message_id":"first-message","channel_id":"first","channel_type":"group","operator_uid":"reader","extra_type":"reaction","emoji":"ok","action":"add","version":1}"#)
        let two = try decodeRemoteExtra(#"{"message_id":"second-message","channel_id":"second","channel_type":"group","operator_uid":"reader","extra_type":"reaction","emoji":"ok","action":"add","version":1}"#)
        var frames = 0, badges = 0
        let memory = store.memoryUpdates.dropFirst().sink { frame in
            frames += 1
            XCTAssertEqual(frame.alertingUnreadTotal, 8)
            XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
        }
        let badge = store.alertingUnreadUpdates.dropFirst().sink { _ in badges += 1 }
        defer { memory.cancel(); badge.cancel() }
        let revision = store.memorySnapshot.revision
        let result = store.applySyncedReactionExtras([one, two], currentUserIDs: [], makeReactionDetail: makeReactionDetail(from:id:))
        XCTAssertEqual(result.conversationsChanged, 2)
        XCTAssertEqual(result.messagesChanged, 2)
        XCTAssertEqual(store.memorySnapshot.revision, revision + 1)
        XCTAssertEqual(frames, 1)
        XCTAssertEqual(badges, 0)
        XCTAssertEqual(store.alertingUnreadTotal, 8)
        XCTAssertEqual(store.conversationMessageSnapshot(id: "first")?.messages[0].reactions.first?.count, 1)
        XCTAssertEqual(store.conversationMessageSnapshot(id: "second")?.messages[0].reactions.first?.count, 1)
    }
}
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

// WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
extension DomainStoreTests {
    func testIncrementalUnreadRecalculatesStaleStructuralHintWithoutDroppingCallbackCommits() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let remove = makeConversation(id: "remove", unread: 3, lastMsgSeq: 10, lastReadSeq: 0)
        let keep = makeConversation(id: "keep", unread: 5, lastMsgSeq: 10, lastReadSeq: 0)
        store.commitConversationSnapshots([remove, keep])
        var nested = false, totals: [Int] = []
        let updates = store.memoryUpdates.dropFirst().sink { frame in
            totals.append(frame.alertingUnreadTotal)
            XCTAssertEqual(frame.alertingUnreadTotal, ConversationUnreadBadgeProjection.total(frame.conversations))
            XCTAssertEqual(store.alertingUnreadTotal, frame.alertingUnreadTotal)
        }
        defer { updates.cancel() }
        store.removeDirectConversations(peerID: "remove") { row in
            if !nested {
                nested = true
                store.mutateStoredConversation(at: 1) { $0.unread = 99 }
            }
            return row.id
        }
        // Preserve this legacy callback/full-replacement order. Its old prepared
        // list replaces the nested value, but each staged frame is still visible.
        XCTAssertEqual(totals, [102, 5])
        XCTAssertEqual(store.conversations.map(\.id), ["keep"])
        XCTAssertEqual(store.alertingUnreadTotal, 5)
    }
}
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

// WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
extension DomainStoreTests {
    func testIncrementalUnreadSystemReplacementCountsEachRemovedPhysicalRow() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        let group = makeConversation(id: "group", kind: .group, unread: 7, lastMsgSeq: 10, lastReadSeq: 1)
        let system = makeConversation(id: "system_notification", kind: .system, unread: 5, lastMsgSeq: 10, lastReadSeq: 1)
        var repeated = system; repeated.unread = 3
        let negative = makeConversation(id: "other-system", kind: .system, unread: -1, lastMsgSeq: 10, lastReadSeq: 1)
        store.commitConversationSnapshots([group, system, repeated, negative])
        XCTAssertEqual(store.alertingUnreadTotal, 15)
        store.replaceSystemConversation { previous in
            XCTAssertEqual(previous?.id, "system_notification")
            var next = system; next.unread = 2
            return next
        }
        XCTAssertEqual(store.alertingUnreadTotal, 9)
        XCTAssertEqual(store.conversations.count, 2)
        store.replaceSystemConversation { _ in nil }
        XCTAssertEqual(store.alertingUnreadTotal, 7)
        XCTAssertEqual(store.conversations.map(\.id), ["group"])
    }
}
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

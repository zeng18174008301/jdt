@testable import IM4Features
import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong
@testable import IM4Stores
@testable import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110

extension DomainStoreTests {
    func testTranscriptNormalEndAndCancelFinishAreIdempotentInEitherOrder() {
        for firstCallback in ["onEnded", "gestureStateReset"] {
            let control = ChatTranscriptScrollControl()
            let now = Date(timeIntervalSince1970: 100)
            _ = control.updateDrag(translation: CGSize(width: 0, height: 80), now: now, suppressionInterval: 1.6)
            _ = control.updateDrag(translation: CGSize(width: 0, height: 70), now: now, suppressionInterval: 1.6)
            XCTAssertEqual(control.finishDrag(now: now, suppressionInterval: 1.6), .latest, firstCallback)
            let finishedGeneration = control.generation
            let finishedDeadline = control.suppressedUntil
            XCTAssertNil(control.finishDrag(now: now.addingTimeInterval(600), suppressionInterval: 1.6), firstCallback)
            XCTAssertEqual(control.generation, finishedGeneration, firstCallback)
            XCTAssertEqual(control.suppressedUntil, finishedDeadline, firstCallback)
            XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(600)), firstCallback)
        }
    }

    func testTranscriptSceneAndPageDepartureFinishWithoutPublishingOrLosingAnchorAuthority() {
        let control = ChatTranscriptScrollControl()
        var publications = 0
        let observer = control.objectWillChange.sink { publications += 1 }
        let now = Date(timeIntervalSince1970: 100)
        var arbiter = ConversationScrollArbiter()
        arbiter.beginNormalOpen(now: now, duration: 3)
        let anchorGeneration = arbiter.generation
        _ = control.updateDrag(translation: CGSize(width: 0, height: 8), now: now, suppressionInterval: 1.6)
        _ = control.finishDrag(now: now, suppressionInterval: 1.6) // scene non-active
        let finishedGeneration = control.generation
        XCTAssertNil(control.finishDrag(now: now.addingTimeInterval(1), suppressionInterval: 1.6)) // disappear
        XCTAssertNil(control.finishDrag(now: now.addingTimeInterval(600), suppressionInterval: 1.6)) // same-scope appear
        XCTAssertEqual(control.generation, finishedGeneration)
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(600)))
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(
            source: .historyPrependCompensation, targetID: "history-anchor", anchor: .top,
            userInitiated: false, generation: anchorGeneration
        ), now: now), .allow)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(
            source: .jumpToLatest, targetID: "bottom", anchor: .bottom,
            userInitiated: true, generation: anchorGeneration
        ), now: now), .allowAndEndWindow)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observer) {}
    }

    func testChatScrollMetricsMeasurementStoreDoesNotPublishGeometryWrites() {
        let store = ChatScrollMetricsMeasurementStore()
        var viewInvalidationCount = 0
        let cancellable = store.objectWillChange.sink {
            viewInvalidationCount += 1
        }
        let first = ChatScrollMetricsSnapshot(
            viewportHeight: 720,
            contentMinY: -120,
            contentMaxY: 1_680
        )
        let second = ChatScrollMetricsSnapshot(
            viewportHeight: 720,
            contentMinY: -360,
            contentMaxY: 1_440
        )

        store.replace(with: first)
        store.replace(with: second)

        XCTAssertEqual(store.metrics, second)
        XCTAssertEqual(viewInvalidationCount, 0)

        store.replace(with: .zero)

        XCTAssertEqual(store.metrics, second)
        XCTAssertEqual(viewInvalidationCount, 0)

        store.removeAll()

        XCTAssertEqual(store.metrics, .zero)
        XCTAssertEqual(viewInvalidationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testChatTranscriptSkipsMidScrollChecksButProcessesEdgesAndLayoutChanges() {
        func metrics(offset: CGFloat, height: CGFloat = 1_600,
                     viewport: CGFloat = 600, readSeq: Int64 = 50) -> ChatScrollMetricsSnapshot {
            ChatScrollMetricsSnapshot(viewportHeight: viewport, contentMinY: -offset,
                                      contentMaxY: height - offset,
                                      renderedReadToken: "chat:\(readSeq)", renderedReadSeq: readSeq)
        }

        XCTAssertFalse(chatNeedsTranscriptLayoutUpdate(from: metrics(offset: 300), to: metrics(offset: 700)))
        XCTAssertTrue(chatNeedsTranscriptLayoutUpdate(from: metrics(offset: 300), to: metrics(offset: 140)))
        XCTAssertTrue(chatNeedsTranscriptLayoutUpdate(from: metrics(offset: 900), to: metrics(offset: 950)))
        // Both positions are close enough to follow the bottom, but only one can acknowledge reads.
        XCTAssertTrue(chatNeedsTranscriptLayoutUpdate(from: metrics(offset: 995), to: metrics(offset: 999)))
        XCTAssertTrue(chatNeedsTranscriptLayoutUpdate(from: metrics(offset: 300), to: metrics(offset: 300, height: 1_760)))
        XCTAssertTrue(chatNeedsTranscriptLayoutUpdate(from: metrics(offset: 300), to: metrics(offset: 300, viewport: 520)))
        XCTAssertTrue(chatNeedsTranscriptLayoutUpdate(from: metrics(offset: 300), to: metrics(offset: 300, readSeq: 51)))
    }

    func testChatOlderHistoryLoadAllowsPassiveScrollMetricsAtTop() {
        let visibility = ChatScrollVisibility(isAtBottom: false, isNearHistoryBoundary: true)

        XCTAssertTrue(chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: false,
            isUserBrowsingHistory: false,
            visibility: visibility
        ))
    }

    func testChatOlderHistoryLoadAutofillsWhenShortContentIsBothTopAndBottom() {
        let visibility = ChatScrollVisibility(
            isAtBottom: true,
            isNearHistoryBoundary: true,
            isContentUnderfilled: true
        )

        XCTAssertTrue(chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: false,
            isUserBrowsingHistory: false,
            visibility: visibility
        ))
        XCTAssertTrue(chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: true,
            isUserBrowsingHistory: true,
            visibility: visibility
        ))
    }

    func testChatOlderHistoryLoadDoesNotAutofillAtBottomWhenContentCanScroll() {
        let visibility = ChatScrollVisibility(
            isAtBottom: true,
            isNearHistoryBoundary: true,
            isContentUnderfilled: false
        )

        XCTAssertFalse(chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: false,
            isUserBrowsingHistory: false,
            visibility: visibility
        ))
    }

    func testChatInitialScrollAnchorUsesBottomWhenLatestReadMessageIsVisible() throws {
        var latestReadMessage = makeMessage(id: "m42", seq: 42, status: .read, isOutgoing: true, text: "last read full content")
        latestReadMessage.readCount = 2
        let messages = [
            makeMessage(id: "m40", seq: 40),
            makeMessage(id: "m41", seq: 41),
            latestReadMessage
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 0,
            lastReadSeq: 42,
            firstUnreadMessageID: "",
            firstUnreadSeq: 0,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenNewerMessagesFollowReadStatus() throws {
        var readMessage = makeMessage(id: "m40", seq: 40, status: .read, isOutgoing: true, text: "last displayed read message")
        readMessage.readCount = 3
        let middleIncoming = makeMessage(id: "m41", seq: 41, text: "newer incoming")
        let latestIncoming = makeMessage(id: "m42", seq: 42)
        let messages = [readMessage, middleIncoming, latestIncoming]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 0,
            lastReadSeq: 42,
            firstUnreadMessageID: "",
            firstUnreadSeq: 0,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenReadCursorIsOutsideLatestWindow() throws {
        let latestMessages = [
            makeMessage(id: "m50", seq: 50),
            makeMessage(id: "m51", seq: 51)
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: latestMessages,
            unreadCount: 0,
            lastReadSeq: 42,
            firstUnreadMessageID: "",
            firstUnreadSeq: 0,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenFirstUnreadLacksRemoteID() throws {
        let messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2, isOutgoing: true),
            makeMessage(id: "m3", seq: 3),
            makeMessage(id: "m4", seq: 4)
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 2,
            lastReadSeq: 0,
            firstUnreadMessageID: "",
            firstUnreadSeq: 3,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenUnreadSeqIsJustOutsideWindow() throws {
        let messages = [
            makeMessage(id: "m40", seq: 40),
            makeMessage(id: "m41", seq: 41),
            makeMessage(id: "m42", seq: 42, isOutgoing: true)
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 1,
            lastReadSeq: 0,
            firstUnreadMessageID: "",
            firstUnreadSeq: 43,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatCanReuseConfirmedBottomForSameReadWindow() {
        XCTAssertTrue(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 42,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 42
        ))
        XCTAssertTrue(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 42,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 45
        ))
    }

    func testChatCannotReuseConfirmedBottomForUnreadOrNewerWindow() {
        XCTAssertFalse(chatCanReuseConfirmedBottom(
            unreadCount: 1,
            latestBottomTargetSeq: 42,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 42
        ))
        XCTAssertFalse(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 43,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 42
        ))
        XCTAssertFalse(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 0,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 42
        ))
        XCTAssertFalse(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 42,
            isLatestMessageWindowLoaded: false,
            rememberedConfirmedSeq: 42
        ))
    }

    func testChatAutomaticBottomScrollStopsAfterUserLeavesBottom() {
        XCTAssertTrue(chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: false,
            isLoadingConversationHistory: false,
            isAutomaticBottomScrollSuppressed: false,
            didUserInteractWithMessageScroll: false,
            isAtBottom: false
        ))
        XCTAssertFalse(chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: true,
            isLoadingConversationHistory: false,
            isAutomaticBottomScrollSuppressed: false,
            didUserInteractWithMessageScroll: true,
            isAtBottom: false
        ))
        XCTAssertFalse(chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: false,
            isLoadingConversationHistory: false,
            isAutomaticBottomScrollSuppressed: true,
            didUserInteractWithMessageScroll: true,
            isAtBottom: false
        ))
        XCTAssertTrue(chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: false,
            isLoadingConversationHistory: false,
            isAutomaticBottomScrollSuppressed: false,
            didUserInteractWithMessageScroll: true,
            isAtBottom: true
        ))
    }

    func testChatLatestBottomConfirmationUsesNextMainQueueTick() {
        XCTAssertEqual(chatLatestBottomConfirmationDelays(force: false), [0])
        XCTAssertEqual(chatLatestBottomConfirmationDelays(force: true), [0])
    }

    func testGroupAnnouncementDisplayContentIgnoresEmptyPlaceholderNotice() {
        XCTAssertEqual(
            groupAnnouncementDisplayContent(content: "", summary: " ", groupNotice: "暂无群公告"),
            ""
        )
        XCTAssertFalse(
            groupAnnouncementHasVisibleContent(content: nil, summary: nil, groupNotice: "暂无群公告")
        )
        XCTAssertEqual(
            groupAnnouncementDisplayContent(content: " 正文 ", summary: "摘要", groupNotice: "暂无群公告"),
            "正文"
        )
        XCTAssertEqual(
            groupAnnouncementDisplayContent(content: "", summary: " 摘要 ", groupNotice: "公告占位"),
            "摘要"
        )
    }

    func testPublishingGroupAnnouncementReportsMissingGroupInsteadOfSilentFailure() {
        let state = AppState()
        var didComplete: Bool?

        state.publishGroupAnnouncement(groupID: "missing-group", title: "群公告", content: "公告内容") { success in
            didComplete = success
        }

        XCTAssertEqual(didComplete, false)
        XCTAssertEqual(state.toast, "群资料同步中，请稍后再试")
    }

    func testSocialGroupDescriptionPolicyTrimsClearsAndCountsUnicodeScalars() throws {
        XCTAssertEqual(try GroupDescriptionInputPolicy.normalize("  群描述  \n"), "群描述")
        XCTAssertEqual(try GroupDescriptionInputPolicy.normalize(" \n "), "")
        XCTAssertEqual(
            GroupDescriptionInputPolicy.normalizedUnicodeScalarCount("  \(String(repeating: "a", count: 500))  "),
            500
        )
        XCTAssertEqual(
            try GroupDescriptionInputPolicy.normalize(String(repeating: "a", count: 500)).unicodeScalars.count,
            500
        )
        XCTAssertThrowsError(try GroupDescriptionInputPolicy.normalize(String(repeating: "a", count: 501))) { error in
            XCTAssertEqual(error as? GroupDescriptionInputError, .tooLong)
        }
        XCTAssertThrowsError(
            try GroupDescriptionInputPolicy.normalize(String(repeating: "👨‍👩‍👧‍👦", count: 72))
        ) { error in
            XCTAssertEqual(error as? GroupDescriptionInputError, .tooLong)
        }
    }

    func testSocialGroupOwnerTransferIdempotencyReusesIntentAndQueuesAuthoritativeRefresh() {
        var state = IM4Stores.GroupOwnerTransferIdempotencyState()
        var createdKeys = ["key-1", "key-2", "key-3"]
        let makeKey = { createdKeys.removeFirst() }

        let first = state.key(scope: "tenant|owner", groupID: "group-1", targetUID: "member-1", makeKey: makeKey)
        let retry = state.key(scope: "tenant|owner", groupID: "group-1", targetUID: "member-1", makeKey: makeKey)
        let changedTarget = state.key(scope: "tenant|owner", groupID: "group-1", targetUID: "member-2", makeKey: makeKey)
        XCTAssertEqual(first, retry)
        XCTAssertNotEqual(first, changedTarget)

        state.clear(scope: "tenant|owner", groupID: "group-1", targetUID: "member-1")
        let completedIntent = state.key(scope: "tenant|owner", groupID: "group-1", targetUID: "member-1", makeKey: makeKey)
        XCTAssertNotEqual(first, completedIntent)

        let store = ContactStore()
        let refreshKey = "tenant|owner|group-1"
        XCTAssertTrue(store.beginGroupBundleRefresh(refreshKey: refreshKey, includeSecondaryData: true))
        XCTAssertFalse(store.beginGroupBundleRefresh(
            refreshKey: refreshKey,
            includeSecondaryData: true,
            queueIfAlreadyRunning: true
        ))
        XCTAssertTrue(store.isGroupBundlePendingFullRefresh(refreshKey: refreshKey))
        XCTAssertTrue(store.finishGroupBundleRefresh(refreshKey: refreshKey))
    }

    func testSocialFriendRequestPresentationSeparatesMerchantReviewCancellationAndIncomingActions() {
        let outgoing = FriendRequest(
            id: "outgoing",
            name: "目标",
            source: "我发出的申请",
            message: "等待企业审核",
            direction: "outgoing",
            tenantReviewStatus: "pending",
            peerReviewStatus: "tenant_review_pending",
            canRespond: false,
            accepted: false
        )
        XCTAssertTrue(outgoing.canCancel)
        XCTAssertEqual(outgoing.statusLabel, "等待对方通过")

        let incoming = FriendRequest(
            id: "incoming",
            name: "申请人",
            source: "好友申请",
            message: "等待企业审核",
            direction: "incoming",
            tenantReviewStatus: "pending",
            peerReviewStatus: "tenant_review_pending",
            canRespond: false,
            accepted: false
        )
        XCTAssertFalse(incoming.isPendingIncoming)
        XCTAssertFalse(incoming.canCancel)

        let cancelled = FriendRequest(
            id: "cancelled",
            name: "目标",
            source: "我发出的申请",
            message: "申请已取消",
            status: "cancelled",
            direction: "outgoing",
            canRespond: false,
            outcome: "application_cancelled",
            resolutionMode: "requester_cancel",
            accepted: false
        )
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertFalse(cancelled.canCancel)
        XCTAssertEqual(cancelled.statusLabel, "已取消")

        let suppressed = FriendRequest(
            id: "suppressed",
            name: "目标",
            source: "我发出的申请",
            message: "申请已受策略抑制",
            status: "suppressed",
            direction: "outgoing",
            canRespond: false,
            outcome: "application_suppressed",
            resolutionMode: "suppressed_by_policy",
            accepted: false
        )
        XCTAssertTrue(suppressed.isSuppressed)
        XCTAssertFalse(suppressed.isPendingOutgoing)
        XCTAssertFalse(suppressed.canCancel)
        XCTAssertFalse(suppressed.accepted)
        XCTAssertEqual(suppressed.statusLabel, "未投递")

        let expired = FriendRequest(
            id: "expired",
            name: "目标",
            source: "我发出的申请",
            message: "申请已过期",
            status: "expired",
            direction: "outgoing",
            canRespond: false,
            accepted: false
        )
        XCTAssertFalse(expired.isPendingOutgoing)
        XCTAssertFalse(expired.canCancel)
        XCTAssertEqual(expired.statusLabel, "已过期")

        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_application.cancelled", kind: "friend"))
    }

    func testSocialGroupAnnouncementReadCountsAreServerGatedAndScrubbedFailClosed() {
        let announcement = GroupAnnouncement(
            id: "announcement-1",
            groupID: "group-1",
            title: "标题",
            content: "正文",
            summary: "正文",
            createdBy: "owner",
            status: "published",
            createdAt: "2026-08-13T09:00:00Z",
            updatedAt: "2026-08-13T10:00:00.123456Z",
            publishedAt: "2026-08-13T09:00:00Z",
            unread: true,
            readAt: nil,
            displayPosition: "above_pinned_messages",
            readAction: "/api/tenant/groups/group-1/announcements/announcement-1/read",
            readCount: 2,
            unreadCount: 3,
            recipientCount: 5,
            canViewReadCounts: true
        )

        XCTAssertEqual(announcement.readCountSummary, "2 人已读 · 3 人未读 · 共 5 人")
        let scrubbed = announcement.scrubbingReadCounts()
        XCTAssertFalse(scrubbed.canViewReadCounts)
        XCTAssertNil(scrubbed.readCount)
        XCTAssertNil(scrubbed.unreadCount)
        XCTAssertNil(scrubbed.recipientCount)
        XCTAssertNil(scrubbed.readCountSummary)
        XCTAssertEqual(scrubbed.id, announcement.id)
        XCTAssertEqual(scrubbed.updatedAt, announcement.updatedAt)

        let staleResponse = GroupAnnouncementPrivacyProjection.sanitize(
            announcement,
            requestEpoch: 4,
            currentEpoch: 5
        )
        XCTAssertFalse(staleResponse.canViewReadCounts)
        XCTAssertNil(staleResponse.readCount)
        XCTAssertEqual(
            GroupAnnouncementPrivacyProjection.sanitize(
                announcement,
                requestEpoch: 5,
                currentEpoch: 5
            ).readCount,
            2
        )
    }

    func testSocialGroupAnnouncementRevisionMergeRejectsSlowSummaryAndReadRollback() {
        let newer = GroupAnnouncement(
            id: "announcement-1",
            groupID: "group-1",
            title: "新标题",
            content: "新正文",
            summary: "新正文",
            createdBy: "owner",
            status: "published",
            createdAt: "2026-08-13T09:00:00Z",
            updatedAt: "2026-08-13T10:00:00Z",
            publishedAt: "2026-08-13T09:00:00Z",
            unread: false,
            readAt: "2026-08-13T10:01:00Z",
            displayPosition: "above_pinned_messages",
            readAction: "",
            readCount: nil,
            unreadCount: nil,
            recipientCount: nil,
            canViewReadCounts: false
        )
        var older = newer
        older = GroupAnnouncement(
            id: older.id,
            groupID: older.groupID,
            title: "旧标题",
            content: "旧正文",
            summary: "旧正文",
            createdBy: older.createdBy,
            status: older.status,
            createdAt: older.createdAt,
            updatedAt: "2026-08-13T09:30:00Z",
            publishedAt: older.publishedAt,
            unread: true,
            readAt: nil,
            displayPosition: older.displayPosition,
            readAction: older.readAction,
            readCount: nil,
            unreadCount: nil,
            recipientCount: nil,
            canViewReadCounts: false
        )
        XCTAssertEqual(
            GroupAnnouncementRevisionProjection.preferred(
                existing: newer,
                incoming: older,
                existingRevision: Date(timeIntervalSince1970: 20),
                incomingRevision: Date(timeIntervalSince1970: 10)
            ).content,
            "新正文"
        )

        var sameRevisionUnread = newer
        sameRevisionUnread = GroupAnnouncement(
            id: sameRevisionUnread.id,
            groupID: sameRevisionUnread.groupID,
            title: sameRevisionUnread.title,
            content: sameRevisionUnread.content,
            summary: sameRevisionUnread.summary,
            createdBy: sameRevisionUnread.createdBy,
            status: sameRevisionUnread.status,
            createdAt: sameRevisionUnread.createdAt,
            updatedAt: sameRevisionUnread.updatedAt,
            publishedAt: sameRevisionUnread.publishedAt,
            unread: true,
            readAt: nil,
            displayPosition: sameRevisionUnread.displayPosition,
            readAction: sameRevisionUnread.readAction,
            readCount: nil,
            unreadCount: nil,
            recipientCount: nil,
            canViewReadCounts: false
        )
        XCTAssertFalse(
            GroupAnnouncementRevisionProjection.preferred(
                existing: newer,
                incoming: sameRevisionUnread,
                existingRevision: Date(timeIntervalSince1970: 20),
                incomingRevision: Date(timeIntervalSince1970: 20)
            ).unread
        )
    }

    func testConversationListDisplayTimestampTreatsPlainTimeAsToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 60 * 60)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 23,
            hour: 21,
            minute: 0
        )))

        let todayPlainTime = try XCTUnwrap(conversationListDisplayTimestamp("20:14", now: now, calendar: calendar))
        let yesterdayMonthDay = try XCTUnwrap(conversationListDisplayTimestamp("6月22日", now: now, calendar: calendar))
        let olderToday = try XCTUnwrap(conversationListDisplayTimestamp("15:34", now: now, calendar: calendar))

        XCTAssertGreaterThan(todayPlainTime, yesterdayMonthDay)
        XCTAssertGreaterThan(todayPlainTime, olderToday)
    }

    func testContactStoreResetClearsTransientState() {
        let store = ContactStore()
        XCTAssertTrue(store.beginContactsSync())
        store.setContactsSyncError("failed")
        store.remarks = ["u1": "Alice"]
        XCTAssertTrue(store.beginGroupInviteApprovalProcessing(requestID: "r1"))
        store.markFriendRelationsLoaded()
        store.replaceKnownInboxIDs(["inbox1"])
        store.rememberSystemInboxReadLocally(id: "system1")
        XCTAssertTrue(store.beginGroupAnnouncementDetailLoading(loadingKey: "group-1|announcement-1"))
        XCTAssertTrue(store.beginGroupBundleRefresh(refreshKey: "tenant-a|user-a|group-1", includeSecondaryData: false))
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: "tenant-a|user-a|group-1", includeSecondaryData: true))

        store.reset()

        XCTAssertFalse(store.isContactsSyncing())
        XCTAssertNil(store.contactsSyncError())
        XCTAssertTrue(store.remarks.isEmpty)
        XCTAssertFalse(store.hasGroupInviteApprovalProcessingIDs())
        XCTAssertFalse(store.friendRelationsLoaded())
        XCTAssertFalse(store.hasKnownInboxIDs())
        XCTAssertFalse(store.hasLocallyReadSystemInboxIDs())
        XCTAssertFalse(store.hasAnnouncementDetailLoadingKeys())
        XCTAssertFalse(store.hasGroupBundleRefreshModes())
        XCTAssertFalse(store.hasGroupBundlePendingFullRefreshKeys())
    }

    func testContactStoreFriendRelationsLoadedLifecycle() {
        let store = ContactStore()

        XCTAssertFalse(store.friendRelationsLoaded())

        store.markFriendRelationsLoaded()
        XCTAssertTrue(store.friendRelationsLoaded())

        store.reset()
        XCTAssertFalse(store.friendRelationsLoaded())
    }

    // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110_BEGIN
    // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110
    func testContactStoreChangesReachTheirOwnConsumersWithoutAppStateRelay() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store = state.contactStore
        let requestID = "approval-visible"
        var rendered: [Bool] = []
        func content(_ isProcessing: Bool) -> some View {
            rendered.append(isProcessing)
            return Text(isProcessing ? "处理中" : "待审核")
        }

        let hosted = hostForSimulatorUI(
            PublisherSnapshotView(
                initialValue: false, updates: store.groupInviteApprovalProcessingUpdates(requestID: requestID),
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
        var deviceIDs: [[String]] = []
        let global = state.objectWillChange.sink { globalUpdates += 1 }
        let devices = store.$deviceSessions.sink { deviceIDs.append($0.map(\.id)) }
        defer { global.cancel(); devices.cancel() }
        let initialRenderCount = rendered.count
        XCTAssertEqual(rendered.last, false)

        store.deviceSessions = [DeviceSession(
            id: "device", name: "Phone", platform: "iOS", lastSeen: "刚刚",
            status: "可信设备", isBound: true, isBlocked: false
        )]
        XCTAssertTrue(store.beginGroupInviteApprovalProcessing(requestID: "approval-other"))
        renderPendingChanges()
        XCTAssertEqual(deviceIDs, [[], ["device"]])
        XCTAssertEqual(rendered.count, initialRenderCount)
        XCTAssertEqual(globalUpdates, 0)

        XCTAssertTrue(store.beginGroupInviteApprovalProcessing(requestID: requestID))
        renderPendingChanges()
        XCTAssertEqual(rendered.last, true)
        store.finishGroupInviteApprovalProcessing(requestID: requestID)
        renderPendingChanges()
        XCTAssertEqual(rendered.last, false)
        XCTAssertEqual(globalUpdates, 0)

        // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_BEGIN
        var directoryUpdates: [ContactStore.DirectoryPresentationSnapshot] = []
        let directory = store.directoryPresentationUpdates.sink { directoryUpdates.append($0) }
        defer { directory.cancel() }
        let approvalRenderCount = rendered.count
        store.remarks["peer"] = "备注"
        store.contacts = [makeUser(id: "peer")]
        renderPendingChanges()
        XCTAssertEqual(directoryUpdates.count, 3)
        XCTAssertEqual(directoryUpdates.last?.remarks, ["peer": "备注"])
        XCTAssertEqual(directoryUpdates.last?.contacts.map(\.id), ["peer"])
        XCTAssertEqual(rendered.count, approvalRenderCount)
        XCTAssertEqual(globalUpdates, 0)
        // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_END
    }
    // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110_END

    func testContactStoreGroupInviteApprovalProcessingLifecycle() {
        let store = ContactStore()

        XCTAssertTrue(store.processingGroupInviteApprovalIDs().isEmpty)
        XCTAssertFalse(store.hasGroupInviteApprovalProcessingIDs())
        XCTAssertFalse(store.beginGroupInviteApprovalProcessing(requestID: ""))

        XCTAssertTrue(store.beginGroupInviteApprovalProcessing(requestID: " request-1 "))
        XCTAssertFalse(store.beginGroupInviteApprovalProcessing(requestID: "request-1"))
        XCTAssertTrue(store.isGroupInviteApprovalProcessing(requestID: "request-1"))
        XCTAssertEqual(store.processingGroupInviteApprovalIDs(), ["request-1"])
        XCTAssertTrue(store.hasGroupInviteApprovalProcessingIDs())

        store.finishGroupInviteApprovalProcessing(requestID: " request-1 ")
        XCTAssertFalse(store.isGroupInviteApprovalProcessing(requestID: "request-1"))
        XCTAssertFalse(store.hasGroupInviteApprovalProcessingIDs())

        XCTAssertTrue(store.beginGroupInviteApprovalProcessing(requestID: "request-2"))
        store.reset()
        XCTAssertTrue(store.processingGroupInviteApprovalIDs().isEmpty)
    }
}

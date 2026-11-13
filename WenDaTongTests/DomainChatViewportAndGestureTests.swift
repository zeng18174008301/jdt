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

extension DomainStoreTests {
    // WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110_BEGIN
    func testToastPresentationExpiresWithoutPublishingAppState() async throws {
        let state = AppState()
        let cleared = expectation(description: "current toast dismisses")
        var messages: [String?] = []
        var appUpdates = 0
        let observations = [
            state.toastPresentationStore.$message.dropFirst().sink { message in
                messages.append(message)
                if message == nil { cleared.fulfill() }
            },
            state.objectWillChange.sink { appUpdates += 1 }
        ]
        defer { observations.forEach { $0.cancel() } }

        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("旧提示")
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("新提示")
        XCTAssertEqual(state.toast, "新提示")
        XCTAssertEqual(appUpdates, 0)

        await fulfillment(of: [cleared], timeout: 6)
        XCTAssertNil(state.toast)
        XCTAssertEqual(messages, ["旧提示", "新提示", nil])
    }
    // WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110_END

    func testChatInitialLatestWindowWaitIgnoresUnreadOnlyRefresh() {
        XCTAssertFalse(chatShouldWaitForInitialLatestWindowRefresh(
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: false,
            canReuseConfirmedBottom: false
        ))
        XCTAssertTrue(chatShouldWaitForInitialLatestWindowRefresh(
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: true,
            canReuseConfirmedBottom: false
        ))
        XCTAssertFalse(chatShouldWaitForInitialLatestWindowRefresh(
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: true,
            canReuseConfirmedBottom: true
        ))
    }

    func testChatInitialEntrySyncPolicyDoesNotForceRemoteHistoryForUnreadOnlyEntry() {
        let policy = chatInitialEntrySyncPolicy(
            hasCachedMessages: true,
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: false,
            canReuseConfirmedBottom: false
        )

        XCTAssertEqual(policy, ChatInitialEntrySyncPolicy(
            forceRemoteHistory: false,
            silent: true,
            showLoadingIndicator: false,
            shouldWarmRefreshAfterInitialRender: true
        ))
    }

    func testChatInitialEntrySyncPolicyForcesRemoteHistoryWhenLatestWindowIsMissing() {
        let policy = chatInitialEntrySyncPolicy(
            hasCachedMessages: true,
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: true,
            canReuseConfirmedBottom: false
        )

        XCTAssertEqual(policy, ChatInitialEntrySyncPolicy(
            forceRemoteHistory: true,
            silent: false,
            showLoadingIndicator: true,
            shouldWarmRefreshAfterInitialRender: false
        ))
    }

    func testChatInitialScrollAnchorUsesBottomForUnreadEntryBeforeOldReadStatus() throws {
        var oldReadStatus = makeMessage(id: "m10", seq: 10, status: .read, isOutgoing: true, text: "old read receipt")
        oldReadStatus.readCount = 2
        let messages = [
            oldReadStatus,
            makeMessage(id: "m40", seq: 40),
            makeMessage(id: "m41", seq: 41),
            makeMessage(id: "m42", seq: 42, text: "last read before unread"),
            makeMessage(id: "m43", seq: 43, text: "new unread")
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 1,
            lastReadSeq: 42,
            firstUnreadMessageID: "m43",
            firstUnreadSeq: 43,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatUnreadReminderDoesNotClearFromInitialVisibleProgress() {
        XCTAssertFalse(chatCanClearUnreadReminderFromVisibleProgress(
            isUserBrowsingHistory: false,
            isAtBottom: false,
            didScrollTowardUnreadMessages: false
        ))
        XCTAssertTrue(chatCanClearUnreadReminderFromVisibleProgress(
            isUserBrowsingHistory: false,
            isAtBottom: false,
            didScrollTowardUnreadMessages: true
        ))
        XCTAssertTrue(chatCanClearUnreadReminderFromVisibleProgress(
            isUserBrowsingHistory: true,
            isAtBottom: true,
            didScrollTowardUnreadMessages: false
        ))
    }

    func testAutomaticReadSyncFailureDoesNotImmediatelyToast() {
        XCTAssertNil(chatReadSyncFailureToastMessage(isAutomaticRecoveryPath: true))
        XCTAssertEqual(
            chatReadSyncFailureToastMessage(isAutomaticRecoveryPath: false),
            "已读状态同步失败，请稍后重试"
        )
    }

    // WDT_CHAT_UNREAD_BADGE_20261021_BEGIN
    func testReadTargetUsesVisibleOutgoingTailWhenIncomingRowIsAboveViewport() throws {
        let messages = [
            makeMessage(id: "incoming", seq: 1),
            makeMessage(id: "reply-2", seq: 2, isOutgoing: true),
            makeMessage(id: "reply-3", seq: 3, isOutgoing: true)
        ]
        let target = try XCTUnwrap(chatReadAcknowledgementTarget(in: messages))
        XCTAssertEqual(target.id, "reply-3")
        let metrics = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -700, contentMaxY: 600,
            renderedReadToken: "chat:3", renderedReadSeq: target.channelSeq, readVisibilityEpoch: 4)
        let incomingRow = ChatIncomingRowGeometry(token: "chat:1", frame: CGRect(x: 0, y: -200, width: 300, height: 80), epoch: 4)
        let tailRow = ChatIncomingRowGeometry(token: "chat:3", frame: CGRect(x: 0, y: 500, width: 300, height: 80), epoch: 4)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: incomingRow, expectedToken: "chat:3",
            epoch: 4, isActive: true, scopeMatches: true))
        XCTAssertEqual(chatVisibleIncomingReadSequence(metrics: metrics, row: tailRow, expectedToken: "chat:3",
            epoch: 4, isActive: true, scopeMatches: true), 3)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: tailRow, expectedToken: "chat:4",
            epoch: 4, isActive: true, scopeMatches: true))
    }

    func testReadTargetExcludesUnconfirmedSystemAndPinnedContextRows() {
        var pinned = makeMessage(id: "pinned", seq: 9, isPinned: true)
        pinned.isPinnedContextOnly = true
        let messages = [
            makeMessage(id: "confirmed", seq: 1),
            makeMessage(id: "sending", seq: 2, status: .sending, isOutgoing: true),
            makeMessage(id: "failed", seq: 3, status: .failed, isOutgoing: true),
            makeMessage(id: "local", seq: 0, isOutgoing: true),
            makeMessage(id: "system", seq: 4, kind: .system),
            pinned
        ]
        XCTAssertEqual(chatReadAcknowledgementTarget(in: messages.lazy.map { $0 })?.id, "confirmed")
        XCTAssertNil(chatReadAcknowledgementTarget(in: messages.dropFirst()))
    }

    func testReadTargetHonorsExistingTombstonePresentationPolicy() {
        let messages = [
            makeMessage(id: "incoming", seq: 1),
            makeMessage(id: "outgoing", seq: 2, isOutgoing: true),
            makeMessage(id: "recalled", seq: 3, status: .recalled),
            makeMessage(id: "deleted", seq: 4, status: .recalled, isDeletedLocally: true)
        ]
        XCTAssertEqual(chatReadAcknowledgementTarget(in: chatTimelineMessagesForRendering(messages))?.id, "deleted")
        XCTAssertEqual(chatReadAcknowledgementTarget(in: chatTimelineMessagesForRendering(messages, showsProcessingNotices: false))?.id, "outgoing")
        XCTAssertTrue(messages[3].isDeletedLocally)
        XCTAssertEqual(messages[2].status, .recalled)
    }
    // WDT_CHAT_UNREAD_BADGE_20261021_END

    // WDT_CHAT_READ_TRIGGER_20261021_BEGIN
    func testReadObservationRequiresContentBottomIncludingTrailingSpace() {
        for viewport: CGFloat in [320, 600, 900] {
            // The old scroll target left 12pt beyond its ID even after alignment.
            let oldMetrics = ChatScrollMetricsSnapshot(viewportHeight: viewport, contentMinY: -700,
                contentMaxY: viewport + 12, renderedReadToken: "chat:21", renderedReadSeq: 21, readVisibilityEpoch: 4)
            let oldRow = ChatIncomingRowGeometry(token: "chat:21",
                frame: CGRect(x: 0, y: viewport - 24 - 8 - 80, width: 300, height: 80), epoch: 4)
            XCTAssertTrue(chatScrollVisibility(metrics: oldMetrics).isAtBottom)
            XCTAssertNil(chatVisibleIncomingReadSequence(metrics: oldMetrics, row: oldRow,
                expectedToken: "chat:21", epoch: 4, isActive: true, scopeMatches: true))

            // Including the same padding inside the target aligns the entire content.
            let metrics = ChatScrollMetricsSnapshot(viewportHeight: viewport, contentMinY: -712,
                contentMaxY: viewport, renderedReadToken: "chat:21", renderedReadSeq: 21, readVisibilityEpoch: 4)
            let row = ChatIncomingRowGeometry(token: "chat:21", frame: oldRow.frame.offsetBy(dx: 0, dy: -12), epoch: 4)
            XCTAssertEqual(metrics.contentHeight, oldMetrics.contentHeight)
            XCTAssertEqual(chatVisibleIncomingReadSequence(metrics: metrics, row: row,
                expectedToken: "chat:21", epoch: 4, isActive: true, scopeMatches: true), 21)
            XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: .empty,
                expectedToken: "chat:21", epoch: 4, isActive: true, scopeMatches: true))
            XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: row,
                expectedToken: "chat:22", epoch: 4, isActive: true, scopeMatches: true))
        }
    }
    // WDT_CHAT_READ_TRIGGER_20261021_END

    func testNativeChatScrollGeometryAccountsForHeaderSafeArea() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Requires native scroll geometry") }
        let layout = ChatScrollReadLayout(token: "chat:437", sequence: 437, epoch: 1)
        func metrics(at offset: CGFloat) -> ChatScrollMetricsSnapshot {
            layout.metrics(for: ScrollGeometry(
                contentOffset: CGPoint(x: 0, y: offset),
                contentSize: CGSize(width: 402, height: 4055),
                contentInsets: EdgeInsets(top: 118, leading: 0, bottom: 0, trailing: 0),
                containerSize: CGSize(width: 402, height: 658)
            ))
        }
        let visibleRow = ChatIncomingRowGeometry(
            token: "chat:437", frame: CGRect(x: 10, y: 542, width: 180, height: 80), epoch: 1
        )

        let top = metrics(at: -118)
        XCTAssertTrue(chatScrollVisibility(metrics: top).isNearHistoryBoundary)
        XCTAssertFalse(chatScrollVisibility(metrics: top).isAtBottom)

        let bottom = metrics(at: 3278)
        XCTAssertTrue(chatScrollVisibility(metrics: bottom).isAtBottom)
        XCTAssertEqual(chatVisibleIncomingReadSequence(metrics: bottom, row: visibleRow,
            expectedToken: "chat:437", epoch: 1, isActive: true, scopeMatches: true), 437)

        let beforeTrailingSpacer = metrics(at: 3266)
        XCTAssertTrue(chatScrollVisibility(metrics: beforeTrailingSpacer).isAtBottom)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: beforeTrailingSpacer, row: visibleRow,
            expectedToken: "chat:437", epoch: 1, isActive: true, scopeMatches: true))
    }

    func testReadObservationAdvancesWhenBottomBooleanStaysUnchanged() {
        let visibleRow = ChatIncomingRowGeometry(token: "chat:21", frame: CGRect(x: 0, y: 500, width: 300, height: 80), epoch: 4)
        let first = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -400, contentMaxY: 600,
            renderedReadToken: "chat:20", renderedReadSeq: 20, readVisibilityEpoch: 4)
        let next = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -450, contentMaxY: 600,
            renderedReadToken: "chat:21", renderedReadSeq: 21, readVisibilityEpoch: 4)
        XCTAssertEqual(chatScrollVisibility(metrics: first), chatScrollVisibility(metrics: next))
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(chatVisibleIncomingReadSequence(metrics: next, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true), 21)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: next, row: .empty, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true))
        let offscreen = ChatIncomingRowGeometry(token: "chat:21", frame: CGRect(x: 0, y: 650, width: 300, height: 80), epoch: 4)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: next, row: offscreen, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true))
        // The Store may publish 21 before the layout containing 20 is replaced.
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: first, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true))
    }

    func testReadObservationRejectsOffscreenBackgroundAndStaleScopeOrEpoch() {
        let visibleRow = ChatIncomingRowGeometry(token: "chat:21", frame: CGRect(x: 0, y: 500, width: 300, height: 80), epoch: 4)
        var metrics = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -450, contentMaxY: 650,
            renderedReadToken: "chat:21", renderedReadSeq: 21, readVisibilityEpoch: 4)
        // Within the scrolling tolerance is insufficient to mark the bottom read.
        XCTAssertTrue(chatScrollVisibility(metrics: metrics).isAtBottom)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true))
        metrics = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -500, contentMaxY: 600,
            renderedReadToken: "chat:21", renderedReadSeq: 21, readVisibilityEpoch: 4)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: false, scopeMatches: true))
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: false))
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: visibleRow, expectedToken: "chat:21",
            epoch: 5, isActive: true, scopeMatches: true))
    }

    func testLayoutCallbacksCoalesceBurstsAndInvalidateOnDeparture() throws {
        var callbacks = ChatLayoutCallbackCoalescer()
        let first = try XCTUnwrap(callbacks.schedule())
        for _ in 0..<1_000 { XCTAssertNil(callbacks.schedule()) }
        XCTAssertTrue(callbacks.consume(first))
        XCTAssertFalse(callbacks.consume(first))
        let obsolete = try XCTUnwrap(callbacks.schedule())
        callbacks.cancel()
        let current = try XCTUnwrap(callbacks.schedule())
        XCTAssertFalse(callbacks.consume(obsolete))
        XCTAssertTrue(callbacks.consume(current))
        // Geometry caused by the applied state can schedule one subsequent pass.
        XCTAssertNotNil(callbacks.schedule())
        XCTAssertNil(callbacks.schedule())
    }

    func testIncomingBottomFollowRetainsPreAppendBottomAcrossBurstAndMediaLayout() {
        var follow = ChatIncomingBottomFollowState()
        let bottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -400, contentMaxY: 600)
        let tallAppend = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -400, contentMaxY: 1600)
        follow.recordAppend(metrics: bottom, generation: 7, eligible: true)
        XCTAssertEqual(follow.decision(generation: 7), true)
        XCTAssertFalse(chatScrollVisibility(metrics: tallAppend).isAtBottom)
        follow.recordAppend(metrics: tallAppend, generation: 7, eligible: true)
        XCTAssertEqual(follow.decision(generation: 7), true)
        // Layout is not a user action and must not revoke the original decision.
        XCTAssertEqual(follow.decision(generation: 7), true)
    }

    func testIncomingBottomFollowPreservesHistoryUntilActuallyBackAtBottom() {
        var follow = ChatIncomingBottomFollowState()
        let history = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -100, contentMaxY: 1400)
        follow.recordAppend(metrics: history, generation: 3, eligible: true)
        XCTAssertEqual(follow.decision(generation: 3), false)
        follow.recordAppend(metrics: history, generation: 3, eligible: true)
        XCTAssertEqual(follow.decision(generation: 3), false)
        let bottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -900, contentMaxY: 600)
        follow.recordAppend(metrics: bottom, generation: 4, eligible: true)
        XCTAssertEqual(follow.decision(generation: 4), true)
    }

    func testIncomingBottomFollowUserDragInvalidatesQueuedBurstAndMediaWork() {
        var follow = ChatIncomingBottomFollowState()
        let control = ChatTranscriptScrollControl()
        let bottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -400, contentMaxY: 600)
        follow.recordAppend(metrics: bottom, generation: control.generation, eligible: true)
        XCTAssertEqual(follow.decision(generation: control.generation), true)
        let now = Date(timeIntervalSince1970: 100)
        _ = control.updateDrag(translation: CGSize(width: 0, height: 20), now: now, suppressionInterval: 1)
        XCTAssertNil(follow.decision(generation: control.generation))
        follow.recordAppend(metrics: bottom, generation: control.generation, eligible: false)
        XCTAssertEqual(follow.decision(generation: control.generation), false)
        _ = control.finishDrag(now: now, suppressionInterval: 1)
        XCTAssertNil(follow.decision(generation: control.generation))
    }

    func testIncomingBottomFollowRejectsMissingGeometryAndResetsOnScopeOrPrepend() {
        var follow = ChatIncomingBottomFollowState()
        follow.recordAppend(metrics: .zero, generation: 1, eligible: true)
        XCTAssertEqual(follow.decision(generation: 1), false)
        let short = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: 0, contentMaxY: 300)
        follow.recordAppend(metrics: short, generation: 1, eligible: true)
        XCTAssertEqual(follow.decision(generation: 1), true)
        follow.reset()
        XCTAssertNil(follow.decision(generation: 1))
        follow.recordAppend(metrics: short, generation: 2, eligible: false)
        XCTAssertEqual(follow.decision(generation: 2), false)
    }

    func testIncomingBottomFollowHasSeparateArbiterRouteAfterManualReturn() {
        var arbiter = ConversationScrollArbiter()
        let now = Date(timeIntervalSince1970: 100)
        arbiter.beginNormalOpen(now: now, duration: 1)
        let generation = arbiter.generation
        _ = arbiter.evaluate(ConversationScrollRequest(source: .userGesture, targetID: nil,
            anchor: nil, userInitiated: true, generation: generation), now: now)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .followBottom, targetID: "bottom",
            anchor: .bottom, userInitiated: false, generation: generation), now: now), .deny)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .incomingFollowBottom, targetID: "bottom",
            anchor: .bottom, userInitiated: false, generation: generation), now: now), .allow)
        arbiter.beginNormalOpen(now: now, duration: 1)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .incomingFollowBottom, targetID: "bottom",
            anchor: .bottom, userInitiated: false, generation: generation), now: now), .deny)
    }

    func testIncomingBottomFollowCorrectsViewportShrinkAfterConfirmedAppend() {
        var follow = ChatIncomingBottomFollowState()
        let confirmedBottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -800, contentMaxY: 600)
        follow.recordAppend(metrics: confirmedBottom, generation: 7, eligible: true)
        let shorterViewport = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -800, contentMaxY: 600)
        XCTAssertEqual(confirmedBottom.contentHeight, shorterViewport.contentHeight)
        XCTAssertTrue(follow.needsLayoutCorrection(from: confirmedBottom, to: shorterViewport, generation: 7))
        let corrected = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -920, contentMaxY: 480)
        XCTAssertFalse(follow.needsLayoutCorrection(from: shorterViewport, to: corrected, generation: 7))
        let lateMedia = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -920, contentMaxY: 900)
        XCTAssertTrue(follow.needsLayoutCorrection(from: corrected, to: lateMedia, generation: 7))
    }

    func testIncomingBottomFollowViewportShrinkDoesNotOverrideHistoryOrNewGesture() {
        var follow = ChatIncomingBottomFollowState()
        let history = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -100, contentMaxY: 1400)
        let shorterViewport = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -100, contentMaxY: 1400)
        follow.recordAppend(metrics: history, generation: 7, eligible: true)
        XCTAssertFalse(follow.needsLayoutCorrection(from: history, to: shorterViewport, generation: 7))
        let bottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -900, contentMaxY: 600)
        follow.recordAppend(metrics: bottom, generation: 8, eligible: true)
        XCTAssertFalse(follow.needsLayoutCorrection(from: bottom, to: shorterViewport, generation: 9))
        follow.reset()
        XCTAssertFalse(follow.needsLayoutCorrection(from: bottom, to: shorterViewport, generation: 8))
    }

    func testViewportRealignmentDoesNotReenableOrdinaryFollowingAfterManualReturn() {
        var arbiter = ConversationScrollArbiter()
        let now = Date(timeIntervalSince1970: 100)
        arbiter.beginNormalOpen(now: now, duration: 1)
        let generation = arbiter.generation
        _ = arbiter.evaluate(ConversationScrollRequest(source: .userGesture, targetID: nil,
            anchor: nil, userInitiated: true, generation: generation), now: now)
        let later = now.addingTimeInterval(10)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .viewportBottomRealignment,
            targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation), now: later), .allow)
        XCTAssertTrue(arbiter.isJumpMode)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .followBottom,
            targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation), now: later), .deny)
        arbiter.beginNormalOpen(now: later, duration: 1)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .viewportBottomRealignment,
            targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation), now: later), .deny)
    }

    func testViewportExpansionRealignsVisibleBottomWithKeyboardSizedGap() {
        let keyboard = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -1000, contentMaxY: 480)
        let restored = ChatScrollMetricsSnapshot(viewportHeight: 806, contentMinY: -1000, contentMaxY: 480)
        // Both remain "visible at bottom", which previously skipped correction.
        XCTAssertEqual(chatScrollVisibility(metrics: keyboard), chatScrollVisibility(metrics: restored))
        XCTAssertTrue(chatNeedsBottomRealignmentAfterViewportExpansion(from: keyboard, to: restored))
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: restored, to: restored))
        let aligned = ChatScrollMetricsSnapshot(viewportHeight: 806, contentMinY: -674, contentMaxY: 806)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: keyboard, to: aligned))
    }

    func testViewportExpansionDoesNotRepositionHistoryOrUnderfilledContent() {
        let history = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -200, contentMaxY: 900)
        let restoredHistory = ChatScrollMetricsSnapshot(viewportHeight: 1000, contentMinY: -200, contentMaxY: 900)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: history, to: restoredHistory))
        let short = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: 0, contentMaxY: 400)
        let restoredShort = ChatScrollMetricsSnapshot(viewportHeight: 806, contentMinY: 0, contentMaxY: 400)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: short, to: restoredShort))
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: .zero, to: restoredShort))
    }

    func testViewportExpansionIgnoresNormalSlackAndViewportShrink() {
        let keyboard = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -1000, contentMaxY: 480)
        let smallGap = ChatScrollMetricsSnapshot(viewportHeight: 500, contentMinY: -1000, contentMaxY: 480)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: keyboard, to: smallGap))
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: smallGap, to: keyboard))
        let invalid = ChatScrollMetricsSnapshot(viewportHeight: .infinity, contentMinY: -1000, contentMaxY: 480)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: keyboard, to: invalid))
    }

    func testChatScrollVisibilityTreatsShortContentAsBottom() {
        let visibility = chatScrollVisibility(metrics: ChatScrollMetricsSnapshot(
            viewportHeight: 600,
            contentMinY: 0,
            contentMaxY: 420
        ))

        XCTAssertTrue(visibility.isAtBottom)
        XCTAssertTrue(visibility.isNearHistoryBoundary)
        XCTAssertTrue(visibility.isContentUnderfilled)
    }

    func testChatScrollVisibilityDetectsBottomWithinTolerance() {
        let visibility = chatScrollVisibility(
            metrics: ChatScrollMetricsSnapshot(
                viewportHeight: 600,
                contentMinY: -760,
                contentMaxY: 632
            ),
            bottomTolerance: 56,
            historyPrefetchDistance: 160
        )

        XCTAssertTrue(visibility.isAtBottom)
        XCTAssertFalse(visibility.isNearHistoryBoundary)
        XCTAssertFalse(visibility.isContentUnderfilled)
    }

    func testChatScrollVisibilityDetectsHistoryPrefetchBoundary() {
        let visibility = chatScrollVisibility(
            metrics: ChatScrollMetricsSnapshot(
                viewportHeight: 600,
                contentMinY: -120,
                contentMaxY: 1_480
            ),
            bottomTolerance: 56,
            historyPrefetchDistance: 160
        )

        XCTAssertFalse(visibility.isAtBottom)
        XCTAssertTrue(visibility.isNearHistoryBoundary)
        XCTAssertFalse(visibility.isContentUnderfilled)
    }

    func testReturnToBottomPolicyRequiresMeasuredHistoryDistanceAndHasNoImmediateSideEffects() {
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: false,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: false,
            isSearchVisible: false,
            isReadOnlySystemConversation: false
        ))
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 0,
            isAtBottom: false,
            isSearchVisible: false,
            isReadOnlySystemConversation: false
        ))
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: true,
            isSearchVisible: false,
            isReadOnlySystemConversation: false
        ))
        XCTAssertTrue(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: false,
            isSearchVisible: false,
            isReadOnlySystemConversation: false
        ))
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: false,
            isSearchVisible: true,
            isReadOnlySystemConversation: false
        ))
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: false,
            isSearchVisible: false,
            isReadOnlySystemConversation: true
        ))

        let plan = chatReturnToBottomActionPlan(bottomAnchorID: "chat-bottom-anchor")
        XCTAssertEqual(plan.targetID, "chat-bottom-anchor")
        XCTAssertEqual(plan.source, .jumpToLatest)
        XCTAssertEqual(plan.anchor, .bottom)
        XCTAssertFalse(plan.acknowledgesReadImmediately)
        XCTAssertFalse(plan.loadsHistoryPage)
        XCTAssertFalse(plan.rebuildsTimeline)
    }

    func testTranscriptKeyboardDismissalTriggersPreserveDraftAndHaveNoChatSideEffects() {
        for trigger in ChatTranscriptKeyboardDismissalTrigger.allCases {
            let plan = chatTranscriptKeyboardDismissalPlan(trigger: trigger)
            XCTAssertTrue(plan.dismissesKeyboard)
            XCTAssertTrue(plan.preservesDraft)
            XCTAssertFalse(plan.sendsMessage)
            XCTAssertFalse(plan.acknowledgesRead)
            XCTAssertFalse(plan.loadsHistoryPage)
            XCTAssertFalse(plan.rebuildsTimeline)
            XCTAssertFalse(plan.requestsScrollTarget)
        }
    }

    // WDT_CHAT_KEYBOARD_INSET_20261021_BEGIN
    func testChatKeyboardAvoidanceReleasesOnlyTheIdleKeyboardRegion() {
        XCTAssertEqual(chatIgnoredKeyboardEdges(composerIsEditing: false, searchIsFocused: false), .bottom)
        XCTAssertEqual(chatIgnoredKeyboardEdges(composerIsEditing: true, searchIsFocused: false), [])
        XCTAssertEqual(chatIgnoredKeyboardEdges(composerIsEditing: false, searchIsFocused: true), [])
        XCTAssertEqual(chatIgnoredKeyboardEdges(composerIsEditing: true, searchIsFocused: true), [])
    }

    func testChatKeyboardAvoidanceCanResumeAfterRepeatedEditing() {
        for _ in 0..<3 {
            XCTAssertEqual(chatIgnoredKeyboardEdges(composerIsEditing: true, searchIsFocused: false), [])
            XCTAssertEqual(chatIgnoredKeyboardEdges(composerIsEditing: false, searchIsFocused: false), .bottom)
        }
    }
    // WDT_CHAT_KEYBOARD_INSET_20261021_END

    func testChatMessageTopMeasurementStoreDoesNotPublishGeometryWrites() {
        let store = ChatMessageTopMeasurementStore()
        var viewInvalidationCount = 0
        let cancellable = store.objectWillChange.sink {
            viewInvalidationCount += 1
        }

        store.replace(with: ["message-1": 42, "message-2": -18], isEnabled: true)

        XCTAssertEqual(store.values, ["message-1": 42, "message-2": -18])
        XCTAssertEqual(viewInvalidationCount, 0)

        store.replace(with: ["message-3": 7], isEnabled: false)

        XCTAssertTrue(store.values.isEmpty)
        XCTAssertEqual(viewInvalidationCount, 0)

        store.replace(with: ["message-4": 11], isEnabled: true)
        store.removeAll()

        XCTAssertTrue(store.values.isEmpty)
        XCTAssertEqual(viewInvalidationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testTranscriptDragOneHundredSameDirectionFramesHaveOneSemanticActionAndNoPublications() {
        let control = ChatTranscriptScrollControl()
        var publications = 0
        var semanticActions = 0
        var historyLogActions = 0
        let observation = control.objectWillChange.sink { publications += 1 }
        let now = Date(timeIntervalSince1970: 100)

        for frame in 1...100 {
            // This is the same gate used before ChatView's state, read-gate
            // scans and history diagnostics, not a separate debounce fixture.
            if let transition = control.updateDrag(
                translation: CGSize(width: 0, height: CGFloat(frame * 8)),
                now: now.addingTimeInterval(Double(frame) / 10),
                suppressionInterval: 1.6
            ) {
                semanticActions += 1
                if transition.direction == .history { historyLogActions += 1 }
                XCTAssertTrue(transition.isStart)
            }
        }

        XCTAssertEqual(semanticActions, 1)
        XCTAssertEqual(historyLogActions, 1)
        XCTAssertEqual(control.generation, 1)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(30)))
        withExtendedLifetime(observation) {}
    }

    func testTranscriptLatestDragRepeatedFramesStayBoundedAndHistoryReversalSurvivesEnd() {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        var transitions = 0
        for frame in 1...100 {
            if control.updateDrag(
                translation: CGSize(width: 0, height: -CGFloat(frame * 8)),
                now: now, suppressionInterval: 1.6
            ) != nil { transitions += 1 }
        }
        XCTAssertEqual(transitions, 1)
        XCTAssertEqual(control.generation, 1)
        XCTAssertFalse(control.isSuppressed(now: now))
        XCTAssertEqual(control.updateDrag(
            translation: CGSize(width: 0, height: -790), now: now, suppressionInterval: 1.6
        )?.direction, .history)
        XCTAssertEqual(control.updateDrag(
            translation: CGSize(width: 0, height: -795), now: now, suppressionInterval: 1.6
        )?.direction, .latest)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(20)))
        XCTAssertEqual(control.finishDrag(now: now.addingTimeInterval(20), suppressionInterval: 1.6), .latest)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(21.5)))
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(21.6)))
    }

    func testTranscriptDragReversesBeforeCrossingItsOriginAndCancelsOldBottomWork() throws {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        let queuedBeforeDrag = control.nextGeneration()
        let first = try XCTUnwrap(control.updateDrag(
            translation: CGSize(width: 0, height: 100), now: now, suppressionInterval: 1.6
        ))
        XCTAssertTrue(first.isStart)
        XCTAssertEqual(first.direction, .history)
        XCTAssertNotEqual(control.generation, queuedBeforeDrag)
        let queuedBeforeReversal = control.generation

        let reverse = try XCTUnwrap(control.updateDrag(
            translation: CGSize(width: 0, height: 90), now: now.addingTimeInterval(1), suppressionInterval: 1.6
        ))
        XCTAssertFalse(reverse.isStart)
        XCTAssertEqual(reverse.direction, .latest)
        XCTAssertNotEqual(control.generation, queuedBeforeReversal)
        XCTAssertNil(control.updateDrag(
            translation: CGSize(width: 0, height: 80), now: now.addingTimeInterval(2), suppressionInterval: 1.6
        ))
        XCTAssertEqual(control.updateDrag(
            translation: CGSize(width: 0, height: 85), now: now.addingTimeInterval(3), suppressionInterval: 1.6
        )?.direction, .history)
    }

    func testTranscriptLongDragHoldsSuppressionThroughBottomGeometryAndAfterEnd() {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        _ = control.updateDrag(translation: CGSize(width: 0, height: 8), now: now, suppressionInterval: 1.6)
        control.clearSuppression() // The existing bottom-visibility callback.
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(30)))
        let duringDragGeneration = control.generation
        XCTAssertEqual(control.finishDrag(now: now.addingTimeInterval(30), suppressionInterval: 1.6), .history)
        XCTAssertNotEqual(control.generation, duringDragGeneration)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(31.5)))
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(31.6)))
        XCTAssertNil(control.finishDrag(now: now.addingTimeInterval(35), suppressionInterval: 1.6))
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(35)))
    }

    func testTranscriptHorizontalFinishAndScopeResetDoNotLeakGestureOrReuseGeneration() {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertNil(control.updateDrag(translation: CGSize(width: 80, height: 8), now: now, suppressionInterval: 1.6))
        XCTAssertNil(control.direction)
        XCTAssertEqual(control.generation, 0)
        _ = control.updateDrag(translation: CGSize(width: 0, height: 20), now: now, suppressionInterval: 1.6)
        XCTAssertNil(control.updateDrag(translation: CGSize(width: 100, height: 20), now: now, suppressionInterval: 1.6))
        XCTAssertEqual(control.finishDrag(now: now, suppressionInterval: 1.6), .history)
        let oldGeneration = control.generation
        control.reset()
        XCTAssertGreaterThan(control.generation, oldGeneration)
        XCTAssertNil(control.direction)
        XCTAssertFalse(control.isSuppressed(now: now))
        let nextDrag = control.updateDrag(translation: CGSize(width: 0, height: -8), now: now, suppressionInterval: 1.6)
        XCTAssertEqual(nextDrag, ChatTranscriptScrollControl.Transition(isStart: true, direction: .latest))
        XCTAssertNil(control.updateDrag(translation: CGSize(width: 0, height: -8), now: now, suppressionInterval: 1.6))
    }

    func testTranscriptSuppressionPreservesHistoryAnchorAndExplicitReturnToBottom() {
        let control = ChatTranscriptScrollControl()
        var arbiter = ConversationScrollArbiter()
        let now = Date(timeIntervalSince1970: 100)
        arbiter.beginNormalOpen(now: now, duration: 3)
        let generation = arbiter.generation
        func request(_ source: ConversationScrollRequestSource, userInitiated: Bool = false) -> ConversationScrollRequest {
            ConversationScrollRequest(source: source, targetID: "anchor", anchor: .top, userInitiated: userInitiated, generation: generation)
        }
        _ = control.updateDrag(translation: CGSize(width: 0, height: 8), now: now, suppressionInterval: 1.6)
        XCTAssertEqual(arbiter.evaluate(request(.userGesture, userInitiated: true), now: now), .allowAndEndWindow)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(20)))
        XCTAssertEqual(arbiter.evaluate(request(.historyPrependCompensation), now: now), .allow)
        XCTAssertEqual(arbiter.evaluate(request(.followBottom), now: now), .deny)
        let returnPlan = chatReturnToBottomActionPlan(bottomAnchorID: "bottom")
        control.suppress(now: now, interval: 1.6)
        XCTAssertEqual(arbiter.evaluate(request(returnPlan.source, userInitiated: true), now: now), .allowAndEndWindow)
        XCTAssertFalse(arbiter.isJumpMode)
        XCTAssertFalse(returnPlan.rebuildsTimeline)
        XCTAssertFalse(returnPlan.loadsHistoryPage)
    }

    func testTranscriptCancellationExpiresAndSameScopeHistoryDragStartsFresh() throws {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        _ = control.updateDrag(translation: CGSize(width: 0, height: 80), now: now, suppressionInterval: 1.6)
        let queuedBeforeCancel = control.generation
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(600)))

        // The GestureState reset callback uses the same finish as normal end.
        XCTAssertEqual(control.finishDrag(now: now.addingTimeInterval(600), suppressionInterval: 1.6), .history)
        XCTAssertNil(control.direction)
        XCTAssertNotEqual(control.generation, queuedBeforeCancel)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(601.5)))
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(602)))

        // No scope reset: the same translation must start a fresh drag, not be
        // suppressed as the previous gesture's same-direction/zero-delta frame.
        let resumed = try XCTUnwrap(control.updateDrag(
            translation: CGSize(width: 0, height: 80),
            now: now.addingTimeInterval(603), suppressionInterval: 1.6
        ))
        XCTAssertEqual(resumed, .init(isStart: true, direction: .history))
    }
}

// WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
extension DomainStoreTests {
    func testIncrementalTimelineAllFiveScopeFieldsAndPermissionsRebuildRows() {
        let model = ChatTimelineViewModel(), messages = [makeMessage(id: "same", seq: 1)], original: [String?] = ["account", "tenant", "app", "actor", "device"]
        applyTimeline(model, messages, incrementalContext(original)); var previous = model.rows[0]
        for index in original.indices { var scope = original; scope[index] = "changed-\(index)"; applyTimeline(model, messages, incrementalContext(scope)); XCTAssertNotEqual(model.rows[0], previous); previous = model.rows[0] }
        applyTimeline(model, messages, incrementalContext(original, group: true)); XCTAssertNotEqual(model.rows[0], previous); previous = model.rows[0]
        let permission = ChatTimelineContext(conversationID: "timeline", scope: original, sessionGeneration: 1, historyScope: "history", policy: nil, isGroup: true, isReadOnly: false, canManageGroup: true)
        applyTimeline(model, messages, permission); XCTAssertNotEqual(model.rows[0], previous)
    }
    func testIncrementalTimelineStableSnapshotDoesNotResolveRowsAgain() {
        let model = ChatTimelineViewModel(), context = incrementalContext(), messages = [makeMessage(id: "stable", seq: 1)]; applyTimeline(model, messages, context); let version = model.version
        let changed = model.update(messages: messages, context: context, unreadID: nil, unreadCount: 0) { _ in XCTFail("Unchanged snapshot resolved again"); return model.rows[0] }
        XCTAssertFalse(changed); XCTAssertEqual(model.version, version)
    }
    func testComposerFailureRestoresOriginDraftWithoutCrossingConversationOrScope() throws {
        let owner = ComposerState(), scope: [String?] = ["account", "tenant", "app", "actor", "device"]; owner.activate(scope: scope, conversationID: "A")
        owner.draft.input = "old"; owner.draft.replyQuote = "quote"; let sent = owner.draft, origin = try XCTUnwrap(owner.token), oldBinding = owner.binding(\.input, conversationID: "A", scope: scope)
        owner.draft.input = "中😀"; owner.draft.replyQuote = nil; owner.draft.selection = NSRange(location: 3, length: 0)
        owner.activate(scope: scope, conversationID: "B"); owner.draft.input = "B draft"; owner.restoreFailedSend(sent, origin: origin); XCTAssertEqual(owner.draft.input, "B draft")
        owner.activate(scope: scope, conversationID: "A"); XCTAssertEqual(owner.draft.input, "old\n中😀"); XCTAssertEqual(owner.draft.replyQuote, "quote"); XCTAssertEqual(owner.draft.selection, NSRange(location: 7, length: 0)) // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110
        owner.restoreFailedSend(sent, origin: origin); XCTAssertEqual(owner.draft.input, "old\n中😀")
        owner.activate(scope: ["other", "tenant", "app", "actor", "device"], conversationID: "A"); owner.restoreFailedSend(sent, origin: origin); oldBinding.wrappedValue = "stale"; XCTAssertEqual(owner.draft.input, "")
        owner.activate(scope: scope, conversationID: "A"); oldBinding.wrappedValue = "stale"; XCTAssertEqual(owner.draft.input, "")
    }
    func testScrollIntentKeepsAcceptedAnchorMotionAndResetsItsState() {
        let machine = ChatScrollIntentStateMachine(), intent = ScrollIntent(position: .historyAnchor, targetID: "anchor", anchor: UnitPoint(x: 0.5, y: 0.27), motion: .immediate); var executed: [ScrollIntent] = []
        machine.apply(intent) { executed.append($0); XCTAssertEqual(machine.state, .applying(intent)) }; XCTAssertEqual(executed, [intent]); XCTAssertEqual(machine.state, .applied(intent))
        machine.reset(); XCTAssertEqual(machine.state, .idle); XCTAssertEqual(ScrollIntent.position(for: .incomingFollowBottom), .followBottom); XCTAssertEqual(ScrollIntent.position(for: .viewportBottomRealignment), .preserveReadingPosition)
    }
}
// WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END

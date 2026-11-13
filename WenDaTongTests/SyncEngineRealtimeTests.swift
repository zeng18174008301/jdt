import XCTest
@testable import WenDaTong

extension SyncEngineTests {
    func testDefaultSyncEngineRealtimeSessionStateTracksConnectionActiveConversationAndResetClears() {
        let engine = DefaultSyncEngine()

        XCTAssertFalse(engine.isRealtimeConnectionActive())
        XCTAssertTrue(engine.shouldPollActiveConversation())
        XCTAssertNil(engine.currentActiveRealtimeConversationID())

        engine.updateRealtimeConnectionState(isConnected: true)
        engine.updateActiveRealtimeConversationID(" conversation-1 ")

        XCTAssertTrue(engine.isRealtimeConnectionActive())
        XCTAssertFalse(engine.shouldPollActiveConversation())
        XCTAssertEqual(engine.currentActiveRealtimeConversationID(), "conversation-1")

        engine.clearActiveRealtimeConversationID("conversation-2")

        XCTAssertEqual(engine.currentActiveRealtimeConversationID(), "conversation-1")

        engine.clearActiveRealtimeConversationID(" conversation-1 ")

        XCTAssertNil(engine.currentActiveRealtimeConversationID())

        engine.updateActiveRealtimeConversationID("   ")

        XCTAssertNil(engine.currentActiveRealtimeConversationID())

        engine.updateRealtimeConnectionState(isConnected: true)
        engine.updateActiveRealtimeConversationID("conversation-3")
        engine.reset()

        XCTAssertFalse(engine.isRealtimeConnectionActive())
        XCTAssertTrue(engine.shouldPollActiveConversation())
        XCTAssertNil(engine.currentActiveRealtimeConversationID())
    }

    func testDefaultSyncEngineKeepsReadAckSeparateFromReadReceipts() {
        let engine = DefaultSyncEngine()
        let readAckRequest = SyncEngineRequest(
            operation: .readAck,
            historyKey: "group|conversation-1",
            reason: "visible-read"
        )
        let receiptRequest = SyncEngineRequest(
            operation: .readReceipt,
            historyKey: "group|conversation-1",
            reason: "receipt-refresh"
        )

        XCTAssertTrue(engine.begin(readAckRequest).started)
        XCTAssertFalse(engine.begin(readAckRequest).started)
        XCTAssertTrue(engine.begin(receiptRequest).started)
        XCTAssertTrue(engine.isInFlight(readAckRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))
    }

    func testDefaultSyncEngineQueuesRealtimeRecoveryConversationsForUnifiedDrain() {
        let engine = DefaultSyncEngine()

        XCTAssertFalse(engine.enqueueRealtimeRecoveryConversation(nil))
        XCTAssertFalse(engine.enqueueRealtimeRecoveryConversation("   "))
        XCTAssertTrue(engine.enqueueRealtimeRecoveryConversation(" conversation-1 "))
        XCTAssertFalse(engine.enqueueRealtimeRecoveryConversation("conversation-1"))
        XCTAssertTrue(engine.enqueueRealtimeRecoveryConversation("conversation-2"))

        XCTAssertEqual(engine.drainRealtimeRecoveryConversations(), ["conversation-1", "conversation-2"])
        XCTAssertEqual(engine.drainRealtimeRecoveryConversations(), [])
        XCTAssertTrue(engine.enqueueRealtimeRecoveryConversation("conversation-1"))
    }

    func testDefaultSyncEngineResetClearsRealtimeRecoveryConversationQueue() {
        let engine = DefaultSyncEngine()

        XCTAssertTrue(engine.enqueueRealtimeRecoveryConversation("conversation-1"))
        engine.reset()

        XCTAssertEqual(engine.drainRealtimeRecoveryConversations(), [])
        XCTAssertTrue(engine.enqueueRealtimeRecoveryConversation("conversation-1"))
    }

    func testDefaultSyncEngineRealtimeRecoveryRefreshPlanThrottlesByRememberedRefreshTime() {
        let engine = DefaultSyncEngine()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            engine.realtimeRecoveryRefreshPlan(
                reason: "connect_ack",
                now: now,
                throttleInterval: 8
            ),
            .refresh(RealtimeRecoveryRefreshCommand(reason: "connect_ack"))
        )

        engine.rememberRealtimeRecoveryRefresh(at: now)

        XCTAssertEqual(
            engine.realtimeRecoveryRefreshPlan(
                reason: "reconnect",
                now: now.addingTimeInterval(7.9),
                throttleInterval: 8
            ),
            .flushOnly(
                RealtimeRecoveryRefreshCommand(reason: "reconnect"),
                reason: "realtime recovery refresh throttled"
            )
        )
        XCTAssertEqual(
            engine.realtimeRecoveryRefreshPlan(
                reason: "foreground",
                now: now.addingTimeInterval(8),
                throttleInterval: 8
            ),
            .refresh(RealtimeRecoveryRefreshCommand(reason: "foreground"))
        )
    }

    func testDefaultSyncEngineRealtimeRecoveryRefreshPlanSkipsInFlightAndResetClearsThrottle() {
        let engine = DefaultSyncEngine()
        let now = Date(timeIntervalSince1970: 2_000)
        let command = RealtimeRecoveryRefreshCommand(reason: "connect_ack")

        XCTAssertTrue(engine.beginRealtimeRecoveryRefresh(command).started)
        XCTAssertEqual(
            engine.realtimeRecoveryRefreshPlan(
                reason: "reconnect",
                now: now,
                throttleInterval: 8
            ),
            .flushOnly(
                RealtimeRecoveryRefreshCommand(reason: "reconnect"),
                reason: "realtime recovery refresh already in flight"
            )
        )

        engine.finishRealtimeRecoveryRefresh(command)
        engine.rememberRealtimeRecoveryRefresh(at: now)

        XCTAssertEqual(
            engine.realtimeRecoveryRefreshPlan(
                reason: "foreground",
                now: now.addingTimeInterval(1),
                throttleInterval: 8
            ),
            .flushOnly(
                RealtimeRecoveryRefreshCommand(reason: "foreground"),
                reason: "realtime recovery refresh throttled"
            )
        )

        engine.reset()

        XCTAssertEqual(
            engine.realtimeRecoveryRefreshPlan(
                reason: "foreground",
                now: now.addingTimeInterval(1),
                throttleInterval: 8
            ),
            .refresh(RealtimeRecoveryRefreshCommand(reason: "foreground"))
        )
    }

    func testDefaultSyncEngineRealtimeRecoveryTaskLifecycleClaimsFinishesCancelsAndResetClearsState() {
        let engine = DefaultSyncEngine()
        let refreshTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let flushTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        XCTAssertTrue(engine.claimRealtimeRecoveryTask(.refresh))
        XCTAssertTrue(engine.hasRealtimeRecoveryTask(.refresh))
        XCTAssertFalse(engine.claimRealtimeRecoveryTask(.refresh))

        engine.attachRealtimeRecoveryTask(.refresh, task: refreshTask)
        engine.finishRealtimeRecoveryTask(.refresh)
        refreshTask.cancel()

        XCTAssertFalse(engine.hasRealtimeRecoveryTask(.refresh))
        XCTAssertTrue(engine.claimRealtimeRecoveryTask(.conversationFlush))

        engine.attachRealtimeRecoveryTask(.conversationFlush, task: flushTask)
        engine.cancelRealtimeRecoveryTasks()

        XCTAssertFalse(engine.hasRealtimeRecoveryTask(.conversationFlush))
        XCTAssertTrue(engine.claimRealtimeRecoveryTask(.conversationFlush))

        let resetTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        engine.attachRealtimeRecoveryTask(.conversationFlush, task: resetTask)
        engine.reset()

        XCTAssertFalse(engine.hasRealtimeRecoveryTask(.conversationFlush))
        XCTAssertTrue(engine.claimRealtimeRecoveryTask(.refresh))

        engine.cancelRealtimeRecoveryTasks()
    }

    func testDefaultSyncEngineRealtimeReconnectNoticePlanThrottlesOnlyWhileActiveAndResetClearsState() {
        let engine = DefaultSyncEngine()
        let now = Date(timeIntervalSince1970: 3_000)

        XCTAssertEqual(engine.realtimeReconnectNoticePlan(now: now, throttleInterval: 30), .show)

        engine.rememberRealtimeReconnectNoticeShown(at: now)

        XCTAssertEqual(
            engine.realtimeReconnectNoticePlan(now: now.addingTimeInterval(29.9), throttleInterval: 30),
            .skip(reason: "realtime reconnect notice throttled")
        )
        XCTAssertEqual(engine.realtimeReconnectNoticePlan(now: now.addingTimeInterval(30), throttleInterval: 30), .show)

        engine.clearRealtimeReconnectNotice()

        XCTAssertEqual(engine.realtimeReconnectNoticePlan(now: now.addingTimeInterval(1), throttleInterval: 30), .show)

        engine.rememberRealtimeReconnectNoticeShown(at: now.addingTimeInterval(1))
        XCTAssertEqual(
            engine.realtimeReconnectNoticePlan(now: now.addingTimeInterval(2), throttleInterval: 30),
            .skip(reason: "realtime reconnect notice throttled")
        )

        engine.reset()

        XCTAssertEqual(engine.realtimeReconnectNoticePlan(now: now.addingTimeInterval(2), throttleInterval: 30), .show)
    }
}

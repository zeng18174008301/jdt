import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testVideoConnectionGateDoesNotMarkConnectedOnTrackOnly() {
        var gate = RTCVideoConnectionGate()
        XCTAssertFalse(gate.apply(.remoteAudioTrackReady))
        XCTAssertFalse(gate.didEmitConnected)
    }

    func testVideoSignalRuntimeRebindInvalidatesOldPollWithoutLosingCursorOrDedupe() {
        var state = RTCVideoSignalRuntimeState(rtcToken: "old")
        let oldGeneration = state.generation
        state.markProcessed("message-1")
        state.commitCursor("cursor-1")
        state.rebindToken("new")

        XCTAssertEqual(state.rtcToken, "new")
        XCTAssertFalse(state.isCurrent(generation: oldGeneration))
        XCTAssertEqual(state.cursor, "cursor-1")
        XCTAssertTrue(state.hasProcessed("message-1"))
    }

    @MainActor
    func testVideoIceRestartBatchDefersPollGenerationUntilAckAndDoesNotReplay() async throws {
        let kinds: [RemoteRTCSignalKind] = [
            .iceRestart,
            .mediaState,
            .answer,
            .candidate,
            .candidate,
            .candidate,
            .candidate,
            .candidate
        ]
        let items = kinds.enumerated().map { index, kind in
            RemoteRTCSignalItem(
                serverCursor: "\(index + 1)-0",
                messageID: "recovery-message-\(index + 1)",
                seq: index + 5,
                kind: kind
            )
        }
        var state = RTCVideoSignalRuntimeState(rtcToken: "old-token")
        let activeGeneration = state.generation
        var inBandRefresh = RTCVideoInBandCredentialRefreshState()
        var handled: [String] = []

        state.stageTokenRebind("refreshed-token")
        XCTAssertTrue(state.isCurrent(generation: activeGeneration))

        try await RTCVideoSignalBatchProcessor.process(
            items,
            state: &state,
            generation: activeGeneration
        ) { item in
            handled.append(item.messageID)
            if item.kind == .iceRestart {
                inBandRefresh.request()
            }
        }

        XCTAssertEqual(handled, items.map(\.messageID))
        XCTAssertTrue(items.allSatisfy { state.hasProcessed($0.messageID) })
        XCTAssertTrue(inBandRefresh.isPending)
        XCTAssertTrue(state.isCurrent(generation: activeGeneration))
        XCTAssertEqual(state.rtcToken, "refreshed-token")
        XCTAssertEqual(state.cursor, "", "cursor must not advance before ACK succeeds")

        inBandRefresh.requireAcknowledgement(of: "8-0")
        XCTAssertFalse(
            inBandRefresh.completeAfterAcknowledgement(
                acknowledgedCursor: state.cursor,
                didAcknowledgeAndCommit: false
            ),
            "an ACK failure must preserve the pending in-band refresh"
        )
        XCTAssertTrue(inBandRefresh.isPending)

        state.commitCursor("8-0")
        XCTAssertTrue(
            inBandRefresh.completeAfterAcknowledgement(
                acknowledgedCursor: state.cursor,
                didAcknowledgeAndCommit: true
            )
        )

        XCTAssertEqual(state.cursor, "8-0")
        XCTAssertTrue(state.isCurrent(generation: activeGeneration))
        XCTAssertFalse(inBandRefresh.isPending)

        var replayed: [String] = []
        try await RTCVideoSignalBatchProcessor.process(
            items,
            state: &state,
            generation: state.generation
        ) { item in
            replayed.append(item.messageID)
        }
        XCTAssertTrue(replayed.isEmpty)
    }

    func testVideoInBandCredentialRefreshRequiresThisIterationAckAndBlocksOutOfBandRefresh() {
        var refresh = RTCVideoInBandCredentialRefreshState()
        refresh.request()
        refresh.requireAcknowledgement(of: "")
        XCTAssertFalse(
            refresh.completeAfterAcknowledgement(
                acknowledgedCursor: "",
                didAcknowledgeAndCommit: true
            )
        )
        XCTAssertTrue(refresh.isPending)

        refresh.requireAcknowledgement(of: "cursor-1")
        XCTAssertFalse(
            refresh.completeAfterAcknowledgement(
                acknowledgedCursor: "cursor-1",
                didAcknowledgeAndCommit: false
            ),
            "an unchanged cursor must not be mistaken for an ACK from this iteration"
        )
        XCTAssertTrue(refresh.isPending)
        XCTAssertEqual(
            RTCVideoCredentialRefreshAction.resolve(
                inBandRequest: false,
                inBandRefreshPending: refresh.isPending
            ),
            .rejectOutOfBand
        )
        XCTAssertEqual(
            RTCVideoCredentialRefreshAction.resolve(
                inBandRequest: true,
                inBandRefreshPending: refresh.isPending
            ),
            .retryNegotiation
        )
    }

    func testVideoCredentialRefreshSnapshotRejectsClosedOrReplacementSession() {
        let snapshot = RTCVideoCredentialRefreshSnapshot(
            sessionEpoch: 7,
            callID: "call-old",
            roomID: "room-old",
            rtcToken: "token-old"
        )
        XCTAssertTrue(
            snapshot.matches(
                sessionEpoch: 7,
                callID: "call-old",
                roomID: "room-old",
                rtcToken: "token-old"
            )
        )
        XCTAssertFalse(
            snapshot.matches(
                sessionEpoch: 8,
                callID: "call-new",
                roomID: "room-new",
                rtcToken: "token-new"
            ),
            "a refresh response from a closed call must not mutate its replacement session"
        )
        XCTAssertFalse(
            snapshot.matches(
                sessionEpoch: 8,
                callID: "call-old",
                roomID: "room-old",
                rtcToken: "token-old"
            ),
            "session epoch must reject same-ID call reuse"
        )
    }

    @MainActor
    func testVideoSignalBatchMarksOnlySuccessfullyHandledItemsAndStopsAtFailure() async {
        enum ExpectedFailure: Error { case failedItem }
        let items = [
            RemoteRTCSignalItem(messageID: "message-1", kind: .mediaState),
            RemoteRTCSignalItem(messageID: "message-2", kind: .candidate),
            RemoteRTCSignalItem(messageID: "message-3", kind: .bye)
        ]
        var state = RTCVideoSignalRuntimeState(rtcToken: "token")
        let generation = state.generation
        var handled: [String] = []

        do {
            try await RTCVideoSignalBatchProcessor.process(
                items,
                state: &state,
                generation: generation
            ) { item in
                handled.append(item.messageID)
                if item.messageID == "message-2" {
                    throw ExpectedFailure.failedItem
                }
            }
            XCTFail("expected item handling failure")
        } catch is ExpectedFailure {
            XCTAssertEqual(handled, ["message-1", "message-2"])
            XCTAssertTrue(state.hasProcessed("message-1"))
            XCTAssertFalse(state.hasProcessed("message-2"))
            XCTAssertFalse(state.hasProcessed("message-3"))
            XCTAssertEqual(state.cursor, "", "cursor must remain uncommitted until ACK succeeds")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testVideoSignalOutboxKeepsStableEnvelopeAndFailsClosedAtCapacity() throws {
        let first = RemoteRTCSignalEnvelope(
            messageID: "message-1",
            seq: 7,
            kind: .candidate,
            data: ["candidate": .string("redacted-test-candidate")]
        )
        let second = RemoteRTCSignalEnvelope(messageID: "message-2", seq: 8, kind: .offer)
        var outbox = RTCVideoSignalOutbox(capacity: 1)

        try outbox.enqueue(first)
        try outbox.enqueue(first)
        XCTAssertEqual(outbox.pending, [first])
        XCTAssertThrowsError(try outbox.enqueue(second)) {
            XCTAssertEqual($0 as? RTCVideoSignalOutboxError, .capacityExceeded)
        }
        outbox.markDelivered(messageID: first.messageID)
        XCTAssertTrue(outbox.pending.isEmpty)

        try outbox.enqueue(first)
        outbox.reset()
        XCTAssertTrue(outbox.pending.isEmpty)
    }

    func testVideoMediaStatePayloadUsesOnlyServerWhitelistedKeys() {
        let noCamera = RTCVideoMediaStatePayload.make(
            cameraEnabled: false,
            mediaMode: "video"
        )
        XCTAssertEqual(
            Set(noCamera.keys),
            Set(["camera_enabled", "media_mode"])
        )
        XCTAssertEqual(noCamera["camera_enabled"], .bool(false))
        XCTAssertEqual(noCamera["media_mode"], .string("video"))
        XCTAssertNil(noCamera["camera_unavailable"])
        XCTAssertNil(noCamera["app_backgrounded"])

        let backgrounded = RTCVideoMediaStatePayload.make(
            cameraEnabled: false,
            microphoneEnabled: true,
            mediaMode: "video"
        )
        XCTAssertEqual(
            Set(backgrounded.keys),
            Set(["camera_enabled", "microphone_enabled", "media_mode"])
        )
        XCTAssertNil(backgrounded["app_backgrounded"])
    }

    func testVideoSignalOutboxSupersedesBestEffortStateWithoutReorderingSequence() throws {
        let firstMediaState = RemoteRTCSignalEnvelope(
            messageID: "media-state-1",
            seq: 1,
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(cameraEnabled: true, mediaMode: "video")
        )
        let secondMediaState = RemoteRTCSignalEnvelope(
            messageID: "media-state-2",
            seq: 2,
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(cameraEnabled: false, mediaMode: "video")
        )
        let answer = RemoteRTCSignalEnvelope(messageID: "answer-1", seq: 3, kind: .answer)
        let firstCandidate = RemoteRTCSignalEnvelope(messageID: "candidate-1", seq: 4, kind: .candidate)
        let secondCandidate = RemoteRTCSignalEnvelope(messageID: "candidate-2", seq: 5, kind: .candidate)
        var outbox = RTCVideoSignalOutbox(capacity: 8)

        try outbox.enqueue(firstMediaState)
        try outbox.enqueue(secondMediaState)
        XCTAssertEqual(
            outbox.pending,
            [secondMediaState],
            "only the latest unsent best-effort media state is useful"
        )

        try outbox.enqueue(answer)
        try outbox.enqueue(firstCandidate)
        try outbox.enqueue(secondCandidate)
        XCTAssertEqual(
            outbox.pending.map(\.messageID),
            ["answer-1", "candidate-1", "candidate-2"],
            "later SDP/ICE discards stale lower-sequence media state and preserves critical order"
        )
        XCTAssertEqual(outbox.pending.map(\.seq), [3, 4, 5])
    }

    func testVideoSignalOutboxKeepsExactCriticalEnvelopeForRetryableFailure() throws {
        let envelope = RemoteRTCSignalEnvelope(
            messageID: "stable-message-id",
            seq: 77,
            kind: .candidate,
            data: ["candidate": .string("redacted-test-candidate")],
            sentAt: "2026-07-26T00:00:00Z"
        )
        var outbox = RTCVideoSignalOutbox()

        try outbox.enqueue(envelope)
        let firstAttempt = try XCTUnwrap(outbox.pending.first)
        // A retryable HTTP/network failure deliberately does not call
        // markDelivered. The next flush must resend the exact same envelope.
        let retryAttempt = try XCTUnwrap(outbox.pending.first)

        XCTAssertEqual(retryAttempt, firstAttempt)
        XCTAssertEqual(retryAttempt.messageID, "stable-message-id")
        XCTAssertEqual(retryAttempt.seq, 77)
        XCTAssertEqual(retryAttempt.sentAt, "2026-07-26T00:00:00Z")
    }

    func testVideoSignalOutboxDiscardsBestEffortStateWhenCriticalSignalNeedsCapacity() throws {
        let mediaState = RemoteRTCSignalEnvelope(
            messageID: "media-state",
            seq: 1,
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(cameraEnabled: false, mediaMode: "video")
        )
        let answer = RemoteRTCSignalEnvelope(messageID: "answer", seq: 2, kind: .answer)
        var outbox = RTCVideoSignalOutbox(capacity: 1)

        try outbox.enqueue(mediaState)
        try outbox.enqueue(answer)

        XCTAssertEqual(outbox.pending, [answer])
    }

    func testVideoSignalFailurePolicyOnlyRecognizesExactAuthoritativeTerminalPairs() {
        XCTAssertTrue(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(
                    statusCode: 409,
                    code: "rtc-call-not-active",
                    message: "terminal"
                )
            )
        )
        XCTAssertTrue(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(
                    statusCode: 404,
                    code: "RTC_CALL_NOT_FOUND",
                    message: "terminal"
                )
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(statusCode: 409, code: "conflict", message: "retry")
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(statusCode: 404, code: "route_not_found", message: "retry")
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(statusCode: 503, code: "rtc_call_not_active", message: "retry")
            )
        )
    }

    func testVideoSignalFailurePolicyDropsOnlyInvalidBestEffortMediaState() {
        let invalidPayload = RTCVideoSignalHTTPError(
            statusCode: 422,
            code: "RTC-SIGNAL-PAYLOAD-INVALID",
            message: "redacted"
        )
        XCTAssertTrue(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .mediaState,
                after: invalidPayload
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .answer,
                after: invalidPayload
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .mediaState,
                after: RTCVideoSignalHTTPError(
                    statusCode: 503,
                    code: "rtc_signal_payload_invalid",
                    message: "retry"
                )
            ),
            "retryable failures must keep the original envelope"
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .mediaState,
                after: URLError(.networkConnectionLost)
            ),
            "network failures must keep the original envelope"
        )
    }

    func testVideoSignalLongPollTimeoutDoesNotDegradeConnectedMedia() {
        XCTAssertFalse(
            RTCVideoSignalPollingFailurePolicy.shouldEmitReconnecting(
                after: URLError(.timedOut),
                iceConnected: true
            )
        )
        XCTAssertTrue(
            RTCVideoSignalPollingFailurePolicy.shouldEmitReconnecting(
                after: URLError(.timedOut),
                iceConnected: false
            )
        )
        XCTAssertTrue(
            RTCVideoSignalPollingFailurePolicy.shouldEmitReconnecting(
                after: URLError(.networkConnectionLost),
                iceConnected: true
            )
        )
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func testVideoSignalPollingFailureBackoffUsesExponentialFloorWithJitter() {
        var state = RTCVideoSignalPollingBackoffState()

        let first = state.recordFailureAndDelayNanoseconds(stableKey: "call-a")
        let second = state.recordFailureAndDelayNanoseconds(stableKey: "call-a")

        XCTAssertGreaterThanOrEqual(first, 1_000_000_000)
        XCTAssertLessThan(first, 1_200_000_000)
        XCTAssertGreaterThanOrEqual(second, 2_000_000_000)
        XCTAssertLessThan(second, 2_400_000_000)

        state.reset()
        let resetFirst = state.recordFailureAndDelayNanoseconds(stableKey: "call-a")
        XCTAssertGreaterThanOrEqual(resetFirst, 1_000_000_000)
        XCTAssertLessThan(resetFirst, 1_200_000_000)
    }

    func testVideoSignalPollingQuickEmptyDelayOnlyForFastEmptyNoCursorProgress() {
        XCTAssertTrue(
            RTCVideoSignalPollingBackoffPolicy.shouldDelayQuickEmptyPage(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 50_000_000
            )
        )
        XCTAssertFalse(
            RTCVideoSignalPollingBackoffPolicy.shouldDelayQuickEmptyPage(
                itemCount: 1,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 50_000_000
            )
        )
        XCTAssertFalse(
            RTCVideoSignalPollingBackoffPolicy.shouldDelayQuickEmptyPage(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-2",
                elapsedNanoseconds: 50_000_000
            )
        )
        XCTAssertFalse(
            RTCVideoSignalPollingBackoffPolicy.shouldDelayQuickEmptyPage(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 1_000_000_000
            )
        )
    }

    // JHT_MOD_BEGIN RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改开始：固定 RTC 连接前空轮询短等待、连接后恢复常规节流
    func testRTCSignalPollingQuickEmptyUsesShortDelayBeforeConnected() {
        XCTAssertEqual(
            RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 50_000_000,
                isConnected: false
            ),
            150_000_000
        )
        XCTAssertEqual(
            RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 50_000_000,
                isConnected: true
            ),
            1_000_000_000
        )
        XCTAssertNil(
            RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 150_000_000,
                isConnected: false
            )
        )
    }
    // JHT_MOD_END RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改结束
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    func testVideoSignalLongPollTimeoutAlwaysExceedsServerWait() {
        let waitMS = RTCVideoSignalLongPollPolicy.normalizedWaitMS(25_000)
        let timeout = RTCVideoSignalLongPollPolicy.requestTimeout(waitMS: waitMS)

        XCTAssertEqual(waitMS, 25_000)
        XCTAssertEqual(timeout, 30)
        XCTAssertGreaterThan(timeout, TimeInterval(waitMS) / 1_000)
    }

    func testRemoteRTCCallDecodesTerminalReasonAndVersionFromSnakeAndCamelCase() throws {
        let snake = try JSONDecoder().decode(
            RemoteRTCCall.self,
            from: Data(#"{"id":"call-snake","status":"ended","end_reason":"caller_hangup","state_version":"12"}"#.utf8)
        )
        XCTAssertEqual(snake.endReason, "caller_hangup")
        XCTAssertEqual(snake.stateVersion, 12)

        let camel = try JSONDecoder().decode(
            RemoteRTCCall.self,
            from: Data(#"{"id":"call-camel","status":"ended","endReason":"peer_timeout","stateVersion":13}"#.utf8)
        )
        XCTAssertEqual(camel.endReason, "peer_timeout")
        XCTAssertEqual(camel.stateVersion, 13)
    }

    func testVideoCredentialSchedulePrefersServerRefreshAfter() {
        let now = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
        let delay = RTCVideoCredentialSchedule.delay(
            refreshAfter: "2026-07-25T12:08:00Z",
            expiresAt: "2026-07-25T12:20:00Z",
            now: now
        )
        XCTAssertEqual(delay, 480)
    }

    func testVideoICERestartPolicyOnlyLetsCallerCreateRestartOffer() {
        XCTAssertEqual(RTCVideoICERestartPolicy.action(isCaller: true), .restartAndOffer)
        XCTAssertEqual(RTCVideoICERestartPolicy.action(isCaller: false), .requestCallerRestart)
    }

    func testVideoCallDurationFormatter() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(VideoCallDurationFormatter.text(connectedAt: connectedAt, now: connectedAt.addingTimeInterval(65)), "01:05")
        XCTAssertEqual(VideoCallDurationFormatter.text(connectedAt: connectedAt, now: connectedAt.addingTimeInterval(3_661)), "01:01:01")
    }
}

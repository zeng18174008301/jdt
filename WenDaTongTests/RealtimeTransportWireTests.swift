import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import Network
import XCTest
@testable import WenDaTong

extension RealtimeTransportTests {
    func testRealtimeClientUsesInjectedWireCodecForIncomingEnvelope() throws {
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string("codec-realtime-envelope")
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let wireCodec = RecordingRealtimeWireCodec()
        let client = RealtimeClient(
            transport: transport,
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
            wireCodec: wireCodec,
            requestIDProvider: { _ in "req-1" },
            networkMonitorFactory: nil
        )
        let url = try XCTUnwrap(URL(string: "ws://example.test/im/ws"))
        let connected = expectation(description: "connect ack handled")

        client.onConnected = {
            connected.fulfill()
        }
        client.start(url: url, token: "token-1")

        wait(for: [connected], timeout: 1)
        XCTAssertEqual(wireCodec.decodedTypeNames(), ["RealtimeEnvelope"])
        XCTAssertEqual(wireCodec.decodedInputTexts(), ["codec-realtime-envelope"])

        client.disconnect(shouldReconnect: false)
        XCTAssertEqual(socket.cancelCount(), 1)
    }

	func testRealtimeClientUsesSingleGlobalOwnerCanonicalDedupeAndNoPseudoCursorWire() async throws {
		let firstAck = #"{"type":"connect_ack","request_id":"ack-1","payload":{}}"#
		let canonicalMessage = #"{"type":"message","request_id":"event-1","payload":{"message":{"message_id":"message-42","channel_id":"group-1","content":"hello"}}}"#
		let firstSocket = FakeRealtimeWebSocketTask(
			receiveMessages: [.string(firstAck), .string(canonicalMessage), .string(canonicalMessage)]
		)
		let secondSocket = FakeRealtimeWebSocketTask(
			receiveMessages: [.string(#"{"type":"connect_ack","request_id":"ack-2","payload":{}}"#)]
		)
		let continuity = IMRuntimeWebSocketContinuity()
		let firstTransport = FakeRealtimeWebSocketTransport(socket: firstSocket)
		let secondTransport = FakeRealtimeWebSocketTransport(socket: secondSocket)
		let firstClient = RealtimeClient(
			transport: firstTransport,
			quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
			requestIDProvider: { _ in "ack-1" },
			networkMonitorFactory: nil,
			continuity: continuity
		)
		let secondClient = RealtimeClient(
			transport: secondTransport,
			quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
			requestIDProvider: { _ in "ack-2" },
			networkMonitorFactory: nil,
			continuity: continuity
		)
		let firstDelivery = expectation(description: "canonical message delivered exactly once")
		var deliveredMessageIDs: [String] = []
		firstClient.onEnvelope = { envelope in
			deliveredMessageIDs.append(envelope.payload["message"]?.objectValue?["message_id"]?.stringValue ?? "")
			firstDelivery.fulfill()
		}
		let primaryURL = try XCTUnwrap(URL(string: "wss://ws-primary.example.com/im/ws"))
		let backupURL = try XCTUnwrap(URL(string: "wss://ws-backup.example.net/im/ws"))

		firstClient.start(url: primaryURL, token: "token-1")
		secondClient.start(url: backupURL, token: "token-2")
		await fulfillment(of: [firstDelivery], timeout: 1)
		try await Task.sleep(nanoseconds: 20_000_000)
		firstSocket.enqueue(.string(firstAck))
		firstSocket.enqueue(.string(canonicalMessage))
		firstClient.start(url: backupURL, token: "token-rotated")
		for _ in 0..<50 where firstSocket.resumeCount() < 2 {
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		try await Task.sleep(nanoseconds: 20_000_000)

		XCTAssertEqual(deliveredMessageIDs, ["message-42"])
		XCTAssertEqual(firstSocket.resumeCount(), 2)
		XCTAssertEqual(secondSocket.resumeCount(), 0)
		XCTAssertTrue(secondTransport.requestedURLs().isEmpty)
		let connectPayloads = try firstSocket.sentStrings().compactMap { packet -> [String: Any]? in
			guard let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any],
			      object["type"] as? String == "connect" else { return nil }
			return object["payload"] as? [String: Any]
		}
		XCTAssertEqual(connectPayloads.count, 2)
		XCTAssertTrue(connectPayloads.allSatisfy { Set($0.keys) == ["token"] })

		firstClient.disconnect(shouldReconnect: false)
		secondClient.start(url: backupURL, token: "token-2")
		for _ in 0..<50 where secondSocket.resumeCount() == 0 {
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTAssertEqual(secondSocket.resumeCount(), 1)
		secondClient.disconnect(shouldReconnect: false)
	}

    func testRTCExactReplayAcrossMessagePushAndSendAckCountsUnreadOnce() async throws {
        let message = rtcWireMessage()
        let result = try await ingestRTCWireFrames([
            rtcWireEnvelope(message, type: "message"),
            rtcWireEnvelope(message, type: "message_push", nested: false),
            rtcWireEnvelope(message, type: "send_ack")
        ])

        XCTAssertEqual(result.deliveredTypes, ["message", "message_push", "send_ack"])
        XCTAssertEqual(result.conversation.messages.map(\.id), ["rtc-message-1"])
        XCTAssertEqual(result.conversation.unread, 1)
        XCTAssertEqual(result.conversation.messageCoveredThroughSeq, 1)
        XCTAssertFalse(result.conversation.messageCoverageRequiresRecovery)
        XCTAssertEqual(result.readableSequence, 1)
    }

    func testRTCWireConflictsReachAuthorityMergeAndPreserveOriginalAndAckBoundary() async throws {
        let original = rtcWireMessage()
        var payloadConflict = original
        var changedPayload = try XCTUnwrap(original["payload"] as? [String: Any])
        changedPayload["ended_at"] = "2026-08-23T10:09:42Z"
        payloadConflict["payload"] = changedPayload
        var sequenceConflict = original
        sequenceConflict["channel_seq"] = 2
        var callIDConflict = original
        changedPayload = try XCTUnwrap(original["payload"] as? [String: Any])
        changedPayload["call_id"] = "different-call"
        callIDConflict["payload"] = changedPayload
        var malformed = original
        malformed["payload"] = ["call_id": "rtc-call-1", "schema_version": "broken"]
        var malformedType = original
        malformedType["content_type"] = "text"
        malformedType["payload"] = ["text": "invalid replacement"]
        var duplicateCall = original
        duplicateCall["message_id"] = "different-message"
        duplicateCall["channel_seq"] = 2
        var sequenceIdentityConflict = callIDConflict
        sequenceIdentityConflict["message_id"] = "different-message"

        let conflicts: [(String, [String: Any], Int64)] = [
            ("payload", payloadConflict, 0),
            ("sequence", sequenceConflict, 1),
            ("call ID", callIDConflict, 0),
            ("malformed", malformed, 0),
            ("typed to ordinary replacement", malformedType, 0),
            ("same call, different message ID", duplicateCall, 1),
            ("same sequence, different call and message IDs", sequenceIdentityConflict, 0)
        ]
        // Exercise both one ingest batch and a replay after the first message was
        // already merged. The production RealtimeClient callback installed by
        // AppState is used; no decoded-message or Store-only injection occurs.
        for (name, conflict, expectedBoundary) in conflicts {
            for flushEachFrame in [false, true] {
                let result = try await ingestRTCWireFrames([
                    rtcWireEnvelope(original, type: "message"),
                    rtcWireEnvelope(conflict, type: "message_push"),
                    rtcWireEnvelope(ordinaryWireMessage(id: "after-gap", sequence: 3), type: "send_ack")
                ], flushEachFrame: flushEachFrame)
                let label = "\(name), flushEachFrame=\(flushEachFrame)"
                XCTAssertEqual(result.deliveredTypes.count, 3, label)
                let record = try XCTUnwrap(result.conversation.messages.first(where: { $0.id == "rtc-message-1" })?.rtcCallRecord)
                XCTAssertEqual(record.callID, "rtc-call-1", label)
                XCTAssertEqual(record.endedAt, ISO8601DateFormatter().date(from: "2026-08-23T10:08:42Z"), label)
                XCTAssertEqual(result.conversation.messages.map(\.id), ["rtc-message-1", "after-gap"], label)
                XCTAssertEqual(result.conversation.unread, 2, label)
                XCTAssertTrue(result.conversation.messageCoverageRequiresRecovery, label)
                XCTAssertEqual(result.conversation.messageCoveredThroughSeq, expectedBoundary, label)
                // This is the existing Store boundary consumed by read ACKs;
                // later accepted messages must not bridge an RTC conflict.
                XCTAssertEqual(result.readableSequence, expectedBoundary, label)
                XCTAssertEqual(result.recoveryTarget?.afterSeq, expectedBoundary, label)
                XCTAssertEqual(result.recoveryTarget?.throughSeq, 3, label)
            }
        }
    }

    func testRTCNestedContentTypeAndMalformedReplayBypassContinuity() async throws {
        var original = rtcWireMessage()
        original.removeValue(forKey: "content_type")
        var payload = try XCTUnwrap(original["payload"] as? [String: Any])
        payload["content_type"] = " RTC_CALL_RECORD "
        original["payload"] = payload
        var malformed = original
        payload["schema_version"] = -1
        malformed["payload"] = payload
        let result = try await ingestRTCWireFrames([
            rtcWireEnvelope(original, type: "message", nested: false),
            rtcWireEnvelope(malformed, type: "send_ack", nested: false)
        ])
        XCTAssertEqual(result.deliveredTypes, ["message", "send_ack"])
        XCTAssertEqual(result.conversation.messages.count, 1)
        XCTAssertEqual(result.conversation.messages.first?.rtcCallRecord?.callID, "rtc-call-1")
        XCTAssertEqual(result.conversation.unread, 1)
        XCTAssertTrue(result.conversation.messageCoverageRequiresRecovery)
        XCTAssertEqual(result.readableSequence, 0)
    }

    func testOrdinaryWireMessagesRetainMessageIDDedupeAcrossEnvelopeTypes() async throws {
        let original = ordinaryWireMessage(id: "text-1", sequence: 1)
        var changed = ordinaryWireMessage(id: "text-1", sequence: 2)
        changed["payload"] = ["text": "replacement"]
        let result = try await ingestRTCWireFrames([
            rtcWireEnvelope(original, type: "message"),
            rtcWireEnvelope(original, type: "message_push", nested: false),
            rtcWireEnvelope(changed, type: "send_ack")
        ])
        XCTAssertEqual(result.deliveredTypes, ["message"])
        XCTAssertEqual(result.conversation.messages.map(\.id), ["text-1"])
        XCTAssertEqual(result.conversation.messages.first?.text, "ordinary")
        XCTAssertEqual(result.conversation.unread, 1)
        XCTAssertEqual(result.readableSequence, 1)
    }

    private func rtcWireMessage() -> [String: Any] {
        [
            "message_id": "rtc-message-1", "channel_id": "caller-1:callee-1",
            "channel_type": "direct", "channel_seq": 1, "from_uid": "caller-1",
            "content_type": "rtc_call_record", "created_at": "2026-08-23T10:08:42Z",
            "payload": [
                "schema_version": 1, "call_id": "rtc-call-1", "call_type": "audio",
                "caller_uid": "caller-1", "callee_uid": "callee-1",
                "final_outcome": "no_answer", "started_at": "2026-08-23T10:00:00Z",
                "ended_at": "2026-08-23T10:08:42Z", "duration_seconds": 0,
                "reason_code": "no_answer", "text": "通话记录", "fallback_text": "通话记录"
            ]
        ]
    }

    private func ordinaryWireMessage(id: String, sequence: Int) -> [String: Any] {
        [
            "message_id": id, "channel_id": "caller-1:callee-1", "channel_type": "direct",
            "channel_seq": sequence, "from_uid": "caller-1", "content_type": "text",
            "created_at": "2026-08-23T10:10:00Z", "payload": ["text": "ordinary"]
        ]
    }

    private func rtcWireEnvelope(_ message: [String: Any], type: String, nested: Bool = true) throws -> String {
        let payload: [String: Any] = nested ? ["message": message] : message
        let object: [String: Any] = ["type": type, "payload": payload]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func ingestRTCWireFrames(
        _ frames: [String],
        flushEachFrame: Bool = false
    ) async throws -> (
        conversation: ConversationMessageSnapshot,
        deliveredTypes: [String],
        readableSequence: Int64,
        recoveryTarget: ConversationStore.MessageSequenceRecoveryTarget?
    ) {
        let socket = FakeRealtimeWebSocketTask(receiveMessages:
            [.string(#"{"type":"connect_ack","request_id":"rtc-ack","payload":{}}"#)]
                + frames.map { .string($0) }
                + [.string(#"{"type":"test_barrier","payload":{}}"#)]
        )
        let client = RealtimeClient(
            transport: FakeRealtimeWebSocketTransport(socket: socket),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false), // WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112
            requestIDProvider: { _ in "rtc-ack" },
            networkMonitorFactory: nil,
            continuity: IMRuntimeWebSocketContinuity()
        )
        let context = IMAPIContext(
            platformToken: nil, accountID: "rtc-wire-test", tenantID: "rtc-wire-\(UUID().uuidString)",
            imUID: "callee-1", imToken: "unit-test-token", platformAuthSession: nil,
            tenantAuthSession: nil, appID: IMAPIContext.canonicalIOSAppID, deviceID: "rtc-wire-test"
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            httpTransport: RTCWireOfflineHTTPTransport()
        )
        let state = AppState(
            api: api, realtimeClient: client, voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messageStore: RTCWireEmptyMessageStore(),
            apiContextOverride: context
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let downstream = try XCTUnwrap(client.onEnvelope)
        let drained = expectation(description: "raw RTC envelopes reached AppState")
        var delivered: [String] = []
        client.onConnected = nil
        client.onEnvelope = { envelope in
            if envelope.type == "test_barrier" {
                state.flushPendingRealtimeMessagesForTesting()
                drained.fulfill()
                return
            }
            delivered.append(envelope.type)
            downstream(envelope)
            if flushEachFrame { state.flushPendingRealtimeMessagesForTesting() }
        }
        defer {
            state.setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            client.disconnect(shouldReconnect: false)
            client.onEnvelope = nil
        }
        client.start(url: try XCTUnwrap(URL(string: "wss://example.test/im/ws")), token: "unit-test-token")
        await fulfillment(of: [drained], timeout: 2)
        let conversation = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first(where: { $0.id == "caller-1:callee-1" }))
        return (
            conversation, delivered,
            state.conversationStore.latestReadableSequence(in: conversation),
            state.conversationStore.messageSequenceRecoveryTarget(for: conversation)
        )
    }

    func testRealtimeClientExpandsBatchFramesInOrder() async throws {
        let batch = """
        {"type":"batch","request_id":"batch-1","payload":{"frames":[{"type":"connect_ack","request_id":"ack-1","payload":{}},{"type":"message_push","request_id":"msg-1","payload":{"channel_id":"g1","channel_type":"group"}},{"payload":{"ignored":true}},{"type":"subscribe_ack","request_id":"sub-1","payload":{"channel_id":"g1","channel_type":"group"}}]}}
        """
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string(batch)
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            quicTransport: FakeRealtimeQUICTransport(result: .success(FakeRealtimeQUICConnection())),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            requestIDProvider: { _ in "ack-1" },
            networkMonitorFactory: nil
        )
        let connected = expectation(description: "connect ack inside batch handled")
        let message = expectation(description: "message frame inside batch forwarded")
        var receivedTypes: [String] = []

        client.onConnected = {
            connected.fulfill()
        }
        client.onEnvelope = { envelope in
            receivedTypes.append(envelope.type)
            if envelope.type == "message_push" {
                XCTAssertEqual(envelope.requestID, "msg-1")
                XCTAssertEqual(envelope.payload["channel_id"]?.stringValue, "g1")
                message.fulfill()
            }
        }
        client.start(url: try XCTUnwrap(URL(string: "ws://example.test/im/ws")), token: "token-1")

        await fulfillment(of: [connected, message], timeout: 1)
        XCTAssertEqual(receivedTypes, ["message_push"])

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeClientIterativelyExpandsNestedBatchAndHandlesControlFrames() async throws {
        let batch = """
        {"type":"batch","request_id":"outer-batch","payload":{"frames":[{"type":"pong","request_id":"pong-1","payload":{}},{"type":"batch","request_id":"inner-batch","payload":{"frames":[{"type":"connect_ack","request_id":"ack-1","payload":{}},{"type":"message_push","request_id":"msg-1","payload":{"channel_id":"g1","channel_type":"group"}},{"type":"subscribe_ack","request_id":"sub-1","payload":{"channel_id":"g1","channel_type":"group"}}]}}]}}
        """
        let socket = FakeRealtimeWebSocketTask(receiveMessages: [
            .string(batch)
        ])
        let transport = FakeRealtimeWebSocketTransport(socket: socket)
        let client = RealtimeClient(
            transport: transport,
            quicTransport: FakeRealtimeQUICTransport(result: .success(FakeRealtimeQUICConnection())),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: false),
            requestIDProvider: { _ in "ack-1" },
            networkMonitorFactory: nil
        )
        let stateChanged = expectation(description: "pong inside batch marks connection alive")
        let connected = expectation(description: "nested connect ack handled")
        let message = expectation(description: "nested business frame forwarded")
        var receivedTypes: [String] = []

        client.onConnectionStateChanged = { connected in
            if connected {
                stateChanged.fulfill()
            }
        }
        client.onConnected = {
            connected.fulfill()
        }
        client.onEnvelope = { envelope in
            receivedTypes.append(envelope.type)
            if envelope.type == "message_push" {
                XCTAssertEqual(envelope.requestID, "msg-1")
                XCTAssertEqual(envelope.payload["channel_id"]?.stringValue, "g1")
                message.fulfill()
            }
        }
        client.start(url: try XCTUnwrap(URL(string: "ws://example.test/im/ws")), token: "token-1")

        await fulfillment(of: [stateChanged, connected, message], timeout: 1)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(receivedTypes, ["message_push"])

        client.disconnect(shouldReconnect: false)
    }

    func testRealtimeBatchExpanderCapsMaliciousDepthWithoutRecursion() {
        var nested: JSONValue = .object([
            "type": .string("message_push"),
            "request_id": .string("deep-message"),
            "payload": .object(["message_id": .string("deep-1")])
        ])
        for index in 0..<(RealtimeBatchExpander.maximumDepth + 4) {
            nested = .object([
                "type": .string("batch"),
                "request_id": .string("nested-\(index)"),
                "payload": .object(["frames": .array([nested])])
            ])
        }
        let root = RealtimeEnvelope(
            type: "batch",
            requestID: "root",
            payload: ["frames": .array([nested])]
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = RealtimeBatchExpander.expand(root)
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertGreaterThan(result.droppedForDepth, 0)
        XCTAssertLessThanOrEqual(
            result.visitedElements,
            RealtimeBatchExpander.maximumElements
        )
        XCTAssertLessThan(elapsed, 1, "malicious nesting must remain main-thread bounded")
    }

    func testRealtimeBatchWireLimitBoundsDecodeInput() {
        XCTAssertTrue(
            RealtimeBatchExpander.acceptsWirePayload(
                byteCount: RealtimeBatchExpander.maximumWireBytes
            )
        )
        XCTAssertFalse(
            RealtimeBatchExpander.acceptsWirePayload(
                byteCount: RealtimeBatchExpander.maximumWireBytes + 1
            )
        )
    }

    func testRealtimeBatchExpanderCapsWideBatchAndPreservesAcceptedOrder() {
        let inputCount = RealtimeBatchExpander.maximumElements + 88
        let frames = (0..<inputCount).map { index in
            JSONValue.object([
                "type": .string("message_push"),
                "request_id": .string("msg-\(index)"),
                "payload": .object(["message_id": .string("m-\(index)")])
            ])
        }
        let result = RealtimeBatchExpander.expand(
            RealtimeEnvelope(
                type: "batch",
                requestID: "wide",
                payload: ["frames": .array(frames)]
            )
        )

        XCTAssertEqual(result.visitedElements, RealtimeBatchExpander.maximumElements)
        XCTAssertEqual(result.frames.count, RealtimeBatchExpander.maximumFrames)
        XCTAssertEqual(result.frames.first?.requestID, "msg-0")
        XCTAssertEqual(
            result.frames.last?.requestID,
            "msg-\(RealtimeBatchExpander.maximumFrames - 1)"
        )
        XCTAssertEqual(
            result.droppedForLimit,
            inputCount - RealtimeBatchExpander.maximumFrames
        )
    }

    func testRealtimeBatchExpanderIsolatesMalformedElementsAndKeepsDuplicatesInWireOrder() {
        let message: [String: JSONValue] = [
            "type": .string("message_push"),
            "request_id": .string("duplicate"),
            "payload": .object(["message_id": .string("m-1")])
        ]
        let result = RealtimeBatchExpander.expand(
            RealtimeEnvelope(
                type: "batch",
                requestID: "mixed",
                payload: [
                    "frames": .array([
                        .int(7),
                        .object(["payload": .object([:])]),
                        .object(message),
                        .object([
                            "type": .string("batch"),
                            "payload": .object(["wrong": .array([])])
                        ]),
                        .object(message)
                    ])
                ]
            )
        )

        XCTAssertEqual(result.frames.map(\.requestID), ["duplicate", "duplicate"])
        XCTAssertEqual(result.malformedElements, 3)
        XCTAssertEqual(result.droppedForDepth, 0)
        XCTAssertEqual(result.droppedForLimit, 0)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

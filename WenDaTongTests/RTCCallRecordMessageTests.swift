@testable import IM4Features
import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
@testable import WenDaTong
import CryptoKit // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112

final class RTCCallRecordMessageTests: XCTestCase {
    func testSevenOutcomesProjectExactViewerCopy() throws {
        let expected: [(RTCCallRecordOutcome, String, String)] = [
            (.completed, "通话时长 08:42", "通话时长 08:42"),
            (.callerCanceled, "已取消", "对方已取消"),
            (.calleeRejected, "对方已拒绝", "已拒绝"),
            (.noAnswer, "无人接听", "未接来电"),
            (.busy, "对方忙线", "忙线未接来电"),
            (.setupFailed, "连接失败", "对方连接失败"),
            (.interrupted, "通话中断 · 08:42", "通话中断 · 08:42")
        ]

        for (outcome, callerText, calleeText) in expected {
            let record = try XCTUnwrap(parse(outcome: outcome))
            XCTAssertEqual(record.presentation(viewerIsCaller: true).statusText, callerText)
            XCTAssertEqual(record.presentation(viewerIsCaller: false).statusText, calleeText)
        }
    }

    func testCallTypeControlsTitleAndIconWithoutUsingFallbackText() throws {
        var payload = payload(outcome: .completed, callType: .video)
        payload["text"] = .string("错误通话旧端文案")
        payload["fallback_text"] = .string("错误通话备用文案")
        let record = try XCTUnwrap(parse(payload: payload))
        let presentation = record.presentation(viewerIsCaller: false)
        XCTAssertEqual(presentation.title, "视频通话")
        XCTAssertEqual(presentation.systemImageName, "video.fill")
        XCTAssertEqual(presentation.statusText, "通话时长 08:42")
        XCTAssertFalse(presentation.conversationPreview.contains("错误"))
    }

    func testDurationUsesCrossClientHourMinuteSecondContract() throws {
        var longCall = payload(outcome: .completed)
        longCall["duration_seconds"] = .int(3_661)
        let record = try XCTUnwrap(parse(payload: longCall))
        XCTAssertEqual(record.presentation(viewerIsCaller: true).statusText, "通话时长 01:01:01")
    }

    func testDirectionAccessibilityAndRedialConfirmationPreservePeerAndType() throws {
        let record = try XCTUnwrap(parse(outcome: .noAnswer, callType: .video))
        let incoming = record.presentation(viewerIsCaller: false)
        XCTAssertEqual(incoming.directionLabel, "呼入")
        XCTAssertEqual(
            incoming.accessibilityLabel(
                peerName: "孟瑶",
                viewerIsCaller: false,
                outcome: record.finalOutcome
            ),
            "未接视频来电，呼入，孟瑶，\(incoming.dialedAtText)，再次呼叫需确认"
        )

        let confirmation = RTCCallRecordRedialConfirmation(
            record: record,
            viewerIsCaller: false,
            peerName: "孟瑶"
        )
        XCTAssertEqual(confirmation.title, "再次拨打视频通话？")
        XCTAssertEqual(confirmation.actionTitle, "拨打视频通话")
        XCTAssertEqual(confirmation.message, "将向孟瑶发起一通新的视频通话。取消不会请求权限或创建呼叫。")
    }

    func testAnsweredElsewhereAndMalformedPayloadsFailClosedToSanitizedFallback() {
        var answeredElsewhere = payload(outcome: .completed)
        answeredElsewhere["final_outcome"] = .string("answered_elsewhere")
        XCTAssertNil(parse(payload: answeredElsewhere))

        for mutation in ["schema_version", "call_id", "caller_uid", "callee_uid", "started_at", "ended_at", "duration_seconds", "reason_code", "text", "fallback_text"] {
            var malformed = payload(outcome: .completed)
            malformed.removeValue(forKey: mutation)
            XCTAssertNil(parse(payload: malformed), mutation)
        }

        var unsafe = payload(outcome: .completed)
        unsafe["reason_code"] = .string("unsafe reason")
        unsafe["fallback_text"] = .string("通话失败 rtc token redacted fd00::1")
        unsafe["text"] = .string("通话失败 gateway.internal")
        XCTAssertNil(parse(payload: unsafe))
        XCTAssertEqual(RTCCallRecordPayload.safeFallbackText(payload: unsafe), "[通话记录]")
        XCTAssertEqual(RTCCallRecordPayload.safeFallbackText(payload: [:]), "[通话记录]")

        for sensitive in [
            "通话 device id 123",
            "通话 push-token redacted",
            "通话 Bearer redacted",
            "通话 fe80::1",
            "通话失败 TURN server turn.example.com",
            "通话失败 ICE server ice.example.com",
            "通话失败 license=abc",
            "通话失败 api_key=abc",
            "通话失败 房间令牌 123456"
        ] {
            var payload = payload(outcome: .completed)
            payload["fallback_text"] = .string(sensitive)
            payload["text"] = .string(sensitive)
            XCTAssertNil(parse(payload: payload), sensitive)
            XCTAssertEqual(RTCCallRecordPayload.safeFallbackText(payload: payload), "[通话记录]", sensitive)
        }
    }

    func testConditionalFieldsAndTimelineAreStrict() {
        var completedWithoutMedia = payload(outcome: .completed)
        completedWithoutMedia.removeValue(forKey: "media_connected_at")
        XCTAssertNil(parse(payload: completedWithoutMedia))

        var noAnswerWithMedia = payload(outcome: .noAnswer)
        noAnswerWithMedia["media_connected_at"] = .string("2026-08-23T10:00:04Z")
        XCTAssertNil(parse(payload: noAnswerWithMedia))

        var rejectedByCaller = payload(outcome: .calleeRejected)
        rejectedByCaller["end_actor_uid"] = .string("caller-1")
        XCTAssertNil(parse(payload: rejectedByCaller))

        var timeOutsideBounds = payload(outcome: .interrupted)
        timeOutsideBounds["answered_at"] = .string("2026-08-23T09:59:59Z")
        XCTAssertNil(parse(payload: timeOutsideBounds))

        var invalidMediaMode = payload(outcome: .completed)
        invalidMediaMode["final_media_mode"] = .string("screen")
        XCTAssertNil(parse(payload: invalidMediaMode))
    }

    func testParserRequiresDirectAuthorityAndCallerAsEnvelopeSender() {
        let valid = payload(outcome: .noAnswer)
        XCTAssertNil(parse(payload: valid, contentType: "text"))
        XCTAssertNil(parse(payload: valid, channelType: "group"))
        XCTAssertNil(parse(payload: valid, fromUID: "callee-1"))
        XCTAssertNotNil(parse(payload: valid))
    }

    func testCachedMessageRoundTripRetainsTypedProjectionAndLegacyDecodeAllowsMissingField() throws {
        let record = try XCTUnwrap(parse(outcome: .interrupted, callType: .video))
        var message = makeMessage(id: "message-1", sequence: 8, record: record)
        message.text = record.presentation(viewerIsCaller: false).conversationPreview
        let encoded = try JSONEncoder().encode(CachedMessage(message: message))
        let decoded = try JSONDecoder().decode(CachedMessage.self, from: encoded)
        XCTAssertEqual(decoded.model.rtcCallRecord, record)
        XCTAssertEqual(decoded.model.contentType, "rtc_call_record")

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "rtcCallRecord")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(try JSONDecoder().decode(CachedMessage.self, from: legacyData).model.rtcCallRecord)
    }

    func testFourDistinctCrossDayTimesKeepDialMessageAndDurationSemantics() throws {
        var wire = payload(outcome: .completed, callType: .video)
        wire["started_at"] = .string("2026-08-23T23:59:00Z")
        wire["answered_at"] = .string("2026-08-23T23:59:20Z")
        wire["media_connected_at"] = .string("2026-08-23T23:59:45Z")
        wire["ended_at"] = .string("2026-08-24T00:01:45Z")
        wire["duration_seconds"] = .int(120)
        let record = try XCTUnwrap(parse(payload: wire))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let incoming = record.presentation(viewerIsCaller: false, timeZone: utc)
        XCTAssertEqual(incoming.dialedAtText, "拨打于 2026-08-23 23:59")
        XCTAssertEqual(incoming.title, "视频通话")
        XCTAssertEqual(incoming.directionLabel, "呼入")
        XCTAssertEqual(incoming.statusText, "通话时长 02:00")
        XCTAssertTrue(incoming.accessibilityLabel(peerName: "孟瑶", viewerIsCaller: false, outcome: .completed)
            .contains("拨打于 2026-08-23 23:59"))
        let eastEight = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        XCTAssertEqual(record.presentation(viewerIsCaller: true, timeZone: eastEight).dialedAtText,
                       "拨打于 2026-08-24 07:59")
        let projected = projectedDate(record: record)
        XCTAssertEqual(projected, record.endedAt)
        XCTAssertEqual(RTCCallRecordTimeProjection.displayTime(projected, now: record.endedAt, timeZone: utc), "00:01")
        XCTAssertEqual(RTCCallRecordTimeProjection.displayTime(
            projected, now: record.endedAt.addingTimeInterval(86_400), timeZone: utc
        ), "8月24日")
        XCTAssertNotEqual(projected, record.startedAt)
        XCTAssertNotEqual(projected, record.answeredAt)
        XCTAssertNotEqual(projected, record.mediaConnectedAt)
    }

    func testMessageTimeProjectionPrefersOriginalEndAndRejectsUntrustedPayloads() throws {
        let record = try XCTUnwrap(parse())
        let validOuter = try XCTUnwrap(RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T10:08:43Z"))
        XCTAssertNotEqual(validOuter, record.endedAt)
        XCTAssertEqual(projectedDate(record: record, outerDate: validOuter), record.endedAt)
        XCTAssertEqual(projectedDate(record: nil, outerDate: validOuter), validOuter)
        for (contentType, channelType, sender) in [
            ("text", "direct", "caller-1"),
            ("rtc_call_record", "group", "caller-1"),
            ("rtc_call_record", "direct", "callee-1")
        ] {
            XCTAssertEqual(RTCCallRecordTimeProjection.messageDate(
                outerDate: validOuter, record: record, contentType: contentType,
                channelType: channelType, fromUID: sender
            ), validOuter)
        }
        for raw in [nil, "", "bad-time", "登录时刻"] as [String?] {
            let outer = RTCCallRecordTimeProjection.parseServerTimestamp(raw)
            XCTAssertNil(outer)
            XCTAssertEqual(projectedDate(record: record, outerDate: outer), record.endedAt)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(projectedDate(record: record, outerDate: Date(timeIntervalSince1970: value)), record.endedAt)
            XCTAssertNil(projectedDate(record: nil, outerDate: Date(timeIntervalSince1970: value)))
        }
        XCTAssertNil(projectedDate(record: nil))
        XCTAssertNil(RTCCallRecordTimeProjection.messageDate(
            outerDate: nil, record: record, contentType: "rtc_call_record", channelType: "group", fromUID: "caller-1"
        ))
        XCTAssertNil(RTCCallRecordTimeProjection.messageDate(
            outerDate: nil, record: record, contentType: "rtc_call_record", channelType: "direct", fromUID: "callee-1"
        ))
        XCTAssertEqual(RTCCallRecordTimeProjection.displayTime(nil), "时间未知")
    }

    func testDecodedTypedPayloadMustPassTheWireSemanticValidatorsAgain() throws {
        let record = try XCTUnwrap(parse())
        let mutations: [(String, Any)] = [
            ("schemaVersion", 2), ("callID", ""), ("callerUID", "other-caller"),
            ("calleeUID", "caller-1"), ("durationSeconds", -1), ("reasonCode", "bad reason"),
            ("fallbackText", "通话 token=redacted"), ("endActorUID", "outside-peer"),
            ("finalMediaMode", " AUDIO "),
            ("endedAt", record.startedAt.addingTimeInterval(-1).timeIntervalSinceReferenceDate),
            ("answeredAt", record.startedAt.addingTimeInterval(-1).timeIntervalSinceReferenceDate),
            ("mediaConnectedAt", record.endedAt.addingTimeInterval(1).timeIntervalSinceReferenceDate),
            ("finalOutcome", "no_answer")
        ]
        for (key, value) in mutations {
            var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            encoded[key] = value
            let decoded = try JSONDecoder().decode(RTCCallRecordPayload.self, from: JSONSerialization.data(withJSONObject: encoded))
            XCTAssertNil(projectedDate(record: decoded), key)
            let outer = record.endedAt.addingTimeInterval(86_400)
            XCTAssertEqual(projectedDate(record: decoded, outerDate: outer), outer, key)
        }
    }

    func testLegacyCacheRepairsOnlyDisplayAndPreservesAuthorityAndSummary() throws {
        let record = try XCTUnwrap(parse(outcome: .interrupted))
        var message = makeMessage(id: "legacy-rtc", sequence: 81, record: record, time: "刚刚")
        message.createdAt = nil
        let cached = CachedMessage(message: message)
        let encoded = try JSONEncoder().encode(cached)
        let decoded = try JSONDecoder().decode(CachedMessage.self, from: encoded).model
        XCTAssertEqual(decoded.time, RTCCallRecordTimeProjection.displayTime(record.endedAt))
        XCTAssertNil(decoded.createdAt)
        XCTAssertEqual(decoded.channelSeq, 81)
        XCTAssertEqual(decoded.rtcCallRecord, record)
        XCTAssertEqual(RTCCallRecordMessageDeduplicator.authority(for: decoded),
                       RTCCallRecordMessageDeduplicator.authority(for: message))

        var conversation = makeConversation(id: "legacy-conversation", messages: [message], coveredThrough: 81)
        conversation.time = "坏时间"
        conversation.sortTimestamp = 12_345
        let restored = CachedConversation(conversation: conversation, messageLimit: 20).model
        XCTAssertEqual(restored.time, decoded.time)
        XCTAssertEqual(restored.sortTimestamp, 12_345)
        XCTAssertEqual(restored.lastMsgSeq, 81)
        XCTAssertEqual(restored.messageCoveredThroughSeq, 81)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var typed = try XCTUnwrap(legacy["rtcCallRecord"] as? [String: Any])
        typed["endedAt"] = record.startedAt.addingTimeInterval(-1).timeIntervalSinceReferenceDate
        legacy["rtcCallRecord"] = typed
        legacy["time"] = "bad-time"
        let invalid = try JSONDecoder().decode(CachedMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).model
        XCTAssertEqual(invalid.time, "时间未知")
        XCTAssertNil(invalid.createdAt)
        XCTAssertNotNil(invalid.rtcCallRecord, "Preserve original payload for collision authority")
        XCTAssertEqual(invalid.rtcCallRecord?.presentation(viewerIsCaller: false).dialedAtText, "拨打时间未知")
        legacy.removeValue(forKey: "rtcCallRecord")
        let absent = try JSONDecoder().decode(CachedMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).model
        XCTAssertEqual(absent.time, "时间未知")

        var validOuterMessage = makeMessage(id: "legacy-rtc", sequence: 81, record: record, time: "server-time")
        validOuterMessage.createdAt = record.endedAt
        XCTAssertEqual(CachedMessage(message: validOuterMessage).model.time,
                       RTCCallRecordTimeProjection.displayTime(record.endedAt))
        XCTAssertEqual(CachedMessage(message: validOuterMessage).model.createdAt, record.endedAt)
    }

    func testFiniteOuterCacheReprojectsOriginalEndAcrossRepeatedHistoryRestoreWithoutChangingAuthority() throws {
        let record = try XCTUnwrap(parse(outcome: .interrupted))
        let outer = record.endedAt.addingTimeInterval(3 * 86_400)
        var original = makeMessage(id: "original-event", sequence: 81, record: record, time: "刚刚")
        original.createdAt = outer
        var conversation = makeConversation(id: "event-time", messages: [original], coveredThrough: 81)
        conversation.time = "legacy-list-time"
        conversation.sortTimestamp = outer.timeIntervalSince1970
        let authority = RTCCallRecordMessageDeduplicator.authority(for: original)
        let expectedTime = RTCCallRecordTimeProjection.displayTime(record.endedAt)
        XCTAssertNotEqual(expectedTime, RTCCallRecordTimeProjection.displayTime(outer))

        for _ in 0..<3 {
            let data = try JSONEncoder().encode(CachedConversation(conversation: conversation, messageLimit: 20))
            conversation = try JSONDecoder().decode(CachedConversation.self, from: data).model
            let restored = try XCTUnwrap(conversation.messages.first)
            XCTAssertEqual(restored.time, expectedTime)
            XCTAssertEqual(conversation.time, expectedTime)
            XCTAssertEqual(restored.createdAt, outer)
            XCTAssertEqual(restored.channelSeq, 81)
            XCTAssertEqual(restored.rtcCallRecord, record)
            XCTAssertEqual(RTCCallRecordMessageDeduplicator.authority(for: restored), authority)
            XCTAssertEqual(conversation.sortTimestamp, outer.timeIntervalSince1970)
            XCTAssertEqual(conversation.lastMsgSeq, 81)
            XCTAssertEqual(conversation.messageCoveredThroughSeq, 81)
            XCTAssertEqual(RTCCallRecordMessageDeduplicator.listSummaryMergeDecision(
                existingMessages: [restored], candidate: original
            ), .exactDuplicate)
            XCTAssertEqual(RTCCallRecordMessageDeduplicator.deduplicated([restored, original]).map(\.id), [original.id])
        }
    }

    func testFiniteOuterCacheRejectsInvalidPayloadTimeAndPreservesOrdinaryMessages() throws {
        let record = try XCTUnwrap(parse())
        let outer = record.endedAt.addingTimeInterval(3 * 86_400)
        var message = makeMessage(id: "invalid-event", sequence: 81, record: record, time: "刚刚")
        message.createdAt = outer
        let encoded = try JSONEncoder().encode(CachedMessage(message: message))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var typed = try XCTUnwrap(object["rtcCallRecord"] as? [String: Any])
        typed["endedAt"] = record.startedAt.addingTimeInterval(-1).timeIntervalSinceReferenceDate
        object["rtcCallRecord"] = typed
        for hasPayload in [true, false] {
            if !hasPayload { object.removeValue(forKey: "rtcCallRecord") }
            let restored = try JSONDecoder().decode(CachedMessage.self, from: JSONSerialization.data(withJSONObject: object)).model
            XCTAssertEqual(restored.time, RTCCallRecordTimeProjection.displayTime(outer))
            XCTAssertEqual(restored.createdAt, outer)
            XCTAssertEqual(restored.channelSeq, 81)
            XCTAssertEqual(restored.rtcCallRecord != nil, hasPayload)
        }

        let group = makeConversation(id: "invalid-group", messages: [message], coveredThrough: 81, kind: .group)
        let restoredGroup = CachedConversation(conversation: group, messageLimit: 20).model
        XCTAssertEqual(restoredGroup.messages.first?.time, RTCCallRecordTimeProjection.displayTime(outer))
        XCTAssertEqual(restoredGroup.time, RTCCallRecordTimeProjection.displayTime(outer))

        let ordinary = makeMessage(id: "ordinary", sequence: 82, record: nil, time: "ordinary-time")
        XCTAssertEqual(CachedMessage(message: ordinary).model.time, "ordinary-time")
        var ordinarySummary = makeConversation(id: "ordinary-summary", messages: [message, ordinary], coveredThrough: 82)
        ordinarySummary.time = "ordinary-summary-time"
        XCTAssertEqual(CachedConversation(conversation: ordinarySummary, messageLimit: 20).model.time, "ordinary-summary-time")
    }

    private func projectedDate(record: RTCCallRecordPayload?, outerDate: Date? = nil) -> Date? {
        RTCCallRecordTimeProjection.messageDate(
            outerDate: outerDate, record: record, contentType: "rtc_call_record", channelType: "direct", fromUID: "caller-1"
        )
    }

    func testActionContractFailsClosedForValidAndMalformedRTCRecords() throws {
        let record = try XCTUnwrap(parse(outcome: .calleeRejected))
        var valid = makeMessage(id: "message-20", sequence: 20, record: record)
        valid.isFavorited = true
        XCTAssertFalse(valid.isForwardSupported)
        XCTAssertTrue(menu(for: valid).isEmpty)

        var malformed = makeMessage(id: "message-21", sequence: 21, record: nil)
        malformed.contentType = "rtc_call_record"
        XCTAssertFalse(malformed.isForwardSupported)
        XCTAssertTrue(menu(for: malformed).isEmpty)
    }

    @MainActor
    func testRedialCoordinatorProvidesOnePeerAndTypeBoundGlobalFlight() async {
        let coordinator = RTCCallRecordRedialCoordinator(monitorsNetwork: false)
        XCTAssertTrue(coordinator.begin(peerUID: "peer-1", callType: .audio))
        XCTAssertEqual(coordinator.activeKey, "peer-1|audio")
        XCTAssertFalse(coordinator.begin(peerUID: "peer-1", callType: .audio))
        XCTAssertFalse(coordinator.begin(peerUID: "peer-2", callType: .video))
        coordinator.finish()
        XCTAssertTrue(coordinator.begin(peerUID: "peer-2", callType: .video))
    }

    func testRedialCreateResponseRequiresFreshNonEmptyCallID() throws {
        func responseData(callID: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "call": ["id": callID],
                "rtc_token": "opaque"
            ])
        }

        XCTAssertNoThrow(try JSONDecoder().decode(RemoteRTCCallResponse.self, from: responseData(callID: "historical")))
        try RTCCallRecordRedialFreshnessContext.withCreateResponseGuard(
            excluding: "historical",
            requiredCallType: .audio
        ) {
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteRTCCallResponse.self, from: responseData(callID: "historical")))
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteRTCCallResponse.self, from: responseData(callID: "")))
            let fresh = try JSONSerialization.data(withJSONObject: [
                "call": ["id": "fresh", "call_type": "audio"],
                "rtc_token": "opaque"
            ])
            XCTAssertNoThrow(try JSONDecoder().decode(RemoteRTCCallResponse.self, from: fresh))
            // The create-only guard is consumed after success so later media/heartbeat
            // responses in inherited child tasks retain their normal decoder behavior.
            XCTAssertNoThrow(try JSONDecoder().decode(RemoteRTCCallResponse.self, from: responseData(callID: "historical")))
        }
        try RTCCallRecordRedialFreshnessContext.withCreateResponseGuard(
            excluding: "historical",
            requiredCallType: .video
        ) {
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteRTCCallResponse.self, from: responseData(callID: "fresh-undecided")))
            let downgraded = try JSONSerialization.data(withJSONObject: [
                "call": ["id": "fresh-video", "call_type": "video", "requested_media_mode": "video", "media_mode": "audio"],
                "rtc_token": "opaque"
            ])
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteRTCCallResponse.self, from: downgraded))
        }
    }

    func testRedialFreshnessScopePropagatesIntoCreateTask() async {
        let inherited = await RTCCallRecordRedialFreshnessContext.withCreateResponseGuard(
            excluding: "historical",
            requiredCallType: .video
        ) {
            await Task {
                RTCCallRecordRedialFreshnessContext.excludedHistoricalCallID == "historical"
                    && RTCCallRecordRedialFreshnessContext.requiredCallType == .video
            }.value
        }
        XCTAssertTrue(inherited)
    }

    private func menu(for message: ChatMessage) -> [MessageActionMenuDescriptor] {
        messageActionMenuDescriptors(
            message: message,
            canShowReadActions: true,
            readActionTitle: "已读",
            canForward: true,
            forwardDisabledReason: "不可转发",
            canSaveAttachment: true,
            canFavoriteAsset: true,
            canReportMessage: true,
            canAdminDeleteForAll: true,
            recallDisabledReason: nil
        )
    }

    func parse(
        outcome: RTCCallRecordOutcome = .completed,
        callType: RTCCallRecordType = .audio
    ) -> RTCCallRecordPayload? {
        parse(payload: payload(outcome: outcome, callType: callType))
    }

    func parse(
        payload: [String: JSONValue],
        contentType: String = "rtc_call_record",
        channelType: String = "direct",
        fromUID: String = "caller-1"
    ) -> RTCCallRecordPayload? {
        RTCCallRecordPayload.parse(
            contentType: contentType,
            channelType: channelType,
            fromUID: fromUID,
            payload: payload
        )
    }

    func payload(
        outcome: RTCCallRecordOutcome,
        callType: RTCCallRecordType = .audio
    ) -> [String: JSONValue] {
        var value: [String: JSONValue] = [
            "schema_version": .int(1),
            "call_id": .string("call-stable-1"),
            "call_type": .string(callType.rawValue),
            "caller_uid": .string("caller-1"),
            "callee_uid": .string("callee-1"),
            "final_outcome": .string(outcome.rawValue),
            "started_at": .string("2026-08-23T10:00:00Z"),
            "ended_at": .string("2026-08-23T10:08:42Z"),
            "duration_seconds": .int(0),
            "reason_code": .string(outcome.rawValue),
            "text": .string("[\(callType.title)] 通话已结束"),
            "fallback_text": .string("通话记录")
        ]
        switch outcome {
        case .completed:
            value["answered_at"] = .string("2026-08-23T10:00:03Z")
            value["media_connected_at"] = .string("2026-08-23T10:00:04Z")
            value["duration_seconds"] = .int(522)
            value["end_actor_uid"] = .string("caller-1")
        case .callerCanceled:
            value["end_actor_uid"] = .string("caller-1")
        case .calleeRejected:
            value["end_actor_uid"] = .string("callee-1")
        case .interrupted:
            value["answered_at"] = .string("2026-08-23T10:00:03Z")
            value["media_connected_at"] = .string("2026-08-23T10:00:04Z")
            value["duration_seconds"] = .int(522)
        case .noAnswer, .busy, .setupFailed:
            break
        }
        return value
    }

    func makeMessage(
        id: String,
        sequence: Int64,
        record: RTCCallRecordPayload?,
        time: String = "10:08"
    ) -> ChatMessage {
        var message = ChatMessage(
            id: id,
            senderId: "caller-1",
            senderName: "来电人",
            text: "通话记录",
            time: time,
            createdAt: Date(timeIntervalSince1970: 1_777_111_111),
            channelSeq: sequence,
            isOutgoing: false,
            status: .read,
            kind: record == nil ? .text : .rtcCallRecord,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        message.contentType = record == nil ? "text" : "rtc_call_record"
        message.rtcCallRecord = record
        return message
    }

    func makeConversation(
        id: String,
        messages: [ChatMessage],
        coveredThrough: Int64,
        requiresRecovery: Bool = false,
        kind: ConversationKind = .direct
    ) -> ConversationMessageSnapshot {
        ConversationMessageSnapshot(
            id: id,
            title: id,
            subtitle: "",
            kind: kind,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: nil,
            accentHex: 0,
            participants: [],
            messages: messages,
            lastMsgSeq: messages.map(\.channelSeq).max() ?? 0,
            messageCoveredThroughSeq: coveredThrough,
            messageCoverageRequiresRecovery: requiresRecovery
        )
    }

    func remoteMessage(id: String, sequence: Int64) -> RemoteMessage {
        let object: [String: Any] = [
            "message_id": id,
            "channel_id": "caller-1:callee-1",
            "channel_type": "direct",
            "channel_seq": sequence,
            "from_uid": "caller-1",
            "content_type": "rtc_call_record",
            "payload": [:],
            "status": "sent",
            "created_at": "2026-08-23T10:00:00Z"
        ]
        return try! JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    func remoteConversation(id: String, lastMessageSequence: Int64) -> RemoteConversation {
        let object: [String: Any] = [
            "channel_id": id,
            "channel_type": "direct",
            "last_msg_seq": lastMessageSequence,
            "unread_count": 0
        ]
        return try! JSONDecoder().decode(
            RemoteConversation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

extension DomainStoreTests {
    // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112_BEGIN
    func testWriteCallArchiveBeforeIsolatedProcessRestart() async throws {
        let run = try M17CallArchiveProcessRun(phase: "write")
        guard !FileManager.default.fileExists(atPath: run.root.path) else {
            XCTFail("The writer requires a fresh UUID-owned fixture directory")
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: run.root, withIntermediateDirectories: false)
        defer { run.defaults.removePersistentDomain(forName: run.suite) }
        let a = m17ArchiveContext(run, tenant: "a")
        let b = m17ArchiveContext(run, tenant: "b")
        let state = try makeM17ArchiveColdLaunch(run, context: a)
        defer { state.callStore.reset() }
        let scopeA = state.callRecordDataScopeKey(for: a)
        let scopeB = state.callRecordDataScopeKey(for: b)
        XCTAssertNotEqual(scopeA, scopeB)
        XCTAssertNil(run.defaults.data(forKey: run.storageKey))
        state.upsertVoiceCallRecord(callID: run.callID("a"), title: "M17 tenant A", subtitle: "语音呼出",
            status: "通话中", direction: .outgoing, startedAt: run.startedAt, stateVersion: 1)
        state.upsertVoiceCallRecord(callID: run.callID("a"), title: "M17 tenant A", subtitle: "语音呼出 · 通话已结束",
            status: "已结束", direction: .outgoing, endedAt: run.endedAt, durationSeconds: 30,
            endReason: "hangup", stateVersion: 2)
        _ = try await waitForM17ArchiveValue("Tenant A terminal state on disk") {
            (try? run.readDiskArchive())?.recordsByScope[scopeA]?.first(where: { $0.stateVersion == 2 })
        }

        state.overrideAPIContextForTesting(b)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        state.ensureCallRecordPersistenceBindingIfNeeded()
        state.upsertVoiceCallRecord(callID: run.callID("b"), title: "M17 tenant B", subtitle: "语音呼出 · 通话已结束",
            status: "已结束", direction: .outgoing, stateVersion: 1)
        let archive: M17CallArchiveProcessRun.Archive = try await waitForM17ArchiveValue("Tenant B positive control on disk") {
            guard let archive = try? run.readDiskArchive(), archive.recordsByScope[scopeB] != nil else { return nil }
            return archive
        }
        XCTAssertEqual(archive.schemaVersion, 1)
        XCTAssertEqual(Set(archive.recordsByScope.keys), Set([scopeA, scopeB]))
        assertM17Terminal(try XCTUnwrap(archive.recordsByScope[scopeA]), run: run)
        XCTAssertEqual(archive.recordsByScope[scopeB]?.map(\.callID), [run.callID("b")])
        let writer = M17CallArchiveProcessRun.Writer(id: run.id, pid: ProcessInfo.processInfo.processIdentifier,
            archive: try run.archiveIdentity())
        try JSONEncoder().encode(writer).write(to: run.writerReceipt, options: .atomic)
        try attachM17ArchiveProcessEvidence(run, writer: writer)
    }

    func testRestoreCallArchiveAfterIsolatedProcessRestart() async throws {
        let run = try M17CallArchiveProcessRun(phase: "restore")
        defer { run.defaults.removePersistentDomain(forName: run.suite) }
        let writer = try JSONDecoder().decode(M17CallArchiveProcessRun.Writer.self, from: Data(contentsOf: run.writerReceipt))
        XCTAssertEqual(writer.id, run.id)
        XCTAssertNotEqual(ProcessInfo.processInfo.processIdentifier, writer.pid, "Restore requires a new app-host process")
        XCTAssertEqual(try run.archiveIdentity(), writer.archive)
        XCTAssertNil(run.defaults.data(forKey: run.storageKey), "The consumer's independent defaults must start empty")

        let b = m17ArchiveContext(run, tenant: "b")
        let state = try makeM17ArchiveColdLaunch(run, context: b)
        defer { state.callStore.reset() }
        let recordsB = try await waitForM17ArchiveValue("Cold login restored B's positive control") {
            state.callStore.calls.isEmpty ? nil : state.callStore.calls
        }
        XCTAssertEqual(recordsB.map(\.callID), [run.callID("b")], "Tenant B must not see A")
        let a = m17ArchiveContext(run, tenant: "a")
        state.overrideAPIContextForTesting(a)
        XCTAssertTrue(state.callStore.calls.isEmpty, "Switching tenants must detach B immediately")
        state.ensureCallRecordPersistenceBindingIfNeeded()
        let recordsA = try await waitForM17ArchiveValue("Switch restored A from the writer's disk archive") {
            state.callStore.calls.isEmpty ? nil : state.callStore.calls
        }
        assertM17Terminal(recordsA, run: run)
        XCTAssertNil(run.defaults.data(forKey: run.storageKey), "Restoration used the disk archive")
        XCTAssertEqual(try run.archiveIdentity(), writer.archive, "Recovery must leave the original archive intact")
        try attachM17ArchiveProcessEvidence(run, writer: writer)
    }

    private func m17ArchiveContext(_ run: M17CallArchiveProcessRun, tenant: String) -> IMAPIContext {
        let identity = "m17-" + run.id.uuidString
        var context = makeAuthenticatedAPIContext(accountID: identity, imUID: identity)
        context.tenantID = "m17-\(run.id.uuidString)-\(tenant)"
        context.deviceID = run.id.uuidString
        return context
    }

    private func makeM17ArchiveColdLaunch(_ run: M17CallArchiveProcessRun, context: IMAPIContext) throws -> AppState {
        let protectedStore = InMemoryProtectedSessionStore()
        XCTAssertTrue(context.save(defaults: run.defaults, sessionStore: protectedStore).isCommitted)
        let loadedContext = IMAPIContext.load(defaults: run.defaults, sessionStore: protectedStore)
        XCTAssertEqual(loadedContext.authSessionFence, context.authSessionFence)
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"), imBase: URL(string: "https://im.example.test"),
            bootstrapBases: [], httpTransport: FakeHTTPTransport(results: []),
            runtimeRouteStore: IMRuntimeRouteStore(defaults: run.defaults), startupContext: loadedContext)
        let state = AppState(api: api, pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: run.defaults),
            accessDiscovery: AccessDiscoveryManager(store: AccessDiscoveryStore(baseDirectory: run.root.appendingPathComponent("discovery"))),
            realtimeClient: RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: FakeRealtimeWebSocketTask()),
                networkMonitorFactory: nil),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            callStore: CallStore(callRecordStore: UserDefaultsCallRecordStore(
                defaults: run.defaults, storageKey: run.storageKey, archiveURL: run.archiveURL)),
            messageStore: SnapshotCache(directoryURL: run.root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: run.root.appendingPathComponent("messages"),
                cachesBase: run.root.appendingPathComponent("caches")),
            biometricDefaults: run.defaults, currentUserIdentityDefaults: run.defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: RecordingRememberedLoginPreferenceStore(), protectedSessionStore: protectedStore,
            registrationSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: loadedContext,
            launchUnitTestOverride: false)
        // The synchronous normal constructor binds the archive. Its unrelated remote restore need not run.
        try XCTUnwrap(state.coldLaunchSessionRestoreTask).cancel()
        state.splashConfigurationRefreshTask?.cancel()
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(IMCurrentUserIdentityCache.load(context: loadedContext, defaults: run.defaults)?.imUID, loadedContext.imUID)
        XCTAssertTrue(state.callStore.hasCallRecordPersistenceBinding)
        return state
    }

    private func waitForM17ArchiveValue<Value>(_ description: String, sample: () -> Value?) async throws -> Value {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let value = sample() { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(sample(), description)
    }

    private func assertM17Terminal(_ records: [CallRecord], run: M17CallArchiveProcessRun) {
        XCTAssertEqual(records.map(\.callID), [run.callID("a")])
        XCTAssertEqual(records.first?.status, "已结束")
        XCTAssertEqual(records.first?.direction, .outgoing)
        XCTAssertEqual(records.first?.startedAt, run.startedAt)
        XCTAssertEqual(records.first?.endedAt, run.endedAt)
        XCTAssertEqual(records.first?.durationSeconds, 30)
        XCTAssertEqual(records.first?.endReason, "hangup")
        XCTAssertEqual(records.first?.stateVersion, 2)
    }

    private func attachM17ArchiveProcessEvidence(_ run: M17CallArchiveProcessRun, writer: M17CallArchiveProcessRun.Writer) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "phase": run.phase, "pid": ProcessInfo.processInfo.processIdentifier, "writerPID": writer.pid,
            "runID": run.id.uuidString, "relativeArchivePath": run.archiveURL.lastPathComponent,
            "archiveSHA256": writer.archive.sha256, "archiveInode": writer.archive.inode,
            "tenantACallID": run.callID("a"), "tenantBCallID": run.callID("b"),
            "tenantAStatus": "已结束", "tenantAStateVersion": 2
        ])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "m17-call-archive-process-" + run.phase
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112_END
}

// WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112_BEGIN
private struct M17CallArchiveProcessRun {
    struct Archive: Decodable {
        let schemaVersion: Int
        let recordsByScope: [String: [CallRecord]]
    }

    struct ArchiveIdentity: Codable, Equatable {
        let sha256: String
        let inode: UInt64
    }

    struct Writer: Codable {
        let id: UUID
        let pid: Int32
        let archive: ArchiveIdentity
    }

    let id: UUID
    let phase: String
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let storageKey = "test.m17.callRecords"
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let endedAt = Date(timeIntervalSince1970: 1_700_000_030)

    init(phase: String) throws {
        let process = ProcessInfo.processInfo
        guard let raw = process.environment["IM4_TEST_M17_CALL_ARCHIVE_RUN_ID"] else {
            throw XCTSkip("Requires the paired app-host runner")
        }
        guard process.arguments.contains("--notification-settings-screenshot"),
              process.arguments.contains("--jht-disable-rtc-runtime") else {
            XCTFail("M17 requires the read-only app host with system RTC disabled")
            throw CocoaError(.featureUnsupported)
        }
        let id = try XCTUnwrap(UUID(uuidString: raw), "The runner must supply a unique fixture ID")
        let name = "IM4M17CallArchiveProcess-" + id.uuidString
        self.id = id
        self.phase = phase
        suite = name + "." + phase
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: phase == "write").appendingPathComponent(name, isDirectory: true)
    }

    var archiveURL: URL { root.appendingPathComponent("call-records.json") }
    var writerReceipt: URL { root.appendingPathComponent("writer.json") }

    func callID(_ tenant: String) -> String { "m17-\(id.uuidString)-\(tenant)" }

    func readDiskArchive() throws -> Archive {
        try JSONDecoder().decode(Archive.self, from: Data(contentsOf: archiveURL))
    }

    func archiveIdentity() throws -> ArchiveIdentity {
        let data = try Data(contentsOf: archiveURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
        return ArchiveIdentity(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            inode: inode.uint64Value)
    }
}
// WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112_END

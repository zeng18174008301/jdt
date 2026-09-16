import XCTest
@testable import BlueStoneIM

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

    func testCallIDDeduplicationIsStableAcrossIdentityAndOrder() throws {
        let record = try XCTUnwrap(parse(outcome: .busy))
        let first = makeMessage(id: "message-10", sequence: 10, record: record)
        let duplicate = makeMessage(id: "message-11", sequence: 11, record: record)
        let normal = makeMessage(id: "message-12", sequence: 12, record: nil)
        let result = RTCCallRecordMessageDeduplicator.deduplicated([first, duplicate, normal])
        XCTAssertEqual(result.map(\.id), ["message-10", "message-12"])
    }

    func testListSummaryOnlySkipsCompleteMatchingAuthority() throws {
        let originalRecord = try XCTUnwrap(parse(outcome: .busy))
        let changedRecord = try XCTUnwrap(parse(outcome: .noAnswer))
        let original = makeMessage(id: "summary-message", sequence: 2, record: originalRecord)
        let exact = makeMessage(id: "summary-message", sequence: 2, record: originalRecord)
        let changed = makeMessage(id: "summary-message", sequence: 2, record: changedRecord)
        var malformed = makeMessage(id: "summary-message", sequence: 2, record: nil)
        malformed.contentType = "rtc_call_record"
        let newIdentity = makeMessage(id: "summary-message-new", sequence: 3, record: originalRecord)
        let highSequenceOriginal = makeMessage(id: "summary-rollback", sequence: 50, record: originalRecord)
        let lowSequenceConflict = makeMessage(id: "summary-rollback", sequence: 1, record: changedRecord)
        let invalidSequenceConflict = makeMessage(id: "summary-rollback", sequence: 0, record: changedRecord)

        XCTAssertEqual(
            RTCCallRecordMessageDeduplicator.listSummaryMergeDecision(
                existingMessages: [original],
                candidate: exact
            ),
            .exactDuplicate
        )
        XCTAssertEqual(
            RTCCallRecordMessageDeduplicator.listSummaryMergeDecision(
                existingMessages: [original],
                candidate: changed
            ),
            .conflict(sequence: 2)
        )
        XCTAssertEqual(
            RTCCallRecordMessageDeduplicator.listSummaryMergeDecision(
                existingMessages: [original],
                candidate: malformed
            ),
            .conflict(sequence: 2)
        )
        XCTAssertEqual(
            RTCCallRecordMessageDeduplicator.listSummaryMergeDecision(
                existingMessages: [original],
                candidate: newIdentity
            ),
            .append
        )
        XCTAssertEqual(
            RTCCallRecordMessageDeduplicator.listSummaryMergeDecision(
                existingMessages: [highSequenceOriginal],
                candidate: lowSequenceConflict
            ),
            .conflict(sequence: 1)
        )
        XCTAssertEqual(
            RTCCallRecordMessageDeduplicator.listSummaryMergeDecision(
                existingMessages: [highSequenceOriginal],
                candidate: invalidSequenceConflict
            ),
            .conflict(sequence: 0)
        )
    }

    @MainActor
    func testCachedHydrationEnforcesCallIDGloballyAcrossConversations() throws {
        let record = try XCTUnwrap(parse(outcome: .busy))
        let first = makeMessage(id: "message-global-1", sequence: 1, record: record)
        let collision = makeMessage(id: "message-global-2", sequence: 2, record: record)
        let conversations = [
            makeConversation(id: "conversation-a", messages: [first], coveredThrough: 1),
            makeConversation(id: "conversation-b", messages: [collision], coveredThrough: 2)
        ]
        let store = ConversationStore()
        store.hydrateCachedConversations(conversations)
        XCTAssertEqual(store.conversations.flatMap(\.messages).filter(\.isRTCCallRecordMessage).count, 1)
        XCTAssertEqual(store.conversation(id: "conversation-b")?.messageCoveredThroughSeq, 1)
        XCTAssertEqual(store.conversation(id: "conversation-b")?.messageCoverageRequiresRecovery, true)
    }

    @MainActor
    func testFreshRemoteConversationListEnforcesCallIDGloballyAndOpensRecoveryGap() throws {
        let record = try XCTUnwrap(parse(outcome: .busy))
        let first = makeMessage(id: "message-list-1", sequence: 1, record: record)
        let collision = makeMessage(id: "message-list-2", sequence: 2, record: record)
        var authoritative = makeConversation(
            id: "conversation-list-a",
            messages: [first],
            coveredThrough: 1
        )
        authoritative.sortTimestamp = 200
        authoritative.lastMessage = "语音通话 · 对方忙线"
        var rejected = makeConversation(
            id: "conversation-list-b",
            messages: [collision],
            coveredThrough: 2
        )
        rejected.sortTimestamp = 100
        rejected.lastMessage = "语音通话 · 对方忙线"

        let store = ConversationStore()
        let result = store.mergeRemoteConversationList(
            entries: [
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: authoritative.id,
                    remote: remoteConversation(id: authoritative.id, lastMessageSequence: 1),
                    conversation: authoritative
                ),
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: rejected.id,
                    remote: remoteConversation(id: rejected.id, lastMessageSequence: 2),
                    conversation: rejected
                )
            ],
            replacing: true,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(result.conversations.flatMap(\.messages).filter(\.isRTCCallRecordMessage).count, 1)
        let recovering = try XCTUnwrap(store.conversation(id: rejected.id))
        XCTAssertTrue(recovering.messages.isEmpty)
        XCTAssertEqual(recovering.lastMessage, "")
        XCTAssertEqual(recovering.messageCoveredThroughSeq, 1)
        XCTAssertTrue(recovering.messageCoverageRequiresRecovery)
        XCTAssertEqual(store.messageSequenceRecoveryTarget(for: recovering)?.afterSeq, 1)
        XCTAssertEqual(store.messageSequenceRecoveryTarget(for: recovering)?.throughSeq, 2)
    }

    @MainActor
    func testIncrementalRemoteConversationListNormalizesNewCallRecordBeforeSoundCandidate() throws {
        let record = try XCTUnwrap(parse(outcome: .busy))
        let authoritativeRecord = makeMessage(id: "message-incremental-1", sequence: 1, record: record)
        let collision = makeMessage(id: "message-incremental-2", sequence: 2, record: record)
        var authoritative = makeConversation(
            id: "conversation-incremental-a",
            messages: [authoritativeRecord],
            coveredThrough: 1
        )
        authoritative.sortTimestamp = 200
        var previous = makeConversation(
            id: "conversation-incremental-b",
            messages: [makeMessage(id: "ordinary-message", sequence: 1, record: nil)],
            coveredThrough: 1
        )
        previous.sortTimestamp = 100
        var refreshed = previous
        refreshed.messages.append(collision)
        refreshed.lastMsgSeq = 2
        refreshed.messageCoveredThroughSeq = 2
        refreshed.lastMessage = "语音通话 · 对方忙线"

        let store = ConversationStore()
        store.conversations = [authoritative, previous]
        let result = store.mergeRemoteConversationList(
            entries: [
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: refreshed.id,
                    remote: remoteConversation(id: refreshed.id, lastMessageSequence: 2),
                    conversation: refreshed
                )
            ],
            replacing: false,
            channelIDForConversation: { $0.id }
        )

        let normalized = try XCTUnwrap(store.conversation(id: refreshed.id))
        XCTAssertEqual(normalized.messages.map(\.id), ["ordinary-message"])
        XCTAssertEqual(normalized.lastMessage, "通话记录")
        XCTAssertEqual(normalized.messageCoveredThroughSeq, 1)
        XCTAssertTrue(normalized.messageCoverageRequiresRecovery)
        XCTAssertEqual(result.soundCandidates.count, 1)
        XCTAssertEqual(result.soundCandidates.first?.mapped, normalized)
    }

    @MainActor
    func testRealtimeCallIDIdentityCollisionCountsUnreadOnceAndOpensGap() throws {
        let record = try XCTUnwrap(parse(outcome: .noAnswer))
        let first = makeMessage(id: "message-30", sequence: 1, record: record)
        let duplicate = makeMessage(id: "message-31", sequence: 2, record: record)
        let entries = [first, duplicate].map { message in
            ConversationStore.MappedRemoteMessage(
                remote: remoteMessage(id: message.id, sequence: message.channelSeq),
                message: message,
                clientMessageIDs: [],
                isRemoteFromCurrentUser: false,
                matchedLocalID: nil
            )
        }
        let result = ConversationStore().mergeMappedRemoteMessages(
            previous: nil,
            mappedRemoteMessages: entries,
            readReceiptsEnabled: false,
            fromRealtime: true,
            sequenceCoverageAfterSeq: 0,
            coveredChannelSeqs: [1, 2]
        )
        XCTAssertEqual(result.messages.map(\.id), ["message-30"])
        XCTAssertEqual(result.incomingRealtimeMessages.map(\.id), ["message-30"])
        XCTAssertEqual(result.latestKnownSeq, 2)
        XCTAssertEqual(result.messageCoveredThroughSeq, 1)
        XCTAssertEqual(result.sequenceRecoveryAfterSeq, 1)
        XCTAssertEqual(result.sequenceRecoveryThroughSeq, 2)
    }

    @MainActor
    func testMalformedReplayCannotReplaceTypedRecordAndCoverageCannotCrossConflict() throws {
        let record = try XCTUnwrap(parse(outcome: .noAnswer))
        let authoritative = makeMessage(id: "message-typed", sequence: 1, record: record)
        var malformed = makeMessage(id: "message-typed", sequence: 1, record: nil)
        malformed.contentType = "rtc_call_record"
        let previous = makeConversation(id: "conversation-typed", messages: [authoritative], coveredThrough: 1)
        let entry = ConversationStore.MappedRemoteMessage(
            remote: remoteMessage(id: malformed.id, sequence: malformed.channelSeq),
            message: malformed,
            clientMessageIDs: [],
            isRemoteFromCurrentUser: false,
            matchedLocalID: nil
        )
        let store = ConversationStore()
        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [entry],
            readReceiptsEnabled: false,
            fromRealtime: true,
            coveredChannelSeqs: [1]
        )
        XCTAssertEqual(result.messages.first?.rtcCallRecord, record)
        XCTAssertEqual(result.messageCoveredThroughSeq, 0)
        XCTAssertEqual(result.sequenceRecoveryAfterSeq, 0)

        let postConflictWindow = makeConversation(
            id: "conversation-gap",
            messages: [makeMessage(id: "normal-3", sequence: 3, record: nil), makeMessage(id: "normal-4", sequence: 4, record: nil)],
            coveredThrough: 1,
            requiresRecovery: true
        )
        XCTAssertEqual(store.messageSequenceCoveredThrough(in: postConflictWindow), 1)
    }

    @MainActor
    func testCallerRecordNeverBecomesIncomingUnreadCandidate() throws {
        let record = try XCTUnwrap(parse(outcome: .callerCanceled))
        var outgoing = makeMessage(id: "message-40", sequence: 1, record: record)
        outgoing = ChatMessage(
            id: outgoing.id,
            senderId: outgoing.senderId,
            senderName: outgoing.senderName,
            text: outgoing.text,
            time: outgoing.time,
            createdAt: outgoing.createdAt,
            channelSeq: outgoing.channelSeq,
            isOutgoing: true,
            status: outgoing.status,
            kind: outgoing.kind,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        outgoing.contentType = "rtc_call_record"
        outgoing.rtcCallRecord = record
        let entry = ConversationStore.MappedRemoteMessage(
            remote: remoteMessage(id: outgoing.id, sequence: outgoing.channelSeq),
            message: outgoing,
            clientMessageIDs: [],
            isRemoteFromCurrentUser: true,
            matchedLocalID: nil
        )
        let result = ConversationStore().mergeMappedRemoteMessages(
            previous: nil,
            mappedRemoteMessages: [entry],
            readReceiptsEnabled: false,
            fromRealtime: true,
            coveredChannelSeqs: [1]
        )
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertTrue(result.incomingRealtimeMessages.isEmpty)
    }

    @MainActor
    func testOlderMalformedRTCPageCannotBypassLocalOrCrossConversationAuthority() throws {
        let record = try XCTUnwrap(parse(outcome: .noAnswer))
        let authoritative = makeMessage(id: "m100", sequence: 100, record: record)
        let variants: [(String, [String: Any])] = [
            ("rtc_call_record", ["call_id": record.callID, "schema_version": -1]),
            ("", ["call_id": record.callID, "content_type": " RTC_CALL_RECORD ", "schema_version": -1]),
            ("text", ["call_id": record.callID, "text": "malformed replacement"])
        ]
        for crossConversation in [false, true] {
            for (contentType, payload) in variants {
                let store = ConversationStore()
                let previous = makeConversation(
                    id: "current", messages: [crossConversation ? makeMessage(id: "ordinary100", sequence: 100, record: nil) : authoritative],
                    coveredThrough: 100
                )
                let other = makeConversation(id: "other", messages: [authoritative], coveredThrough: 100)
                store.conversations = crossConversation ? [previous, other] : [previous]
                let entry = try olderHistoryEntry(id: "m99", sequence: 99, contentType: contentType, payload: payload)
                XCTAssertNil(entry.message.rtcCallRecord)
                let result = store.mergeMappedRemoteMessages(
                    previous: previous, mappedRemoteMessages: [entry], readReceiptsEnabled: false,
                    fromRealtime: false, olderHistoryBeforeSeq: 100, coveredChannelSeqs: [99]
                )
                XCTAssertEqual(result.messages, previous.messages)
                XCTAssertEqual(result.messageCoveredThroughSeq, 98)
                XCTAssertTrue(result.messageCoverageRequiresRecovery)
                XCTAssertEqual(result.sequenceRecoveryAfterSeq, 98)
                XCTAssertEqual(result.sequenceRecoveryThroughSeq, 100)
                var updated = previous
                updated.messages = result.messages
                updated.messageCoveredThroughSeq = result.messageCoveredThroughSeq
                updated.messageCoverageRequiresRecovery = result.messageCoverageRequiresRecovery
                XCTAssertEqual(store.latestReadableSequence(in: updated), 98)
                if crossConversation { XCTAssertEqual(store.conversations.last?.messages, [authoritative]) }
            }
        }
    }

    @MainActor
    func testOlderOrdinaryReplacementOfRTCIdentityAlsoUsesAuthorityMerge() throws {
        let record = try XCTUnwrap(parse(outcome: .noAnswer))
        let authoritative = makeMessage(id: "m100", sequence: 100, record: record)
        let previous = makeConversation(id: "current", messages: [authoritative], coveredThrough: 100)
        for (id, sequence, before) in [("m100", Int64(99), Int64(100)), ("different-id", 100, 101)] {
            let store = ConversationStore()
            store.conversations = [previous]
            let entry = try olderHistoryEntry(id: id, sequence: sequence, contentType: "text", payload: ["text": "replacement"])
            let result = store.mergeMappedRemoteMessages(
                previous: previous, mappedRemoteMessages: [entry], readReceiptsEnabled: false,
                fromRealtime: false, olderHistoryBeforeSeq: before, coveredChannelSeqs: [sequence]
            )
            XCTAssertEqual(result.messages, [authoritative])
            XCTAssertEqual(result.messageCoveredThroughSeq, sequence - 1)
            XCTAssertTrue(result.messageCoverageRequiresRecovery)
        }
    }

    @MainActor
    func testOrdinaryOlderPageStillPrependsWithCoverageAndWithoutRecovery() throws {
        let existing = makeMessage(id: "ordinary100", sequence: 100, record: nil)
        let previous = makeConversation(id: "ordinary", messages: [existing], coveredThrough: 100)
        let entry = try olderHistoryEntry(id: "ordinary99", sequence: 99, contentType: "text", payload: ["text": "older"])
        let result = ConversationStore().mergeMappedRemoteMessages(
            previous: previous, mappedRemoteMessages: [entry], readReceiptsEnabled: false,
            fromRealtime: false, olderHistoryBeforeSeq: 100, coveredChannelSeqs: [99]
        )
        XCTAssertEqual(result.messages.map(\.id), ["ordinary99", "ordinary100"])
        XCTAssertEqual(result.messageCoveredThroughSeq, 100)
        XCTAssertFalse(result.messageCoverageRequiresRecovery)
        XCTAssertNil(result.sequenceRecoveryAfterSeq)
        XCTAssertTrue(result.incomingRealtimeMessages.isEmpty)
    }

    private func olderHistoryEntry(
        id: String, sequence: Int64, contentType: String, payload: [String: Any]
    ) throws -> ConversationStore.MappedRemoteMessage {
        let object: [String: Any] = [
            "message_id": id, "channel_id": "caller-1:callee-1", "channel_type": "direct",
            "channel_seq": sequence, "from_uid": "caller-1", "content_type": contentType,
            "payload": payload, "created_at": "2026-08-23T10:00:00Z"
        ]
        let remote = try JSONDecoder().decode(RemoteMessage.self, from: JSONSerialization.data(withJSONObject: object))
        var mapped = makeMessage(id: id, sequence: sequence, record: nil)
        mapped.contentType = remote.contentType
        return ConversationStore.MappedRemoteMessage(
            remote: remote, message: mapped, clientMessageIDs: [], isRemoteFromCurrentUser: false, matchedLocalID: nil
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

    private func parse(
        outcome: RTCCallRecordOutcome = .completed,
        callType: RTCCallRecordType = .audio
    ) -> RTCCallRecordPayload? {
        parse(payload: payload(outcome: outcome, callType: callType))
    }

    private func parse(
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

    private func payload(
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

    private func makeMessage(
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

    private func makeConversation(
        id: String,
        messages: [ChatMessage],
        coveredThrough: Int64,
        requiresRecovery: Bool = false,
        kind: ConversationKind = .direct
    ) -> Conversation {
        Conversation(
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

    private func remoteMessage(id: String, sequence: Int64) -> RemoteMessage {
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

    private func remoteConversation(id: String, lastMessageSequence: Int64) -> RemoteConversation {
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
}

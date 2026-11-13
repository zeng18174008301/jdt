import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine // WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111
@testable import WenDaTong
import IM4Data // WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111

extension RTCCallRecordMessageTests {
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
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.hydrateCachedConversations(conversations)
        XCTAssertEqual(store.conversationMessageSnapshots().flatMap(\.messages).filter(\.isRTCCallRecordMessage).count, 1)
        XCTAssertEqual(store.conversationMessageSnapshot(id: "conversation-b")?.messageCoveredThroughSeq, 1)
        XCTAssertEqual(store.conversationMessageSnapshot(id: "conversation-b")?.messageCoverageRequiresRecovery, true)
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

        let store = ConversationStore(scope: TestMessageMemoryScope.value)
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
        let recovering = try XCTUnwrap(store.conversationMessageSnapshot(id: rejected.id))
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

        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        store.commitConversationSnapshots([authoritative, previous])
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

        let normalized = try XCTUnwrap(store.conversationMessageSnapshot(id: refreshed.id))
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
        let result = ConversationStore(scope: TestMessageMemoryScope.value).mergeMappedRemoteMessages(
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
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
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
        let result = ConversationStore(scope: TestMessageMemoryScope.value).mergeMappedRemoteMessages(
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
                let store = ConversationStore(scope: TestMessageMemoryScope.value)
                let previous = makeConversation(
                    id: "current", messages: [crossConversation ? makeMessage(id: "ordinary100", sequence: 100, record: nil) : authoritative],
                    coveredThrough: 100
                )
                let other = makeConversation(id: "other", messages: [authoritative], coveredThrough: 100)
                store.commitConversationSnapshots(crossConversation ? [previous, other] : [previous])
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
                if crossConversation { XCTAssertEqual(store.conversationMessageSnapshots().last?.messages, [authoritative]) }
            }
        }
    }

    @MainActor
    func testOlderOrdinaryReplacementOfRTCIdentityAlsoUsesAuthorityMerge() throws {
        let record = try XCTUnwrap(parse(outcome: .noAnswer))
        let authoritative = makeMessage(id: "m100", sequence: 100, record: record)
        let previous = makeConversation(id: "current", messages: [authoritative], coveredThrough: 100)
        for (id, sequence, before) in [("m100", Int64(99), Int64(100)), ("different-id", 100, 101)] {
            let store = ConversationStore(scope: TestMessageMemoryScope.value)
            store.commitConversationSnapshots([previous])
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
        let result = ConversationStore(scope: TestMessageMemoryScope.value).mergeMappedRemoteMessages(
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
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111_BEGIN
@MainActor
final class M17IOConsumerTests: XCTestCase {
    func testDiagnosticActorKeepsRedactionSequenceAndExportFormat() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = RTCCallDiagnosticLogStore(baseURL: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        await logger.append(category: " flow\nnext ", media: " AUDIO ", callID: " short\rID ",
                            message: "Bearer synthetic-secret\nconnected", at: date)
        await logger.append(category: "long", media: "video", message: String(repeating: "x", count: 2_401), at: date)
        let log = root.appendingPathComponent("RTCCallDiagnostics/rtc-call-diagnostics.log")
        let text = try String(contentsOf: log, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("seq=1 media=voice [flow next] call=short ID Bearer=<redacted> connected"))
        XCTAssertFalse(text.contains("synthetic-secret"))
        XCTAssertTrue(lines[1].contains("seq=2 media=video [long] " + String(repeating: "x", count: 2_400) + "...[truncated]"))
        let exported = try await logger.makeExportTextFile()
        defer { try? FileManager.default.removeItem(at: exported) }
        let exportText = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(exportText.contains("file_format=txt"))
        XCTAssertTrue(exportText.hasSuffix("\n# Current log\n" + text))
        XCTAssertFalse(exportText.contains("# Previous rotated log"))
    }

    func testRawLogRotationReplacesPreviousOnlyAtOriginalThreshold() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.log")
        let previous = root.appendingPathComponent("previous.log")
        let storage = IM4Data.RotatingLogFileStorage(directoryURL: root, logURL: current, previousLogURL: previous)
        try storage.prepareForAppend(maximumBytes: 4)
        XCTAssertNil(storage.currentText())
        try storage.append(Data("1234".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        try storage.prepareForAppend(maximumBytes: 4)
        XCTAssertEqual(storage.previousText(), "1234")
        XCTAssertNil(storage.currentText())
        try storage.append(Data("next".utf8))
        try storage.prepareForAppend(maximumBytes: 4)
        XCTAssertEqual(storage.previousText(), "next")
        try storage.append(Data([0xff, 0x61]))
        XCTAssertEqual(storage.currentText(), "�a")
    }

    func testDiagnosticDirectoryFailureDoesNotAdvanceSequenceOrEscapeAppend() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("RTCCallDiagnostics")
        try Data("blocker".utf8).write(to: blocked)
        let logger = RTCCallDiagnosticLogStore(baseURL: root)
        await logger.append(category: "failed", message: "not-written")
        XCTAssertEqual(try Data(contentsOf: blocked), Data("blocker".utf8))
        try FileManager.default.removeItem(at: blocked)
        await logger.append(category: "recovered", message: "written")
        let text = try String(contentsOf: blocked.appendingPathComponent("rtc-call-diagnostics.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("seq=1 media=unknown [recovered] written"))
        XCTAssertFalse(text.contains("not-written"))
    }

    func testTypedArchiveReadsOriginalSchemaAndMigratesDefaultsWithoutChangingScopePolicy() throws {
        let suite = "M17Archive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = temporaryRoot()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("archive.json")
        let first = record("first"), second = record("second")
        let rawRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
        let legacy = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "recordsByScope": ["tenant|uid": [rawRecord]]])
        defaults.set(legacy, forKey: "m17")
        let store = UserDefaultsCallRecordStore(defaults: defaults, storageKey: "m17", archiveURL: url, maxStoredRecords: 1)
        XCTAssertEqual(store.load(scope: " \ntenant|uid "), [first])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.save([second, first], scope: " tenant|uid ")
        XCTAssertEqual(store.load(scope: "tenant|uid"), [second])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "recordsByScope"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let scopes = try XCTUnwrap(object["recordsByScope"] as? [String: Any])
        XCTAssertEqual(Set(scopes.keys), ["tenant|uid"])
    }

    func testArchiveCorruptionUnsupportedSchemaAndEncodingFailureKeepOldBytes() throws {
        let suite = "M17ArchiveInvalid.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("archive.json")
        let store = UserDefaultsCallRecordStore(defaults: defaults, storageKey: "m17", archiveURL: url)
        for bytes in [Data("broken-json".utf8), Data(#"{"schemaVersion":99,"recordsByScope":{}}"#.utf8)] {
            try bytes.write(to: url)
            defaults.set(bytes, forKey: "m17")
            XCTAssertTrue(store.load(scope: "tenant|uid").isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(defaults.data(forKey: "m17"), bytes)
        }
        defaults.removeObject(forKey: "m17")
        try FileManager.default.removeItem(at: url)
        store.save([record("good")], scope: "tenant|uid")
        let diskBefore = try Data(contentsOf: url), defaultsBefore = defaults.data(forKey: "m17")
        store.save([record("invalid", duration: .infinity)], scope: "tenant|uid")
        store.save([record("ignored")], scope: " \n ")
        XCTAssertEqual(try Data(contentsOf: url), diskBefore)
        XCTAssertEqual(defaults.data(forKey: "m17"), defaultsBefore)
        XCTAssertEqual(store.load(scope: "tenant|uid"), [record("good")])
    }

    func testArchiveDiskPriorityAndLastScopeDeletionKeepOriginalOrder() throws {
        let suite = "M17ArchivePriority.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = temporaryRoot()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("archive.json")
        let store = UserDefaultsCallRecordStore(defaults: defaults, storageKey: "m17", archiveURL: url)
        store.save([record("disk")], scope: "a")
        let diskBytes = try Data(contentsOf: url)
        let defaultsOnly = UserDefaultsCallRecordStore(defaults: defaults, storageKey: "m17")
        defaultsOnly.save([record("defaults")], scope: "a")
        let defaultsBytes = defaults.data(forKey: "m17")
        XCTAssertEqual(store.load(scope: "a"), [record("disk")])
        XCTAssertEqual(try Data(contentsOf: url), diskBytes)
        XCTAssertEqual(defaults.data(forKey: "m17"), defaultsBytes)
        store.save([record("other")], scope: "b")
        store.save([], scope: "a")
        XCTAssertEqual(store.load(scope: "b"), [record("other")])
        XCTAssertNotNil(defaults.data(forKey: "m17"))
        store.save([], scope: "b")
        XCTAssertNil(defaults.data(forKey: "m17"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDiskWriteFailurePreservesDefaultsCommitAndBlockingFile() throws {
        let suite = "M17ArchiveFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let blocker = root.appendingPathComponent("blocked")
        try Data("keep".utf8).write(to: blocker)
        var errors = 0
        let storage = IM4Data.CallRecordArchiveStorage(defaults: defaults, storageKey: "m17",
            archiveURL: blocker.appendingPathComponent("archive.json"), onDiskWriteFailure: { _ in errors += 1 })
        storage.save([record("saved")], scope: "scope")
        XCTAssertEqual(errors, 1)
        XCTAssertNotNil(defaults.data(forKey: "m17"))
        XCTAssertEqual(try Data(contentsOf: blocker), Data("keep".utf8))
        let defaultsOnly = IM4Data.CallRecordArchiveStorage(defaults: defaults, storageKey: "m17", archiveURL: nil)
        XCTAssertEqual(defaultsOnly.records(scope: "scope"), [record("saved")])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m17-io-\(UUID().uuidString)", isDirectory: true)
    }

    private func record(_ id: String, duration: Double = 30) -> CallRecord {
        CallRecord(id: id, callID: "call-" + id, peerID: "peer", title: "Peer", subtitle: "Call",
                   time: "12:00", status: "Ended", durationSeconds: duration)
    }
}
// WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111_END

// WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111_BEGIN
extension DomainStoreTests {
    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
    func testColdLoginCallArchiveKeepsPendingRecordsAcrossScopeSwitchAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("call-archive-" + UUID().uuidString)
        let suite = "CallArchive." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("call-records.json")
        let adapter = UserDefaultsCallRecordStore(defaults: defaults, storageKey: "test.callRecords", archiveURL: url)
        let scopeReader = AppState(biometricDefaults: defaults, protectedSessionStore: InMemoryProtectedSessionStore(),
            registrationSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: makeIsolatedAPIContext())
        let tenant = UUID().uuidString
        var a = makeAuthenticatedAPIContext(accountID: "a", imUID: "uid-a")
        a.tenantID = tenant
        a.deviceID = UUID().uuidString
        var b = makeAuthenticatedAPIContext(accountID: "b", imUID: "uid-b")
        b.tenantID = tenant
        b.deviceID = a.deviceID
        let retiredScopeHash = try LocalMessageScope(context: a).scopeHash
        let mediaRegistry = IOSMediaCacheStoreRegistry()
        let scopeA = scopeReader.callRecordDataScopeKey(for: a)
        let scopeB = scopeReader.callRecordDataScopeKey(for: b)
        let seedA = CallRecord(id: "seed-a", callID: "seed-a", title: "A on disk", subtitle: "Archived",
            time: "10:00", status: "ended")
        let seedB = CallRecord(id: "seed-b", callID: "seed-b", title: "B on disk", subtitle: "Archived",
            time: "10:10", status: "ended")
        let untrusted = "v2|bundle=shared"
        adapter.save([seedA], scope: scopeA)
        let retainedB = CallRecord(id: "older-b", callID: "older-b", title: "Older B", subtitle: "Archived",
            time: "09:10", status: "ended")
        adapter.save([seedB, retainedB], scope: scopeB)
        adapter.save([seedA], scope: untrusted)

        let entered = expectation(description: "normal login is waiting on the original archive")
        let archive = GatedCallArchive(store: adapter, blockedScope: scopeA, entered: entered)
        defer { archive.release() }
        func coldLaunch(_ context: IMAPIContext, store: CallStore) -> AppState {
            let protectedStore = InMemoryProtectedSessionStore()
            XCTAssertTrue(context.save(sessionStore: protectedStore).isCommitted)
            let state = AppState(api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])),
                realtimeClient: RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: FakeRealtimeWebSocketTask()),
                    networkMonitorFactory: nil), voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
                callStore: store, messagePersistence: MessagePersistenceCoordinator(
                    applicationSupportBase: root.appendingPathComponent("messages"),
                    cachesBase: root.appendingPathComponent("caches"), scopeRetirementMediaRegistry: mediaRegistry),
                biometricDefaults: defaults, protectedSessionStore: protectedStore,
                registrationSessionStore: InMemoryProtectedSessionStore(), launchUnitTestOverride: false)
            XCTAssertTrue(state.isAuthenticated)
            XCTAssertTrue(state.callStore.hasCallRecordPersistenceBinding)
            XCTAssertNotNil(state.coldLaunchSessionRestoreTask)
            state.coldLaunchSessionRestoreTask?.cancel()
            return state
        }
        func addRecord(_ id: String, state: AppState) {
            state.upsertVoiceCallRecord(callID: id, title: id, subtitle: "语音呼出 · 通话已结束",
                status: "已结束", direction: .outgoing)
        }

        let state = coldLaunch(a, store: CallStore(callRecordStore: archive))
        addTeardownBlock { [retiringContext = a, persistence = state.messagePersistence] in
            await persistence.waitForScheduledScopePurge(scopeHash: retiredScopeHash)
            guard try !persistence.hasPendingScopeCleanup(context: retiringContext) else {
                XCTFail("Private message scope retirement did not finish")
                return
            }
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
        }
        await fulfillment(of: [entered], timeout: 4)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        addRecord("new-a", state: state)
        XCTAssertEqual(state.callStore.calls.compactMap(\.callID), ["new-a"])

        let publishedB = expectation(description: "replacement binding publishes its restored plus pending records")
        var seen: [[String]] = []
        let observation = state.callStore.$calls.dropFirst().sink { records in
            let ids = records.compactMap(\.callID)
            seen.append(ids)
            if ids == ["new-b", "seed-b", "older-b"] { publishedB.fulfill() }
        }
        state.overrideAPIContextForTesting(b)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        state.ensureCallRecordPersistenceBindingIfNeeded()
        let rollback = state.callStore.makeCallRecordRollback(callID: "seed-b")
        addRecord("seed-b", state: state)
        addRecord("new-b", state: state)
        XCTAssertEqual(state.callStore.calls.compactMap(\.callID), ["new-b", "seed-b"])
        archive.release()
        await fulfillment(of: [publishedB], timeout: 4)
        observation.cancel()
        XCTAssertFalse(seen.joined().contains("new-a"))
        XCTAssertFalse(seen.joined().contains("seed-a"))
        rollback()
        XCTAssertEqual(state.callStore.calls.first(where: { $0.callID == "seed-b" }), seedB)
        XCTAssertEqual(state.callStore.calls.compactMap(\.callID), ["new-b", "seed-b", "older-b"])
        addRecord("saved-b", state: state)
        state.callStore.reset()
        XCTAssertTrue(state.callStore.calls.isEmpty)

        let restarted = coldLaunch(b, store: CallStore(callRecordStore: archive))
        let ready = expectation(description: "second normal login reads the written archive")
        let reopened = restarted.callStore.$calls.filter { !$0.isEmpty }.prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 4)
        reopened.cancel()
        XCTAssertEqual(restarted.callStore.calls.compactMap(\.callID), ["saved-b", "new-b", "seed-b", "older-b"])
        XCTAssertEqual(adapter.load(scope: scopeA).compactMap(\.callID), ["new-a", "seed-a"])
        XCTAssertEqual(adapter.load(scope: untrusted), [seedA])
        let operations = archive.operations
        XCTAssertTrue(operations.allSatisfy { !$0.onMainThread })
        XCTAssertTrue(operations.contains { $0.scope == scopeA && $0.write })
        XCTAssertTrue(operations.contains { $0.scope == scopeB && $0.write })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let stages = operations.map { [
            "fixtureScope": $0.scope == scopeA ? "A" : "B",
            "write": $0.write,
            "onMainThread": $0.onMainThread
        ] as [String: Any] }
        let trace = XCTAttachment(data: try JSONSerialization.data(withJSONObject: stages),
            uniformTypeIdentifier: "public.json")
        trace.name = "call-archive-normal-login-reopen-and-scope-io"
        trace.lifetime = .keepAlways
        add(trace)
        restarted.callStore.reset()
    }
    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END

    func testAccountContextChangeImmediatelyDetachesPreviousCallHistory() {
        var contextA = makeIsolatedAPIContext()
        contextA.accountID = "call-isolation-account-a"
        contextA.tenantID = "call-isolation-tenant"
        contextA.imUID = "call-isolation-uid-a"
        contextA.imToken = "fixture-token-a"
        let state = AppState(apiContextOverride: contextA)
        state.callStore.calls = [CallRecord(id: "a-record", title: "Fixture A",
                                           subtitle: "已结束", time: "12:30", status: "已结束")]
        var contextB = contextA
        contextB.accountID = "account-b"
        contextB.imUID = "uid-b"
        contextB.imToken = "fixture-token-b"
        state.overrideAPIContextForTesting(contextB)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        XCTAssertFalse(state.callStore.hasCallRecordPersistenceBinding)
    }

    func testCallRecordStoreRestoresFromDiskWhenDefaultsAreCleared() throws {
        let suiteName = "CallRecordDiskPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("call-records-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }
        let scope = "bundle=app1|tenant=a|uid=u"
        let record = CallRecord(
            id: "disk-record",
            callID: "disk-call",
            peerID: "peer-disk",
            title: "Alice",
            subtitle: "语音呼出 · 通话已结束",
            time: "12:00",
            status: "已结束",
            direction: .outgoing,
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 330),
            durationSeconds: 30
        )
        let store = UserDefaultsCallRecordStore(
            defaults: defaults,
            storageKey: "call.records.disk.test",
            archiveURL: archiveURL
        )
        store.save([record], scope: scope)
        XCTAssertEqual(store.load(scope: scope).first?.callID, "disk-call")

        defaults.removePersistentDomain(forName: suiteName)
        let relaunchedStore = UserDefaultsCallRecordStore(
            defaults: defaults,
            storageKey: "call.records.disk.test",
            archiveURL: archiveURL
        )

        let relaunchedRecord = try XCTUnwrap(relaunchedStore.load(scope: scope).first)
        XCTAssertEqual(relaunchedRecord.callID, "disk-call")
        XCTAssertEqual(relaunchedRecord.peerID, "peer-disk")
        XCTAssertEqual(relaunchedRecord.startedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(relaunchedRecord.endedAt, Date(timeIntervalSince1970: 330))
        XCTAssertEqual(relaunchedRecord.durationSeconds, 30)
    }
}

// WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_BEGIN
private final class GatedCallArchive: CallRecordPersisting {
    struct Operation {
        let scope: String
        let write: Bool
        let onMainThread: Bool
    }

    private let store: UserDefaultsCallRecordStore
    private let blockedScope: String
    private let entered: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var events: [Operation] = []

    init(store: UserDefaultsCallRecordStore, blockedScope: String, entered: XCTestExpectation) {
        self.store = store
        self.blockedScope = blockedScope
        self.entered = entered
    }

    var operations: [Operation] { lock.withLock { events } }

    func load(scope: String) -> [CallRecord] {
        let firstBlockedRead = lock.withLock {
            let block = scope == blockedScope && !events.contains { $0.scope == scope }
            events.append(Operation(scope: scope, write: false, onMainThread: Thread.isMainThread))
            return block
        }
        if firstBlockedRead {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 8), .success)
        }
        return store.load(scope: scope)
    }

    func save(_ records: [CallRecord], scope: String) {
        lock.withLock { events.append(Operation(scope: scope, write: true, onMainThread: Thread.isMainThread)) }
        store.save(records, scope: scope)
    }

    func release() { gate.signal() }
}
// WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_END
// WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111_END

@testable import IM4Domain
import Foundation
// WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112_BEGIN
import Combine
import SwiftUI
import UIKit
// WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112_END
import XCTest
@testable import WenDaTong

final class BatchForwardStateTests: XCTestCase {
    private static let clientBatchA = "11111111-1111-4111-8111-111111111111"
    private static let clientBatchB = "22222222-2222-4222-8222-222222222222"

    private let scope = BatchForwardScope(
        tenantID: "tenant-a",
        actorUID: "actor-a",
        sourceChannelID: "source-a",
        sourceChannelType: "group"
    )

    private func message(
        _ id: String,
        sender: String? = "actor-a",
        provenance: BatchForwardSenderProvenance = .authoritativeStored,
        seq: Int64? = nil,
        page: Int? = nil,
        kind: String = "text",
        contentType: String = "",
        nested: [String] = [],
        fileName: String = "",
        mimeType: String = ""
    ) -> BatchForwardMessageSnapshot {
        BatchForwardMessageSnapshot(
            messageID: id,
            sourceChannelID: "source-a",
            sourceChannelType: "group",
            senderUID: sender,
            senderProvenance: provenance,
            channelSeq: seq,
            createdAtMillis: 1_000,
            historyPage: page,
            contentType: contentType,
            kind: kind,
            nestedSemanticMarkers: nested,
            fileName: fileName,
            mimeType: mimeType
        )
    }

    private func target(_ id: String, type: String = "direct") -> BatchForwardTarget {
        BatchForwardTarget(
            channelID: id,
            channelType: type,
            displayName: id,
            searchTerms: ["alias-\(id)"]
        )
    }

    private func readyCommand(
        _ state: inout BatchForwardState,
        generatedID: String = BatchForwardStateTests.clientBatchA
    ) -> BatchForwardSubmitCommand {
        guard case let .ready(command) = state.beginSubmission(makeClientBatchID: { generatedID }) else {
            XCTFail("expected ready")
            fatalError("expected ready")
        }
        return command
    }

    func testSourceClickOrderNeverBecomesDeliveryAuthorityAcrossPages() {
        let messages = [
            message("z-earliest", seq: 8, page: 2),
            message("m-tied-later", seq: 9, page: 1),
            message("a-tied-earlier", seq: 9, page: 2),
            message("b-latest", seq: 10, page: 1),
        ]
        var requests: [[String]] = []
        for order in [
            ["a-tied-earlier", "z-earliest", "b-latest", "m-tied-later"],
            ["b-latest", "m-tied-later", "z-earliest", "a-tied-earlier"],
            ["m-tied-later", "a-tied-earlier", "b-latest", "z-earliest"],
        ] {
            var state = BatchForwardState(scope: scope)
            state.ingestSourcePage(messages.filter { $0.messageID == order.first! })
            XCTAssertEqual(state.toggleSource(order.first!), .selected)
            state.ingestSourcePage(messages.filter { $0.messageID != order.first! })
            for id in order.dropFirst() {
                XCTAssertEqual(state.toggleSource(id), .selected)
            }
            XCTAssertEqual(state.selectedSourceIDsInClickOrder, order)
            let destination = target("friend-a")
            state.ingestTargets([destination])
            XCTAssertEqual(state.toggleTarget(destination.identityKey(actorUID: scope.actorUID)), .selected)
            requests.append(readyCommand(&state).request.sourceMessageIDs)
        }
        XCTAssertEqual(requests, [
            ["z-earliest", "a-tied-earlier", "m-tied-later", "b-latest"],
            ["z-earliest", "a-tied-earlier", "m-tied-later", "b-latest"],
            ["z-earliest", "a-tied-earlier", "m-tied-later", "b-latest"],
        ])
    }

    // WDT_IOS1_D583_UI_SOURCE_CONTRACTS_20261112_BEGIN
    func testMessageRowOnlyEvaluatesBatchStateInActiveSelectionMode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let timeline = try String(contentsOf: root.appendingPathComponent("WenDaTong/App/ChatTimelineAssembly.swift"), encoding: .utf8)
        let start = try XCTUnwrap(timeline.range(of: "private func messageRowView("))
        let end = try XCTUnwrap(timeline.range(of: "private var messageListBottomAnchor:", range: start.upperBound..<timeline.endIndex))
        let row = timeline[start.upperBound..<end.lowerBound]
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        // Ordinary rows skip eligibility and selected-ID membership. Active rows pass both values to the real decoration.
        XCTAssertTrue(row.contains(
            "let batchDisabledReason = isBatchForwardSelectionActive ? batchForwardDisabledReason(for: row.message) : nil"
        ))
        XCTAssertTrue(row.contains(
            "let batchSelected = isBatchForwardSelectionActive && batchForwardSelectedSourceIDs.contains(row.message.id)"
        ))
        XCTAssertEqual(row.components(separatedBy: "batchForwardDisabledReason(for:").count - 1, 1)
        XCTAssertEqual(row.components(separatedBy: "batchForwardSelectedSourceIDs.contains(").count - 1, 1)
        XCTAssertFalse(row.contains("batchForwardEligibility("))
        XCTAssertTrue(row.contains(
            "isBatchSelectionActive: isBatchForwardSelectionActive, batchSelected: batchSelected, batchDisabledReason: batchDisabledReason, toggleSelection: actions.toggleSelection"
        ))
        XCTAssertTrue(row.contains("onSelectionTap: isBatchForwardSelectionActive ? { actions.toggleSelection() } : nil"))

        let layout = try String(contentsOf: root.appendingPathComponent("Sources/IM4Features/Chat/ChatTimelineLayout.swift"), encoding: .utf8)
        let decorationStart = try XCTUnwrap(layout.range(of: "public struct ChatTimelineRowDecoration<"))
        let decorationEnd = try XCTUnwrap(layout.range(of: "public struct ChatTimelineItemLayout<", range: decorationStart.upperBound..<layout.endIndex))
        let decoration = layout[decorationStart.upperBound..<decorationEnd.lowerBound]
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(decoration.contains("if isBatchSelectionActive { Button { toggleSelection() }"))
        XCTAssertTrue(decoration.contains("systemName: batchSelected ? \"checkmark.circle.fill\" : (batchDisabledReason == nil ? \"circle\" : \"nosign\")"))
        XCTAssertTrue(decoration.contains(".disabled(batchDisabledReason != nil)"))
        XCTAssertTrue(decoration.contains("if isBatchSelectionActive, let batchDisabledReason { Text(batchDisabledReason)"))
    }
    // WDT_IOS1_D583_UI_SOURCE_CONTRACTS_20261112_END

    func testBatchSelectionRejectsRTCCallRecordsButAllowsText() {
        var state = BatchForwardState(scope: scope)
        let text = message("text")
        let call = message("call", contentType: "rtc_call_record")
        state.ingestSourcePage([text, call])

        XCTAssertEqual(BatchForwardSemantics.eligibility(of: text, actorUID: scope.actorUID), .selectable)
        XCTAssertEqual(
            BatchForwardSemantics.eligibility(of: call, actorUID: scope.actorUID),
            .disabled("该消息类型不可转发")
        )
        XCTAssertEqual(state.toggleSource("text"), .selected)
        XCTAssertEqual(state.toggleSource("call"), .rejected("该消息类型不可转发"))
        XCTAssertEqual(state.selectedSourceIDSet, ["text"])
        let destination = target("friend-a")
        state.ingestTargets([destination])
        XCTAssertEqual(state.toggleTarget(destination.identityKey(actorUID: scope.actorUID)), .selected)
        XCTAssertEqual(readyCommand(&state).request.sourceMessageIDs, ["text"])
    }

    func testReenteringBatchSelectionRechecksUpdatedEligibility() {
        var state = BatchForwardState(scope: scope)
        state.ingestSourcePage([message("voice", kind: "voice")])
        XCTAssertEqual(state.toggleSource("voice"), .selected)
        XCTAssertEqual(state.toggleSource("voice"), .removed)
        XCTAssertTrue(state.selectedSourceIDSet.isEmpty)

        state.ingestSourcePage([message("voice", sender: "other", kind: "voice")])
        XCTAssertEqual(state.toggleSource("voice"), .rejected(batchForwardVoiceOwnershipReason))
        XCTAssertTrue(state.selectedSourceIDSet.isEmpty)

        state.ingestSourcePage([message("voice", kind: "voice")])
        XCTAssertEqual(state.toggleSource("voice"), .selected)
    }

    func testVoiceOwnershipUsesOnlyAuthoritativeStoredSenderAndExactCopy() {
        let cases: [(BatchForwardMessageSnapshot, BatchForwardEligibility)] = [
            (message("self", kind: "voice"), .selectable),
            (
                message(
                    "other",
                    sender: "other",
                    kind: "voice",
                    contentType: "audio",
                    mimeType: "audio/mpeg"
                ),
                .disabled(batchForwardVoiceOwnershipReason)
            ),
            (
                message("unknown", sender: nil, provenance: .unknown, kind: "voice"),
                .disabled(batchForwardVoiceOwnershipReason)
            ),
            (
                message("forged", provenance: .clientSupplied, kind: "voice"),
                .disabled(batchForwardVoiceOwnershipReason)
            ),
            (
                message("audio-note-other", sender: "other", kind: "audio_note"),
                .disabled(batchForwardVoiceOwnershipReason)
            ),
            (
                message("voice-clip-other", sender: "other", contentType: "voice_clip"),
                .disabled(batchForwardVoiceOwnershipReason)
            ),
            (
                message(
                    "voice-note-unknown",
                    sender: nil,
                    provenance: .unknown,
                    kind: "voice_note"
                ),
                .disabled(batchForwardVoiceOwnershipReason)
            ),
            (
                message(
                    "voicemessage-client-supplied",
                    provenance: .clientSupplied,
                    nested: ["payload.voicemessage"]
                ),
                .disabled(batchForwardVoiceOwnershipReason)
            ),
            (message("nested-self", nested: ["payload.voice"]), .selectable),
            (
                message(
                    "legacy-other",
                    sender: "other",
                    fileName: "voice-123.m4a",
                    mimeType: "audio/mp4"
                ),
                .disabled(batchForwardVoiceOwnershipReason)
            ),
            (
                message(
                    "generic-audio",
                    sender: nil,
                    provenance: .unknown,
                    kind: "audio",
                    contentType: "audio",
                    mimeType: "audio/mpeg"
                ),
                .selectable
            ),
        ]
        for (snapshot, expected) in cases {
            XCTAssertEqual(
                BatchForwardSemantics.eligibility(of: snapshot, actorUID: "actor-a"),
                expected,
                snapshot.messageID
            )
        }
        XCTAssertEqual(batchForwardVoiceOwnershipReason, "仅可转发自己发送的语音")
    }

    func testTabsSearchExpansionAndSelectionAreIndependent() {
        var state = BatchForwardState(scope: scope)
        let friendA = target("friend-a")
        let friendB = target("friend-b")
        let groupA = target("group-a", type: "group")
        state.ingestTargets([friendA, friendB, groupA])
        XCTAssertEqual(state.toggleTarget(friendA.identityKey(actorUID: scope.actorUID)), .selected)
        state.setTargetSearchQuery("alias-friend-b")
        XCTAssertEqual(state.visibleTargets(candidates: [friendA, friendB, groupA]).map(\.channelID), ["friend-b"])
        state.setActiveTargetTab(.group)
        state.setTargetSearchQuery("")
        XCTAssertEqual(state.visibleTargets(candidates: [friendA, friendB, groupA]).map(\.channelID), ["group-a"])
        state.setActiveTargetTab(.friend)
        state.setTargetTabExpanded(.friend, expanded: false)
        XCTAssertEqual(
            state.visibleTargets(candidates: [friendA, friendB], initialLimit: 1).map(\.channelID),
            ["friend-a"]
        )
        state.setTargetTabExpanded(.friend, expanded: true)
        XCTAssertEqual(state.visibleTargets(candidates: [friendA, friendB], initialLimit: 1).count, 2)
        XCTAssertEqual(state.selectedTargets.map(\.channelID), ["actor-a:friend-a"])
    }

    func testRetryDoubleTapReconnectReuseKeyAndIntentChangeRotatesIt() {
        var state = BatchForwardState(scope: scope)
        state.ingestSourcePage([message("m1")])
        let first = target("friend-a")
        let second = target("friend-b")
        state.ingestTargets([first, second])
        XCTAssertEqual(state.toggleSource("m1"), .selected)
        XCTAssertEqual(state.toggleTarget(first.identityKey(actorUID: scope.actorUID)), .selected)

        let initial = readyCommand(&state, generatedID: Self.clientBatchA)
        XCTAssertEqual(initial.headers["Idempotency-Key"], Self.clientBatchA)
        XCTAssertEqual(
            state.beginSubmission(makeClientBatchID: { Self.clientBatchB }),
            .ignoredInFlight
        )

        state.markUncertain("connection dropped")
        let reconnect = readyCommand(&state, generatedID: Self.clientBatchB)
        XCTAssertEqual(reconnect.request.clientBatchID, Self.clientBatchA)
        state.markRetryableFailure("retry")
        state.setTargetSearchQuery("anything")
        let retry = readyCommand(&state, generatedID: Self.clientBatchB)
        XCTAssertEqual(retry.request.clientBatchID, Self.clientBatchA)

        state.markRetryableFailure()
        XCTAssertEqual(state.toggleTarget(second.identityKey(actorUID: scope.actorUID)), .selected)
        let changed = readyCommand(&state, generatedID: Self.clientBatchB)
        XCTAssertEqual(changed.request.clientBatchID, Self.clientBatchB)
    }

    func testFrozenTopLevelWireShapeAndStrictRFC4122UUID() throws {
        var state = BatchForwardState(scope: scope)
        state.ingestSourcePage([message("m1")])
        let destination = target("friend-a")
        state.ingestTargets([destination])
        XCTAssertEqual(state.toggleSource("m1"), .selected)
        XCTAssertEqual(state.toggleTarget(destination.identityKey(actorUID: scope.actorUID)), .selected)
        XCTAssertEqual(
            state.beginSubmission(makeClientBatchID: { "not-a-uuid" }),
            .invalid("client_batch_id 必须是 RFC4122 UUID")
        )
        XCTAssertNil(state.clientBatchID)

        let command = readyCommand(&state, generatedID: Self.clientBatchA.uppercased())
        XCTAssertEqual(command.request.clientBatchID, Self.clientBatchA)
        XCTAssertEqual(command.headers["Idempotency-Key"], Self.clientBatchA)
        XCTAssertEqual(state.clientBatchID, Self.clientBatchA)
        let data = try JSONEncoder().encode(command.request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "client_batch_id",
                "source_channel_id",
                "source_channel_type",
                "source_message_ids",
                "targets",
                "mode",
            ]
        )
        XCTAssertNil(object["contract_version"])
        XCTAssertNil(object["source"])
        XCTAssertEqual(object["source_message_ids"] as? [String], ["m1"])
    }

    func testScopeIDsTypesAndUnknownOrSystemContentFailClosed() {
        XCTAssertEqual(
            BatchForwardSemantics.eligibility(
                of: message("unknown", kind: "future_unknown"),
                actorUID: "actor-a"
            ),
            .disabled("该消息类型不可转发")
        )
        XCTAssertEqual(
            BatchForwardSemantics.eligibility(
                of: message("system", nested: ["payload.system"]),
                actorUID: "actor-a"
            ),
            .disabled("该消息类型不可转发")
        )

        var blankSourceID = BatchForwardState(scope: scope)
        blankSourceID.ingestSourcePage([message("")])
        let destination = target("friend-a")
        blankSourceID.ingestTargets([destination])
        XCTAssertEqual(blankSourceID.toggleSource(""), .selected)
        XCTAssertEqual(blankSourceID.toggleTarget(destination.identityKey(actorUID: scope.actorUID)), .selected)
        XCTAssertEqual(
            blankSourceID.beginSubmission(makeClientBatchID: { Self.clientBatchA }),
            .invalid("source_message_id 不能为空")
        )

        var blankTargetID = BatchForwardState(scope: scope)
        blankTargetID.ingestSourcePage([message("m1")])
        let blankTarget = target("")
        blankTargetID.ingestTargets([blankTarget])
        XCTAssertEqual(blankTargetID.toggleSource("m1"), .selected)
        XCTAssertEqual(blankTargetID.toggleTarget(blankTarget.identityKey(actorUID: scope.actorUID)), .selected)
        XCTAssertEqual(
            blankTargetID.beginSubmission(makeClientBatchID: { Self.clientBatchA }),
            .invalid("目标会话类型不受支持")
        )

        let invalidScope = BatchForwardScope(
            tenantID: "",
            actorUID: "actor-a",
            sourceChannelID: "source-a",
            sourceChannelType: "group"
        )
        var incomplete = BatchForwardState(scope: invalidScope)
        incomplete.ingestSourcePage([message("m1")])
        incomplete.ingestTargets([destination])
        XCTAssertEqual(incomplete.toggleSource("m1"), .selected)
        XCTAssertEqual(incomplete.toggleTarget(destination.identityKey(actorUID: invalidScope.actorUID)), .selected)
        XCTAssertEqual(
            incomplete.beginSubmission(makeClientBatchID: { Self.clientBatchA }),
            .invalid("批量转发作用域不完整")
        )
    }

    func testStaleMixedVoiceFailsBeforeSubmissionAndPreservesDraft() {
        var state = BatchForwardState(scope: scope)
        state.ingestSourcePage([
            message("voice", kind: "voice"),
            message("text"),
        ])
        let destination = target("friend-a")
        state.ingestTargets([destination])
        XCTAssertEqual(state.toggleSource("voice"), .selected)
        XCTAssertEqual(state.toggleSource("text"), .selected)
        XCTAssertEqual(state.toggleTarget(destination.identityKey(actorUID: scope.actorUID)), .selected)

        state.ingestSourcePage([message("voice", sender: "other", kind: "voice")])
        XCTAssertEqual(
            state.beginSubmission(makeClientBatchID: { "must-not-run" }),
            .invalid(batchForwardVoiceOwnershipReason)
        )
        XCTAssertEqual(state.selectedSourceIDSet, ["voice", "text"])
        XCTAssertNil(state.clientBatchID)
        XCTAssertTrue(state.reconciledServerMessageIDs.isEmpty)
    }

    func testPeerAndReversedDirectTargetsUseCanonicalPairThroughCommit() {
        let peer = target("peer")
        let reversed = target("peer:actor-a")
        XCTAssertEqual(
            peer.identityKey(actorUID: scope.actorUID),
            "direct|actor-a:peer"
        )
        XCTAssertEqual(
            reversed.identityKey(actorUID: scope.actorUID),
            peer.identityKey(actorUID: scope.actorUID)
        )

        var state = BatchForwardState(scope: scope)
        state.ingestSourcePage([message("m1")])
        state.ingestTargets([reversed])
        XCTAssertEqual(state.toggleSource("m1"), .selected)
        XCTAssertEqual(
            state.toggleTarget(reversed.identityKey(actorUID: scope.actorUID)),
            .selected
        )
        let command = readyCommand(&state)
        XCTAssertEqual(command.request.targets.first?.channelID, "actor-a:peer")

        let response = committedResult(
            sourceIDs: ["m1"],
            targets: [reversed],
            clientBatchID: Self.clientBatchA.uppercased()
        )
        XCTAssertEqual(state.applyCommittedResult(response), .applied)
        XCTAssertEqual(state.lastCommittedResult?.clientBatchID, Self.clientBatchA)
        XCTAssertEqual(
            state.lastCommittedResult?.targets.first?.channelID,
            "actor-a:peer"
        )
    }

    func testCommittedMappingMustBeCompleteOrderedAndAuthoritative() {
        var state = BatchForwardState(scope: scope)
        state.ingestSourcePage([message("m2"), message("m1")])
        let first = target("friend-a")
        let second = target("group-a", type: "group")
        state.ingestTargets([first, second])
        XCTAssertEqual(state.toggleSource("m2"), .selected)
        XCTAssertEqual(state.toggleSource("m1"), .selected)
        XCTAssertEqual(state.toggleTarget(first.identityKey(actorUID: scope.actorUID)), .selected)
        XCTAssertEqual(state.toggleTarget(second.identityKey(actorUID: scope.actorUID)), .selected)
        _ = readyCommand(&state)

        let malformed = committedResult(
            sourceIDs: ["m1", "m2"],
            targets: [first, second],
            secondTargetOrdinals: [1, 0]
        )
        if case .rejected = state.applyCommittedResult(malformed) {
            // Expected.
        } else {
            XCTFail("reordered source_ordinal must be rejected")
        }
        XCTAssertEqual(state.selectedSourceIDSet, ["m1", "m2"])
        XCTAssertTrue(state.reconciledServerMessageIDs.isEmpty)

        let valid = committedResult(
            sourceIDs: ["m1", "m2"],
            targets: [first, second],
            clientBatchID: Self.clientBatchA.uppercased()
        )
        XCTAssertEqual(state.applyCommittedResult(valid), .applied)
        XCTAssertTrue(state.selectedSourceIDSet.isEmpty)
        XCTAssertTrue(state.selectedTargets.isEmpty)
        XCTAssertEqual(
            state.reconciledServerMessageIDs,
            ["server-0-0", "server-0-1", "server-1-0", "server-1-1"]
        )
    }

    private func committedResult(
        sourceIDs: [String],
        targets: [BatchForwardTarget],
        secondTargetOrdinals: [Int] = [0, 1],
        clientBatchID: String = BatchForwardStateTests.clientBatchA
    ) -> BatchForwardCommittedResult {
        let targetResults = targets.enumerated().map { targetOrdinal, target in
            let ordinals = targetOrdinal == 1 ? secondTargetOrdinals : Array(sourceIDs.indices)
            return BatchForwardTargetResult(
                targetOrdinal: targetOrdinal,
                channelID: target.channelID,
                channelType: target.channelType,
                messages: ordinals.enumerated().map { index, sourceOrdinal in
                    BatchForwardCreatedMessage(
                        sourceOrdinal: sourceOrdinal,
                        sourceMessageID: sourceIDs[sourceOrdinal],
                        messageID: "server-\(targetOrdinal)-\(index)"
                    )
                }
            )
        }
        return BatchForwardCommittedResult(
            contractVersion: 1,
            batchID: "server-batch",
            clientBatchID: clientBatchID,
            sourceCount: sourceIDs.count,
            targetCount: targets.count,
            createdCount: sourceIDs.count * targets.count,
            state: "committed",
            idempotentReplay: false,
            authoritativeSourceMessageIDs: sourceIDs,
            targets: targetResults
        )
    }
}

// WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112_BEGIN
// WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110_BEGIN
extension DomainStoreTests {
    func testMountedBatchSelectionConsumesArrivingSourceBeforeActualBubbleSelection() async throws {
        let (state, _, source) = f3LiveForwardFixture(includeTail: false)
        var bubbles: [String: MessageBubble] = [:]
        ChatTimelineRenderDiagnostics.reset()
        ChatTimelineRenderDiagnostics.batchForwardBubble = { bubble in
            if bubble.conversationID == source.id { bubbles[bubble.message.id] = bubble }
        }
        let hosted = hostForSimulatorUI(NavigationView { ChatView(conversationID: source.id) }
            .navigationViewStyle(.stack).appStateEnvironment(state), size: CGSize(width: 390, height: 760))
        defer { hosted.window.isHidden = true; ChatTimelineRenderDiagnostics.reset(); state.cancelBatchForward() }
        state.beginBatchForward(conversationID: source.id, initialMessageID: "f3-a")
        try await f3Wait { bubbles["f3-a"]?.onSelectionTap != nil }
        var arrived = makeMessage(id: "f3-b", senderId: "uid-1", seq: 2, isOutgoing: true)
        arrived.senderProvenance = .authoritativeStored
        XCTAssertNotNil(state.conversationStore.appendLocalOutgoingMessage(arrived, to: source.id))
        try await f3Wait { bubbles["f3-b"]?.onSelectionTap != nil }
        let displayed = try XCTUnwrap(bubbles["f3-b"])
        XCTAssertEqual(displayed.message.id, "f3-b", "actual mounted MessageBubble rendered the arrival")
        try XCTUnwrap(displayed.onSelectionTap)()
        XCTAssertEqual(state.batchForwardState?.selectedSourceIDsInClickOrder, ["f3-a", "f3-b"])
        XCTAssertNotNil(state.batchForwardState?.sourcesByID["f3-b"])
        let before = state.batchForwardState
        var unrelated = makeConversation(id: "f3-unrelated", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        unrelated.messages = [makeMessage(id: "other", seq: 1)]
        state.conversationStore.commitConversationSnapshots(state.conversationStore.conversationMessageSnapshots() + [unrelated])
        try await Task.sleep(nanoseconds: 100_000_000)
        let stable = state.batchForwardState
        XCTAssertNotNil(state.conversationStore.updateAttachmentProgress(0.4, messageID: "other", conversationID: unrelated.id))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.batchForwardState, stable, "another message window cannot refresh this source")
        XCTAssertEqual(state.batchForwardState?.selectedSourceIDsInClickOrder, before?.selectedSourceIDsInClickOrder)
    }

    func testMountedTargetSheetRefreshesMessageOnlyEligibilityAndSubmission() async throws {
        let (state, transport, source) = f3LiveForwardFixture(includeTail: true)
        var bar: BatchForwardSelectionBar?
        ChatTimelineRenderDiagnostics.reset()
        ChatTimelineRenderDiagnostics.batchForwardBar = { bar = $0 }
        let hosted = hostForSimulatorUI(NavigationView { ChatView(conversationID: source.id) }
            .navigationViewStyle(.stack).appStateEnvironment(state), size: CGSize(width: 390, height: 760))
        defer { hosted.window.isHidden = true; ChatTimelineRenderDiagnostics.reset(); state.cancelBatchForward() }
        state.beginBatchForward(conversationID: source.id, initialMessageID: "f3-a")
        try await f3Wait { bar != nil }
        try XCTUnwrap(bar).onForward()
        try await f3Wait { hosted.controller.presentedViewController != nil }
        XCTAssertNotNil(hosted.controller.presentedViewController, "actual onForward opened its target sheet")
        let target = try XCTUnwrap(state.batchForwardTargetCandidates().first { $0.target.channelID == source.id })
        state.toggleBatchForwardTarget(target.target)
        var metadataEvents = 0
        let metadata = state.conversationStore.conversationUpdates.dropFirst().sink { _ in metadataEvents += 1 }
        defer { metadata.cancel() }
        XCTAssertTrue(state.conversationStore.applyRecall(messageID: "f3-a", conversationID: source.id))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(metadataEvents, 0, "recalling a non-tail source changed only its message window")
        XCTAssertEqual(state.batchForwardState?.sourcesByID["f3-a"]?.clientState, "recalled")
        XCTAssertEqual(state.batchForwardState?.selectedSourceIDsInClickOrder, ["f3-a"], "retain selected pages while refreshing eligibility")
        state.submitBatchForward()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(transport.requests().filter { $0.url?.path == "/api/im/messages/forward-batch" }.isEmpty,
                      "the real sheet submission method rejects the newly ineligible cached source before HTTP")
        guard transport.requests().allSatisfy({ $0.url?.path != "/api/im/messages/forward-batch" }) else { return }
        var restored = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: source.id))
        restored.messages[0] = source.messages[0]
        state.conversationStore.commitConversationSnapshot(restored, at: 0)
        try await f3Wait { state.batchForwardState?.sourcesByID["f3-a"]?.clientState == "sent" }
        XCTAssertEqual(metadataEvents, 0)
        state.submitBatchForward()
        try await f3Wait { transport.requests().contains { $0.url?.path == "/api/im/messages/forward-batch" } }
        let requests = transport.requests().filter { $0.url?.path == "/api/im/messages/forward-batch" }
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["source_message_ids"] as? [String], ["f3-a"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), body["client_batch_id"] as? String)
    }

    private func f3LiveForwardFixture(includeTail: Bool) -> (AppState, FakeHTTPTransport, ConversationMessageSnapshot) {
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"retry"}}"#.utf8),
            isHTTPResponse: true, statusCode: 503)])
        let state = AppState(api: makeCallEndingAPI(transport: transport), apiContextOverride: makeAuthenticatedAPIContext())
        var source = makeConversation(id: "f3-source", kind: .group, unread: 0,
                                      lastMsgSeq: includeTail ? 2 : 1, lastReadSeq: includeTail ? 2 : 1)
        source.hasUnreadReaction = false; source.unreadReactionCount = 0
        var first = makeMessage(id: "f3-a", senderId: "uid-1", seq: 1, isOutgoing: true)
        first.senderProvenance = .authoritativeStored
        source.messages = [first]
        if includeTail {
            var tail = makeMessage(id: "f3-tail", senderId: "uid-1", seq: 2, isOutgoing: true)
            tail.senderProvenance = .authoritativeStored; source.messages.append(tail)
        }
        state.conversationStore.updateConversationLatestFromMessages(&source)
        state.conversationStore.commitConversationSnapshots([source])
        state.tenantInteractionStore.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext)
        state.tenantInteractionStore.snapshot.actions.forwardEnabled = true
        return (state, transport, source)
    }

    private func f3Wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(condition(), "mounted batch-forward condition did not arrive")
    }
}
// WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110_END
// WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112_END

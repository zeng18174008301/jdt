import IM4Domain
import IM4Data
import UIKit
import IM4Core // WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111
import Foundation
import Combine
import SwiftUI
import XCTest
@testable import WenDaTong

// WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
extension DomainStoreTests {
    func testSingleRealtimeWireJoinsDecodeMergeAndExactStoreRevision() async throws {
        try await checkRealtimeWireInstallation(batch: false)
    }

    func testRealtimeWireBatchInstallsWithoutSingleConversationMarker() async throws {
        try await checkRealtimeWireInstallation(batch: true)
    }

    private func checkRealtimeWireInstallation(batch: Bool) async throws {
        let messageID = "single-realtime-target"
        let companionID = "batch-companion"
        let decoded = expectation(description: "the target wire envelope enters the decoder off Main")
        let codec = RecordingRealtimeWireCodec(passthrough: true) { frame, onMainThread in
            guard frame.contains(messageID) else { return }
            XCTAssertFalse(onMainThread)
            decoded.fulfill()
        }
        let fixture = try await backgroundDecodeFixture(codec: codec)
        defer { fixture.close() }
        let store = fixture.state.conversationStore
        var peer = computeRow("actor-a:other", messageID: "other-base", kind: .direct)
        peer.sortTimestamp = 40
        var target = computeRow("actor-a:peer", messageID: "base", kind: .direct)
        target.sortTimestamp = 20
        store.commitConversationSnapshots([peer, target])
        let baseRevision = store.memorySnapshot.revision
        var flow: [(event: RealtimeMessageFlowSignpost.Event, uptime: UInt64)] = []
        var samples: [MessageDerivationSample] = []
        var installed: [(revision: UInt64, incremental: Bool)] = []
        RealtimeMessageFlowSignpost.sink = { flow.append(($0, DispatchTime.now().uptimeNanoseconds)) }
        let commit = store.memoryCommits.sink { update in
            guard let window = update.messageChanges[target.id], window.current.last?.id == messageID,
                  !window.previous.contains(where: { $0.id == messageID }) else { return }
            XCTAssertEqual(store.memorySnapshot.revision, update.current.revision)
            XCTAssertEqual(store.conversations.map(\.id), [target.id, peer.id])
            let marker = store.messageMemoryStore.installedIncrementalRealtimeUpdate
            if let marker {
                XCTAssertEqual(marker.revision, update.current.revision)
                XCTAssertEqual(marker.conversationID, target.id)
            }
            if batch { XCTAssertEqual(update.messageChanges[peer.id]?.current.last?.id, companionID) }
            installed.append((update.current.revision, marker != nil))
        }
        let done = expectation(description: "single message completes its normal realtime timer and worker")
        fixture.state.realtimeComputeRuntime.onDerivation = {
            samples += $0
            guard let arrival = flow.first(where: { $0.event.stage == .arrival }) else { return }
            if $0.contains(where: { $0.phase == .commit && $0.context.sourceCorrelations.contains(arrival.event.correlation) }) {
                done.fulfill()
            }
        }
        defer {
            RealtimeMessageFlowSignpost.sink = nil
            fixture.state.realtimeComputeRuntime.onDerivation = nil
            commit.cancel()
        }
        var message = computeMessage(messageID, sequence: 2, channel: target.id)
        message["channel_type"] = "direct"
        let packet: [String: Any] = ["type": "message", "payload": ["message": message]]
        let wire: String
        if batch {
            var companion = computeMessage(companionID, sequence: 2, channel: peer.id, sender: "other")
            companion["channel_type"] = "direct"
            companion["created_at"] = "2026-11-09T01:00:00Z"
            wire = try computeBatch([packet, ["type": "message", "payload": ["message": companion]]])
        } else {
            wire = try computeObject(packet)
        }
        fixture.socket.enqueue(.string(wire))
        fixture.start()
        await fulfillment(of: [decoded, done], timeout: 6)
        let arrival = try XCTUnwrap(flow.first { $0.event.stage == .arrival })
        let installedFlow = try XCTUnwrap(flow.first {
            $0.event.stage == .storeInstalled && $0.event.correlation == arrival.event.correlation
        })
        let chain = samples.filter { $0.context.sourceCorrelations.contains(arrival.event.correlation) }
        let capture = try XCTUnwrap(chain.first { $0.phase == .capture })
        let merge = try XCTUnwrap(chain.first { $0.phase == .merging })
        let install = try XCTUnwrap(chain.first { $0.phase == .storeInstalled })
        XCTAssertEqual(try XCTUnwrap(installedFlow.event.revision), baseRevision + 1)
        XCTAssertEqual(installed.map(\.revision), [baseRevision + 1])
        let installedFrame = try XCTUnwrap(installed.first)
        XCTAssertEqual(installedFrame.revision, installedFlow.event.revision)
        XCTAssertEqual(installedFrame.incremental, !batch, "Only the single-message frame uses incremental installation")
        XCTAssertEqual(install.outputRevision, installedFlow.event.revision)
        XCTAssertEqual(chain.filter { $0.phase == .merging }.count, batch ? 2 : 1)
        XCTAssertFalse(merge.onMainThread)
        XCTAssertTrue(install.onMainThread)
        XCTAssertLessThanOrEqual(arrival.uptime, capture.uptimeNanoseconds)
        XCTAssertLessThanOrEqual(capture.uptimeNanoseconds, merge.uptimeNanoseconds)
        XCTAssertLessThanOrEqual(merge.uptimeNanoseconds, install.uptimeNanoseconds)
        XCTAssertEqual(store.conversationMessageSnapshot(id: target.id)?.messages.last?.id, messageID)
        struct Timing: Encodable {
            let sourceCorrelation: UInt64
            let postDecodeArrivalUptimeNs: UInt64
            let storeInstalledUptimeNs: UInt64
            let incrementalInstallation: Bool
            let stages: [MessageDerivationSample]
        }
        let timing = Timing(sourceCorrelation: arrival.event.correlation, postDecodeArrivalUptimeNs: arrival.uptime,
            storeInstalledUptimeNs: installedFlow.uptime, incrementalInstallation: installedFrame.incremental,
            stages: chain)
        let measurement = XCTAttachment(data: try JSONEncoder().encode(timing), uniformTypeIdentifier: "public.json")
        measurement.name = batch ? "batch-realtime-derivation" : "single-realtime-derivation"
        measurement.lifetime = .keepAlways; add(measurement)
    }
}
// WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension DomainStoreTests {
    func testRealtimeComputeActualWireMatchesOriginalAlgorithmsAndDurableAck() async throws {
        var results: [[ConversationMessageSnapshot]] = []
        for serial in [false, true] {
            let f = try await backgroundDecodeFixture(codec: RecordingRealtimeWireCodec(passthrough: true))
            defer { f.close() }
            let local = makeMessage(id: "local_compute", senderId: "actor-a", seq: 0, status: .sending, isOutgoing: true)
            var row = computeRow("decode-channel", messageID: "base")
            row.messages.append(local)
            f.state.conversationStore.commitConversationSnapshots([row, computeRow("other", messageID: "other-base")])
            let ticket = try XCTUnwrap(f.state.localMessageTicket)
            _ = try await f.persistence.enqueueOutgoing(ticket: ticket, intent: LocalMessageOutgoingIntent(
                conversation: LocalMessageConversationSnapshot(conversation: row, channelID: row.id,
                    channelType: "group", currentActorID: "actor-a"), message: CachedMessage(message: local),
                operationKind: "send_text", attachment: nil), revision: 1)
            var observations: [RealtimeComputeRuntime.Observation] = []
            f.state.realtimeComputeRuntime.onComputed = { observations.append($0) }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
            let store = f.state.conversationStore
            var ackInstallCount = 0
            let ackCommit = store.memoryCommits.sink { commit in
                guard let window = commit.messageChanges[row.id], window.current.last?.id == "server-ack",
                      !window.previous.contains(where: { $0.id == "server-ack" }) else { return }
                ackInstallCount += 1
                XCTAssertNil(store.messageMemoryStore.installedIncrementalRealtimeUpdate)
            }
            defer { ackCommit.cancel() }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
            let done = expectation(description: "actual serial=\(serial) barrier")
            installComputeBarrier(f, serial: serial, done: done)
            let packets = [computePacket("third", sequence: 3), computePacket("second", sequence: 2),
                computePacket("second", sequence: 2), computePacket("other-next", sequence: 2, channel: "other")]
            f.socket.enqueue(.string(try computeBatch(packets)))
            var ack = computeMessage("server-ack", sequence: 4, sender: "actor-a")
            ack["client_msg_no"] = "local_compute"
            f.socket.enqueue(.string(try computeObject(["type": "send_ack", "payload": ["message": ack]])))
            f.socket.enqueue(.string(computeBarrier)); f.start()
            await fulfillment(of: [done], timeout: 6)
            var pending = try await f.persistence.pendingOutbox(ticket: ticket)
            for _ in 0..<100 where !pending.isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000); pending = try await f.persistence.pendingOutbox(ticket: ticket)
            }
            XCTAssertTrue(pending.isEmpty)
            let snapshot = f.state.conversationStore.conversationMessageSnapshots()
            XCTAssertEqual(ackInstallCount, 1) // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
            XCTAssertEqual(snapshot.first { $0.id == row.id }?.messages.map(\.id), ["base", "second", "third", "server-ack"])
            XCTAssertEqual(snapshot.first { $0.id == row.id }?.messageCoveredThroughSeq, 4)
            // Current fixture waits for the original asynchronous snapshot projection, not only outbox ACK.
            let wantedProjection = f.state.localMessageProjectionRevision
            var persistedProjection = try await f.persistence.projectionRevisionFloor(ticket: ticket)
            for _ in 0..<100 where persistedProjection < wantedProjection {
                try await Task.sleep(nanoseconds: 10_000_000)
                persistedProjection = try await f.persistence.projectionRevisionFloor(ticket: ticket)
            }
            XCTAssertGreaterThanOrEqual(persistedProjection, wantedProjection, "original projection completion serial=\(serial)")
            let disk = try await f.persistence.activateAndLoad(context: f.state.apiContext,
                sessionGeneration: f.state.localMessageSessionGeneration)
            XCTAssertTrue(disk.conversations.flatMap(\.messages).contains { $0.id == "server-ack" && $0.channelSeq == 4 })
            XCTAssertEqual(sentPacketTypes(f.socket), ["connect"])
            XCTAssertTrue(f.http.requests().filter { $0.url?.path.contains("ack") == true }.isEmpty)
            if serial {
                XCTAssertEqual(observations.count, 2)
                XCTAssertTrue(observations.allSatisfy { !$0.mappedOnMainThread && !$0.mergedOnMainThread && !$0.fallback && $0.stalePlans == 0 }, "\(observations.map { ($0.attempts, $0.stalePlans, $0.fallback, $0.fallbackReasons) })")
            } else { XCTAssertTrue(observations.isEmpty) }
            results.append(snapshot)
        }
        XCTAssertEqual(results[0], results[1], "real worker result differs from unchanged original Main algorithms")
    }

    func testRealtimeComputeSuspendedInputsRecomputeOnlyRelevantChanges() async throws {
        for change in ["same-window", "ABA", "read", "directory", "unrelated"] {
            let entered = expectation(description: "captured inputs \(change)")
            let gate = DispatchSemaphore(value: 0), once = DispatchSemaphore(value: 1)
            let f = try await backgroundDecodeFixture(codec: RecordingRealtimeWireCodec(passthrough: true))
            defer { gate.signal(); once.signal(); f.close() }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
            // Keep the group cleanup a no-op so it cannot replace the message's staged frame.
            let rows = [computeRow("decode-channel", messageID: "base"), computeRow("other", messageID: "other-base")]
            f.state.conversationStore.commitConversationSnapshots(rows.map { $0.scrubbingGroupMemberTotals() })
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
            f.state.realtimeComputeRuntime.probe = { phase in
                if case .mapping = phase, once.wait(timeout: .now()) == .success {
                    XCTAssertFalse(Thread.isMainThread); entered.fulfill()
                    XCTAssertEqual(gate.wait(timeout: .now() + 8), .success)
                }
            }
            var observations: [RealtimeComputeRuntime.Observation] = []
            f.state.realtimeComputeRuntime.onComputed = { observations.append($0) }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
            let store = f.state.conversationStore
            var observedInstallCount = 0
            let observedCommit = store.memoryCommits.sink { commit in
                guard change == "same-window" || change == "unrelated",
                      let window = commit.messageChanges["decode-channel"],
                      window.current.last?.id == "arrived", !window.previous.contains(where: { $0.id == "arrived" }) else { return }
                observedInstallCount += 1
                let marker = store.messageMemoryStore.installedIncrementalRealtimeUpdate
                if change == "unrelated" {
                    XCTAssertEqual(marker?.conversationID, "decode-channel")
                    XCTAssertEqual(marker?.revision, commit.current.revision)
                } else {
                    XCTAssertNil(marker)
                }
            }
            defer { observedCommit.cancel() }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
            let done = expectation(description: "suspended actual wire barrier")
            installComputeBarrier(f, serial: true, done: done)
            f.socket.enqueue(.string(try computeBatch([computePacket("arrived", sequence: 2)])))
            f.socket.enqueue(.string(computeBarrier)); f.start()
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertFalse(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")!.messages.contains { $0.id == "arrived" })
            if change == "directory" {
                f.state.contacts = [makeUser(id: "peer", name: "new directory name")]
            } else if change == "read" {
                let watermark = try XCTUnwrap(ConversationStore.ReadWatermark(eventID: "concurrent-read",
                    tenantID: f.state.apiContext.tenantID ?? "", imUID: f.state.apiContext.imUID ?? "", appID: f.state.apiContext.appID,
                    channelID: "decode-channel", channelType: "group", lastReadSeq: 2))
                _ = f.state.conversationStore.rememberReadWatermark(watermark)
            } else {
                let id = change == "unrelated" ? "other" : "decode-channel"
                let index = try XCTUnwrap(f.state.conversationStore.conversations.firstIndex { $0.id == id })
                let original = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: id))
                f.state.conversationStore.mutateStoredConversation(at: index) { value in
                    value.messages[0].text = "local edit"; value.messages[0].attachmentTransferProgress = 0.7
                    value.title = "local title"
                }
                if change == "ABA" { f.state.conversationStore.mutateStoredConversation(at: index) { $0 = original } }
            }
            gate.signal(); await fulfillment(of: [done], timeout: 6)
            let current = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel"))
            XCTAssertEqual(current.messages.map(\.id), ["base", "arrived"])
            let observation = try XCTUnwrap(observations.last)
            XCTAssertEqual(observation.attempts, change == "unrelated" ? 1 : 2, change)
            XCTAssertEqual(observation.stalePlans, change == "unrelated" ? 0 : 1, change)
            XCTAssertFalse(observation.fallback, change)
            XCTAssertFalse(observation.mappedOnMainThread); XCTAssertFalse(observation.mergedOnMainThread)
            if change == "same-window" || change == "unrelated" {
                XCTAssertEqual(observedInstallCount, 1) // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
            }
            if change == "same-window" {
                XCTAssertEqual(current.messages.first?.text, "local edit")
                XCTAssertEqual(current.messages.first?.attachmentTransferProgress, 0.7)
            }
            if change == "read" { XCTAssertEqual(current.lastReadSeq, 2); XCTAssertEqual(current.unread, 0) }
            if change == "directory" { XCTAssertEqual(current.messages.last?.senderName, "new directory name") }
            if change == "unrelated" { XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshot(id: "other")?.messages.first?.text, "local edit") }
        }
    }

    func testRealtimeComputeAcceptedAckSurvivesCredentialRotationButNotRetiredSession() async throws {
        for retire in [false, true] {
            let entered = expectation(description: "held accepted ack")
            let gate = DispatchSemaphore(value: 0), once = DispatchSemaphore(value: 1)
            let f = try await backgroundDecodeFixture(codec: RecordingRealtimeWireCodec(passthrough: true))
            defer { gate.signal(); once.signal(); f.close() }
            let local = makeMessage(id: "local_held", senderId: "actor-a", seq: 0, status: .sending, isOutgoing: true)
            var row = computeRow("decode-channel", messageID: "base"); row.messages.append(local)
            row = row.scrubbingGroupMemberTotals() // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
            f.state.conversationStore.commitConversationSnapshots([row])
            let ticket = try XCTUnwrap(f.state.localMessageTicket)
            _ = try await f.persistence.enqueueOutgoing(ticket: ticket, intent: LocalMessageOutgoingIntent(
                conversation: LocalMessageConversationSnapshot(conversation: row, channelID: row.id, channelType: "group", currentActorID: "actor-a"),
                message: CachedMessage(message: local), operationKind: "send_text", attachment: nil), revision: 1)
            f.state.realtimeComputeRuntime.probe = { phase in
                if case .merging = phase, once.wait(timeout: .now()) == .success {
                    entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 8), .success)
                }
            }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
            let store = f.state.conversationStore
            let targetID = row.id
            var ackInstallCount = 0
            var observations: [RealtimeComputeRuntime.Observation] = []
            f.state.realtimeComputeRuntime.onComputed = { observations.append($0) }
            let ackCommit = store.memoryCommits.sink { commit in
                guard let window = commit.messageChanges[targetID], window.current.last?.id == "held-authority",
                      !window.previous.contains(where: { $0.id == "held-authority" }) else { return }
                ackInstallCount += 1
                XCTAssertEqual(store.memorySnapshot.revision, commit.current.revision)
                XCTAssertNil(store.messageMemoryStore.installedIncrementalRealtimeUpdate)
            }
            defer { ackCommit.cancel() }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
            let callback = try XCTUnwrap(f.client.onSerialEnvelope)
            let returned = expectation(description: "accepted ack callback finished")
            f.client.onSerialEnvelope = { envelope, diagnostic, delivery in
                await callback(envelope, diagnostic, delivery)
                if envelope.type == "send_ack" { returned.fulfill() }
            }
            var ack = computeMessage("held-authority", sequence: 2, sender: "actor-a"); ack["client_msg_no"] = "local_held"
            f.socket.enqueue(.string(try computeObject(["type": "send_ack", "payload": ["message": ack]]))); f.start()
            await fulfillment(of: [entered], timeout: 3)
            if retire { f.state.setAuthenticated(false) }
            else { var context = f.state.apiContext; context.credentialRevision += 1; context.imToken = "rotated-unit-token"; f.state.apiContext = context }
            f.client.disconnect(shouldReconnect: false) // Cancels the native receive task, not an already admitted scope-valid ACK.
            gate.signal(); await fulfillment(of: [returned], timeout: 6)
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
            XCTAssertEqual(ackInstallCount, retire ? 0 : 1)
            if !retire {
                let computed = try XCTUnwrap(observations.first)
                XCTAssertEqual(observations.count, 1)
                XCTAssertEqual(computed.attempts, 1)
                XCTAssertEqual(computed.stalePlans, 0)
                XCTAssertFalse(computed.fallback)
            }
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
            if retire {
                XCTAssertFalse(f.state.conversationStore.conversationMessageSnapshots().flatMap(\.messages).contains { $0.id == "held-authority" })
            } else {
                var pending = try await f.persistence.pendingOutbox(ticket: ticket)
                for _ in 0..<100 where !pending.isEmpty {
                    try await Task.sleep(nanoseconds: 10_000_000); pending = try await f.persistence.pendingOutbox(ticket: ticket)
                }
                XCTAssertTrue(pending.isEmpty)
                XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshot(id: row.id)?.messages.map(\.id), ["base", "held-authority"])
            }
        }
    }

    func testRealtimeComputeMultiwindowAtomicFrameKeepsReentrantCommandsAndMountedChat() async throws {
        let f = try await backgroundDecodeFixture(codec: RecordingRealtimeWireCodec(passthrough: true))
        defer { f.close() }
        f.state.conversationStore.commitConversationSnapshots([computeRow("decode-channel", messageID: "base"), computeRow("other", messageID: "other-base")])
        var bubbles: [String: MessageBubble] = [:]
        ChatTimelineRenderDiagnostics.reset()
        ChatTimelineRenderDiagnostics.batchForwardBubble = { bubble in bubbles[bubble.message.id] = bubble }
        let hosted = hostForSimulatorUI(NavigationView { AppFeatureComposition.chatRouting().makeChat("decode-channel") }
            .navigationViewStyle(.stack).appStateEnvironment(f.state), size: CGSize(width: 390, height: 760))
        defer { hosted.window.isHidden = true; ChatTimelineRenderDiagnostics.reset(); f.state.cancelBatchForward() }
        f.state.beginBatchForward(conversationID: "decode-channel", initialMessageID: "base")
        for _ in 0..<100 where bubbles["base"] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(bubbles["base"])
        let start = f.state.conversationStore.memorySnapshot.revision
        var commits: [UInt64] = [], reentered = false
        let subscription = f.state.conversationStore.memoryCommits.sink { commit in
            commits.append(commit.current.revision)
            XCTAssertEqual(f.state.conversationStore.memorySnapshot.revision, commit.current.revision)
            XCTAssertEqual(f.state.conversationStore.messageMemoryStore.revision, commit.current.revision)
            if !reentered, commit.current.revision > start {
                reentered = true
                XCTAssertTrue(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")!.messages.contains { $0.id == "arrived" })
                XCTAssertTrue(f.state.conversationStore.conversationMessageSnapshot(id: "other")!.messages.contains { $0.id == "other-arrived" })
                _ = f.state.conversationStore.appendLocalOutgoingMessage(self.makeMessage(id: "local_reentrant", seq: 0), to: "decode-channel")
            }
        }
        defer { subscription.cancel() }
        let done = expectation(description: "atomic mounted barrier")
        installComputeBarrier(f, serial: true, done: done)
        f.socket.enqueue(.string(try computeBatch([computePacket("arrived", sequence: 2), computePacket("other-arrived", sequence: 2, channel: "other")])))
        f.socket.enqueue(.string(computeBarrier)); f.start(); await fulfillment(of: [done], timeout: 6)
        XCTAssertTrue(reentered)
        XCTAssertEqual(Array(commits.prefix(2)), [start + 1, start + 2])
        XCTAssertTrue(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")!.messages.contains { $0.id == "local_reentrant" })
        for _ in 0..<100 where bubbles["arrived"] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let displayed = try XCTUnwrap(bubbles["arrived"])
        XCTAssertEqual(displayed.message.id, "arrived")
    }

    func testRealtimeComputeGlobalRTCConflictMatchesOriginalAcrossAtomicWindows() async throws {
        var results: [[ConversationMessageSnapshot]] = []
        for serial in [false, true] {
            let f = try await backgroundDecodeFixture(codec: RecordingRealtimeWireCodec(passthrough: true))
            defer { f.close() }
            let a = computeRow("caller-1:callee-1", messageID: "a-base", kind: .direct); let b = computeRow("other", messageID: "b-base", kind: .direct)
            f.state.conversationStore.commitConversationSnapshots([a, b])
            var observations: [RealtimeComputeRuntime.Observation] = []
            f.state.realtimeComputeRuntime.onComputed = { observations.append($0) }
            let done = expectation(description: "global RTC actual barrier")
            installComputeBarrier(f, serial: serial, done: done)
            let payload: [String: Any] = ["schema_version": 1, "call_id": "compute-global-call", "call_type": "audio",
                "caller_uid": "caller-1", "callee_uid": "callee-1", "final_outcome": "busy",
                "started_at": "2026-08-23T10:00:00Z", "ended_at": "2026-08-23T10:08:42Z",
                "duration_seconds": 0, "reason_code": "busy", "text": "通话已结束", "fallback_text": "通话记录"]
            var packets: [[String: Any]] = []
            for (channel, id) in [(a.id, "rtc-one"), (b.id, "rtc-two")] {
                var message = computeMessage(id, sequence: 2, channel: channel, sender: "caller-1")
                message["channel_type"] = "direct"; message["content_type"] = "rtc_call_record"; message["payload"] = payload
                packets.append(["type": "message", "payload": ["message": message]])
            }
            var commits = 0
            let subscription = f.state.conversationStore.memoryCommits.sink { _ in commits += 1 }
            defer { subscription.cancel() }
            f.socket.enqueue(.string(try computeBatch(packets))); f.socket.enqueue(.string(computeBarrier)); f.start()
            await fulfillment(of: [done], timeout: 6)
            let value = f.state.conversationStore.conversationMessageSnapshots()
            XCTAssertEqual(value.flatMap(\.messages).filter { $0.rtcCallRecord?.callID == "compute-global-call" }.count, 1)
            let conflicting = try XCTUnwrap(value.first { $0.id == b.id })
            XCTAssertTrue(conflicting.messageCoverageRequiresRecovery); XCTAssertEqual(conflicting.messageCoveredThroughSeq, 1)
            if serial {
                XCTAssertEqual(commits, 1, "both RTC-dependent windows must install in one native Store frame")
                XCTAssertEqual(observations.count, 1); XCTAssertFalse(observations[0].fallback)
            }
            results.append(value)
        }
        XCTAssertEqual(results[0], results[1])
    }

    func testRealtimeComputeContentionFallsBackWithoutLosingAcceptedAckOrLatestEdit() async throws {
        let f = try await backgroundDecodeFixture(codec: RecordingRealtimeWireCodec(passthrough: true))
        let first = expectation(description: "first stale plan"), second = expectation(description: "second stale plan")
        let firstToken = DispatchSemaphore(value: 1), secondToken = DispatchSemaphore(value: 1)
        let firstGate = DispatchSemaphore(value: 0), secondGate = DispatchSemaphore(value: 0)
        defer { firstGate.signal(); secondGate.signal(); firstToken.signal(); secondToken.signal(); f.close() }
        var row = computeRow("decode-channel", messageID: "base")
        let local = makeMessage(id: "local_contention", senderId: "actor-a", seq: 0, status: .sending, isOutgoing: true)
        row.messages.append(local); f.state.conversationStore.commitConversationSnapshots([row])
        let ticket = try XCTUnwrap(f.state.localMessageTicket)
        _ = try await f.persistence.enqueueOutgoing(ticket: ticket, intent: LocalMessageOutgoingIntent(
            conversation: LocalMessageConversationSnapshot(conversation: row, channelID: row.id, channelType: "group", currentActorID: "actor-a"),
            message: CachedMessage(message: local), operationKind: "send_text", attachment: nil), revision: 1)
        f.state.realtimeComputeRuntime.probe = { phase in
            guard case .mapping = phase else { return }
            if firstToken.wait(timeout: .now()) == .success {
                first.fulfill(); XCTAssertEqual(firstGate.wait(timeout: .now() + 8), .success)
            } else if secondToken.wait(timeout: .now()) == .success {
                second.fulfill(); XCTAssertEqual(secondGate.wait(timeout: .now() + 8), .success)
            }
        }
        var observed: RealtimeComputeRuntime.Observation?
        f.state.realtimeComputeRuntime.onComputed = { observed = $0 }
        let done = expectation(description: "fallback accepted ACK completes")
        installComputeBarrier(f, serial: true, done: done)
        var ack = computeMessage("contention-authority", sequence: 2, sender: "actor-a"); ack["client_msg_no"] = "local_contention"
        f.socket.enqueue(.string(try computeObject(["type": "send_ack", "payload": ["message": ack]])))
        f.socket.enqueue(.string(computeBarrier)); f.start()
        await fulfillment(of: [first], timeout: 3)
        XCTAssertNotNil(f.state.conversationStore.updateAttachmentProgress(0.2, messageID: "base", conversationID: row.id))
        firstGate.signal(); await fulfillment(of: [second], timeout: 3)
        XCTAssertNotNil(f.state.conversationStore.updateAttachmentProgress(0.8, messageID: "base", conversationID: row.id))
        secondGate.signal(); await fulfillment(of: [done], timeout: 6)
        let observation = try XCTUnwrap(observed)
        XCTAssertEqual(observation.attempts, 3); XCTAssertEqual(observation.stalePlans, 2)
        // Historical method name retained; contention now recomputes off Main instead of falling back.
        XCTAssertFalse(observation.fallback); XCTAssertTrue(observation.fallbackReasons.isEmpty)
        XCTAssertFalse(observation.mappedOnMainThread); XCTAssertFalse(observation.mergedOnMainThread)
        let current = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: row.id))
        XCTAssertEqual(current.messages.map(\.id), ["base", "contention-authority"])
        XCTAssertEqual(current.messages.first?.attachmentTransferProgress, 0.8)
        var pending = try await f.persistence.pendingOutbox(ticket: ticket)
        for _ in 0..<100 where !pending.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000); pending = try await f.persistence.pendingOutbox(ticket: ticket)
        }
        XCTAssertTrue(pending.isEmpty); XCTAssertEqual(sentPacketTypes(f.socket), ["connect"])
    }

    func testRealtimeComputeProjectionMatrixMatchesOriginalActualConsumer() async throws {
        let variants: [(String, [String: Any])] = [
            ("text", ["text": "hello", "mentions": [["uid": "peer-account"]],
                "reply": ["message_id": "quoted", "from_uid": "card-user", "content_type": "text", "text": "quoted text"]]),
            ("image", ["file_id": "image-1", "file_name": "photo.png", "mime_type": "image/png", "width": 800, "height": 600]),
            ("file", ["file_id": "file-1", "file_name": "report.pdf", "size_bytes": 1234, "mime_type": "application/pdf", "download_url": "https://assets.example.test/report.pdf"]),
            ("video", ["file_id": "video-1", "file_name": "video.mp4", "mime_type": "video/mp4", "duration_seconds": 12, "width": 800, "height": 600]),
            ("audio", ["file_id": "audio-1", "file_name": "voice.m4a", "mime_type": "audio/mp4", "duration_seconds": 4, "waveform": [0.1, 0.5, 0.2]]),
            ("sticker", ["file_id": "sticker-1", "url": "https://assets.example.test/sticker.gif", "mime_type": "image/gif", "width": 100, "height": 100]),
            ("contact_card", ["contact_uid": "card-user", "name": "Card contact"]),
            ("system", ["event_type": "group_member_joined", "operator_uid": "card-user", "member_uids": ["peer-account"], "text": "joined"]),
            ("text", ["text": "recalled body"]),
            ("future_type", ["text": "future fallback", "nested": ["nullable": NSNull(), "large": Int64.max]])
        ]
        var values: [[ConversationMessageSnapshot]] = []
        for serial in [false, true] {
            let f = try await backgroundDecodeFixture(codec: RecordingRealtimeWireCodec(passthrough: true))
            defer { f.close() }
            f.state.contacts = [makeUser(id: "peer", name: "Peer directory", userID: "peer-account"), makeUser(id: "card-user", name: "Card directory")]
            f.state.contactRemarks = ["card-user": "Card remark"]
            f.state.conversationStore.commitConversationSnapshots([computeRow("decode-channel", messageID: "base")])
            var observations: [RealtimeComputeRuntime.Observation] = []
            f.state.realtimeComputeRuntime.onComputed = { observations.append($0) }
            var packets: [[String: Any]] = []
            for (index, variant) in variants.enumerated() {
                var message = computeMessage("matrix-\(index)", sequence: Int64(index + 2))
                message["content_type"] = variant.0; message["payload"] = variant.1
                message["sender_avatar"] = "/api/assets/avatar/peer.png"
                if index == 8 { message["status"] = "recalled"; message["is_edited"] = true; message["edit_revision"] = 3 }
                packets.append(["type": "message", "payload": ["message": message]])
            }
            let done = expectation(description: "projection matrix barrier")
            installComputeBarrier(f, serial: serial, done: done)
            f.socket.enqueue(.string(try computeBatch(packets))); f.socket.enqueue(.string(computeBarrier)); f.start()
            await fulfillment(of: [done], timeout: 6)
            let snapshot = f.state.conversationStore.conversationMessageSnapshots()
            XCTAssertEqual(snapshot.flatMap(\.messages).count, variants.count + 1)
            if serial {
                XCTAssertEqual(observations.count, 1)
                XCTAssertFalse(observations[0].fallback, "\(observations[0].fallbackReasons)")
                XCTAssertFalse(observations[0].mappedOnMainThread); XCTAssertFalse(observations[0].mergedOnMainThread)
            }
            values.append(snapshot)
        }
        XCTAssertEqual(values[0], values[1], "complete message values and metadata differ from original mapping/merge")
    }

    func testRealtimeComputeSuspendedGlobalRTCDependencyRecomputesWithoutLosingAuthority() async throws {
        let f = try await backgroundDecodeFixture(codec: RecordingRealtimeWireCodec(passthrough: true))
        let entered = expectation(description: "RTC inputs captured")
        let gate = DispatchSemaphore(value: 0), once = DispatchSemaphore(value: 1)
        defer { gate.signal(); once.signal(); f.close() }
        let target = computeRow("caller-1:callee-1", messageID: "target-base", kind: .direct)
        let other = computeRow("other", messageID: "other-base", kind: .direct)
        f.state.conversationStore.commitConversationSnapshots([target, other])
        let payload: [String: Any] = ["schema_version": 1, "call_id": "held-global-call", "call_type": "audio",
            "caller_uid": "caller-1", "callee_uid": "callee-1", "final_outcome": "busy", "started_at": "2026-08-23T10:00:00Z",
            "ended_at": "2026-08-23T10:08:42Z", "duration_seconds": 0, "reason_code": "busy", "text": "通话已结束", "fallback_text": "通话记录"]
        var incoming = computeMessage("held-rtc", sequence: 2, channel: target.id, sender: "caller-1")
        incoming["channel_type"] = "direct"; incoming["content_type"] = "rtc_call_record"; incoming["payload"] = payload
        f.state.realtimeComputeRuntime.probe = { phase in
            if case .merging = phase, once.wait(timeout: .now()) == .success {
                entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 8), .success)
            }
        }
        var observed: RealtimeComputeRuntime.Observation?
        f.state.realtimeComputeRuntime.onComputed = { observed = $0 }
        let done = expectation(description: "RTC version barrier")
        installComputeBarrier(f, serial: true, done: done)
        f.socket.enqueue(.string(try computeObject(["type": "message", "payload": ["message": incoming]])))
        f.socket.enqueue(.string(computeBarrier)); f.start(); await fulfillment(of: [entered], timeout: 3)
        var authority = incoming; authority["message_id"] = "concurrent-authority"; authority["channel_id"] = other.id
        let remote = try JSONDecoder().decode(RemoteMessage.self, from: JSONSerialization.data(withJSONObject: authority))
        let message = f.state.chatMessage(from: remote)
        _ = try XCTUnwrap(message.rtcCallRecord)
        let index = try XCTUnwrap(f.state.conversationStore.conversations.firstIndex { $0.id == other.id })
        f.state.conversationStore.mutateStoredConversation(at: index) { value in
            value.messages.append(message); value.lastMsgSeq = 2; value.messageCoveredThroughSeq = 2
        }
        gate.signal(); await fulfillment(of: [done], timeout: 6)
        let observation = try XCTUnwrap(observed)
        XCTAssertEqual(observation.attempts, 2); XCTAssertEqual(observation.stalePlans, 1); XCTAssertFalse(observation.fallback)
        let current = f.state.conversationStore.conversationMessageSnapshots()
        XCTAssertEqual(current.flatMap(\.messages).filter { $0.rtcCallRecord?.callID == "held-global-call" }.map(\.id), ["concurrent-authority"])
        XCTAssertTrue(current.first { $0.id == target.id }!.messageCoverageRequiresRecovery)
        XCTAssertEqual(current.first { $0.id == target.id }!.messageCoveredThroughSeq, 1)
    }


    // WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
    func testPhase6HTTPJumpRunsActualDerivationOffMainWithSameWorkload() async throws {
        var results: [ConversationMessageSnapshot] = []
        var measurements: [[String: UInt64]] = []
        for offMain in [false, true] {
            let messages = (2...51).map { computeMessage("http-\($0)", sequence: Int64($0)) }
            let f = try await phase6HTTPFixture(responses: [phase6Page(messages)])
            defer { f.close() }
            f.state.conversationStore.commitConversationSnapshots([computeRow("decode-channel", messageID: "base")])
            var samples: [MessageDerivationSample] = []
            f.state.realtimeComputeRuntime.onDerivation = { samples += $0 }
            let started = DispatchTime.now().uptimeNanoseconds
            if offMain {
                let target = await f.state.prepareMessageJump(messageID: "http-51", channelSeq: 51, conversationID: "decode-channel")
                XCTAssertEqual(target, "http-51")
            } else {
                let page = try await f.state.api.syncMessages(context: f.state.apiContext, channelID: "decode-channel",
                    channelType: "group", afterSeq: 0, beforeSeq: 52, limit: 50)
                f.state.applyRemoteMessages(page.items, channelID: "decode-channel", channelType: "group",
                    derivationTrace: MessageDerivationInstrumentation.context(),
                    historyBoundary: f.state.historyBoundary(from: page, channelType: "group"))
                f.state.conversationStore.normalizePinnedContextMessagesWithinLoadedWindow(conversationID: "decode-channel")
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            let value = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel"))
            XCTAssertEqual(value.messages.map(\.id), ["base"] + (2...51).map { "http-\($0)" })
            XCTAssertEqual(value.messageCoveredThroughSeq, 51)
            let mapping = samples.filter { $0.phase == .mapping }, merging = samples.filter { $0.phase == .merging }
            XCTAssertEqual(mapping.count, 1); XCTAssertEqual(merging.count, 1)
            XCTAssertTrue((mapping + merging).allSatisfy { $0.onMainThread == !offMain })
            if offMain {
                let ordering = samples.filter { $0.phase == .ordering }
                XCTAssertEqual(ordering.count, 1); XCTAssertTrue(ordering.allSatisfy { !$0.onMainThread })
                // WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_BEGIN
                let sources = try XCTUnwrap(mapping.first?.context.sourceCorrelations)
                XCTAssertEqual(sources.count, 1)
                XCTAssertTrue(samples.allSatisfy { $0.context == mapping[0].context })
                // WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_END
            }
            let installed = try XCTUnwrap(samples.first { $0.phase == .storeInstalled })
            XCTAssertTrue(installed.onMainThread)
            XCTAssertEqual(installed.outputRevision, f.state.conversationStore.memorySnapshot.revision)
            XCTAssertEqual(f.http.requests().filter { $0.url?.path == "/api/im/sync" }.count, 1)
            measurements.append(["off_main": offMain ? 1 : 0, "messages": 50, "wall_ns": elapsed,
                "mapping_ns": mapping[0].durationNanoseconds, "merging_ns": merging[0].durationNanoseconds])
            results.append(value)
        }
        XCTAssertEqual(results[0], results[1], "same HTTP payload differs between synchronous compatibility and actual async jump")
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurements),
            uniformTypeIdentifier: "public.json")
        attachment.name = "phase6-same-http50-main-vs-worker-cost"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPhase6HTTPHeldDerivationRechecksScopeEpochABAAndAllowsCredentialAdvance() async throws {
        for change in ["scope", "epoch", "ABA", "credential", "cancel"] {
            let entered = expectation(description: "HTTP actor held \(change)")
            let gate = DispatchSemaphore(value: 0), once = DispatchSemaphore(value: 1)
            let f = try await phase6HTTPFixture(responses: [phase6Page([computeMessage("http-held", sequence: 2)])])
            defer { gate.signal(); once.signal(); f.close() }
            f.state.conversationStore.commitConversationSnapshots([computeRow("decode-channel", messageID: "base")])
            let original = f.state.apiContext
            f.state.realtimeComputeRuntime.probe = { phase in
                if case .mapping = phase, once.wait(timeout: .now()) == .success {
                    XCTAssertFalse(Thread.isMainThread); entered.fulfill()
                    XCTAssertEqual(gate.wait(timeout: .now() + 8), .success)
                }
            }
            let task = Task { await f.state.prepareMessageJump(messageID: "http-held", channelSeq: 2, conversationID: "decode-channel") }
            await fulfillment(of: [entered], timeout: 3)
            var changed = original
            switch change {
            case "scope": changed.tenantID = "other-http-tenant"
            case "epoch": changed.sessionEpoch = UUID().uuidString
            case "ABA":
                changed.tenantID = "other-http-tenant"; changed.sessionEpoch = UUID().uuidString
                f.state.apiContext = changed
                changed = original; changed.sessionEpoch = UUID().uuidString
            case "credential": changed.imToken = "unit-http-rotated"; changed.credentialRevision += 1
            default: task.cancel()
            }
            if change != "cancel" { f.state.apiContext = changed }
            XCTAssertFalse(f.state.conversationStore.conversationMessageSnapshots().flatMap(\.messages).contains { $0.id == "http-held" })
            gate.signal()
            let returned = await task.value
            if change == "credential" {
                XCTAssertEqual(returned, "http-held")
                XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages.map(\.id), ["base", "http-held"])
            } else {
                XCTAssertNil(returned)
                XCTAssertFalse(f.state.conversationStore.conversationMessageSnapshots().flatMap(\.messages).contains { $0.id == "http-held" })
            }
        }
    }

    func testPhase6HTTPDerivationQueuePreservesAdmittedOrderAcrossConversations() async throws {
        let entered = expectation(description: "first HTTP compute owns queue")
        let gate = DispatchSemaphore(value: 0), once = DispatchSemaphore(value: 1)
        // WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_BEGIN
        let transport = try Phase6QueuedHistoryTransport(pages: [
            "decode-channel": phase6Page([computeMessage("http-first", sequence: 2)]),
            "other": phase6Page([computeMessage("http-second", sequence: 2, channel: "other")])])
        let suite = "phase6-http-queue-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = try await phase6HTTPFixture(responses: [], transport: transport, isolatedDefaults: defaults)
        defer { gate.signal(); once.signal(); f.close() }
        defer { f.state.realtimeComputeRuntime.probe = nil }
        // WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_END
        f.state.conversationStore.commitConversationSnapshots([computeRow("decode-channel", messageID: "base"), computeRow("other", messageID: "other-base")])
        var committed: [String] = []
        let subscription = f.state.conversationStore.memoryCommits.sink { commit in
            if commit.messageChanges["decode-channel"]?.current.contains(where: { $0.id == "http-first" }) == true { committed.append("first") }
            if commit.messageChanges["other"]?.current.contains(where: { $0.id == "http-second" }) == true { committed.append("second") }
            XCTAssertEqual(commit.current.revision, f.state.conversationStore.messageMemoryStore.revision)
        }
        defer { subscription.cancel() }
        f.state.realtimeComputeRuntime.probe = { phase in
            if case .mapping = phase, once.wait(timeout: .now()) == .success {
                entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 8), .success)
            }
        }
        let first = Task { await f.state.prepareMessageJump(messageID: "http-first", channelSeq: 2, conversationID: "decode-channel") }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task { await f.state.prepareMessageJump(messageID: "http-second", channelSeq: 2, conversationID: "other") }
        // WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_BEGIN
        defer { first.cancel(); second.cancel() }
        for _ in 0..<100 where f.state.realtimeComputeRuntime.queuedDerivationCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.requestedChannels(), ["decode-channel", "other"])
        XCTAssertEqual(f.state.realtimeComputeRuntime.queuedDerivationCount, 1)
        // WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_END
        XCTAssertTrue(committed.isEmpty, "Main remains responsive while both HTTP responses await the serial compute owner")
        gate.signal()
        let a = await first.value, b = await second.value
        XCTAssertEqual(a, "http-first"); XCTAssertEqual(b, "http-second")
        XCTAssertEqual(committed, ["first", "second"])
    }

    // WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112: HTTP alias and trace tests live in RealtimeMountedHistoryAndRecoveryTests.swift.
    // WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111_BEGIN
    // Native mounted history and sequence recovery now live in RealtimeMountedHistoryAndRecoveryTests.swift.
    // WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111_END

    private func phase6Page(_ messages: [[String: Any]]) throws -> HTTPTransportResult {
        HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["items": messages,
            "history_visible_from_seq": 1, "history_limited": false, "has_more_before": false]]), isHTTPResponse: true, statusCode: 200)
    }

    private func phase6HTTPFixture(responses: [HTTPTransportResult], transport: (any HTTPTransport)? = nil,
        isolatedDefaults: UserDefaults? = nil) async throws -> BackgroundDecodeFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phase6-http-" + UUID().uuidString)
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches"))
        let http = FakeHTTPTransport(results: responses), socket = FakeRealtimeWebSocketTask()
        var context = makeAuthenticatedAPIContext(); context.accountID = UUID().uuidString
        context.tenantID = "phase6-http-" + UUID().uuidString; context.imUID = "actor-a"; context.deviceID = UUID().uuidString
        let defaults = isolatedDefaults ?? .standard
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: isolatedDefaults == nil ? nil : [], httpTransport: transport ?? http,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
            startupContext: isolatedDefaults == nil ? nil : context)
        let client = RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: socket), networkMonitorFactory: nil)
        let discoveryStore = isolatedDefaults.map { _ in AccessDiscoveryStore(baseDirectory: root.appendingPathComponent("discovery")) }
            ?? AccessDiscoveryStore()
        let state = AppState(api: api, pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            accessDiscovery: AccessDiscoveryManager(store: discoveryStore),
            realtimeClient: client, voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshot")), messagePersistence: persistence,
            biometricDefaults: defaults,
            rememberedLoginCredentialStore: isolatedDefaults == nil
                ? KeychainRememberedLoginCredentialStore() : RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: InMemoryProtectedSessionStore(),
            registrationSessionStore: isolatedDefaults == nil
                ? IMKeychainSessionStore(registrationRecovery: true) : InMemoryProtectedSessionStore(),
            apiContextOverride: context)
        if transport == nil { state.setAuthenticated(true) }
        else { state.authenticationPresentationStore.setInitialAuthentication(true) }
        state.storeCancellables.removeAll(); state.suppressCurrentUserIdentityPersistence = true
        state.setCurrentUser(makeUser(id: "actor-a"))
        state.localMessageTicket = try await persistence.ensureTicket(context: context, sessionGeneration: state.localMessageSessionGeneration)
        // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
        // Prime the normal request gate before the history trace. Otherwise a policy fetch
        // inherits the history task-local, and appears in its samples on a cold fixture.
        // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN
        if transport != nil {
            // Select this run's known fixture policy even when C7 retains a last-good
            // policy from an earlier launch. Leave the real SDK request gate enabled.
            let policy: RemoteAppCurrentPolicy
            if isolatedDefaults != nil {
                // Warm the real gate's in-memory policy from the fixture SDK. The normal refresh also
                // writes the app-wide last-good policy, which belongs to the simulator host.
                policy = try await api.currentAppPolicy(appID: context.appID, forceRefresh: true)
                XCTAssertTrue(policy.isUsable)
                state.appPolicyPresentationStore.installResolvedPolicy(policy)
                state.currentAppPolicyExpiresAt = Date().addingTimeInterval(TimeInterval(policy.cacheTTLSeconds))
            } else {
                policy = try await state.loadCurrentAppPolicy(force: true)
            }
            XCTAssertFalse(policy.requireRealName)
            XCTAssertFalse(policy.requirePhoneVerification)
        }
        // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END
        // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
        return BackgroundDecodeFixture(root: root, socket: socket, client: client, state: state, http: http, persistence: persistence)
    }
    // WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END

    private func installComputeBarrier(_ f: BackgroundDecodeFixture, serial: Bool, done: XCTestExpectation) {
        if serial {
            let callback = f.client.onSerialEnvelope!
            f.client.onSerialEnvelope = { envelope, diagnostic, delivery in
                if envelope.type == "compute_barrier" { await f.state.flushPendingRealtimeMessagesSerial(); done.fulfill(); return }
                await callback(envelope, diagnostic, delivery)
            }
        } else {
            let callback = f.client.onEnvelope!
            f.client.onEnvelope = { envelope in
                if envelope.type == "compute_barrier" { f.state.flushPendingRealtimeMessagesForTesting(); done.fulfill(); return }
                callback(envelope)
            }
        }
    }
    private var computeBarrier: String { #"{"type":"compute_barrier","payload":{}}"# }
    private func computeRow(_ id: String, messageID: String, kind: ConversationKind = .group) -> ConversationMessageSnapshot {
        var row = makeConversation(id: id, kind: kind, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.messages = [makeMessage(id: messageID, seq: 1)]; row.messageCoveredThroughSeq = 1
        return row
    }
    private func computeMessage(_ id: String, sequence: Int64, channel: String = "decode-channel", sender: String = "peer") -> [String: Any] {
        ["message_id": id, "channel_id": channel, "channel_type": "group", "channel_seq": sequence, "from_uid": sender,
         "content_type": "text", "created_at": "2026-11-10T01:00:00Z", "payload": ["text": id]]
    }
    private func computePacket(_ id: String, sequence: Int64, channel: String = "decode-channel") -> [String: Any] {
        ["type": "message", "payload": ["message": computeMessage(id, sequence: sequence, channel: channel)]]
    }
    private func computeObject(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    private func computeBatch(_ packets: [[String: Any]]) throws -> String { try computeObject(["type": "batch", "payload": ["frames": packets]]) }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
